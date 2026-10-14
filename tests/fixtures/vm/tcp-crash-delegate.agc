def greet(socket: Socket) -> Result[Void]
  return TCP.send(socket, "hi\n", 1000)
end

def handler(socket: Socket) -> Result[Int]
  sent = Task.await(Task.spawn(&greet, socket))
  zero = 0
  return ok(1 / zero)
end

def client(port: Int) -> Result[String]
  socket = try TCP.connect("127.0.0.1", port, 1000)
  first = try TCP.read_line(socket, 1000)
  second = TCP.read_line(socket, 1500)
  return second
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  c = Task.spawn(&client, TCP.local_port(listener))
  h = Task.spawn_owning(&handler, Result.unwrap!(TCP.accept(listener, 1000)))
  IO.inspect(Task.await(c))
  IO.inspect(Task.await(h))
end
