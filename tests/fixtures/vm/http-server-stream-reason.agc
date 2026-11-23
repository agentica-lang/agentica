import HTTP from "std/http"

# A producer that closes its body with a reason: the client gets the pieces sent before it, then the connection
# closes without the last chunk, so it sees a cut body. Once before the handler returns, once during the stream.

struct Feed
  gate: Channel[Bool]
  body: Channel[Bytes]
end

def failure() -> Result[Void] = error("source failed", kind: "io.failed")

def cut(body: Channel[Bytes]) -> Void
  case failure()
    ok(_) -> body.close
    error(e) -> body.close(e)
  end
end

# Sends a piece, waits for main to read it, then gives up.
def gated(feed: Feed) -> Void
  _ = feed.body.send("one".bytes, 5000)
  _ = feed.gate.recv(5000)
  cut(feed.body)
end

def respond(gate: Channel[Bool], request: HTTP.Request, given: HTTP.RequestBody) -> Result[HTTP.Answer]
  _ = try HTTP.read_all(given, 0)
  body: Channel[Bytes] = Channel.new(2)
  if request.path == "/early"
    _ = body.send("a".bytes, 5000)
    cut(body)
  else
    Task.spawn(&gated, Feed(gate: gate, body: body))
  end

  ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: [], body: body)))
end

def app_of(f: HTTP.App) -> HTTP.App = f

def routes(gate: Channel[Bool]) -> HTTP.App = app_of do |request, body| respond(gate, request, body) end

def ask(port: Int, path: String) -> TCP.Socket
  socket = TCP.connect("127.0.0.1", port, 5000).unwrap!
  TCP.send(socket, "GET #{path} HTTP/1.1\r\nHost: x\r\n\r\n", 5000).unwrap!
  socket
end

# The status line and the headers, without the Date.
def head_of(socket: TCP.Socket) -> String
  lines: List[String] = []
  line = TCP.read_line(socket, 5000).unwrap!
  while line != ""
    if not line.start_with?("Date:")
      lines = List.append(lines, line)
    end
    line = TCP.read_line(socket, 5000).unwrap!
  end

  lines.join(" | ")
end

def chunk_of(socket: TCP.Socket) -> String
  size = TCP.read_line(socket, 5000).unwrap!
  "#{size} #{TCP.read_line(socket, 5000).unwrap!}"
end

def main() -> Void
  gate: Channel[Bool] = Channel.new(1)
  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1)
  server = HTTP.serve("127.0.0.1", 0, routes(gate), options).unwrap!
  port = HTTP.local_port(server)

  puts("-- closed with a reason before the handler returns")
  socket = ask(port, "/early")
  puts(head_of(socket))
  puts(chunk_of(socket))
  IO.inspect(TCP.read_line(socket, 5000))
  TCP.close(socket)

  puts("-- closed with a reason during the stream")
  socket = ask(port, "/gated")
  puts(head_of(socket))
  puts(chunk_of(socket))
  _ = gate.send(true, 5000)
  IO.inspect(TCP.read_line(socket, 5000))
  TCP.close(socket)

  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
