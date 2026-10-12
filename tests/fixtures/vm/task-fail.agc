def boom(n: Int) -> Int
  Task.sleep(1)
  return 10 / n
end

def main() -> Void
  puts("start")
  value = Task.await(Task.spawn(&boom, 0))
  puts("never #{value}")
end
