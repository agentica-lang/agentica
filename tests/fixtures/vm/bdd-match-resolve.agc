import "std/test/report" as Report
import "std/bdd/match" as Match
import "std/bdd/gherkin" as Gherkin

def predefined() -> List[String]
  return [
    "the Agentica program {string}",
    "I send a line:",
    "I send the line {string}",
    "I send input:",
    "I close stdin",
    "I receive a line within {int} milliseconds:",
    "I receive the line {string} within {int} milliseconds",
    "I receive a JSON line within {int} milliseconds:",
    "stdin remains open",
    "the program exits with code {int} within {int} milliseconds",
    "stdout is:",
    "stderr is:",
  ]
end

def report(patterns: List[Match.Pattern], step: Gherkin.Step) -> Void
  case Match.resolve(patterns, step)
    Gherkin.Outcome.Done(hit) -> puts("#{step.text} -> #{patterns[hit.index].text} #{hit.captures.inspect}")
    Gherkin.Outcome.Failed(problem) ->
      span = problem.span
      puts("#{step.text} -> #{problem.code} #{span.file}:#{span.line}:#{span.column}-#{span.end_column}")
  end
end

def run(definitions: List[String], feature: String) -> Void
  where = Report.Span(file: "steps.agc", line: 1, column: 1, end_column: 1)
  case Match.compile(definitions, where)
    Gherkin.Outcome.Done(patterns) ->
      case Gherkin.parse("sample.feature", feature)
        Gherkin.Outcome.Done(parsed) ->
          for scenario in parsed.scenarios
            puts("Scenario: #{scenario.name}")
            for step in scenario.steps
              report(patterns, step)
            end
          end
        Gherkin.Outcome.Failed(problem) -> puts(problem.code)
      end
    Gherkin.Outcome.Failed(problem) -> puts(problem.code)
  end
end

def main() -> Void
  handlers = [
    "I remember {int}",
    "the remembered number is {int}",
    "scenario state is empty",
    "I submit a record:",
    "the table is valid:",
    "the message is {string}",
    "{int} is small",
  ]
  run(predefined().concat(handlers), "Feature: Custom\n\n  Scenario Outline: Remember <number>\n    Then scenario state is empty\n    When I remember <number>\n    Then the remembered number is <number>\n\n    Examples:\n      | number |\n      | 7      |\n      | -3     |\n\n  Scenario: Quoted capture\n    Then the message is \"hello \\\"world\\\"\"\n    And 3 is small\n\n  Scenario: Program\n    Given the Agentica program \"echo.agc\"\n    When I send the line 'hi'\n    Then I receive the line \"hi\" within 5000 milliseconds\n    And the program exits with code 0 within 1000 milliseconds\n    And stdout is:\n      \"\"\"\n      \"\"\"\n\n  Scenario: Unknown\n    Given missing definition\n    Then I remember seven\n    And I close stdin please\n")
  run(predefined().concat(["value is {int}", "value is 1", "value is {string}"]), "Feature: Patterns\nScenario: ambiguous\nThen value is 1\nThen value is 2\nThen value is '1'\nThen value is x\n")
end
