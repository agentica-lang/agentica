# Values written straight into their register: an assignment to an existing local whose last instruction reads that
# local as an operand (`aliases` runs it in a hot loop, so the JIT compiles the same instructions), and call results
# placed in the last register taken, including nested calls and calls whose arguments read the local being assigned.
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

def aliases(rounds: Int) -> String
  idx = [1, 2, 0]
  names = [2, 0, 1]
  i = 0
  k = 0
  n = 0
  f = 1.5
  b = false
  s = ""
  x = true
  y = true
  round = 0
  while round < rounds
    i = idx[i]
    k = names[k]
    x = (y and x) == x
    n = n + round + 3
    n = n / 7
    n = n % 5
    n = -n
    b = n <= n
    f = f * f
    f = f / f + f
    if f > 1000.0
      f = 1.5
    end
    s = "a"
    s = s + s
    round += 1
  end
  "#{i} #{k} #{x} #{n} #{f} #{b} #{s}"
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
  puts(aliases(3))
  puts(aliases(20_000))
end
