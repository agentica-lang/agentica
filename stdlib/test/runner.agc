## The runner of `agentica test`.
##
## `agentica test` compiles a small program that calls `main`. It reads its configuration, runs the feature files and
## test files, and prints the report.

import Gherkin from "std/bdd/gherkin"
import Match from "std/bdd/match"
import Tags from "std/bdd/tags"
import Report from "report"
import Child from "child"
import Coverage from "coverage"
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
  # The command that runs a program under test: the binary, then the user's --deny-* flags and --sandbox, which every
  # child that runs the user's code gets too (see `deny`). The runner itself runs without them.
  agentica: List[String]
  count: Int
  empty_path: String
  empty_message: String
  style: String
  seeded: Bool
  seed: Int
  only: String
  test_timeout_ms: Int
  report_path: String
end

enum Listing
  Ready(List[Match.Pattern])
  Broken(Report.Failure)
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

# A feature file read and filtered, before its scenarios run: its result without scenarios, the folder its scenarios
# run in, and the scenarios that --only and --tags keep.
struct Planned
  shell: Report.FileResult
  base: String
  chosen: List[Gherkin.Scenario]
end

# How an entry runs: whole (a test file, or an entry with a problem), as a result known before anything runs (a
# feature file that cannot be read or parsed), or scenario by scenario.
enum Plan
  Whole
  Known(Report.FileResult)
  Scenarios(Planned)
end

# One piece of work of `--jobs`: a whole entry (scenario is -1), or one scenario of a feature file with what it needs,
# so a task copies only its own scenario.
struct Job
  entry: Int
  scenario: Int
  item: Optional[Gherkin.Scenario]
  base: String
  cover: String
end

# What a job gives back.
enum Ran
  File(Report.FileResult)
  Scenario(Report.ScenarioResult)
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
  # The driver writes one feature file or discovery error per line after the settings, then, only when `--tags` was
  # given, the expression as a JSON string. It is a line of its own, not a field of `Config`, because the decode of
  # `Config` has no optional fields and the driver of stage0 (which never writes it) must keep working.
  read = (0...config.count).to_a.map do |_| JSON.decode(File.read_line(handle, 5000).unwrap_or(""), Entry) end
  tags = read_tags(handle)
  jobs = read_jobs(handle)
  timing = read_timing(handle)
  parts = read_coverage(handle)
  _ = File.close(handle, 5000)
  if read.any? do |entry| not entry.ok? end
    IO.warn("invalid BDD runner configuration: a feature entry does not decode")
    System.exit(2)
  end
  seed = config.seed
  if not config.seeded
    seed = Random.int(0, 2147483647)
  end
  started = Time.monotonic_ms()
  entries = read.map do |entry| entry.unwrap! end
  files = selected(seeded(config, seed), tags, jobs, parts, entries)
  # Wall time, not the sum of the file times: with `--jobs` the files and their scenarios overlap.
  wall_ms = Time.monotonic_ms() - started
  text = Report.text(files, config.style == "ai", seed)
  if timing and config.style != "json"
    text = Report.timed_text(files, config.style == "ai", seed, wall_ms)
  end
  # A red run still writes its coverage: what its tests reached is worth seeing. A green run whose report cannot be
  # written fails, so that CI does not upload an old report as this run's.
  covered = covered_run(config, parts, entries)
  code = Report.exit_code(files)
  if code == 0 and Coverage.failed?(covered)
    code = 1
  end

  if config.style == "json" and parts != ""
    more = {"coverage": Coverage.json(covered), "ok": JSON.from(code == 0), "exit_code": JSON.from(code)}
    text = JSON.encode(Report.json_and(files, seed, wall_ms, more))
  elsif config.style == "json"
    text = JSON.encode(Report.json(files, seed, wall_ms))
  elsif parts != ""
    text = "#{text}\n#{Coverage.report_text(covered)}"
  end
  saved = save_report(config.report_path, text)
  if not saved.ok?
    IO.warn("cannot write the BDD report: #{saved.message}")
    System.exit(2)
  end
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
  File.close(out, 5000)
end

def min_of(a: Int, b: Int) -> Int
  return a if a < b
  b
end

# The `--tags` expression: the line after the entries, a JSON string. No line is no filter; a line that cannot be read
# is a failure, so a run never goes on without the filter that was asked for.
def read_tags(handle: File.Handle) -> Result[String]
  line = File.read_line(handle, 5000)
  case line
    ok(_) -> nil
    error(e) ->
      return ok("") if e.is_a?("io.eof")

      return error(e)
  end

  text = JSON.string(JSON.parse(line.unwrap!).unwrap_or(JSON.null()))
  return error("the line is not a JSON string", kind: "json.decode") if !text.ok?

  text
end

# The `--jobs` line, after the tags line: a JSON integer. A missing or unusable line is one job at a time, the
# behaviour without the flag.
def read_jobs(handle: File.Handle) -> Int
  line = File.read_line(handle, 5000)
  return 1 if !line.ok?

  parsed = JSON.int(JSON.parse(line.unwrap!).unwrap_or(JSON.null()))
  return 1 if !parsed.ok? or parsed.unwrap! < 1

  parsed.unwrap!
end

# The `--coverage` line, after the timing line: the folder for the LCOV part of each child, as a JSON string. A missing
# line is no coverage.
def read_coverage(handle: File.Handle) -> String
  line = File.read_line(handle, 5000)
  return "" if !line.ok?

  JSON.string(JSON.parse(line.unwrap!).unwrap_or(JSON.null())).unwrap_or("")
end

# The coverage of the run (Coverage.collect), without the test files and the step program: they always run.
def covered_run(config: Config, parts: String, entries: List[Entry]) -> Coverage.Run
  return Coverage.Run(path: "", files: [], broken: [], problem: "") if parts == ""

  tests = entries.filter do |entry| entry.kind == "tests" end
  left_out = tests.map do |entry| Coverage.shown(entry.path) end
  Coverage.collect(parts, left_out.push(Coverage.shown(config.steps_source)))
end

# The `--timing` line, after the jobs line: a JSON boolean. A missing or unusable line is no timing.
def read_timing(handle: File.Handle) -> Bool
  line = File.read_line(handle, 5000)
  return false if !line.ok?

  JSON.bool(JSON.parse(line.unwrap!).unwrap_or(JSON.null())).unwrap_or(false)
end

# The report of the run. A `--tags` expression that cannot be read or is bad is a usage error and nothing runs (the
# driver has checked the expression already, so this is a mismatch of driver and runner).
def selected(
  config: Config,
  tags: Result[String],
  jobs: Int,
  parts: String,
  entries: List[Entry],
) -> List[Report.FileResult]
  compiled = Tags.compile(tags.unwrap_or(""))
  message = ""
  if !tags.ok?
    message = "cannot read --tags: #{tags.message}"
  elsif !compiled.ok?
    message = "invalid --tags: #{compiled.message}"
  end

  if message != ""
    where = Report.Span(file: "<arguments>", line: 1, column: 1, end_column: 1)
    return [Report.file_error("<arguments>", "", Report.error_at("RUNTIME-BDD-USAGE", message, where))]
  end

  matched(config, tags.unwrap!, compiled.unwrap!, run_all(config, compiled.unwrap!, jobs, parts, entries))
end

def run_all(config: Config, tags: Tags.Expr, jobs: Int, parts: String, found: List[Entry]) -> List[Report.FileResult]
  if found.size == 0
    problem = Child.located("CHECK-BDD-EMPTY", config.empty_message, config.empty_path)
    return [Report.file_error(config.empty_path, "", problem)]
  end
  # Unit tests have no tags, so `--tags` leaves them out.
  entries = found
  if Tags.filters?(tags)
    entries = found.filter do |entry| entry.kind != "tests" or entry.problem != "" end
  end

  listing = Listing.Ready([])
  if entries.any? do |entry| entry.kind == "feature" and entry.problem == "" end
    listing = steps_listing(config)
  elsif config.steps_given and config.steps_error != ""
    listing = steps_listing(config)
  end
  case listing
    Listing.Broken(problem) ->
      tests = run_entries(config, tags, [], jobs, parts, entries.filter do |entry| entry.kind == "tests" end)
      [Report.file_error(config.steps_source, "steps", problem)].concat(tests)
    Listing.Ready(patterns) -> run_entries(config, tags, patterns, jobs, parts, entries)
  end
end

# Runs the entries and gives their results in the order of `entries`, each file's scenarios in file order, so the
# report does not depend on which job ends first. One job (the default) runs them one after another without tasks.
# With more, the jobs are the scenarios of the feature files and the whole test files, `jobs` at a time from one
# queue in entry order, so one long feature file no longer runs alone at the end. Each scenario and test file already
# runs in its own child VM, so a task only waits for its children. The task deadline starts when the job's task starts,
# after it has a slot. The job has a limit of its own (each scenario and test has one), so the deadline is a day.
def run_entries(
  config: Config,
  tags: Tags.Expr,
  patterns: List[Match.Pattern],
  jobs: Int,
  parts: String,
  entries: List[Entry],
) -> List[Report.FileResult]
  # The LCOV part of each child is named after its file's place in `entries` (and its scenario's in the file), so
  # children that run at once never share one.
  indices = (0...entries.size).to_a
  return indices.map do |at| run_entry(config, tags, patterns, part_of(parts, at), entries[at]) end if jobs <= 1

  plans = indices.map do |at| plan_entry(config, tags, entries[at]) end
  work = jobs_of(plans, parts)
  ended = Task.map(work, jobs, 86_400_000) do |job|
    if job.scenario < 0
      at = job.entry
      return ok(Ran.File(run_entry(config, tags, patterns, part_of(parts, at), entries[at])))
    end

    ok(Ran.Scenario(run_scenario(config, patterns, job.base, job.item.unwrap!, job.cover)))
  end

  gathered(entries, plans, work, ended)
end

# The jobs of the plans, in entry order and each file's scenarios in file order.
def jobs_of(plans: List[Plan], parts: String) -> List[Job]
  work: List[Job] = []
  for at in 0...plans.size
    case plans[at]
      Plan.Whole -> work = work.push(Job(entry: at, scenario: -1, item: none, base: "", cover: ""))
      Plan.Known(_) -> work = work
      Plan.Scenarios(planned) ->
        for index in 0...planned.chosen.size
          cover = cover_of(part_of(parts, at), index)
          job = Job(entry: at, scenario: index, item: some(planned.chosen[index]), base: planned.base, cover: cover)
          work = work.push(job)
        end
    end
  end

  work
end

# The result of each entry from the results of its jobs, which follow `work` in order. A job that did not end (an
# infrastructure failure of its task) makes its whole file an error, as when the file was one job.
def gathered(
  entries: List[Entry],
  plans: List[Plan],
  work: List[Job],
  ended: List[Result[Ran]],
) -> List[Report.FileResult]
  results: List[Report.FileResult] = []
  next = 0
  for at in 0...entries.size
    entry = entries[at]
    scenarios: List[Report.ScenarioResult] = []
    file: Optional[Report.FileResult] = none
    problem = ""
    while next < work.size and work[next].entry == at
      case ended[next]
        ok(ran) ->
          case ran
            Ran.File(result) -> file = some(result)
            Ran.Scenario(result) -> scenarios = scenarios.push(result)
          end

        error(message) ->
          if problem == ""
            problem = "#{message}"
          end
      end
      next += 1
    end

    if problem != ""
      located = Child.located("RUNTIME-BDD-INFRA", problem, entry.path)
      results = results.push(Report.file_error(entry.path, entry.kind, located))
    else
      case plans[at]
        Plan.Known(result) -> results = results.push(result)
        Plan.Whole -> results = results.push(file.unwrap!)
        Plan.Scenarios(planned) -> results = results.push(planned.shell.with(scenarios: scenarios))
      end
    end
  end

  results
end

# A filter (`--only` or `--tags`) that keeps nothing is an error, not a pass.
def matched(
  config: Config,
  tags_text: String,
  tags: Tags.Expr,
  files: List[Report.FileResult],
) -> List[Report.FileResult]
  filtered = config.only != "" or Tags.filters?(tags)
  kept = files.any? do |file| file.scenarios.size > 0 or failed?(file.verdict) end
  return files if not filtered or kept
  message = "no test or scenario name contains #{config.only.inspect}"
  if config.only == ""
    message = "no scenario has tags matching #{tags_text.inspect}"
  elsif Tags.filters?(tags)
    message = "no scenario matches --only #{config.only.inspect} and --tags #{tags_text.inspect}"
  end

  problem = Child.located("CHECK-BDD-EMPTY", message, config.empty_path)
  files.push(Report.file_error(config.empty_path, "", problem))
end

def failed?(verdict: Report.Verdict) -> Bool
  case verdict
    Report.Verdict.Fail(_) -> true
    Report.Verdict.Pass -> false
    Report.Verdict.Skipped(_) -> false
    Report.Verdict.NotExecuted -> false
  end
end

def steps_listing(config: Config) -> Listing
  where = Report.Span(file: config.steps_source, line: 1, column: 1, end_column: 1)
  if config.steps_error != ""
    parsed = Report.from_json(config.steps_error)
    return Listing.Broken(parsed.unwrap_or(Report.error_at("RUNTIME-BDD-INFRA", parsed.message, where)))
  end
  list_steps(config, where)
end

# The name of the LCOV parts of the file at `at` without its `.info`, or "" without coverage.
def part_of(parts: String, at: Int) -> String
  return "" if parts == ""

  "#{parts}/#{at}"
end

def run_entry(
  config: Config,
  tags: Tags.Expr,
  patterns: List[Match.Pattern],
  part: String,
  entry: Entry,
) -> Report.FileResult
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
      deny: deny(config),
      coverage: part,
    )

    return Units.run(settings, entry.path, entry.bytecode, entry.front_end)
  end
  run_file(config, tags, patterns, part, entry.path)
end

# How an entry runs under `--jobs`: a feature file without a problem is read and filtered here, the rest run whole.
def plan_entry(config: Config, tags: Tags.Expr, entry: Entry) -> Plan
  return Plan.Whole if entry.problem != "" or entry.kind == "tests"

  plan_file(config, tags, entry.path)
end

def seeded(config: Config, seed: Int) -> Config
  Config(
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
    seeded: true,
    seed: seed,
    only: config.only,
    test_timeout_ms: config.test_timeout_ms,
    report_path: config.report_path,
  )
end

# The list child sends the patterns of BDD.run in order on its channel and exits, so the channel is read until it ends.
def list_steps(config: Config, where: Report.Span) -> Listing
  spawned = Process.spawn_channel(config.vm, vm_args(config, 1000000, "list", ""))
  return Listing.Broken(Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where)) if not spawned.ok?
  p = spawned.unwrap!
  _ = Process.close_stdin(p, 5000)
  deadline = Time.monotonic_ms() + 30000
  read = Child.read_records(p, deadline)
  if read.problem == "process: output exceeds 1048576 bytes"
    Process.close(p)
    return Listing.Broken(Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "step program output exceeds 1 MiB", where))
  end
  output = Process.output(p, Child.left(deadline))
  Process.close(p)
  if read.problem == "process: operation timed out" or not output.ok?
    return Listing.Broken(
      Report.error_at("RUNTIME-BDD-TIMEOUT", "the step program did not list its steps within 30 seconds", where),
    )
  end
  if output.unwrap!.truncated
    return Listing.Broken(Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "step program output exceeds 1 MiB", where))
  end
  records = read.items
  failures = records.filter do |record| Child.event_of(record) == "fail" end
  return Listing.Broken(record_error(failures[0], where)) if failures.size > 0
  if not records.any? do |record| Child.event_of(record) == "ready" end
    crash = Child.stderr_diagnostic(output.unwrap!.stderr, where)
    return Listing.Broken(crash.unwrap!) if crash.ok?
    return Listing.Broken(Report.error_at("RUNTIME-BDD-CONTEXT", "the step program did not call BDD.run", where))
  end
  steps = records.filter do |record| Child.event_of(record) == "step" end
  texts = steps.map do |record| Child.text_of(record, "pattern") end

  case Match.compile(texts, where)
    Gherkin.Outcome.Done(patterns) -> Listing.Ready(patterns)
    Gherkin.Outcome.Failed(problem) -> Listing.Broken(from_diagnostic(problem))
  end
end

def run_file(
  config: Config,
  tags: Tags.Expr,
  patterns: List[Match.Pattern],
  part: String,
  path: String,
) -> Report.FileResult
  case plan_file(config, tags, path)
    Plan.Scenarios(planned) ->
      chosen = planned.chosen
      scenarios = (0...chosen.size).to_a.map do |at|
        run_scenario(config, patterns, planned.base, chosen[at], cover_of(part, at))
      end

      planned.shell.with(scenarios: scenarios)
    Plan.Known(result) -> result
    # `plan_file` never returns `Whole` (only `plan_entry` does); the case needs the arm.
    Plan.Whole -> Report.file_error(path, "feature", Child.located("RUNTIME-BDD-INFRA", "nothing to run", path))
  end
end

# Reads and parses a feature file and keeps the scenarios that --only and --tags select; a file that cannot be read or
# parsed is its error.
def plan_file(config: Config, tags: Tags.Expr, path: String) -> Plan
  text = File.read_text(path, 5000)
  if text.message == "filesystem: file exceeds 1048576 bytes"
    located = Child.located("RUNTIME-BDD-IO", "feature file exceeds 1 MiB", path)
    return Plan.Known(Report.file_error(path, "feature", located))
  end
  if not text.ok?
    return Plan.Known(Report.file_error(path, "feature", Child.located("RUNTIME-BDD-INFRA", text.message, path)))
  end
  case Gherkin.parse(path, text.unwrap!)
    Gherkin.Outcome.Failed(problem) -> Plan.Known(Report.file_error(path, "feature", from_diagnostic(problem)))
    Gherkin.Outcome.Done(feature) ->
      base = Path.resolve(Path.join([path, ".."]).unwrap_or(path)).unwrap_or(path)
      chosen = feature.scenarios.filter do |item|
        (config.only == "" or item.name.include?(config.only)) and Tags.selects?(tags, item.tags)
      end

      shell = Report.FileResult(
        path: path,
        feature: feature.name,
        kind: "feature",
        scenarios: [],
        verdict: Report.Verdict.Pass,
        output: "",
      )

      Plan.Scenarios(Planned(shell: shell, base: base, chosen: chosen))
  end
end

# The LCOV file of the scenario at `at` of a file whose part is `part`, or "" without coverage.
def cover_of(part: String, at: Int) -> String
  return "" if part == ""

  "#{part}-#{at}.info"
end

# Every step is resolved before the child starts; the first unresolved one fails and the others are not executed.
def run_scenario(
  config: Config,
  patterns: List[Match.Pattern],
  base: String,
  item: Gherkin.Scenario,
  cover: String,
) -> Report.ScenarioResult
  started = Time.monotonic_ms()
  found = item.steps.map do |step| resolved_of(Match.resolve(patterns, step)) end
  failing = (0...found.size).to_a.filter do |i| found[i].index < 0 end
  ran = failing.size == 0
  run = Run(failed_at: item.steps.size, verdict: Report.Verdict.Pass)
  if ran
    run = run_child(config, base, item, found, patterns, started, cover)
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
        Report.Verdict.Skipped(_) -> status = Report.StepStatus.Skipped
        Report.Verdict.Pass -> status = Report.StepStatus.Passed
        Report.Verdict.NotExecuted -> status = Report.StepStatus.NotExecuted
      end
    end
    Report.StepResult(text: item.steps[i].text, location: item.steps[i].span, status: status)
  end

  Report.ScenarioResult(
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
def run_child(
  config: Config,
  base: String,
  item: Gherkin.Scenario,
  found: List[Match.Resolved],
  patterns: List[Match.Pattern],
  started: Int,
  cover: String,
) -> Run
  count = item.steps.size
  spawned = Process.spawn_channel(config.vm, vm_args(config, 1000000 * (count + 1), "scenario", cover))
  if not spawned.ok?
    return Run(failed_at: 0, verdict: failure("RUNTIME-BDD-INFRA", spawned.message, item.steps[0].span))
  end
  p = spawned.unwrap!
  _ = Process.close_stdin(p, 5000)
  deadline = started + 30000
  fields: Map[String, JSON.Value] = {
    "base": JSON.from(base),
    "agentica": JSON.from(config.agentica),
    "seeded": JSON.from(config.seeded),
    "seed": JSON.from(config.seed),
    "programs": JSON.from(run_folder(config)),
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
      Report.Verdict.Skipped(_) -> run = Run(failed_at: i, verdict: answer.verdict)
      Report.Verdict.Pass -> i += 1
      Report.Verdict.NotExecuted -> i += 1
    end
  end
  if run.failed_at == count
    _ = Process.channel_close(p, Child.left(deadline))
    ending = await_exit(p, deadline, item.span)
    case ending
      Report.Verdict.Fail(_) -> run = Run(failed_at: count, verdict: ending)
      Report.Verdict.Skipped(_) -> run = Run(failed_at: count, verdict: ending)
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
  run
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
  fields: Map[String, JSON.Value] = {
    "index": JSON.from(index),
    "definition": JSON.from(found.index),
    "pattern": JSON.from(patterns[found.index].text),
    "captures": JSON.from(found.captures),
    "has_doc": JSON.from(has_doc),
    "doc": JSON.from(doc),
    "has_table": JSON.from(has_table),
    "table": JSON.from(table),
  }

  JSON.encode(JSON.object(fields))
end

# Reads channel records until the step ends; what the handler printed is read once per step and may not exceed 1 MiB.
def await_step(p: Process, index: Int, deadline: Int, span: Report.Span, then_step: Bool) -> StepEnd
  asserts = 0
  hooks = false
  while true
    line = Process.channel_read_line(p, Child.left(deadline))
    if not line.ok?
      # `BDD.skip` runs the hooks before it sends `skip`: a deadline after `after` is a hook's.
      if hooks and line.message == "process: operation timed out"
        return StepEnd(verdict: failure("RUNTIME-BDD-TIMEOUT", late_text(true), span), asserts: asserts)
      end
      return StepEnd(verdict: Report.Verdict.Fail(read_failure(p, line.message, deadline, span)), asserts: asserts)
    end
    record = Child.record_of(line.unwrap!)
    event = Child.event_of(record)
    if event == "assert"
      asserts += 1
    elsif event == "after"
      hooks = true
    elsif event == "fail" or event == "end" or event == "skip"
      printed = Process.read_available(p, Child.left(deadline))
      if not printed.ok?
        return StepEnd(
          verdict: Report.Verdict.Fail(read_failure(p, printed.message, deadline, span)),
          asserts: asserts,
        )
      end
      if event == "fail"
        failure = with_hook_problems(p, record_error(record, span), deadline)
        return StepEnd(verdict: Report.Verdict.Fail(failure), asserts: asserts)
      end
      if event == "skip"
        return StepEnd(verdict: Report.Verdict.Skipped(Child.text_of(record, "reason")), asserts: asserts)
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
  StepEnd(verdict: Report.Verdict.Pass, asserts: asserts)
end

# After a failed step the child runs its after hooks (`BDD.after`) and then exits. What the hooks report arrives as
# more fail records: they are added to the message, so the step's own failure stays the one shown. The wait ends with
# the child, or at the scenario's deadline.
def with_hook_problems(p: Process, failure: Report.Failure, deadline: Int) -> Report.Failure
  message = failure.message
  hooks = false
  line = Process.channel_read_line(p, Child.left(deadline))
  while line.ok?
    record = Child.record_of(line.unwrap!)
    event = Child.event_of(record)
    if event == "after"
      hooks = true
    elsif event == "fail"
      message = "#{message}; #{Child.text_of(record, "message")}"
    end
    line = Process.channel_read_line(p, Child.left(deadline))
  end
  if line.message == "process: operation timed out"
    message = "#{message}; #{late_text(hooks)}"
  end
  Report.Failure(
    code: failure.code,
    message: message,
    span: failure.span,
    end_line: failure.end_line,
    expected: failure.expected,
    actual: failure.actual,
    original: failure.original,
  )
end

# After the last step the runner closes the channel and the child exits 0 when it reads the end; anything else fails
# the scenario.
def await_exit(p: Process, deadline: Int, span: Report.Span) -> Report.Verdict
  hooks = false
  line = Process.channel_read_line(p, Child.left(deadline))
  while line.ok?
    record = Child.record_of(line.unwrap!)
    event = Child.event_of(record)
    if event == "after"
      hooks = true
    elsif event == "fail"
      return Report.Verdict.Fail(record_error(record, span))
    end
    line = Process.channel_read_line(p, Child.left(deadline))
  end
  if line.message == "process: end of input"
    code = Process.wait(p, Child.left(deadline))
    printed = Process.read_available(p, Child.left(deadline))
    return Report.Verdict.Fail(read_failure(p, printed.message, deadline, span)) if not printed.ok?
    return Report.Verdict.Pass if code.ok? and code.unwrap! == 0
  end
  return failure("RUNTIME-BDD-TIMEOUT", late_text(hooks), span) if line.message == "process: operation timed out"
  Report.Verdict.Fail(read_failure(p, line.message, deadline, span))
end

# Why a child that has sent its last record is still running at the deadline: its after hooks when it said they run
# (the `after` record), else only its own end.
def late_text(hooks: Bool) -> String
  return "an after hook did not finish within the scenario's time limit" if hooks
  "the step program did not exit within the scenario's time limit"
end

def read_failure(p: Process, message: String, deadline: Int, span: Report.Span) -> Report.Failure
  if message == "process: operation timed out"
    return Report.error_at("RUNTIME-BDD-TIMEOUT", "BDD operation timed out", span)
  end
  if message == "process: output exceeds 1048576 bytes" or message == "process: line exceeds 1048576 bytes"
    return Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "handler output exceeds 1 MiB", span)
  end
  return Report.error_at("RUNTIME-BDD-IO", message, span) if not Child.gone?(message)
  output = Process.output(p, Child.left(deadline))
  return Report.error_at("RUNTIME-BDD-TIMEOUT", "BDD operation timed out", span) if not output.ok?
  crash = Child.stderr_diagnostic(output.unwrap!.stderr, span)
  return crash.unwrap! if crash.ok?
  code = Process.wait(p, Child.left(deadline))
  Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "step exited prematurely (exit code #{code.unwrap_or(-1)})", span)
end

def send_failure(p: Process, message: String, deadline: Int, span: Report.Span) -> Report.Failure
  if message == "process: send exceeds 1048576 bytes"
    return Report.error_at("RUNTIME-BDD-IO", "the step line exceeds 1 MiB after JSON escaping", span)
  end
  read_failure(p, message, deadline, span)
end

def record_error(record: JSON.Value, span: Report.Span) -> Report.Failure
  Report.Failure(
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
    Gherkin.Outcome.Done(found) -> found
    Gherkin.Outcome.Failed(_) -> Match.Resolved(index: -1, captures: [])
  end
end

def unresolved(patterns: List[Match.Pattern], step: Gherkin.Step) -> Report.Failure
  case Match.resolve(patterns, step)
    Gherkin.Outcome.Failed(problem) -> Report.with_actual(from_diagnostic(problem), step.text.inspect)
    Gherkin.Outcome.Done(_) -> Report.error_at("RUNTIME-BDD-INFRA", "the step resolved on the second try", step.span)
  end
end

# `cover` is the LCOV part of the child (`--coverage`), or "" for none.
def vm_args(config: Config, steps: Int, mode: String, cover: String) -> List[String]
  options = [
    "run",
    "--json",
    "--max-steps",
    steps.to_s,
    "--seed",
    config.seed.to_s,
    "--source-root",
    config.steps_root,
  ].concat(deny(config))

  if cover != ""
    options = options.concat(["--coverage", cover])
  end

  return options.concat(["--embedded", "steps", "--", "--agentica-bdd", mode]) if config.steps_bytecode == ""
  options.concat(["--", config.steps_bytecode, "--agentica-bdd", mode])
end

# The private folder of the run, which holds the report: `std/bdd` compiles the programs under test there, once for
# every scenario (`compiled` in stdlib/bdd.agc).
def run_folder(config: Config) -> String
  Path.resolve(Path.join([config.report_path, ".."]).unwrap_or("")).unwrap_or("")
end

# The user's --deny-* flags and --sandbox: the words after the binary in `agentica`.
def deny(config: Config) -> List[String] = config.agentica.drop(1)

def failure(code: String, message: String, span: Report.Span) -> Report.Verdict
  Report.Verdict.Fail(Report.error_at(code, message, span))
end

def from_diagnostic(problem: Gherkin.Diagnostic) -> Report.Failure
  Report.error_at(problem.code, problem.message, problem.span)
end
