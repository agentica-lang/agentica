import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "served".bytes))
end

def keep(server: HTTP.Server) -> Result[Void] = HTTP.wait(server)

def start(servers: Channel[HTTP.Server]) -> Task[Result[Void]]
  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 4, max_body_bytes: 64)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  _ = servers.send(server, 5000)
  Task.spawn_owning(&keep, server)
end

def fetch(url: String) -> Result[HTTP.Response]
  pool = HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)
  HTTP.get_response(url, pool)
end

def show(label: String, outcome: Result[HTTP.Response]) -> Void
  case outcome
    ok(response) -> puts("#{label}: #{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
    error(_) -> puts("#{label}: refused")
  end
end

def main() -> Void
  servers: Channel[HTTP.Server] = Channel.new(1)
  keeper = Task.await(Task.spawn(&start, servers))
  server = servers.recv(5000).unwrap!
  url = "http://127.0.0.1:#{HTTP.local_port(server)}/"
  show("after the helper ended", fetch(url))
  HTTP.close_server(server)
  IO.inspect(Task.await(keeper))
  show("after the close", fetch(url))
end
