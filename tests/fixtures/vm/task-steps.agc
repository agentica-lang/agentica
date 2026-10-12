def work(n: Int) -> Int
  i = 0
  while i < n
    i = i + 1
  end
  return i
end

def nested(n: Int) -> Int
  return Task.await(Task.spawn(&work, n)) + Task.await(Task.spawn(&work, n))
end

def main() -> Void
  IO.inspect(Task.await(Task.spawn(&nested, 40)))
  IO.inspect(Task.await(Task.spawn(&work, 30)))
end
