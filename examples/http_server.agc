def handle(request: Request, writer: HttpWriter) -> Void
  if request.method == "GET" and request.path == "/"
    HTTP.respond(writer, 200, [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], "hello\n", 30000)
  else
    HTTP.respond(writer, 404, [], "not found\n", 30000)
  end
end

def main() -> Void
  server = Result.unwrap!(HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()))
  puts(String.from_int(HTTP.local_port(server)))
  IO.flush()
  Result.unwrap!(HTTP.wait(server))
end
