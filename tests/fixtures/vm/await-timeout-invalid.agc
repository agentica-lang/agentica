def one(n: Int) -> Int
  return n
end

def zero(task: Task[Int]) -> Result[Int]
  case Task.await(task, 0)
    Await.Done(n) -> return ok(n)
    Await.TimedOut -> return error("timed out")
  end
end

def negative(task: Task[Int]) -> Result[Int]
  case Task.await(task, -1)
    Await.Done(n) -> return ok(n)
    Await.TimedOut -> return error("timed out")
  end
end

def main() -> Void
  task = Task.spawn(&one, 1)
  puts(Task.await(task))
  IO.inspect(Task.await(Task.spawn(&zero, task)))
  IO.inspect(Task.await(Task.spawn(&negative, task)))
  Task.await(task, 0)
  puts("not reached")
end
