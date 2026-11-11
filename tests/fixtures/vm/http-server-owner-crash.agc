import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  at = request.target.index_of("?").unwrap!
  side = String.to_int!(request.target.slice(at + 1, request.target.length - at - 1))
  socket = TCP.connect("127.0.0.1", side, 5000).unwrap!
  TCP.send(socket, "handling\n", 5000).unwrap!
  Task.sleep(60000)
  puts("never: the handler woke up")
  return ok(HTTP.Response(status: 200, headers: [], body: "late".bytes))
end

def fetch(url: String) -> Result[HTTP.Response]
  pool = HTTP.client(HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)).unwrap!
  return HTTP.get(pool, url)
end

def explode(server: HTTP.Server) -> Result[Int]
  zero = HTTP.local_port(server) * 0
  return ok(10 / zero)
end

def main() -> Void
  side = TCP.listen("127.0.0.1", 0).unwrap!
  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 4, max_body_bytes: 64)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  pending = Task.spawn(&fetch, base + "/hang?#{TCP.local_port(side)}")
  signal = TCP.accept(side, 5000).unwrap!
  puts(TCP.read_line(signal, 5000).unwrap!)
  IO.inspect(Task.await(Task.spawn_owning(&explode, server)))
  IO.inspect(TCP.read_line(signal, 5000))
  case Task.await(pending)
    ok(response) -> puts("response: #{response.status}")
    error(message) -> puts("client: #{message}")
  end
  IO.inspect(HTTP.wait(server))
  case fetch(base + "/after?0")
    ok(response) -> puts("after: #{response.status}")
    error(_) -> puts("after: refused")
  end
end
