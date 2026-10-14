def follow(inbox: Channel[Task[Result[Int]]]) -> Result[Int]
  target = inbox.recv(5000).unwrap!
  case Task.await(target, 30)
    Await.Done(r) -> return r
    Await.TimedOut -> return error("timed out")
  end
end

def follow_plain(inbox: Channel[Task[Result[Int]]]) -> Result[Int]
  target = inbox.recv(5000).unwrap!
  case Task.await(target)
    ok(n) -> return ok(n)
    error(e) -> return error("plain saw: #{e}")
  end
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
  a = Task.spawn(&follow_plain, left)
  b = Task.spawn(&follow, right)
  left.send(b, 5000)
  right.send(a, 5000)
  report("a", Task.await(a))
  report("b", Task.await(b))

  first: Channel[Task[Result[Int]]] = Channel.new(1)
  second: Channel[Task[Result[Int]]] = Channel.new(1)
  c = Task.spawn(&follow, first)
  d = Task.spawn(&follow, second)
  first.send(d, 5000)
  second.send(c, 5000)
  report("c", Task.await(c))
  report("d", Task.await(d))
end
