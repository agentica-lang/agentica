import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  return ok(HTTP.Response(status: 200, headers: [], body: "served".bytes))
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle)).unwrap!
  url = "http://127.0.0.1:#{HTTP.local_port(server)}/"
  Test.run([
    Test.test("a client made in a test leaves no task behind") do
      pool = HTTP.client().unwrap!
      Test.eq(HTTP.get(pool, url).unwrap!.body, "served".bytes)
    end,
    Test.test("a client made in an earlier test still works") do
      pool = HTTP.client().unwrap!
      first = HTTP.get(pool, url).unwrap!.body.size
      Test.eq(first + HTTP.get(pool, url).unwrap!.body.size, 12)
    end
  ])
end
