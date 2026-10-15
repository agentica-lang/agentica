import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "served"))
end

def main() -> Void
  ports: Channel[Int] = Channel.new(1)
  Test.run([
    Test.test("a server left listening is reported") do
      server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
      ports.send(HTTP.local_port(server), 5000)
      ok()
    end,
    Test.test("the next test finds its port closed") do
      port = ports.recv(5000).unwrap!
      listening = TCP.connect("127.0.0.1", port, 2000).ok?
      Test.assert(not listening, "the server is still listening")
    end
  ])
end
