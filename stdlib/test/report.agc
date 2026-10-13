export struct Span
  file: String
  line: Int
  column: Int
  end_column: Int
end

export enum Example
  NoExample
  Row(Span)
end

export enum Detail
  Unknown
  Known(String)
end

export struct Error
  code: String
  message: String
  span: Span
  end_line: Int
  expected: Detail
  actual: Detail
  original: Json
end

export enum Verdict
  Pass
  Fail(Error)
end

export enum StepStatus
  Passed
  Failed(Error)
  NotExecuted
end

export struct StepResult
  text: String
  location: Span
  status: StepStatus
end

export struct ScenarioResult
  name: String
  tags: List[String]
  location: Span
  example: Example
  duration_ms: Int
  steps: List[StepResult]
  verdict: Verdict
end

export struct FileResult
  path: String
  feature: String
  scenarios: List[ScenarioResult]
  verdict: Verdict
end

struct Totals
  passed: Int
  failed: Int
  file_errors: Int
  exit_code: Int
end

export def error_at(code: String, message: String, span: Span) -> Error
  return Error(code: code, message: message, span: span, end_line: span.line, expected: Detail.Unknown,
               actual: Detail.Unknown, original: JSON.null())
end

# Reads a diagnostic as `--json` writes it and keeps the whole object, so the report writes every key unchanged
# (help, function, callee, labels, ...).
export def from_json(text: String) -> Result[Error]
  root = try JSON.parse(text)
  range = try JSON.get(root, "range")
  start = try JSON.get(range, "start")
  stop = try JSON.get(range, "end")
  span = Span(file: try text_at(root, "file"), line: try int_at(start, "line"), column: try int_at(start, "column"),
                      end_column: try int_at(stop, "column"))
  return ok(Error(code: try text_at(root, "code"), message: try text_at(root, "message"), span: span,
                  end_line: try int_at(stop, "line"), expected: detail_at(root, "expected"), actual: detail_at(root, "actual"),
                  original: root))
end

# For an error built from fields. An error from `from_json` is returned unchanged, since its kept object is what the
# report writes, so the text and the JSON cannot disagree.
export def with_actual(problem: Error, actual: String) -> Error
  if not JSON.null?(problem.original)
    return problem
  end
  return Error(code: problem.code, message: problem.message, span: problem.span, end_line: problem.end_line,
               expected: problem.expected, actual: Detail.Known(actual), original: problem.original)
end

export def file_error(path: String, problem: Error) -> FileResult
  return FileResult(path: path, feature: "", scenarios: [], verdict: Verdict.Fail(problem))
end

# 0 when at least one scenario ran and nothing failed, 2 when any file or scenario error is RUNTIME-BDD-INFRA or
# RUNTIME-BDD-USAGE, else 1.
export def exit_code(files: List[FileResult]) -> Int
  return totals(files).exit_code
end

export def json(files: List[FileResult]) -> Json
  sums = totals(files)
  fields: Map[String, Json] = {
    "ok": JSON.from(sums.exit_code == 0),
    "passed": JSON.from(sums.passed),
    "failed": JSON.from(sums.failed),
    "not_executed": JSON.from(0),
    "file_errors": JSON.from(sums.file_errors),
    "exit_code": JSON.from(sums.exit_code),
    "files": JSON.array(files.map do |file| file_json(file) end),
  }
  return JSON.object(fields)
end

# The plain text (ai false) or the --ai text, without a final newline.
export def text(files: List[FileResult], ai: Bool) -> String
  sums = totals(files)
  separator = "\n"
  if ai
    separator = " | "
  end
  chunks = files.map do |file| file_text(file, separator) end
  last = "#{sums.passed} passed, #{sums.failed} failed, 0 not executed, #{sums.file_errors} file errors"
  return chunks.filter do |chunk| chunk != "" end.push(last).join("\n")
end

def totals(files: List[FileResult]) -> Totals
  scenarios = files.reduce(0) do |n, file| n + file.scenarios.size end
  passed = files.reduce(0) do |n, file| n + file.scenarios.filter do |item| not failed?(item.verdict) end.size end
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
  return Totals(passed: passed, failed: scenarios - passed, file_errors: file_errors, exit_code: code)
end

def failed?(verdict: Verdict) -> Bool
  case verdict
    Verdict.Pass -> return false
    Verdict.Fail(_) -> return true
  end
end

def severe?(verdict: Verdict) -> Bool
  case verdict
    Verdict.Pass -> return false
    Verdict.Fail(problem) -> return problem.code == "RUNTIME-BDD-INFRA" or problem.code == "RUNTIME-BDD-USAGE"
  end
end

def status(verdict: Verdict) -> String
  if failed?(verdict)
    return "failed"
  end
  return "passed"
end

def file_json(file: FileResult) -> Json
  state = status(file.verdict)
  if file.scenarios.any? do |item| failed?(item.verdict) end
    state = "failed"
  end
  fields: Map[String, Json] = {
    "path": JSON.from(file.path),
    "feature": JSON.from(file.feature),
    "status": JSON.from(state),
    "scenarios": JSON.array(file.scenarios.map do |item| scenario_json(item) end),
    "error": verdict_json(file.verdict),
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
  fields: Map[String, Json] = {"file": JSON.from(span.file), "line": JSON.from(span.line), "column": JSON.from(span.column)}
  return JSON.object(fields)
end

def verdict_json(verdict: Verdict) -> Json
  case verdict
    Verdict.Pass -> return JSON.null()
    Verdict.Fail(problem) -> return error_json(problem)
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

def file_text(file: FileResult, separator: String) -> String
  head: List[String] = []
  case file.verdict
    Verdict.Fail(problem) -> head = ["FAIL #{file.path}#{separator}#{summary(problem)}"]
    Verdict.Pass -> head = []
  end
  lines = file.scenarios.map do |item| scenario_text(file.feature, item, separator) end
  return head.concat(lines).join("\n")
end

def scenario_text(feature: String, item: ScenarioResult, separator: String) -> String
  case item.verdict
    Verdict.Pass -> return "PASS #{feature} / #{item.name}"
    Verdict.Fail(problem) -> return "FAIL #{feature} / #{item.name}#{separator}#{summary(problem)}"
  end
end

def summary(problem: Error) -> String
  span = problem.span
  head = "#{span.file}:#{span.line}:#{span.column} [#{problem.code}] #{problem.message}"
  return head + detail_text("expected", problem.expected) + detail_text("actual", problem.actual)
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
