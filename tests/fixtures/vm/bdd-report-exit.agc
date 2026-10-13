import "std/bdd/report" as Report
import "std/bdd/gherkin" as Gherkin

def at(line: Int) -> Gherkin.Span
  return Gherkin.Span(file: "/specs/x.feature", line: line, column: 3, end_column: 12)
end

def problem(code: String) -> Report.Error
  return Report.Error(code: code, message: "went wrong", span: at(2), end_line: 2, expected: Report.Detail.Unknown,
                      actual: Report.Detail.Unknown)
end

def scenario(name: String, verdict: Report.Verdict) -> Report.ScenarioResult
  steps = [Report.StepResult(text: "a step", location: at(3), status: Report.StepStatus.Passed)]
  return Report.ScenarioResult(name: name, tags: [], location: at(2), example: Gherkin.Example.NoExample, duration_ms: 0,
                               steps: steps, verdict: verdict)
end

def feature(scenarios: List[Report.ScenarioResult]) -> Report.FileResult
  return Report.FileResult(path: "/specs/x.feature", feature: "X", scenarios: scenarios, verdict: Report.Verdict.Pass)
end

def show(label: String, files: List[Report.FileResult]) -> Void
  puts("#{label}: exit #{Report.exit_code(files)}")
  puts(Report.text(files, true))
end

def main() -> Void
  passing = scenario("passes", Report.Verdict.Pass)
  show("no files", [])
  show("one pass", [feature([passing])])
  show("no scenarios", [feature([])])
  show("one failure", [feature([passing, scenario("fails", Report.Verdict.Fail(problem("RUNTIME-BDD-TIMEOUT")))])])
  show("infra file", [Report.file_error("/specs/steps.agc", problem("RUNTIME-BDD-INFRA")), feature([passing])])
  show("infra scenario", [feature([scenario("crashes", Report.Verdict.Fail(problem("RUNTIME-BDD-INFRA")))])])
  odd = "a\"b\\c\nd\t" + String.from_code(233) + String.from_code(1) + String.from_code(127)
  multi = Report.Error(code: "RUNTIME-DIVISION-BY-ZERO", message: odd, span: at(5), end_line: 7,
                       expected: Report.Detail.Known(odd), actual: Report.Detail.Known(""))
  files = [feature([scenario(odd, Report.Verdict.Fail(multi))])]
  show("escapes", files)
  puts(Report.text(files, false))
  puts(Report.json(files))
end
