import HTTP from "std/http"

# Sends one event every 100 ms, then ends the stream. A failed send means the client left, so it stops.
def produce(events: Channel[Bytes]) -> Void
  for n in 1..3
    if not Result.ok?(events.send("data: tick #{n}\n\n".bytes, 5000))
      break
    end
    Task.sleep(100)
  end
  events.close
end

def handle(request: HttpRequest) -> Result[HTTP.StreamResponse]
  if request.method == "GET" and request.path == "/events"
    events: Channel[Bytes] = Channel.new(8)
    Task.spawn(&produce, events)
    headers = [Header(name: "Content-Type", value: "text/event-stream"), Header(name: "Cache-Control", value: "no-cache")]
    return ok(HTTP.StreamResponse(status: 200, headers: headers, body: events))
  end
  return ok(HTTP.StreamResponse(status: 404, headers: [], body: HTTP.whole("not found\n".bytes)))
end

def main() -> Void
  server = HTTP.listen_stream("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  if System.args().length == 1 and System.args()[0] == "serve"
    puts(HTTP.local_port(server))
    IO.flush()
    HTTP.wait(server).unwrap!
    return
  end
  client = HTTP.client(HTTP.client_options()).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/events").unwrap!
  puts(response.status)
  puts(HTTP.header_values(response.headers, "transfer-encoding"))
  puts(response.body)
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
