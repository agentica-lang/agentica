import HTTP from "std/http"

# A server that closes cancels the task that reads each request body (RequestBody.done). This app cancels it itself,
# at a fixed point, and then hands `app` a body whose pieces have ended: a request with no body still gets its answer,
# and a request with a body gets none (it used to get a 400 for a valid request).

def answer(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: request.path.bytes))
end

def cancelling(request: HttpRequest, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  Task.cancel(body.done)
  ended: Channel[Bytes] = Channel.new(1)
  ended.close
  return HTTP.app(&answer).call(request, HTTP.RequestBody(pieces: ended, done: body.done))
end

# Sends `head` alone (a body it announces never comes, so its reader is still waiting when it is cancelled) and gives
# the first line of the answer, or "closed".
def first_line(port: Int, head: String) -> String
  socket = TCP.connect("127.0.0.1", port, 5000).unwrap!
  TCP.send(socket, head, 5000).unwrap!
  line = TCP.read_line(socket, 5000)
  TCP.close(socket)
  case line
    ok(text) ->
      if text.empty?
        return "closed"
      end
      return text.strip
    error(_) -> return "closed"
  end
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, &cancelling).unwrap!
  port = HTTP.local_port(server)
  puts(first_line(port, "GET /get HTTP/1.1\r\nHost: here\r\nConnection: close\r\n\r\n"))
  puts(first_line(port, "POST /post HTTP/1.1\r\nHost: here\r\nContent-Length: 5\r\n\r\n"))
  HTTP.close_server(server)
  puts(HTTP.wait(server).ok?)
end
