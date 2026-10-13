def chatter(n: Int) -> Int
  i = 0
  while i < 50
    puts("#{n} #{i}")
    Task.sleep(0)
    i += 1
  end
  return n
end

def parent(n: Int) -> Result[Int]
  child = Task.spawn(&middle, n + 1)
  Task.sleep(0)
  Task.sleep(0)
  return ok(10 / n)
end

def middle(n: Int) -> Int
  grandchild = Task.spawn(&chatter, n + 1)
  return Task.await(Task.spawn(&chatter, n))
end

def main() -> Void
  task = Task.spawn(&parent, 0)
  puts(Task.await(task).ok?)
  Task.sleep(0)
  Task.sleep(0)
  puts(Task.pending_count())
end
