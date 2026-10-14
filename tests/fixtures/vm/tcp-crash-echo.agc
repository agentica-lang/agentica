struct Client
  port: Int
  line: String
end

def echo(socket: Socket) -> Result[String]
  line = TCP.read_line(socket, 5000).unwrap!
  n = 100 / (line.length - 4)
  TCP.send(socket, "#{line} #{n}\n", 5000)
  TCP.close(socket)
  return ok(line)
end

def ask(client: Client) -> Result[String]
  socket = try TCP.connect("127.0.0.1", client.port, 5000)
  try TCP.send(socket, client.line + "\n", 5000)
  reply = TCP.read_line(socket, 1000)
  TCP.close(socket)
  return reply
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  first = Task.spawn(&ask, Client(port: port, line: "boom"))
  crashed = Task.spawn_owning(&echo, Result.unwrap!(TCP.accept(listener, 5000)))
  IO.inspect(Task.await(first))
  second = Task.spawn(&ask, Client(port: port, line: "hello"))
  served = Task.spawn_owning(&echo, Result.unwrap!(TCP.accept(listener, 5000)))
  IO.inspect(Task.await(second))
  IO.inspect(Task.await(served))
  IO.inspect(Task.await(crashed))
  TCP.close_listener(listener)
end
