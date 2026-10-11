export struct Point
  x: Int
  y: Int
end

export enum Shape[T]
  Dot(Point)
  Tagged(T, Point)
  Nothing
end

export def origin() -> Point
  return Point(x: 0, y: 0)
end

export def tag(label: String, at: Point) -> Shape[String]
  return Shape.Tagged(label, at)
end

export def describe(at: Point) -> String
  return "at #{at}"
end
