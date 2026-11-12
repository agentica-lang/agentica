# A builtin record or enum that a std/ module re-exports prints with the name a program writes (HTTP.Response,
# Logger.Level), not its builtin name (HttpWire.Response, LogRegistry.Level): to_s, inspect, puts, interpolation, and
# inside a list, an Optional and a Result.
import HTTP from "std/http"
import Logger from "std/logger"

def main() -> Void
  header = HTTP.Header(name: "a", value: "b")
  response = HTTP.Response(status: 200, headers: [header], body: "x".bytes)
  puts(header)
  puts(header.to_s)
  puts(header.inspect)
  puts("got #{response}")
  puts(HTTP.ServerOptions(max_connections: 2).inspect)
  request: Result[HTTP.Request] = ok(HTTP.Request(method: "GET", target: "/", path: "/", headers: [], body: "".bytes))
  puts(request)
  level = Logger.Level.Warning
  puts(level)
  puts([some(level)].inspect)
  event = Logger.Event(level: Logger.Level.Info, message: "m", fields: {}, time_ms: 0, task: 1)
  puts(event)
end
