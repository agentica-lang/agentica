export struct Point
  x: Int
  y: Int
end

export enum Shape
  Dot(Point)
  Line(Point, Point)
end

export def double(n: Int) -> Int
  return n * 2
end

export def origin() -> Point
  return Point(x: 0, y: 0)
end
