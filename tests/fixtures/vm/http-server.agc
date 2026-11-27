import HTTP from "std/http"

# The whole response of any method on a connection of its own, as the removed pooled `HTTP.request` gave it.
def request(
  options: HTTP.ClientOptions,
  method: String,
  url: String,
  body: Bytes,
  headers: List[HTTP.Header] = [],
) -> Result[HTTP.Response]
  stream = try HTTP.open(method, url, body, headers, options)
  pieces: List[Bytes] = []
  open = true
  while open
    case stream.body.recv(5000)
      ok(piece) -> pieces = pieces.push(piece)
      error(_) -> open = false
    end
  end
  ok(HTTP.Response(status: stream.status, headers: stream.headers, body: Bytes.concat(pieces)))
end

def reply(status: Int, body: String) -> Result[HTTP.Response]
  ok(HTTP.Response(status: status, headers: [HTTP.Header(name: "X-Seen", value: "yes")], body: body.bytes))
end

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  return error("the handler failed") if request.path == "/fail"
  if request.path == "/unsendable"
    return ok(
      HTTP.Response(status: 200, headers: [HTTP.Header(name: "Content-Length", value: "3")], body: "abc".bytes),
    )
  end
  return reply(204, "") if request.path == "/empty"
  return reply(304, "") if request.path == "/same"
  if request.path == "/close"
    return ok(
      HTTP.Response(status: 200, headers: [HTTP.Header(name: "Connection", value: "close")], body: "bye".bytes),
    )
  end
  return reply(200, "0123456789abcdefg") if request.path == "/large"
  return reply(404, "not found") if request.path == "/missing"
  if request.path == "/binary"
    return ok(HTTP.Response(status: 200, headers: [], body: Bytes.from_list([255, 0, 128]).unwrap!))
  end
  if request.path == "/latin1"
    return ok(
      HTTP.Response(
        status: 200,
        headers: [HTTP.Header(name: "Content-Type", value: "text/plain; charset=ISO-8859-1")],
        body: "caf".bytes + Bytes.from_list([233]).unwrap!,
      ),
    )
  end
  if request.path == "/quoted"
    return ok(
      HTTP.Response(
        status: 200,
        headers: [HTTP.Header(name: "Content-Type", value: "text/plain; format=flowed; charset=\"UTF-8\"")],
        body: "ñandú".bytes,
      ),
    )
  end
  kind = HTTP.header_values(request.headers, "x-kind")
  # The body is Bytes: text when it is UTF-8, else its byte values.
  shown = Result.unwrap_or(HTTP.text(request.body, request.headers), "#{request.body.to_a}")
  reply(200, "#{request.method} #{request.target} #{request.path} #{kind} [#{shown}]")
end

def show(r: Result[HTTP.Response]) -> Void
  case r
    ok(response) ->
      puts(
        "#{response.status} #{HTTP.header_values(response.headers, "x-seen")} #{HTTP.header_values(response.headers, "content-length")} #{HTTP.header_values(response.headers, "connection")} [#{HTTP.text(response.body, response.headers).unwrap!}]",
      )
    error(message) -> puts("error: #{message}")
  end
end

def raw(port: Int, bytes: List[Int]) -> String
  socket = TCP.connect("127.0.0.1", port, 5000).unwrap!
  TCP.send_bytes(socket, Bytes.from_list(bytes).unwrap!, 5000).unwrap!
  line = TCP.read_line(socket, 5000).unwrap!
  TCP.close(socket)
  line
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
  String.from_bytes(Bytes.concat(pieces)).unwrap!.split("\r\n\r\n")[1]
end

def main() -> Void
  defaults = HTTP.ServerOptions()
  IO.inspect(defaults)
  bad = HTTP.ServerOptions(request_timeout_ms: 0, idle_timeout_ms: 1000, max_connections: 1, max_body_bytes: 16)
  IO.inspect(HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), bad))
  IO.inspect(
    HTTP.serve(
      "127.0.0.1",
      0,
      HTTP.app(&handle),
      HTTP.ServerOptions(request_timeout_ms: 1000, idle_timeout_ms: 1000, max_connections: 65537, max_body_bytes: 16),
    ),
  )

  IO.inspect(
    HTTP.serve(
      "127.0.0.1",
      0,
      HTTP.app(&handle),
      HTTP.ServerOptions(
        request_timeout_ms: 1000,
        idle_timeout_ms: 1000,
        max_connections: 1,
        max_body_bytes: 268435457,
      ),
    ),
  )

  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 16)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  IO.inspect(server)
  port = HTTP.local_port(server)
  base = "http://127.0.0.1:#{port}"
  pool = HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)
  show(HTTP.get_response(base + "/hello?x=1", pool))
  show(HTTP.get_response(base + "/again", pool))
  show(
    HTTP.post_response(
      base + "/form",
      "ñandú".bytes,
      [HTTP.Header(name: "X-Kind", value: "a"), HTTP.Header(name: "x-kind", value: "b")],
      pool,
    ),
  )

  show(request(pool, "HEAD", base + "/head", "".bytes))
  show(HTTP.get_response(base + "/empty", pool))
  show(HTTP.get_response(base + "/same", pool))
  show(HTTP.get_response(base + "/missing", pool))
  show(HTTP.get_response(base + "/quoted", pool))
  binary = HTTP.get_response(base + "/binary", pool).unwrap!
  IO.inspect(binary.body)
  IO.inspect(HTTP.text(binary.body, binary.headers))
  latin = HTTP.get_response(base + "/latin1", pool).unwrap!
  IO.inspect(latin.body)
  IO.inspect(HTTP.text(latin.body, latin.headers))
  show(HTTP.post_response(base + "/limit", "0123456789abcdef".bytes, [], pool))
  show(HTTP.get_response(base + "/close", pool))
  show(HTTP.get_response(base + "/after-close", pool))
  show(HTTP.get_response(base + "/fail", pool))
  show(HTTP.get_response(base + "/unsendable", pool))
  show(HTTP.post_response(base + "/over", "0123456789abcdefg".bytes, [], pool))
  small = HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 16)
  show(HTTP.get_response(base + "/large", small))
  show(HTTP.get_response(base + "/still", pool))
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
