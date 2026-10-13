### TCP, TLS and HTTP

Networking uses the existing expression syntax and lightweight tasks.
`TCP`, `TLS`, `HttpWire`, `Socket`, `Listener`, `HttpClient`, `HttpServer`,
`Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions` and
`HttpServerOptions` are reserved; `HTTP` is not, since it is the import
alias of `std/http` ("HTTP client and server (`std/http`)" under "File modules
and imports"). Handles are opaque: no constructor, equality, fields or JSON
encoding; inspect prints their type in angle brackets. Handles belong to
their run and close when it ends.
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
rejected. The HTTP calls are in "HTTP client and server (`std/http`)".

### Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. File handles
are opaque, belong to one evaluation, and close when it ends. The interpreter
uses the host user's filesystem permissions; there is no filesystem permission
flag. File operations accept regular files and symlinks to regular files, and
reject directories and special files.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Void]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Void]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Void]
File.read_text(path: String, timeout_ms: Int) -> Result[String]
File.write_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.append_text(path: String, text: String, timeout_ms: Int) -> Result[Void]
File.stat(path: String, timeout_ms: Int) -> Result[FileInfo]
Dir.list(path: String, timeout_ms: Int) -> Result[List[String]]
Dir.mkdir(path: String, timeout_ms: Int) -> Result[Void]
Path.cwd() -> Result[String]
Path.join(parts: List[String]) -> Result[String]
Path.resolve(path: String) -> Result[String]
```

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

~~~text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: List[Int], timeout_ms: Int) -> Result[Void]
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[List[Int]]
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
Process.close(p: Process) -> Void
Process.spawn_captured(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.output(p: Process, timeout_ms: Int) -> Result[ProcessOutput]
~~~

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
