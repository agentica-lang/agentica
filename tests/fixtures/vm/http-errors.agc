import HTTP from "std/http"

def options(connections: Int, body: Int) -> HttpClientOptions
  return HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: connections, max_body_bytes: body)
end

def serve(listener: Listener) -> Void
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  line = Result.unwrap!(TCP.read_line(socket, 5000))
  while line != ""
    line = Result.unwrap!(TCP.read_line(socket, 5000))
  end
  TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n", 5000)
  TCP.close(socket)
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  line = Result.unwrap!(TCP.read_line(socket, 5000))
  while line != ""
    line = Result.unwrap!(TCP.read_line(socket, 5000))
  end
  TCP.send_bytes(socket, Bytes.from_list([72, 84, 84, 80, 47, 49, 46, 49, 32, 50, 48, 48, 32, 79, 75, 13, 10, 67, 111, 110, 116, 101, 110, 116, 45, 76, 101, 110, 103, 116, 104, 58, 32, 49, 13, 10, 13, 10, 255]).unwrap!, 5000)
  TCP.close(socket)
end

def main() -> Void
  IO.inspect(HTTP.client(options(0, 10)))
  IO.inspect(HTTP.client(options(65537, 10)))
  IO.inspect(HTTP.client(options(1, 67108865)))
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  port = TCP.local_port(listener)
  server = Task.spawn(&serve, listener)
  pool = Result.unwrap!(HTTP.client(options(1, 16)))
  IO.inspect(pool)
  for url in ["ftp://x/", "http://", "http://u@h/", "http://h:/", "http://h:0/", "http://h:123456/", "http://[::1/", "http://[example.com]/", "http://h x/"]
    IO.inspect(HTTP.get(pool, url))
  end
  IO.inspect(HTTP.request(pool, "GET", "http://127.0.0.1:#{port}/", "".bytes, [Header(name: "Host", value: "x")]))
  IO.inspect(HTTP.request(pool, "BAD METHOD", "http://127.0.0.1:#{port}/", "".bytes))
  IO.inspect(HTTP.post(pool, "http://127.0.0.1:#{port}/", "this body is over the limit".bytes))
  IO.inspect(HTTP.get(pool, "http://127.0.0.1:#{port}/big"))
  IO.inspect(HTTP.get(pool, "http://127.0.0.1:#{port}/bytes"))
  Task.await(server)
  HTTP.close_client(pool)
  TCP.close_listener(listener)
end
