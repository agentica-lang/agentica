import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/crash"
    zero = request.body.size
    return ok(HttpResponse(status: 200, headers: [], body: "#{10 / zero}".bytes))
  end
  return ok(HttpResponse(status: 200, headers: [], body: "fine".bytes))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)
  server = HTTP.listen("127.0.0.1", 0, &handle, options).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  pool = HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64, ca_file: "")).unwrap!
  for path in ["/crash", "/ok", "/crash", "/crash", "/ok"]
    case HTTP.post(pool, base + path, "".bytes)
      ok(response) -> puts("#{path}: #{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
      error(message) -> puts("#{path}: #{message}")
    end
  end
  IO.inspect(Task.unobserved_crash())
  HTTP.close_server(server)
end
