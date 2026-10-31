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
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int, cert_file: String = "", key_file: String = "") -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

- TLS listeners and sockets use the same TCP calls (`TCP.accept`, `TCP.send`,
  `TCP.recv_bytes`, `TCP.read_line`, `TCP.close`, `TCP.close_listener`,
  `TCP.local_port`); only `TLS.connect` and `TLS.listen` differ.
- Port 0 on listen picks an assigned port. Listen binds every address the host
  resolves to, on one port (`localhost` takes `127.0.0.1` and `::1`); addresses
  the system cannot use are skipped. Ports are 1..65535 to connect and 0..65535
  to listen. A host with NUL is an error.
- TLS (1.2 or later) verifies certificates and hostnames; verification cannot be
  turned off. An empty CA path uses system trust: `SSL_CERT_FILE`, else the
  platform store (the CA bundle on Linux; the Security roots and Keychain trust
  on macOS; the ROOT store on Windows, whose CA-store intermediates are never
  trusted as roots and distrusted certificates are rejected), read once per
  process, plus `SSL_CERT_DIR`. A nonempty path is a PEM CA file that replaces
  system trust; a missing or empty file fails the connect. An IP address host is
  checked against the certificate's IP addresses.
- The server takes a PEM certificate chain and key; a bad file or mismatched key
  fails the listen. `TLS.connect` sends a client certificate when `cert_file`
  and `key_file` name the same PEM forms (both empty: none; only one: an error),
  and a bad file or mismatched key fails the connect. A peer that closes
  without TLS's closing message ends the stream like EOF. TLS behaves the same
  on Linux, macOS and Windows.
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
HTTP.client_options() -> HttpClientOptions
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
HTTP.text(body: Bytes, headers: List[Header] = []) -> Result[String]
HTTP.header_values(headers: List[Header], name: String) -> List[String]
HTTP.download_options() -> DownloadOptions
HTTP.download(client: HttpClient, url: String, path: String, options: DownloadOptions) -> Result[Download]

Header(name: String, value: String)
HttpResponse(status: Int, headers: List[Header], body: Bytes)
DownloadOptions(timeout_ms: Int = 30000, max_total_bytes: Int = 268435456)
Download(status: Int, headers: List[Header], bytes_written: Int)
HttpClientOptions(timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String)
```

- Every call is whole: it returns after the full body is read, as `Bytes` of at
  most `max_body_bytes`, with any content. `client_options()` gives a 30 s timeout,
  a 30 s idle timeout, 4 connections per origin, a 1 MiB body limit and system
  CA trust. Options must be positive; `max_connections` is at most 65536 and
  `max_body_bytes` at most 64 MiB. One `timeout_ms` covers the whole call.
- The client keeps idle keep-alive connections per scheme, host and port. URLs
  are `http://` or `https://`; the fragment is dropped, user info is rejected
  and IPv6 hosts go in brackets. It adds `Host` and `Content-Length`; a request
  that sets `Host`, `Content-Length`, `Transfer-Encoding` or `Connection` is an
  error.
- Response header names are lowercase; `header_values` matches
  case-insensitively and keeps duplicates in order. 4xx and 5xx are normal
  responses. Errors are Results: protocol and limit errors start with `http: `,
  a timeout is `network: operation timed out`. No streaming, automatic redirect
  or gzip decoding. The client runs as Agentica code in tasks of its own, so it
  spends the run's `--max-steps` budget.
- `download` streams a `GET` body to a new file instead of `Bytes`, for
  binary-safe bodies up to 256 MiB: at most 1 MiB is held at once, every
  framing (`Content-Length`, chunked, close-delimited) counts against
  `max_total_bytes`, and the file never grows past it. The file must not
  exist (`create_private`, so an existing path fails untouched) and a failed
  download keeps the partial file. 4xx and 5xx still return `ok` with their
  status and written body, without redirect follow; the connection is not
  pooled. `DownloadOptions()` and `download_options()` give 30 s and 256 MiB.
- A body is `Bytes`: send text as `"...".bytes` (no body: `"".bytes`) and read
  it with `HTTP.text(response.body, response.headers)`, which decodes UTF-8
  only: a `charset` in `Content-Type` other than `utf-8`, or a body that is not
  valid UTF-8, is an error (`us-ascii` counts as `utf-8`; other charsets: the
  planned `agentica-lang/charset` package). `HttpResponse` is not JSON
  encodable. The body of a request in a server handler is `Bytes` too:
  `HTTP.text(request.body, request.headers)`.
- Names that do not exist: `HTTP.client()` (write
  `HTTP.client(HTTP.client_options())`), `response.text`, `header_timeout_ms`
  (`request_timeout_ms`), and `read`, `trailers`, `close_body`,
  `request_stream` (one whole `HTTP.request`).

## HTTP server (`std/http`)

```text
HTTP.server_options() -> HttpServerOptions
HTTP.listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void

HTTP.listen_stream(host: String, port: Int, handler: Fn[HttpRequest, Result[HTTP.StreamResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_stream_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HTTP.StreamResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.whole(data: Bytes) -> Channel[Bytes]

HttpRequest(method: String, target: String, path: String, headers: List[Header], body: Bytes)
HTTP.StreamResponse(status: Int, headers: List[Header], body: Channel[Bytes])
HttpServerOptions(request_timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int)
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
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  puts(HTTP.local_port(server))
  IO.flush()
  HTTP.wait(server).unwrap!
end
```

- `listen` (TCP) and `listen_tls` (PEM certificate and key files) return at once
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
- `server_options()` gives a 30 s `request_timeout_ms` (first byte of the first
  request; then each whole request from its first byte; then each response write
  from the handler's return), a 30 s `idle_timeout_ms` between requests, 128
  connections at once (more wait) and a 1 MiB body limit, with the client's
  checks. Bad requests never reach the handler: the server answers 400, 413,
  417, 431, 501 or 505 itself and closes.
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
- The server reads the connection for the whole stream. When the client's input
  ends (it left, or half-closed) or a send fails, it closes the channel: the
  producer's next `send` is `error("channel: closed")`, and it must stop.
  `closed?` is `true` for a silent producer once the pieces already sent were
  taken. The body is then cut without its last chunk, so the client sees it as
  incomplete. The producer must close the channel on every path: one that never
  does holds the stream until the client leaves. A bounded channel is the
  backpressure. Bytes the client sends during the stream (a pipelined request)
  are dropped, and the connection closes after the stream.
- A slow producer is fine: no timeout runs while the server waits for a piece
  (`idle_timeout_ms` counts between requests). `request_timeout_ms` bounds each
  piece's send, so a client that stops reading is cut off. `HEAD` gets the head
  and closes the channel. HTTP/1.0 is the 505 of `listen`.
- The client side does not stream: `HTTP.get` waits for the whole body.
