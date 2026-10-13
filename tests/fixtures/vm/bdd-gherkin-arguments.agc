import "std/bdd/gherkin" as Gherkin

def check(text: String) -> Void
  case Gherkin.parse("sample.feature", text)
    Gherkin.Outcome.Done(feature) -> puts("parsed #{feature.name}")
    Gherkin.Outcome.Failed(problem) ->
      span = problem.span
      puts("#{problem.code} #{span.file}:#{span.line}:#{span.column}-#{span.end_column}")
  end
end

def main() -> Void
  check("Feature: f\nScenario: s\nThen rows:\n| a | b |\n| c |\n")
  check("Feature: f\nScenario: s\nThen rows:\n| a | ignored\\|\n")
  check("Feature: f\nScenario Outline: s\nThen fine\nExamples:\n| n |\n| 7 | ignored\\|\n")
  check("Feature: f\nScenario: s\n|a|")
  check("Feature: f\nScenario: s\n\"\"\"\n\"\"\"")
  check("Feature: f\nScenario Outline: s\nThen fine\nExamples:\n|\n|\n")
  check("Feature: f\nScenario Outline: <missing>\nThen fine\nExamples:\n| x |\n| 1 |\n")
  check("Feature: f\nScenario Outline: s\nThen fine\n")
  check("Feature: f\nScenario: s\nWhen input:\n\"\"\"\nunfinished\n")
  check("Feature: f\nScenario: s\nGiven x\n| a \\q |\n")
  check("Feature: f\nScenario: s\nGiven x\n| a |\n| b\n")
  check("Feature: f\nScenario: s\nGiven x\n\"\"\"bad!\n\"\"\"\n")
  check("Feature: f\nScenario: s\nGiven x\n| a |\n\"\"\"\n\"\"\"\n")
  check("Feature: f\nScenario: s\nGiven x\nExamples:\n| a |\n| 1 |\n")
  check("Feature: f\nScenario Outline: s\nGiven x\nExamples:\n| a | a |\n| 1 | 2 |\n")
  check("Feature: f\nScenario Outline: s\nGiven x\nExamples:\n| a |\n")
  check("Feature: f\nScenario Outline: s\nGiven <a>\nExamples:\n| a |\n| 1 |\nExamples:\n| b |\n| 2 |\n")
end
