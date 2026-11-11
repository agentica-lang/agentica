## The text form of `agentica type-at` (docs/grammar/06b-builtins.md): the span of the expression, then its
## source text and its type, and a second line for the definition, if there is one. Each line starts with
## `file:line:column`, like `rg`. A builtin has no place: its lines are `builtin` and the signature of each form. The
## type of a name that only the link could answer (docs/grammar/06b-builtins.md) is written `?`.

import Model from "../analysis/model"
import DiagnosticModel from "../diagnostics/diagnostic_model"

## The lines of the answer for the expression in the file of its position.
export def text(found: Model.TypeAt) -> String
  type = found.type
  if type == ""
    type = "?"
  end

  head = "#{found.position.file}:#{range(found.range)} #{first_line(found.text)}: #{type}"
  return "#{head}\n#{builtin_lines(found.signatures)}" if found.definition.size == 0

  definition = found.definition[0]
  "#{head}\n#{definition.file}:#{start(definition.name_range)} #{definition.kind} #{definition.name}\n"
end

# `line:column-line:column`, the end exclusive.
def range(part: DiagnosticModel.Region) -> String = "#{start(part)}-#{part.stop.line}:#{part.stop.column}"

def start(part: DiagnosticModel.Region) -> String = "#{part.start.line}:#{part.start.column}"

# The text up to its first line break, with "..." when more follows: a block spans lines and the answer is one line.
def first_line(text: String) -> String
  lines = text.split("\n")
  return "#{lines[0]} ..." if lines.size > 1

  text
end

# One `builtin SIGNATURE` line for each form of the builtin; nothing for an answer that is not a builtin.
def builtin_lines(signatures: List[String]) -> String
  signatures.map do |line: String| "builtin #{line}\n" end.join("")
end
