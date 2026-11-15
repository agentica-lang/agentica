# A value assigned to an existing local, or a call result placed in the last register taken, is written straight into
# its register: each case reads that register before it is written.
enum Shape
  Dot
  Box(Int, Int)
end

struct Pair
  left: Int
  right: Int
end

def add(a: Int, b: Int) -> Int = a + b

def twice(a: Int) -> Int = a * 2

def area(shape: Shape) -> Int
  case shape
    Shape.Dot -> 0
    Shape.Box(w, h) -> w * h
  end
end

def main() -> Void
  x = 3
  y = 4
  x = add(x, y)
  puts(x)
  x = x + twice(x)
  puts(x)
  x = add(twice(x), add(x, twice(y)))
  puts(x)
  x = x - x / 2
  puts(x)
  s = "a"
  s = s + s + "b"
  puts(s)
  p = Pair(left: 1, right: 2)
  p = Pair(left: p.right, right: p.left)
  puts("#{p.left} #{p.right}")
  p = p.with(left: p.right + p.left)
  puts("#{p.left} #{p.right}")
  n = p.left
  n = p.right
  puts(n)
  xs = [1, 2, 3]
  xs = xs.push(xs.size)
  xs = [xs[3], xs[0]]
  puts(xs)
  flag = x > 1
  flag = !flag
  puts(flag)
  shape = Shape.Box(2, 5)
  x = case shape
    Shape.Dot -> x
    Shape.Box(w, _) -> x + w
  end

  puts(x)
  x = case x > 100
    true -> x
    _ -> add(x, area(shape))
  end

  puts(x)
  f = ->(v: Int) { v + x }
  x = f.call(x)
  puts(x)
  total = 0
  for v in [1, 2, 3]
    total = total * 10 + v
  end
  puts(total)
  last = twice(add(twice(1), total))
  puts(last)
end
