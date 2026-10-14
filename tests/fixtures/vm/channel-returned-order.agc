struct Ctx
  gate: Task[Void]
  ch: Channel[Int]
end

def idle(turns: Int) -> Void
  i = 0
  while i < turns
    Task.sleep(0)
    i += 1
  end
end

def receiver(ch: Channel[Int]) -> Result[Int]
  return ch.recv(5000)
end

def parent(ctx: Ctx) -> Result[Int]
  r = Task.spawn(&receiver, ctx.ch)
  Task.await(ctx.gate)
  zero = 0
  return ok(1 / zero)
end

def main() -> Void
  ch: Channel[Int] = Channel.new(4)
  gate = Task.spawn(&idle, 50)
  p1 = Task.spawn(&parent, Ctx(gate: gate, ch: ch))
  p2 = Task.spawn(&parent, Ctx(gate: gate, ch: ch))
  Task.await(gate)
  puts(ch.send(1, 0))
  puts(ch.send(2, 0))
  puts(Task.await(p1))
  puts(Task.await(p2))
  puts(ch.recv(0))
  puts(ch.recv(0))
end
