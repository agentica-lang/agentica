export struct Point
  x: Int
end

export enum Shape
  Dot(Point)
  Empty
end

export def show() -> Void
  puts("#{Point(x: 2)} #{Shape.Empty}")
end

