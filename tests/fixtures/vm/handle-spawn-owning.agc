def ask(port: Int) -> Result[String]
  socket = try TCP.connect("127.0.0.1", port, 5000)
  try TCP.send(socket, "ping\n", 5000)
  first = try TCP.read_line(socket, 5000)
  second = try TCP.read_line(socket, 5000)
  puts("client: #{first}, #{second}")
  return TCP.read_line(socket, 5000)
end

def peek(socket: Socket) -> Result[Void]
  return TCP.send(socket, "peek\n", 5000)
end

def echo_once(socket: Socket) -> Result[String]
  line = try TCP.read_line(socket, 5000)
  try TCP.send(socket, "echo #{line}\n", 5000)
  return ok(line)
end

def give_away(socket: Socket) -> Result[Int]
  Task.spawn_owning(&echo_once, socket)
  return ok(1)
end

def give_twice(socket: Socket) -> Result[Int]
  Task.spawn_owning(&echo_once, socket)
  Task.spawn_owning(&peek, socket)
  return ok(2)
end

def give_closed(socket: Socket) -> Result[Int]
  TCP.close(socket)
  Task.spawn_owning(&peek, socket)
  return ok(3)
end

def accept_once(listener: Listener) -> Result[String]
  socket = try TCP.accept(listener, 5000)
  try TCP.send(socket, "listener handed over\n", 5000)
  return ok("accepted")
end

def report(label: String, outcome: Result[Int]) -> Void
  case outcome
    ok(n) -> puts("#{label}: #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)

  asking = Task.spawn(&ask, port)
  served = Result.unwrap!(TCP.accept(listener, 5000))
  IO.inspect(Task.await(Task.spawn(&peek, served)))
  helper = Task.spawn_owning(&echo_once, served)
  IO.inspect(Task.await(helper))
  IO.inspect(Task.await(asking))
  IO.inspect(TCP.send(served, "after\n", 5000))

  other = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  accepted = Result.unwrap!(TCP.accept(listener, 5000))
  report("not the owner", Task.await(Task.spawn(&give_away, accepted)))
  IO.inspect(TCP.send(accepted, "still mine\n", 5000))
  IO.inspect(TCP.read_line(other, 5000))
  report("twice", Task.await(Task.spawn_owning(&give_twice, accepted)))
  TCP.close(other)

  third = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  closing = Result.unwrap!(TCP.accept(listener, 5000))
  report("closed", Task.await(Task.spawn_owning(&give_closed, closing)))
  TCP.close(third)
  TCP.close_listener(listener)

  lone = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  acceptor = Task.spawn_owning(&accept_once, lone)
  caller = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(lone), 5000))
  IO.inspect(TCP.read_line(caller, 5000))
  IO.inspect(Task.await(acceptor))
  IO.inspect(TCP.accept(lone, 100))
  TCP.close(caller)
end
