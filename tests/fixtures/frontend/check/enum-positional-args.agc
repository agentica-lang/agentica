enum Shape
  Circle(Float)
  Square(Float)
end

def main() -> Void
  s = Shape.Circle(radius: 1.0)
  puts(s)
end
