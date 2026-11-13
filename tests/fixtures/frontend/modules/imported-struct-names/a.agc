struct Point
  x: Int
end

enum Shape
  Dot(Point)
  Empty
end

def show() -> Void
  puts("#{Point(x: 2)} #{Shape.Empty}")
end
