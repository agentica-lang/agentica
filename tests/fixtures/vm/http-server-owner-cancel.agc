import HTTP from "std/http"

struct Wiring
  ports: Channel[Int]
  go: Channel[Bool]
end

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  return ok(HTTP.Response(status: 200, headers: [], body: "served".bytes))
end

def host(ports: Channel[Int]) -> Void
  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 4, max_body_bytes: 64)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  _ = ports.send(HTTP.local_port(server), 5000)
  _ = HTTP.wait(server)
  puts("never: the server owner was not cancelled")
end

def supervisor(wiring: Wiring) -> Result[Int]
  Task.spawn(&host, wiring.ports)
  _ = wiring.go.recv(5000)
  zero = 0
  return ok(1 / zero)
end

def fetch(url: String) -> Result[HTTP.Response]
  pool = HTTP.client(HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64)).unwrap!
  return HTTP.get(pool, url)
end

def show(label: String, outcome: Result[HTTP.Response]) -> Void
  case outcome
    ok(response) -> puts("#{label}: #{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
    error(_) -> puts("#{label}: refused")
  end
end

def main() -> Void
  wiring = Wiring(ports: Channel.new(1), go: Channel.new(1))
  boss = Task.spawn(&supervisor, wiring)
  port = wiring.ports.recv(5000).unwrap!
  url = "http://127.0.0.1:#{port}/"
  show("before", fetch(url))
  _ = wiring.go.send(true, 5000)
  case Task.await(boss)
    ok(n) -> puts(n)
    error(e) -> puts("supervisor: #{e}")
  end
  show("after", fetch(url))
  puts(Task.pending_count())
end
