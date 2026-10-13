def idle(n: Int) -> Int
  Task.sleep(0)
  return n
end

def wait_for(task: Task[Int]) -> Int
  return Task.await(task)
end

def count(n: Int) -> Int
  return Task.pending_count() + n
end

def nap(ms: Int) -> Int
  Task.sleep(ms)
  return ms
end

def main() -> Void
  puts(Task.pending_count())
  first = Task.spawn(&idle, 1)
  second = Task.spawn(&wait_for, first)
  puts(Task.pending_count())
  Task.sleep(0)
  puts(Task.pending_count())
  puts(Task.await(second))
  puts(Task.pending_count())
  puts(Task.await(Task.spawn(&count, 0)))
  unawaited = Task.spawn(&idle, 2)
  Task.sleep(0)
  Task.sleep(0)
  puts(Task.pending_count())
  sleeper = Task.spawn(&nap, 60000)
  Task.sleep(0)
  puts(Task.pending_count())
end
