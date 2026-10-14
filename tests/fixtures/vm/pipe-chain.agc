def parse(text: String) -> Result[Int]
  return text.trim.to_int
end

def validate(n: Int) -> Result[Int]
  if n < 0
    return error("negative")
  end
  return ok(n)
end

def add(a: Int, b: Int) -> Int
  return a + b
end

def scale(n: Int, factor: Int) -> Int
  return n * factor
end

def twice(xs: List[Int], f: Fn[Int, Int]) -> List[Int]
  return xs.map do |x: Int|
    f.call(f.call(x))
  end
end

def inc(n: Int) -> Int
  return n + 1
end

def load(text: String) -> Result[Int]
  return text |> try parse() |> validate()
end

def total(text: String) -> Result[Int]
  n = text |> try parse() |> try validate()
  return ok(n |> add(1) |> scale(2))
end

def main() -> Void
  puts(1 |> add(2) |> scale(3))
  puts(1 + 2 |> scale(4) == 12)
  puts(load(" 7 ").inspect)
  puts(load("-3").inspect)
  puts(load("x").ok?)
  puts(total("5").inspect)
  puts(total("-5").inspect)
  chained = (" 20 "
    |> try_or_zero()
    |> add(1)
    |> scale(2))
  puts(chained)
  puts([1, 2, 3] |> twice(&inc))
  puts([1, 2, 3] |> twice() do |x: Int|
    x * 2
  end)
  puts(-2 |> add(5))
  puts("#{4 |> scale(5)} items")
end

def try_or_zero(text: String) -> Int
  return (text |> parse()).unwrap_or(0)
end
