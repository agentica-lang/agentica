def hold(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 60000)
end

def parent(socket: Socket) -> Result[Int]
  Task.spawn_owning(&hold, socket)
  Task.sleep(0)
  zero = 0
  return ok(1 / zero)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  mine = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(listener), 5000))
  theirs = Result.unwrap!(TCP.accept(listener, 5000))
  owner = Task.spawn_owning(&parent, theirs)
  IO.inspect(TCP.read_line(mine, 5000))
  case Task.await(owner)
    ok(n) -> puts(n)
    error(e) -> puts("parent: #{e}")
  end
  IO.inspect(Task.pending_count())
  TCP.close(mine)
  TCP.close_listener(listener)
end
