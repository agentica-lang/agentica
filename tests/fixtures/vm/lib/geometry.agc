struct Point
  x: Int
  y: Int
end

enum Shape[T]
  Dot(Point)
  Tagged(T, Point)
  Nothing
end

def origin() -> Point
  return Point(x: 0, y: 0)
end

def tag(label: String, at: Point) -> Shape[String]
  return Shape.Tagged(label, at)
end

def describe(at: Point) -> String
  return "at #{at}"
end
