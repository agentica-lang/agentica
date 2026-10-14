### 10.6 HTTP parsing

HTTP on the VM uses whole messages and `String` bodies. Streaming waits for channels (10.7). The rules of this section are fixed by the hostile-case tests (10.7.4).

- Well-formed messages give the status, headers and body, as an ok `Result`.
- Malformed or hostile input is rejected. A server answers with an error status and closes. A client request call returns an error `Result`. These codes are fixed: 400 (malformed head or body), 413 (body over the limit), 417 (an `Expect` other than `100-continue`), 431 (too many headers or trailers, or a line, head or trailer block over its limit), 505 (a request version `HTTP/[0-9.]+` other than `HTTP/1.1`), and 501 (`CONNECT`, or a `Transfer-Encoding` other than one `chunked`). Any other code is free.
- Leniencies: picohttpparser's RFC 9112 leniencies are accepted (one leading empty line before a request, runs of spaces in the start line). They never make framing ambiguous.
- Framing is strict. `Content-Length` with any `Transfer-Encoding` is 400, checked first. Conflicting `Content-Length` values, bad chunk sizes and obs-fold are 400. Equal duplicate `Content-Length` values (the header twice, or `5, 5`) are one length (RFC 9110 §8.6). A `Transfer-Encoding` other than one `chunked` is 501.
- picohttpparser validates the head behind our own adapter (`vm/http_parse.h`), so it can be swapped. No picohttpparser type leaks out of `vm/http_pico.c`.
- The adapter's own checks:
  - The pre-scan checks the line and head size limits (431), rejects bare LF (400, against smuggling), and counts header lines: more than 100 is 431.
  - The start line is checked before any header line: its length (431), then its shape. A request is `METHOD SP+ TARGET SP+ VERSION`, and a response is `VERSION SP+ 3DIGIT`. In a request, `HTTP/1`, `HTTP/2`, `HTTP/1.10` and `HTTP/2.0` are 505, and any other bad shape is 400. A complete bad start line fails at once, even where picohttpparser would wait for more.
  - The target is origin form, or `*` with `OPTIONS`, with bytes 33 to 126 only (400). The method is token characters only (400). `CONNECT` is 501.
  - Responses: `HTTP/1.1` only, status 100 to 599. 101 is rejected. At most 15 interim responses are accepted, and the 16th fails. Responses fail as client error `Result`s.
- The body decoder (`vm/http_body.c`) is our own incremental state machine, set up with the framing and `max_body_bytes`. It gives 413 over the limit, 431 for an over-long chunk-size or trailer line and for trailers over their limits, and 400 for any other malformed body. Chunk sizes accumulate with saturation. Trailers are checked (token names, value bytes, the line, block and count limits, and no framing names: `content-length`, `transfer-encoding`, `host`, `connection`, `trailer`) and dropped; there is no trailer API. EOF inside a `Content-Length` or chunked body is `http: truncated HTTP body`; EOF ends a close-delimited body normally, except over TLS (10.7.1).
- Until the streaming items (20e to 20g) there is no chunked encoder. Responses always carry `Content-Length`, and requests are never chunked.
- Tests target the adapter interface, so a replacement parser must pass the same tests: the C unit test `vm/tests/http_parse_test.c`, and the socket cases of `tests/vm-http-test.rkt`, sent by Python raw-socket peers (`tests/fixtures/http-peer.py`, `tests/fixtures/http-server-peer.py`).

#### 10.6.1 As built (20a)

The limits are constants in `vm/http_parse.h`: `AGC_HTTP_MAX_LINE` (8192), `AGC_HTTP_MAX_BLOCK` (65536) and `AGC_HTTP_MAX_HEADERS` (100). A response head with status 100 to 199 is returned without framing, and the caller counts the interim responses. A `Content-Length` body is reserved whole after the limit check. Only `vm/http_pico.c` and the Makefile know picohttpparser.

### 10.7 HTTP on the VM: the hybrid split (phase 20; the client and the server are built)

HTTP is split between the C builtin module `HttpWire` and the Agentica module `std/http.agc`, which programs import as `HTTP`. The API, options, limits and answers are in the grammar (`docs/grammar/06d-io-and-network.md`, "HTTP client and server"). The client is 10.7.1, the server 10.7.2, the answers 10.7.3 and the tests 10.7.4. Streaming is planned in `docs/future/30-hybrid-http.md`.

- **C (`HttpWire`)** is VM-only and std-only. It keeps the byte-level, security-critical and shared parts: the parser and decoder (10.6), the UTF-8 check, the error answers before dispatch, response writing with `Content-Length` only, the client's pool and its `SSL_CTX` (one per client, until `TlsContext`, `docs/future/29-tls-context.md`), and the server's slots, task group and `close_server`.
- **`std/http`** keeps the rest: options, URL parsing, request building, the accept and connection loops, keep-alive, handler dispatch, and the header helpers. A body crosses once, as a `String`.
- **Timeouts.** `get`, `post` and `request` block only the calling task. One `timeout_ms` covers the whole call: the wait for a pooled connection, DNS, connect, the TLS handshake, the request and the response. 4xx and 5xx are normal responses. The server has two deadlines per request, each `request_timeout_ms`: reading one whole request from its first byte, and writing the response from the handler's return. The handler's own run is not bounded. `idle_timeout_ms` is the wait for the next request on a kept-alive connection (server), and how long an idle pooled connection is kept (client).
- **Body limit and memory.** `max_body_bytes` defaults to 1 MiB on both sides and may be raised to 64 MiB. A body is held in C once and in its `String` once, so body memory is at most `max_body_bytes` × `max_connections` × 4 (512 MiB with the server defaults). A program that raises `max_body_bytes` must lower `max_connections`. A body over the limit is an `error` on the client, and a 413 on the server, before the handler runs.
- **Bodies are text.** A request or response body must be valid UTF-8. The client returns an `error` for a response body that is not, and the server answers 400 without running the handler. Binary bodies wait for `Bytes` (phase 13). `Content-Encoding` stays raw.
- **The handler returns its answer**, `Fn[HttpRequest, Result[HttpResponse]]`. An `error` becomes a 500 (10.7.3). The returned `Result` is used, so `CHECK-UNUSED-RESULT` applies (`docs/future/26-strict-diagnostics.md`).
- **Response framing** is always `Content-Length`, never chunked, never trailers. `HEAD` gets the head and no body, with the `Content-Length` of the body it would have sent. 204 and 304 get no body and no `Content-Length`, and a non-empty body with them is a 500. The request body is read in full before the handler runs, so keep-alive needs no "was the body consumed?" rule.
- **Incoming framing** is complete: chunked request bodies, and chunked or close-delimited response bodies, are decoded in full in C, within the limits.
- **Requests the client sends** carry `Content-Length` when the body is not empty or the method is `POST`, `PUT` or `PATCH`. The client adds `Host`, and refuses user `Host`, `Content-Length`, `Transfer-Encoding` and `Connection` headers, and CR, LF and control bytes. It writes the body while it reads the response, so an early 413 cannot deadlock the call.
- **Pool.** `HttpClient` keeps idle keep-alive connections per scheme, host and port, at most `max_connections` per origin. A call waits in FIFO order for a free one, within its timeout. A connection is leased for one call, and goes back to the pool only when the response was complete and neither side asked to close.
- **Server.** One task per connection, and requests on one connection run one at a time. `Upgrade` and `CONNECT` get 501, and `HTTP/1.1` only is accepted. At most `max_connections` connections are open at once, and an extra one waits in the kernel's backlog. `HTTP.wait` returns only after `HTTP.close_server`. When `main` returns or the run fails, every server and client is closed and every handler task stops.
- **Exposure.** `std/http` is reached by an explicit import, `import "std/http" as HTTP`, like `std/queue`. `HTTP` is a free alias. The record and handle types (`HttpRequest`, `HttpResponse`, `HttpClientOptions`, `HttpServerOptions`, `Header`, `HttpClient`, `HttpServer`) are global builtin names.
- **`HttpWire` is std-only.** A public raw layer would be a second way to do HTTP. The linker (`src/modules.rkt`) gives `CHECK-UNKNOWN-NAME` for a qualified `HttpWire.f` in any module not embedded from `stdlib/` (`std-only-modules` in `src/builtins.rkt`), and `help` leaves it out. The loader does not guard it: a crafted `.agcb` gets nothing `TCP` and `TLS` do not give (the trust model of `docs/vm/README.md` §1). `HttpWire` is a reserved name.
- **Options.** `HTTP.client` and `HTTP.listen` check every number first: positive, `max_connections` at most 65536, `max_body_bytes` at most 64 MiB. A bad record is an `error` result.
- **TLS** keeps the file paths (`ca_file`, `cert_file`, `key_file`) until `TlsContext`.

#### 10.7.1 As built: the client (20a)

```text
HttpWire.client(timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String) -> Result[HttpClient]
HttpWire.exchange(client: HttpClient, scheme: String, host: String, port: Int, method: String, target: String, headers: List[Header], body: String) -> Result[HttpResponse]
HttpWire.close_client(client: HttpClient) -> Void
```

- `exchange` reads `timeout_ms` and `max_body_bytes` from the client, since `std/http` cannot read them back from the opaque handle.
- `vm/http_client.c` (Linux; a stub elsewhere) keeps, per origin, the idle connections, the open slot count and a FIFO of waiting exchanges. Idle connections close after `idle_timeout_ms` (one timer per client) or when the peer closes them.
- Retry: an exchange that leased an idle connection and then fails before any response byte (EOF, a read or write error) is retried once on a new connection, at the head of the waiters, within the same timeout, if its method is `GET`, `HEAD`, `OPTIONS`, `PUT` or `DELETE`. This covers the race where the server closes an idle keep-alive connection as the request is sent.
- Connections are tcp.c's (`vm/net.h`), so DNS, connect, TLS and the close rules stay in one place.
- `exchange` adds `Host` (the port only when it is not the scheme's default; an IPv6 host in brackets) and `Content-Length`, and refuses the user headers listed above. A connection goes back to the pool only after a complete exchange with no `Connection: close` on either side and a framed body. Header names are lowercased, values are Latin-1, and the body must be valid UTF-8.
- After 204 or 304 the connection is not kept if the response still announced a body. After `HEAD` it is kept, since no body follows a `HEAD` response whatever it announces (RFC 9110 §9.3.2). Bytes already buffered when an exchange ends close the connection. A freed connection goes to the first waiter after a 1 ms timer, so bytes that arrive in that window close it first. This is a narrow guard, not a promise. Idle connections are unreferenced in libuv, so a pool never hides a stalled run.
- **Over TLS, a close-delimited body must end with `close_notify`.** tcp.c records whether the TLS layer closed before the TCP FIN. A bare FIN gives `http: truncated HTTP body`. OpenSSL cannot tell the two apart here, since `SSL_OP_IGNORE_UNEXPECTED_EOF` makes a bare FIN look like `close_notify`.
- One `timeout_ms` covers the call, from the wait for a slot to the last body byte. On timeout the connection is closed and the call returns `network: operation timed out`. `close_client` closes idle connections and fails every call in flight with `http: client is closed`.
- At the end of the run, the client's goodbye hook sends one non-blocking `close_notify` on each HTTPS connection, idle or in use (§10.2.2).
- Errors are `http: ` plus the text in `vm/http_body.c` (or `vm/http_client.c`), or the network text of tcp.c.

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

- `vm/http_server.c` (Linux; a stub elsewhere) holds them, on tcp.c's connection object. Header lists are shared with the client in `vm/http_fields.c`.
- `read_request` waits up to `first_byte_timeout_ms` for the first byte. A raw byte on the socket counts, so a TLS handshake does too. Then the timeout is `timeout_ms`, which bounds the rest of the request. The checks run in this order: the parse errors of 10.6; an `Upgrade` header (501); an `Expect` other than `100-continue` (417); a `Content-Length` over `max_body_bytes` (413); `100 Continue` if `Expect` asked and the body is still to come; the body and its UTF-8 check (400). Every error answer is written by C as `HTTP/1.1 CODE REASON` with `Content-Length: 0` and `Connection: close`. The write side is then shut, and input is read and dropped until the peer closes or the deadline, so unread request bytes cannot turn the close into a reset that loses the answer. The call returns `error("http: <reason>")`. EOF before the first byte is `network: end of input`. EOF mid-request is `http: connection closed before the request was complete`. The deadline returns `network: operation timed out` with no answer. Once a request is complete, the socket stops reading until the next `read_request`, so pipelined bytes cannot grow the buffer.
- `write_response` builds the whole response before it writes. The status must be 200 to 599. A handler's `Content-Length` or `Transfer-Encoding` is refused (`Content-Length and Transfer-Encoding are set by the server`), and a 204 or 304 gets no body. A `Date` header is added unless the handler set one, and the body is omitted for `HEAD`. A `Connection: close` in the request or the response closes the connection, and the handler's `Connection` headers are replaced by one `Connection: close`. A bad response is `error("http: invalid response: <reason>")`, with nothing written. Otherwise it returns `ok(true)` while the connection stays open, and `ok(false)` after a closing response, which gets the same lingering close as the error answers.
- `server` runs `f(server)` (the accept loop of `std/http`) as a task of the group, so `close_server` cancels it with the connections, and a server closed inside `Test.run` leaves no task running. `accept` returns a socket once fewer than `max_connections` are open, and parks otherwise. A TLS socket is returned before its handshake, which runs under the first read's or write's timeout.
- `spawn` starts `f(socket)` as a child of the group, moves the socket to it, marks the task `hidden`, and sets an end hook that closes the socket and frees the slot when the task ends in any way.
- `close_server` is idempotent. It closes the listener, wakes `accept` (which returns `http: server is closed`) and `wait` (which returns `ok()`), and drops the group, which cancels the subtree and closes every handle a task of it owns. So the connection sockets close, and so do the sockets a handler's spawned task opened. A running task that closes its own server stops after that builtin (`vm/tests/task_cancel_test.c`).
- A crash in a connection task ends that connection (§37.5), and its client sees the close with no response (Crashes, 10.2.1).
- `std/http` runs the accept loop in the group. For each socket it spawns the connection loop: `read_request` (the first request waits `request_timeout_ms` for its first byte, later ones `idle_timeout_ms`), the handler with no time limit, then `write_response` with a fresh `request_timeout_ms`. A handler `error`, or a response that `write_response` refuses, gives a 500 with `Connection: close` and one `IO.warn` line (`http: handler error: ...` or `http: invalid response: ...`). The loop ends when `write_response` returns anything but `ok(true)`.
- The connections are tcp.c sockets, so they get `close_notify` at the end of the run (10.3).

#### 10.7.3 Errors and status codes

**Server side**, in the order they can happen:

| Case | Who | Answer |
|---|---|---|
| Malformed or hostile head or body: bad start line, bare LF, obs-fold, bad target or method, bad framing, or not exactly one non-empty `Host` header | C | 400, `Connection: close`, empty body, then close. The handler never runs |
| A line, the head, the header count or the trailers over their limits | C | 431, then close |
| A body over `max_body_bytes` (a `Content-Length` over it is answered before any body byte is read) | C | 413, then close |
| A version `HTTP/[0-9.]+` other than `HTTP/1.1` | C | 505, then close |
| `CONNECT`, `Upgrade`, a `Transfer-Encoding` other than one `chunked` | C | 501, then close |
| An `Expect` other than `100-continue` | C | 417, then close |
| `Expect: 100-continue` with a `Content-Length` over `max_body_bytes` | C | 413, then close, with no 100 Continue first |
| A request body that is not UTF-8 | C | 400, then close |
| The client is too slow for `request_timeout_ms` (request or response), or the idle wait ends | C | The connection is closed |
| The handler returns `error(message)` | `std/http` | 500, `Connection: close`, empty body. The message is not sent. `http: handler error: <message>` goes to stderr |
| The handler returns a response that cannot be sent (status outside 200 to 599, a bad or framing header, a body with 204 or 304) | C refuses, `std/http` answers | 500, `Connection: close`, and `http: invalid response: <reason>` on stderr |
| A runtime diagnostic in the handler | The VM | The connection task crashes (§37.5). The client sees the close, and the server goes on |
| A handler that runs a long time | None | Never stopped. Its reply is still sent, with a fresh `request_timeout_ms` for the write |
| Writing the response fails (the client left) | C | The connection is closed quietly |

The codes that the hostile-case goldens fix are those 10.6 marks as fixed. `IO.warn` lines are program stderr, so the golden fixtures record them.

**Client side:** every failure is an `error` result, never a diagnostic. That covers a URL that is not `http://` or `https://` with a host (userinfo and non-ASCII are rejected), DNS, connect and TLS failures, the timeout, `http: client is closed`, a malformed response, a body over `max_body_bytes`, and a body that is not UTF-8. A connection that fails is never pooled.

#### 10.7.4 Tests

- **Goldens** (`tests/fixtures/vm/http-*.agc` and `.expected`) are their own peers: one program runs a server and a client in two tasks, and only `main` prints. They cover the methods and statuses, the error answers, keep-alive reuse, `Connection: close`, the body limit at and one byte over, `close_server` while a handler sleeps, and `main` returning while a call is in flight. Fixtures that depend on a timeout go in the Racket test, since goldens record step counts.
- **The hostile cases of 10.6** run against the VM server, sent by a Python raw-socket peer (`tests/vm-http-test.rkt`, standard library only), and check the status code and the close. The C unit test (`vm/tests/http_parse_test.c`) covers the same list at the adapter.
- **Interop on port 0** (`tests/vm-http-test.rkt`, standard library only): the VM client against Python's `http.server` and against an HTTPS server made with Python's `ssl` and the CA of `tests/fixtures/tls/`; the VM server against Python's `http.client` and Node's `http`, including chunked uploads, `Expect: 100-continue`, pipelining and many concurrent clients up to `max_connections`. Python and Node are required in CI.
- **Guards**: a user file, a `pkg/` module and a relative import that call `HttpWire.exchange` each get `CHECK-UNKNOWN-NAME` with the `std/http` help (`tests/modules-test.rkt`).
- **Performance** is not a CI gate: `benchmarks/http_bench.py` against `examples/http_server.agc`. The numbers go in `docs/vm-benchmarks.md` (roadmap 20c-bench).
