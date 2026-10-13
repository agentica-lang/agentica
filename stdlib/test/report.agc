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
  NotExecuted
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
  output: String
end

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

export def file_error(path: String, kind: String, problem: Error) -> FileResult
  return file_failure(path, kind, problem, "")
end

export def file_failure(path: String, kind: String, problem: Error, output: String) -> FileResult
  return FileResult(path: path, feature: "", kind: kind, scenarios: [], verdict: Verdict.Fail(problem), output: output)
end

# 0 when at least one scenario ran and nothing failed, 2 when any file or scenario error is RUNTIME-BDD-INFRA or
# RUNTIME-BDD-USAGE, else 1.
export def exit_code(files: List[FileResult]) -> Int
  return totals(files).exit_code
end

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

# The plain text (ai false) or the --ai text, without a final newline.
export def text(files: List[FileResult], ai: Bool, seed: Int) -> String
  sums = totals(files)
  chunks = files.map do |file| file_text(file, ai) end
  last = "#{sums.passed} passed, #{sums.failed} failed, #{sums.not_executed} not executed, #{sums.file_errors} file errors"
  if sums.exit_code != 0
    last = "#{last}, seed #{seed}"
  end
  return chunks.filter do |chunk| chunk != "" end.push(last).join("\n")
end

def totals(files: List[FileResult]) -> Totals
  scenarios = files.reduce(0) do |n, file| n + file.scenarios.size end
  passed = files.reduce(0) do |n, file| n + file.scenarios.filter do |item| status(item.verdict) == "passed" end.size end
  skipped = files.reduce(0) do |n, file| n + file.scenarios.filter do |item| status(item.verdict) == "not_executed" end.size end
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
  fields: Map[String, Json] = {"file": JSON.from(span.file), "line": JSON.from(span.line), "column": JSON.from(span.column)}
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
    Verdict.Fail(problem) -> head = ["FAIL #{file.path}#{separator(ai)}#{summary(problem)}#{output_text(file.output, ai)}"]
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
    Verdict.Fail(problem) -> return "FAIL #{label} / #{item.name}#{separator(ai)}#{summary(problem)}#{output_text(item.output, ai)}"
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
  return "\n" + output.split("\n").map do |line| "  #{line}" end.join("\n")
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
