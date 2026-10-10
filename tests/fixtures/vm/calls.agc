def fib(n: Int) -> Int
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end

def first_even_above(n: Int) -> Int
  while true
    n += 1
    if n % 2 == 0
      return n
    end
  end
  return -1
end

def report(label: Int, value: Int) -> Void
  puts(label)
  puts(value)
end

def nothing() -> Void
end

def main() -> Void
  report(1, fib(7))
  report(2, first_even_above(9))
  nothing()
  puts("end")
  return
  puts("unreachable")
end
