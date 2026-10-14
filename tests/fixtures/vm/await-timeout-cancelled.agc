struct Link
  results: Channel[Task[Result[Int]]]
  plains: Channel[Task[Int]]
  go: Channel[Int]
end

def linger_result(ms: Int) -> Result[Int]
  Task.sleep(ms)
  return ok(ms)
end

def linger(ms: Int) -> Int
  Task.sleep(ms)
  return ms
end

def parent(link: Link) -> Result[Int]
  link.results.send(Task.spawn(&linger_result, 60000), 5000)
  link.plains.send(Task.spawn(&linger, 60000), 5000)
  link.go.recv(5000)
  zero = 0
  return ok(1 / zero)
end

def watch(plain: Task[Int]) -> Result[Int]
  case Task.await(plain, 30000)
    Await.Done(n) -> return ok(n)
    Await.TimedOut -> return error("timed out")
  end
end

def main() -> Void
  link = Link(results: Channel.new(1), plains: Channel.new(1), go: Channel.new(1))
  owner = Task.spawn(&parent, link)
  results = link.results.recv(5000).unwrap!
  plain = link.plains.recv(5000).unwrap!
  IO.inspect(Task.await(results, 20))
  IO.inspect(Task.await(plain, 20))
  watcher = Task.spawn(&watch, plain)
  link.go.send(1, 1000)
  IO.inspect(Task.await(owner))
  IO.inspect(Task.await(watcher))
  IO.inspect(Task.await(results, 20))
  puts("the caller is unaffected")
  Task.await(plain, 20)
  puts("not reached")
end
