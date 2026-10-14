def inner(n: Int) -> Int
  return 10 / n
end

def worker(n: Int) -> Int
  Task.sleep(1)
  return inner(n) + 1
end

def main() -> Void
  puts("start")
  task = Task.spawn(&worker, 0)
  puts(Task.await(task))
end
