struct Point
  x: Int
  y: Int
end

struct Label
  text: String
  at: Point
  tags: List[String]
  weight: Float
  hidden: Bool
  note: Nil
end

struct Empty
end

def shift(p: Point, dx: Int) -> Point
  return Point(y: p.y, x: p.x + dx)
end

def first_tag(l: Label) -> String
  return l.tags[0]
end

def main() -> Void
  p = Point(y: 2, x: 1)
  puts(p)
  q = shift(p, 10)
  puts(q.x)
  puts(p.x)
  label = Label(note: nil, hidden: false, weight: -0.0, tags: ["a\"b", "λ"], at: q, text: "tab\there")
  puts(label)
  print(label)
  print("\n")
  IO.warn(label.at)
  puts("label #{label}, x #{label.at.x}")
  puts(label.to_s)
  puts(label.inspect)
  puts(label.text)
  puts(label.text.inspect)
  puts(first_tag(label))
  points = [p, q, Point(x: -3, y: 9223372036854775807)]
  puts(points)
  total = 0
  for pt in points
    if pt.y > 100
      next
    end
    total += pt.x + pt.y
  end
  puts(total)
  puts(points[2].y)
  puts(Empty())
  e = Empty()
  puts([e, e])
  i = 0
  walker = Point(x: 0, y: 0)
  while i < 3
    walker = shift(walker, i)
    i += 1
  end
  puts(walker)
end
