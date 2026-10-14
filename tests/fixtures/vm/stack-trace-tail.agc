def leaf(n: Int) -> Int
  return 10 / n
end

def step(n: Int) -> Int
  return leaf(n - n)
end

def run(n: Int) -> Int
  return step(n) + 1
end

def main() -> Void
  puts(run(3))
end
