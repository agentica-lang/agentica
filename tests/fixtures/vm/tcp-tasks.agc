struct Hello
  port: Int
  name: String
end

def client(hello: Hello) -> String
  socket = Result.unwrap!(TCP.connect("127.0.0.1", hello.port, 5000))
  Result.unwrap!(TCP.send(socket, "#{hello.name}\n", 5000))
  reply = Result.unwrap!(TCP.read_line(socket, 5000))
  TCP.close(socket)
  return reply
end

def serve(socket: Socket) -> Void
  name = Result.unwrap!(TCP.read_line(socket, 5000))
  Result.unwrap!(TCP.send(socket, "hello #{name}\n", 5000))
  TCP.close(socket)
end

def wait_line(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 5000)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  a = Task.spawn(&client, Hello(port: port, name: "alpha"))
  b = Task.spawn(&client, Hello(port: port, name: "beta"))
  first = Task.spawn(&serve, Result.unwrap!(TCP.accept(listener, 5000)))
  second = Task.spawn(&serve, Result.unwrap!(TCP.accept(listener, 5000)))
  near = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  far = Result.unwrap!(TCP.accept(listener, 5000))
  reader = Task.spawn(&wait_line, near)
  Task.sleep(0)
  waited = TCP.read_line(near, 50)
  wrote = TCP.send(near, "ping\n", 5000)
  ping = TCP.read_line(far, 5000)
  Result.unwrap!(TCP.send(far, "pong\n", 5000))
  pong = Task.await(reader)
  Task.await(first)
  Task.await(second)
  TCP.close(near)
  TCP.close(far)
  TCP.close_listener(listener)
  puts(Task.await(a))
  puts(Task.await(b))
  IO.inspect(waited)
  IO.inspect(wrote)
  IO.inspect(ping)
  IO.inspect(pong)
end
