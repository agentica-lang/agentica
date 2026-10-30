import HTTP from "std/http"

# A server that sends bytes past the end of some responses: a body on a HEAD answer, a second response after a
# Content-Length body, bytes after a chunked body that ends at the 512th byte, and a body on a 204. The client keeps
# no such connection, so every call gets its own response.

def request_line(socket: Socket) -> Result[String]
  first = try TCP.read_line(socket, 5000)
  line = first
  while line != ""
    line = try TCP.read_line(socket, 5000)
  end
  return ok(first)
end

def chunked_to_512() -> String
  data = "cccccccccccccccccccccccccccccccccccccccccccccccccc"
  data = data + data + data + data + data + data + data + data + data + data
  return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1f4\r\n" + data + "\r\n0\r\n\r\n"
end

def answer(line: String) -> String
  if line == "HEAD /head HTTP/1.1"
    return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
  elsif line == "GET /extra HTTP/1.1"
    return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nevil"
  elsif line == "GET /chunked HTTP/1.1"
    return chunked_to_512() + "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nevil"
  elsif line == "GET /204 HTTP/1.1"
    return "HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nevil"
  end
  return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nget"
end

# One connection at a time: the client never has two open (max_connections 1), and it closes each one it does not
# keep before it opens the next.
def serve(listener: Listener) -> List[String]
  log: List[String] = []
  id = 1
  while id <= 7
    socket = Result.unwrap!(TCP.accept(listener, 5000))
    open = true
    while open
      case request_line(socket)
        ok(line) ->
          log = List.append(log, "conn #{id}: #{line}")
          TCP.send(socket, answer(line), 5000)
        error(_) -> open = false
      end
    end
    TCP.close(socket)
    id = id + 1
  end
  return log
end

def show(r: Result[HttpResponse]) -> String
  case r
    ok(response) -> return "#{response.status} [#{response.body.size} bytes]"
    error(message) -> return message
  end
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  base = "http://127.0.0.1:#{TCP.local_port(listener)}"
  server = Task.spawn(&serve, listener)
  pool = Result.unwrap!(HTTP.client(HTTP.client_options().with(max_connections: 1, timeout_ms: 5000)))
  puts("HEAD /head: #{show(HTTP.request(pool, "HEAD", base + "/head", "".bytes))}")
  for path in ["/head", "/head", "/extra", "/extra", "/chunked", "/chunked", "/204", "/204"]
    puts("#{path}: #{show(HTTP.get(pool, base + path))}")
  end
  HTTP.close_client(pool)
  for line in Task.await(server)
    puts(line)
  end
  TCP.close_listener(listener)
end
