struct Point
  x: Int
  y: Float
end

def main() -> Void
  n = IO.inspect(41) + 1
  puts(n)
  s = IO.inspect("tab\tquote\"λ")
  puts(s)
  xs = IO.inspect([Point(x: 1, y: 2.5)])
  puts(xs[0].x)
  m = IO.inspect({"a": ok(1), "b": error("no")})
  puts(m["b"])
  IO.inspect(nil)
  IO.inspect(true)
end
