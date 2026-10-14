def pick(xs: List[Int], i: Int) -> Int
  return xs[i] + 1
end

def load(i: Int) -> Int
  return pick([1, 2, 3], i) * 2
end

def main() -> Void
  puts("start")
  puts(load(5))
end
