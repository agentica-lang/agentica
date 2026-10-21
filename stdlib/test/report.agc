## Results of `agentica test`, and the text and JSON reports built from them.

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
export struct Error
  code: String
  message: String
  span: Span
  end_line: Int
  expected: Detail
  actual: Detail
  original: Json
end

## The result of a scenario or a file: `Pass`, `Fail` with an error, or `NotExecuted`.
export enum Verdict
  Pass
  Fail(Error)
  NotExecuted
end

## The result of one step.
export enum StepStatus
  Passed
  Failed(Error)
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

struct Totals
  passed: Int
  failed: Int
  not_executed: Int
  file_errors: Int
  exit_code: Int
end

## Builds an `Error` at `span` with no expected or actual value.
export def error_at(code: String, message: String, span: Span) -> Error
  return Error(code: code, message: message, span: span, end_line: span.line, expected: Detail.Unknown,
               actual: Detail.Unknown, original: JSON.null())
end

## Reads a diagnostic as `--json` writes it. Keeps the whole object, so the report writes every key unchanged
## (`help`, `callee`, `labels` and so on).
export def from_json(text: String) -> Result[Error]
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
  return ok(
    Error(
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
export def with_actual(problem: Error, actual: String) -> Error
  if not JSON.null?(problem.original)
    return problem
  end
  return Error(code: problem.code, message: problem.message, span: problem.span, end_line: problem.end_line,
               expected: problem.expected, actual: Detail.Known(actual), original: problem.original)
end

## Builds a file result with no scenarios that fails with `problem`.
export def file_error(path: String, kind: String, problem: Error) -> FileResult
  return file_failure(path, kind, problem, "")
end

## Like `file_error`, and keeps the `output` of the file.
export def file_failure(path: String, kind: String, problem: Error, output: String) -> FileResult
  return FileResult(path: path, feature: "", kind: kind, scenarios: [], verdict: Verdict.Fail(problem), output: output)
end

## Returns the exit code of a run: 0 when at least one scenario ran and nothing failed, 2 when any file or scenario
## error is `RUNTIME-BDD-INFRA` or `RUNTIME-BDD-USAGE`, else 1.
export def exit_code(files: List[FileResult]) -> Int
  return totals(files).exit_code
end

## Builds the `--json` report of `files` and the `seed` as a JSON object.
export def json(files: List[FileResult], seed: Int) -> Json
  sums = totals(files)
  fields: Map[String, Json] = {
    "ok": JSON.from(sums.exit_code == 0),
    "passed": JSON.from(sums.passed),
    "failed": JSON.from(sums.failed),
    "not_executed": JSON.from(sums.not_executed),
    "seed": JSON.from(seed),
    "file_errors": JSON.from(sums.file_errors),
    "exit_code": JSON.from(sums.exit_code),
    "files": JSON.array(files.map do |file| file_json(file) end),
  }
  return JSON.object(fields)
end

## Builds the plain text report, or the `--ai` text when `ai` is true. It has no final newline.
export def text(files: List[FileResult], ai: Bool, seed: Int) -> String
  sums = totals(files)
  chunks = files.map do |file| file_text(file, ai) end
  last = (
    "#{sums.passed} passed, #{sums.failed} failed, #{sums.not_executed} not executed, " +
    "#{sums.file_errors} file errors"
  )
  if sums.exit_code != 0
    last = "#{last}, seed #{seed}"
  end
  return chunks.filter do |chunk| chunk != "" end.push(last).join("\n")
end

def totals(files: List[FileResult]) -> Totals
  scenarios = files.reduce(0) do |n, file| n + file.scenarios.size end
  passed = files.reduce(0) do |n, file|
    n + file.scenarios.filter do |item| status(item.verdict) == "passed" end.size
  end
  skipped = files.reduce(0) do |n, file|
    n + file.scenarios.filter do |item| status(item.verdict) == "not_executed" end.size
  end
  file_errors = files.filter do |file| failed?(file.verdict) end.size
  severe = files.any? do |file|
    severe?(file.verdict) or file.scenarios.any? do |item| severe?(item.verdict) end
  end
  code = 1
  if scenarios > 0 and passed == scenarios and file_errors == 0
    code = 0
  elsif severe
    code = 2
  end
  return Totals(passed: passed, failed: scenarios - passed - skipped, not_executed: skipped, file_errors: file_errors,
                exit_code: code)
end

def failed?(verdict: Verdict) -> Bool
  return status(verdict) == "failed"
end

def severe?(verdict: Verdict) -> Bool
  case verdict
    Verdict.Fail(problem) -> return problem.code == "RUNTIME-BDD-INFRA" or problem.code == "RUNTIME-BDD-USAGE"
    Verdict.Pass -> return false
    Verdict.NotExecuted -> return false
  end
end

def status(verdict: Verdict) -> String
  case verdict
    Verdict.Pass -> return "passed"
    Verdict.Fail(_) -> return "failed"
    Verdict.NotExecuted -> return "not_executed"
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
    "scenarios": JSON.array(file.scenarios.map do |item| scenario_json(item) end),
    "error": verdict_json(file.verdict),
    "output": JSON.from(file.output),
  }
  return JSON.object(fields)
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
    "output": JSON.from(item.output),
  }
  return JSON.object(fields)
end

def step_json(step: StepResult) -> Json
  state = "passed"
  problem = JSON.null()
  case step.status
    StepStatus.Passed -> state = "passed"
    StepStatus.NotExecuted -> state = "not_executed"
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
  return JSON.object(fields)
end

def location_json(span: Span) -> Json
  fields: Map[String, Json] = {
    "file": JSON.from(span.file),
    "line": JSON.from(span.line),
    "column": JSON.from(span.column),
  }
  return JSON.object(fields)
end

def verdict_json(verdict: Verdict) -> Json
  case verdict
    Verdict.Fail(problem) -> return error_json(problem)
    Verdict.Pass -> return JSON.null()
    Verdict.NotExecuted -> return JSON.null()
  end
end

def error_json(problem: Error) -> Json
  if not JSON.null?(problem.original)
    return problem.original
  end
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
  return JSON.object(put_detail(put_detail(fields, "expected", problem.expected), "actual", problem.actual))
end

def put_detail(fields: Map[String, Json], key: String, detail: Detail) -> Map[String, Json]
  case detail
    Detail.Known(value) -> return fields.put(key, JSON.from(value))
    Detail.Unknown -> return fields
  end
end

def file_text(file: FileResult, ai: Bool) -> String
  head: List[String] = []
  case file.verdict
    Verdict.Fail(problem) -> head = [
      "FAIL #{file.path}#{separator(ai)}#{summary(problem, ai)}#{output_text(file.output, ai)}",
    ]
    Verdict.Pass -> head = []
    Verdict.NotExecuted -> head = []
  end
  label = file.feature
  if file.kind == "tests"
    label = file.path
  end
  lines = file.scenarios.map do |item| scenario_text(label, item, ai) end
  return head.concat(lines).join("\n")
end

def scenario_text(label: String, item: ScenarioResult, ai: Bool) -> String
  case item.verdict
    Verdict.Pass -> return "PASS #{label} / #{item.name}"
    Verdict.NotExecuted -> return "NOT RUN #{label} / #{item.name}"
    Verdict.Fail(problem) ->
      return "FAIL #{label} / #{item.name}#{separator(ai)}#{summary(problem, ai)}#{output_text(item.output, ai)}"
  end
end

def separator(ai: Bool) -> String
  if ai
    return " | "
  end
  return "\n"
end

def output_text(output: String, ai: Bool) -> String
  if output == ""
    return ""
  elsif ai
    return " | output #{output.inspect}"
  end
  indented = output.split("\n").map do |line| "  #{line}" end.join("\n")
  return "\n#{indented}"
end

def summary(problem: Error, ai: Bool) -> String
  span = problem.span
  head = "#{span.file}:#{span.line}:#{span.column} [#{problem.code}] #{problem.message}"
  return (
    head +
    detail_text("expected", problem.expected) +
    detail_text("actual", problem.actual) +
    stack_text(problem, ai)
  )
end

def stack_text(problem: Error, ai: Bool) -> String
  lines = stack_lines(problem.original)
  if lines.length == 0
    return ""
  elsif ai
    return " | stack #{lines.join("; ")}"
  end
  frames = lines.map do |line| "    #{line}" end.join("\n")
  return "\n  stack, innermost first:\n#{frames}"
end

def stack_lines(root: Json) -> List[String]
  found = JSON.get(root, "stack")
  if not found.ok?
    return []
  end
  none: List[Json] = []
  frames = JSON.list(found.unwrap!).unwrap_or(none)
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
  return lines
end

# The frames the VM shows before a cut stack's gap: AGC_STACK_HEAD in vm/port.h.
def stack_head() -> Int
  return 15
end

def not_shown(omitted: Int) -> String
  if omitted == 1
    return "... 1 frame not shown ..."
  end
  return "... #{omitted} frames not shown ..."
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
  return line
end

def place_text(place: Json) -> String
  file = text_at(place, "file").unwrap_or("?")
  line = int_at(place, "line").unwrap_or(0)
  column = int_at(place, "column").unwrap_or(0)
  return "#{file}:#{line}:#{column}"
end

def detail_text(label: String, detail: Detail) -> String
  case detail
    Detail.Known(value) -> return "; #{label} #{value}"
    Detail.Unknown -> return ""
  end
end

def text_at(root: Json, key: String) -> Result[String]
  return JSON.string(try JSON.get(root, key))
end

def int_at(root: Json, key: String) -> Result[Int]
  return JSON.int(try JSON.get(root, key))
end

def detail_at(root: Json, key: String) -> Detail
  found = JSON.get(root, key)
  if found.ok?
    value = JSON.string(found.unwrap!)
    if value.ok?
      return Detail.Known(value.unwrap!)
    end
  end
  return Detail.Unknown
end
