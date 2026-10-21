## The text form of `agentica type-at` (docs/future/39-semantic-cli.md, 39.2): the span of the expression, then its
## source text and its type, and a second line for the definition, if there is one. Each line starts with
## `file:line:column`, like `rg`.

import Ast from "../syntax/ast"
import Definitions from "definitions"
import Source from "../syntax/source"
import TypeAt from "type_at"

## The lines of the answer for the expression in `file`; `definition_file` is the name of the file of the definition.
export def text(file: String, answered: TypeAt.Answer, definition_file: String) -> String
  span = answered.span
  head = "#{file}:#{range(span)} #{first_line(answered.text)}: #{answered.type}"
  case answered.definition
    Ast.Optional.Absent -> return "#{head}\n"
    Ast.Optional.Present(found) ->
      return "#{head}\n#{definition_file}:#{span_start(found.name_span)} #{found.kind} #{found.name}\n"
  end
end

# `line:column-line:column`, the end exclusive.
def range(span: Source.Span) -> String
  return "#{span_start(span)}-#{span.stop.line}:#{span.stop.column}"
end

def span_start(span: Source.Span) -> String
  return "#{span.start.line}:#{span.start.column}"
end

# The text up to its first line break, with "..." when more follows: a block spans lines and the answer is one line.
def first_line(text: String) -> String
  lines = text.split("\n")
  if lines.size > 1
    return "#{lines[0]} ..."
  end
  return text
end
