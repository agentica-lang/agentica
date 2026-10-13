# TCP, TLS and HTTP

Networking uses the existing expression syntax and lightweight tasks.
`TCP`, `TLS`, `Socket`, `Listener`, `HttpClient`, `Header`, `HttpResponse`
and `HttpClientOptions` are reserved. Handles are opaque: no constructor,
equality, fields or JSON encoding; inspect prints their type in angle
brackets. Handles belong to their run and close when it ends. Network access
needs no CLI permission flag.

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
system trust (`SSL_CERT_FILE`, else the system CA bundle, plus
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
`import "std/http" as HTTP`; an `HTTP.` call without the import is
`CHECK-UNKNOWN-NAME` with a help that shows the import. There is only a
client: no HTTP server until it comes back in a later release (roadmap 20c).

```text
HTTP.client_options() -> HttpClientOptions
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.header_values(headers: List[Header], name: String) -> List[String]
```

| Record | Fields |
| --- | --- |
| Header | name: String, value: String |
| HttpResponse | status: Int, headers: List[Header], body: String |
| HttpClientOptions | timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String |

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
and no gzip decoding.

```agentica
import "std/http" as HTTP

def main() -> Void
  client = Result.unwrap!(HTTP.client(HTTP.client_options()))
  case HTTP.get(client, "http://127.0.0.1:8080/health")
    ok(response) -> puts("#{response.status} #{response.body}")
    error(message) -> IO.warn(message)
  end
  HTTP.close_client(client)
end
```

The builtin `HTTP` module of earlier releases is gone: `HTTP.client()`
becomes `HTTP.client(HTTP.client_options())`, `HTTP.text(response.body, t)`
becomes `response.body`, and `read`, `trailers`, `close_body`,
`request_stream`, the server calls and the `Request`, `Response`, `HttpBody`,
`HttpWriter`, `HttpServer` and `HttpServerOptions` types no longer exist.
Binary bodies have no replacement yet: a body that is not UTF-8 is an error.
`max_body_bytes` defaults to 1 MiB (it was 64 MiB), and `timeout_ms` covers
the whole response, not only the headers.
