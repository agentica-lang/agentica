import HTTP from "std/http"

# A client that does not read holds a streaming producer back, and the server then cuts the client off. It is a program
# of its own, apart from http-server-stream.agc, because how many pieces the kernel's socket buffers take before the
# server's send waits is the system's to decide and changes from run to run, and so do the steps of the run: no
# --max-steps limit at T - 1 or at T is swept for it (KERNEL_TIMED_FIXTURES in tests/vm_diff_support.py).

struct Feed
  said: Channel[String]
  body: Channel[Bytes]
end

# Fills the bounded channel behind a client that does not read. Its send waits longer than the server's timeout for a
# piece to be sent, so the error it ends with is the server cutting the client off, not its own timeout.
def backed_up(feed: Feed) -> Void
  piece = "y".bytes
  while piece.size < 65536
    piece = piece + piece
  end
  sent = 0
  failure = ""
  more = true
  while more
    case feed.body.send(piece, 5000)
      ok(_) -> sent += 1
      error(message) ->
        failure = message
        more = false
    end
  end
  _ = feed.said.send("producer was held back: #{sent < 2000}, then: #{failure}", 5000)
  feed.body.close
end

def routes(said: Channel[String]) -> Fn[HttpRequest, Result[HTTP.StreamResponse]]
  return handler_of() do |_|
    body: Channel[Bytes] = Channel.new(2)
    Task.spawn(&backed_up, Feed(said: said, body: body))
    return ok(
      HTTP.StreamResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain")], body: body),
    )
  end
end

# A block is the only way to make a handler that holds the channel.
def handler_of(f: Fn[HttpRequest, Result[HTTP.StreamResponse]]) -> Fn[HttpRequest, Result[HTTP.StreamResponse]]
  return f
end

def app_of(f: HTTP.App) -> HTTP.App
  return f
end

# The body read first (a body that cannot be read is refused as HTTP.app does), then the stream of the route.
def stream_answer(route: Fn[HttpRequest, Result[HTTP.StreamResponse]], request: HttpRequest, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  case HTTP.read_all(body, 1024)
    ok(_) -> return ok(HTTP.Answer.Stream(try route.call(request)))
    error(message) -> return ok(HTTP.body_refusal(message))
  end
end

def streamed(route: Fn[HttpRequest, Result[HTTP.StreamResponse]]) -> HTTP.App
  return app_of() do |request, body| stream_answer(route, request, body) end
end

# The status line and the headers, without the Date, which differs on every run.
def head_of(socket: Socket) -> String
  lines: List[String] = []
  line = TCP.read_line(socket, 5000).unwrap!
  while line != ""
    if not String.starts_with?(line, "Date:")
      lines = List.append(lines, line)
    end
    line = TCP.read_line(socket, 5000).unwrap!
  end
  return lines.join(" | ")
end

def main() -> Void
  said: Channel[String] = Channel.new(1)
  options = HttpServerOptions(request_timeout_ms: 400, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)
  server = HTTP.serve("127.0.0.1", 0, streamed(routes(said)), options).unwrap!
  socket = TCP.connect("127.0.0.1", HTTP.local_port(server), 5000).unwrap!
  TCP.send(socket, "GET / HTTP/1.1\r\nHost: x\r\n\r\n", 5000).unwrap!
  puts(head_of(socket))
  puts(said.recv(5000).unwrap!)
  TCP.close(socket)
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
