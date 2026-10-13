import "std/bdd/match" as Match
import "std/bdd/gherkin" as Gherkin

def check(definitions: List[String]) -> Void
  where = Gherkin.Span(file: "steps.agc", line: 1, column: 1, end_column: 12)
  case Match.compile(definitions, where)
    Gherkin.Outcome.Done(patterns) -> puts("compiled #{patterns.size}")
    Gherkin.Outcome.Failed(problem) ->
      span = problem.span
      puts("#{problem.code} #{span.file}:#{span.line}:#{span.column}-#{span.end_column}")
  end
end

def main() -> Void
  check([])
  check(["x", "y {int}", "z {string}"])
  check(["x {float}"])
  check(["x {}"])
  check(["x {String}"])
  check(["x { int }"])
  check(["x {"])
  check(["x }"])
  check(["x {int"])
  check(["{{int}}"])
  check(["{stri{int}ng}"])
  check(["} {float}"])
  check(["x", "x"])
  check(["I close stdin", "x", "I close stdin"])
  check(["x", "x", "{bad}"])
  check(["{bad}", "x", "x"])
  check(["x {int}", "x {string}", "x {int}"])
end
