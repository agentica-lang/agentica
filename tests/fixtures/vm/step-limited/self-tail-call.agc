def f(n: Int) -> Int
  return f(n + 1)
end

def main() -> Void
  puts("start")
  puts(f(0))
  puts("done")
end
