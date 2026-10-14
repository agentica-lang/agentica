def drain(label: String, ch: Channel[Int]) -> Void
  while true
    case ch.recv(5000)
      ok(n) -> puts("#{label}: got #{n}")
      error(e) ->
        puts("#{label}: #{e}, closed? #{ch.closed?}")
        break
    end
  end
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def returns(ch: Channel[Int]) -> Result[Int]
  try ch.send(1, 1000)
  try ch.send(2, 1000)
  return ok(2)
end

def crashes(ch: Channel[Int]) -> Result[Int]
  try ch.send(1, 1000)
  try ch.send(2, 1000)
  zero = 0
  return ok(1 / zero)
end

def lingers(ch: Channel[Int]) -> Result[Int]
  try ch.send(1, 1000)
  Task.sleep(60000)
  return ok(0)
end

def abandons(ch: Channel[Int]) -> Result[Int]
  Task.spawn_owning(&lingers, ch)
  Task.sleep(0)
  zero = 0
  return ok(1 / zero)
end

def listens(ch: Channel[Int]) -> Result[Int]
  return ch.recv(60000)
end

def abandons_listener(ch: Channel[Int]) -> Result[Int]
  Task.spawn_owning(&listens, ch)
  Task.sleep(0)
  zero = 0
  return ok(1 / zero)
end

def late(ch: Channel[Int]) -> Result[Int]
  Task.sleep(50)
  try ch.send(7, 1000)
  return ok(7)
end

def idle(ch: Channel[Int]) -> Result[Int]
  Task.sleep(50)
  return ok(0)
end

def flood(ch: Channel[Int]) -> Result[Int]
  try ch.send(1, 5000)
  try ch.send(2, 5000)
  return ok(2)
end

def main() -> Void
  done: Channel[Int] = Channel.new(4)
  report("return", Task.await(Task.spawn_owning(&returns, done)))
  drain("return", done)

  broken: Channel[Int] = Channel.new(4)
  report("crash", Task.await(Task.spawn_owning(&crashes, broken)))
  drain("crash", broken)

  cancelled: Channel[Int] = Channel.new(4)
  report("cancel", Task.await(Task.spawn(&abandons, cancelled)))
  drain("cancel", cancelled)

  waiting: Channel[Int] = Channel.new(4)
  Task.spawn_owning(&late, waiting)
  drain("parked reader", waiting)

  full: Channel[Int] = Channel.new(1)
  keeper = Task.spawn_owning(&idle, full)
  sender = Task.spawn(&flood, full)
  report("parked sender", Task.await(sender))
  report("keeper", Task.await(keeper))
  drain("full", full)

  shared: Channel[Int] = Channel.new(1)
  peer = Task.spawn(&listens, shared)
  Task.sleep(0)
  report("parked owner", Task.await(Task.spawn(&abandons_listener, shared)))
  report("parked peer", Task.await(peer))
  puts(shared.closed?)
  puts(Task.pending_count())
end
