def handle(request: HttpRequest) -> HttpResponse
  headers = [Header(name: "a", value: request.path)]
  return HttpResponse(status: 200, headers: headers, body: request.body)
end

def main() -> Void
  response = handle(HttpRequest(method: "GET", target: "/", path: "/", headers: [], body: "x"))
  puts(response.status)
  info = File.stat("/tmp", 1000)
  case info
    ok(i) -> puts(i.kind)
    error(m) -> puts(m)
  end
  o = ProcessOutput(stdout: "", stderr: "", truncated: false)
  puts(o.truncated)
end
