## How a stage reports a failure: a diagnostic with the extra notes (expected, actual,
## callee, signature, labels) and the file it is in. A Result error is a String, so the failure travels packed (pack)
## and `try` stops at the first one, as in the parser; unpack reads it back.

import Diag from "../diagnostics/diagnostic"
import Source from "../syntax/source"

## A note on a second span, such as "this is Int".
struct Label
  span: Source.Span
  text: String
end

## The first problem the checker found. The notes are "" when the diagnostic has none. signature is the
## signature of the function being checked; callee the signature of the function or builtin called. key_path is the
## place of a problem in agentica.toml or agentica.lock, which have no source span for it; "" for any other problem.
struct Problem
  file: String
  key_path: String
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

## Whether the problem points at the text of its file: false for a problem at a key of agentica.toml or agentica.lock,
## and for one about such a file as a whole (no line 0 span, see link_failure.agc, fail_file). The text forms print the
## file name alone for those.
def at_source?(found: Problem) -> Bool = found.key_path == "" and found.span.start.line > 0

## A problem with no notes.
def problem(
  file: String,
  signature: String,
  code: String,
  message: String,
  span: Source.Span,
  help: Diag.Help,
) -> Problem
  Problem(
    file: file,
    key_path: "",
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
def pack(found: Problem) -> String
  fields = [
    found.file,
    found.key_path,
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
  parts.join("")
end

## Reads back the problem that pack wrote.
def unpack(text: String) -> Problem
  fields: List[String] = []
  at = 0
  while at < text.length
    newline = at + text.slice(at, text.length - at).index_of("\n").unwrap!
    size = text.slice(at, newline - at).to_i!
    fields = fields.push(text.slice(newline + 1, size))
    at = newline + 1 + size
  end

  labels: List[Label] = []
  index = 12
  while index < fields.size
    labels = labels.push(Label(span: read_span(fields[index]), text: fields[index + 1]))
    index += 2
  end

  help = Diag.Help.NoHelp
  if fields[5] == "1"
    help = Diag.Help.Hint(fields[6])
  end

  Problem(
    file: fields[0],
    key_path: fields[1],
    code: fields[2],
    message: fields[3],
    span: read_span(fields[4]),
    help: help,
    expected: fields[7],
    actual: fields[8],
    callee: fields[9],
    signature: fields[10],
    labels: labels,
  )
end

private

def span_text(span: Source.Span) -> String
  numbers = [span.start.offset, span.start.line, span.start.column, span.stop.offset, span.stop.line, span.stop.column]
  texts = numbers.map do |number: Int| number.to_s end
  texts.join(",")
end

def read_span(text: String) -> Source.Span
  numbers = text.split(",").map do |part: String| part.to_i! end
  start = Source.Position(offset: numbers[0], line: numbers[1], column: numbers[2])
  stop = Source.Position(offset: numbers[3], line: numbers[4], column: numbers[5])
  Source.Span(start: start, stop: stop)
end

def help_flag(help: Diag.Help) -> String
  case help
    Diag.Help.Hint(_) -> "1"
    Diag.Help.NoHelp -> "0"
  end
end

def help_text(help: Diag.Help) -> String
  case help
    Diag.Help.Hint(text) -> text
    Diag.Help.NoHelp -> ""
  end
end
