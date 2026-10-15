struct Point
  x: Int
  y: Int
end

def add(a: Int, b: Int) -> Int
  return a + b
end

def main() -> Void
  p = Point(x: 1, y: 2)
  xs = [1, 2, 3]
  puts("n=#{xs.size} #{p.x + add(1, 2)}")
  puts(xs.map do |x| x * 2 end.to_s)
end
