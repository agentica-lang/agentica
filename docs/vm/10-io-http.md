### 10.6 HTTP parsing

HTTP on the VM uses whole messages. Every body is `Bytes`: the client's
request and response bodies, and the request body and response body of a
handler. Streaming waits for channels (10.7). The rules of this
section are fixed by the hostile-case tests (10.7.4).

- Well-formed messages give the status, headers and body, as an ok `Result`.
- Malformed or hostile input is rejected. A server answers with an error status
  and closes. A client request call returns an error `Result`. These codes are
  fixed: 400 (malformed head or body), 413 (body over the limit), 417 (an
  `Expect` other than `100-continue`), 431 (too many headers or trailers, or a
  line, head or trailer block over its limit), 505 (a request version
  `HTTP/[0-9.]+` other than `HTTP/1.1`), and 501 (`CONNECT`, or a
  `Transfer-Encoding` other than one `chunked`). Any other code is free.
- Leniencies: picohttpparser's RFC 9112 leniencies are accepted (one leading
  empty line before a request, runs of spaces in the start line). They never
  make framing ambiguous.
- Framing is strict. `Content-Length` with any `Transfer-Encoding` is 400,
  checked first. Conflicting `Content-Length` values, bad chunk sizes and
  obs-fold are 400. Equal duplicate `Content-Length` values (the header twice,
  or `5, 5`) are one length (RFC 9110 §8.6). A `Transfer-Encoding` other than
  one `chunked` is 501.
- picohttpparser validates the head behind our own adapter (`vm/http_parse.h`),
  so it can be swapped. No picohttpparser type leaks out of `vm/http_pico.c`.
- The adapter's own checks:
  - The pre-scan checks the line and head size limits (431), rejects bare LF
    (400, against smuggling), and counts header lines: more than 100 is 431.
  - The start line is checked before any header line: its length (431), then its
    shape. A request is `METHOD SP+ TARGET SP+ VERSION`, and a response is
    `VERSION SP+ 3DIGIT`. In a request, `HTTP/1`, `HTTP/2`, `HTTP/1.10` and
    `HTTP/2.0` are 505, and any other bad shape is 400. A complete bad start
    line fails at once, even where picohttpparser would wait for more.
  - The target is origin form, or `*` with `OPTIONS`, with bytes 33 to 126 only
    (400). The method is token characters only (400). `CONNECT` is 501.
  - Responses: `HTTP/1.1` only, status 100 to 599. 101 is rejected. At most 15
    interim responses are accepted, and the 16th fails. Responses fail as client
    error `Result`s.
- The body decoder (`vm/http_body.c`) is our own incremental state machine, set
  up with the framing and `max_body_bytes`. It gives 413 over the limit, 431 for
  an over-long chunk-size or trailer line and for trailers over their limits,
  and 400 for any other malformed body. Chunk sizes accumulate with saturation.
  Trailers are checked (token names, value bytes, the line, block and count
  limits, and no framing names: `content-length`, `transfer-encoding`, `host`,
  `connection`, `trailer`) and dropped; there is no trailer API. EOF inside a
  `Content-Length` or chunked body is `http: truncated HTTP body`; EOF ends a
  close-delimited body normally, except over TLS (10.7.1).
- Tests target the adapter interface, so a replacement parser must pass the same
  tests: the C unit test `vm/tests/http_parse_test.c`, and the socket cases of
  `tests/test_vm_http.py`, sent by Python raw-socket peers
  (`tests/fixtures/http-peer.py`, `tests/fixtures/http-server-peer.py`).

#### 10.6.1 As built (20a)

A response head with status 100 to 199 is returned without framing, and the
caller counts the interim responses. A `Content-Length` body is reserved whole
after the limit check.

### 10.7 HTTP on the VM: the hybrid split

HTTP is split between the C builtin module `HttpWire` and the Agentica module
`std/http.agc`, which programs import as `HTTP`. The API, options, limits and
answers are in `site/content/library/io-and-system/network.md`. Client
streaming is planned in `docs/future/30-hybrid-http.md`.
Both halves build and run on Linux, macOS and Windows: the C side works on
libuv sockets (`vm/tcp.c`, `vm/net.h`) and has no platform code of its own.

- **C (`HttpWire`)** is VM-only and std-only. It keeps the byte-level,
  security-critical and shared parts: the parser and decoder (10.6), the bytes
  of the error answers and of the response head, the client's
  pool and its `SSL_CTX` (one per client, until `TlsContext`,
  `docs/future/29-tls-context.md`), and the server's slots, task group and
  `close_server`. The server's parsing functions hold no state: each takes the
  bytes read so far and returns a record.
- **`std/http`** keeps the rest: options, URL parsing, request building, the
  accept and connection loops, the server's reads and writes, keep-alive,
  handler dispatch, and the header helpers. A body crosses as `Bytes` pieces
  joined once, on both sides.
- **Timeouts.** `get`, `post` and `request` block only the calling task. One
  `timeout_ms` covers the whole call: the wait for a pooled connection, DNS,
  connect, the TLS handshake, the request and the response. 4xx and 5xx are
  normal responses. The server has two deadlines per request, each
  `request_timeout_ms`: reading one whole request from its first byte, and
  writing the response from the handler's return. The handler's own run is not
  bounded. `idle_timeout_ms` is the wait for the next request on a kept-alive
  connection (server), and how long an idle pooled connection is kept (client).
- **Body limit and memory.** `max_body_bytes` defaults to 1 MiB on both sides
  and may be raised to 64 MiB. A body is held in C once and in its `Bytes`
  once, so body memory is at most `max_body_bytes` ×
  `max_connections` × 4 (512 MiB with the server defaults). A program that
  raises `max_body_bytes` must lower `max_connections`. A body over the limit
  is an `error` on the client, and a 413 on the server, before the handler
  runs. `HttpWire` itself takes up to 256 MiB, which only a file download
  (`HTTP.download`, streamed in pieces of at most 1 MiB) may
  use: the transfer stops at its `max_total_bytes`, the file never grows past
  it, and a failed download keeps the partial file.
- **Bodies are bytes.** The client keeps a response body as it came, a handler
  gets the request body as it came and returns `Bytes`; `HTTP.text` decodes
  it in the `charset` of `Content-Type` when `Bytes.decode` knows it (UTF-8
  without one; any other charset is an error). The server never
  answers 400 for the content of a body, only for its framing.
  `Content-Encoding` stays raw.
- **The handler returns its answer**, `Fn[HttpRequest, Result[HttpResponse]]`.
  An `error` becomes a 500 (10.7.3). The returned `Result` is used, so
  `CHECK-UNUSED-RESULT` applies (`docs/future/26-strict-diagnostics.md`).
- **Response framing** is always `Content-Length`, never chunked, never
  trailers. `HEAD` gets the head and no body, with the `Content-Length` of the
  body it would have sent. 204 and 304 get no body and no `Content-Length`, and
  a non-empty body with them is a 500. The request body is read in full before
  the handler runs, so keep-alive needs no "was the body consumed?" rule.
- **Incoming framing** is complete: chunked request bodies, and chunked or
  close-delimited response bodies, are decoded in full, within the limits.
- **Requests the client sends** carry `Content-Length` when the body is not
  empty or the method is `POST`, `PUT` or `PATCH`, and are never chunked. The
  client adds `Host`, and
  refuses user `Host`, `Content-Length`, `Transfer-Encoding` and `Connection`
  headers, and CR, LF and control bytes. It writes a large body while it reads
  the response, so an early 413 cannot deadlock the call.
- **Pool.** `HttpClient` keeps idle keep-alive connections per scheme, host and
  port, at most `max_connections` per origin. A call waits in FIFO order for a
  free one, within its timeout. A connection is leased for one call, and goes
  back to the pool only when the response was complete and neither side asked to
  close.
- **Server.** One task per connection, and requests on one connection run one at
  a time. `Upgrade` and `CONNECT` get 501 (a WebSocket handshake is the one
  `Upgrade` a `listen_websocket` server takes, 10.7.2), and `HTTP/1.1` only is
  accepted. At most `max_connections` connections are open at once, and an
  extra one waits in the kernel's backlog. `HTTP.wait` returns only after
  `HTTP.close_server`. When `main` returns or the run fails, every server and
  client is closed and every handler task stops.
- **Exposure.** `std/http` is reached by an explicit import,
  `import HTTP from "std/http"`, like `std/queue`. `HTTP` is a free alias. The
  record and handle types (`HttpRequest`, `HttpResponse`, `HttpClientOptions`,
  `HttpServerOptions`, `Header`, `HttpClient`, `HttpServer`) are global builtin
  names.
- **`HttpWire` is std-only.** A public raw layer would be a second way to do
  HTTP. The linker (`compiler/modules/resolve.agc`) gives `CHECK-UNKNOWN-NAME`
  for a qualified `HttpWire.f` in any module not embedded from `stdlib/` (the
  std-only modules of `compiler/catalog/builtins_data.agc`), and `help` leaves
  it out. The loader does not guard it: a crafted `.agcb` gets nothing `TCP` and
  `TLS` do not give (the trust model of `docs/vm/README.md` §1). `HttpWire` is
  a reserved name.
- **Options.** `HTTP.client` and `HTTP.listen` check every number first:
  positive, `max_connections` at most 65536, `max_body_bytes` at most 64 MiB. A
  bad record is an `error` result.
- **TLS** takes a `TlsContext` (10.3): `HttpClientOptions.tls` a client one
  (`none`: system trust), and the `listen_*_tls` forms a server one.

#### 10.7.1 As built: the client (20a)

The `HttpWire` signatures, for the client and the server, are its rows in
`compiler/catalog/builtins_data.agc`.

- The client is `std/http` code on `TCP`, `TLS`, `Channel` and `Task`.
  `HttpWire.service` (`vm/http_service.c`) runs `f(jobs)`, the client's owner
  task, under a service root (`agc_task_service` in `vm/task.c`). No caller's
  crash, cancel or end reaches it, `Task.pending_count` leaves its tasks out,
  `Test.test` does not see them as leftovers, and their timers do not keep a
  stalled run waiting (the stall checks count only the other timers). The owner
  owns `jobs`, so its end closes the channel. The `HttpClient` value holds the
  channel and the options; it prints `<HttpClient>`.
- `HTTP.request` parses the URL and builds the head with `encode_request`
  (`vm/http_wire.c`), which adds `Host` (the port only when it is not the
  scheme's default; an IPv6 host in brackets) and `Content-Length`, and refuses
  the user headers listed above and a body over `max_body_bytes`. It sends a
  `HttpWire.Job` with a reply channel of its own on `jobs`, and waits for the
  answer until its deadline, `timeout_ms` after the call, plus 100 ms of grace.
  `close_client` closes `jobs`, and a later call gets `http: client is closed`
  (what still runs: the last item of the differences below).
- With `proxy` in the options, std/http passes the absolute URL
  (`http://host:port/path`) as the target of `encode_request`, which still
  writes the target's `Host`. The job names the proxy as its origin, scheme,
  host and port, so the owner pools connections by the proxy and the worker
  connects to it (a failure names the proxy). `open`, `upload`, `download` and
  `start` do the same on their own connection. An `https` URL is refused
  before any connection: there is no `CONNECT` yet.
- The owner keeps, per origin (scheme, host and port), the open count, the idle
  workers and a FIFO of waiting jobs. A job goes to the idle worker freed last,
  else to a new worker while fewer than `max_connections` are open, else to the
  FIFO. A waiting job is dropped, never sent, when its deadline has passed (its
  caller has returned the timeout already) or when its caller gave up on the
  reply channel (`HttpWire.awaited?` is false: a receiver that had parked on it
  left without a value, by a cancel or a recv timeout; a caller that has not
  parked yet has not given up). When `jobs` is closed, the owner
  answers every waiting and running job with `http: client is closed`, closes
  the inboxes of the idle workers and ends. An origin with no connection and no
  waiting job is dropped from the owner's map.
- Crashes: the owner spawns each worker under a small supervisor task that
  awaits it as a `Result` task, so a worker's crash is observed, not reported
  as unobserved, and the supervisor then tells the owner the worker is gone.
  The owner frees the slot and sends `http: connection failed` to the reply of
  the worker's last job (the send fails when the worker had answered). The
  service task awaits the owner the same way: after an owner crash it closes
  `jobs`, so later calls get `http: client is closed`; the workers are
  cancelled with the owner and calls in flight return their timeout.
- A worker owns one connection, made with `TCP.connect`, `TLS.connect` (a
  client with `tls: some(context)`) or `HttpWire.connect_tls`, so DNS, connect,
  TLS and the close rules stay in tcp.c. `HttpWire.connect_tls` is
  `TLS.connect` with the client's own system-trust context: tcp.c builds one
  `SSL_CTX` on a pool thread at the first `https://` connection, and every
  later connection makes its `SSL` from it. Each connection, and the build,
  holds a reference, so `HttpWire.drop_tls` (run by the service task after
  `close_client`) frees the context only after the last handshake and
  connection let it go. A failed build is not kept: the next connection tries
  again. A `TlsContext` reads its CA file once, so a change to it reaches new
  contexts only. Its first job waits in its inbox, so no task keeps that job's
  body for the worker's life; the owner keeps only each
  worker's last reply channel. It runs a job, answers on the job's reply
  channel, tells the owner on `jobs` whether it keeps the connection, then waits
  on its inbox for `idle_timeout_ms`. The timeout closes the connection and ends
  the worker. The worker closes its inbox before its last look at it, so the
  owner cannot hand a job to a worker that has left: the send fails, and another
  worker takes the job. When the caller gave up on the reply channel
  (`HttpWire.awaited?`), the worker closes the connection instead of keeping it,
  as the library page says of a timed-out call
  (`site/content/library/concurrency/task.md`, "Task.map").
- Retry: a job on a reused connection that fails before any response byte (end
  of input, a read or write error) is retried once on a new connection, within
  the same deadline, if its method is `GET`, `HEAD`, `OPTIONS`, `PUT` or
  `DELETE`. This covers the race where the server closes an idle keep-alive
  connection as the request is sent.
- A body over 16 KiB is written by a task of its own while the response is
  read, so an early 413 is read. A response read after the request failed to
  go out is the answer; with no response the write error is.
- `read_response` (`vm/tcp.c`) reads the next response head like `read_head`
  and applies the framing rules: after `HEAD`, 204 or 304 no body follows (RFC
  9110 §9.3.2), and a 204 or 304 that still announced one is not kept; a
  close-delimited body is not kept either; a `Content-Length` over
  `max_body_bytes` is `http: body exceeds max_body_bytes`. An interim (1xx)
  head comes back as it is, and `std/http` reads at most 15 of them. The body is
  read with `TCP.recv_bytes` and `chunk` (whose runs say which bytes of a
  framing read are body) and kept as `Bytes`, whatever it holds.
- A connection is kept only after a complete exchange with no
  `Connection: close` on either side, a framed body, the whole request written
  and nothing after the response: `buffered` must be 0 and `ended` false on
  `HttpWire.Response` (after a head with no body), and after a body on
  `HttpWire.idle?`, which does not wait for input. Bytes there are a server bug
  or a response nobody asked for, and the next call must not read them; an
  input that has already ended (`ended`: the end of input, a TCP FIN under TLS,
  or a read error) would fail the next call. Header names are lowercased and
  values are Latin-1.
- **Over TLS, a close-delimited body must end with `close_notify`.** tcp.c
  records whether the TLS layer closed before the TCP FIN, and `clean_eof?`
  reads it after the end of input. A bare FIN gives `http: truncated HTTP body`.
  OpenSSL cannot tell the two apart here, since `SSL_OP_IGNORE_UNEXPECTED_EOF`
  makes a bare FIN look like `close_notify`.
- One deadline covers the call, from the wait for a connection to the last body
  byte. On timeout the connection is closed and the call returns
  `network: operation timed out`.

- Errors are `http: ` plus the text in `vm/http_parse.h`, the texts of
  `std/http`, or the network text of tcp.c.

Properties of the client that no test checks:

- An idle connection is not watched for a peer close. The retry covers the
  race.
- A cancelled caller only stops waiting: its job runs to its end or its
  deadline, and then its connection is closed.
- After `close_client` no request goes out that a worker had not started:
  every job still on `jobs`, waiting or in a worker's inbox is answered
  `http: client is closed`, and a worker checks `jobs.closed?` before it runs
  a job. A request a worker had already started still runs to its end; its
  caller also gets `http: client is closed`. The owner may still hand jobs to
  workers while it takes the messages buffered before the close, but those
  workers then see the close and send nothing.
- The client's work is bytecode, so it spends the step budget of
  `--max-steps`.

#### 10.7.2 As built: the server (20c)

- `vm/http_wire.c` holds the functions that take bytes or records and return
  records (`HttpWire.Chunk`, `HttpWire.Reply`). These, with
  `HttpWire.Head`, are std-only record types: only a std module can name them,
  and they reserve no user name. A `Chunk` holds the decoder's state between
  reads, and `chunk` checks every field before it decodes. `vm/tcp.c` holds the
  reads: `read_head` (the head stays in the socket's input until it is whole,
  is parsed only when a line ends, and only its bytes are taken; a bad head is a
  `Head` with the answer's `status` and `reason`), `idle?` (whether the input
  holds no byte and has not ended or failed; it takes none and never waits for
  input) and `close_write`.
- The I/O thread owns the server's state: the listener, the count of open
  connections and the queue of waiting `accept` and `wait` calls. A builtin
  changes it only through a step posted there (`agc_loop_call`, inline at
  N = 1), and the listener's watch runs there already. `accept` and `wait` are
  jobs that the I/O thread ends: an accept carries its connection to the done
  half, which makes the socket on the caller's scheduler. A connection task's
  end, and a socket that `spawn` does not take, give the room back with a
  posted step that serves the queue. `close_server` marks the server closed
  (an atomic flag, so a scheduler refuses at once), then posts the release
  that ends every waiter and gives up the listener. At N = 1 an accept with a
  connection ready returns without a job (`agc_io_here`). So the server runs
  at N > 1 under the same rules as TCP (§16.9), with no lock of its own.
- `std/http` reads a request: it waits up to `request_timeout_ms` (the first
  request) or `idle_timeout_ms` (later ones) for the first byte. On TLS that
  wait covers the handshake too. Then `request_timeout_ms`
  bounds the rest of the request. The checks run in this order: the parse
  errors of 10.6; an `Upgrade` header (501, unless the request is a `GET` with
  one `Upgrade: websocket`, which `std/http` then answers 501 itself on a route
  that does not upgrade, after the checks below: the `Expect` (417) and size
  (413) refusals of a handshake head come first there); an `Expect` other than
  `100-continue` (417); a `Content-Length` over `max_body_bytes` (413);
  `100 Continue` if `Expect` asked and no body byte is buffered; then the body,
  which is kept as it comes. The head goes through `read_head`, chunk framing
  through `chunk` on 512-byte reads, and body data through `TCP.recv_bytes`.
  Every error answer is `error_answer`: `HTTP/1.1 CODE REASON` with
  `Content-Length: 0` and `Connection: close`. It is sent within the request
  deadline, or within 100 ms when that has passed. The write side is then shut
  (`close_write`), and input is read and dropped until the peer closes, the
  deadline, or 256 KiB (`DRAIN_BYTES`, as in Go's net/http), whichever comes
  first. This way unread request bytes cannot turn the close into a reset that
  loses the answer, and a peer that keeps sending cannot hold the server
  reading. A peer that is still sending a large body after the limit may see a
  reset instead of the answer. The read returns `error("http: <reason>")`. EOF
  before the first byte is `network: end of input`. EOF mid-request is
  `http: connection closed before the request was complete`. The deadline
  returns `network: operation timed out` with no answer. TCP reads only while
  a reader waits, so pipelined bytes cannot grow the buffer past one read.
  Bytes past one request stay in the socket's input for the next, except the
  bytes a chunked body's last read took, which `read_head` puts back.
- The response head is `encode_response`, built before anything is written, with
  whether the connection closes after it. The status must be 200 to 599. A
  handler's `Content-Length` or `Transfer-Encoding` is refused
  (`Content-Length and Transfer-Encoding are set by the server`). A `Date`
  header is added unless the handler set one. A `Connection: close` in the
  request or the response closes the connection, and the handler's `Connection`
  headers are replaced by one `Connection: close`. A bad response is
  `error("http: invalid response: <reason>")`, with nothing written. Otherwise
  the write returns `ok(true)` while the connection stays open, and `ok(false)`
  after a closing response, which gets the same lingering close as the error
  answers.
- `server` takes the listener off its owner's list: the server owns it, so only
  the server's close closes it, ending the server's owner closes both, and
  handing the server to another task with `Task.spawn_owning` moves both. It
  runs `f(server)` (the accept loop of `std/http`) as a task of the group, so
  `close_server` cancels it with the connections, and a server closed inside
  `Test.run` leaves no task running. `accept` returns a socket once fewer than
  `max_connections` are open, and parks otherwise. A TLS socket is returned
  before its handshake, which runs under the first read's or write's timeout.
- `spawn` is the hand-off of `Task.spawn_owning`
([handle ownership][task-rules])
  into the server's group, through the port function `agc_task_spawn_owning`: it
  starts `f(socket)` as a child of the group and gives it the socket, which the
  caller (the accept loop of `std/http`) must own, or the call fails with
  `RUNTIME-HANDLE-NOT-OWNED`. It marks the task `hidden` and sets an end hook
  that frees the slot and wakes a waiting `accept`. It does not close the
  socket: the socket belongs to the connection task, so the one close path of
  [§14.5](14-core-invariants.md#145-handles) closes it when that task ends in
  any way (return, crash or cancel). There is no group registration of sockets.
- `close_server` is idempotent. It closes the listener, wakes `accept` (which
  returns `http: server is closed`) and `wait` (which returns `ok()`), and drops
  the group, which cancels the subtree. Every cancelled task closes the handles
  it owns as it ends, so the connection sockets close, and so do the sockets a
  handler's spawned task opened. A server is a handle owned by the task that
  made it: when that task ends (returns, crashes or is cancelled), the one close
  path runs `close_server` for it, and its port is free. A running task that
  closes its own server stops after that builtin
  (`vm/tests/task_cancel_test.c`).

- `std/http` runs the accept loop in the group. For each socket it spawns the
  connection loop: read a request, run the handler, then write the response.
  The loop ends when the write returns anything but `ok(true)`.
- A `listen_stream` server runs the same loop with a handler that returns a
  `StreamResponse`. A body channel that is already closed with its pieces
  buffered is the whole body: it goes out with `Content-Length`, in the head of
  the same encoding. Pieces are `Bytes` and go out with `TCP.send_bytes`, so no
  UTF-8 check runs on them. Otherwise the head is `encode_response` of the same
  status and headers with an empty body, its `Content-Length: 0` swapped for
  `Transfer-Encoding: chunked` (so the head checks and the C code are the same),
  and the connection task sends the pieces as it takes them from the channel.
  With `length: some(n)` the head carries `Content-Length: n` in place of the
  chunked header and the pieces go out raw; the pump counts the bytes, cuts the
  connection when the body ends short or a piece would pass `n`, sends no last
  chunk and ends the body when it is full: it reads the watcher before the last
  byte goes out, as it does before a last chunk, closes the channel, and does
  not wait for the producer to close, since the client has its bytes and may
  send its next request at once. A length of 0 never streams: it goes out like
  an empty closed body, since the head is then the whole answer. A watcher task,
  spawned in the group, loops on `TCP.recv_bytes` for the whole stream: the end
  of the client's input (or a read error) sets a one-slot `left` channel and
  closes the body channel, which wakes the connection task and fails the
  producer's next `send`, with no write needed; the pump then sees `left` and
  does not send the last chunk, so the client sees a cut body. Bytes read while
  the stream runs are dropped and set a `sent` channel: a socket read cannot be
  stopped without losing bytes (the cancel of a read that has completed drops
  its result), so the bytes of a pipelined request are not kept and the
  connection closes at the end of the stream, after `close_write` and a drain
  (as does `Connection: close`, or a request already in the buffer). When the
  stream has ended with nothing read, the watcher's pending read is the wait for
  the next request: its bytes go back as the start of the request, and the
  connection task waits for them at most `idle_timeout_ms`. `take_ready` and the
  pump read the end of the body from the receive's own error (`channel:
  closed`), not from a later `closed?`. HTTP/1.0 never gets here: the parser
  answers 505.
- A `listen_upload` server reads the head (and the framing checks: 413 over
  256 MiB, 400, 411, 417 and the `100 Continue`) the same way, then spawns a
  feeder task and calls the handler with `RequestBody(pieces, done)`. The
  feeder reads the socket in steps of at most 64 KiB (the wait of each is
  `request_timeout_ms`, also for a piece the handler has not taken) and sends
  each piece, chunked bodies decoded, into an 8-slot channel, so memory per
  connection is about 512 KiB. It sends the bytes it read past the body to a
  one-slot `rest` channel, then closes `pieces`, and its result is `done`. When
  the handler returns, the server closes `pieces` and looks at `rest` without
  waiting: a value means the body was read whole, so the answer goes out as it
  is and the connection serves the next request, starting from `rest`. No value
  means the handler answered early or the body failed: the answer gets
  `Connection: close`, the feeder is cancelled, the input is drained for at most
  the answer time and the connection closes. `HTTP.read_all` is a receive loop
  over `pieces` with a byte limit that awaits `done`.
- A `listen_websocket` server reads the request whole, as `listen` does, and
  calls the handler, which answers (`Upgrade.Reply`, served as a `listen`
  answer, the connection kept) or upgrades. An upgrade writes the 101 head
  by hand (`Sec-WebSocket-Accept` is the base64 of `Digest.sha1` of the key and
  the GUID of RFC 6455), then runs the session in the connection task with
  three tasks around it. The reader is the only task that reads the socket: it
  takes the frame head (two bytes, then the length and mask), checks it before
  it reads the payload (masked, no reserved bits, known opcode, control frames
  whole and at most 125 bytes, the length against `max_message_bytes`), unmasks
  the payload in a loop over its bytes (about 7 MB/s), joins fragments, checks
  UTF-8 and close codes, and sends whole messages to `incoming`. The
  forwarder turns the handler's `outgoing` messages into frames for the writer.
  The writer is the only task that writes the socket and the one that ends the
  connection: its channel holds frames and four verdicts (our close frame, the
  answer to the peer's, a failure frame, the loss of the peer), and it
  finishes when the handshake is done, on a failed write, or `close_ms` after
  our close frame. The reader answers a close frame (the echo goes to the writer
  before the handler hears the `Close`). Every path ends with one `Close` on
  `incoming`: the peer's, the code of the failure, or 1006. The pure part (the
  frame codec, the checks and the accept key) is `std/internal/websocket`; a
  read timeout closes the socket, so `idle_ms` is the timeout of each read and
  `ping_ms` is the timeout of the writer's wait.

#### 10.7.3 Errors and status codes

**Server side**, in the order they can happen:

- **Case:** Malformed or hostile head or body: bad start line, bare LF,
  obs-fold, bad target or method, bad framing, or not exactly one non-empty
  `Host` header
  - **Who:** C
  - **Answer:** 400, `Connection: close`, empty body, then close. The handler
    never runs

- **Case:** A line, the head, the header count or the trailers over their limits
  - **Who:** C
  - **Answer:** 431, then close

- **Case:** A body over `max_body_bytes` (a `Content-Length` over it is answered
  before any body byte is read)
  - **Who:** C
  - **Answer:** 413, then close

- **Case:** A version `HTTP/[0-9.]+` other than `HTTP/1.1`
  - **Who:** C
  - **Answer:** 505, then close

- **Case:** `CONNECT`, `Upgrade` (except a `GET` with one `Upgrade: websocket`
  on a `listen_websocket` route), a `Transfer-Encoding` other than one `chunked`
  - **Who:** C
  - **Answer:** 501, then close

- **Case:** An `Expect` other than `100-continue`
  - **Who:** C
  - **Answer:** 417, then close

- **Case:** `Expect: 100-continue` with a `Content-Length` over `max_body_bytes`
  - **Who:** C
  - **Answer:** 413, then close, with no 100 Continue first

- **Case:** The client is too slow for `request_timeout_ms` (request or
  response), or the idle wait ends
  - **Who:** C
  - **Answer:** The connection is closed

- **Case:** The handler returns `error(message)`
  - **Who:** `std/http`
  - **Answer:** 500, `Connection: close`, empty body. The message is not sent.
    `http: handler error: <message>` goes to stderr

- **Case:** The handler returns a response that cannot be sent (status outside
  200 to 599, a bad or framing header, a body with 204 or 304)
  - **Who:** C refuses, `std/http` answers
  - **Answer:** 500, `Connection: close`, and `http: invalid response: <reason>`
    on stderr

- **Case:** A runtime diagnostic in the handler
  - **Who:** The VM
  - **Answer:** The connection task crashes (handle ownership). The client sees
    the close,
    and the server goes on

- **Case:** A handler that runs a long time
  - **Who:** None
  - **Answer:** Never stopped. Its reply is still sent, with a fresh
    `request_timeout_ms` for the write

- **Case:** Writing the response fails (the client left)
  - **Who:** C
  - **Answer:** The connection is closed quietly

The codes that the hostile-case goldens fix are those 10.6 marks as fixed.
`IO.warn` lines are program stderr, so the golden fixtures record them.

**Client side:** every failure is an `error` result, never a diagnostic. That
covers a URL that is not `http://` or `https://` with a host (userinfo and
non-ASCII are rejected), DNS, connect and TLS failures, the timeout,
`http: client is closed`, a malformed response, a body over `max_body_bytes`,
and a truncated body. A body that is not valid in its charset is no failure of
the call: `HTTP.text` refuses it. A connection that fails is never pooled.

#### 10.7.4 Tests

- **Goldens** (`tests/fixtures/vm/http-*.agc` and `.expected`) are their own
  peers: one program runs a server and a client in two tasks, and only `main`
  prints. A case that depends on a timeout cannot be a golden, since goldens
  record step counts.
- **The hostile cases of 10.6** run against the VM server, sent by a Python
  raw-socket peer (`tests/test_vm_http.py`, standard library only), and check
  the status code and the close. The C unit test (`vm/tests/http_parse_test.c`)
  covers the same list at the adapter.
- **Interop on port 0** (`tests/test_vm_http.py`, standard library only): the
  VM client against Python's `http.server` and an HTTPS server made with
  Python's `ssl` and the CA of `tests/fixtures/tls/`; the VM server against
  Python's `http.client` and Node's `http`. Python and Node are required in CI.
- **Guards**: a user file, a `pkg/` module and a relative import that call
  `HttpWire.service` each get `CHECK-UNKNOWN-NAME` with the `std/http` help
  (the `check` spec tests of the modules rules).
- **Performance** is not a CI gate: `benchmarks/http_bench.py` against
  `examples/http_server.agc`. The numbers go in `docs/vm-benchmarks.md`.

[task-rules]: ../../site/content/library/concurrency/task.md
