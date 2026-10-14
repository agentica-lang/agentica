def leaf(n: Int) -> Int
  return 10 / n
end

def step(n: Int) -> Int
  return leaf(n - n)
end

def ping(n: Int) -> Int
  return pong(n) + 1
end

def pong(n: Int) -> Int
  if n == 0
    return step(n) + 1
  end
  return ping(n - 1) + 1
end

def walk(n: Int) -> Int
  if n == 0
    return ping(100) + 1
  end
  return walk(n - 1) + 1
end

def worker(n: Int) -> Int
  return walk(n) + 1
end

def main() -> Void
  task = Task.spawn(&worker, 50)
  puts(Task.await(task))
end
