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

def head(socket: TCP.Socket, port: Int, seen: List[String]) -> List[String]
  line = Result.unwrap!(TCP.read_line(socket, 5000))
  while line != ""
    seen = List.append(seen, String.replace(line, port.to_s, "PORT"))
    line = Result.unwrap!(TCP.read_line(socket, 5000))
  end
  seen
end

def answer(listener: TCP.Listener, port: Int, seen: List[String], response: String) -> List[String]
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  seen = head(socket, port, seen)
  _ = TCP.send(socket, response, 5000)
  TCP.close(socket)
  seen
end

def serve(listener: TCP.Listener) -> List[String]
  port = TCP.local_port(listener)
  seen = answer(listener, port, [], "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Note: one\r\nx-note: two\r\n\r\nhello")
  seen = answer(
    listener,
    port,
    seen,
    "HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\nX-Tail: t\r\n\r\n",
  )

  socket = Result.unwrap!(TCP.accept(listener, 5000))
  seen = head(socket, port, seen)
  seen = List.append(seen, Result.unwrap!(TCP.read_line(socket, 5000)))
  _ = TCP.send(socket, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nuntil close", 5000)
  TCP.close(socket)
  seen = answer(listener, port, seen, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  # A body that is not UTF-8: the client keeps it as it came.
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  seen = head(socket, port, seen)
  _ = TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 3\r\n\r\n", 5000)
  _ = TCP.send_bytes(socket, Bytes.from_list([255, 0, 128]).unwrap!, 5000)
  TCP.close(socket)
  seen
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  server = Task.spawn(&serve, listener)
  pool = HTTP.ClientOptions()
  base = "http://127.0.0.1:#{port}"
  first = Result.unwrap!(HTTP.get_response(base + "/a?b=1#frag", pool))
  second = request(pool, "DELETE", base, "".bytes, [HTTP.Header(name: "X-Id", value: "7")])
  third = HTTP.post_response(base + "/form", "ping\r\n".bytes, [], pool)
  fourth = HTTP.get_response(base + "/again", pool)
  fifth = Result.unwrap!(HTTP.get_response(base + "/binary", pool))
  IO.inspect(first.status)
  IO.inspect(first.body)
  IO.inspect(HTTP.text(first.body, first.headers))
  IO.inspect(HTTP.header_values(first.headers, "X-NOTE"))
  IO.inspect(second)
  IO.inspect(third)
  IO.inspect(fourth)
  IO.inspect(fifth.body)
  IO.inspect(HTTP.text(fifth.body, fifth.headers))
  for line in Task.await(server)
    puts(line)
  end
  TCP.close_listener(listener)
end
