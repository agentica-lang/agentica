# HTTP (`std/http`)

The HTTP types are `HTTP.Request`, `HTTP.Response`, `HTTP.Header`,
`HTTP.ClientOptions`, `HTTP.ServerOptions` and the handles `HTTP.Client` and
`HTTP.Server`, builtin types that `std/http` re-exports (also
`import {Request, Response} from "std/http"`). A value prints with these
names: `HTTP.Response(...)`, `<HTTP.Client>`. `TLS.Context` and `--deny-net`:
`network.md`.

## Client

HTTP is an Agentica library: `import HTTP from "std/http"`. Without it, `HTTP.`
calls are `CHECK-UNKNOWN-NAME` and the help shows the import.

```text
HTTP.client(options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Client]
HTTP.close_client(client: HTTP.Client) -> Void
HTTP.proxy_from_env(url: String) -> String
HTTP.get(client: HTTP.Client, url: String) -> Result[HTTP.Response]
HTTP.post(client: HTTP.Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[HTTP.Response]
HTTP.request(client: HTTP.Client, method: String, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[HTTP.Response]
HTTP.get_response(url: String, options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Response]
HTTP.post_response(url: String, body: Bytes, headers: List[HTTP.Header] = [], options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Response]
HTTP.text(body: Bytes, headers: List[HTTP.Header] = []) -> Result[String]
HTTP.header_values(headers: List[HTTP.Header], name: String) -> List[String]
HTTP.download(client: HTTP.Client, url: String, path: String, options: DownloadOptions = DownloadOptions()) -> Result[Download]
HTTP.start(origin: String, options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Connection]
HTTP.send_request(conn: HTTP.Connection, method: String, target: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[HTTP.ResponseHead]
HTTP.read_body(conn: HTTP.Connection, max_bytes: Int = 65536) -> Result[Bytes]
HTTP.finish(conn: HTTP.Connection) -> Void
HTTP.open(method: String, url: String, body: Bytes, headers: List[HTTP.Header] = [], options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Stream]
HTTP.upload(method: String, url: String, body: Channel[Bytes], length: Int = -1, headers: List[HTTP.Header] = [], options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Response]

HTTP.Header(name: String, value: String)
HTTP.Response(status: Int, headers: List[HTTP.Header], body: Bytes)
DownloadOptions(timeout_ms: Int = 30000, max_total_bytes: Int = 268435456)
Download(status: Int, headers: List[HTTP.Header], bytes_written: Int)
HTTP.ClientOptions(timeout_ms: Int = 30000, idle_timeout_ms: Int = 30000, max_connections: Int = 4, max_body_bytes: Int = 1048576, proxy: String = "", tls: Optional[TLS.Context] = none)
```

- Every call is whole: it returns after the full body is read, as `Bytes` of at
  most `max_body_bytes`, with any content. `HTTP.ClientOptions()`, the default,
  gives a 30 s timeout, a 30 s idle timeout, 4 connections per origin, a 1 MiB
  body limit and system CA trust (`tls: some(context)` takes a client context
  instead). Options must be positive (`max_body_bytes` at most 64 MiB). One
  `timeout_ms` covers the whole call.
  `proxy: "http://host:port"` sends `http://` requests through a forward proxy
  and opens a `CONNECT` tunnel for `https://`; user info in it is sent as
  `Proxy-Authorization: Basic` to the proxy only, and no error shows it. A
  client never reads the environment: pass
  `HTTP.ClientOptions(proxy: HTTP.proxy_from_env(url))` (curl's rules, `""` is
  none).
- One connection that you drive yourself (Ruby's `Net::HTTP.start`):
  `HTTP.start(origin)` connects (an origin with no path),
  `HTTP.send_request(conn, method, target, body)` returns at the response head
  (`status`, `headers`), `HTTP.read_body(conn, max_bytes)` gives the body piece
  by piece and an empty `Bytes` at its end, `HTTP.finish(conn)` closes. After a
  body read to its end the same connection takes the next request, unless the
  server closed it. Use it for a body read as it arrives (up to 256 MiB); whole
  responses use `get` or the client. One call at a time, in the task that opened
  it.
- One request: `HTTP.get_response(url)` and `HTTP.post_response(url, body)`
  make a client of their own, send it and close it before they return (Ruby's
  `Net::HTTP.get_response`). Many requests: one `HTTP.client()` with `get`,
  `post` and `request`. Over HTTPS each `get_response` builds a new TLS context,
  so many calls belong on one client.
- A body on a channel, on a connection of its own: `HTTP.open(method, url,
  body)` returns at the head as `HTTP.Stream(status, headers, body, done)`. Read
  `stream.body` (a `Channel[Bytes]`, pieces up to 64 KiB) until the closed
  error, then `Task.await(stream.done)`: only `done` tells a whole body from a
  cut one (a timeout, a body over 256 MiB). Close `body` to stop early while
  data flows; on a quiet stream use `Task.cancel(stream.done)`.
  `HTTP.upload(method, url, body_channel, length)` sends the pieces another task
  puts in the channel, as chunks until it closes (`length` -1, the default) or
  with an exact `length`, which ends the body at that many bytes, and returns
  the whole response; `POST`, `PUT` or `PATCH` only. A producer that can fail
  should set `length`, since a closed channel is a clean end.
- URLs are `http://` or `https://`; the fragment is dropped, user info is
  rejected and IPv6 hosts go in brackets. It adds `Host` and `Content-Length`; a
  request that sets `Host`, `Content-Length`, `Transfer-Encoding` or
  `Connection` is an error.
- Response header names are lowercase; `header_values` matches
  case-insensitively and keeps duplicates in order. 4xx and 5xx are normal
  responses. Errors are Results: protocol and limit errors start with `http: `,
  a timeout is `network: operation timed out`. `HTTP.get` has no
  streaming (see `HTTP.start`), redirect following or gzip decoding.
- `download` streams a `GET` body to a new file instead of `Bytes`: the
  file must not exist (an existing path fails untouched), a failed download
  keeps the partial file, and `max_total_bytes` (default 256 MiB) caps what is
  written. 4xx and 5xx still return `ok` with their status and written body.
- A body is `Bytes`: send text as `"...".bytes` (no body: `"".bytes`) and read
  it with `HTTP.text(response.body, response.headers)`, which decodes the
  `charset` of `Content-Type` (UTF-8 without one) when `b.decode` knows it
  (UTF-8, UTF-16, UTF-32, ASCII, Latin-1, ISO-8859-15, Windows-1252); a body
  invalid in its charset, or another charset, is an error. `HTTP.Response` is
  not JSON encodable. The body of a request in a server handler is `Bytes` too:
  `HTTP.text(request.body, request.headers)`.
- Names that do not exist: `response.text`, `header_timeout_ms`
  (`request_timeout_ms`), and `read`, `trailers`, `close_body`,
  `request_stream`.

## Server

```text
HTTP.serve(host: String, port: Int, app: HTTP.App, options: HTTP.ServerOptions = HTTP.ServerOptions()) -> Result[HTTP.Server]
HTTP.serve_tls(host: String, port: Int, tls: TLS.Context, app: HTTP.App, options: HTTP.ServerOptions = HTTP.ServerOptions()) -> Result[HTTP.Server]
HTTP.app(handler: HTTP.Handler, max_body_bytes: Int = 1048576) -> HTTP.App
HTTP.local_port(server: HTTP.Server) -> Int
HTTP.wait(server: HTTP.Server) -> Result[Void]
HTTP.close_server(server: HTTP.Server) -> Void
HTTP.shutdown(server: HTTP.Server, timeout_ms: Int = 30000) -> Void
HTTP.Answer: Whole(HTTP.Response), Stream(HTTP.StreamResponse), Upgrade(HTTP.Upgrade)

HTTP.RequestBody(pieces: Channel[Bytes], done: Task[Result[Void]])
HTTP.read_all(body: HTTP.RequestBody, max_bytes: Int) -> Result[Bytes]
HTTP.body_refusal(message: String) -> HTTP.Answer
HTTP.whole(data: Bytes) -> Channel[Bytes]
HTTP.accept_websocket(request: HTTP.Request, session: HTTP.WebSocketSession, options: HTTP.WebSocketOptions = HTTP.WebSocketOptions()) -> Result[HTTP.Upgrade]
HTTP.WebSocket(incoming: Channel[HTTP.Message], outgoing: Channel[HTTP.Message], protocol: String)
HTTP.Message: Text(String), Binary(Bytes), Ping(Bytes), Pong(Bytes), Close(Int, String), Prepared(Bytes)
HTTP.prepare(message: HTTP.Message) -> HTTP.Message
HTTP.WebSocketOptions(max_message_bytes: Int = 1048576, idle_ms: Int = 0, ping_ms: Int = 0, close_ms: Int = 5000, protocols: List[String] = [], outgoing_queue: Int = 8)

HTTP.Request(method: String, target: String, path: String, headers: List[HTTP.Header], body: Bytes,
            remote_addr: String = "")
HTTP.StreamResponse(status: Int, headers: List[HTTP.Header], body: Channel[Bytes], length: Optional[Int] = none)
HTTP.ServerOptions(request_timeout_ms: Int = 30000, idle_timeout_ms: Int = 30000, max_connections: Int = 128, max_body_bytes: Int = 1048576)
```

`serve` takes an app, `Fn[HTTP.Request, HTTP.RequestBody, Result[HTTP.Answer]]`
(`HTTP.App`): the request (empty `body`) and the body on a channel in, a whole
response, a stream or a WebSocket upgrade out. A route that takes the request
whole is a `Handler`, made an app with `HTTP.app`:

```ruby
import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  if request.method == "GET" and request.path == "/"
    return ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello\n".bytes))
  end

  ok(HTTP.Response(status: 404, headers: [], body: "not found\n".bytes))
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle)).unwrap!
  puts(HTTP.local_port(server))
  IO.flush()
  HTTP.wait(server).unwrap!
end
```

One app serves every kind of route on one port: branch on `request.path` and
return `HTTP.Answer.Upgrade`, `.Stream` or `.Whole`, or call
`HTTP.app(&page).call(request, body)` for a plain `Handler`.

- `HTTP.Handler` is `Fn[HTTP.Request, Result[HTTP.Response]]`, and `HTTP.App`
  is `Fn[HTTP.Request, HTTP.RequestBody, Result[HTTP.Answer]]`. A middleware is
  a function `Handler -> Handler` that calls `next.call(request)` or answers
  itself. It returns a lambda, `->(request) { step(next, request) }`; keep
  the lambda to one call and put the work in a named `step`. Stack them:
  `logged(guarded(&hello))`. An `App` middleware is `App -> App`.
- `serve` (TCP) and `serve_tls` (a server `TLS.Context`) return at once and
  serve in the background. Port 0 picks a free port (`local_port`). Each
  connection runs in its own task, with keep-alive.
- `HTTP.app(handler, max_body_bytes)` reads the body whole (1 MiB unless
  given, a negative limit counts as 0) and calls the `Handler`: over the limit
  is a 413, a chunk line or trailer over the head limits a 431, a bad chunk a
  400, all closing; a cut or stalled body closes the connection.
- `target` is the request target as sent; `path` is the part before `?`. Header
  names are lowercase. `remote_addr` is the client's IP without the port
  (behind a proxy, the proxy's). An app gets no other argument: pass data
  through the request, a file or a socket.
- The server adds `Content-Length`, `Date` and `Connection: close` as needed;
  `HEAD` gets no body.
- An app's (or handler's) `error(message)`, or a response that cannot be sent
  (status outside 200 to 599, a bad header, a `Content-Length` or
  `Transfer-Encoding` header, a body with 204 or 304), sends a 500 with an empty
  body, closes the connection and writes `http: handler error: <message>` or
  `http: invalid response: <reason>` on stderr. A runtime error ends only its
  connection (the run exits 1 at the end, as for any unobserved task crash).
- `HTTP.ServerOptions()` gives a 30 s `request_timeout_ms` (each step of a
  request, not the app), a 30 s `idle_timeout_ms` between requests, 128
  connections at once (more wait) and a 1 MiB body limit. Bad requests never
  reach the app: the server answers 400, 413, 417, 431, 501 or 505 itself and
  closes.
- `close_server` closes the listener and every connection and cancels the
  apps and their spawned tasks. `wait` returns `ok()` once the server is
  closed and those tasks ended. When `main` returns, the server stops with the
  run. A server belongs to the task that called `HTTP.serve`: when that task
  ends the server closes and its port is freed, so call `serve` in the task
  that keeps the server, such as `main`.
- `shutdown` is the graceful stop (for SIGTERM: `System.subscribe`). It stops
  accepting at once, closes the idle connections, lets the requests in flight
  finish (their answers say `Connection: close`), and after `timeout_ms` closes
  what is left as `close_server` does. It returns when the server is closed.

### Reading a request body (uploads)

`body.pieces` (a `Channel[Bytes]`, pieces up to 64 KiB, never empty, chunked
bodies decoded) carries the body as it arrives.

```ruby
def store(body: HTTP.RequestBody) -> Result[HTTP.Answer]
  total = 0
  while true
    case body.pieces.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  try Task.await(body.done)
  ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: "#{total}".bytes)))
end
```

- Receive until the closed error, then `Task.await(body.done)`: only `done` says
  whether the whole body arrived (an `error`: the client left, a bad chunk, a
  timeout, past the cap). The channel holds 8 pieces, so a slow app backs up
  the socket.
- `max_body_bytes` of `HTTP.ServerOptions` (1 MiB, at most 256 MiB) caps every
  body: a larger `Content-Length` is a 413 before the app runs and before
  `100 Continue`. Raise it for uploads; `HTTP.app` keeps its own limit
  (1 MiB unless given), so a route under it that takes more raises both.
- The connection is kept only when the whole body had arrived when the app
  returned; otherwise the answer carries `Connection: close`.
- `Expect: 100-continue` within the cap gets its `100` before the app runs.
- `HTTP.read_all(body, max_bytes)` collects the body, or is an `error` (past
  `max_bytes` or the cap, a bad chunk, a cut body).
  `HTTP.body_refusal(message)` is the answer for that error, as `HTTP.app`
  gives it (413, 431 or 400, closing): a route that reads the body itself, a
  stream route say, returns `ok(HTTP.body_refusal(message))`. `HTTP.upload` is
  the client that streams to it.

### Streaming a response (SSE, tokens, big bodies)

Answer `Answer.Stream` only when a route's body is not ready at once. The
`HTTP.StreamResponse` has a `body` that is a `Channel[Bytes]`, and a task the
app started sends the pieces and closes the channel (`tasks.md`).

```ruby
def produce(events: Channel[Bytes]) -> Void
  for n in 1..3
    break if not Result.ok?(events.send("data: #{n}\n\n".bytes, 5000))
    Task.sleep(100)
  end
  events.close
end

def handle(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  events: Channel[Bytes] = Channel.new(8)
  Task.spawn(&produce, events)
  headers = [HTTP.Header(name: "Content-Type", value: "text/event-stream")]
  ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: headers, body: events)))
end
```

- The head goes out at once, then each piece as one flushed chunk, and the
  channel closing ends the body. The server sets the framing: an app that
  sets `Content-Length` or `Transfer-Encoding` gets the 500. Pieces
  are `Bytes` sent as they are; empty ones are skipped.
- `length: some(n)` is for a body of known size (a big file in pieces): the head
  has `Content-Length: n` and the pieces go out raw. A body that ends short of
  `n`, or a piece that would pass it, closes the connection, so the client sees
  an incomplete body. The body ends as soon as `n` bytes are sent: the server
  closes the channel (the producer's next `send` fails, and it stops). A closed
  body of another size, a negative length, or a length on a 204 or 304 is the
  500.
- The server reads the connection for the whole stream. When the client's input
  ends (it left, or half-closed) or a send fails, it closes the channel: the
  producer's next `send` is `error("channel: closed")`, and it must stop. A
  silent producer can read `closed?` between pieces. The client then sees the
  body as incomplete. The producer must close the channel on every path: one
  that never does holds the stream until the client leaves. A bounded channel
  is the backpressure. The connection closes after the stream.
- A slow producer is fine: no timeout runs while the server waits for a piece.
  `request_timeout_ms` bounds each piece's send, so a client that stops
  reading is cut off. HTTP/1.0 is a 505.

### WebSocket (RFC 6455) on the server

A route that upgrades answers
`ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &session)))`.
`HTTP.Upgrade` is `Accept(...)` (make it only with `accept_websocket`) or
`Reply(response)`, a whole answer for a request that is no handshake. An
upgrade needs the whole body first: an `Accept` before it arrived is a 500.

```ruby
def echo(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(60000)
      ok(message) ->
        case message
          HTTP.Message.Text(text) -> try ws.outgoing.send(HTTP.Message.Text(text), 5000)
          HTTP.Message.Close(_, _) -> return ok()
          _ -> puts("ignored")
        end
      error(_) -> return ok()
    end
  end

  ok()
end
```

- The session `Fn[HTTP.WebSocket, Result[Void]]` runs in the connection's task.
  `incoming` holds 8 messages and `outgoing` holds `outgoing_queue` (8 by
  default; the server writes what is queued in one write), both with
  backpressure. A pong waits behind what is queued, and a session that closed
  its own `outgoing` may get no pongs. A session that stops draining `incoming`
  stops the server reading the socket (no pong, no close answer): keep
  receiving, or end. A peer that stopped reading delays the `Close` until the
  write in progress ends (at most `request_timeout_ms`). `incoming` ends with
  one `Close(code, reason)`, whatever ended the connection (code 1006: no close
  frame came). Receive until `Close`, or until the closed error.
- Messages are whole (fragments joined, text UTF-8 checked); the server answers
  pings itself, a `Pong` is handed on. Sending `Close(code, reason)` starts the
  close handshake. When the session returns the server sends `Close(1000)`
  (1011 for an `error`) and closes.
- To send one message to many sockets, frame it once with
  `HTTP.prepare(HTTP.Message.Text(text))` and send the `Prepared` result on
  every `outgoing`, so it is not framed for every socket. A session never
  receives `Prepared`, but a `case` on `HTTP.Message` needs `_` or a
  `Prepared` arm.
- Frames that break RFC 6455 close the connection with 1002, 1007 or 1009; the
  cap is `max_message_bytes`.
- `accept_websocket` answers a bad handshake itself (400, or 426 for another
  version). It does not check `Origin`: compare
  `HTTP.header_values(request.headers, "origin")` before accepting when the
  server serves pages. Any other `Upgrade` (`h2c`, a `POST`) is a 501.
