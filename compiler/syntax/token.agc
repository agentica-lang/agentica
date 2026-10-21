## The token of the lexer: its kind, lexeme, value and span.

import Source from "source"

## A `##` block: its text and what follows it.
export struct DocBlock
  text: String
  next: String
end

## The value a token carries besides its lexeme.
export enum Value
  NoValue
  Text(String)
  Whole(Int)
  Huge(String)
  Real(Float)
  Doc(DocBlock)
end

## A token: its kind, its lexeme, its value and its span.
export struct Token
  kind: String
  lexeme: String
  value: Value
  span: Source.Span
end
