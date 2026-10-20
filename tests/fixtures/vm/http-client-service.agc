import HTTP from "std/http"

# Answers one request per accepted connection while that connection lasts, then says how it ended. The client's
# connection ends only when the client closes it.
def serve(listener: Listener) -> String
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  ended = ""
  while ended == ""
    case TCP.read_line(socket, 5000)
      ok(line) ->
        if line == ""
          TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 5000)
        end
      error(message) -> ended = message
    end
  end
  TCP.close(socket)
  return ended
end

# Makes a client, hands it over and crashes: the client is not the crashed task's.
def make_and_crash(clients: Channel[HttpClient]) -> Result[Void]
  clients.send(Result.unwrap!(HTTP.client(HTTP.client_options())), 5000)
  failed: Result[Int] = error("the maker crashes")
  Result.unwrap!(failed)
  return ok()
end

def get(pool: HttpClient, url: String) -> String
  case HTTP.get(pool, url)
    ok(response) -> return "#{response.status} #{response.body}"
    error(message) -> return message
  end
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  url = "http://127.0.0.1:#{TCP.local_port(listener)}/"
  server = Task.spawn(&serve, listener)
  puts(Task.pending_count())
  clients: Channel[HttpClient] = Channel.new(1)
  maker = Task.spawn(&make_and_crash, clients)
  puts(not Result.ok?(Task.await(maker)))
  pool = Result.unwrap!(clients.recv(5000))
  puts(get(pool, url))
  puts(get(pool, url))
  puts(Task.pending_count())
  HTTP.close_client(pool)
  puts(Task.await(server))
  puts(get(pool, url))
  puts(Task.pending_count())
  TCP.close_listener(listener)
end
