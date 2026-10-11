import "lib/callbacks.agc" as Cb

struct Handler
  name: String
  run: Fn[Int, Int]
end

def double(x: Int) -> Int
  return x * 2
end

def keep(f: Fn[Int, Int]) -> Fn[Int, Int]
  return f
end

def pick(n: Int) -> Fn[Int, Int]
  if n > 0
    return keep() do |x: Int|
      x + n
    end
  end
  return &double
end

enum Opt
  Some(Int)
  None
end

def run(f: Fn[Int, Void], x: Int) -> Void
  f.call(x)
end

def quiet(f: Fn[Int, Void]) -> Fn[Int, Void]
  return f
end

def first_big(xs: List[Int], limit: Int) -> List[Int]
  found = xs.map do |x|
    if x > limit
      return x * 100
    end
    x
  end
  return found
end

def base_len(text: String) -> Int
  if text == "ab"
    return 2
  end
  return 1
end

def parse(text: String) -> Result[Int]
  if text == "bad"
    return error("bad input")
  end
  return ok(base_len(text))
end

def checked(f: Fn[String, Result[Int]]) -> Fn[String, Result[Int]]
  return f
end

def lengths(words: List[String]) -> List[Result[Int]]
  f = checked() do |w: String|
    n = try parse(w)
    ok(n + 1)
  end
  return words.map(f)
end

def main() -> Void
  base = 10
  label = "n"
  adders = [1, 2, 3].map do |i|
    keep() do |x: Int|
      x + i + base
    end
  end
  base = 1000
  for f in adders
    puts(f.call(5))
  end
  late = keep() do |x: Int| x * base end
  puts(late.call(2))
  shown = [4, 5].map do |x: Int|
    inner = [x, x + 1].map do |y| "#{label}#{y + base}" end
    inner[1]
  end
  puts(shown)
  for k in [1, 2]
    g = keep() do |x: Int|
      h = keep() do |y: Int| y * k + x end
      h.call(x)
    end
    puts(g.call(10))
  end
  table = {"double": &double, "triple": &Cb.triple, "plus": pick(7)}
  puts(table["double"].call(4))
  puts(table["triple"].call(4))
  puts(table["plus"].call(4))
  puts(pick(0).call(21))
  hs = [Handler(name: "neg", run: keep() do |x: Int| 0 - x end), Handler(name: "sq", run: keep() do |x: Int| x * x end)]
  for h in hs
    puts("#{h.name} #{h.run.call(6)}")
  end
  puts(Cb.twice(&double, 3))
  puts(Cb.twice(&Cb.triple, 3))
  puts(Cb.twice(keep() do |x: Int| x - base end, 3))
  puts(first_big([1, 2, 3], 1))
  puts(first_big([1, 2, 3], 9))
  puts(lengths(["ab", "abc"]))
  puts(lengths(["ab", "bad", "c"]))
  [1, 2].each do |x|
  end
  g = quiet() do |v: Int|
    if v > 1
      return
    end
    puts("small #{v} #{label}")
  end
  run(g, 1)
  run(g, 2)
  g.call(0)
  i = 0
  while i < 3
    o = Opt.Some(i)
    if i == 2
      o = Opt.None
    end
    case o
      Opt.Some(v) ->
        h = quiet() do |w: Int| puts("case #{v} #{w}") end
        h.call(i * 100)
      Opt.None -> puts("none")
    end
    i = i + 1
  end
  noop = [1, 2].map do |x|
    puts("visit #{x}")
    x
  end
  puts(noop)
end
