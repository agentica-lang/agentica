# TCP, TLS and HTTP

`TCP`, `TLS`, `Socket`, `Listener`, `HttpClient`, `Header`, `HttpResponse` and
`HttpClientOptions` are reserved. Handles are opaque (no constructor, equality,
fields or JSON); inspect prints their type in angle brackets. A handle belongs
to the task that opened it and closes when that task or the run ends
(`tasks.md`). A server loop gives each connection its own task with
`Task.spawn_owning(&serve, socket)`, so a crash closes only that connection.

No flag is needed for network access. With `--deny-net` (or `--sandbox`) every
connect and listen, `std/http` included, returns an error starting `denied:
--deny-net` before any DNS lookup. With `--deny-fs`, a TLS call that names a
file returns `denied: --deny-fs`.

```text
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[Socket]
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.accept(listener: Listener, timeout_ms: Int) -> Result[Socket]
TCP.send(socket: Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.send_bytes(socket: Socket, bytes: Bytes, timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[Bytes]
TCP.read_line(socket: Socket, timeout_ms: Int) -> Result[String]
TCP.close(socket: Socket) -> Void
TCP.close_listener(listener: Listener) -> Void
TCP.local_port(listener: Listener) -> Int
TLS.client_context(options: TlsClientOptions) -> Result[TlsContext]
TLS.server_context(options: TlsServerOptions) -> Result[TlsContext]
TLS.connect(host: String, port: Int, context: TlsContext, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, context: TlsContext) -> Result[Listener]

TlsClientOptions(ca_file: String = "", cert_file: String = "", key_file: String = "")
TlsServerOptions(cert_file: String, key_file: String)
```

- A `TlsContext` is the TLS setup of one role, built once (the PEM files are
  read and checked then) and shared by every socket, listener and HTTP client
  made from it. A file changed later needs a new context. `TLS.connect` takes a
  client context and `TLS.listen` a server one; the other role is
  `RUNTIME-TLS-CONTEXT-ROLE`.
- TLS listeners and sockets use the same TCP calls (`TCP.accept`, `TCP.send`,
  `TCP.recv_bytes`, `TCP.read_line`, `TCP.close`, `TCP.close_listener`,
  `TCP.local_port`); only `TLS.connect` and `TLS.listen` differ.
- Port 0 on listen picks an assigned port. Listen binds every address the host
  resolves to, on one port (`localhost` takes `127.0.0.1` and `::1`); addresses
  the system cannot use are skipped. Ports are 1..65535 to connect and 0..65535
  to listen. A host with NUL is an error.
- TLS (1.2 or later) verifies certificates and hostnames; verification cannot be
  turned off. An empty `ca_file` uses system trust: `SSL_CERT_FILE`, else the
  platform store (the CA bundle on Linux; the Security roots and Keychain trust
  on macOS; the ROOT store on Windows, whose CA-store intermediates are never
  trusted as roots and distrusted certificates are rejected), read once per
  process, plus `SSL_CERT_DIR`. A nonempty one is a PEM CA file that replaces
  system trust; a missing or empty file fails `TLS.client_context`. An IP
  address host is checked against the certificate's IP addresses.
- A server context takes a PEM certificate chain and key; a bad file or
  mismatched key fails `TLS.server_context`. A client context sends a client
  certificate when `cert_file` and `key_file` name the same PEM forms (both
  empty: none; only one: an error). A peer that closes without TLS's closing
  message ends the stream like EOF. TLS behaves the same on Linux, macOS and
  Windows.
- Timeouts are positive milliseconds and cover the whole operation, lock waits
  included. Reads and writes have independent locks: coordinate which task
  reads and the order of writes. A timeout during active I/O closes the socket
  (later calls fail at once with `network: socket is closed`); one only waiting
  for the lock does not. Failures are Results; close is idempotent.
- Send encodes UTF-8 and flushes; `send_bytes` takes a `Bytes` of at most 1 MiB.
  `recv_bytes` accepts 1..1048576 and returns the available data up to that
  count as `Bytes`, empty at EOF. TCP is a stream, not messages.
- `read_line` handles fragmented UTF-8, strips LF or CRLF and accepts a final
  unterminated line at EOF. It errors on an empty EOF, on a read error (a reset
  mid-line is an error, not a line) and on a line over 1 MiB, which also closes
  the socket.

## HTTP client (`std/http`)

HTTP is an Agentica library: `import HTTP from "std/http"`. Without it, `HTTP.`
calls are `CHECK-UNKNOWN-NAME` and the help shows the import. Client and server
behave the same on Linux, macOS and Windows, over HTTP and HTTPS.

```text
HTTP.client(options: HttpClientOptions = HttpClientOptions()) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
HTTP.get_response(url: String, options: HttpClientOptions = HttpClientOptions()) -> Result[HttpResponse]
HTTP.post_response(url: String, body: Bytes, headers: List[Header] = [], options: HttpClientOptions = HttpClientOptions()) -> Result[HttpResponse]
HTTP.text(body: Bytes, headers: List[Header] = []) -> Result[String]
HTTP.header_values(headers: List[Header], name: String) -> List[String]
HTTP.download(client: HttpClient, url: String, path: String, options: DownloadOptions = DownloadOptions()) -> Result[Download]
HTTP.start(origin: String, options: HttpClientOptions = HttpClientOptions()) -> Result[HTTP.Connection]
HTTP.send_request(conn: HTTP.Connection, method: String, target: String, body: Bytes, headers: List[Header] = []) -> Result[HTTP.ResponseHead]
HTTP.read_body(conn: HTTP.Connection, max_bytes: Int = 65536) -> Result[Bytes]
HTTP.finish(conn: HTTP.Connection) -> Void
HTTP.open(method: String, url: String, body: Bytes, headers: List[Header] = [], options: HttpClientOptions = HttpClientOptions()) -> Result[HTTP.Stream]
HTTP.upload(method: String, url: String, body: Channel[Bytes], length: Int = -1, headers: List[Header] = [], options: HttpClientOptions = HttpClientOptions()) -> Result[HttpResponse]

Header(name: String, value: String)
HttpResponse(status: Int, headers: List[Header], body: Bytes)
DownloadOptions(timeout_ms: Int = 30000, max_total_bytes: Int = 268435456)
Download(status: Int, headers: List[Header], bytes_written: Int)
HttpClientOptions(timeout_ms: Int = 30000, idle_timeout_ms: Int = 30000, max_connections: Int = 4, max_body_bytes: Int = 1048576, tls: Optional[TlsContext] = none)
```

- Every call is whole: it returns after the full body is read, as `Bytes` of at
  most `max_body_bytes`, with any content. `HttpClientOptions()`, the default,
  gives a 30 s timeout, a 30 s idle timeout, 4 connections per origin, a 1 MiB
  body limit and system CA trust (`tls: some(context)` takes a client context
  instead). Options must be positive; `max_connections` is
  at most 65536 and `max_body_bytes` at most 64 MiB. One `timeout_ms` covers the
  whole call.
- One connection that you drive yourself (Ruby's `Net::HTTP.start`):
  `HTTP.start(origin)` connects (an origin with no path),
  `HTTP.send_request(conn, method, target, body)` returns at the response head
  (`status`, `headers`), `HTTP.read_body(conn, max_bytes)` gives the body
  piece by piece and an empty `Bytes` at its end, `HTTP.finish(conn)` closes.
  After a body read to its end (a response with no body is at its end at once)
  the same connection takes the next request, unless the server closed it or
  sent input after the body. Use it for a body read as it arrives (up to 256
  MiB) or for control of the socket; whole responses use `get` or the client.
  `timeout_ms` of the options is the time of each call and nothing is retried.
  One call at a time, in the task that opened it.
- One request: `HTTP.get_response(url)` and `HTTP.post_response(url, body)` make
  a client of their own, send it and close it before they return (Ruby's
  `Net::HTTP.get_response`). Many requests: one `HTTP.client()` with `get`,
  `post` and `request`. Over HTTPS each `get_response` also builds a new TLS
  context and loads the CA bundle, so many calls belong on one client.
- A body on a channel, on a connection of its own: `HTTP.open(method, url,
  body)` returns at the head as `HTTP.Stream(status, headers, body, done)`. Read
  `stream.body` (a `Channel[Bytes]`, pieces up to 64 KiB) until the closed
  error, then `Task.await(stream.done)`: only `done` tells a whole body from a
  cut one (a timeout, a body over 256 MiB). Close `body` to stop early (`done`
  is then `error("channel: closed")`) while data flows; on a quiet stream the
  prompt stop is `Task.cancel(stream.done)`. `HTTP.upload(method, url,
  body_channel, length)` sends the pieces another task puts in the channel, as
  chunks until it closes (`length` -1, the default) or with an exact `length`,
  which ends the body at that many bytes, and returns the whole response;
  `POST`, `PUT` or `PATCH` only. A server that answers 413 and closes mid-upload
  still gives its response (on Windows a reset can drop it, and the write error
  is returned). `timeout_ms` is the time of each wait (connect, head, each read,
  each channel step). A producer that can fail should set `length`, since a
  closed channel is a clean end.
- The client keeps idle keep-alive connections per scheme, host and port. URLs
  are `http://` or `https://`; the fragment is dropped, user info is rejected
  and IPv6 hosts go in brackets. It adds `Host` and `Content-Length`; a request
  that sets `Host`, `Content-Length`, `Transfer-Encoding` or `Connection` is an
  error.
- Response header names are lowercase; `header_values` matches
  case-insensitively and keeps duplicates in order. 4xx and 5xx are normal
  responses. Errors are Results: protocol and limit errors start with `http: `,
  a timeout is `network: operation timed out`. No streaming (see `HTTP.start`),
  automatic redirect or gzip decoding. The client runs as Agentica code in tasks
  of its own, so it spends the run's `--max-steps` budget.
- `download` streams a `GET` body to a new file instead of `Bytes`, for
  binary-safe bodies up to 256 MiB: at most 1 MiB is held at once, every
  framing (`Content-Length`, chunked, close-delimited) counts against
  `max_total_bytes`, and the file never grows past it. The file must not
  exist (`create_private`, so an existing path fails untouched) and a failed
  download keeps the partial file. 4xx and 5xx still return `ok` with their
  status and written body, without redirect follow; the connection is not
  pooled. `DownloadOptions()`, the default, gives 30 s and 256 MiB.
- A body is `Bytes`: send text as `"...".bytes` (no body: `"".bytes`) and read
  it with `HTTP.text(response.body, response.headers)`, which decodes the
  `charset` of `Content-Type` (UTF-8 without one) when `b.decode` knows it
  (UTF-8, UTF-16, UTF-32, ASCII, Latin-1, ISO-8859-15, Windows-1252); a body
  invalid in its charset, or another charset, is an error (other charsets: the
  planned `agentica-lang/charset` package). `HttpResponse` is not JSON
  encodable. The body of a request in a server handler is `Bytes` too:
  `HTTP.text(request.body, request.headers)`.
- Names that do not exist: `response.text`, `header_timeout_ms`
  (`request_timeout_ms`), and `read`, `trailers`, `close_body`,
  `request_stream` (one whole `HTTP.request`).

## HTTP server (`std/http`)

```text
HTTP.listen(host: String, port: Int, handler: HTTP.Handler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.Handler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void

HTTP.listen_stream(host: String, port: Int, handler: HTTP.StreamHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_stream_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.StreamHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_upload(host: String, port: Int, handler: HTTP.UploadHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_upload_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.UploadHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.RequestBody(pieces: Channel[Bytes], done: Task[Result[Void]])
HTTP.read_all(body: HTTP.RequestBody, max_bytes: Int) -> Result[Bytes]
HTTP.whole(data: Bytes) -> Channel[Bytes]
HTTP.listen_websocket(host: String, port: Int, handler: HTTP.UpgradeHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_websocket_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.UpgradeHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.accept_websocket(request: HttpRequest, session: HTTP.WebSocketSession, options: HTTP.WebSocketOptions = HTTP.WebSocketOptions()) -> Result[HTTP.Upgrade]
HTTP.upgrade_only(handler: HTTP.Handler) -> HTTP.UpgradeHandler
HTTP.WebSocket(incoming: Channel[HTTP.Message], outgoing: Channel[HTTP.Message], protocol: String)
HTTP.Message: Text(String), Binary(Bytes), Ping(Bytes), Pong(Bytes), Close(Int, String)
HTTP.WebSocketOptions(max_message_bytes: Int = 1048576, idle_ms: Int = 0, ping_ms: Int = 0, close_ms: Int = 5000, protocols: List[String] = [])

HttpRequest(method: String, target: String, path: String, headers: List[Header], body: Bytes)
HTTP.StreamResponse(status: Int, headers: List[Header], body: Channel[Bytes], length: Optional[Int] = none)
HttpServerOptions(request_timeout_ms: Int = 30000, idle_timeout_ms: Int = 30000, max_connections: Int = 128, max_body_bytes: Int = 1048576)
```

A handler takes the whole request and returns the whole response:

```ruby
import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello\n".bytes))
  end

  return ok(HttpResponse(status: 404, headers: [], body: "not found\n".bytes))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle).unwrap!
  puts(HTTP.local_port(server))
  IO.flush()
  HTTP.wait(server).unwrap!
end
```

- `HTTP.Handler` and `HTTP.StreamHandler` are aliases of the handler types
  `Fn[HttpRequest, Result[HttpResponse]]` and
  `Fn[HttpRequest, Result[HTTP.StreamResponse]]`. A middleware is a function
  `Handler -> Handler` that calls `next.call(request)` or answers itself. A
  block cannot be returned directly, so a helper
  `def handler(f: HTTP.Handler) -> HTTP.Handler` turns
  `handler() do |request| step(next, request) end` into the value; keep the
  block to one call and put the work in the named `step`. Stack them by calling
  one with another's result: `logged(guarded(&hello))`.
- `listen` (TCP) and `listen_tls` (a server `TlsContext`) return at once
  and serve in the background. Port 0 picks a free port, which `local_port`
  returns. Each connection runs in its own task, with keep-alive.
- `target` is the request target as sent; `path` is the part before `?`. Header
  names are lowercase and the body is `Bytes`, as the client sent it. A handler
  gets no other argument: pass data through the request, a file or a socket.
- The server adds `Content-Length` (not on 204 and 304, which need an empty
  body), `Date` unless the handler set it, and `Connection: close` when asked;
  `HEAD` gets no body.
- A handler's `error(message)`, or a response that cannot be sent (status
  outside 200 to 599, a bad header, a `Content-Length` or `Transfer-Encoding`
  header, a body with 204 or 304), sends a 500 with an empty body, closes the
  connection and writes `http: handler error: <message>` or `http: invalid
  response: <reason>` on stderr. A runtime error ends only its connection (the
  client sees a close; the run exits 1 at the end, as for any unobserved task
  crash). Handlers have no time limit.
- `HttpServerOptions()`, the default, gives a 30 s `request_timeout_ms` (first
  byte of the first request; then each whole request from its first byte; then
  each response write from the handler's return), a 30 s `idle_timeout_ms`
  between requests, 128 connections at once (more wait) and a 1 MiB body limit,
  with the client's checks. Bad requests never reach the handler: the server
  answers 400, 413, 417, 431, 501 or 505 itself and closes.
- `close_server` closes the listener and every connection and cancels the
  handlers and their spawned tasks. `wait` returns `ok()` once the server is
  closed and those tasks ended. When `main` returns, the server stops with the
  run. A server belongs to the task that called `HTTP.listen`: when that task
  ends the server closes and its port is freed, so call `listen` in the task
  that keeps the server, such as `main`.

### Streaming a response (SSE, tokens, big bodies)

Use `listen_stream` only when a route's body is not ready at once; otherwise
`listen`. The handler returns an `HTTP.StreamResponse` whose `body` is a
`Channel[Bytes]`, and a task it started sends the pieces and closes the channel
(`tasks.md`). Every route of a `listen_stream` server returns one, and a route
with one text uses `body: HTTP.whole("text".bytes)`.

```ruby
def produce(events: Channel[Bytes]) -> Void
  for n in 1..3
    if not Result.ok?(events.send("data: #{n}\n\n".bytes, 5000))
      break
    end
    Task.sleep(100)
  end
  events.close
end

def handle(request: HttpRequest) -> Result[HTTP.StreamResponse]
  events: Channel[Bytes] = Channel.new(8)
  Task.spawn(&produce, events)
  headers = [Header(name: "Content-Type", value: "text/event-stream")]
  return ok(HTTP.StreamResponse(status: 200, headers: headers, body: events))
end
```

- The head goes out at once, then each piece as one flushed chunk, and the
  channel closing ends the body. The server sets the framing: a handler that
  sets `Content-Length` or `Transfer-Encoding` gets the 500 of `listen`. Pieces
  are `Bytes` sent as they are (a file or binary data works); empty ones are
  skipped. A body already closed when the handler returns goes out
  with `Content-Length`.
- `length: some(n)` is for a body of known size (a big file in pieces): the head
  has `Content-Length: n` and the pieces go out raw. A body that ends short of
  `n`, or a piece that would pass it, closes the connection, so the client sees
  an incomplete body. The body ends as soon as `n` bytes are sent, without
  waiting for the producer to close: the server closes the channel (the
  producer's next `send` fails, and it stops) and the connection serves the next
  request. A closed body of another size, a negative length, or a length on a
  204 or 304 is the 500 of `listen`.
- The server reads the connection for the whole stream. When the client's input
  ends (it left, or half-closed) or a send fails, it closes the channel: the
  producer's next `send` is `error("channel: closed")`, and it must stop. A
  silent producer can read `closed?` between pieces, which is `true` as soon as
  the server closes the channel. The body is then cut without its last chunk, so
  the client sees it as incomplete. The producer must close the channel on every
  path: one that never does holds the stream until the client leaves. A bounded
  channel is the backpressure. Bytes the client sends during the stream (a
  pipelined request) are dropped, and the connection closes after the stream.
- A slow producer is fine: no timeout runs while the server waits for a piece
  (`idle_timeout_ms` counts between requests). `request_timeout_ms` bounds each
  piece's send, so a client that stops reading is cut off. `HEAD` gets the head
  and closes the channel. HTTP/1.0 is the 505 of `listen`.
- The client side does not stream: `HTTP.get` waits for the whole body.

### Reading a request body as it arrives (big uploads)

`listen` reads the whole body first (at most `max_body_bytes`). For an upload
too big to hold, use `listen_upload`: the handler is
`Fn[HttpRequest, HTTP.RequestBody, Result[HttpResponse]]`
(`HTTP.UploadHandler`), `request.body` is empty, and `body.pieces` (a
`Channel[Bytes]`, pieces up to 64 KiB, never empty, chunked bodies decoded)
carries the body.

```ruby
def save(request: HttpRequest, body: HTTP.RequestBody) -> Result[HttpResponse]
  total = 0
  while true
    case body.pieces.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  try Task.await(body.done)
  return ok(HttpResponse(status: 200, headers: [], body: "#{total}".bytes))
end
```

- Receive until the closed error, then `Task.await(body.done)`: only `done` says
  whether the whole body arrived (an `error`: the client left, a bad chunk, a
  timeout). The channel holds 8 pieces, so a slow handler backs up the socket.
- `max_body_bytes` does not apply; the body is at most 256 MiB, and a handler
  that wants less counts bytes and answers 413. `request_timeout_ms` is the wait
  of each step, not of the whole upload.
- The connection serves the next request only when the whole body had arrived
  when the handler returned; otherwise the answer carries `Connection: close`
  and the connection closes after it.
- `Expect: 100-continue` gets its `100` before the handler runs: a handler
  cannot refuse an upload before the body is sent.
- `HTTP.read_all(body, max_bytes)` collects the body (an `error` past
  `max_bytes`, or when `done` is an error), so one `listen_upload` server can
  serve its small routes simply.
- The response is whole. `HTTP.upload` is the client that streams to it.

### WebSocket (RFC 6455) on the server

`listen_websocket` is `listen` plus upgrades: the handler is
`HTTP.UpgradeHandler`, `Fn[HttpRequest, Result[HTTP.Upgrade]]`. It returns
`HTTP.accept_websocket(request, &session)` for a route that upgrades, and
`HTTP.upgrade_only(&handler).call(request)` for a plain one
(`Upgrade.Reply(response)`).

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

  return ok()
end
```

- The session `Fn[HTTP.WebSocket, Result[Void]]` runs in the connection's task.
  `incoming` and `outgoing` hold 8 messages (backpressure), and a session that
  stops draining `incoming` stops the server reading the socket (no pong, no
  close answer): keep receiving, or end. `incoming` ends with
  one `Close(code, reason)`, whatever ended the connection (code 1006: no close
  frame came); then it closes. Receive until `Close`, or until the closed error.
- Messages are whole: fragments are joined, text is UTF-8 checked, pings are
  answered by the server (not handed on), a `Pong` is handed on. Sending
  `Close(code, reason)` starts the close handshake. When the session returns the
  server sends `Close(1000)` (1011 for an `error`), waits for the peer, closes.
- Frames that break RFC 6455 close the connection with 1002, 1007 or 1009; the
  cap is `max_message_bytes`. `idle_ms`, `ping_ms`, `close_ms` and `protocols`
  are in `HTTP.WebSocketOptions`.
- `accept_websocket` answers a bad handshake itself (400, or 426 for another
  version). It does not check `Origin`: compare
  `HTTP.header_values(request.headers, "origin")` before accepting when the
  server serves pages. The other `listen` forms answer an `Upgrade` 501.
- Unmasking runs at about 7 MB/s: keep `max_message_bytes` small.
