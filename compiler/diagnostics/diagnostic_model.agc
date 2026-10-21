## A diagnostic as plain data: the shape of the JSON object that `--json` writes (diagnostic_json.agc) and that
## `std/analysis` returns. It holds no enum and no offset, so a client reads it without knowing the compiler's types.
## An absent note is the empty text, as in the JSON form, where the key is left out.

import Diag from "diagnostic"
import Problems from "problem"
import Source from "../syntax/source"

## A place in a text: line and column count from 1, in characters.
export struct Position
  line: Int
  column: Int
end

## A part of a text: `stop` is the first place after it.
export struct Region
  start: Position
  stop: Position
end

## A note on a second part of the text, such as "this is Int".
export struct Label
  range: Region
  text: String
end

## One problem of a program. `file` is the file as the answer names it; `key_path` is the place in agentica.toml or
## agentica.lock of a problem that has no source span (`range` is then the start of the file); `function` is the
## signature of the function being checked, and `callee` the one of the function or builtin called.
export struct Diagnostic
  code: String
  message: String
  file: String
  range: Region
  key_path: String
  help: String
  expected: String
  actual: String
  callee: String
  function: String
  labels: List[Label]
end

## The part of a text that a span covers, without its offsets.
export def range_of(span: Source.Span) -> Region
  return Region(
    start: Position(line: span.start.line, column: span.start.column),
    stop: Position(line: span.stop.line, column: span.stop.column),
  )
end

## The diagnostic of a problem.
export def of_problem(problem: Problems.Problem) -> Diagnostic
  help = ""
  case problem.help
    Diag.Help.Hint(text) -> help = text
    Diag.Help.NoHelp -> help = ""
  end
  return Diagnostic(
    code: problem.code,
    message: problem.message,
    file: problem.file,
    range: range_of(problem.span),
    key_path: problem.key_path,
    help: help,
    expected: problem.expected,
    actual: problem.actual,
    callee: problem.callee,
    function: problem.signature,
    labels: problem.labels.map do |label: Problems.Label| Label(range: range_of(label.span), text: label.text) end,
  )
end
