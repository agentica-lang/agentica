struct Pair
  mine: Channel[Int]
  theirs: Channel[Int]
end

def relay(pair: Pair) -> Result[Int]
  case pair.mine.recv(20)
    ok(n) ->
      pair.theirs.send(n, 20)
      return ok(n)
    error(e) -> return error("recv: #{e}")
  end
end

def fill(pair: Pair) -> Result[Int]
  pair.mine.send(1, 20)
  case pair.mine.send(2, 20)
    ok(_) -> return ok(0)
    error(e) -> return error("send: #{e}")
  end
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def main() -> Void
  a: Channel[Int] = Channel.new(1)
  b: Channel[Int] = Channel.new(1)
  c: Channel[Int] = Channel.new(1)
  first = Task.spawn(&relay, Pair(mine: a, theirs: b))
  second = Task.spawn(&relay, Pair(mine: b, theirs: a))
  third = Task.spawn(&fill, Pair(mine: c, theirs: c))
  report("first", Task.await(first))
  report("second", Task.await(second))
  report("third", Task.await(third))
  puts(Task.pending_count())
end
