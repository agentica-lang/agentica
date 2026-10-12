struct Item
  value: Int
end

def double(n: Int) -> Int
  Task.sleep(0)
  return n * 2
end

def nested(n: Int) -> Item
  value = Task.await(Task.spawn(&double, n))
  return Item(value: value)
end

def failure(n: Int) -> Result[Int]
  return error("normal result")
end

def tried(n: Int) -> Result[Int]
  v = try failure(n)
  return ok(v)
end

def nothing(n: Int) -> Nil
  return nil
end

def shout(n: Int) -> Void
  puts("task #{n} ran")
end

def start(n: Int, f: Fn[Int, Int]) -> Task[Int]
  return Task.spawn(f, n)
end

def main() -> Void
  a: Task[Item] = Task.spawn(&nested, 21)
  IO.inspect(Task.await(a))
  IO.inspect(Task.await(a))
  IO.inspect(Task.await(Task.spawn(&nested, 7)))
  IO.inspect(a)
  IO.inspect([a, a])
  IO.inspect(Task.await(Task.spawn(&failure, 0)))
  IO.inspect(Task.await(Task.spawn(&tried, 0)))
  IO.inspect(Task.await(Task.spawn(&nothing, 0)))
  Task.await(Task.spawn(&shout, 3))
  offset = 100
  IO.inspect(Task.await(start(5) do |n|
    Task.sleep(1)
    n + offset
  end))
  Task.sleep(0)
  Task.sleep(2)
  puts("done")
end
