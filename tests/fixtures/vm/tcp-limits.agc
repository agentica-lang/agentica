struct Job
  socket: Socket
  text: String
end

def push(job: Job) -> Result[Void]
  return TCP.send(job.socket, job.text, 5000)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  exact = String.join(List.repeat("a", 1048576), "")
  client = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  server = Result.unwrap!(TCP.accept(listener, 5000))
  first = Task.spawn(&push, Job(socket: client, text: exact + "\n"))
  line = Result.unwrap!(TCP.read_line(server, 5000))
  sent = Task.await(first)
  second = Task.spawn(&push, Job(socket: client, text: exact + "b"))
  over = TCP.read_line(server, 5000)
  closed = TCP.read_line(server, 5000)
  pushed = Task.await(second)
  eof = TCP.read_line(client, 5000)
  TCP.close(client)
  TCP.close_listener(listener)
  puts(String.length(line))
  IO.inspect(sent)
  IO.inspect(over)
  IO.inspect(closed)
  IO.inspect(pushed)
  IO.inspect(eof)
end
