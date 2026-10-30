import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello\n".bytes))
  end
  return ok(HttpResponse(status: 404, headers: [], body: "not found\n".bytes))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  if System.args().length == 1 and System.args()[0] == "serve"
    puts(HTTP.local_port(server))
    IO.flush()
    HTTP.wait(server).unwrap!
    return
  end
  client = HTTP.client(HTTP.client_options()).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/").unwrap!
  puts(response.status)
  puts(HTTP.text(response.body, response.headers).unwrap!)
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
