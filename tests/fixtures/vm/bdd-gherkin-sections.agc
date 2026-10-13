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
  check("")
  check("Feature: empty\n")
  check("Feature: f\nScenario: empty\n")
  check("Feature: f\nScenario: s\nAnd missing\n")
  check("Feature: f\nRule: rule\n")
  check("# language: es\nFeature: f\n")
  check("Feature: f\nScenario: s\nThen: typo\n")
  check("Scenario: s\nGiven x\n")
  check("Feature: f\nFeature: g\n")
  check("Feature: f\nScenario:\n")
  check("Feature: f\nScenario: s\nGiven x\nBackground:\n")
  check("Feature: f\nBackground:\nScenario: s\nGiven x\n")
  check("Feature: f\nGiven x\n")
  check("Feature: f\nScenario: s\nGiven x\nmore text\n")
  check("@ok bad\nFeature: f\n")
  check("Feature: f\nScenario: s\n@late\nGiven x\n")
  check("Feature: f\nScenario: s\nGiven x\n@left\n")
end
