def scale() -> Int
  return 1
end

def collatz_length(start: Int) -> Int
  n = start
  steps = 0
  while n != 1
    if n % 2 == 0
      n /= 2
    else
      n = 3 * n + 1
    end
    steps += 1
  end
  return steps
end

def main() -> Void
  limit = 2500 * scale()
  total = 0
  longest = 0
  n = 1
  while n <= limit
    steps = collatz_length(n)
    total += steps
    if steps > longest
      longest = steps
    end
    n += 1
  end
  puts("collatz #{limit}: total #{total}, longest #{longest}")
end
