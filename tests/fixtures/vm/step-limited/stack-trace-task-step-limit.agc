def spin(n: Int) -> Int
  while true
    n += 1
  end
  return n
end

def worker(n: Int) -> Int
  return spin(n) + 1
end

def main() -> Void
  task = Task.spawn(&worker, 0)
  puts(Task.await(task))
end
