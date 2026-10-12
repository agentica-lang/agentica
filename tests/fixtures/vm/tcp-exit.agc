def hold(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 60000)
end

def wait_accept(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 60000))
end

struct Flood
  socket: Socket
  chunk: String
end

def flood(job: Flood) -> Result[Void]
  return TCP.send(job.socket, job.chunk, 60000)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  quiet = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  silent = Result.unwrap!(TCP.accept(listener, 5000))
  source = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  sink = Result.unwrap!(TCP.accept(listener, 5000))
  chunk = String.join(List.repeat("abcdefgh", 1048576), "")
  chunk = chunk + chunk
  chunk = chunk + chunk
  chunk = chunk + chunk
  Task.spawn(&hold, quiet)
  Task.spawn(&wait_accept, listener)
  Task.spawn(&flood, Flood(socket: source, chunk: chunk))
  Task.sleep(20)
  IO.inspect(silent)
  IO.inspect(sink)
  puts("done")
end
