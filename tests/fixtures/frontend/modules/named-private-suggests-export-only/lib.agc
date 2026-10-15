export enum Color
  Red
  Green(Int)
end

export enum Maybe[T]
  Some(T)
  None
end

export struct Point
  x: Int
  y: Int
end

export def lex(text: String) -> Int
  return text.size
end

export def make(x: Int) -> Point
  return Point(x: x, y: 0)
end

def hidden() -> Int
  return 2
end

def maker() -> Int
  return 1
end
