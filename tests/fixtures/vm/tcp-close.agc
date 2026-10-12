def wait_line(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 60000)
end

def wait_accept(listener: Listener) -> Result[Socket]
  return TCP.accept(listener, 60000)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  near = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  far = Result.unwrap!(TCP.accept(listener, 5000))
  reader = Task.spawn(&wait_line, near)
  acceptor = Task.spawn(&wait_accept, listener)
  Task.sleep(20)
  TCP.close(near)
  TCP.close_listener(listener)
  IO.inspect(Task.await(reader))
  IO.inspect(Task.await(acceptor))
  IO.inspect(TCP.read_line(far, 5000))
  TCP.close(far)
  TCP.close(near)
  TCP.close_listener(listener)
end
