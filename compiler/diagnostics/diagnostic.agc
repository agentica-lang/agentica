## The diagnostic that every stage gives in place of its data when it stops.

import Source from "../syntax/source"

## One problem found by a stage: a stable code, a message, the span it points at and an optional help.
struct Diagnostic
  code: String
  message: String
  span: Source.Span
  help: Help
end

## The help of a diagnostic: none, or a hint.
enum Help
  NoHelp
  Hint(String)
end

## What a stage gives: its data, or the first diagnostic.
enum Outcome[T]
  Done(T)
  Failed(Diagnostic)
end

## Returns a diagnostic with the code, message, span and help.
def fail(code: String, message: String, span: Source.Span, help: Help) -> Diagnostic
  Diagnostic(code: code, message: message, span: span, help: help)
end

private
