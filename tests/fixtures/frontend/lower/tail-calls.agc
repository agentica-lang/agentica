def count(n: Int, acc: Int) -> Int
  if n == 0
    return acc
  end
  return count(n - 1, acc + 1)
end

def even(n: Int) -> Bool
  if n == 0
    return true
  end
  return odd(n - 1)
end

def odd(n: Int) -> Bool
  if n == 0
    return false
  end
  return even(n - 1)
end

def nothing() -> Void
  return
end

def forward() -> Void
  return nothing()
end

def main() -> Void
  puts(count(1000, 0))
  puts(even(10))
  forward()
  puts(1 + count(3, 0))
end
