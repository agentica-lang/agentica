struct Span
  name: String
  r: Range
end

enum Shape
  Line(Range)
  Dot
end

def show(n: Int) -> Void
  print(n)
end

def find(r: Range, want: Int) -> Int
  for i in r
    if i == want
      return i * 10
    end
  end
  return -1
end

def checked(r: Range) -> Result[Int]
  total = 0
  for i in r
    v: Result[Int] = ok(i)
    if i == 3
      v = error("three")
    end
    total += try v
  end
  return ok(total)
end

def main() -> Void
  s = Span(name: "a", r: 1...3)
  m = {"x": 4..6}
  IO.inspect([s, Span(name: "b", r: m["x"])])
  IO.inspect([Shape.Line(s.r), Shape.Dot])
  case Shape.Line(m["x"])
    Shape.Line(r) -> puts(r.size)
    Shape.Dot -> puts("dot")
  end
  puts([find(1..9, 4), find(1...4, 4)])
  puts([checked(1..2), checked(1..5)])
  puts([(1..2) != (1..2), (1..2) != (1...2), s.r != m["x"]])
  for i in 0...3 do
    print(i)
  end
  for i in 1..3
    if i == 2
      next
    end
    print(i)
  end
  for i in 3..1
    print(i)
  end
  for i in 2...2
  end
  r = 9223372036854775806..9223372036854775807
  for i in r
    r = 1..1
    puts(" #{i}")
  end
  e = (-9223372036854775807)...(-9223372036854775808)
  for i in e
    print(i)
  end
  for i in (-9223372036854775808)...(-9223372036854775807)
    puts(i)
    break
  end
  3.times do |i|
    print(i)
  end
  0.times(&show)
  9223372036854775806.upto(9223372036854775807) do |i|
    puts(i)
  end
  (-9223372036854775807).downto(-9223372036854775808, &show)
  3.upto(1, &show)
  (1...4).each(&show)
  puts("")
  IO.inspect([1..5, 1...5, (-3)..(-1), (-9223372036854775808)...(-9223372036854775808)])
  puts([(1...5).size, (5..1).size, (0..9223372036854775806).size])
  puts([(1...5).last, (1..5).first, (2...2).first, e.last])
  puts([(1..5) == (1..5), (1..5) != (1...5), r.include?(1), (1...5).include?(5)])
  puts("#{1..2} #{(1...2).inspect} #{(1..2).to_s}")
  puts((0..6).to_a.filter do |n|
    n % 3 == 0
  end)
  puts(Range.to_a(5...5))
end
