import HTTP from "std/http"

# A task cancelled while it waits for its answer through get_response closes its connection at once: the server, which
# never answers, reads the end of input.

struct Call
  url: String
end

struct Peer
  listener: TCP.Listener
  got: Channel[Bool]
end

def fetch(call: Call) -> Result[HTTP.Response] = HTTP.get_response(call.url)

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

def cancelled(peer: Peer, call: Call) -> Void
  server = Task.spawn(&hold, peer)
  client = Task.spawn(&fetch, call)
  _ = peer.got.recv(10000)
  Task.cancel(client)
  puts(Task.await(server))
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  peer = Peer(listener: listener, got: Channel.new(1))
  cancelled(peer, Call(url: "http://127.0.0.1:#{TCP.local_port(listener)}/"))
  TCP.close_listener(listener)
end
