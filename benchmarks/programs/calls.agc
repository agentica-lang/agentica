def scale() -> Int
  return 1
end

def fib(n: Int) -> Int
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end

def add(a: Int, b: Int) -> Int
  return a + b
end

def mix(total: Int, value: Int) -> Int
  return add(total * 31, value) % 1000000007
end

def main() -> Void
  rounds = 2 * scale()
  total = 0
  round = 0
  while round < rounds
    total = mix(total, fib(20 + round % 2))
    i = 0
    while i < 20000
      total = mix(total, i)
      i += 1
    end
    round += 1
  end
  puts("calls #{rounds}: checksum #{total}")
end
