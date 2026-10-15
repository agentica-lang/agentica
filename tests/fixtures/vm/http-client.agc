import HTTP from "std/http"

def head(socket: Socket, port: Int, seen: List[String]) -> List[String]
  line = Result.unwrap!(TCP.read_line(socket, 5000))
  while line != ""
    seen = List.append(seen, String.replace(line, port.to_s, "PORT"))
    line = Result.unwrap!(TCP.read_line(socket, 5000))
  end
  return seen
end

def serve(listener: Listener) -> List[String]
  port = TCP.local_port(listener)
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  seen = head(socket, port, [])
  TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Note: one\r\nx-note: two\r\n\r\nhello", 5000)
  seen = head(socket, port, seen)
  TCP.send(socket, "HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\nX-Tail: t\r\n\r\n", 5000)
  seen = head(socket, port, seen)
  seen = List.append(seen, Result.unwrap!(TCP.read_line(socket, 5000)))
  TCP.send(socket, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nuntil close", 5000)
  TCP.close(socket)
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  seen = head(socket, port, seen)
  TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 5000)
  TCP.close(socket)
  return seen
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  server = Task.spawn(&serve, listener)
  pool = Result.unwrap!(HTTP.client(HTTP.client_options()))
  base = "http://127.0.0.1:#{port}"
  first = Result.unwrap!(HTTP.get(pool, base + "/a?b=1#frag"))
  second = HTTP.request(pool, "DELETE", base, [Header(name: "X-Id", value: "7")], "")
  third = HTTP.post(pool, base + "/form", [], "ping\r\n")
  fourth = HTTP.get(pool, base + "/again")
  HTTP.close_client(pool)
  closed = HTTP.get(pool, base)
  IO.inspect(first.status)
  IO.inspect(first.body)
  IO.inspect(HTTP.header_values(first.headers, "X-NOTE"))
  IO.inspect(second)
  IO.inspect(third)
  IO.inspect(fourth)
  IO.inspect(closed)
  for line in Task.await(server)
    puts(line)
  end
  TCP.close_listener(listener)
end
