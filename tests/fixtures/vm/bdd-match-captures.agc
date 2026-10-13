import "std/bdd/match" as Match
import "std/bdd/gherkin" as Gherkin

def show(pattern: String, text: String) -> Void
  where = Gherkin.Span(file: "steps.agc", line: 1, column: 1, end_column: 1)
  case Match.compile([pattern], where)
    Gherkin.Outcome.Done(patterns) ->
      found = Match.captures(patterns[0], text)
      if found.ok?
        puts("#{pattern} | #{text} -> #{found.unwrap!.inspect}")
      else
        puts("#{pattern} | #{text} -> no match")
      end
    Gherkin.Outcome.Failed(problem) -> puts("#{pattern} -> #{problem.code}")
  end
end

def main() -> Void
  show("I close stdin", "I close stdin")
  show("I close stdin", "I close stdin now")
  show("I close stdin", "close stdin")
  show("a.b", "aXb")
  show("a(b)+", "a(b)+")
  show("I remember {int}", "I remember 7")
  show("I remember {int}", "I remember -3")
  show("I remember {int}", "I remember 007")
  show("I remember {int}", "I remember -")
  show("I remember {int}", "I remember 1.5")
  show("I remember {int}", "I remember ")
  show("{int} is small", "3 is small")
  show("{int} is small", "9 is small")
  show("{int}{int}", "123")
  show("{int}{int}", "-12-3")
  show("{int}{int}", "1")
  show("{int}1", "1231")
  show("{int}-{int}", "1-2-3")
  show("{int}-{int}", "1--2")
  show("{int}2{int}", "12223")
  show("value {int}{string}", "value 12'x'")
  show("the message is {string}", "the message is \"hello \\\"world\\\"\"")
  show("the message is {string}", "the message is 'it\\'s'")
  show("the message is {string}", "the message is \"it's\"")
  show("the message is {string}", "the message is 'say \"hi\"'")
  show("the message is {string}", "the message is \"a\\\\b\\n\"")
  show("the message is {string}", "the message is \"\"")
  show("the message is {string}", "the message is \"open")
  show("the message is {string}", "the message is \"a\" \"b\"")
  show("the message is {string}", "the message is plain")
  show("the message is {string}", "the message is \"tail\\\"")
  show("{string} and {string}", "\"a\" and 'b'")
  show("{string}{string}", "'a''b'")
  show("café {string} {int}", "café \"é\" -0")
  show("I receive the line {string} within {int} milliseconds", "I receive the line \"ok\" within 500 milliseconds")
end
