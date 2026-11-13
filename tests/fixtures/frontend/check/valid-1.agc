struct Job
  socket: TCP.Socket
end

struct Crate
  inbox: Channel[Int]
end

def feed(inbox: Channel[Int]) -> Result[Int]
  return ok(1)
end

def crate(c: Crate) -> Void
end

def identity(n: Int) -> Int
  return n
end

def serve(socket: TCP.Socket) -> Result[String]
  return TCP.read_line(socket, 10)
end

def edit(file: File.Handle) -> Void
end

def watch(p: Process) -> Void
end

def accept_one(l: TCP.Listener) -> Void
end

def job(j: Job) -> Void
end

def many(sockets: List[TCP.Socket]) -> Void
end

def main() -> Void
  socket = TCP.connect("127.0.0.1", 1, 10).unwrap!
  t: Task[Result[String]] = Task.spawn_owning(&serve, socket)
  _ = Task.await(t)
  Task.spawn_owning(&edit, File.open("x", "read", 10).unwrap!)
  Task.spawn_owning(&watch, Process.spawn("x", [], Process.Options(timeout_ms: 10)).unwrap!)
  ch: Channel[Int] = Channel.new(4)
  _fed: Task[Result[Int]] = Task.spawn_owning(&feed, ch)
  Task.spawn_owning(&feed, Channel.new(2))
end

