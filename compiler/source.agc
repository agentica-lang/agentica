export struct Position
  offset: Int
  line: Int
  column: Int
end

export struct Span
  start: Position
  stop: Position
end

export def position(offset: Int, line: Int, line_start: Int) -> Position
  return Position(offset: offset, line: line, column: offset - line_start + 1)
end
