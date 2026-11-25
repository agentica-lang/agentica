enum Color
  Red
  Green
end

enum Shape
  Dot
  Circle(Int)
end

def main() -> Void
  puts(Color.values.size)
  puts(Color.parse("Red").ok?)
  puts(Shape.Circle(1).name)
end
