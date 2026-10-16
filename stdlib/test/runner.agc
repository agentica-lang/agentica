## The runner of `agentica test`.
##
## `agentica test` compiles a small program that calls `main`. It reads its configuration, runs the feature files and
## test files, and prints the report.

import Gherkin from "std/bdd/gherkin"
import Match from "std/bdd/match"
import Report from "report"
import Child from "child"
import Units from "units"

struct Config
  # The binary, started as `run ...` for the step program and for each scenario.
  vm: String
  # The step program file; "" means the default one that the binary carries, started with `run --embedded steps`.
  steps_bytecode: String
  steps_source: String
  steps_root: String
  steps_error: String
  steps_given: Bool
  agentica: List[String]
  count: Int
  empty_path: String
  empty_message: String
  style: String
  allow_run: Bool
  seeded: Bool
  seed: Int
  only: String
  test_timeout_ms: Int
  report_path: String
end

enum Listing
  Ready(List[Match.Pattern])
  Broken(Report.Error)
end

struct Entry
  path: String
  problem: String
  kind: String
  bytecode: String
  source_root: String
  front_end: String
end

struct StepEnd
  verdict: Report.Verdict
  asserts: Int
end

struct Run
  failed_at: Int
  verdict: Report.Verdict
end

## Reads the configuration file named by the one command-line argument, runs every feature and test file in it, and
## writes the report to the file the configuration names (`report_path`, a new file). The driver reads it from there:
## a child's stdout keeps only 1 MiB, and the report of a large run is bigger. Exits with a non-zero code when
## something failed.
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
  seed = config.seed
  if not config.seeded
    seed = Random.int(0, 2147483647)
  end
  files = matched(config, run_all(seeded(config, seed), read.map do |entry| entry.unwrap! end))
  text = Report.text(files, config.style == "ai", seed)
  if config.style == "json"
    text = JSON.encode(Report.json(files, seed))
  end
  saved = save_report(config.report_path, text)
  if not saved.ok?
    IO.warn("cannot write the BDD report: #{saved.message}")
    System.exit(2)
  end
  code = Report.exit_code(files)
  if code != 0
    System.exit(code)
  end
end

# A file gets at most 1 MiB in one write, and a character takes up to 4 bytes.
def save_report(path: String, text: String) -> Result[Void]
  out = try File.open(path, "create_private", 5000)
  at = 0
  while at < text.length
    size = min_of(250000, text.length - at)
    try File.write(out, text.slice(at, size), 5000)
    at += size
  end
  return File.close(out, 5000)
end

def min_of(a: Int, b: Int) -> Int
  if a < b
    return a
  end
  return b
end

def run_all(config: Config, entries: List[Entry]) -> List[Report.FileResult]
  if entries.size == 0
    problem = Child.located("CHECK-BDD-EMPTY", config.empty_message, config.empty_path)
    return [Report.file_error(config.empty_path, "", problem)]
  end
  listing = Listing.Ready([])
  if entries.any? do |entry| entry.kind == "feature" and entry.problem == "" end
    listing = steps_listing(config)
  elsif config.steps_given and config.steps_error != ""
    listing = steps_listing(config)
  end
  case listing
    Listing.Broken(problem) ->
      tests = entries.filter do |entry| entry.kind == "tests" end.map do |entry| run_entry(config, [], entry) end
      return [Report.file_error(config.steps_source, "steps", problem)].concat(tests)
    Listing.Ready(patterns) -> return entries.map do |entry| run_entry(config, patterns, entry) end
  end
end

def matched(config: Config, files: List[Report.FileResult]) -> List[Report.FileResult]
  if config.only == "" or files.any? do |file| file.scenarios.size > 0 or failed?(file.verdict) end
    return files
  end
  problem = Child.located(
    "CHECK-BDD-EMPTY",
    "no test or scenario name contains #{config.only.inspect}",
    config.empty_path,
  )
  return files.push(Report.file_error(config.empty_path, "", problem))
end

def failed?(verdict: Report.Verdict) -> Bool
  case verdict
    Report.Verdict.Fail(_) -> return true
    Report.Verdict.Pass -> return false
    Report.Verdict.NotExecuted -> return false
  end
end

def steps_listing(config: Config) -> Listing
  where = Report.Span(file: config.steps_source, line: 1, column: 1, end_column: 1)
  if config.steps_error != ""
    parsed = Report.from_json(config.steps_error)
    return Listing.Broken(parsed.unwrap_or(Report.error_at("RUNTIME-BDD-INFRA", parsed.message, where)))
  end
  return list_steps(config, where)
end

def run_entry(config: Config, patterns: List[Match.Pattern], entry: Entry) -> Report.FileResult
  if entry.problem != ""
    return Report.file_error(entry.path, entry.kind, Child.located("RUNTIME-BDD-INFRA", entry.problem, entry.path))
  end
  if entry.kind == "tests"
    settings = Units.Settings(
      vm: config.vm,
      seed: config.seed,
      only: config.only,
      timeout_ms: config.test_timeout_ms,
      source_root: entry.source_root,
    )
    return Units.run(settings, entry.path, entry.bytecode, entry.front_end)
  end
  return run_file(config, patterns, entry.path)
end

def seeded(config: Config, seed: Int) -> Config
  return Config(
    vm: config.vm,
    steps_bytecode: config.steps_bytecode,
    steps_source: config.steps_source,
    steps_root: config.steps_root,
    steps_error: config.steps_error,
    steps_given: config.steps_given,
    agentica: config.agentica,
    count: config.count,
    empty_path: config.empty_path,
    empty_message: config.empty_message,
    style: config.style,
    allow_run: config.allow_run,
    seeded: true,
    seed: seed,
    only: config.only,
    test_timeout_ms: config.test_timeout_ms,
    report_path: config.report_path,
  )
end

# The list child sends the patterns of BDD.run in order on its channel and exits, so the channel is read until it ends.
def list_steps(config: Config, where: Report.Span) -> Listing
  spawned = Process.spawn_channel(config.vm, vm_args(config, 1000000, "list"), ".", 30000)
  if not spawned.ok?
    return Listing.Broken(Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where))
  end
  p = spawned.unwrap!
  Process.close_stdin(p, 5000)
  deadline = Time.monotonic_ms() + 30000
  read = Child.read_records(p, deadline)
  if read.problem == "process: output exceeds 1048576 bytes"
    Process.close(p)
    return Listing.Broken(Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "step program output exceeds 1 MiB", where))
  end
  output = Process.output(p, Child.left(deadline))
  Process.close(p)
  if read.problem == "network: operation timed out" or not output.ok?
    return Listing.Broken(
      Report.error_at("RUNTIME-BDD-TIMEOUT", "the step program did not list its steps within 30 seconds", where),
    )
  end
  if output.unwrap!.truncated
    return Listing.Broken(Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "step program output exceeds 1 MiB", where))
  end
  records = read.items
  failures = records.filter do |record| Child.event_of(record) == "fail" end
  if failures.size > 0
    return Listing.Broken(record_error(failures[0], where))
  end
  if not records.any? do |record| Child.event_of(record) == "ready" end
    crash = Child.stderr_diagnostic(output.unwrap!.stderr, where)
    if crash.ok?
      return Listing.Broken(crash.unwrap!)
    end
    return Listing.Broken(Report.error_at("RUNTIME-BDD-CONTEXT", "the step program did not call BDD.run", where))
  end
  texts = records.filter do |record|
    Child.event_of(record) == "step"
  end.map do |record| Child.text_of(record, "pattern") end
  case Match.compile(texts, where)
    Gherkin.Outcome.Done(patterns) -> return Listing.Ready(patterns)
    Gherkin.Outcome.Failed(problem) -> return Listing.Broken(from_diagnostic(problem))
  end
end

def run_file(config: Config, patterns: List[Match.Pattern], path: String) -> Report.FileResult
  text = File.read_text(path, 5000)
  if text.message == "filesystem: file exceeds 1048576 bytes"
    return Report.file_error(path, "feature", Child.located("RUNTIME-BDD-IO", "feature file exceeds 1 MiB", path))
  end
  if not text.ok?
    return Report.file_error(path, "feature", Child.located("RUNTIME-BDD-INFRA", text.message, path))
  end
  case Gherkin.parse(path, text.unwrap!)
    Gherkin.Outcome.Failed(problem) -> return Report.file_error(path, "feature", from_diagnostic(problem))
    Gherkin.Outcome.Done(feature) ->
      base = Path.resolve(Path.join([path, ".."]).unwrap_or(path)).unwrap_or(path)
      chosen = feature.scenarios.filter do |item| config.only == "" or item.name.include?(config.only) end
      scenarios = chosen.map do |item| run_scenario(config, patterns, base, item) end
      return Report.FileResult(path: path, feature: feature.name, kind: "feature", scenarios: scenarios,
                               verdict: Report.Verdict.Pass, output: "")
  end
end

# Every step is resolved before the child starts; the first unresolved one fails and the others are not executed.
def run_scenario(
  config: Config,
  patterns: List[Match.Pattern],
  base: String,
  item: Gherkin.Scenario,
) -> Report.ScenarioResult
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
        Report.Verdict.NotExecuted -> status = Report.StepStatus.NotExecuted
      end
    end
    Report.StepResult(text: item.steps[i].text, location: item.steps[i].span, status: status)
  end
  return Report.ScenarioResult(
    name: item.name,
    tags: item.tags,
    location: item.span,
    example: item.example,
    duration_ms: Time.monotonic_ms() - started,
    steps: steps,
    verdict: run.verdict,
    output: "",
  )
end

# One child VM per scenario: the settings line, then one line per step on the child's channel, each answered by records
# on it.
def run_child(config: Config, base: String, item: Gherkin.Scenario, found: List[Match.Resolved],
              patterns: List[Match.Pattern], started: Int) -> Run
  count = item.steps.size
  spawned = Process.spawn_channel(config.vm, vm_args(config, 1000000 * (count + 1), "scenario"), ".", 30000)
  if not spawned.ok?
    return Run(failed_at: 0, verdict: failure("RUNTIME-BDD-INFRA", spawned.message, item.steps[0].span))
  end
  p = spawned.unwrap!
  Process.close_stdin(p, 5000)
  deadline = started + 30000
  fields: Map[String, Json] = {
    "base": JSON.from(base),
    "agentica": JSON.from(config.agentica),
    "allow_run": JSON.from(config.allow_run),
    "seeded": JSON.from(config.seeded),
    "seed": JSON.from(config.seed),
  }
  run = Run(failed_at: count, verdict: Report.Verdict.Pass)
  sent = Process.channel_send(p, "#{JSON.encode(JSON.object(fields))}\n", Child.left(deadline))
  if not sent.ok?
    run = Run(failed_at: 0, verdict: Report.Verdict.Fail(send_failure(p, sent.message, deadline, item.steps[0].span)))
  end
  total = 0
  i = 0
  while i < count and run.failed_at == count
    step = item.steps[i]
    sent = Process.channel_send(p, "#{step_line(i, found[i], patterns, step)}\n", Child.left(deadline))
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
      Report.Verdict.NotExecuted -> i += 1
    end
  end
  if run.failed_at == count
    Process.channel_close(p, Child.left(deadline))
    ending = await_exit(p, deadline, item.span)
    case ending
      Report.Verdict.Fail(_) -> run = Run(failed_at: count, verdict: ending)
      Report.Verdict.Pass ->
        if total == 0
          run = Run(
            failed_at: count,
            verdict: failure("RUNTIME-BDD-NO-ASSERTION", "scenario performed no BDD assertions", item.span),
          )
        end
      Report.Verdict.NotExecuted -> run = Run(failed_at: count, verdict: ending)
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

# Reads channel records until the step ends; what the handler printed is read once per step and may not exceed 1 MiB.
def await_step(p: Process, index: Int, deadline: Int, span: Report.Span, then_step: Bool) -> StepEnd
  asserts = 0
  while true
    line = Process.channel_read_line(p, Child.left(deadline))
    if not line.ok?
      return StepEnd(verdict: Report.Verdict.Fail(read_failure(p, line.message, deadline, span)), asserts: asserts)
    end
    record = Child.record_of(line.unwrap!)
    event = Child.event_of(record)
    if event == "assert"
      asserts += 1
    elsif event == "fail" or event == "end"
      printed = Process.read_available(p, Child.left(deadline))
      if not printed.ok?
        return StepEnd(
          verdict: Report.Verdict.Fail(read_failure(p, printed.message, deadline, span)),
          asserts: asserts,
        )
      end
      if event == "fail"
        return StepEnd(verdict: Report.Verdict.Fail(record_error(record, span)), asserts: asserts)
      end
      if JSON.int(JSON.get(record, "index").unwrap_or(JSON.null())).unwrap_or(-1) != index
        return StepEnd(
          verdict: failure("RUNTIME-BDD-INFRA", "the step program broke the BDD record protocol", span),
          asserts: asserts,
        )
      end
      if then_step and asserts == 0
        return StepEnd(
          verdict: failure("RUNTIME-BDD-NO-ASSERTION", "Then must perform a BDD assertion", span),
          asserts: asserts,
        )
      end
      return StepEnd(verdict: Report.Verdict.Pass, asserts: asserts)
    end
  end
  return StepEnd(verdict: Report.Verdict.Pass, asserts: asserts)
end

# After the last step the runner closes the channel and the child exits 0 when it reads the end; anything else fails
# the scenario.
def await_exit(p: Process, deadline: Int, span: Report.Span) -> Report.Verdict
  line = Process.channel_read_line(p, Child.left(deadline))
  while line.ok?
    record = Child.record_of(line.unwrap!)
    if Child.event_of(record) == "fail"
      return Report.Verdict.Fail(record_error(record, span))
    end
    line = Process.channel_read_line(p, Child.left(deadline))
  end
  if line.message == "process: end of input"
    code = Process.wait(p, Child.left(deadline))
    printed = Process.read_available(p, Child.left(deadline))
    if not printed.ok?
      return Report.Verdict.Fail(read_failure(p, printed.message, deadline, span))
    end
    if code.ok? and code.unwrap! == 0
      return Report.Verdict.Pass
    end
  end
  return Report.Verdict.Fail(read_failure(p, line.message, deadline, span))
end

def read_failure(p: Process, message: String, deadline: Int, span: Report.Span) -> Report.Error
  if message == "network: operation timed out"
    return Report.error_at("RUNTIME-BDD-TIMEOUT", "BDD operation timed out", span)
  end
  if message == "process: output exceeds 1048576 bytes" or message == "process: line exceeds 1048576 bytes"
    return Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "handler output exceeds 1 MiB", span)
  end
  if not Child.gone?(message)
    return Report.error_at("RUNTIME-BDD-IO", message, span)
  end
  output = Process.output(p, Child.left(deadline))
  if not output.ok?
    return Report.error_at("RUNTIME-BDD-TIMEOUT", "BDD operation timed out", span)
  end
  crash = Child.stderr_diagnostic(output.unwrap!.stderr, span)
  if crash.ok?
    return crash.unwrap!
  end
  code = Process.wait(p, Child.left(deadline))
  return Report.error_at(
    "RUNTIME-BDD-PREMATURE-EXIT",
    "step exited prematurely (exit code #{code.unwrap_or(-1)})",
    span,
  )
end

def send_failure(p: Process, message: String, deadline: Int, span: Report.Span) -> Report.Error
  if message == "process: send exceeds 1048576 bytes"
    return Report.error_at("RUNTIME-BDD-IO", "the step line exceeds 1 MiB after JSON escaping", span)
  end
  return read_failure(p, message, deadline, span)
end

def record_error(record: Json, span: Report.Span) -> Report.Error
  return Report.Error(
    code: Child.text_of(record, "code"),
    message: Child.text_of(record, "message"),
    span: span,
    end_line: span.line,
    expected: Child.detail_of(record, "expected"),
    actual: Child.detail_of(record, "actual"),
    original: JSON.null(),
  )
end

def resolved_of(outcome: Gherkin.Outcome[Match.Resolved]) -> Match.Resolved
  case outcome
    Gherkin.Outcome.Done(found) -> return found
    Gherkin.Outcome.Failed(_) -> return Match.Resolved(index: -1, captures: [])
  end
end

def unresolved(patterns: List[Match.Pattern], step: Gherkin.Step) -> Report.Error
  case Match.resolve(patterns, step)
    Gherkin.Outcome.Failed(problem) -> return Report.with_actual(from_diagnostic(problem), step.text.inspect)
    Gherkin.Outcome.Done(_) -> return Report.error_at(
      "RUNTIME-BDD-INFRA",
      "the step resolved on the second try",
      step.span,
    )
  end
end

def vm_args(config: Config, steps: Int, mode: String) -> List[String]
  options = [
    "run",
    "--allow-run",
    "--json",
    "--max-steps",
    steps.to_s,
    "--seed",
    config.seed.to_s,
    "--source-root",
    config.steps_root,
  ]
  if config.steps_bytecode == ""
    return options.concat(["--embedded", "steps", "--", "--agentica-bdd", mode])
  end
  return options.concat(["--", config.steps_bytecode, "--agentica-bdd", mode])
end

def failure(code: String, message: String, span: Report.Span) -> Report.Verdict
  return Report.Verdict.Fail(Report.error_at(code, message, span))
end

def from_diagnostic(problem: Gherkin.Diagnostic) -> Report.Error
  return Report.error_at(problem.code, problem.message, problem.span)
end

