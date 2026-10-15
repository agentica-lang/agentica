struct Job
  socket: Socket
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

def serve(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 10)
end

def edit(file: FileHandle) -> Void
end

def watch(p: Process) -> Void
end

def accept_one(l: Listener) -> Void
end

def host(s: HttpServer) -> Void
end

def pool(client: HttpClient) -> Void
end

def job(j: Job) -> Void
end

def many(sockets: List[Socket]) -> Void
end

def hand(l: Listener, s: HttpServer) -> Void
  Task.spawn_owning(&accept_one, l)
  Task.spawn_owning(&host, s)
end

def main() -> Void

end

