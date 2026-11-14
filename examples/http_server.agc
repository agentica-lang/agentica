import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  if request.method == "GET" and request.path == "/"
    return ok(
      HTTP.Response(
        status: 200,
        headers: [HTTP.Header(name: "Content-Type", value: "text/plain; charset=utf-8")],
        body: "hello\n".bytes,
      ),
    )
  end
  if request.method == "GET" and request.path == "/slow"
    Task.sleep(500)
    return ok(HTTP.Response(status: 200, headers: [], body: "done\n".bytes))
  end
  ok(HTTP.Response(status: 404, headers: [], body: "not found\n".bytes))
end

# Serves until SIGTERM or Ctrl-C, then stops gracefully: the requests in flight finish first.
def serve_until_stopped(server: HTTP.Server) -> Void
  signals = System.subscribe([System.Signal.Term, System.Signal.Int]).unwrap!
  puts(HTTP.local_port(server))
  IO.flush()
  while not Result.ok?(signals.recv(60000))
  end
  HTTP.shutdown(server)
  puts("stopped")
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle)).unwrap!
  if System.args().length == 1 and System.args()[0] == "serve"
    serve_until_stopped(server)
    return
  end
  client = HTTP.client().unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/").unwrap!
  puts(response.status)
  puts(HTTP.text(response.body, response.headers).unwrap!)
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
