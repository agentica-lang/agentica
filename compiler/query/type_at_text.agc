## The text form of `agentica type-at` (docs/future/39-semantic-cli.md, 39.2): the span of the expression, then its
## source text and its type, and a second line for the definition, if there is one. Each line starts with
## `file:line:column`, like `rg`. A builtin has no place: its lines are `builtin` and the signature of each form. The
## type of a name that only the link could answer (docs/future/39-semantic-cli.md, 39.6) is written `?`.

import Model from "../analysis/model"
import DiagnosticModel from "../diagnostics/diagnostic_model"

## The lines of the answer for the expression in the file of its position.
export def text(found: Model.TypeAt) -> String
  type = found.type
  if type == ""
    type = "?"
  end

  head = "#{found.position.file}:#{range(found.range)} #{first_line(found.text)}: #{type}"
  if found.definition.size == 0
    return "#{head}\n#{builtin_lines(found.signatures)}"
  end

  definition = found.definition[0]
  return "#{head}\n#{definition.file}:#{start(definition.name_range)} #{definition.kind} #{definition.name}\n"
end

# `line:column-line:column`, the end exclusive.
def range(part: DiagnosticModel.Region) -> String
  return "#{start(part)}-#{part.stop.line}:#{part.stop.column}"
end

def start(part: DiagnosticModel.Region) -> String
  return "#{part.start.line}:#{part.start.column}"
end

# The text up to its first line break, with "..." when more follows: a block spans lines and the answer is one line.
def first_line(text: String) -> String
  lines = text.split("\n")
  if lines.size > 1
    return "#{lines[0]} ..."
  end

  return text
end

# One `builtin SIGNATURE` line for each form of the builtin; nothing for an answer that is not a builtin.
def builtin_lines(signatures: List[String]) -> String
  return signatures.map do |line: String| "builtin #{line}\n" end.join("")
end
