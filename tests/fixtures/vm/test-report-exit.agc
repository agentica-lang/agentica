import Report from "std/test/report"

def at(line: Int) -> Report.Span
  return Report.Span(file: "/specs/x.feature", line: line, column: 3, end_column: 12)
end

def problem(code: String) -> Report.Error
  return Report.Error(code: code, message: "went wrong", span: at(2), end_line: 2, expected: Report.Detail.Unknown,
                      actual: Report.Detail.Unknown, original: JSON.null())
end

def scenario(name: String, verdict: Report.Verdict) -> Report.ScenarioResult
  steps = [Report.StepResult(text: "a step", location: at(3), status: Report.StepStatus.Passed)]
  return Report.ScenarioResult(name: name, tags: [], location: at(2), example: Report.Example.NoExample, duration_ms: 0,
                               steps: steps, verdict: verdict, output: "")
end

def unit(name: String, verdict: Report.Verdict, output: String) -> Report.ScenarioResult
  where = Report.Span(file: "/test/x_test.agc", line: 4, column: 5, end_column: 5)
  return Report.ScenarioResult(name: name, tags: [], location: where, example: Report.Example.NoExample, duration_ms: 0,
                               steps: [], verdict: verdict, output: output)
end

def feature(scenarios: List[Report.ScenarioResult]) -> Report.FileResult
  return Report.FileResult(path: "/specs/x.feature", feature: "X", kind: "feature", scenarios: scenarios, verdict: Report.Verdict.Pass, output: "")
end

# As `agentica --json check` writes it, with a help line added.
def front_end() -> String
  label = "{\"range\":{\"end\":{\"column\":8,\"line\":2},\"start\":{\"column\":7,\"line\":2}},\"text\":\"this is Int\"}"
  return ("{\"actual\":\"String\",\"code\":\"CHECK-TYPE-MISMATCH\",\"expected\":\"Int\",\"file\":\"/specs/steps.agc\"," +
    "\"function\":\"main() -> Void\",\"help\":\"convert it with String.to_int!(...)\",\"labels\":[#{label}]," +
    "\"message\":\"operator expects two values of the same type\",\"range\":{\"end\":{\"column\":10,\"line\":2}," +
    "\"start\":{\"column\":9,\"line\":2}}}")
end

def show(label: String, files: List[Report.FileResult]) -> Void
  puts("#{label}: exit #{Report.exit_code(files)}")
  puts(Report.text(files, true, 7))
end

def main() -> Void
  passing = scenario("passes", Report.Verdict.Pass)
  show("no files", [])
  show("one pass", [feature([passing])])
  show("no scenarios", [feature([])])
  show("one failure", [feature([passing, scenario("fails", Report.Verdict.Fail(problem("RUNTIME-BDD-TIMEOUT")))])])
  show("infra file", [Report.file_error("/specs/steps.agc", "steps", problem("RUNTIME-BDD-INFRA")), feature([passing])])
  show("usage", [Report.file_error("<arguments>", "", problem("RUNTIME-BDD-USAGE"))])
  show("infra scenario", [feature([scenario("crashes", Report.Verdict.Fail(problem("RUNTIME-BDD-INFRA")))])])
  checked = Report.from_json(front_end())
  if checked.ok?
    files = [Report.file_error("/specs/steps.agc", "steps", checked.unwrap!), feature([passing])]
    show("front end", files)
    puts(Report.json(files, 7))
    puts(Report.text([Report.file_error("/specs/steps.agc", "steps", Report.with_actual(checked.unwrap!, "ignored"))], true, 7))
  end
  puts(Report.from_json("{\"code\":\"X\"}").message)
  odd = "a\"b\\c\nd\t" + String.from_code(233) + String.from_code(1) + String.from_code(127)
  multi = Report.Error(code: "RUNTIME-DIVISION-BY-ZERO", message: odd, span: at(5), end_line: 7,
                       expected: Report.Detail.Known(odd.inspect), actual: Report.Detail.Known("".inspect), original: JSON.null())
  files = [feature([scenario(odd, Report.Verdict.Fail(multi))])]
  show("escapes", files)
  puts(Report.text(files, false, 7))
  puts(Report.json(files, 7))
  failed = Report.Error(code: "RUNTIME-TEST-ASSERTION", message: "values are not equal", span: at(9), end_line: 9,
                        expected: Report.Detail.Known("2"), actual: Report.Detail.Known("3"), original: JSON.null())
  units = [unit("adds", Report.Verdict.Pass, ""), unit("fails", Report.Verdict.Fail(failed), "line one\nline two"),
           unit("later", Report.Verdict.NotExecuted, "")]
  tests = [Report.FileResult(path: "/test/x_test.agc", feature: "", kind: "tests", scenarios: units, verdict: Report.Verdict.Pass, output: "")]
  show("tests", tests)
  puts(Report.text(tests, false, 7))
  puts(Report.json(tests, 7))
  show("tests pass", [Report.FileResult(path: "/test/x_test.agc", feature: "", kind: "tests", scenarios: [units[0]],
                                        verdict: Report.Verdict.Pass, output: "")])
end
