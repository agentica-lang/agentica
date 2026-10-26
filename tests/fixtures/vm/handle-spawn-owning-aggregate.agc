enum Conn
  Plain(Socket)
  Idle
end

struct Job
  conn: Conn
  inbox: Channel[Int]
end

struct Pair
  inbox: Channel[Int]
  sockets: Channel[Socket]
end

def report(label: String, r: Result[Int]) -> Void
  case r
    ok(n) -> puts("#{label}: ok #{n}")
    error(e) -> puts("#{label}: #{e}")
  end
end

def drain(label: String, ch: Channel[Int]) -> Void
  while true
    case ch.recv(5000)
      ok(n) -> puts("#{label}: got #{n}")
      error(e) ->
        puts("#{label}: #{e}, closed? #{ch.closed?}")
        break
    end
  end
end

def work(job: Job) -> Result[Int]
  try job.inbox.send(1, 1000)
  case job.conn
    Conn.Plain(socket) ->
      try TCP.send(socket, "from the worker\n", 5000)
      return ok(2)
    Conn.Idle -> return ok(0)
  end
end

def sockets(all: List[Socket]) -> Result[Int]
  for socket in all
    try TCP.send(socket, "listed\n", 5000)
  end
  return ok(all.size)
end

def table(all: Map[String, Socket]) -> Result[Int]
  for socket in all.values
    try TCP.send(socket, "mapped\n", 5000)
  end
  return ok(all.size)
end

def wrapped(r: Result[Socket]) -> Result[Int]
  socket = try r
  try TCP.send(socket, "wrapped\n", 5000)
  return ok(1)
end

# Owns the inbox (handed over with the Pair) and hands over a Job with it and a socket it gets from the caller: the
# spawn fails on the socket after the inbox passed its check, so the inbox stays here and this task's crash closes it.
def give_half(pair: Pair) -> Result[Int]
  socket = try pair.sockets.recv(5000)
  Task.spawn_owning(&work, Job(conn: Conn.Plain(socket), inbox: pair.inbox))
  return ok(8)
end

# Hands over a Job whose socket the calling task does not own: the spawn fails, and its channel stays unowned.
def give_borrowed(job: Job) -> Result[Int]
  Task.spawn_owning(&work, job)
  return ok(9)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  client = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  served = Result.unwrap!(TCP.accept(listener, 5000))

  inbox: Channel[Int] = Channel.new(4)
  report("plain", Task.await(Task.spawn_owning(&work, Job(conn: Conn.Plain(served), inbox: inbox))))
  drain("plain", inbox)
  IO.inspect(TCP.read_line(client, 5000))
  IO.inspect(TCP.send(served, "after\n", 5000))
  IO.inspect(TCP.read_line(client, 5000))
  TCP.close(client)

  idle: Channel[Int] = Channel.new(4)
  report("idle", Task.await(Task.spawn_owning(&work, Job(conn: Conn.Idle, inbox: idle))))
  drain("idle", idle)

  other = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  mine = Result.unwrap!(TCP.accept(listener, 5000))
  report("listed", Task.await(Task.spawn_owning(&sockets, [mine, mine])))
  IO.inspect(TCP.read_line(other, 5000))
  IO.inspect(TCP.read_line(other, 5000))
  IO.inspect(TCP.read_line(other, 5000))
  TCP.close(other)

  third = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  kept = Result.unwrap!(TCP.accept(listener, 5000))
  spare: Channel[Int] = Channel.new(4)
  report("borrowed", Task.await(Task.spawn(&give_borrowed, Job(conn: Conn.Plain(kept), inbox: spare))))
  IO.inspect(TCP.send(kept, "still mine\n", 5000))
  IO.inspect(TCP.read_line(third, 5000))
  report("spare", Task.await(Task.spawn_owning(&work, Job(conn: Conn.Idle, inbox: spare))))
  drain("spare", spare)

  half: Channel[Int] = Channel.new(4)
  sockets: Channel[Socket] = Channel.new(1)
  halfway = Task.spawn_owning(&give_half, Pair(inbox: half, sockets: sockets))
  IO.inspect(sockets.send(kept, 5000))
  report("half", Task.await(halfway))
  drain("half", half)
  IO.inspect(TCP.send(kept, "kept again\n", 5000))
  IO.inspect(TCP.read_line(third, 5000))
  TCP.close(kept)
  TCP.close(third)

  fourth = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  shared = Result.unwrap!(TCP.accept(listener, 5000))
  report("mapped", Task.await(Task.spawn_owning(&table, {"a": shared, "b": shared, "c": shared})))
  IO.inspect(TCP.read_line(fourth, 5000))
  IO.inspect(TCP.read_line(fourth, 5000))
  IO.inspect(TCP.read_line(fourth, 5000))
  IO.inspect(TCP.read_line(fourth, 5000))
  TCP.close(fourth)

  fifth = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  boxed = Result.unwrap!(TCP.accept(listener, 5000))
  report("wrapped", Task.await(Task.spawn_owning(&wrapped, ok(boxed))))
  IO.inspect(TCP.read_line(fifth, 5000))
  IO.inspect(TCP.read_line(fifth, 5000))
  TCP.close(fifth)
  TCP.close_listener(listener)
end
