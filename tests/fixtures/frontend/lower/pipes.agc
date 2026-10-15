def inc(n: Int) -> Int
  return n + 1
end

def add(a: Int, b: Int) -> Int
  return a + b
end

def shout(s: String) -> String
  return s + "!"
end

def main() -> Void
  puts(1 |> inc() |> add(5) |> inc())
  puts("x" |> shout())
end
