def make(capacity: Int) -> Result[Int]
  ch: Channel[Int] = Channel.new(capacity)
  return ok(capacity)
end

def send_in(ms: Int) -> Result[Int]
  ch: Channel[Int] = Channel.new(1)
  ch.send(1, ms)
  return ok(ms)
end

def recv_in(ms: Int) -> Result[Int]
  ch: Channel[Int] = Channel.new(1)
  ch.recv(ms)
  return ok(ms)
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def main() -> Void
  report("capacity 0", Task.await(Task.spawn(&make, 0)))
  report("capacity 1", Task.await(Task.spawn(&make, 1)))
  report("capacity 1048576", Task.await(Task.spawn(&make, 1048576)))
  report("capacity 1048577", Task.await(Task.spawn(&make, 1048577)))
  report("capacity -5", Task.await(Task.spawn(&make, -5)))
  report("send -1", Task.await(Task.spawn(&send_in, -1)))
  report("recv -1", Task.await(Task.spawn(&recv_in, -1)))
end
