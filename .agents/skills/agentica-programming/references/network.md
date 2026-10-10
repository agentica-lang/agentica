# TCP, TLS and HTTP/1.1

Networking uses the existing expression syntax and lightweight Racket tasks.
`TCP`, `TLS`, `HTTP`, `Socket`, `Listener`, `HttpClient`, `HttpServer`,
`HttpBody`, `HttpWriter`, `Header`, `Request`, `Response`,
`HttpClientOptions` and `HttpServerOptions` are reserved. Handles are opaque:
no constructor, equality, fields or JSON encoding; inspect prints their type
in angle brackets. Handles belong to their evaluation and close when it ends.
Network access needs no CLI permission flag.

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

Listen on port zero for an assigned port. TLS listeners and sockets use the
same TCP operations. TLS verifies certificates and hostnames with TLS 1.2 or
later; an empty CA path uses system trust, a nonempty path selects a PEM CA.
The server takes a PEM certificate chain and private key.

Timeouts are positive milliseconds and cover the whole operation, including
lock waits. Read and write directions have independent locks; coordinate
which task reads a stream and the order of writes. Timing out an active I/O
operation closes that socket. Waiting for a lock alone does not close it.
Failures return Results; explicit close is idempotent.

Send encodes UTF-8 and flushes. Byte values must be 0..255, at most 1 MiB per
send_bytes call. recv_bytes accepts 1..1048576, returns available data up to
that count, and returns ok([]) at EOF. TCP supplies a stream, not messages.
read_line handles fragmented UTF-8, strips LF or CRLF, accepts a final line
without a terminator, and errors on empty EOF or a line over 1 MiB.

Builtin records are immutable and use the existing named-field constructors:

| Record | Fields |
| --- | --- |
| Header | name: String, value: String |
| Request | method: String, target: String, path: String, headers: List[Header], body: HttpBody |
| Response | status: Int, headers: List[Header], body: HttpBody |
| HttpClientOptions | timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String |
| HttpServerOptions | header_timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int |

Request.target preserves the origin-form target including the query; path is
the part before `?`, with no percent decoding. Incoming header names are
lowercase. Lists preserve duplicates and order, including Set-Cookie.
Header values use the HTTP Latin-1 byte range; names must be HTTP tokens.
CR/LF injection, control characters and user-supplied framing headers are
rejected. Host is supplied by the client; Content-Length and Transfer-Encoding
are supplied by framing operations.

```text
HTTP.client_options() -> HttpClientOptions
HTTP.server_options() -> HttpServerOptions
HTTP.client() -> Result[HttpClient]
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[Response]
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[Response]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[Response]
HTTP.request_stream(client: HttpClient, method: String, url: String, headers: List[Header], length: Int, producer: Fn[A, HttpWriter, Result[Void]], argument: A) -> Result[Response]
HTTP.read(body: HttpBody, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
HTTP.text(body: HttpBody, timeout_ms: Int) -> Result[String]
HTTP.trailers(body: HttpBody) -> Result[List[Header]]
HTTP.close_body(body: HttpBody) -> Void
HTTP.header_values(headers: List[Header], name: String) -> List[String]
```

Options helpers return defaults: 30 s operation/header timeout, 30 s idle
timeout, 4 connections per client origin or 128 server connections, 64 MiB per
body, and system CA trust. Construct options records to customize them; numeric
options must be positive, and max_connections is capped at 65536.
Request acquisition, DNS, connection, TLS and response headers share one
client timeout. HTTP.wait deliberately waits until explicit close.

The pool groups connections by scheme, hostname and port. Each connection has
one active exchange. Reuse requires complete upload and complete response
consumption, including chunk terminators and trailers. Connection: close,
EOF-framed bodies, invalid framing, or abandoned bodies prevent reuse.
Closing a client closes its pool and active exchanges. A pending pool wait
may time out without affecting another exchange.

get/post/request return as soon as response headers are available. HTTP 4xx
and 5xx are normal Response values. request_stream runs a supervised producer
concurrently with response reception; length -1 uses chunked, otherwise it is
the exact byte length. Pass producer data through argument; no closures are
needed. The producer can finish with trailers; otherwise successful return
finishes automatically. An error Result aborts the exchange and appears on
the request or a subsequent body read. Producer diagnostics terminate the
evaluation with their original location.

read accepts 1..1048576 bytes and returns progress, not an entire requested
buffer. ok([]) means body EOF. text collects up to 1 MiB within one total
deadline and decodes UTF-8 strictly. Decode arbitrary streamed chunks only
after assembling complete characters. trailers requires completed consumption;
close_body abandons an unread body. Header lookup is case-insensitive.
Content encoding remains raw: there is no automatic gzip decompression.

```text
HTTP.listen(host: String, port: Int, handler: Fn[Request, HttpWriter, Void], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[Request, HttpWriter, Void], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
HTTP.begin(writer: HttpWriter, status: Int, headers: List[Header], length: Int, timeout_ms: Int) -> Result[Void]
HTTP.write(writer: HttpWriter, text: String, timeout_ms: Int) -> Result[Void]
HTTP.write_bytes(writer: HttpWriter, bytes: List[Int], timeout_ms: Int) -> Result[Void]
HTTP.finish(writer: HttpWriter, trailers: List[Header], timeout_ms: Int) -> Result[Void]
HTTP.respond(writer: HttpWriter, status: Int, headers: List[Header], text: String, timeout_ms: Int) -> Result[Void]
```

Connections run concurrently with independent evaluator contexts and one
shared step budget. Each connection processes requests sequentially. begin
starts a response with status 200..599; length -1 selects chunked. write and
write_bytes flush each part, at most 1 MiB per call. Fixed lengths must match
exactly. finish emits the final chunk/trailers or validates a fixed length.
respond combines begin/write/finish for a UTF-8 string.

HEAD suppresses response bytes; 204 and 304 have no response body. The server
supports 100 Continue and rejects unsupported expectations. It finishes a
valid response on handler return; a handler that never begins a response
gets 500 and connection close. Unconsumed request bodies close the connection.
Writers become inactive on handler/producer return. Coordinate ownership:
immutable records do not make socket operations atomic across tasks.

close_server stops acceptance, cancels handlers and nested tasks, closes all
connections and wakes wait. It is idempotent. Main return and global failure
also close services. An awaited task cancelled by resource shutdown reports
RUNTIME-TASK-CANCELLED; intentional shutdown itself is not a global failure.
BDD handlers must close services and finish tasks before returning.

HTTP/1.1 supports fixed lengths, chunked transfer, trailers and informational
responses. Ambiguous framing is rejected. Header limits are 64 KiB, 100
entries and 8 KiB per line. Body limits apply incrementally. Protocol errors
before dispatch affect only their connection; body read failures return Results.
A handler's explicit unwrap failure remains a global diagnostic.
HTTP/1.0, upgrades, proxies, automatic redirects/retries, cookie management and
a dedicated SSE API are outside this phase.
