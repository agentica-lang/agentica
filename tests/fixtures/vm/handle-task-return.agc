def dial(port: Int) -> Void
  socket = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  Result.unwrap!(TCP.send(socket, "hello\n", 5000))
end

def dial_and_return(port: Int) -> Socket
  return Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
end

def open_and_return(path: String) -> FileHandle
  return Result.unwrap!(File.open(path, "write", 5000))
end

def listen_and_return(host: String) -> Listener
  return Result.unwrap!(TCP.listen(host, 0))
end

def write_to(file: FileHandle) -> Result[Void]
  return File.write(file, "from the helper\n", 5000)
end

def main() -> Void
  dir: String = System.args()[0]
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)

  left_open = Task.spawn(&dial, port)
  near = Result.unwrap!(TCP.accept(listener, 5000))
  IO.inspect(TCP.read_line(near, 5000))
  IO.inspect(TCP.read_line(near, 5000))
  Task.await(left_open)

  returned = Task.spawn(&dial_and_return, port)
  far = Result.unwrap!(TCP.accept(listener, 5000))
  socket = Task.await(returned)
  IO.inspect(TCP.send(socket, "late\n", 5000))
  IO.inspect(TCP.read_line(far, 5000))

  path = Result.unwrap!(Path.join([dir, "opened.txt"]))
  file = Task.await(Task.spawn(&open_and_return, path))
  IO.inspect(File.write(file, "late", 5000))

  inner = Task.await(Task.spawn(&listen_and_return, "127.0.0.1"))
  IO.inspect(TCP.accept(inner, 100))

  mine = Result.unwrap!(File.open(path, "write", 5000))
  IO.inspect(Task.await(Task.spawn(&write_to, mine)))
  IO.inspect(File.write(mine, "and main\n", 5000))
  IO.inspect(File.close(mine, 5000))
  IO.inspect(Result.unwrap!(File.read_text(path, 5000)))
  TCP.close(far)
  TCP.close(near)
  TCP.close_listener(listener)
end
