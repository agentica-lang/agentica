struct Point
  x: Int
  y: Int
end

def main() -> Void
  p = Point(x: 1, y: 2)
  puts(p == Point(x: 1, y: 2))
  puts([1] != [2])
  puts(1 == 2)
end
