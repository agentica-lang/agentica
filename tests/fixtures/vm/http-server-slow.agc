import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/hang"
    at = request.target.index_of("?").unwrap!
    side = String.to_int!(request.target.slice(at + 1, request.target.length - at - 1))
    socket = TCP.connect("127.0.0.1", side, 5000).unwrap!
    TCP.send(socket, "hanging\n", 5000).unwrap!
    Task.sleep(60000)
  else
    Task.sleep(300)
  end
  return ok(HttpResponse(status: 200, headers: [], body: "slow #{request.path}"))
end

def fetch(url: String) -> Result[HttpResponse]
  pool = HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64, ca_file: "")).unwrap!
  return HTTP.get(pool, url)
end

def main() -> Void
  side = TCP.listen("127.0.0.1", 0).unwrap!
  options = HttpServerOptions(request_timeout_ms: 100, idle_timeout_ms: 100, max_connections: 2, max_body_bytes: 64)
  server = HTTP.listen("127.0.0.1", 0, &handle, options).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  IO.inspect(fetch(base + "/slow").unwrap!.body)
  Task.spawn(&fetch, base + "/hang?#{TCP.local_port(side)}")
  signal = TCP.accept(side, 5000).unwrap!
  puts(TCP.read_line(signal, 5000).unwrap!)
  puts("main returns while a handler runs")
end
