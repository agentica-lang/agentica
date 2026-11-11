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
  body: Channel[Bytes]
end

def finish(feed: Feed) -> Void
  feed.body.close
end

# Sends a piece, then waits for main to read it before the next one.
def gated(feed: Feed) -> Void
  for piece in ["one".bytes, "two".bytes]
    _ = feed.body.send(piece, 5000)
    _ = feed.hub.gate.recv(5000)
  end
  finish(feed)
end

# Waits a moment first, so the handler has returned with the channel still open.
def short(feed: Feed) -> Void
  Task.sleep(20)
  _ = feed.body.send("a".bytes, 5000)
  finish(feed)
end

# Waits for the close of the channel, which is how a producer learns that the client left or that the server stopped.
# It sends nothing, so only the close wakes its recv. The wait is a recv and not a loop that sleeps and looks: a loop
# runs once more for each pause that the timing adds, and the number of steps of the run (which the --max-steps sweep
# checks to the step) would change with it.
def wait_closed(feed: Feed) -> Void
  while Result.ok?(feed.body.recv(5000))
    puts("a piece came back to the producer")
  end
end

# What a producer says once the channel is closed: a send fails.
def say_stopped(feed: Feed) -> Void
  case feed.body.send("x".bytes, 0)
    error(message) -> _ = feed.hub.said.send("producer stopped: #{message}", 5000)
    ok(_) -> _ = feed.hub.said.send("producer was not stopped", 5000)
  end
end

# A HEAD request has no body: the server closes the channel without reading it. The responses that the server refuses
# (a body with a 204, headers of its own) have the same producer: it sends nothing, and waits for the close, so that no
# timer of it is still running when main returns, where it would race with the end of the run and change its steps.
def head_only(feed: Feed) -> Void
  wait_closed(feed)
  say_stopped(feed)
end

# Sends one piece, waits until main has read it (the gate), so that its own recv cannot take the piece from the server,
# and then waits for the close.
def until_closed(feed: Feed) -> Void
  _ = feed.body.send("x".bytes, 5000)
  _ = feed.hub.gate.recv(5000)
  wait_closed(feed)
  say_stopped(feed)
end

# Pieces that are not UTF-8, and one that is text.
def binary(feed: Feed) -> Void
  Task.sleep(20)
  _ = feed.body.send(Bytes.from_list([255, 0, 128]).unwrap!, 5000)
  _ = feed.body.send("".bytes, 5000)
  _ = feed.body.send("ok".bytes, 5000)
  finish(feed)
end

# One piece of 512 KiB and 9 bytes: two chunks. The first chunk is one line of "z" ended by a newline, so that main
# reads it with one read_line: a loop of recv_bytes would run once per piece of it that TCP delivers, and the number
# of steps of the run (which the --max-steps sweep checks to the step) would change with the timing.
def large(feed: Feed) -> Void
  Task.sleep(20)
  piece = "z".bytes
  while piece.size < 524288
    piece = piece + piece
  end
  _ = feed.body.send(piece.take(524287) + "\n012345678".bytes, 5000)
  finish(feed)
end

# Sends one piece and then nothing at all: it can only learn that the client left by looking at the channel.
def quiet(feed: Feed) -> Void
  _ = feed.body.send("q".bytes, 5000)
  _ = feed.hub.gate.recv(5000)
  wait_closed(feed)
  if feed.body.closed?
    _ = feed.hub.said.send("quiet producer saw the close", 5000)
  else
    _ = feed.hub.said.send("quiet producer woke with the channel open", 5000)
  end
end

def stream_with(hub: Hub, job: Fn[Feed, Void], status: Int, headers: List[HTTP.Header]) -> Result[HTTP.StreamResponse]
  body: Channel[Bytes] = Channel.new(2)
  Task.spawn(job, Feed(hub: hub, body: body))
  return ok(HTTP.StreamResponse(status: status, headers: headers, body: body))
end

def stream(hub: Hub, job: Fn[Feed, Void], status: Int) -> Result[HTTP.StreamResponse]
  return stream_with(hub, job, status, [HTTP.Header(name: TYPE, value: "text/plain")])
end

# A block is the only way to make a handler that holds the hub.
def handler_of(f: Fn[HTTP.Request, Result[HTTP.StreamResponse]]) -> Fn[HTTP.Request, Result[HTTP.StreamResponse]]
  return f
end

def app_of(f: HTTP.App) -> HTTP.App
  return f
end

# The body read first (a body that cannot be read is refused as HTTP.app does), then the stream of the route.
def stream_answer(route: Fn[HTTP.Request, Result[HTTP.StreamResponse]], request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  case HTTP.read_all(body, 1024)
    ok(_) -> return ok(HTTP.Answer.Stream(try route.call(request)))
    error(message) -> return ok(HTTP.body_refusal(message))
  end
end

def streamed(route: Fn[HTTP.Request, Result[HTTP.StreamResponse]]) -> HTTP.App
  return app_of() do |request, body| stream_answer(route, request, body) end
end

def routes(hub: Hub) -> Fn[HTTP.Request, Result[HTTP.StreamResponse]]
  return handler_of() do |request|
    case request.path
      "/gated" -> return stream(hub, &gated, 200)
      "/short" -> return stream(hub, &short, 200)
      "/leave" -> return stream(hub, &until_closed, 200)
      "/head" -> return stream(hub, &head_only, 200)
      "/binary" -> return stream(hub, &binary, 200)
      "/binary-whole" -> return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole(Bytes.from_list([255, 0, 128]).unwrap!)))
      "/large" -> return stream(hub, &large, 200)
      "/length" -> return stream_with(hub, &head_only, 200, [HTTP.Header(name: "Content-Length", value: "3")])
      "/framing" -> return stream_with(hub, &head_only, 200, [HTTP.Header(name: "Transfer-Encoding", value: "chunked")])
      "/quiet" -> return stream(hub, &quiet, 200)
      "/nobody" -> return stream(hub, &head_only, 204)
      "/whole" -> return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole("whole text\n".bytes)))
      "/fail" -> return error("the handler failed")
      _ -> return ok(HTTP.StreamResponse(status: 404, headers: [], body: HTTP.whole("".bytes)))
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
    if not line.start_with?("Date:")
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

# Exactly count bytes of the socket, as numbers.
def bytes_of(socket: Socket, count: Int) -> List[Int]
  got = "".bytes
  while got.size < count
    got = got + TCP.recv_bytes(socket, count - got.size, 5000).unwrap!
  end
  return got.to_a
end

# One chunk of binary data as "size [bytes]", and the CRLF after it.
def binary_chunk_of(socket: Socket) -> String
  size = TCP.read_line(socket, 5000).unwrap!
  data = bytes_of(socket, size.to_i!)
  TCP.read_line(socket, 5000).unwrap!
  return "#{size} #{data}"
end

# True once the server has closed the connection: the input ends.
def closed_by_server(socket: Socket) -> Bool
  line = TCP.read_line(socket, 5000)
  while Result.ok?(line)
    line = TCP.read_line(socket, 5000)
  end
  return Result.message(line) == "network: end of input"
end

def main() -> Void
  hub = Hub(gate: Channel.new(1), said: Channel.new(4))
  # request_timeout_ms bounds the send of a whole piece: the one of 512 KiB waits for main to read it, which a slow
  # machine with small socket buffers can take long to do (1.4 s was too short on the macOS x86_64 runners, #1189).
  # No case waits for this timeout to fire, so it matches the 5 s of the client's reads.
  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)
  server = HTTP.serve("127.0.0.1", 0, streamed(routes(hub)), options).unwrap!
  port = HTTP.local_port(server)

  puts("-- each piece arrives before the producer sends the next one, and the connection is kept")
  socket = connect(port)
  ask(socket, "GET", "/gated", "")
  puts(head_of(socket))
  puts(chunk_of(socket))
  _ = hub.gate.send(true, 5000)
  puts(chunk_of(socket))
  _ = hub.gate.send(true, 5000)
  puts(chunk_of(socket))
  ask(socket, "GET", "/whole", "")
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)

  puts("-- bytes that are not UTF-8 arrive as they are, streamed or whole")
  ask(socket, "GET", "/binary", "")
  puts(head_of(socket))
  puts(binary_chunk_of(socket))
  puts(chunk_of(socket))
  puts(chunk_of(socket))
  ask(socket, "GET", "/binary-whole", "")
  puts(head_of(socket))
  puts(bytes_of(socket, 3))

  puts("-- a piece over 512 KiB is sent as several chunks")
  ask(socket, "GET", "/large", "")
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)
  TCP.read_line(socket, 5000).unwrap!
  TCP.read_line(socket, 5000).unwrap!
  puts(binary_chunk_of(socket))
  puts(chunk_of(socket))

  puts("-- an empty body is a Content-Length of 0")
  ask(socket, "GET", "/nothing", "")
  puts(head_of(socket))

  puts("-- HEAD gets the head, and the producer is stopped")
  ask(socket, "HEAD", "/head", "")
  puts(head_of(socket))
  puts(hub.said.recv(5000).unwrap!)
  ask(socket, "GET", "/whole", "")
  puts(head_of(socket))
  puts(TCP.read_line(socket, 5000).unwrap!)

  puts("-- a request sent during a stream is dropped: the stream ends cleanly and the connection closes")
  TCP.send(socket, "GET /short HTTP/1.1\r\nHost: x\r\n\r\nGET /whole HTTP/1.1\r\nHost: x\r\n\r\n", 5000).unwrap!
  puts(head_of(socket))
  puts(chunk_of(socket))
  puts(chunk_of(socket))
  puts(closed_by_server(socket))
  TCP.close(socket)

  puts("-- the same after a chunked request body, where the next request is already in the server's buffer")
  socket = connect(port)
  TCP.send(socket, "POST /short HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nz\r\n0\r\n\r\nGET /whole HTTP/1.1\r\nHost: x\r\n\r\n", 5000).unwrap!
  puts(head_of(socket))
  puts(chunk_of(socket))
  puts(chunk_of(socket))
  puts(closed_by_server(socket))
  TCP.close(socket)
  socket = connect(port)

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
  _ = hub.gate.send(true, 5000)
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
  _ = hub.gate.send(true, 5000)
  TCP.close(socket)
  puts(hub.said.recv(5000).unwrap!)
  socket = connect(port)

  puts("-- a client that sent bytes during the stream and then leaves is noticed too")
  TCP.close(socket)
  socket = connect(port)
  TCP.send(socket, "GET /quiet HTTP/1.1\r\nHost: x\r\n\r\nG", 5000).unwrap!
  puts(head_of(socket))
  puts(chunk_of(socket))
  _ = hub.gate.send(true, 5000)
  TCP.close(socket)
  puts(hub.said.recv(5000).unwrap!)

  puts("-- responses that cannot be streamed")
  for path in ["/length", "/framing"]
    socket = connect(port)
    ask(socket, "GET", path, "")
    puts(head_of(socket))
    TCP.close(socket)
  end
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
  _ = hub.gate.send(true, 5000)
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
  # The pieces already sent still arrive; then the connection ends.
  line = TCP.read_line(socket, 5000)
  while Result.ok?(line)
    line = TCP.read_line(socket, 5000)
  end
  IO.inspect(line)
end
