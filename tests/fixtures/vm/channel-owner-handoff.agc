def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def quick(ch: Channel[Int]) -> Result[Int]
  try ch.send(1, 1000)
  return ok(1)
end

def idle(ch: Channel[Int]) -> Result[Int]
  Task.sleep(50)
  return ok(0)
end

def shut(ch: Channel[Int]) -> Result[Int]
  ch.close
  return ok(0)
end

def pass_on(ch: Channel[Int]) -> Result[Int]
  Task.spawn_owning(&idle, ch)
  return ok(1)
end

def give_twice(ch: Channel[Int]) -> Result[Int]
  Task.spawn_owning(&idle, ch)
  Task.spawn_owning(&idle, ch)
  return ok(2)
end

def give_closed(ch: Channel[Int]) -> Result[Int]
  ch.close
  Task.spawn_owning(&idle, ch)
  return ok(3)
end

def main() -> Void
  plain: Channel[Int] = Channel.new(4)
  report("plain spawn", Task.await(Task.spawn(&quick, plain)))
  puts(plain.closed?)
  plain.send(2, 100)
  puts(plain.recv(100).unwrap!)
  puts(plain.recv(100).unwrap!)
  case plain.recv(100)
    ok(n) -> puts(n)
    error(e) -> puts("recv: #{e}, closed? #{plain.closed?}")
  end
  plain.close

  owned: Channel[Int] = Channel.new(4)
  keeper = Task.spawn_owning(&idle, owned)
  report("closed by a non-owner", Task.await(Task.spawn(&shut, owned)))
  puts(owned.closed?)
  report("owner after close", Task.await(keeper))
  owned.close
  puts(owned.closed?)

  chained: Channel[Int] = Channel.new(4)
  report("owner hands on", Task.await(Task.spawn_owning(&pass_on, chained)))
  puts(chained.closed?)
  Task.sleep(100)
  puts(chained.closed?)

  held: Channel[Int] = Channel.new(4)
  holder = Task.spawn_owning(&idle, held)
  report("not the owner", Task.await(Task.spawn(&pass_on, held)))
  puts(held.closed?)
  report("holder", Task.await(holder))
  puts(held.closed?)

  twice: Channel[Int] = Channel.new(4)
  report("twice", Task.await(Task.spawn(&give_twice, twice)))
  report("closed", Task.await(Task.spawn(&give_closed, Channel.new(1))))
  puts(Task.pending_count())
end
