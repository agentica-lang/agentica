import HTTP from "std/http"

# A server that closes cancels the task that reads each request body (RequestBody.done). Under /cut this app cancels
# it itself, at a fixed point, and then hands `app` a body whose pieces have ended: a request with no body (by its
# framing) still gets its answer, and a request with a body gets none (it used to get a 400 for a valid request).
# Under /keep the body is read as usual.

def answer(request: HTTP.Request) -> Result[HTTP.Response]
  said = "#{request.method} #{request.path} #{request.body.size}"
  return ok(HTTP.Response(status: 200, headers: [], body: said.bytes))
end

def route(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  if request.path == "/cut"
    Task.cancel(body.done)
    ended: Channel[Bytes] = Channel.new(1)
    ended.close
    return HTTP.app(&answer).call(request, HTTP.RequestBody(pieces: ended, done: body.done))
  end
  return HTTP.app(&answer).call(request, body)
end

# Sends `data` (a body it announces but leaves out never comes, so its reader is still waiting when it is cancelled)
# and gives the status line and the body of the answer, or "closed".
def exchange(port: Int, data: String) -> String
  socket = TCP.connect("127.0.0.1", port, 5000).unwrap!
  TCP.send(socket, data, 5000).unwrap!
  got = "".bytes
  while true
    case TCP.recv_bytes(socket, 65536, 5000)
      ok(piece) ->
        if piece.empty?
          break
        end
        got = got + piece
      error(_) -> break
    end
  end
  TCP.close(socket)
  if got.empty?
    return "closed"
  end
  lines = HTTP.text(got).unwrap!.split("\r\n")
  return "#{lines[0]} [#{lines[lines.length - 1]}]"
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, &route).unwrap!
  port = HTTP.local_port(server)
  head = " HTTP/1.1\r\nHost: here\r\nConnection: close\r\n"
  puts(exchange(port, "GET /cut#{head}\r\n"))
  puts(exchange(port, "HEAD /cut#{head}\r\n"))
  puts(exchange(port, "POST /cut#{head}Content-Length: 0\r\n\r\n"))
  puts(exchange(port, "POST /cut#{head}Content-Length: 5\r\n\r\n"))
  puts(exchange(port, "GET /cut#{head}Content-Length: 5\r\n\r\n"))
  puts(exchange(port, "POST /keep#{head}Content-Length: 2, 2\r\n\r\nab"))
  HTTP.close_server(server)
  puts(HTTP.wait(server).ok?)
end
