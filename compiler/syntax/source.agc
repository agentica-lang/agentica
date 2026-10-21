## Positions and spans: where a piece of source text sits, by offset, line and column.

## A place in a text: the offset of a character, its line and its column.
export struct Position
  offset: Int
  line: Int
  column: Int
end

## A piece of a text from its first character to the position after its last one.
export struct Span
  start: Position
  stop: Position
end

## Returns the position at `offset` on a line that starts at `line_start`; columns count from 1.
export def position(offset: Int, line: Int, line_start: Int) -> Position
  return Position(offset: offset, line: line, column: offset - line_start + 1)
end
