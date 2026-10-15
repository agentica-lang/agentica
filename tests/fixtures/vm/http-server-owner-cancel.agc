import HTTP from "std/http"

struct Wiring
  ports: Channel[Int]
  go: Channel[Bool]
end

def handle(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "served"))
end

def host(ports: Channel[Int]) -> Void
  options = HttpServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 4, max_body_bytes: 64)
  server = HTTP.listen("127.0.0.1", 0, &handle, options).unwrap!
  ports.send(HTTP.local_port(server), 5000)
  HTTP.wait(server)
  puts("never: the server owner was not cancelled")
end

def supervisor(wiring: Wiring) -> Result[Int]
  Task.spawn(&host, wiring.ports)
  wiring.go.recv(5000)
  zero = 0
  return ok(1 / zero)
end

def fetch(url: String) -> Result[HttpResponse]
  pool = HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 64, ca_file: "")).unwrap!
  return HTTP.get(pool, url)
end

def show(label: String, outcome: Result[HttpResponse]) -> Void
  case outcome
    ok(response) -> puts("#{label}: #{response.status} #{response.body}")
    error(message) -> puts("#{label}: refused")
  end
end

def main() -> Void
  wiring = Wiring(ports: Channel.new(1), go: Channel.new(1))
  boss = Task.spawn(&supervisor, wiring)
  port = wiring.ports.recv(5000).unwrap!
  url = "http://127.0.0.1:#{port}/"
  show("before", fetch(url))
  wiring.go.send(true, 5000)
  case Task.await(boss)
    ok(n) -> puts(n)
    error(e) -> puts("supervisor: #{e}")
  end
  show("after", fetch(url))
  puts(Task.pending_count())
end
