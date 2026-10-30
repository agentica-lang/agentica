import HTTP from "std/http"

TYPE = "Content-Type"

# What the producers of the routes share with main: the gate main opens to let a producer go on, and the line a producer
# writes about how it ended.
struct Hub
  gate: Channel[Bool]
  said: Channel[String]
end

struct Feed
  hub: Hub
  body: Channel[String]
end

def finish(feed: Feed) -> Void
  feed.body.close
end

# Sends a piece, then waits for main to read it before the next one.
def gated(feed: Feed) -> Void
  for piece in ["one", "two"]
    feed.body.send(piece, 5000)
    feed.hub.gate.recv(5000)
  end
  finish(feed)
end

# Waits a moment first, so the handler has returned with the channel still open.
def short(feed: Feed) -> Void
  Task.sleep(20)
  feed.body.send("a", 5000)
  finish(feed)
end

# Sends until a send fails, which is how the producer learns that the client left.
def until_closed(feed: Feed) -> Void
  while Result.ok?(feed.body.send("x", 5000))
    Task.sleep(5)
  end
  case feed.body.send("x", 0)
    error(message) -> feed.hub.said.send("producer stopped: #{message}", 5000)
    ok(_) -> feed.hub.said.send("producer was not stopped", 5000)
  end
end

# Sends one piece and then nothing at all: it can only learn that the client left by looking at the channel.
def quiet(feed: Feed) -> Void
  feed.body.send("q", 5000)
  while not feed.body.closed?
    Task.sleep(5)
  end
  feed.hub.said.send("quiet producer saw the close", 5000)
end

# Pauses longer than the server's timeouts between pieces: a live stream is not cut.
def slow(feed: Feed) -> Void
  for piece in ["a", "b", "c"]
    Task.sleep(500)
    feed.body.send(piece, 5000)
  end
  finish(feed)
end

# Fills the bounded channel behind a client that does not read, and says where the producer had to wait.
def backed_up(feed: Feed) -> Void
  piece = "y"
  while String.length(piece) < 65536
    piece = piece + piece
  end
  sent = 0
  while Result.ok?(feed.body.send(piece, 300))
    sent += 1
  end
  feed.hub.said.send("producer waited: #{sent < 2000}", 5000)
  finish(feed)
end

def stream(hub: Hub, job: Fn[Feed, Void], status: Int) -> Result[HTTP.StreamResponse]
  body: Channel[String] = Channel.new(2)
  Task.spawn(job, Feed(hub: hub, body: body))
  return ok(HTTP.StreamResponse(status: status, headers: [Header(name: TYPE, value: "text/plain")], body: body))
end

# A block is the only way to make a handler that holds the hub.
def handler_of(f: Fn[HttpRequest, Result[HTTP.StreamResponse]]) -> Fn[HttpRequest, Result[HTTP.StreamResponse]]
  return f
end

def routes(hub: Hub) -> Fn[HttpRequest, Result[HTTP.StreamResponse]]
  return handler_of() do |request|
    case request.path
      "/gated" -> return stream(hub, &gated, 200)
      "/short" -> return stream(hub, &short, 200)
      "/leave" -> return stream(hub, &until_closed, 200)
      "/quiet" -> return stream(hub, &quiet, 200)
      "/slow" -> return stream(hub, &slow, 200)
      "/back" -> return stream(hub, &backed_up, 200)
      "/nobody" -> return stream(hub, &gated, 204)
      "/whole" -> return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole("whole text\n")))
      "/fail" -> return error("the handler failed")
      _ -> return ok(HTTP.StreamResponse(status: 404, headers: [], body: HTTP.whole("")))
    end
  end
end

def connect(port: Int) -> Socket
  return TCP.connect("127.0.0.1", port, 5000).unwrap!
end

def ask(socket: Socket, method: String, path: String, extra: String) -> Void
  TCP.send(socket, "#{method} #{path} HTTP/1.1\r\nHost: x\r\n#{extra}\r\n", 5000).unwrap!
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

# One chunk as "size data", or "end" for the last one.
def chunk_of(socket: Socket) -> String
  size = TCP.read_line(socket, 5000).unwrap!
  if size == "0"
    TCP.read_line(socket, 5000).unwrap!
    return "end"
  end
  return "#{size} #{TCP.read_line(socket, 5000).unwrap!}"
end

def main() -> Void
  hub = Hub(gate: Channel.new(1), said: Channel.new(4))
  options = HttpServerOptions(request_timeout_ms: 200, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)
  server = HTTP.listen_stream("127.0.0.1", 0, routes(hub), options).unwrap!
  port = HTTP.local_port(server)

  puts("-- each piece arrives before the producer sends the next one, and the connection is kept")
  socket = connect(port)
  ask(socket, "GET", "/gated", "")
  puts(head_of(socket))
  puts(chunk_of(socket))
  hub.gate.send(true, 5000)
  puts(chunk_of(socket))
  hub.gate.send(true, 5000)
  puts(chunk_of(socket))
  ask(socket, "GET", "/whole", "")
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)

  puts("-- HEAD gets the head, and the producer is stopped")
  ask(socket, "HEAD", "/leave", "")
  puts(head_of(socket))
  puts(hub.said.recv(5000).unwrap!)
  ask(socket, "GET", "/whole", "")
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)

  puts("-- a request sent behind a stream is answered after it")
  TCP.send(socket, "GET /short HTTP/1.1\r\nHost: x\r\n\r\nGET /whole HTTP/1.1\r\nHost: x\r\n\r\n", 5000).unwrap!
  puts(head_of(socket))
  puts(chunk_of(socket))
  puts(chunk_of(socket))
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)

  puts("-- the same after a chunked request body, where the next request is already in the server's buffer")
  TCP.send(socket, "POST /short HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nz\r\n0\r\n\r\nGET /whole HTTP/1.1\r\nHost: x\r\n\r\n", 5000).unwrap!
  puts(head_of(socket))
  puts(chunk_of(socket))
  puts(chunk_of(socket))
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)

  puts("-- Connection: close ends the connection after the last chunk")
  ask(socket, "GET", "/short", "Connection: close\r\n")
  puts(head_of(socket))
  puts(chunk_of(socket))
  puts(chunk_of(socket))
  IO.inspect(TCP.read_line(socket, 5000))
  TCP.close(socket)

  puts("-- a client that leaves stops the producer and frees the connection slot")
  socket = connect(port)
  ask(socket, "GET", "/leave", "")
  puts(head_of(socket))
  puts(chunk_of(socket))
  TCP.close(socket)
  puts(hub.said.recv(5000).unwrap!)
  socket = connect(port)
  ask(socket, "GET", "/whole", "")
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)

  puts("-- a client that leaves while the producer is silent is noticed too")
  TCP.close(socket)
  socket = connect(port)
  ask(socket, "GET", "/quiet", "")
  puts(head_of(socket))
  puts(chunk_of(socket))
  TCP.close(socket)
  puts(hub.said.recv(5000).unwrap!)
  socket = connect(port)

  puts("-- a slow producer is not cut by the timeouts")
  ask(socket, "GET", "/slow", "")
  puts(head_of(socket))
  for n in 1..4
    puts(chunk_of(socket))
  end

  puts("-- a client that does not read holds the producer back")
  ask(socket, "GET", "/back", "")
  puts(head_of(socket))
  puts(hub.said.recv(5000).unwrap!)
  TCP.close(socket)

  puts("-- responses that cannot be streamed")
  socket = connect(port)
  ask(socket, "GET", "/nobody", "")
  puts(head_of(socket))
  TCP.close(socket)
  socket = connect(port)
  ask(socket, "GET", "/fail", "")
  puts(head_of(socket))
  TCP.close(socket)

  puts("-- closing the server ends a stream that is running")
  socket = connect(port)
  ask(socket, "GET", "/leave", "")
  puts(head_of(socket))
  puts(chunk_of(socket))
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
  # The pieces already sent still arrive; then the connection ends.
  line = TCP.read_line(socket, 5000)
  while Result.ok?(line)
    line = TCP.read_line(socket, 5000)
  end
  IO.inspect(line)
end
