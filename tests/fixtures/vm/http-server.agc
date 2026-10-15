import HTTP from "std/http"

def reply(status: Int, body: String) -> Result[HttpResponse]
  return ok(HttpResponse(status: status, headers: [Header(name: "X-Seen", value: "yes")], body: body))
end

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/fail"
    return error("the handler failed")
  end
  if request.path == "/unsendable"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Length", value: "3")], body: "abc"))
  end
  if request.path == "/empty"
    return reply(204, "")
  end
  if request.path == "/same"
    return reply(304, "")
  end
  if request.path == "/close"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Connection", value: "close")], body: "bye"))
  end
  if request.path == "/large"
    return reply(200, "0123456789abcdefg")
  end
  if request.path == "/missing"
    return reply(404, "not found")
  end
  kind = HTTP.header_values(request.headers, "x-kind")
  return reply(200, "#{request.method} #{request.target} #{request.path} #{kind} [#{request.body}]")
end

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{HTTP.header_values(response.headers, "x-seen")} #{HTTP.header_values(response.headers, "content-length")} #{HTTP.header_values(response.headers, "connection")} [#{response.body}]")
    error(message) -> puts("error: #{message}")
  end
end

def raw(port: Int, bytes: List[Int]) -> String
  socket = TCP.connect("127.0.0.1", port, 5000).unwrap!
  TCP.send_bytes(socket, bytes, 5000).unwrap!
  line = TCP.read_line(socket, 5000).unwrap!
  TCP.close(socket)
  return line
end

def main() -> Void
  defaults = HTTP.server_options()
  IO.inspect(defaults)
  bad = HttpServerOptions(request_timeout_ms: 0, idle_timeout_ms: 1000, max_connections: 1, max_body_bytes: 16)
  IO.inspect(HTTP.listen("127.0.0.1", 0, &handle, bad))
  IO.inspect(HTTP.listen("127.0.0.1", 0, &handle, HttpServerOptions(request_timeout_ms: 1000, idle_timeout_ms: 1000, max_connections: 65537, max_body_bytes: 16)))
  IO.inspect(HTTP.listen("127.0.0.1", 0, &handle, HttpServerOptions(request_timeout_ms: 1000, idle_timeout_ms: 1000, max_connections: 1, max_body_bytes: 67108865)))
  options = HttpServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 16)
  server = HTTP.listen("127.0.0.1", 0, &handle, options).unwrap!
  IO.inspect(server)
  port = HTTP.local_port(server)
  base = "http://127.0.0.1:#{port}"
  pool = HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64, ca_file: "")).unwrap!
  show(HTTP.get(pool, base + "/hello?x=1"))
  show(HTTP.get(pool, base + "/again"))
  show(HTTP.post(pool, base + "/form", [Header(name: "X-Kind", value: "a"), Header(name: "x-kind", value: "b")], "ñandú"))
  show(HTTP.request(pool, "HEAD", base + "/head", [], ""))
  show(HTTP.get(pool, base + "/empty"))
  show(HTTP.get(pool, base + "/same"))
  show(HTTP.get(pool, base + "/missing"))
  show(HTTP.post(pool, base + "/limit", [], "0123456789abcdef"))
  show(HTTP.get(pool, base + "/close"))
  show(HTTP.get(pool, base + "/after-close"))
  show(HTTP.get(pool, base + "/fail"))
  show(HTTP.get(pool, base + "/unsendable"))
  show(HTTP.post(pool, base + "/over", [], "0123456789abcdefg"))
  small = HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 16, ca_file: "")).unwrap!
  show(HTTP.get(small, base + "/large"))
  HTTP.close_client(small)
  show(HTTP.get(pool, base + "/still"))
  HTTP.close_client(pool)
  head = [80, 79, 83, 84, 32, 47, 32, 72, 84, 84, 80, 47, 49, 46, 49, 13, 10, 72, 111, 115, 116, 58, 32, 120, 13, 10]
  puts(raw(port, List.concat(head, [67, 111, 110, 116, 101, 110, 116, 45, 76, 101, 110, 103, 116, 104, 58, 32, 50, 13, 10, 13, 10, 255, 254])))
  puts(raw(port, [71, 69, 84, 32, 47, 32, 72, 84, 84, 80, 47, 49, 46, 48, 13, 10, 13, 10]))
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
