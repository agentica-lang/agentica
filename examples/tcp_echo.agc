def echo(socket: Socket) -> Void
  line = TCP.read_line(socket, 30000)
  if Result.ok?(line)
    TCP.send(socket, Result.unwrap!(line) + "\n", 30000)
  end
  TCP.close(socket)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  puts(String.from_int(TCP.local_port(listener)))
  IO.flush()
  while true
    connection = TCP.accept(listener, 30000)
    if Result.ok?(connection)
      Task.spawn(&echo, Result.unwrap!(connection))
    end
  end
end
