enum Color
  Red
  Green(Int)
end

enum Maybe[T]
  Some(T)
  None
end

struct Point
  x: Int
  y: Int
end

def lex(text: String) -> Int
  return text.size
end

def make(x: Int) -> Point
  return Point(x: x, y: 0)
end

def as(x: Int) -> Int
  return x
end

def from(x: Int) -> Int
  return x
end

private

def hidden() -> Int
  return 2
end
