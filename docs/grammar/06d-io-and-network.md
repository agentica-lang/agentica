### TCP, TLS and HTTP

Networking uses the existing expression syntax and lightweight tasks. `TCP`,
`TLS`, `HttpWire`, `Socket`, `Listener`, `HttpClient`, `HttpServer`, `Header`,
`HttpRequest`, `HttpResponse`, `HttpClientOptions` and `HttpServerOptions` are
reserved; `HTTP` is not, since it is the import alias of `std/http` (below,
"HTTP client and server (`std/http`)"). Handles are opaque: no constructor,
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
system trust (the file in `SSL_CERT_FILE`, else the system CA bundle, and
the directories in `SSL_CERT_DIR`); a nonempty path selects a PEM CA file
that replaces system trust, and a missing or empty file makes the connect
fail. A host that is an IP address is checked against the certificate's IP
addresses. The server takes a PEM certificate chain and private key; a bad
file or a key that does not match fails the listen. A peer that closes
without TLS's closing message ends the stream like EOF, so the protocol on
top must detect a cut message.

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

Builtin records are immutable and use the existing named-field constructors:

| Record | Fields |
| --- | --- |
| Header | name: String, value: String |
| HttpRequest | method: String, target: String, path: String, headers: List[Header], body: String |
| HttpResponse | status: Int, headers: List[Header], body: String |
| HttpClientOptions | timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String |
| HttpServerOptions | request_timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int |

Header values use the HTTP Latin-1 byte range; names must be HTTP tokens.
CR/LF injection, control characters and user-supplied framing headers are
rejected.

#### HTTP client and server (`std/http`)

HTTP is the `std/http` library, imported with `import "std/http" as HTTP`
(`HTTP` is the documented alias; any other alias works too). It has a
client and a server.

The `HTTP` client functions (`std/http`) are in [`network.md`](../../site/content/library/network.md).

Every call is whole: it returns after the whole body was read, and
the body must be valid UTF-8. `client_options()` gives a 30 s timeout, a 30 s
idle timeout, 4 connections per origin, a 1 MiB body limit and system CA
trust; options must be positive, `max_connections` at most 65536 and
`max_body_bytes` at most 64 MiB. One `timeout_ms` covers the whole call:
the wait for a pooled connection, DNS, connect, the TLS handshake, the
request and the whole response. The client keeps idle keep-alive connections
per scheme, host and port, and calls wait in FIFO order for one of the
`max_connections` slots. `close_client` closes them; a call in flight then
fails with "http: client is closed". A `GET`, `HEAD`, `OPTIONS`, `PUT` or
`DELETE` sent on a reused keep-alive connection that the server had
already closed is retried once on a new connection, within the same
timeout, when no byte of a response arrived; `POST`, `PATCH` and other
methods are never retried and return the error.

URLs are `http://` or `https://` with a host, an optional port (1..65535) and
an optional path and query; the fragment is dropped, user info is rejected and
IPv6 hosts go in brackets. The client adds `Host` and, when there is a body or
the method is `POST`, `PUT` or `PATCH`, `Content-Length`; a request that sets
`Host`, `Content-Length`, `Transfer-Encoding` or `Connection` itself is an
error. Response header names are lowercase. 4xx and 5xx are normal responses.
A response must be `HTTP/1.1` with a status of 100 to 599; at most 15 interim
responses are skipped and a 101 is an error. A chunked or close-delimited
response body is decoded whole, its trailers are checked and dropped, and
`Content-Encoding` stays raw (no gzip). A bad options record is an error
Result. Protocol and limit errors start with `http: `; connection errors keep
the TCP and TLS texts (`tcp-connect: ...`, `ssl-connect: ...`, `error reading
from stream port`, `error writing to stream port`), and a timeout is `network:
operation timed out`. A bracketed host must be an IPv6 literal (hex digits,
`:` and `.`). `std/http` calls the internal module `HttpWire`, which no other
module can name (`CHECK-UNKNOWN-NAME`).

The `HTTP` server functions are in the same page.

A complete program is in [`examples/http_server.agc`](../../examples/http_server.agc).

`listen` opens a TCP listener (port 0 picks a free port, which `local_port`
returns) and `listen_tls` a TLS one from PEM files, then serve in the
background: each connection runs in its own task, which reads a request, calls
the handler, writes its response and, with keep-alive, reads the next one. The
handler gets a whole request (an `HttpRequest`, with the fields in the table
above), where `target` is the request target as sent, `path` is the part
before `?`, header names are lowercase and the body is valid UTF-8. It returns
a whole `HttpResponse`; the server adds `Content-Length` (except on 204 and
304, which must have an empty body), `Date` unless the handler set it, and
`Connection: close` when either side asked for it, and sends no body for
`HEAD` (whose `Content-Length` is that of the body it would have sent). A
handler that returns `error(message)`, or a response that cannot be sent (a
status outside 200 to 599, a bad header, a `Content-Length` or
`Transfer-Encoding` header, a body with 204 or 304), gives the client a 500
with an empty body and closes the connection; stderr gets one line, `http:
handler error: <message>` or `http: invalid response: <reason>`. The handler
has no time limit. A runtime error in a handler crashes its connection task:
the client sees the connection close, the server goes on, and the run reports
the crash as any task crash (it exits 1 at the end unless something observed
it).

`server_options()` gives 30 s request and idle timeouts, 128 connections and 1
MiB bodies, with the client's option checks. `request_timeout_ms` bounds the
wait for the first byte of a connection's first request, then the rest of each
request from its first byte, and, from the handler's return, the write of its
response; `idle_timeout_ms` bounds the wait for a later request on a
kept-alive connection. At most `max_connections` connections are served at
once; more wait in the listener's backlog. Requests the server rejects before
the handler runs get an empty answer and a close; the status for each case
(400, 413, 417, 431, 501 or 505) is in [`docs/vm/10-io-http.md`
§10.7.3](../vm/10-io-http.md#1073-errors-and-status-codes). `wait` returns
`ok()` once the server is closed. `close_server` closes the listener, ends
every connection, and cancels the handlers and every task they spawned; it is
idempotent. When `main` returns, the run ends whatever the server is doing. If
the client leaves while the response is written, the connection closes
quietly.

### Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. File handles
are opaque, belong to one evaluation, and close when it ends. The interpreter
uses the host user's filesystem permissions; there is no filesystem permission
flag. File operations accept regular files and symlinks to regular files, and
reject directories and special files.

The signatures of `File`, `Dir` and `Path` are in `agentica help NAME --json` and in [`site/content/library/files.md`](../../site/content/library/files.md).

`File.open` modes are `read`, `write` and `append`. Read requires an existing
regular file; write creates or truncates; append creates or appends. Text is
strict UTF-8. Whole-text helpers and each stream read/write are limited to
1 MiB; `read_bytes` takes 1..1048576 bytes and returns `ok([])` at EOF.
`read_line` removes LF or CRLF, accepts a final unterminated line, and returns
an error for EOF before any line or invalid UTF-8. Byte values are 0..255.
`File.close` flushes output and is idempotent. Explicit flush and close return
Results so I/O failures remain recoverable.

Timeouts are positive milliseconds and include the serialized handle lock wait.
Timing out active I/O closes that handle; timing out while waiting for its lock
leaves it open. Errors are Results. `File.stat` follows symlinks and reports
`FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`; directory
sizes are zero. `Dir.list` returns immediate entry names sorted by name.
`Dir.mkdir` creates parents and succeeds when the directory already exists.
`Path.join` follows the host's path rules. `Path.resolve` makes a lexical
absolute path and does not resolve symlinks.

### Processes

Process is an opaque handle with no constructor, fields, equality, or JSON encoding. IO.inspect prints `<Process>`.

The signatures of `Process` are in `agentica help NAME --json` and in [`site/content/library/process.md`](../../site/content/library/process.md).

- Launching requires agentica --allow-run file.agc. The flag defaults off and precedes the source file; later arguments reach System.args. The test command accepts it before or after the command. Checking and builtin help need no flag. Permission reaches tasks. BDD step handlers can always launch programs, because `agentica test` runs every scenario's child VM with `--allow-run`; `agentica test --allow-run` only passes the flag on to the programs under test.
- A command with no `/` is a bare name: it is looked up in each `PATH` entry in order. The working directory is never added: empty `PATH` entries are skipped, so a program in the current directory runs as `./name`, while an explicit relative entry such as `.` or `bin` resolves against the working directory, as in the shell. A command that contains `/` is a path, relative to the inherited working directory unless it is absolute. A name that is not found, or that names a directory, is "executable is unavailable". Children inherit the environment. Arguments are passed directly without shell interpolation. Empty commands, NUL-containing arguments, and unavailable executables fail. On Windows only `.exe` and `.com` programs run; other files, such as batch files, fail. A file that is found but cannot be executed (no execute permission, a bad format) is an error Result from `spawn`.
- Timeouts are positive milliseconds, including lock wait. Read and write locks are independent. A timeout after starting stream I/O kills and closes the child; timing out while waiting for its lock preserves it. Waiting for exit times out without terminating the child.
- Sends accept at most 1048576 UTF-8 bytes or integers 0..255 and flush before succeeding. Invalid data consumes nothing. read_bytes accepts 0..1048576 and waits for that count or EOF: short/empty EOF succeeds, and zero consumes nothing.
- read_line consumes a line of at most 1 MiB, strips LF/CRLF, and strictly decodes UTF-8. An unterminated final line succeeds; empty EOF is an error. Invalid UTF-8 consumes the completed line. An oversized line closes the child.
- close_stdin flushes and closes input idempotently; further sends fail. wait returns the host exit code, including nonzero codes, and can be repeated. It preserves unread stdout and waits for stderr forwarding to finish.
- Stderr streams separately to the program's stderr with a fixed-size buffer. Output has no lifetime cap. A child can block when stdout's pipe fills: use Task to read concurrently with sending or waiting.
- Handles belong to their evaluation. close force-kills a running child, reaps it, closes owned ports/workers, and is idempotent. Other operations on closed handles fail. Main return, System.exit, diagnostics, task failures, step exhaustion, and external interruption also clean up directly spawned children. Arbitrary descendant trees are outside the cleanup guarantee. Borrowed ports remain open.
- Operational failures return String error Results. Explicit cleanup failures are RUNTIME-PROCESS-CLOSE, at the call span.
- Captured processes. `spawn_captured` works like `spawn` (same lookup, `--allow-run`, environment and cleanup) with three differences. The child starts in `dir`: `"."` keeps the working directory, a relative `dir` resolves against it, an empty `dir` or one with NUL is an error, and a `dir` that is not a directory is "directory is unavailable". The command still resolves against the program's working directory, not `dir`, so `spawn_captured("./sh", [], "/bin", t)` is "executable is unavailable". The VM reads the child's stdout and stderr all the time, so the child never blocks on a full pipe: stdout goes into a buffer that `read_line` and `read_bytes` read, stderr into its own buffer and never to the program's stderr. Past 1 MiB of unread stdout, or 1 MiB of stderr, that stream is marked truncated and further bytes are dropped. Once either stream is truncated, every stdout read returns `error("process: output exceeds 1048576 bytes")`: a read already waiting wakes with it, and `read_bytes(p, 0, t)` returns it at once, so a program can check for a stderr flood without waiting.
- `output` waits until the child's stdout and stderr both end, then returns the builtin record `ProcessOutput(stdout: String, stderr: String, truncated: Bool)`: the stdout not read yet, all of stderr (invalid UTF-8 becomes U+FFFD), and whether either stream was truncated. It consumes nothing and can be called again. A timeout is `error("network: operation timed out")` and keeps the child; a process from `spawn` gives `error("process: output is not captured")`. `ProcessOutput` is reserved.
- Closing a captured child (`close`, a stream timeout, the end of the run) sends `SIGTERM`, then `SIGKILL` after one second, so a child that is itself an Agentica program can stop its own children first. `close` and a timeout close the handle at once and never wait; the end of the run waits about one second at most for a captured child before it kills it. Children from `spawn` are still killed at once.
