import "std/test/report" as Report
import "std/bdd/match" as Match
import "std/bdd/gherkin" as Gherkin

def report_feature() -> String
  lines = [
    "@report",
    "Feature: Report",
    "",
    "  Scenario: all pass",
    "    Given a number 1",
    "    Then it is 1",
    "",
    "  @wip",
    "  Scenario: wrong value",
    "    Given a number 2",
    "    Then it is 3",
    "    And it is 2",
    "",
    "  Scenario: undefined step",
    "    Given a number 2",
    "    When nobody knows \"this\"",
    "    Then it is 2",
    "",
    "  Scenario: ambiguous step",
    "    Then the value is \"x\"",
    "",
    "  Scenario Outline: row <n>",
    "    Given a number <n>",
    "    Then it is 5",
    "",
    "    Examples:",
    "      | n |",
    "      | 5 |",
    "      | 6 |",
  ]
  return lines.join("\n")
end

def assertion(step: Gherkin.Step, expected: String, actual: String) -> Report.Error
  return Report.Error(code: "RUNTIME-BDD-ASSERTION", message: "BDD assertion failed", span: step.span,
                      end_line: step.span.line, expected: Report.Detail.Known(expected), actual: Report.Detail.Known(actual),
                      original: JSON.null())
end

# Every step is resolved first: an undefined or ambiguous step fails alone and the others are not executed.
# Then "a number N" remembers N and "it is N" checks it; the first failure skips the rest.
def run_scenario(patterns: List[Match.Pattern], item: Gherkin.Scenario) -> Report.ScenarioResult
  resolved = item.steps.map do |step| Match.resolve(patterns, step) end
  verdict = Report.Verdict.Pass
  bad = first_failure(resolved)
  if bad >= 0
    case resolved[bad]
      Gherkin.Outcome.Failed(problem) ->
        verdict = Report.Verdict.Fail(Report.with_actual(Report.error_at(problem.code, problem.message, problem.span), item.steps[bad].text.inspect))
      Gherkin.Outcome.Done(_) -> verdict = Report.Verdict.Pass
    end
  end
  results: List[Report.StepResult] = []
  remembered = ""
  for i in 0...resolved.size
    step = item.steps[i]
    status = Report.StepStatus.Passed
    case verdict
      Report.Verdict.Fail(found) ->
        status = Report.StepStatus.NotExecuted
        if i == bad
          status = Report.StepStatus.Failed(found)
        end
      Report.Verdict.Pass ->
        case resolved[i]
          Gherkin.Outcome.Failed(_) -> status = Report.StepStatus.NotExecuted
          Gherkin.Outcome.Done(hit) ->
            if hit.index == 0
              remembered = hit.captures[0]
            elsif hit.captures[0] != remembered
              found = assertion(step, hit.captures[0].inspect, remembered.inspect)
              status = Report.StepStatus.Failed(found)
              verdict = Report.Verdict.Fail(found)
            end
        end
    end
    results = results.push(Report.StepResult(text: step.text, location: step.span, status: status))
  end
  return Report.ScenarioResult(name: item.name, tags: item.tags, location: item.span, example: item.example,
                               duration_ms: item.steps.size, steps: results, verdict: verdict)
end

def first_failure(resolved: List[Gherkin.Outcome[Match.Resolved]]) -> Int
  for i in 0...resolved.size
    case resolved[i]
      Gherkin.Outcome.Failed(_) -> return i
      Gherkin.Outcome.Done(_) -> next
    end
  end
  return -1
end

def run_file(patterns: List[Match.Pattern], path: String, text: String) -> Report.FileResult
  case Gherkin.parse(path, text)
    Gherkin.Outcome.Failed(problem) -> return Report.file_error(path, Report.error_at(problem.code, problem.message, problem.span))
    Gherkin.Outcome.Done(feature) ->
      scenarios = feature.scenarios.map do |item| run_scenario(patterns, item) end
      return Report.FileResult(path: path, feature: feature.name, scenarios: scenarios, verdict: Report.Verdict.Pass)
  end
end

def compiled(definitions: List[String]) -> List[Match.Pattern]
  where = Report.Span(file: "steps.agc", line: 1, column: 1, end_column: 1)
  case Match.compile(definitions, where)
    Gherkin.Outcome.Done(patterns) -> return patterns
    Gherkin.Outcome.Failed(_) -> return []
  end
end

def main() -> Void
  patterns = compiled(["a number {int}", "it is {int}", "the value is {string}", "the value is \"x\""])
  files = [
    run_file(patterns, "/specs/a.feature", report_feature()),
    run_file(patterns, "/specs/b.feature", "Scenario: first\n  Given a number 1\n"),
    run_file(patterns, "/specs/c.feature", "Feature: Empty\n"),
  ]
  puts(Report.json(files))
  puts(Report.text(files, false))
  puts(Report.text(files, true))
  puts("exit #{Report.exit_code(files)}")
end
