## How the checker reports a failure: a diagnostic with the extra notes of src/diagnostic.rkt (expected, actual,
## callee, signature, labels) and the file it is in. A Result error is a String, so the failure travels packed (pack)
## and `try` stops at the first one, as in the parser; unpack reads it back.

import Diag from "diagnostic"
import Source from "source"

## A note on a second span, such as "this is Int".
export struct Label
  span: Source.Span
  text: String
end

## The first problem the checker found. The notes are "" when the diagnostic has none (src/ uses #f). signature is the
## signature of the function being checked; callee the signature of the function or builtin called.
export struct Problem
  file: String
  code: String
  message: String
  span: Source.Span
  help: Diag.Help
  expected: String
  actual: String
  callee: String
  signature: String
  labels: List[Label]
end

## A problem with no notes.
export def problem(
  file: String,
  signature: String,
  code: String,
  message: String,
  span: Source.Span,
  help: Diag.Help,
) -> Problem
  return Problem(
    file: file,
    code: code,
    message: message,
    span: span,
    help: help,
    expected: "",
    actual: "",
    callee: "",
    signature: signature,
    labels: [],
  )
end

## The problem written as one String.
export def pack(found: Problem) -> String
  fields = [
    found.file,
    found.code,
    found.message,
    span_text(found.span),
    help_flag(found.help),
    help_text(found.help),
    found.expected,
    found.actual,
    found.callee,
    found.signature,
    found.labels.size.to_s,
  ]
  for label in found.labels
    fields = fields.concat([span_text(label.span), label.text])
  end
  parts = fields.map do |field: String| "#{field.length}\n#{field}" end
  return parts.join("")
end

## Reads back the problem that pack wrote.
export def unpack(text: String) -> Problem
  fields: List[String] = []
  at = 0
  while at < text.length
    newline = at + text.slice(at, text.length - at).index_of("\n").unwrap!
    size = text.slice(at, newline - at).to_i!
    fields = fields.push(text.slice(newline + 1, size))
    at = newline + 1 + size
  end
  labels: List[Label] = []
  index = 11
  while index < fields.size
    labels = labels.push(Label(span: read_span(fields[index]), text: fields[index + 1]))
    index += 2
  end
  help = Diag.Help.NoHelp
  if fields[4] == "1"
    help = Diag.Help.Hint(fields[5])
  end
  return Problem(
    file: fields[0],
    code: fields[1],
    message: fields[2],
    span: read_span(fields[3]),
    help: help,
    expected: fields[6],
    actual: fields[7],
    callee: fields[8],
    signature: fields[9],
    labels: labels,
  )
end

def span_text(span: Source.Span) -> String
  numbers = [span.start.offset, span.start.line, span.start.column, span.stop.offset, span.stop.line, span.stop.column]
  return numbers.map do |number: Int| number.to_s end.join(",")
end

def read_span(text: String) -> Source.Span
  numbers = text.split(",").map do |part: String| part.to_i! end
  start = Source.Position(offset: numbers[0], line: numbers[1], column: numbers[2])
  stop = Source.Position(offset: numbers[3], line: numbers[4], column: numbers[5])
  return Source.Span(start: start, stop: stop)
end

def help_flag(help: Diag.Help) -> String
  case help
    Diag.Help.Hint(text) -> return "1"
    Diag.Help.NoHelp -> return "0"
  end
end

def help_text(help: Diag.Help) -> String
  case help
    Diag.Help.Hint(text) -> return text
    Diag.Help.NoHelp -> return ""
  end
end
