import HTTP from "std/http"

struct Signal
  port: Int
  word: String
end

def linger(signal: Signal) -> Void
  socket = TCP.connect("127.0.0.1", signal.port, 5000).unwrap!
  TCP.send(socket, "#{signal.word}\n", 5000).unwrap!
  line = TCP.read_line(socket, 60000).unwrap!
  puts("never: #{signal.word} read #{line}")
end

def side_of(request: HTTP.Request) -> Int
  at = request.target.index_of("?").unwrap!
  return request.target.slice(at + 1, request.target.length - at - 1).to_i!
end

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  side = side_of(request)
  if request.path == "/left"
    Task.spawn(&linger, Signal(port: side, word: "left"))
    return ok(HTTP.Response(status: 200, headers: [], body: "returned".bytes))
  end
  Task.spawn(&linger, Signal(port: side, word: "spawned"))
  socket = TCP.connect("127.0.0.1", side, 5000).unwrap!
  TCP.send(socket, "sleeping\n", 5000).unwrap!
  Task.sleep(60000)
  puts("never: the handler woke up")
  return ok(HTTP.Response(status: 200, headers: [], body: "late".bytes))
end

def fetch(url: String) -> Result[HTTP.Response]
  pool = HTTP.client(HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)).unwrap!
  return HTTP.get(pool, url)
end

def show(r: Result[HTTP.Response]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
    error(message) -> puts("error: #{message}")
  end
end

def main() -> Void
  side = TCP.listen("127.0.0.1", 0).unwrap!
  tail = "?#{TCP.local_port(side)}"
  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 4, max_body_bytes: 64)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  show(Task.await(Task.spawn(&fetch, base + "/left" + tail)))
  left = TCP.accept(side, 5000).unwrap!
  puts(TCP.read_line(left, 5000).unwrap!)
  sleeper = Task.spawn(&fetch, base + "/sleep" + tail)
  a = TCP.accept(side, 5000).unwrap!
  b = TCP.accept(side, 5000).unwrap!
  lines = [TCP.read_line(a, 5000).unwrap!, TCP.read_line(b, 5000).unwrap!]
  puts(lines.sort)
  HTTP.close_server(server)
  for socket in [left, a, b]
    IO.inspect(TCP.read_line(socket, 5000))
  end
  show(Task.await(sleeper))
  IO.inspect(HTTP.wait(server))
  case fetch(base + "/after" + tail)
    ok(response) -> puts("after close: #{response.status}")
    error(_) -> puts("after close: refused")
  end
end
