import HTTP from "std/http"

# A call that waits in the queue of a pooled client (max_connections 1, its one connection busy) and is cancelled there
# is dropped by the owner: when the busy connection closes, no new connection is opened for it.

struct Peer
  listener: TCP.Listener
  got: Channel[Bool]
  go: Channel[Bool]
end

struct Call
  pool: HTTP.Client
  url: String
end

def status(call: Call) -> Result[Int]
  response = try HTTP.get(call.pool, call.url)
  ok(response.status)
end

def head(socket: TCP.Socket, timeout_ms: Int) -> Result[String]
  first = try TCP.read_line(socket, timeout_ms)
  line = first
  while line != ""
    line = try TCP.read_line(socket, timeout_ms)
  end

  ok(first)
end

# Takes the first request, tells main, answers it with Connection: close once main says so, then waits for another
# connection.
def serve(peer: Peer) -> Result[String]
  socket = try TCP.accept(peer.listener, 10000)
  _ = try head(socket, 10000)
  _ = peer.got.send(true, 10000)
  _ = peer.go.recv(10000)
  try TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok", 10000)
  TCP.close(socket)
  case TCP.accept(peer.listener, 1000)
    ok(_) -> ok("server: a new connection came")
    error(_) -> ok("server: no new connection")
  end
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  pool = Result.unwrap!(HTTP.client(HTTP.ClientOptions(max_connections: 1)))
  url = "http://127.0.0.1:#{TCP.local_port(listener)}/"
  peer = Peer(listener: listener, got: Channel.new(1), go: Channel.new(1))
  server = Task.spawn(&serve, peer)
  call = Call(pool: pool, url: url)
  first = Task.spawn(&status, call)
  _ = peer.got.recv(10000)
  queued = Task.spawn(&status, call)
  Task.sleep(200)
  Task.cancel(queued)
  _ = peer.go.send(true, 10000)
  puts("first: #{Task.await(first)}")
  puts(Task.await(server))
  HTTP.close_client(pool)
  TCP.close_listener(listener)
end
