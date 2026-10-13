### 10.6 HTTP parsing

HTTP on the VM is simple: whole messages, `String` bodies, no streaming
until channels (10.7). Every rule of this section is fixed by the
hostile-case tests below.

- Well-formed messages give the status, headers and body, and a `Result`
  that is ok or an error.
- Malformed or hostile input is rejected. A server answers with an error
  status and closes the connection; a client request call returns an error
  `Result` (its message text is free). The exact 4xx or 5xx code is free
  except these, which are fixed: 400 (a malformed head or body), 413 (body
  over the limit), 417 (an `Expect` other than one `100-continue`), 431
  (too many headers or trailers, or a line, head or trailer block over its
  size limit), 505 (a request with an HTTP version of the form
  `HTTP/[0-9.]+` other than `HTTP/1.1`; a bad response version is a client
  error `Result`) and 501 (`CONNECT`, and any `Transfer-Encoding` other
  than one `chunked`). It does not have to report the first failing line
  in any fixed order.
- Leniencies: picohttpparser's RFC 9112 leniencies, one leading empty line
  before a request and runs of spaces in the start line, are accepted.
  They do not make framing ambiguous. The reason phrase accepts what
  picohttpparser accepts; control bytes in a reason phrase give a client
  error.

- Framing rules stay strict: `Content-Length` with `Transfer-Encoding`
  (with any `Transfer-Encoding`, this is 400 first), conflicting `Content-Length` values (400), bad chunk sizes and obs-fold
  are rejected. Equal duplicate `Content-Length` values (the header twice,
  or `5, 5`) are accepted as one (RFC 9110 §8.6).
  `Transfer-Encoding` other than one `chunked` (`gzip`, `gzip, chunked`,
  two `Transfer-Encoding` headers) gives 501.

picohttpparser validates the head; that is why it is a dependency (and its SSE4.2 path
later, `docs/future/19-simd.md` §19). It sits behind our own small adapter, so it can be
swapped later (for example for llhttp), the same way libuv stays inside
the I/O layer.

- `vm/http_parse.h` holds our types only: a parsed head struct (method,
  target, version, status, reason, and the headers with their count, all
  as byte slices into the input buffer) and
  `agc_http_parse_request_head` and `agc_http_parse_response_head` (calls
  in 10.6.1). They return OK with the bytes consumed, INCOMPLETE, or ERROR
  with our own error enum.
- Only `vm/http_pico.c` includes `picohttpparser.h`. No picohttpparser type
  or return code leaks out of it.
- The adapter calls picohttpparser without `last_len`, and only when the
  newly read bytes complete a line (contain LF). Each call parses the whole
  buffered head again. A head is at most the start line (8192 bytes plus
  CRLF) and 64 KiB of headers (10.5), and it has at most about 100 lines
  (the start line, 100 headers and the blank line) before the pre-scan
  stops it, so parsing work is bounded by lines × head size. On INCOMPLETE
  the caller reads more and calls again with the grown buffer.
- A -1 from picohttpparser maps to one error: 400 "invalid HTTP request
  head" for a server, and an error `Result` ("invalid HTTP response head")
  for a client.
- The adapter checks more than picohttpparser, all on our own pre-scan or
  on picohttpparser's output:
  - The pre-scan (one pass over newly read bytes) checks the line and
    head size limits (431), rejects bare LF (kept strict against
    smuggling), and counts header lines: once the count passes 100 it
    returns 431, before picohttpparser runs. Before a request, the
    pre-scan and the start-line check skip one leading CRLF, matching the
    documented leniency, so the header count is not off by one. The
    pre-scan stops at the end of the start line; the start-line check
    (431 for its length, then 505 or 400) runs before the pre-scan looks
    at any header line.
  - Once the start line is complete, and before picohttpparser runs, the
    adapter checks its shape itself. A request is
    `METHOD SP+ TARGET SP+ VERSION`, a response `VERSION SP+ 3DIGIT`. In
    a request, a version of the form `HTTP/[0-9.]+` gives 505 unless it is
    exactly `HTTP/1.1` (so `HTTP/1`, `HTTP/2`, `HTTP/1.10` and `HTTP/2.0`
    give 505); any other bad shape gives 400. In a response, a bad version
    or shape is a client error `Result`. So a complete bad start line
    always fails at once, even where picohttpparser would still return -2
    for short input.
  - Request target: origin form (`/...`), or `*` with `OPTIONS`; only bytes
    33 to 126; anything else is 400.
  - Method: token characters only (400); `CONNECT` gives 501.
  - obs-fold lines (picohttpparser returns a header with `name == NULL`)
    are rejected with 400.
  - Responses: `HTTP/1.1` only, status 100 to 599, 101 rejected, at most
    15 interim responses (the 16th fails); these give an error `Result`.
  - The `Host` rules, and the body framing and smuggling rules above
    (conflicting `Content-Length` 400, unsupported `Transfer-Encoding`
    501).
- Our own body decoder, `vm/http_body.c` (no third-party code), is an
  incremental state machine. It is set up with the framing
  (`Content-Length` n, chunked, or until close for responses) and the
  `max_body_bytes` limit; then `feed(buf, len)` returns the bytes consumed
  and NEED_MORE, DONE or ERROR: 413 over the limit, 431 for an over-long
  chunk-size or trailer line or for trailers over the block-size or count
  limit, and 400 for every other malformed body. The body slices go into
  one `malloc`'d buffer for the whole body, within `max_body_bytes`, which
  becomes one `String` (10.7). Chunk sizes accumulate with saturation;
  `phr_decode_chunked` is not used, since it knows no limits. Trailer
  lines are checked with the header rules (token names, value bytes, the
  forbidden trailer list, and the size and count limits) and then dropped:
  there is no trailer API. Swapping the head parser leaves the body decoder
  unchanged. Until the streaming items (20e to 20g), the VM has no chunked
  encoder: responses always carry `Content-Length`, and requests are never
  chunked.
- Tests target the adapter interface, so a replacement parser must pass the
  same tests: a C unit test in `vm/tests/`, and fixed, deterministic hostile
  cases. They check the rejection (and the code where it is fixed), not
  message text: `Content-Length` with
  `Transfer-Encoding`, conflicting `Content-Length` (400), equal duplicate
  `Content-Length` twice and as `5, 5` (accepted), `Transfer-Encoding:
  gzip`, `gzip, chunked` and two `Transfer-Encoding` headers (501), huge
  chunk sizes (413), bare LF, over-long lines and heads (431), 100 headers
  accepted and 101 and 150 rejected with 431, trailers over the line,
  block-size or count limit (431), `HTTP/1`, `HTTP/2`, `HTTP/1.10` and
  `HTTP/2.0` (505), an `HTTP/2.0` start line followed by 101 headers in
  one write (505), a malformed version, a leading CRLF before a request
  with 100 headers (accepted), absolute-form and non-ASCII targets, `*`
  without `OPTIONS`, a bad method token, `CONNECT` (501), an obs-fold line,
  bad trailers, and on the client
  side `HTTP/1.0` responses, status 99 and 600, a 101 response, and 15
  interim responses accepted and 16 rejected. One case sends a complete bad
  start line ending in CRLF and leaves the socket open: it is rejected
  before any timeout; another sends the short line `GET / HTTP/1\r\n`,
  which gets 505.

#### 10.6.1 As built (20a)

- `vm/http_parse.h` has no limits parameter: the limits are the constants
  `AGC_HTTP_MAX_LINE` (8192), `AGC_HTTP_MAX_BLOCK` (65536) and
  `AGC_HTTP_MAX_HEADERS` (100). The calls are
  `agc_http_parse_request_head(buf, len, out, used, error)` and
  `agc_http_parse_response_head(...)`, returning `AGC_HTTP_OK`,
  `AGC_HTTP_INCOMPLETE` or `AGC_HTTP_ERROR` with an `agc_http_error`;
  `agc_http_error_code` gives its status (400, 413, 431, 501, 505) and
  `agc_http_error_text` its message. `agc_http_framing` turns a parsed head
  into the body framing (`Content-Length`, chunked, or until close for a
  response). A response head with status 100 to 199 is returned without
  framing; the caller counts interim responses.
- `vm/http_body.c` is the decoder of the last bullets, filling one buffer:
  `agc_http_body_init(body, frame, length, limit)`, then
  `agc_http_body_feed(body, data, len, used)` (NEED_MORE, DONE or ERROR)
  and `agc_http_body_end` at EOF (DONE for a close-delimited body, else
  "truncated"). A `Content-Length` body is reserved whole up front, after
  the limit check. Trailers are checked and dropped.
- Only `vm/http_pico.c` and the Makefile know picohttpparser; it is built
  like yyjson, as one object (`build/vm/<config>/picohttpparser.o`).
- Tests: `vm/tests/http_parse_test.c` runs the hostile list on the adapter
  and the decoder (request and response heads; each body fed whole and
  byte by byte); `tests/vm-http-test.rkt` sends the client-side cases from
  a Python raw-socket peer (`tests/fixtures/http-peer.py`). The server-side
  cases over a socket come with the server (20c).

### 10.7 HTTP on the VM: the hybrid split (phase 20; the client and the server are built)

HTTP is split between a small C builtin module, `HttpWire`, and the Agentica module `std/http.agc`, which programs import as `HTTP`. The builtin `HTTP` module is gone (deleted with the evaluator in 7i), so `std/http` is the only HTTP. The language-level rules (API, options, limits, answers) are in the grammar, `docs/grammar/05b-modules.md` ("HTTP client and server"); this section is the design and the as-built notes: the client is 10.7.1, the server 10.7.2, the answers 10.7.3 and the tests 10.7.4. Streaming on channels (20e to 20g) is planned in `docs/future/30-hybrid-http.md`.

- **C (`HttpWire`)**, VM-only and std-only. It keeps what is byte-level, security-critical or shared across tasks: the head parser of 10.6 (`vm/http_parse.h`, `vm/http_pico.c`), the body decoder (`vm/http_body.c`) filling one `malloc`'d buffer per body, the UTF-8 check, the error answers before dispatch (400, 413, 417, 431, 501, 505), response writing with `Content-Length` only, the client's connection pool and its `SSL_CTX` (one per client, from `ca_file`, until `TlsContext`, `docs/future/29-tls-context.md`), and the server's task group: accept with the `max_connections` slots, group tasks that own their sockets, and `close_server`, which cancels the group's tasks through `agc_task_cancel` (10.2.1 and 10.2.2, with pool waiters among its states).
- **Agentica (`std/http`)** keeps the rest: options and their checks, URL parsing, request building, the accept loop, the per-connection loop, keep-alive, handler dispatch, the 500 answers for a handler `error` or an unsendable response, and the header helpers. No Agentica code touches a body byte by byte: a body crosses once, as a `String`. A piece moves to C only when a measurement shows it is hot (the server measurement 7j), with its `std/http` API unchanged.
- **Dropped** from the earlier C-only design: the streaming body API (`HttpBody`, `HttpWriter`, the `request_stream` producer task), the trailer API, the chunked encoder (back in 20f and 20g for streams on channels), and a server loop and handler dispatch in C. **Kept**: picohttpparser v1.4 behind the adapter, every check of 10.6, the limits of 10.5 with saturating sizes, and the hostile-case list.

**Design decisions.**

- **Whole messages.** `get`, `post` and `request` send the whole request, read the whole response (head and body) and return it; they block only the calling task. 4xx and 5xx are normal responses. One `timeout_ms` covers the whole call: the wait for a pooled connection, DNS, connect, the TLS handshake, the request and the whole response. The server has two deadlines per request, each `request_timeout_ms` long: reading one whole request from its first byte (`read_request`), and writing the response from the handler's return (`write_response`). The handler's own run is not bounded. `idle_timeout_ms` is the wait for the first byte of the next request on a kept-alive connection (server) and how long an idle pooled connection is kept (client).
- **Body limit and memory.** `max_body_bytes` defaults to 1 MiB on both sides and may be raised to 64 MiB. Per connection the request body sits once in the C buffer and once in its `String`, and the response body once in the handler's `String` and once in the C write buffer, so memory for bodies is at least `max_body_bytes` times `max_connections` times 4 at worst (up to 512 MiB with the defaults); a program that raises `max_body_bytes` must lower `max_connections` to match. A body over the limit is an `error` result on the client and a 413 on the server, before the handler runs.
- **Bodies are text.** A request or response body must be valid UTF-8: the client returns an `error` for a response body that is not, and the server answers 400 and the handler never runs. Binary bodies wait for `Bytes` (phase 13): before it the only type is `List[Int]`, a million boxed values per MiB and a per-byte Agentica loop, which the std-first rule forbids. `Content-Encoding` stays raw (no gzip).
- **The handler returns its answer**, `Fn[HttpRequest, Result[HttpResponse]]`: returning is the one way to answer, and an `error` becomes a 500 (10.7.3). A returned `Result` is used, so it fits `CHECK-UNUSED-RESULT` (`docs/future/26-strict-diagnostics.md`).
- **Response framing** is always `Content-Length`: never chunked, never trailers. `HEAD` gets the head (with the `Content-Length` of the body it would have sent) and no body; 204 and 304 get no body and no `Content-Length`, and a handler that returns a non-empty body with them gets a 500. A response ends the server's part of the exchange, so keep-alive needs no "was the body consumed?" rule: the request body was read in full before the handler ran.
- **Incoming framing** stays complete: chunked request bodies and chunked and close-delimited response bodies are decoded in full, in C, within the limits; trailers are checked with the header rules (10.6), then dropped.
- **Requests the client sends** carry `Content-Length` when the body is not empty or the method is `POST`, `PUT` or `PATCH` (`Content-Length: 0` for an empty body). The client adds `Host`; user `Host`, `Content-Length`, `Transfer-Encoding` and `Connection` headers are rejected, and so are CR, LF and control bytes. The body is written while the response is read, in C, so a server that answers early (413) or echoes a large body cannot deadlock the call.
- **The pool stays, with no API.** `HttpClient` keeps idle keep-alive connections per scheme, host and port, at most `max_connections` per origin, and a call waits in FIFO order for a free one within its timeout. A connection is leased only for the length of one call, inside C, and goes back to the pool when the response was complete and neither side asked to close. `close_client` closes idle connections at once; a call in flight in another task fails with "http: client is closed" and its connection is closed.
- **Arity.** A `std/` module has user functions, which cannot be overloaded or generic: `HTTP.client()` without options is gone, so a client is `HTTP.client(HTTP.client_options())`; `HTTP.request_stream` is gone with streaming (its generic argument could not be written in Agentica; its job comes back on channels).
- **Server behavior**: one task per connection, requests on one connection one at a time, 100 Continue for one `Expect: 100-continue` (417 for any other expectation), 501 for `Upgrade` and `CONNECT`, `HTTP/1.1` only, at most `max_connections` connections at once (an extra one waits in the kernel's backlog), and `HTTP.wait` returns only after `HTTP.close_server`. When `main` returns or the run fails, every server and client is closed and every handler task stops. `HTTP.close_server` stops accepting, cancels running handlers and every task they spawned, closes every connection and wakes `HTTP.wait`; it is idempotent.
- **Options.** `HTTP.client` and `HTTP.listen` check the options record first: every number positive, `max_connections` at most 65536, `max_body_bytes` at most 64 MiB. A bad record is an `error` result.
- **TLS** keeps today's file paths (`ca_file`, `cert_file`, `key_file`) until `TlsContext`.
- **Exposure.** `std/http` is reached by an explicit import, `import "std/http" as HTTP`, like `std/queue`: no new compiler mechanism, the program says where the code comes from, and a runtime error inside the library names `std/http.agc`. Rejected: global `HTTP.*` through the compiler prelude (the prelude is for generic code and methods on builtin types, which `std/http` is not) and an implicit import in the linker (magic for one module, and a second way to import a `std/` module). `HTTP` is a free alias, not a reserved name; an `HTTP.get` call without the import is `CHECK-UNKNOWN-NAME` with a help that shows the import. `HttpRequest`, `HttpResponse`, `HttpClientOptions`, `HttpServerOptions`, `Header`, `HttpClient` and `HttpServer` stay global builtin names, since the C primitives build and take them.
- **`HttpWire` is std-only.** A public raw layer next to `std/http` would be a second way to do HTTP. The linker (`src/modules.rkt`) gives `CHECK-UNKNOWN-NAME`, with a help that shows the `std/http` import, for a qualified `HttpWire.f` in any module not embedded from `stdlib/` (`std-only-modules` in `src/builtins.rkt`); `agentica help`, `help --json` and "did you mean" lists leave it out. The loader does not guard it: a crafted `.agcb` that calls it gets nothing that `TCP` and `TLS` do not give (the trust model of `docs/vm/README.md` §1). `HttpWire` is a reserved name (`CHECK-REDEFINED-NAME` for a user type or alias with it), named apart from `HTTP` because an alias cannot collide with a builtin name.

#### 10.7.1 As built: the client (20a)

`HttpWire` has three client builtins; the server ones are in 10.7.2.

```text
HttpWire.client(timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String) -> Result[HttpClient]
HttpWire.exchange(client: HttpClient, scheme: String, host: String, port: Int, method: String, target: String, headers: List[Header], body: String) -> Result[HttpResponse]
HttpWire.close_client(client: HttpClient) -> Void
```

- The client takes every option once, and `exchange` reads `timeout_ms`
  and `max_body_bytes` from it, since `std/http` cannot read them back from
  the opaque handle. `std/http` checks the option ranges first.
- `vm/http_client.c` (Linux; other platforms get a stub table) holds the
  pool: per origin (scheme, host, port) a list of idle connections, the
  number of open slots and a FIFO of waiting exchanges. A finished
  exchange parks its connection as idle or frees its slot, and the first
  waiter gets it. Idle connections close after `idle_timeout_ms` (one timer
  per client; the clock is updated before each check) or when the peer
  closes them. An origin with no open connection, no waiter and no
  exchange is freed.
- Retry: an exchange that leased an idle connection and then fails with
  EOF, a read error or a write error before any response byte (no interim
  response, nothing buffered) is retried once on a new connection, at the
  head of the waiters and within the same timeout, when its method is
  `GET`, `HEAD`, `OPTIONS`, `PUT` or `DELETE`. This covers the race where
  the server closes an idle keep-alive connection as the request is sent.
  The request bytes are kept until the exchange ends for this.
- Connections are tcp.c's: `vm/net.h` exports its connection object
  (`agc_conn_open`, `agc_conn_send`, `agc_conn_read`, ...) with a watch
  callback, so DNS, connect, TLS through memory BIOs and the close rules
  stay in one place. The client's `SSL_CTX` is built on the libuv pool on
  the first HTTPS call and shared by its connections.
- `exchange` checks the method, target, host and header bytes, adds `Host`
  (the port only when it is not the scheme's default; an IPv6 host in
  brackets) and `Content-Length` (when the body is not empty or the method
  is `POST`, `PUT` or `PATCH`), and refuses user `Host`,
  `Content-Length`, `Transfer-Encoding` and `Connection` headers. It writes
  the request while it reads the response, so a server may answer (413, for
  example) before the upload ends. Interim responses are skipped (at most
  15); 101 is an error. The connection goes back to the pool only after a
  complete exchange with no `Connection: close` on either side and a framed
  body. Header names are lowercased, values are decoded as Latin-1, and the
  body must be valid UTF-8.
- After 204 or 304 the connection is not kept when the response still
  announced a body (a nonzero `Content-Length`, or chunked). After `HEAD`
  it is kept: no body follows a `HEAD` response whatever it announces
  (RFC 9110 §9.3.2). Bytes already buffered when an exchange ends close
  the connection. A connection freed while calls wait is parked as idle
  and handed to the first waiter by the client's timer 1 ms later, so
  bytes that arrive in that window close it first. This is a narrow guard,
  not a promise: a call that leases an idle connection right away (two
  calls in a row from one task) can still read bytes a server sends late.
  Idle connections and the idle timer are unreferenced in libuv
  (`agc_conn_hold`), so a pool never hides a stalled run.
- Over TLS, a close-delimited body must end with `close_notify`: tcp.c
  records whether the TLS layer closed before the TCP FIN
  (`agc_conn_clean_eof`), and a bare FIN gives "http: truncated HTTP body".
  OpenSSL cannot tell this itself here, since `SSL_OP_IGNORE_UNEXPECTED_EOF`
  makes a bare FIN look like `close_notify` (both set
  `SSL_RECEIVED_SHUTDOWN`).
- One `timeout_ms` covers the call, from the wait for a slot to the last
  body byte; on timeout the connection is closed and the call returns
  "network: operation timed out". `close_client` closes idle connections
  and fails every call in flight with "http: client is closed".
- At the end of the run the exit path's `goodbye` hook (`client_goodbye`,
  added in 20c) sends one non-blocking TLS `close_notify` on each HTTPS
  connection of an `HttpClient`, idle or in use (`agc_conn_goodbye`), as
  tcp.c does for its sockets.
- Errors are `http: ` plus the text of 10.6, or the network error text of
  tcp.c for DNS, connect, TLS, read and write failures.
- `HttpResponse`, `Header`, `HttpClientOptions` and `FileInfo` carry their
  field types from `builtin-records`, so `JSON.encode`, `JSON.decode` and
  `JSON.schema` work on them on the VM (the `http-json` golden).
- Turn cost (`AGC_COST_SIZE`): charged when the call ends, after the
  exchange is freed, for the header list, the request's bytes (head and
  body) and the response's body and header fields.

#### 10.7.2 As built: the server (20c)

```text
HttpWire.read_request(socket: Socket, first_byte_timeout_ms: Int, timeout_ms: Int, max_body_bytes: Int) -> Result[HttpRequest]
HttpWire.write_response(socket: Socket, request: HttpRequest, response: HttpResponse, timeout_ms: Int) -> Result[Bool]
HttpWire.server(listener: Listener, max_connections: Int, f: Fn[HttpServer, Void]) -> HttpServer
HttpWire.accept(server: HttpServer) -> Result[Socket]
HttpWire.spawn(server: HttpServer, socket: Socket, f: Fn[Socket, Void]) -> Void
HttpWire.close_server(server: HttpServer) -> Void
HttpWire.wait(server: HttpServer) -> Result[Void]
HttpWire.local_port(server: HttpServer) -> Int
```

- `vm/http_server.c` (Linux; a stub table elsewhere) holds them, on tcp.c's
  connection object (`vm/net.h`) with a watch callback, as the client does.
  Header lists and the header writer are shared with the client in
  `vm/http_fields.c`.
- `read_request` waits up to `first_byte_timeout_ms` for the first byte of
  a request (bytes already buffered, or a raw byte heard on the socket, so
  a TLS handshake counts), then restarts its job's timer with `timeout_ms`
  (`agc_io_extend`), which bounds the rest of the request. The checks run
  in the order of 10.7.3: the parse errors of 10.6, any `Upgrade` header
  (501), an `Expect` other than one `100-continue` (417), a
  `Content-Length` over `max_body_bytes` (413), then `100 Continue` when
  `Expect` asked for it and the body is still to come, then the body and
  its UTF-8 check (400). Every error answer is written by C:
  `HTTP/1.1 CODE REASON`, `Content-Length: 0` and `Connection: close`.
  After it is sent the write side is shut (`agc_conn_half_close`, with
  `close_notify` over TLS) and input is read and dropped until the peer
  closes or the request's deadline, so request bytes the server never read
  cannot turn the close into a reset that loses the answer. Then the
  socket closes and the call returns `error("http: <reason>")`. EOF before
  the first byte is `error("network: end of input")`; EOF in the middle of
  a request is "http: connection closed before the request was complete";
  the deadline closes the socket and returns "network: operation timed
  out" with no answer. Header names are lowercased and values decoded as
  Latin-1; `path` is the target before `?`. When the request is complete
  the socket stops reading (`agc_conn_pause`) until the next
  `read_request`, so a client that pipelines bytes while a response is
  written cannot grow the input buffer.
- `write_response` builds the whole response before it writes: a status
  of 200 to 599 (the reason phrase is the standard one, or empty), the
  header checks of the client (`Content-Length` and `Transfer-Encoding`
  are refused: "Content-Length and Transfer-Encoding are set by the
  server"), no body with 204 or 304, a `Date` header unless the handler set
  one, `Content-Length` except on 204 and 304, and the body unless the
  request's method is `HEAD`. The connection closes when the request or
  the response has `Connection: close` (`agc_http_list_closes`, the same
  token check as the client's `agc_http_closes`): then the handler's
  `Connection` headers are dropped and one `Connection: close` is sent, so
  the header cannot contradict itself. A bad response is
  `error("http: invalid response: <reason>")` with nothing written.
  Otherwise the call returns `ok(true)` when the connection stays open and
  `ok(false)` after a closing response, which gets the same lingering close
  as the error answers before the socket closes. `timeout_ms` bounds the
  write, and the lingering, from the call; a deadline during the lingering
  still returns `ok(false)`.
- `server` makes the `HttpServer` and runs `f(server)`, the accept loop of
  `std/http`, as a task of the group, so `close_server` cancels it with the
  connections and a server closed inside `Test.run` leaves no task running.
  The `HttpServer` handle holds the listener, the number of open
  connections, `max_connections` (1 to 65536) and the jobs of tasks parked
  in `accept` or `wait`, and a group node: a task that never runs
  (`agc_task_group`), the parent of the connection tasks. `accept` returns
  an accepted socket once fewer than `max_connections` are open, and parks
  otherwise; the listener's watch, a freed slot and the close wake it.
  Accept failures are traced and retried. A TLS socket is returned before
  its handshake: tcp.c makes the session at accept and runs the handshake
  on the first read or write, under that call's timeout.
- `spawn` starts `f(socket)` as a child of the group
  (`agc_task_spawn_in`), moves the socket to it, marks it `hidden` and sets
  its end hook (`agc_task.end`), which closes the socket and frees the
  slot when the task ends in any way. The children of a connection task
  that ended move to the group, as 20b's rule moves them to any parent.
- `close_server` (also the close of an owned server when its owner
  crashes) is idempotent: it closes the listener, wakes `accept` (which
  then returns "http: server is closed") and `wait` (which returns
  `ok()`), and drops the group (`agc_task_drop`): it marks the subtree,
  cancels it with `agc_task_cancel`, and closes every handle a task of it
  owns (`agc_close_owned`), so the connection sockets and the sockets a
  handler's spawned task opened close too. A handler that closes its own
  server stops after that builtin, as a running task does under 20b; no
  program can do that today (a handler cannot reach its `HttpServer`), and
  the C test of `agc_task_drop` covers it.
- A crash in a connection task ends that connection (§37.5): its socket
  closes and its client sees the close with no response. Connection tasks
  are `hidden`: no await can observe them, so of their unobserved crashes
  only the first per test (or per run outside `Test.run`) is kept in the
  crash list, and the others are counted on it. With observed crashes
  leaving the list, the list stays bounded however many handlers crash.
- `std/http` runs the accept loop in the group and, for each socket,
  `spawn`s the connection loop: `read_request` (the first request waits
  `request_timeout_ms` for its first byte, later ones `idle_timeout_ms`),
  the handler with no time limit, then `write_response` with a fresh
  `request_timeout_ms`. A handler `error` or a response that
  `write_response` refuses gives a 500 with `Connection: close` and one
  `IO.warn` line (`http: handler error: ...` or `http: invalid response:
  ...`). The loop ends when `write_response` returns anything but
  `ok(true)`.
- The server's connections are tcp.c sockets, so the end of the run gives
  them `close_notify` there (10.3).
- Turn cost (`AGC_COST_SIZE`): `read_request` charges the body, the header
  count and their bytes when it ends; `write_response` charges the
  response's bytes.
- Tests: the `http-server*` goldens; `tests/vm-http-test.rkt` runs a VM
  server (plain and TLS) against `tests/fixtures/http-server-peer.py` (the
  hostile list of 10.6 on raw sockets, with status and close, the `Expect`
  cases, pipelining, `http.client`, the `max_connections` wait, a silent
  TLS client and a plain request on the TLS port) and
  `tests/fixtures/http-server-peer.js` (Node `http`).

#### 10.7.3 Errors and status codes

**Server side**, in the order they can happen:

| Case | Who | Answer |
|---|---|---|
| Malformed or hostile head or body: bad start line, bare LF, obs-fold, bad target or method, bad framing | C (`HttpWire.read_request`) | 400, `Connection: close`, empty body, then close; the handler never runs |
| A line, the head, the header count or the trailers over their limits | C | 431, then close |
| A body over `max_body_bytes` (a `Content-Length` over it is answered before any body byte is read) | C | 413, then close |
| A version that is `HTTP/[0-9.]+` but not `HTTP/1.1` | C | 505, then close |
| `CONNECT`, `Upgrade`, `Transfer-Encoding` other than one `chunked` | C | 501, then close |
| An `Expect` other than one `100-continue` | C | 417, then close |
| `Expect: 100-continue` with a `Content-Length` over `max_body_bytes` | C | 413, then close, and no 100 Continue is sent first: the order is head checks, then the `Content-Length` limit, then 100 Continue, then the body |
| A request body that is not UTF-8 | C | 400, then close |
| The client sends its request too slowly (more than `request_timeout_ms` from its first byte), or reads the response too slowly (more than `request_timeout_ms` from the handler's return), or the idle wait ends | C | the connection is closed |
| The handler returns `error(message)` | `std/http` | 500, `Connection: close`, empty body; the message is not sent to the client, and `std/http` writes `http: handler error: <message>` to stderr with `IO.warn` |
| The handler returns a response that cannot be sent: status outside 200 to 599, a bad header name or value, a framing header, a body with 204 or 304 | C refuses to write it; `std/http` answers | 500, `Connection: close`, and `http: invalid response: <reason>` on stderr |
| A runtime diagnostic in the handler (an `unwrap!` of an error, an index out of range) | the VM | it crashes the connection task (`docs/future/37-task-crash-isolation.md` §37.5): the client sees the connection close with no response, the server goes on, and the crash is reported as any task crash |
| A handler that runs a long time | none | the handler is never stopped and has no time limit; its reply is still sent, with a fresh `request_timeout_ms` for the write that starts when it returns. The client's own timeout bounds what the client waits for |
| Writing the response fails (the client left) | C | the connection is closed quietly |

The codes that the hostile-case goldens fix are those 10.6 says are fixed. Stderr lines from `IO.warn` are program stderr, so the golden fixtures record them.

**Client side:** every failure is an `error` result, never a diagnostic: a URL that is not `http://` or `https://` with a host (userinfo and non-ASCII are rejected), DNS, connect and TLS failures, the timeout, "client is closed", a malformed response (10.6: `HTTP/1.1` only, status 100 to 599, 101 rejected, at most 15 interim responses), a body over `max_body_bytes`, and a body that is not UTF-8. A connection that fails is never put back in the pool.

#### 10.7.4 Tests

Every item keeps its own tests and docs:

- **Golden fixtures** (`tests/fixtures/vm/http-*.agc` and `.expected`), deterministic because a fixture is its own peer, as the `tcp-*` fixtures are: one program runs a server and a client in two tasks and only `main` prints. Cases: GET, POST, HEAD, 204, 304, 404, a handler `error` (500 and its stderr line), an unsendable response (500), keep-alive reuse (two calls on one pooled connection: the second needs no new accept), `Connection: close`, a body at `max_body_bytes` and one byte over (413 on the server, an `error` on the client), a non-UTF-8 body, `close_server` while a handler sleeps (the handler's next line never prints, and a task it spawned never prints), `HTTP.wait` after `close_server`, a handler that sleeps longer than `request_timeout_ms` and still gets its reply out, a handler that calls `HTTP.close_server` and then prints (the line never prints, and its client gets no response), a task spawned by a handler that has already returned, still running when `close_server` is called (it never prints again), `main` returning while a call is in flight, and the option checks. Fixtures that wait on a timeout go in the Racket test below, since goldens record step counts and must not depend on timing.
- **The hostile cases of 10.6**, all of them, against the VM server, sent by a Python raw-socket peer in `tests/vm-http-test.rkt` (standard library only), asserting the status code and that the connection closes, plus the client-side cases (`HTTP/1.0`, status 99 and 600, 101, 15 interim responses accepted and 16 rejected, a bad chunk size, a response body over the limit) served by the same raw peer. A C unit test of the adapter and the body decoder (`vm/tests/http_parse_test.c`) covers the same list at the interface, so a replacement parser must pass it.
- **Interop with independent peers on port 0**, in `tests/vm-http-test.rkt`, standard library only: the VM client against Python's `http.server.ThreadingHTTPServer` (keep-alive, chunked responses, a close-delimited body, a slow server and the timeout, `max_connections` waits) and against an HTTPS server made with Python's `ssl` and the CA of `tests/fixtures/tls/`; the VM server against Python's `http.client` and Node's `http` module (chunked uploads, `Expect: 100-continue`, pipelined keep-alive requests, `HEAD`, many concurrent clients up to `max_connections` and one more that waits). Python and Node are required in CI, as for TCP.
- **Task cancellation**: `vm/tests/task_cancel_test.c` (10.2.1).
- **The guards**: a user file, a `pkg/` module and a relative import that call `HttpWire.exchange` each get `CHECK-UNKNOWN-NAME` at the reference with the `std/http` help (`tests/modules-test.rkt`); `HttpWire` is absent from `agentica help`, `help --json` and "did you mean" lists.
- **`Expect` order**: a request with `Expect: 100-continue` and a `Content-Length` over the limit gets 413 and the Python raw peer sees no `100 Continue` before it.
- **Performance sanity check**, not a CI gate: `benchmarks/http_bench.py` (a Python standard-library load client: N keep-alive requests over C connections) against `examples/http_server.agc`, and against the VM client fetching from a Python server; the numbers go in `docs/vm-benchmarks.md` (roadmap item 20c-bench).
