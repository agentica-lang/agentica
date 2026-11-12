## Results of `agentica test`, and the text and JSON reports built from them.

# How many scenarios the timing lists, the slowest first.
SLOWEST = 5

## A place in a file: the line, the column and the end column.
export struct Span
  file: String
  line: Int
  column: Int
  end_column: Int
end

## Where a scenario came from: no example, or one `Examples` row.
export enum Example
  NoExample
  Row(Span)
end

## An expected or actual value of an error: unknown, or known as text.
export enum Detail
  Unknown
  Known(String)
end

## A failure: a code, a message and its place, and the expected and actual values when known.
## `original` keeps the diagnostic object as `--json` wrote it (with its `stack` keys, which the text report shows), or
## JSON null for an error built from fields.
export struct Failure
  code: String
  message: String
  span: Span
  end_line: Int
  expected: Detail
  actual: Detail
  original: Json
end

## The result of a scenario or a file: `Pass`, `Fail` with an error, `Skipped` with the reason a step gave, or
## `NotExecuted`.
export enum Verdict
  Pass
  Fail(Failure)
  Skipped(String)
  NotExecuted
end

## The result of one step. `Skipped` is the step that ended its scenario with `BDD.skip`.
export enum StepStatus
  Passed
  Failed(Failure)
  Skipped
  NotExecuted
end

## The text, place and status of one step.
export struct StepResult
  text: String
  location: Span
  status: StepStatus
end

## The result of one scenario: its steps, verdict, duration and output.
export struct ScenarioResult
  name: String
  tags: List[String]
  location: Span
  example: Example
  duration_ms: Int
  steps: List[StepResult]
  verdict: Verdict
  output: String
end

## The result of one feature file or test file.
export struct FileResult
  path: String
  feature: String
  kind: String
  scenarios: List[ScenarioResult]
  verdict: Verdict
  output: String
end

# A scenario with the name of its file, as the report shows it.
struct Timed
  label: String
  item: ScenarioResult
end

struct Totals
  passed: Int
  failed: Int
  skipped: Int
  not_executed: Int
  file_errors: Int
  exit_code: Int
end

## Builds a `Failure` at `span` with no expected or actual value.
export def error_at(code: String, message: String, span: Span) -> Failure
  Failure(
    code: code,
    message: message,
    span: span,
    end_line: span.line,
    expected: Detail.Unknown,
    actual: Detail.Unknown,
    original: JSON.null(),
  )
end

## Reads a diagnostic as `--json` writes it. Keeps the whole object, so the report writes every key unchanged
## (`help`, `callee`, `labels` and so on).
export def from_json(text: String) -> Result[Failure]
  root = try JSON.parse(text)
  range = try JSON.get(root, "range")
  start = try JSON.get(range, "start")
  stop = try JSON.get(range, "end")
  span = Span(
    file: try text_at(root, "file"),
    line: try int_at(start, "line"),
    column: try int_at(start, "column"),
    end_column: try int_at(stop, "column"),
  )

  ok(
    Failure(
      code: try text_at(root, "code"),
      message: try text_at(root, "message"),
      span: span,
      end_line: try int_at(stop, "line"),
      expected: detail_at(root, "expected"),
      actual: detail_at(root, "actual"),
      original: root,
    ),
  )
end

## Adds `actual` to an error built from fields. An error from `from_json` is returned unchanged, since its kept object
## is what the report writes, so the text and the JSON cannot disagree.
export def with_actual(problem: Failure, actual: String) -> Failure
  return problem if not JSON.null?(problem.original)
  Failure(
    code: problem.code,
    message: problem.message,
    span: problem.span,
    end_line: problem.end_line,
    expected: problem.expected,
    actual: Detail.Known(actual),
    original: problem.original,
  )
end

## Builds a file result with no scenarios that fails with `problem`.
export def file_error(path: String, kind: String, problem: Failure) -> FileResult
  file_failure(path, kind, problem, "")
end

## Like `file_error`, and keeps the `output` of the file.
export def file_failure(path: String, kind: String, problem: Failure, output: String) -> FileResult
  FileResult(path: path, feature: "", kind: kind, scenarios: [], verdict: Verdict.Fail(problem), output: output)
end

## Returns the exit code of a run: 0 when there is a scenario and nothing failed or was left unexecuted (a skipped
## scenario is not a failure), 2 when any file or scenario error is `RUNTIME-BDD-INFRA` or `RUNTIME-BDD-USAGE`, else 1.
export def exit_code(files: List[FileResult]) -> Int = totals(files).exit_code

## Builds the `--json` report of `files` and the `seed` as a JSON object. `wall_ms` is the time the run took, which
## is less than the sum of the file times when files run in parallel (`--jobs`).
export def json(files: List[FileResult], seed: Int, wall_ms: Int) -> Json = json_and(files, seed, wall_ms, {})

## `json` with the fields of `more` added (`coverage`), or put in place of its own (`ok` and `exit_code`).
export def json_and(files: List[FileResult], seed: Int, wall_ms: Int, more: Map[String, Json]) -> Json
  sums = totals(files)
  fields: Map[String, Json] = {
    "ok": JSON.from(sums.exit_code == 0),
    "passed": JSON.from(sums.passed),
    "failed": JSON.from(sums.failed),
    "skipped": JSON.from(sums.skipped),
    "not_executed": JSON.from(sums.not_executed),
    "seed": JSON.from(seed),
    "file_errors": JSON.from(sums.file_errors),
    "exit_code": JSON.from(sums.exit_code),
    "duration_ms": JSON.from(wall_ms),
    "files": JSON.array(files.map do |file| file_json(file) end),
  }

  for key in more.keys
    fields = fields.put(key, more[key])
  end

  JSON.object(fields)
end

## Builds the plain text report, or the `--ai` text when `ai` is true. It has no final newline.
export def text(files: List[FileResult], ai: Bool, seed: Int) -> String = report_text(files, ai, seed, false, 0)

## Like `text`, with the time of the run (`wall_ms`, as in `json`), of each file and of the slowest scenarios
## (`agentica test --timing`) before the totals.
export def timed_text(files: List[FileResult], ai: Bool, seed: Int, wall_ms: Int) -> String
  report_text(files, ai, seed, true, wall_ms)
end

def report_text(files: List[FileResult], ai: Bool, seed: Int, timing: Bool, wall_ms: Int) -> String
  sums = totals(files)
  chunks = files.map do |file| file_text(file, ai) end
  if timing
    chunks = chunks.push(timing_text(files, wall_ms))
  end
  last = (
    "#{sums.passed} passed, #{sums.failed} failed, #{sums.skipped} skipped, #{sums.not_executed} not executed, " +
    "#{sums.file_errors} file errors"
  )

  if sums.exit_code != 0
    last = "#{last}, seed #{seed}"
  end
  shown = chunks.filter do |chunk| chunk != "" end
  shown.push(last).join("\n")
end

# The time of a file: the durations of its scenarios, which run one after another.
def file_ms(file: FileResult) -> Int = file.scenarios.reduce(0) do |n, item| n + item.duration_ms end

# The time of the run, then one line for each file with the sum of the times of its scenarios in milliseconds, then the
# slowest scenarios, as `agentica test --timing` prints them. A file with no scenario (a file error) shows no line.
def timing_text(files: List[FileResult], wall_ms: Int) -> String
  ran = files.filter do |file| file.scenarios.size > 0 end
  lines = ["timing: #{wall_ms} ms"]
  timed: List[Timed] = []
  for file in ran
    label = file_label(file)
    lines = lines.push("  #{file_ms(file)} ms of scenarios #{label} (#{count_text(file.scenarios.size)})")
    timed = timed.concat(file.scenarios.map do |item| Timed(label: label, item: item) end)
  end

  by_time = timed.sort_by do |entry| 0 - entry.item.duration_ms end
  slowest = by_time.take(SLOWEST)
  if slowest.size > 0
    lines = lines.push("slowest scenarios:")
  end

  for entry in slowest
    lines = lines.push("  #{entry.item.duration_ms} ms #{entry.label} / #{entry.item.name}")
  end

  lines.join("\n")
end

def file_label(file: FileResult) -> String
  return file.path if file.kind == "tests"

  file.feature
end

def count_text(count: Int) -> String
  return "1 scenario" if count == 1

  "#{count} scenarios"
end

# How many scenarios of the files have the status `wanted`.
def with_status(files: List[FileResult], wanted: String) -> Int
  files.reduce(0) do |n, file|
    matching = file.scenarios.filter do |item| status(item.verdict) == wanted end
    n + matching.size
  end
end

def totals(files: List[FileResult]) -> Totals
  scenarios = files.reduce(0) do |n, file| n + file.scenarios.size end
  passed = with_status(files, "passed")
  skipped = with_status(files, "skipped")
  not_run = with_status(files, "not_executed")
  failed_files = files.filter do |file| failed?(file.verdict) end
  file_errors = failed_files.size
  severe = files.any? do |file| severe?(file.verdict) or file.scenarios.any? do |item| severe?(item.verdict) end end
  code = 1
  if scenarios > 0 and passed + skipped == scenarios and file_errors == 0
    code = 0
  elsif severe
    code = 2
  end
  Totals(
    passed: passed,
    failed: scenarios - passed - skipped - not_run,
    skipped: skipped,
    not_executed: not_run,
    file_errors: file_errors,
    exit_code: code,
  )
end

def failed?(verdict: Verdict) -> Bool = status(verdict) == "failed"

def severe?(verdict: Verdict) -> Bool
  case verdict
    Verdict.Fail(problem) -> problem.code == "RUNTIME-BDD-INFRA" or problem.code == "RUNTIME-BDD-USAGE"
    Verdict.Pass -> false
    Verdict.Skipped(_) -> false
    Verdict.NotExecuted -> false
  end
end

def status(verdict: Verdict) -> String
  case verdict
    Verdict.Pass -> "passed"
    Verdict.Fail(_) -> "failed"
    Verdict.Skipped(_) -> "skipped"
    Verdict.NotExecuted -> "not_executed"
  end
end

def file_json(file: FileResult) -> Json
  state = status(file.verdict)
  if file.scenarios.any? do |item| failed?(item.verdict) end
    state = "failed"
  end
  fields: Map[String, Json] = {
    "path": JSON.from(file.path),
    "feature": JSON.from(file.feature),
    "kind": JSON.from(file.kind),
    "status": JSON.from(state),
    "duration_ms": JSON.from(file_ms(file)),
    "scenarios": JSON.array(file.scenarios.map do |item| scenario_json(item) end),
    "error": verdict_json(file.verdict),
    "output": JSON.from(file.output),
  }

  JSON.object(fields)
end

def scenario_json(item: ScenarioResult) -> Json
  example = JSON.null()
  case item.example
    Example.Row(span) -> example = location_json(span)
    Example.NoExample -> example = JSON.null()
  end
  fields: Map[String, Json] = {
    "name": JSON.from(item.name),
    "status": JSON.from(status(item.verdict)),
    "tags": JSON.from(item.tags),
    "location": location_json(item.location),
    "example": example,
    "duration_ms": JSON.from(item.duration_ms),
    "steps": JSON.array(item.steps.map do |step| step_json(step) end),
    "error": verdict_json(item.verdict),
    "reason": reason_json(item.verdict),
    "output": JSON.from(item.output),
  }

  JSON.object(fields)
end

# The reason a step gave to `BDD.skip`, or null.
def reason_json(verdict: Verdict) -> Json
  case verdict
    Verdict.Skipped(reason) -> JSON.from(reason)
    Verdict.Pass -> JSON.null()
    Verdict.Fail(_) -> JSON.null()
    Verdict.NotExecuted -> JSON.null()
  end
end

def step_json(step: StepResult) -> Json
  state = "passed"
  problem = JSON.null()
  case step.status
    StepStatus.Passed -> state = "passed"
    StepStatus.NotExecuted -> state = "not_executed"
    StepStatus.Skipped -> state = "skipped"
    StepStatus.Failed(found) ->
      state = "failed"
      problem = error_json(found)
  end
  fields: Map[String, Json] = {
    "text": JSON.from(step.text),
    "status": JSON.from(state),
    "location": location_json(step.location),
    "error": problem,
  }

  JSON.object(fields)
end

def location_json(span: Span) -> Json
  fields: Map[String, Json] = {
    "file": JSON.from(span.file),
    "line": JSON.from(span.line),
    "column": JSON.from(span.column),
  }

  JSON.object(fields)
end

def verdict_json(verdict: Verdict) -> Json
  case verdict
    Verdict.Fail(problem) -> error_json(problem)
    Verdict.Pass -> JSON.null()
    Verdict.Skipped(_) -> JSON.null()
    Verdict.NotExecuted -> JSON.null()
  end
end

def error_json(problem: Failure) -> Json
  return problem.original if not JSON.null?(problem.original)
  span = problem.span
  start: Map[String, Json] = {"line": JSON.from(span.line), "column": JSON.from(span.column)}
  stop: Map[String, Json] = {"line": JSON.from(problem.end_line), "column": JSON.from(span.end_column)}
  range: Map[String, Json] = {"start": JSON.object(start), "end": JSON.object(stop)}
  fields: Map[String, Json] = {
    "code": JSON.from(problem.code),
    "message": JSON.from(problem.message),
    "file": JSON.from(span.file),
    "range": JSON.object(range),
  }

  JSON.object(put_detail(put_detail(fields, "expected", problem.expected), "actual", problem.actual))
end

def put_detail(fields: Map[String, Json], key: String, detail: Detail) -> Map[String, Json]
  case detail
    Detail.Known(value) -> fields.put(key, JSON.from(value))
    Detail.Unknown -> fields
  end
end

def file_text(file: FileResult, ai: Bool) -> String
  head: List[String] = []
  case file.verdict
    Verdict.Fail(problem) ->
      head = ["FAIL #{file.path}#{separator(ai)}#{summary(problem, ai)}#{output_text(file.output, ai)}"]
    Verdict.Pass -> head = []
    Verdict.Skipped(_) -> head = []
    Verdict.NotExecuted -> head = []
  end
  label = file_label(file)
  lines = file.scenarios.map do |item| scenario_text(label, item, ai) end
  head.concat(lines).join("\n")
end

def scenario_text(label: String, item: ScenarioResult, ai: Bool) -> String
  case item.verdict
    Verdict.Pass -> "PASS #{label} / #{item.name}"
    Verdict.NotExecuted -> "NOT RUN #{label} / #{item.name}"
    Verdict.Skipped(reason) -> "SKIP #{label} / #{item.name}#{skip_text(reason, ai)}"
    Verdict.Fail(problem) ->
      "FAIL #{label} / #{item.name}#{separator(ai)}#{summary(problem, ai)}#{output_text(item.output, ai)}"
  end
end

# The reason on one line, whatever line breaks it holds.
def skip_text(reason: String, ai: Bool) -> String
  shown = reason.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
  if shown == ""
    return ""
  elsif ai
    return " | #{shown}"
  end

  "\n  #{shown}"
end

def separator(ai: Bool) -> String
  return " | " if ai
  "\n"
end

def output_text(output: String, ai: Bool) -> String
  if output == ""
    return ""
  elsif ai
    return " | output #{output.inspect}"
  end
  lines = output.split("\n").map do |line| "  #{line}" end
  indented = lines.join("\n")
  "\n#{indented}"
end

def summary(problem: Failure, ai: Bool) -> String
  span = problem.span
  head = "#{span.file}:#{span.line}:#{span.column} [#{problem.code}] #{problem.message}"
  head + detail_text("expected", problem.expected) + detail_text("actual", problem.actual) + stack_text(problem, ai)
end

def stack_text(problem: Failure, ai: Bool) -> String
  lines = stack_lines(problem.original)
  if lines.length == 0
    return ""
  elsif ai
    return " | stack #{lines.join("; ")}"
  end
  indented = lines.map do |line| "    #{line}" end
  frames = indented.join("\n")
  "\n  stack, innermost first:\n#{frames}"
end

def stack_lines(root: Json) -> List[String]
  found = JSON.get(root, "stack")
  return [] if not found.ok?
  no_frames: List[Json] = []
  frames = JSON.list(found.unwrap!).unwrap_or(no_frames)
  omitted = int_at(root, "stack_omitted").unwrap_or(0)
  lines: List[String] = []
  for index in 0...frames.length
    if omitted > 0 and index == stack_head()
      lines = lines.concat([not_shown(omitted)])
    end
    lines = lines.concat([frame_line(frames[index])])
  end
  spawned = JSON.get(root, "spawned_at")
  if spawned.ok?
    lines = lines.concat(["task spawned at #{place_text(spawned.unwrap!)}"])
  end
  lines
end

# The frames the VM shows before a cut stack's gap: AGC_STACK_HEAD in vm/port.h.
def stack_head() -> Int = 15

def not_shown(omitted: Int) -> String
  return "... 1 frame not shown ..." if omitted == 1
  "... #{omitted} frames not shown ..."
end

def frame_line(frame: Json) -> String
  name = text_at(frame, "function").unwrap_or("?")
  line = "#{name} at #{place_text(frame)}"
  repeat = int_at(frame, "repeat").unwrap_or(1)
  if repeat > 1
    line = "#{line} (#{repeat} times)"
  end
  if JSON.get(frame, "tail").ok?
    line = "#{line} (after a tail call)"
  end
  line
end

def place_text(place: Json) -> String
  file = text_at(place, "file").unwrap_or("?")
  line = int_at(place, "line").unwrap_or(0)
  column = int_at(place, "column").unwrap_or(0)
  "#{file}:#{line}:#{column}"
end

def detail_text(label: String, detail: Detail) -> String
  case detail
    Detail.Known(value) -> "; #{label} #{value}"
    Detail.Unknown -> ""
  end
end

def text_at(root: Json, key: String) -> Result[String] = JSON.string(try JSON.get(root, key))

def int_at(root: Json, key: String) -> Result[Int] = JSON.int(try JSON.get(root, key))

def detail_at(root: Json, key: String) -> Detail
  found = JSON.get(root, key)
  if found.ok?
    value = JSON.string(found.unwrap!)
    return Detail.Known(value.unwrap!) if value.ok?
  end
  Detail.Unknown
end
