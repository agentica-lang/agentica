import HTTP from "std/http"

# A call that waits for the only connection and whose task is cancelled meanwhile is dropped, never sent: the server
# sees the slow call and the call after it, not the POST of the cancelled task.

struct Call
  pool: HttpClient
  url: String
end

def request_line(socket: Socket) -> Result[String]
  first = try TCP.read_line(socket, 5000)
  line = first
  while line != ""
    line = try TCP.read_line(socket, 5000)
  end
  return ok(first)
end

def serve(listener: Listener) -> List[String]
  log: List[String] = []
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  open = true
  while open
    case request_line(socket)
      ok(line) ->
        log = List.append(log, line)
        if line == "GET /slow HTTP/1.1"
          Task.sleep(600)
        end
        TCP.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", 5000)
      error(_) -> open = false
    end
  end
  TCP.close(socket)
  return log
end

def get(call: Call) -> Result[HttpResponse]
  return HTTP.get(call.pool, call.url)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  base = "http://127.0.0.1:#{TCP.local_port(listener)}"
  server = Task.spawn(&serve, listener)
  pool = Result.unwrap!(HTTP.client(HTTP.client_options().with(max_connections: 1, timeout_ms: 5000)))
  first = Task.spawn(&get, Call(pool: pool, url: base + "/slow"))
  Task.sleep(100)
  puts(Task.map([1], 1, 200) do |n| HTTP.post(pool, base + "/queued", [], "x") end)
  IO.inspect(Task.await(first))
  IO.inspect(HTTP.get(pool, base + "/after"))
  HTTP.close_client(pool)
  for line in Task.await(server)
    puts(line)
  end
  TCP.close_listener(listener)
end
