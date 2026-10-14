def follow(inbox: Channel[Task[Result[Int]]]) -> Result[Int]
  target = inbox.recv(5000).unwrap!
  case Task.await(target, 5000)
    Await.Done(r) -> return r
    Await.TimedOut -> return error("timed out")
  end
end

def follow_plain(inbox: Channel[Task[Result[Int]]]) -> Result[Int]
  target = inbox.recv(5000).unwrap!
  return Task.await(target)
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def main() -> Void
  mine: Channel[Task[Result[Int]]] = Channel.new(1)
  one = Task.spawn(&follow, mine)
  mine.send(one, 5000)
  report("self", Task.await(one))

  left: Channel[Task[Result[Int]]] = Channel.new(1)
  right: Channel[Task[Result[Int]]] = Channel.new(1)
  a = Task.spawn(&follow, left)
  b = Task.spawn(&follow_plain, right)
  left.send(b, 5000)
  right.send(a, 5000)
  report("a", Task.await(a))
  report("b", Task.await(b))
end
