import "gherkin" as Gherkin
import "match" as Match
import "report" as Report

struct Config
  vm: String
  steps_bytecode: String
  steps_source: String
  steps_error: String
  agentica: List[String]
  count: Int
  empty_path: String
  style: String
  allow_run: Bool
  seeded: Bool
  seed: Int
end

enum Listing
  Ready(List[Match.Pattern])
  Broken(Report.Error)
end

struct Entry
  path: String
  problem: String
end

struct StepEnd
  verdict: Report.Verdict
  asserts: Int
end

struct Run
  failed_at: Int
  verdict: Report.Verdict
end

export def main() -> Void
  args = System.args()
  if args.size != 1
    IO.warn("usage: the BDD runner takes the path of its configuration file")
    System.exit(2)
  end
  opened = File.open(args[0], "read", 5000)
  if not opened.ok?
    IO.warn("cannot open the BDD runner configuration: #{opened.message}")
    System.exit(2)
  end
  handle = opened.unwrap!
  decoded = JSON.decode(File.read_line(handle, 5000).unwrap_or(""), Config)
  if not decoded.ok?
    IO.warn("invalid BDD runner configuration: #{decoded.message}")
    System.exit(2)
  end
  config = decoded.unwrap!
  # The driver writes one feature file or discovery error per line after the settings.
  read = (0...config.count).to_a.map do |i| JSON.decode(File.read_line(handle, 5000).unwrap_or(""), Entry) end
  closed = File.close(handle, 5000)
  if read.any? do |entry| not entry.ok? end
    IO.warn("invalid BDD runner configuration: a feature entry does not decode")
    System.exit(2)
  end
  files = run_all(config, read.map do |entry| entry.unwrap! end)
  if config.style == "json"
    puts(Report.json(files))
  else
    puts(Report.text(files, config.style == "ai"))
  end
  code = Report.exit_code(files)
  if code != 0
    System.exit(code)
  end
end

def run_all(config: Config, entries: List[Entry]) -> List[Report.FileResult]
  where = Gherkin.Span(file: config.steps_source, line: 1, column: 1, end_column: 1)
  if config.steps_error != ""
    parsed = Report.from_json(config.steps_error)
    fallback = error_at("RUNTIME-BDD-INFRA", parsed.message, where)
    return [Report.file_error(config.steps_source, parsed.unwrap_or(fallback))]
  end
  patterns: List[Match.Pattern] = []
  case list_steps(config, where)
    Listing.Broken(problem) -> return [Report.file_error(config.steps_source, problem)]
    Listing.Ready(found) -> patterns = found
  end
  if entries.size == 0
    return [Report.file_error(config.empty_path, located("CHECK-BDD-EMPTY", "no .feature files found", config.empty_path))]
  end
  return entries.map do |entry|
    if entry.problem != ""
      return Report.file_error(entry.path, located("RUNTIME-BDD-INFRA", entry.problem, entry.path))
    end
    return run_file(config, patterns, entry.path)
  end
end

# The list child writes the patterns of BDD.run in order and exits, so its stdout is read once at the end.
def list_steps(config: Config, where: Gherkin.Span) -> Listing
  spawned = Process.spawn_captured(config.vm, vm_args(config, 1000000, "list"), ".", 30000)
  if not spawned.ok?
    return Listing.Broken(error_at("RUNTIME-BDD-INFRA", spawned.message, where))
  end
  p = spawned.unwrap!
  Process.close_stdin(p, 5000)
  output = Process.output(p, 30000)
  Process.close(p)
  if not output.ok?
    return Listing.Broken(error_at("RUNTIME-BDD-TIMEOUT", "the step program did not list its steps within 30 seconds", where))
  end
  if output.unwrap!.truncated
    return Listing.Broken(error_at("RUNTIME-BDD-OUTPUT-LIMIT", "step program output exceeds 1 MiB", where))
  end
  records = output.unwrap!.stdout.split("\n").filter do |line| line.include?(marker()) end.map do |line| record_of(line) end
  failures = records.filter do |record| event_of(record) == "fail" end
  if failures.size > 0
    return Listing.Broken(record_error(failures[0], where))
  end
  if not records.any? do |record| event_of(record) == "ready" end
    crash = stderr_diagnostic(output.unwrap!.stderr)
    if crash.ok?
      return Listing.Broken(crash.unwrap!)
    end
    return Listing.Broken(error_at("RUNTIME-BDD-CONTEXT", "the step program did not call BDD.run", where))
  end
  texts = records.filter do |record| event_of(record) == "step" end.map do |record| text_of(record, "pattern") end
  case Match.compile(texts, where)
    Gherkin.Outcome.Done(patterns) -> return Listing.Ready(patterns)
    Gherkin.Outcome.Failed(problem) -> return Listing.Broken(Report.from_diagnostic(problem))
  end
end

def run_file(config: Config, patterns: List[Match.Pattern], path: String) -> Report.FileResult
  text = File.read_text(path, 5000)
  if text.message == "filesystem: file exceeds 1048576 bytes"
    return Report.file_error(path, located("RUNTIME-BDD-IO", "feature file exceeds 1 MiB", path))
  end
  if not text.ok?
    return Report.file_error(path, located("RUNTIME-BDD-INFRA", text.message, path))
  end
  case Gherkin.parse(path, text.unwrap!)
    Gherkin.Outcome.Failed(problem) -> return Report.file_error(path, Report.from_diagnostic(problem))
    Gherkin.Outcome.Done(feature) ->
      base = Path.resolve(Path.join([path, ".."]).unwrap_or(path)).unwrap_or(path)
      scenarios = feature.scenarios.map do |item| run_scenario(config, patterns, base, item) end
      return Report.FileResult(path: path, feature: feature.name, scenarios: scenarios, verdict: Report.Verdict.Pass)
  end
end

# Every step is resolved before the child starts; the first unresolved one fails and the others are not executed.
def run_scenario(config: Config, patterns: List[Match.Pattern], base: String, item: Gherkin.Scenario) -> Report.ScenarioResult
  started = Time.monotonic_ms()
  found = item.steps.map do |step| resolved_of(Match.resolve(patterns, step)) end
  failing = (0...found.size).to_a.filter do |i| found[i].index < 0 end
  ran = failing.size == 0
  run = Run(failed_at: item.steps.size, verdict: Report.Verdict.Pass)
  if ran
    run = run_child(config, base, item, found, patterns, started)
  else
    at = failing[0]
    run = Run(failed_at: at, verdict: Report.Verdict.Fail(unresolved(patterns, item.steps[at])))
  end
  steps = (0...item.steps.size).to_a.map do |i|
    status = Report.StepStatus.NotExecuted
    if i < run.failed_at and ran
      status = Report.StepStatus.Passed
    elsif i == run.failed_at
      case run.verdict
        Report.Verdict.Fail(problem) -> status = Report.StepStatus.Failed(problem)
        Report.Verdict.Pass -> status = Report.StepStatus.Passed
      end
    end
    Report.StepResult(text: item.steps[i].text, location: item.steps[i].span, status: status)
  end
  return Report.ScenarioResult(name: item.name, tags: item.tags, location: item.span, example: item.example,
                               duration_ms: Time.monotonic_ms() - started, steps: steps, verdict: run.verdict)
end

# One child VM per scenario: the settings line, then one line per step, each answered by records on the child's stdout.
def run_child(config: Config, base: String, item: Gherkin.Scenario, found: List[Match.Resolved],
              patterns: List[Match.Pattern], started: Int) -> Run
  count = item.steps.size
  spawned = Process.spawn_captured(config.vm, vm_args(config, 1000000 * (count + 1), "scenario"), ".", 30000)
  if not spawned.ok?
    return Run(failed_at: 0, verdict: failure("RUNTIME-BDD-INFRA", spawned.message, item.steps[0].span))
  end
  p = spawned.unwrap!
  deadline = started + 30000
  fields: Map[String, Json] = {
    "base": JSON.from(base),
    "agentica": JSON.from(config.agentica),
    "allow_run": JSON.from(config.allow_run),
    "seeded": JSON.from(config.seeded),
    "seed": JSON.from(config.seed),
  }
  run = Run(failed_at: count, verdict: Report.Verdict.Pass)
  sent = Process.send(p, JSON.encode(JSON.object(fields)) + "\n", left(deadline))
  if not sent.ok?
    run = Run(failed_at: 0, verdict: Report.Verdict.Fail(send_failure(p, sent.message, deadline, item.steps[0].span)))
  end
  total = 0
  i = 0
  while i < count and run.failed_at == count
    step = item.steps[i]
    sent = Process.send(p, step_line(i, found[i], patterns, step) + "\n", left(deadline))
    answer = StepEnd(verdict: Report.Verdict.Pass, asserts: 0)
    if sent.ok?
      answer = await_step(p, i, deadline, step.span, step.kind == "Then")
    else
      answer = StepEnd(verdict: Report.Verdict.Fail(send_failure(p, sent.message, deadline, step.span)), asserts: 0)
    end
    total += answer.asserts
    case answer.verdict
      Report.Verdict.Fail(_) -> run = Run(failed_at: i, verdict: answer.verdict)
      Report.Verdict.Pass -> i += 1
    end
  end
  if run.failed_at == count
    Process.close_stdin(p, left(deadline))
    ending = await_exit(p, deadline, item.span)
    case ending
      Report.Verdict.Fail(_) -> run = Run(failed_at: count, verdict: ending)
      Report.Verdict.Pass ->
        if total == 0
          run = Run(failed_at: count, verdict: failure("RUNTIME-BDD-NO-ASSERTION", "scenario performed no BDD assertions", item.span))
        end
    end
  end
  Process.close(p)
  return run
end

def step_line(index: Int, found: Match.Resolved, patterns: List[Match.Pattern], step: Gherkin.Step) -> String
  has_doc = false
  doc = ""
  has_table = false
  table: List[List[String]] = []
  case step.argument
    Gherkin.Argument.DocString(text) ->
      has_doc = true
      doc = text
    Gherkin.Argument.DataTable(rows) ->
      has_table = true
      table = rows
    Gherkin.Argument.NoArgument -> has_doc = false
  end
  fields: Map[String, Json] = {
    "index": JSON.from(index),
    "definition": JSON.from(found.index),
    "pattern": JSON.from(patterns[found.index].text),
    "captures": JSON.from(found.captures),
    "has_doc": JSON.from(has_doc),
    "doc": JSON.from(doc),
    "has_table": JSON.from(has_table),
    "table": JSON.from(table),
  }
  return JSON.encode(JSON.object(fields))
end

# Reads records until the step ends; text without the marker is handler output, at most 1 MiB per step.
def await_step(p: Process, index: Int, deadline: Int, span: Gherkin.Span, then_step: Bool) -> StepEnd
  asserts = 0
  output = 0
  while true
    line = Process.read_line(p, left(deadline))
    if not line.ok?
      return StepEnd(verdict: Report.Verdict.Fail(read_failure(p, line.message, deadline, span)), asserts: asserts)
    end
    text = line.unwrap!
    at = text.index_of(marker())
    record = JSON.null()
    if at.ok?
      record = record_of(text)
    end
    event = event_of(record)
    if event == ""
      output += text.length + 1
    else
      output += at.unwrap_or(0)
    end
    if output > 1048576
      return StepEnd(verdict: failure("RUNTIME-BDD-OUTPUT-LIMIT", "handler output exceeds 1 MiB", span), asserts: asserts)
    end
    if event == "assert"
      asserts += 1
    elsif event == "fail"
      return StepEnd(verdict: Report.Verdict.Fail(record_error(record, span)), asserts: asserts)
    elsif event == "end"
      if JSON.int(JSON.get(record, "index").unwrap_or(JSON.null())).unwrap_or(-1) != index
        return StepEnd(verdict: failure("RUNTIME-BDD-INFRA", "the step program broke the BDD record protocol", span), asserts: asserts)
      end
      if then_step and asserts == 0
        return StepEnd(verdict: failure("RUNTIME-BDD-NO-ASSERTION", "Then must perform a BDD assertion", span), asserts: asserts)
      end
      peek = Process.read_bytes(p, 0, 1000)
      if not peek.ok?
        return StepEnd(verdict: Report.Verdict.Fail(read_failure(p, peek.message, deadline, span)), asserts: asserts)
      end
      return StepEnd(verdict: Report.Verdict.Pass, asserts: asserts)
    end
  end
  return StepEnd(verdict: Report.Verdict.Pass, asserts: asserts)
end

# After the last step the child exits 0 when its stdin ends; anything else fails the scenario.
def await_exit(p: Process, deadline: Int, span: Gherkin.Span) -> Report.Verdict
  line = Process.read_line(p, left(deadline))
  while line.ok?
    text = line.unwrap!
    if text.include?(marker()) and event_of(record_of(text)) == "fail"
      return Report.Verdict.Fail(record_error(record_of(text), span))
    end
    line = Process.read_line(p, left(deadline))
  end
  if line.message == "process: end of input"
    code = Process.wait(p, left(deadline))
    if code.ok? and code.unwrap! == 0
      return Report.Verdict.Pass
    end
  end
  return Report.Verdict.Fail(read_failure(p, line.message, deadline, span))
end

def read_failure(p: Process, message: String, deadline: Int, span: Gherkin.Span) -> Report.Error
  if message == "network: operation timed out"
    return error_at("RUNTIME-BDD-TIMEOUT", "BDD operation timed out", span)
  end
  if message == "process: output exceeds 1048576 bytes" or message == "process: line exceeds 1048576 bytes"
    return error_at("RUNTIME-BDD-OUTPUT-LIMIT", "handler output exceeds 1 MiB", span)
  end
  if message != "process: end of input"
    return error_at("RUNTIME-BDD-IO", message, span)
  end
  output = Process.output(p, left(deadline))
  if not output.ok?
    return error_at("RUNTIME-BDD-TIMEOUT", "BDD operation timed out", span)
  end
  crash = stderr_diagnostic(output.unwrap!.stderr)
  if crash.ok?
    return crash.unwrap!
  end
  code = Process.wait(p, left(deadline))
  return error_at("RUNTIME-BDD-PREMATURE-EXIT", "step exited prematurely (exit code #{code.unwrap_or(-1)})", span)
end

def send_failure(p: Process, message: String, deadline: Int, span: Gherkin.Span) -> Report.Error
  if message == "process: send exceeds 1048576 bytes"
    return error_at("RUNTIME-BDD-IO", "the step line exceeds 1 MiB after JSON escaping", span)
  end
  return read_failure(p, message, deadline, span)
end

# A child that halts writes its --json diagnostic as the last line of stderr.
def stderr_diagnostic(stderr: String) -> Result[Report.Error]
  lines = stderr.split("\n").filter do |line| line != "" end
  if lines.size == 0
    return error("no diagnostic")
  end
  return Report.from_json(lines[lines.size - 1])
end

def record_error(record: Json, span: Gherkin.Span) -> Report.Error
  return Report.Error(code: text_of(record, "code"), message: text_of(record, "message"), span: span, end_line: span.line,
                      expected: detail_of(record, "expected"), actual: detail_of(record, "actual"), original: JSON.null())
end

def detail_of(record: Json, key: String) -> Report.Detail
  found = JSON.get(record, key)
  if found.ok? and JSON.string(found.unwrap!).ok?
    return Report.Detail.Known(JSON.string(found.unwrap!).unwrap!)
  end
  return Report.Detail.Unknown
end

def resolved_of(outcome: Gherkin.Outcome[Match.Resolved]) -> Match.Resolved
  case outcome
    Gherkin.Outcome.Done(found) -> return found
    Gherkin.Outcome.Failed(_) -> return Match.Resolved(index: -1, captures: [])
  end
end

def unresolved(patterns: List[Match.Pattern], step: Gherkin.Step) -> Report.Error
  case Match.resolve(patterns, step)
    Gherkin.Outcome.Failed(problem) -> return Report.with_actual(Report.from_diagnostic(problem), step.text)
    Gherkin.Outcome.Done(_) -> return error_at("RUNTIME-BDD-INFRA", "the step resolved on the second try", step.span)
  end
end

def vm_args(config: Config, steps: Int, mode: String) -> List[String]
  seed: List[String] = []
  if config.seeded
    seed = ["--seed", config.seed.to_s]
  end
  return ["--allow-run", "--json", "--max-steps", steps.to_s].concat(seed).concat(["--", config.steps_bytecode, "--agentica-bdd", mode])
end

def left(deadline: Int) -> Int
  remaining = deadline - Time.monotonic_ms()
  if remaining < 1
    return 1
  end
  return remaining
end

def record_of(line: String) -> Json
  at = line.index_of(marker()).unwrap_or(0) + marker().length
  return JSON.parse(line.slice(at, line.length - at)).unwrap_or(JSON.null())
end

def event_of(record: Json) -> String
  return text_of(record, "event")
end

def text_of(record: Json, key: String) -> String
  found = JSON.get(record, key)
  if found.ok?
    return JSON.string(found.unwrap!).unwrap_or("")
  end
  return ""
end

def failure(code: String, message: String, span: Gherkin.Span) -> Report.Verdict
  return Report.Verdict.Fail(error_at(code, message, span))
end

def error_at(code: String, message: String, span: Gherkin.Span) -> Report.Error
  return Report.from_diagnostic(Gherkin.Diagnostic(code: code, message: message, span: span))
end

def located(code: String, message: String, path: String) -> Report.Error
  return error_at(code, message, Gherkin.Span(file: path, line: 1, column: 1, end_column: 1))
end

def marker() -> String
  return String.from_code(30) + "agentica-bdd "
end
