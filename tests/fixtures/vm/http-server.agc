import HTTP from "std/http"

def reply(status: Int, body: String) -> Result[HttpResponse]
  return ok(HttpResponse(status: status, headers: [Header(name: "X-Seen", value: "yes")], body: body.bytes))
end

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/fail"
    return error("the handler failed")
  end
  if request.path == "/unsendable"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Length", value: "3")], body: "abc".bytes))
  end
  if request.path == "/empty"
    return reply(204, "")
  end
  if request.path == "/same"
    return reply(304, "")
  end
  if request.path == "/close"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Connection", value: "close")], body: "bye".bytes))
  end
  if request.path == "/large"
    return reply(200, "0123456789abcdefg")
  end
  if request.path == "/missing"
    return reply(404, "not found")
  end
  if request.path == "/binary"
    return ok(HttpResponse(status: 200, headers: [], body: Bytes.from_list([255, 0, 128]).unwrap!))
  end
  if request.path == "/latin1"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=ISO-8859-1")], body: "caf".bytes + Bytes.from_list([233]).unwrap!))
  end
  if request.path == "/quoted"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; format=flowed; charset=\"UTF-8\"")], body: "ñandú".bytes))
  end
  kind = HTTP.header_values(request.headers, "x-kind")
  # The body is Bytes: text when it is UTF-8, else its byte values.
  shown = Result.unwrap_or(HTTP.text(request.body, request.headers), "#{request.body.to_a}")
  return reply(200, "#{request.method} #{request.target} #{request.path} #{kind} [#{shown}]")
end

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{HTTP.header_values(response.headers, "x-seen")} #{HTTP.header_values(response.headers, "content-length")} #{HTTP.header_values(response.headers, "connection")} [#{HTTP.text(response.body, response.headers).unwrap!}]")
    error(message) -> puts("error: #{message}")
  end
end

def raw(port: Int, bytes: List[Int]) -> String
  socket = TCP.connect("127.0.0.1", port, 5000).unwrap!
  TCP.send_bytes(socket, Bytes.from_list(bytes).unwrap!, 5000).unwrap!
  line = TCP.read_line(socket, 5000).unwrap!
  TCP.close(socket)
  return line
end

# Sends the request bytes and reads the answer to the end (the request says Connection: close); returns its body text.
def raw_body(port: Int, bytes: List[Int]) -> String
  socket = TCP.connect("127.0.0.1", port, 5000).unwrap!
  TCP.send_bytes(socket, Bytes.from_list(bytes).unwrap!, 5000).unwrap!
  pieces: List[Bytes] = []
  data = TCP.recv_bytes(socket, 4096, 5000).unwrap!
  while !data.empty?
    pieces = List.append(pieces, data)
    data = TCP.recv_bytes(socket, 4096, 5000).unwrap!
  end
  TCP.close(socket)
  return String.from_bytes(Bytes.concat(pieces)).unwrap!.split("\r\n\r\n")[1]
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
  show(HTTP.post(pool, base + "/form", "ñandú".bytes, [Header(name: "X-Kind", value: "a"), Header(name: "x-kind", value: "b")]))
  show(HTTP.request(pool, "HEAD", base + "/head", "".bytes))
  show(HTTP.get(pool, base + "/empty"))
  show(HTTP.get(pool, base + "/same"))
  show(HTTP.get(pool, base + "/missing"))
  show(HTTP.get(pool, base + "/quoted"))
  binary = HTTP.get(pool, base + "/binary").unwrap!
  IO.inspect(binary.body)
  IO.inspect(HTTP.text(binary.body, binary.headers))
  latin = HTTP.get(pool, base + "/latin1").unwrap!
  IO.inspect(latin.body)
  IO.inspect(HTTP.text(latin.body, latin.headers))
  show(HTTP.post(pool, base + "/limit", "0123456789abcdef".bytes))
  show(HTTP.get(pool, base + "/close"))
  show(HTTP.get(pool, base + "/after-close"))
  show(HTTP.get(pool, base + "/fail"))
  show(HTTP.get(pool, base + "/unsendable"))
  show(HTTP.post(pool, base + "/over", "0123456789abcdefg".bytes))
  small = HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 16, ca_file: "")).unwrap!
  show(HTTP.get(small, base + "/large"))
  HTTP.close_client(small)
  show(HTTP.get(pool, base + "/still"))
  HTTP.close_client(pool)
  # Request bodies that are not UTF-8 reach the handler as they are, with either framing.
  post = "POST / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n".bytes.to_a
  length = List.concat(post, List.concat("Content-Length: 2\r\n\r\n".bytes.to_a, [255, 254]))
  puts(raw_body(port, length))
  chunks = List.concat([255, 0, 128], List.concat("\r\n2\r\n".bytes.to_a, [254, 10]))
  chunked = List.concat(post, List.concat("Transfer-Encoding: chunked\r\n\r\n3\r\n".bytes.to_a, chunks))
  puts(raw_body(port, List.concat(chunked, "\r\n0\r\n\r\n".bytes.to_a)))
  puts(raw(port, [71, 69, 84, 32, 47, 32, 72, 84, 84, 80, 47, 49, 46, 48, 13, 10, 13, 10]))
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
