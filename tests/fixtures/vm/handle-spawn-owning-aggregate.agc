enum Conn
  Plain(Socket)
  Idle
end

struct Job
  conn: Conn
  inbox: Channel[Int]
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
  TCP.close(kept)
  TCP.close(third)
  TCP.close_listener(listener)
end
