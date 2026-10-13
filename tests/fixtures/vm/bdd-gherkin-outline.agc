import "std/bdd/gherkin" as Gherkin

def at(span: Gherkin.Span) -> String
  return "#{span.file}:#{span.line}:#{span.column}-#{span.end_column}"
end

def show(text: String) -> Void
  case Gherkin.parse("sample.feature", text)
    Gherkin.Outcome.Done(feature) ->
      puts("feature #{feature.name.inspect} #{feature.tags} #{at(feature.span)}")
      for scenario in feature.scenarios
        example = "none"
        case scenario.example
          Gherkin.Example.Row(row) -> example = at(row)
          Gherkin.Example.NoExample -> example = "none"
        end
        puts("scenario #{scenario.name.inspect} #{scenario.tags} #{at(scenario.span)} example #{example}")
        for step in scenario.steps
          puts("  #{step.kind} #{step.text.inspect} #{at(step.span)}")
          case step.argument
            Gherkin.Argument.DocString(doc) -> puts("    doc #{doc.inspect}")
            Gherkin.Argument.DataTable(rows) -> puts("    table #{rows}")
            Gherkin.Argument.NoArgument -> puts("    no argument")
          end
        end
      end
    Gherkin.Outcome.Failed(problem) -> puts("#{problem.code} #{at(problem.span)}")
  end
end

def main() -> Void
  show(
    "@stream\nFeature: streaming\n  Description\n\nBackground: setup\n  Given ready\n" +
    "@case\nScenario Outline: value <n>\n  When input:\n    \"\"\"json\n    {\"n\":<n>}\n    \"\"\"\n" +
    "  Then rows:\n    | key | value |\n    | a\\|b | <n> |\n    | pipe\\| | slash\\\\|\n  And finished\n" +
    "  @examples\n  Examples:\n    | n |\n    | 1 |\n    | 2 |\n"
  )
  show(
    "# language: en\r\nFeature: plain\r\n\r\nBackground:\r\n  Given ready\r\n" +
    "Example: first\r\n  When run\r\n    \"\"\"\r\n      kept\r\n    out\r\n\r\n    \"\"\"\r\n  But not <this>\r\n" +
    "@one @two\r\nScenario: second\r\n  Then done\r\n    | a\\nb | \\\\ |\r\n"
  )
end
