def work(n: Int) -> Int
  return n + 1
end

def risky(n: Int) -> Result[Int]
  if n > 0
    return ok(n)
  end
  return error("zero")
end

def show(outcome: Await[Int]) -> Void
  case outcome
    Await.Done(n) -> puts(n)
    Await.TimedOut -> puts("late")
  end
end

def main() -> Void
  t = Task.spawn(&work, 1)
  puts(Task.await(t))
  show(Task.await(Task.spawn(&work, 2), 1000))
  r = Task.spawn(&risky, 0)
  puts(Task.await(r).ok?)
  ch: Channel[Int] = Channel.new(2)
  ch.send(1, 100)
  puts(ch.recv(100).unwrap!)
  Task.sleep(0)
  puts(Task.pending_count())
end
