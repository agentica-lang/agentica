struct Point
  x: Int
  y: Int
end

enum Shape
  Dot(Point)
  Line(Point, Point)
end

def double(n: Int) -> Int
  return n * 2
end

def origin() -> Point
  return Point(x: 0, y: 0)
end
