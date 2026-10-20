# TCP, TLS and HTTP

Networking uses the existing expression syntax and lightweight tasks.
`TCP`, `TLS`, `Socket`, `Listener`, `HttpClient`, `Header`, `HttpResponse`
and `HttpClientOptions` are reserved. Handles are opaque: no constructor,
equality, fields or JSON encoding; inspect prints their type in angle
brackets. A handle belongs to the task that opened it and closes when that
task ends, or when the run ends (see `tasks.md`). A server loop gives each
accepted connection to its own task with `Task.spawn_owning(&serve, socket)`,
so a crash in that task closes only that connection; plain `Task.spawn` leaves
the socket with the loop task. Network access needs no CLI permission flag.

```text
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[Socket]
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.accept(listener: Listener, timeout_ms: Int) -> Result[Socket]
TCP.send(socket: Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.send_bytes(socket: Socket, bytes: List[Int], timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
TCP.read_line(socket: Socket, timeout_ms: Int) -> Result[String]
TCP.close(socket: Socket) -> Void
TCP.close_listener(listener: Listener) -> Void
TCP.local_port(listener: Listener) -> Int
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

Listen on port zero for an assigned port. Listen binds every address the
host resolves to, all on one port (`localhost` takes both `127.0.0.1` and
`::1` clients); addresses the system cannot use, such as IPv6 on a host
without it, are skipped. Ports are 1..65535 for connect and 0..65535 for
listen. A host containing NUL is an error. TLS listeners and sockets use the
same TCP operations. TLS verifies certificates and hostnames with TLS 1.2 or
later; there is no way to turn verification off. An empty CA path uses
system trust (`SSL_CERT_FILE`, else the system store: the CA bundle on
Linux, the Keychain trust settings on macOS, the ROOT store on Windows, with
the certificates the system distrusts rejected; read once per process; plus
`SSL_CERT_DIR`); a nonempty path is a PEM CA file that replaces system
trust, and a missing or empty file makes the connect fail. An IP address
host is checked against the certificate's IP addresses. The server takes a
PEM certificate chain and private key; a bad file or a key that does not
match fails the listen. A peer that closes without TLS's closing message
ends the stream like EOF.

Timeouts are positive milliseconds and cover the whole operation, including
lock waits. Read and write directions have independent locks; coordinate
which task reads a stream and the order of writes. Timing out an active I/O
operation closes that socket, and later calls on it fail at once with
`network: socket is closed`. Waiting for a lock alone does not close it.
Failures return Results; explicit close is idempotent.

Send encodes UTF-8 and flushes. Byte values must be 0..255, at most 1 MiB per
send_bytes call. recv_bytes accepts 1..1048576, returns available data up to
that count, and returns ok([]) at EOF. TCP supplies a stream, not messages.
read_line handles fragmented UTF-8, strips LF or CRLF, accepts a final line
without a terminator at EOF, and errors on empty EOF, on a read error (a
connection reset in the middle of a line is an error, not a line) and on a
line over 1 MiB, which also closes the socket.

## HTTP client (`std/http`)

HTTP is a library written in Agentica. Import it with
`import HTTP from "std/http"`; an `HTTP.` call without the import is
`CHECK-UNKNOWN-NAME` with a help that shows the import. It has a client
(this section) and a server (the next one).

```text
HTTP.client_options() -> HttpClientOptions
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.header_values(headers: List[Header], name: String) -> List[String]
```

- **Record:** Header
  - **Fields:** name: String, value: String

- **Record:** HttpResponse
  - **Fields:** status: Int, headers: List[Header], body: String

- **Record:** HttpClientOptions
  - **Fields:** timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int,
    max_body_bytes: Int, ca_file: String

Every call is whole: it returns after the whole response body was read, and
the body must be valid UTF-8 (at most `max_body_bytes`). `client_options()`
gives a 30 s timeout, a 30 s idle timeout, 4 connections per origin, a 1 MiB
body limit and system CA trust; options must be positive, `max_connections`
at most 65536 and `max_body_bytes` at most 64 MiB. One `timeout_ms` covers
the whole call. The client keeps idle keep-alive connections per scheme,
host and port. URLs are `http://` or `https://`; the fragment is dropped,
user info is rejected and IPv6 hosts go in brackets. The client adds `Host`
and `Content-Length`; a request that sets `Host`, `Content-Length`,
`Transfer-Encoding` or `Connection` is an error. Response header names are
lowercase; `header_values` matches names case-insensitively and keeps
duplicates in order. 4xx and 5xx are normal responses. Errors are Results:
protocol and limit errors start with `http: `, and a timeout is
`network: operation timed out`. There is no streaming, no automatic redirect
and no gzip decoding. The client's work runs as Agentica code in tasks of its
own, so it spends the `--max-steps` budget of the run.

```agentica
import HTTP from "std/http"

def main() -> Void
  client = Result.unwrap!(HTTP.client(HTTP.client_options()))
  case HTTP.get(client, "http://127.0.0.1:8080/health")
    ok(response) -> puts("#{response.status} #{response.body}")
    error(message) -> IO.warn(message)
  end
  HTTP.close_client(client)
end
```

## HTTP server (`std/http`)

```text
HTTP.server_options() -> HttpServerOptions
HTTP.listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
```

- **Record:** HttpRequest
  - **Fields:** method: String, target: String, path: String, headers:
    List[Header], body: String

- **Record:** HttpServerOptions
  - **Fields:** request_timeout_ms: Int, idle_timeout_ms: Int, max_connections:
    Int, max_body_bytes: Int

A handler takes the whole request and returns the whole response:

```agentica
import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello\n"))
  end
  return ok(HttpResponse(status: 404, headers: [], body: "not found\n"))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  puts(HTTP.local_port(server))
  IO.flush()
  HTTP.wait(server).unwrap!
end
```

`listen` (TCP) and `listen_tls` (PEM certificate and key files) return at
once and serve in the background; port 0 picks a free port, which
`local_port` returns. Each connection runs in its own task with keep-alive.
`target` is the request target as sent, `path` the part before `?`; header
names are lowercase and the body is valid UTF-8. A handler gets no other
argument: pass data to it through the request, a file or a socket. The
server adds `Content-Length` (not on 204 and 304, which need an empty
body), `Date` unless the handler set it, and `Connection: close` when the
request or the response asked for it; `HEAD` gets no body. A handler
`error(message)`, or a response that cannot be sent (status outside 200 to
599, a bad header, a `Content-Length` or `Transfer-Encoding` header, a body
with 204 or 304), sends a 500 with an empty body, closes the connection and
writes `http: handler error: <message>` or `http: invalid response:
<reason>` on stderr. A runtime error in a handler ends only its
connection (the client sees a close; the run exits 1 at the end as for any
unobserved task crash). Handlers have no time limit.

`server_options()` gives a 30 s `request_timeout_ms` (the first byte of a
connection's first request, then each whole request from its first byte,
then the write of each response from the handler's return), a 30 s
`idle_timeout_ms` (between requests on one connection), 128 connections at
once (more wait) and a 1 MiB body limit, with the client's option checks.
Bad requests never reach the handler: the server answers 400, 413, 417,
431, 501 or 505 itself and closes. `close_server` closes the listener and
every connection and cancels the handlers and the tasks they spawned;
`wait` returns `ok()` once the server is closed. When `main` returns, the
server stops with the run. A server belongs to the task that called
`HTTP.listen`: when that task ends (it returns, crashes or is cancelled), the
server is closed and its port is free, so call `listen` in the task that keeps
the server, such as `main`.

Earlier releases' `HTTP` API is gone, and the checker's help names the
replacement for each name. `HTTP.client()` is
`HTTP.client(HTTP.client_options())`; `HTTP.text(response.body, t)` is
`response.body`; `read`, `trailers`, `close_body`, and `request_stream` no
longer exist. A handler takes an `HttpRequest` and returns
`ok(HttpResponse(...))` instead of calling `HTTP.respond(writer, ...)`.
`HTTP.begin`, `write`, `write_bytes`, and `finish` are gone.
`HttpServerOptions.header_timeout_ms` is now `request_timeout_ms`. The
`Request`, `Response`, `HttpBody`, and `HttpWriter` types are gone. Binary
bodies have no replacement yet: a body that is not UTF-8 is an error.
`max_body_bytes` defaults to 1 MiB (it was 64 MiB), and `timeout_ms` covers the
whole response, not only the headers.
