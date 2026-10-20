import HTTP from "std/http"

# A POST that the owner has handed to a new worker when close_client runs is not sent: its caller gets
# "http: client is closed", and the server sees no connection.

struct Call
  pool: HttpClient
  url: String
end

def post(call: Call) -> Result[HttpResponse]
  return HTTP.post(call.pool, call.url, [], "do not send")
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  pool = Result.unwrap!(HTTP.client(HTTP.client_options()))
  call = Task.spawn(&post, Call(pool: pool, url: "http://127.0.0.1:#{TCP.local_port(listener)}/"))
  # The POST runs up to its wait for the answer: its job is on the client's channel.
  Task.sleep(0)
  HTTP.close_client(pool)
  IO.inspect(Task.await(call))
  case TCP.accept(listener, 500)
    ok(socket) ->
      puts("the server got a connection")
      TCP.close(socket)
    error(message) -> puts("server: #{message}")
  end
  TCP.close_listener(listener)
end
