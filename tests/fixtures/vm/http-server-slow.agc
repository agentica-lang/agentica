import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  if request.path == "/hang"
    at = request.target.index_of("?").unwrap!
    side = request.target.slice(at + 1, request.target.length - at - 1).to_i!
    socket = TCP.connect("127.0.0.1", side, 5000).unwrap!
    TCP.send(socket, "hanging\n", 5000).unwrap!
    Task.sleep(60000)
  else
    Task.sleep(300)
  end
  return ok(HTTP.Response(status: 200, headers: [], body: "slow #{request.path}".bytes))
end

def fetch(url: String) -> Result[HTTP.Response]
  pool = HTTP.client(HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)).unwrap!
  return HTTP.get(pool, url)
end

def main() -> Void
  side = TCP.listen("127.0.0.1", 0).unwrap!
  options = HTTP.ServerOptions(request_timeout_ms: 100, idle_timeout_ms: 100, max_connections: 2, max_body_bytes: 64)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  IO.inspect(fetch(base + "/slow").unwrap!.body)
  Task.spawn(&fetch, base + "/hang?#{TCP.local_port(side)}")
  signal = TCP.accept(side, 5000).unwrap!
  puts(TCP.read_line(signal, 5000).unwrap!)
  puts("main returns while a handler runs")
end
