def boom(n: Int) -> Int
  xs = [1, 2, 3]
  return xs[n]
end

def main() -> Void
  t = Task.spawn(&boom, 5)
  puts("waiting")
  Task.sleep(10)
  puts("main goes on")
end
