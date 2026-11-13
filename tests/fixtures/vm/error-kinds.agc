# The kind and the code of one real failure per family of the C builtins (#671): an OS error has the errno as its code
# (ENOENT 2, EEXIST 17 and EISDIR 21 are the same on Linux, macOS and Windows) and the rest no code.
# ECONNREFUSED differs between systems, so only its presence is shown.

struct Row
  name: String
end

def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def show[T](label: String, family: String, result: Result[T]) -> Void
  case result
    ok(_) -> puts("#{label}: ok")
    error(e) ->
      code = case e.code
        some(n) -> n.to_s
        none -> "none"
      end
      puts("#{label}: #{e.kind} code=#{code} #{family}=#{e.is_a?(family)}")
  end
end

def coded[T](label: String, result: Result[T]) -> Void
  case result
    ok(_) -> puts("#{label}: ok")
    error(e) -> puts("#{label}: #{e.kind} code=#{e.code.some?}")
  end
end

def boom(n: Int) -> Result[Int]
  return ok(10 / n)
end

# Two sends of 600000 bytes and no newline: the reader's line goes over its limit of 1048576 bytes.
def send_long(socket: TCP.Socket) -> Result[Void]
  chunk = "x" * 600000
  try TCP.send(socket, chunk, 5000)
  return TCP.send(socket, chunk, 5000)
end

def main() -> Void
  dir: String = System.args()[0]
  file = at(dir, "file.txt")
  _ = File.write_text(file, "data", 60000)
  show("missing file", "io", File.read_text(at(dir, "missing.txt"), 60000))
  show("directory as file", "io", File.write_text(dir, "x", 60000))
  show("directory as text", "io", File.read_text(dir, 60000))
  show("existing file", "io", File.open(file, "create_private", 60000))
  show("invalid path", "io", File.read_text("", 60000))
  show("stat missing", "io", File.stat(at(dir, "missing.txt"), 60000))
  show("TLS ca_file", "io", TLS.client_context(TLS.ClientOptions(ca_file: at(dir, "missing.pem"))))
  show("bad timeout", "argument", File.read_text(file, 0))

  show("parse Int", "number", "12x".to_i)
  show("Int range", "number", "99999999999999999999".to_i)
  show("bad UTF-8", "text", String.from_bytes(Bytes.from_list([104, 255]).unwrap!))
  show("parse JSON", "json", JSON.parse("{"))
  show("decode JSON", "json", JSON.decode("[1]", Row))
  show("inflate", "zlib", Zlib.inflate("not zlib".bytes, 1000))
  show("environment", "system", System.env("AGENTICA_ERROR_KINDS_UNSET"))

  jobs: Channel[Int] = Channel.new(1)
  show("channel timeout", "channel", jobs.recv(10))
  jobs.close
  show("channel closed", "channel", jobs.recv(10))
  show("task crashed", "task", Task.await(Task.spawn(&boom, 0)))

  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  client = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  server = Result.unwrap!(TCP.accept(listener, 5000))
  TCP.close(server)
  show("end of input", "net", TCP.read_line(client, 5000))
  TCP.close(client)
  show("closed socket", "net", TCP.read_line(client, 5000))
  long = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  peer = Result.unwrap!(TCP.accept(listener, 5000))
  sender = Task.spawn(&send_long, peer)
  show("long line", "net", TCP.read_line(long, 5000))
  TCP.close(long)
  _ = Task.await(sender)
  TCP.close(peer)
  idle = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  show("read timeout", "net", TCP.read_line(idle, 30))
  TCP.close(idle)
  TCP.close_listener(listener)
  coded("refused", TCP.connect("127.0.0.1", port, 5000))
  show("no program", "process", Process.spawn("agentica-error-kinds-missing", [], Process.Options(timeout_ms: 5000)))
end
