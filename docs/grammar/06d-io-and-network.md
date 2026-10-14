### TCP, TLS and HTTP

Networking uses the normal expression syntax and lightweight tasks. The network names in §4 are reserved, and handles are opaque: they belong to their run and close when it ends. No CLI flag is needed. Signatures and details are in [`library/io-and-system/network.md`](../../site/content/library/io-and-system/network.md); the protocol is in [`docs/vm/10-io-http.md`](../vm/10-io-http.md) and [`docs/vm/10-io-tls.md`](../vm/10-io-tls.md).

- Ports are 1 to 65535 to connect and 0 to 65535 to listen; port 0 asks for an assigned port, which `TCP.local_port` returns. A host with NUL is an error.
- TLS checks certificates and host names, with TLS 1.2 or later; verification cannot be turned off. An empty CA file means system trust; a nonempty one replaces it, and a missing or empty file fails the connect. A peer that closes without TLS's close message ends the stream like EOF, so the protocol must detect a cut message.
- Timeouts are positive milliseconds and cover the whole operation, lock waits included. A timeout during active I/O closes that socket, and later calls fail with `network: socket is closed`. A timeout while only waiting for a lock keeps it open.
- `send` takes UTF-8 text and flushes; `send_bytes` takes values 0 to 255, at most 1 MiB per call. `recv_bytes` takes 1 to 1048576 and gives `ok([])` at EOF. `read_line` is an error on an empty EOF, on a reset in the middle of a line, and on a line over 1 MiB, which also closes the socket.
- Header values use the Latin-1 byte range. CR, LF, control characters and framing headers set by the program are rejected.

#### HTTP client and server (`std/http`)

HTTP is the `std/http` library, imported with `import "std/http" as HTTP`; any alias works. It calls the internal module `HttpWire`, which no other module can name (`CHECK-UNKNOWN-NAME`). A complete program is in [`examples/http_server.agc`](../../examples/http_server.agc).

A client call is whole: it returns after the whole body, which must be valid UTF-8. One `timeout_ms` covers the whole call. Calls wait in FIFO order for one of the `max_connections` slots (at most 65536). `max_body_bytes` is at most 64 MiB. A call in flight when `close_client` runs fails with `http: client is closed`.

A `GET`, `HEAD`, `OPTIONS`, `PUT` or `DELETE` sent on a reused connection that the server had already closed is retried once on a new connection, within the same timeout, if no response byte arrived. `POST`, `PATCH` and other methods are never retried.

URLs are `http://` or `https://`. A request that sets `Host`, `Content-Length`, `Transfer-Encoding` or `Connection` itself is an error. Status codes 4xx and 5xx are normal responses. Protocol errors start with `http: `; connection errors keep their TCP or TLS text; a timeout is `network: operation timed out`.

`listen` (or `listen_tls`) serves in the background, with one task per connection. The handler gets a whole `HttpRequest` and returns a whole `HttpResponse`; the server adds the framing headers it needs. If the handler returns `error(message)`, or the response cannot be sent (a status outside 200 to 599, a bad header, a handler-set `Content-Length` or `Transfer-Encoding`, or a body on 204 or 304), the client gets a 500 with an empty body and the connection closes. Stderr gets `http: handler error: <message>` or `http: invalid response: <reason>`. A handler has no time limit. A runtime error in a handler crashes its connection task, and the run reports the crash.

`server_options()` gives 30 s request and idle timeouts, 128 connections and 1 MiB bodies. `request_timeout_ms` bounds the first byte of a connection's first request, then the rest of each request, then the response write; `idle_timeout_ms` bounds the wait for a later request. Connections beyond `max_connections` wait in the backlog. A request rejected before the handler runs gets an empty answer and a close (400, 413, 417, 431, 501 or 505). `close_server` closes the listener, ends every connection, cancels the handlers and the tasks they spawned, and is idempotent. Return from `main` ends the run, whatever the server is doing.

### Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. A file handle is opaque, belongs to one evaluation, and closes when it ends. The host user's permissions apply; there is no filesystem permission flag. File operations accept regular files and symlinks to them, and reject directories and special files. Signatures are in [`library/io-and-system/files.md`](../../site/content/library/io-and-system/files.md).

- `File.open` modes: `read` (an existing regular file), `write` (creates or truncates) and `append` (creates or appends).
- Text is strict UTF-8. Whole-text helpers and each stream read or write are limited to 1 MiB. `read_bytes` takes 1 to 1048576 bytes and gives `ok([])` at EOF. `read_line` strips LF or CRLF and accepts a final unterminated line; it is an error at EOF or on invalid UTF-8.
- `File.close` flushes and is idempotent. Timeouts are positive milliseconds and include the lock wait. A timeout during active I/O closes the handle; a timeout while waiting for the lock keeps it open.
- `File.stat` follows symlinks and gives `FileInfo(kind, size_bytes, modified_seconds)`. `Dir.list` gives immediate entry names, sorted. `Dir.mkdir` creates parents. `Path.resolve` is lexical and does not resolve symlinks.

### Processes

`Process` is an opaque handle, with no constructor, fields, equality or JSON encoding; `IO.inspect` prints `<Process>`. Signatures are in [`library/io-and-system/process.md`](../../site/content/library/io-and-system/process.md).

- Starting a program needs `agentica --allow-run file.agc`. The flag defaults to off and precedes the source file; later arguments reach `System.args`. The `test` command accepts it before or after the command. Checking and `help` need no flag. The permission reaches tasks. BDD step handlers can always start programs.
- A command without `/` is looked up in each `PATH` entry, in order. An empty entry is skipped, so `./name` runs a program in the working directory; a relative entry such as `.` resolves against it. A command with `/` is a path, relative to the working directory unless absolute. A name that is not found, or names a directory, is `executable is unavailable`. Arguments go straight to the program, with no shell. On Windows only `.exe` and `.com` run. A file that is found but cannot run is an error Result from `spawn`.
- Timeouts are positive milliseconds and include the lock wait. A timeout during stream I/O kills and closes the child; a timeout while waiting for the lock keeps it; a timed-out wait for exit does not terminate it.
- A send takes at most 1048576 UTF-8 bytes, or integers 0 to 255, and flushes. Invalid data consumes nothing. `read_bytes` takes 0 to 1048576 and waits for that many bytes or EOF. `read_line` takes at most 1 MiB, strips LF or CRLF, and decodes strictly. An empty EOF is an error, and an oversized line closes the child.
- `close_stdin` flushes and closes input, idempotently. `wait` returns the exit code, including nonzero codes, and can be repeated. A child blocks when its stdout pipe is full, so read it in a task while sending or waiting.
- `close` force-kills a running child, waits for it to exit (other tasks run meanwhile) and closes the ports it owns; it is idempotent. A timeout closes the child too, but does not wait for it. Return from `main`, `System.exit`, a diagnostic, a task failure, step exhaustion and an external interruption clean up the children started directly; their descendants are not covered. Operational failures are String error Results. A failed explicit cleanup is `RUNTIME-PROCESS-CLOSE` at the call.
- `spawn_captured` works like `spawn`, with the same lookup, permission and cleanup, except that the child starts in `dir` (`"."` keeps the working directory; an empty, NUL or non-directory `dir` is an error) and its streams are read by the VM. The child never blocks on a full pipe. Stdout is read by `read_line` and `read_bytes`; stderr never reaches the program's stderr. Past 1 MiB of unread stdout, or of stderr, that stream is truncated and later bytes are dropped; after a truncation every stdout read returns `error("process: output exceeds 1048576 bytes")`.
- `output` waits until both streams end and returns `ProcessOutput(stdout, stderr, truncated)`: the stdout not read yet, all of stderr (invalid UTF-8 becomes U+FFFD), and whether a stream was truncated. It consumes nothing. A timeout is `error("network: operation timed out")` and keeps the child. On a `spawn` handle it is `error("process: output is not captured")`.
- Closing a captured child sends `SIGTERM`, then `SIGKILL` one second later, so a child that is itself an Agentica program can stop its own children first. `close` and a timeout never wait. At the end of a run a captured child gets about one second; a child from `spawn` is killed at once.
