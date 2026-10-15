struct Point
  x: Int
  y: Int
end

struct Line
  from: Point
  to: Point
  label: String
  tags: List[String]
end

struct Empty
end

def shift(p: Point) -> Point
  return p.with(y: p.y + 1, x: p.y)
end

def main() -> Void
  a = Point(y: 2, x: 1)
  line = Line(from: a, to: shift(a), label: "l", tags: ["t"])
  moved = line.with(to: line.to.with(x: 9), label: line.label + "!")
  e = Empty()
  puts("#{moved.to.x} #{moved.label} #{line.from} #{e}")
  puts(shift(Point(x: 0, y: 0)).x)
  same = a.with(x: a.x)
  puts(same.inspect)
end
