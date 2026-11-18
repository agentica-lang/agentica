import HTTP from "std/http"

# A task cancelled while it waits for its answer closes its connection at once, on a pooled client and through
# get_response: the server, which never answers, reads the end of input. The pooled connection does not go back to the
# pool, and its one slot is free: the next call opens a new connection, which is answered.

struct Call
  pool: HTTP.Client
  url: String
  once: Bool
end

struct Peer
  listener: TCP.Listener
  got: Channel[Bool]
end

def fetch(call: Call) -> Result[HTTP.Response]
  return HTTP.get_response(call.url) if call.once

  HTTP.get(call.pool, call.url)
end

# Takes a connection and its request head, tells main, and reads on without answering until the client closes.
def hold(peer: Peer) -> Result[String]
  socket = try TCP.accept(peer.listener, 10000)
  line = try TCP.read_line(socket, 10000)
  while line != ""
    line = try TCP.read_line(socket, 10000)
  end
  _ = peer.got.send(true, 10000)
  rest = try TCP.recv_bytes(socket, 1024, 10000)
  TCP.close(socket)
  ok("server: the client closed with #{rest.size} bytes more")
end

def answer(listener: TCP.Listener) -> Result[String]
  socket = try TCP.accept(listener, 10000)
  line = try TCP.read_line(socket, 10000)
  while line != ""
    line = try TCP.read_line(socket, 10000)
  end
  try TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 10000)
  ok("server: answered on a new connection")
end

def cancelled(peer: Peer, call: Call) -> Void
  server = Task.spawn(&hold, peer)
  client = Task.spawn(&fetch, call)
  _ = peer.got.recv(10000)
  Task.cancel(client)
  puts(Task.await(server))
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  pool = Result.unwrap!(HTTP.client(HTTP.ClientOptions(max_connections: 1)))
  peer = Peer(listener: listener, got: Channel.new(1))
  call = Call(pool: pool, url: "http://127.0.0.1:#{TCP.local_port(listener)}/", once: false)
  cancelled(peer, call)
  server = Task.spawn(&answer, listener)
  case HTTP.get(pool, call.url)
    ok(response) -> puts("client: #{response.status}")
    error(e) -> puts("client: #{e.message}")
  end
  puts(Task.await(server))
  cancelled(peer, call.with(once: true))
  HTTP.close_client(pool)
  TCP.close_listener(listener)
end
