## The token of the lexer: its kind, lexeme, value and span.

import Source from "source"

## A `##` block: its text and what follows it.
struct DocBlock
  text: String
  next: String
end

## One line of an `<<~EAG` body as written, without its line break, and where it starts (column 1).
struct EagLine
  text: String
  start: Source.Position
end

## The body of an `<<~EAG` heredoc: its lines as written and the number of spaces the squiggly form removes from each
## (the fewest leading spaces of the lines that have text). The parser expands it (eag.agc).
struct EagBody
  lines: List[EagLine]
  indent: Int
end

## The value a token carries besides its lexeme.
enum Value
  NoValue
  Text(String)
  Whole(Int)
  Huge(String)
  Real(Float)
  Doc(DocBlock)
  Eag(EagBody)
end

## A plain comment, which makes no token: its text from the `#` to the end of its line (the line break is not part of
## it), whether only blanks come before it on its line (`own_line`; false for a comment after code), and its span. A
## `##` line that starts a line is a doc, a DOC token, not a comment; a `##` after code is a comment.
struct Comment
  text: String
  own_line: Bool
  span: Source.Span
end

## A token: its kind, its lexeme, its value and its span.
struct Token
  kind: String
  lexeme: String
  value: Value
  span: Source.Span
end

private
