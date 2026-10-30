import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "served".bytes))
end

def keep(server: HttpServer) -> Result[Void]
  return HTTP.wait(server)
end

def start(servers: Channel[HttpServer]) -> Task[Result[Void]]
  options = HttpServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 4, max_body_bytes: 64)
  server = HTTP.listen("127.0.0.1", 0, &handle, options).unwrap!
  servers.send(server, 5000)
  return Task.spawn_owning(&keep, server)
end

def fetch(url: String) -> Result[HttpResponse]
  pool = HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64, ca_file: "")).unwrap!
  return HTTP.get(pool, url)
end

def show(label: String, outcome: Result[HttpResponse]) -> Void
  case outcome
    ok(response) -> puts("#{label}: #{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
    error(message) -> puts("#{label}: refused")
  end
end

def main() -> Void
  servers: Channel[HttpServer] = Channel.new(1)
  keeper = Task.await(Task.spawn(&start, servers))
  server = servers.recv(5000).unwrap!
  url = "http://127.0.0.1:#{HTTP.local_port(server)}/"
  show("after the helper ended", fetch(url))
  HTTP.close_server(server)
  IO.inspect(Task.await(keeper))
  show("after the close", fetch(url))
end
