## 30. HTTP on the VM: simple, synchronous, hybrid

**Status:** planned (roadmap phase 20), decided by the user on 2026-10-12. Two parts:

- **Simple HTTP** (20a to 20d, 30.1 to 30.10; 20d is now merged into 20c) is HTTP on the VM ([the order table](../roadmap/README.md#current-implementation-order)): after TLS on the VM; 20a came before BDD in Agentica ([section 31](31-bdd-in-agentica.md#31-bdd-in-agentica), roadmap [phase 21](../roadmap/21-bdd-in-agentica.md)); 20b and 20c come after 7i (order step 7.2.1), and 20c brings the server back (see the next point). It also changes the API on purpose, with the user's decision: a call sends a whole request and gets a whole response, a handler returns a whole response, and there is no streaming. That is a breaking change made during the catch-up (30.8).
- **Changed on 2026-10-13 (owner decision):** 7i comes before 20b to 20d; the order is 7i, then HTTP 20b, then task crash isolation ([phase 24](../roadmap/24-task-crash-isolation.md), [§37](37-task-crash-isolation.md#37-task-crash-isolation)), then unit tests ([phase 25](../roadmap/25-unit-tests.md), [§36](36-unit-tests.md#36-unit-tests-test)), then 20c, then doc comments (phase 22) and digit separators (phase 23). 7i deleted the builtin `HTTP` module together with the evaluator, its last reason to exist: the 23 catalog entries, the types that only it used (`Request`, `Response`, `HttpBody`, `HttpWriter`, `HttpServer`, `HttpServerOptions`), `src/http-*.rkt`, the `http-producer` rule and the one-argument `HTTP.client`. `HTTP` left the reserved names, so `import "std/http" as HTTP` is the documented import from 7i on, and an `HTTP.` call without it gets the import help. Programs keep the `std/http` client (20a); 20c brought the server back (with `HttpRequest`, `HttpServer` and `HttpServerOptions`; as built in `docs/vm/10-io-tls-processes-http.md` §10.7.2). What was left of 20d (the server hints, the performance check) moved into 20c.
- **Streaming** (20e to 20g, 30.11) is a new feature, VM-only, at order step 7.4: after phase 17 (`Task.map` and channels, §27), since it is built on `Channel[T]` (§27.2), and right before `TlsContext` (§29, phase 19).

**What is asked for:** HTTP on the VM, written as much as possible in Agentica (`std/` first), with C only where it must be: byte-level work, security-critical parsing and hot paths. And an API that is synchronous and very simple: one call, one whole message.

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms) (one way to do each thing, immutable values, static types), the [std-first rule](../roadmap/README.md#new-library-features-std-first), the golden-output rule of `docs/vm/README.md` §1, and the strict parsing rules of `docs/vm/10-io-tls-processes-http.md` §10.6, which do not move.

| § | Item | Roadmap |
|---|---|---|
| 30.3 | The API after phase 20 | 20a (client), 20c (server), 20d (the switch) |
| 30.4 | Errors and status codes | 20a, 20c, 20d |
| 30.5 | The split: `HttpWire` in C, `std/http` in Agentica | 20a to 20d |
| 30.6 | Server tasks, `close_server` and task cancellation | 20b (cancellation core), 20c (the group) |
| 30.7 | How `std/http` is exposed: an explicit import | 20a (the module), 20d (the `HTTP` alias) |
| 30.8 | Migration: what is removed and what it breaks; programs the evaluator cannot run | 20a, 20d |
| 30.9 | What the old C-only design drops | 20a, 20c |
| 30.10 | Tests | each item |
| 30.11 | Streaming on channels | 20e, 20f, 20g |
| 30.12 | Later: binary bodies, `TlsContext` | phase 13, phase 19 |

### 30.1 Today

- **The API** (`docs/grammar.md:798`, `src/builtins.rkt:68` to `src/builtins.rkt:90`): 23 `HTTP` builtins. The client returns a `Response` as soon as its head arrives, with a streaming `HttpBody`; the body is read with `HTTP.read` (bytes, as `List[Int]`) or `HTTP.text` (at most 1 MiB), then `HTTP.trailers` or `HTTP.close_body`. `HTTP.request_stream` uploads through a producer `Fn[A, HttpWriter, Result[Void]]` and an `argument: A`, a generic signature that no user function could have. The server calls a handler `Fn[Request, HttpWriter, Void]`, which answers through `HTTP.begin`, `write`, `write_bytes`, `finish` or `respond`.
- **The code** is Racket on the frozen evaluator: `src/http-wire.rkt` (framing: `read-request-head` at `src/http-wire.rkt:86`, `read-response-head` at `src/http-wire.rkt:108`, the body at `src/http-wire.rkt:126`, the writer at `src/http-wire.rkt:257`), `src/http-client.rkt` (the pool: `make-http-client` at `src/http-client.rkt:21`, `acquire` at `src/http-client.rkt:81`, `http-client-request` at `src/http-client.rkt:140`) and `src/http-server.rkt` (`make-http-server`, with the accept loop, one task per connection, 100 Continue, 417, 501 for `Upgrade`, and 500 for a handler that never began a response).
- **On the VM** nothing of HTTP exists. A program that calls an `HTTP` builtin gets `LOWER-UNSUPPORTED` and the driver runs it on the evaluator (`src/main.rkt:318`). The C design of `docs/vm/10-io-tls-processes-http.md` §10.6 (picohttpparser behind our adapter, our own incremental body decoder and chunked encoder) was planned for that API.
- **Users** in the repository: `examples/http_get.agc`, `examples/http_server.agc`, `tests/http-test.rkt` (89 `HTTP.` uses), `tests/task-test.rkt`, `tests/checker-test.rkt`, `tests/bytecode-test.rkt`, `tests/vm-diff-common.rkt`, `site/content/library/network.md`, and the programming skill's `references/network.md` and `references/builtins.md`.

### 30.2 Decisions

| Question | Decision | Where |
|---|---|---|
| Streaming in phase 20? | No. Whole requests and whole responses; streaming comes on channels at order step 7.4 | 30.3, 30.11 |
| Body type | `String`, strict UTF-8; binary bodies wait for `Bytes` (phase 13) | 30.3, 30.12 |
| Body size | `max_body_bytes`, default 1 MiB, may be raised to 64 MiB | 30.3 |
| Handler | `Fn[HttpRequest, Result[HttpResponse]]`: it returns its answer | 30.3, 30.4 |
| Response framing | always `Content-Length`; never chunked, never trailers | 30.3 |
| Incoming chunked bodies | still decoded, in full, in C, within the limits | 30.5 |
| Connection pool | kept, inside the C `HttpClient`, with no API | 30.5 |
| What is C | head parsing, whole-body framing and limits, the pool, the server's task group | 30.5 |
| What is Agentica | URLs, options, request and response building, the server loops, keep-alive, handler dispatch, error answers, header helpers | 30.5 |
| How programs get it | `import "std/http" as HTTP`, an explicit import | 30.7 |
| Who may call `HttpWire` | only modules embedded from `stdlib/` (std-only); user code gets `CHECK-UNKNOWN-NAME` with a help that shows the `std/http` import | 30.5 |
| A program that needs the VM on an evaluator path | refused with `LOWER-UNSUPPORTED` ("needs the VM"), exit 1, wherever a program would reach the evaluator; the same rule phase 21 uses (§31.9) | 30.8 |
| TLS | today's file paths (`ca_file`, `cert_file`, `key_file`) until `TlsContext` (§29) | 30.3, 30.12 |

### 30.3 The API after phase 20

```agentica
import "std/http" as HTTP

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello\n"))
  end
  return ok(HttpResponse(status: 404, headers: [], body: "not found\n"))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  client = HTTP.client(HTTP.client_options()).unwrap!
  response = HTTP.get(client, "http://127.0.0.1:#{HTTP.local_port(server)}/").unwrap!
  puts(response.status)   # 200
  puts(response.body)     # hello
  HTTP.close_client(client)
  HTTP.close_server(server)
end
```

```text
HTTP.client_options() -> HttpClientOptions
HTTP.server_options() -> HttpServerOptions
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.header_values(headers: List[Header], name: String) -> List[String]
HTTP.listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
```

| Record (builtin) | Fields |
| --- | --- |
| `Header` | `name: String, value: String` (unchanged) |
| `HttpRequest` | `method: String, target: String, path: String, headers: List[Header], body: String` |
| `HttpResponse` | `status: Int, headers: List[Header], body: String` |
| `HttpClientOptions` | `timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String` |
| `HttpServerOptions` | `request_timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int` |

`HttpClient` and `HttpServer` stay opaque handles. `HttpBody` and `HttpWriter` are gone.

**Decisions:**

- **Synchronous, whole messages.** `get`, `post` and `request` send the whole request, read the whole response (head and body), and return it. They block only the calling task; other tasks run (§10.2.1). There is no `HTTP.read`, `text`, `trailers` or `close_body`: `response.body` is the text. 4xx and 5xx are normal responses, as today.
- **One timeout per call.** The client's `timeout_ms` covers the whole call: waiting for a pooled connection, DNS, connect, the TLS handshake, sending the request, and reading the whole response. (Today it ends at the response head.) The server has two deadlines per request, each `request_timeout_ms` long: the first bounds reading one whole request, head and body, from its first byte (`read_request`); the second starts when the handler returns and bounds writing its response (`write_response`). The time the handler runs is not bounded, as today, so a slow handler's reply is still sent. `request_timeout_ms` replaces `header_timeout_ms`, whose name no longer fits. `idle_timeout_ms` is the wait for the first byte of the next request on a kept-alive connection (server) and how long an idle pooled connection is kept (client), as today.
- **The body limit.** `max_body_bytes` defaults to 1 MiB on both sides (today 64 MiB, which was a limit on a stream, not on a `String` held in memory), and a program may raise it up to 64 MiB; a larger value is rejected like any invalid option (30.4). Memory for bodies is at least `max_body_bytes` × `max_connections` × 4 at worst: per connection, the request body sits once in the C buffer and once in its `String`, and the response body once in the handler's `String` and once in the C write buffer while it is sent (a handler that builds its body by concatenation holds more for a moment). So the defaults (1 MiB, 128 server connections) can reach 512 MiB, and a program that raises `max_body_bytes` must lower `max_connections` to match. A body over the limit is an `error` result on the client, and 413 on the server (before the handler runs). `HTTP.text`'s 1 MiB is where the default comes from.
- **Bodies are text.** A request or response body must be valid UTF-8: the client returns an `error` result for a response body that is not; the server answers 400 for a request body that is not, and the handler never runs. Binary bodies wait for `Bytes` (30.12). Keeping a whole byte body in C would be easy, but the only type for it before phase 13 is `List[Int]`: a 1 MiB body would be a million boxed values and every use a per-byte Agentica loop, which is exactly what the std-first rule forbids. `Content-Encoding` stays raw (no gzip), as today.
- **The handler returns its answer.** `Fn[HttpRequest, Result[HttpResponse]]`. Returning is the one way to answer: no writer, no `begin`/`write`/`finish`/`respond`. A handler that does I/O can use `try`, and an `error` becomes a 500 (30.4). A returned `Result` is used, so it fits the planned `CHECK-UNUSED-RESULT` (§26), unlike today's ignored `HTTP.respond` results.
- **Response framing is always `Content-Length`.** The server never sends chunked bodies or trailers. `HEAD` gets the head (with the `Content-Length` of the body it would have sent) and no body; 204 and 304 get no body and no `Content-Length`, and a handler that returns a non-empty body with them gets a 500. A response always ends the server's part of the exchange, so keep-alive needs no "was the body consumed?" rule: the request body was read in full before the handler ran.
- **Incoming framing stays complete.** The server decodes chunked request bodies and the client decodes chunked and close-delimited response bodies, in full, in C, within the limits. Incoming trailers are parsed and checked with the header rules (§10.6), then dropped: there is no API for them.
- **Requests the client sends** carry `Content-Length` when the body is not empty, or when the method is `POST`, `PUT` or `PATCH` (then `Content-Length: 0` for an empty body); `Host` is added by the client; user `Host`, `Content-Length`, `Transfer-Encoding` and `Connection` headers are rejected, and so are CR, LF and control bytes, as today. A body is written while the response is read, in C, so a server that answers early (413) or echoes a large body cannot deadlock the call.
- **The pool stays, with no API.** `HttpClient` keeps idle keep-alive connections per scheme, host and port, at most `max_connections` per origin, and a call waits in FIFO order for a free one within its timeout. Since every exchange is whole, a connection is leased only for the length of one call, inside C: it goes back to the pool when the response was complete and neither side asked to close. `HTTP.close_client` closes idle connections at once; a call in flight in another task fails with "client is closed" and its connection is closed.
- **Arity changes forced by Agentica.** A `std/` module has user functions, which cannot be overloaded or generic: `HTTP.client()` (no options) goes, so a client is `HTTP.client(HTTP.client_options())` (the one call that would read better with a default parameter; if default values (15a, order step 7.5) can be calls, a follow-up may give `options` the default `client_options()`, which changes no existing call); `HTTP.request_stream` goes with streaming (it could not be written in Agentica anyway, since its `A` is generic; its job comes back on channels in 30.11).
- **Server behaviour kept from today:** one task per connection, requests on one connection one at a time, 100 Continue for one `Expect: 100-continue` (417 for any other expectation), 501 for `Upgrade` and `CONNECT`, `HTTP/1.1` only, at most `max_connections` connections at once (an extra one waits in the kernel's backlog), and `HTTP.wait` returns only after `HTTP.close_server`.
- **Ending a run**, as today: when `main` returns or the run fails, every server and client is closed and every handler task stops. `HTTP.close_server` stops accepting, cancels running handlers and every task they spawned, closes every connection and wakes `HTTP.wait`; it is idempotent (30.6).

### 30.4 Errors and status codes

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
| The handler returns `error(message)` | `std/http` | 500, `Connection: close`, empty body; the message is not sent to the client, and `std/http` writes `http: handler error: <message>` to stderr with `IO.warn`, so the person or agent running the server sees why |
| The handler returns a response that cannot be sent: status outside 200 to 599, a bad header name or value, a framing header, a body with 204 or 304 | C refuses to write it; `std/http` answers | 500, `Connection: close`, and `http: invalid response: <reason>` on stderr |
| A runtime diagnostic in the handler (an `unwrap!` of an error, an index out of range) | the VM | since phase 24 (§37.5), it crashes the connection task: the client sees the connection close with no response, the server goes on, and the crash is reported as any task crash (as built in 20c) |
| A handler that runs a long time | none | the handler is never stopped and has no time limit, as today; its reply is still sent, with a fresh `request_timeout_ms` for the write that starts when it returns (30.3). The client's own timeout bounds what the client waits for |
| Writing the response fails (the client left) | C | the connection is closed quietly |

The codes that the hostile-case goldens fix are those §10.6 says must match: 413, 431, 505 and 501, plus 400 and 417. Stderr lines from `IO.warn` are program stderr, so the golden fixtures record them; `std/log` (§24) may replace them later.

**Client side:** every failure is an `error` result, never a diagnostic: a URL that is not `http://` or `https://` with a host (userinfo and non-ASCII are rejected), DNS, connect and TLS failures, the timeout, "client is closed", a malformed response (§10.6: `HTTP/1.1` only, status 100 to 599, 101 rejected, at most 15 interim responses), a body over `max_body_bytes`, and a body that is not UTF-8. A connection that fails is never put back in the pool.

**Options:** `HTTP.client` and `HTTP.listen` check the options record first, as `validate-options` does today: every number positive, `max_connections` at most 65536, and `max_body_bytes` at most 64 MiB. A bad record is an `error` result.

### 30.5 The split: `HttpWire` in C, `std/http` in Agentica

**Why some of it stays in C.** By the std-first rule, the parts that touch the OS (sockets), the parser of untrusted input (picohttpparser, exception 3), and anything that needs runtime state shared across tasks stay in C. Bodies stay in C too, because before binary data (phase 13) and faster lists (8d) Agentica has no fast way to handle bulk bytes: a body crosses into Agentica once, as one `String`, and no Agentica code ever loops over its bytes.

**The C side: the `HttpWire` builtin module, std-only.** A small set of VM-only builtins that only `std/` code may call. A public raw layer next to `std/http` would be a second way to do HTTP, so `HttpWire` is a stated exception to the std-first rule's "the new builtin is public", like the prelude-only builtins of §25.6. The mechanism, the simplest that works before 7i:

- `src/builtins.rkt` keeps a list of module names, `std-only-modules`, which is `'("HttpWire")` today. Every `HttpWire` builtin is also in `vm-only-builtins`, the set of 30.8. No catalog entry changes shape.
- The linker (`src/modules.rkt`) already knows where each module comes from: an embedded module's key is its `std/...` string (`src/modules.rkt:59`), any other module's key is a path. When it resolves a qualified name `M.f` where `M` is in `std-only-modules`, and the module being linked is not an embedded one, it stops with `CHECK-UNKNOWN-NAME` at the reference, with a help that shows `import "std/http" as HTTP`, the code an unknown builtin module already gets. So user files, `pkg/` modules and relative imports cannot call it; only `stdlib/*.agc` files can.
- `agentica help`, `agentica help --json` and every "did you mean" list leave `HttpWire` out, as they leave out the prelude-only builtins; a test checks all three.
- The loader does not guard it: a crafted `.agcb` that calls `HttpWire` gets nothing that `TCP` and `TLS` do not already give (the trust model of `docs/vm/README.md` §1).
- `HttpWire` is named apart from `HTTP` on purpose: `HTTP` is the documented import alias of `std/http`, and an alias cannot collide with a builtin name (`docs/grammar.md:165`). It is a reserved name: 20a adds `HttpWire` to `reserved-type-names` (`src/checker.rkt:13`), so a user type or import alias with that name is `CHECK-REDEFINED-NAME` (`src/modules.rkt:129`). `HttpRequest` and `HttpResponse` are builtin records, so they are reserved through the same list's record keys. It is documented for developers (`docs/vm/10-io-tls-processes-http.md` §10.7, the development skill), not in the programming skill or the site.

```text
HttpWire.read_request(socket: Socket, first_byte_timeout_ms: Int, timeout_ms: Int, max_body_bytes: Int) -> Result[HttpRequest]
HttpWire.write_response(socket: Socket, response: HttpResponse, head_only: Bool, close: Bool, timeout_ms: Int) -> Result[Void]
HttpWire.client(max_connections: Int, idle_timeout_ms: Int, ca_file: String) -> Result[HttpClient]
HttpWire.exchange(client: HttpClient, scheme: String, host: String, port: Int, method: String, target: String, headers: List[Header], body: String, max_body_bytes: Int, timeout_ms: Int) -> Result[HttpResponse]
HttpWire.close_client(client: HttpClient) -> Void
HttpWire.server(listener: Listener, max_connections: Int) -> HttpServer
HttpWire.accept(server: HttpServer) -> Result[Socket]
HttpWire.spawn(server: HttpServer, socket: Socket, f: Fn[Socket, Void]) -> Void
HttpWire.close_server(server: HttpServer) -> Void
HttpWire.wait(server: HttpServer) -> Result[Void]
HttpWire.local_port(server: HttpServer) -> Int
```

- **`read_request`** waits up to `first_byte_timeout_ms` for the first byte, then reads the head through the picohttpparser adapter with every check of §10.6 (`vm/http_parse.h`, `vm/http_pico.c`), sends 100 Continue or answers 417, reads the whole body (`Content-Length` or chunked) through the body decoder (`vm/http_body.c`) into one `malloc`'d buffer within `max_body_bytes`, checks UTF-8, and returns an `HttpRequest` (header names lowercase, `path` the part of the target before `?`). Everything within `timeout_ms`. On any protocol error it writes the error answer of 30.4 itself and closes the socket, then returns an `error` result; at EOF before the first byte it returns `error("network: end of input")`. Error answers are security-critical bytes, so they are written in C and the Agentica side only has to stop.
- **`write_response`** validates the status and headers (tokens, the Latin-1 byte range, no CR or LF, no user framing headers), returns an `error` result without writing anything when they are bad, and otherwise writes the head with `Content-Length` (or none for 204 and 304), adds `Connection: close` when `close` is true, and writes the body unless `head_only`. One `uv_try_write`, then one `uv_write` of the rest, as TCP writes (`docs/vm/10-io-tls-processes-http.md` §10.3.1).
- **`client` and `exchange`**: the `HttpClient` handle holds the pool (idle connections per origin, the lease counts, a FIFO of waiting calls, each with a slot reservation as a channel's waiters have, §27.2) and one `SSL_CTX` built from `ca_file` once per client (system trust when empty), so HTTPS does not reload the CA bundle per connection. `exchange` leases or opens a connection (TCP, or TLS through the VM's TLS code with the client's `SSL_CTX` and the host for SNI and verification), checks the method token, the target bytes (33 to 126) and the headers, writes the request head and body while it reads the response, handles interim responses, reads and decodes the whole body within `max_body_bytes`, checks UTF-8, returns the connection to the pool or closes it, and returns an `HttpResponse`. One `timeout_ms` covers all of it.
- **`server`, `accept`, `spawn`, `close_server`, `wait` and `local_port`** are the server's task group (30.6). `accept` returns an accepted socket once fewer than `max_connections` connections are open, and an `error` result only after `close_server`; other accept failures (`EMFILE`, say) are traced and retried inside C. For a TLS listener it returns the socket before the handshake, which then runs inside the first `read_request` under its timeouts, so a slow client cannot stall the accept loop (the evaluator does the same: `network-accept` with `#:upgrade? #f`, then `network-upgrade` in the connection task).
- **Turn costs**: each primitive charges a turn cost by the size of what it writes or returns (`AGC_COST_SIZE`, §10.2.1), also when it parks, as the TCP builtins do.

**The Agentica side: `stdlib/http.agc`**, registered in `src/stdlib.rkt` next to `std/queue.agc` (`src/stdlib.rkt:17`). It grows with the items: 20a adds the client functions, 20c the server functions. Until 20d the builtin `HTTP` module still exists, so the alias `HTTP` is taken and tests import the module under another alias (`import "std/http" as Web`); `grammar.md` documents each part as it lands, with a status line that says the builtin `HTTP` stays the way to write HTTP programs until 20d, and the programming skill teaches it only from 20d. It holds every public function of 30.3:

- **Options:** `client_options()` and `server_options()` return the default records; `client` and `listen` validate them (30.4) and pass plain numbers to `HttpWire`.
- **URLs:** `get`, `post` and `request` parse the URL with `String` builtins into scheme, host (an IPv6 literal in brackets), port (80 or 443 by default) and target (path and query; a fragment is dropped), and reject what 30.4 lists. The C side checks the target bytes and the host again, so a bug in the Agentica parser cannot inject bytes.
- **The client calls** are one `HttpWire.exchange` each: `get` is `request` with `"GET"`, no headers and no body; `post` is `request` with `"POST"`.
- **The server:** `listen` and `listen_tls` validate the options, open the listener (`TCP.listen`, or `TLS.listen(host, port, cert_file, key_file)` on the VM's TLS code), make the group with `HttpWire.server`, and spawn the accept loop. The accept loop calls `HttpWire.accept` and, for each socket, `HttpWire.spawn(server, socket) do |s| serve(s, handler, options) end`; it ends when `accept` returns its error after `close_server`.
- **The connection loop** (`serve`), the keep-alive policy and handler dispatch: read a request (`request_timeout_ms` for the first byte of the first request, `idle_timeout_ms` for later ones, then `request_timeout_ms` for the whole request from its first byte), call the handler (no time limit), turn its `error` or an unsendable response into the 500 of 30.4, decide whether to close (the request or the response has `Connection: close`, or a 500 was sent), write the response (`head_only` for `HEAD`) with a fresh `request_timeout_ms` that starts when the handler returns, and loop or return. The group closes the socket when the task ends.
- **Helpers:** `header_values` (a case-insensitive match with `String.downcase`), `local_port`, `wait`, `close_server` and `close_client` (one-line calls of `HttpWire`).

**What stays in C until 13 and 8d, and what could move later.** Head parsing and body framing stay in C for good: they are exception 3 (a parser of untrusted input with a mature library) and security-critical. The body buffers, the pool and the task group stay in C because they are bulk bytes and shared runtime state. After phase 13 (`Bytes`) a binary body form becomes possible (30.12). After 8d nothing has to move; the URL parser and the loops are already Agentica. A piece moves to C only when a measurement shows it is hot (the server measurement 7j), with its `std/http` API unchanged, as the std-first rule says.

**Performance.** No Agentica code runs per byte. Per request the Agentica side runs one URL parse (client) or one loop turn and one handler call (server): a few hundred steps. The sanity check in 30.10 compares with the evaluator's HTTP.

### 30.6 Server tasks, `close_server` and task cancellation

`HTTP.close_server` must stop handlers and the tasks they spawned, as the evaluator's server did. Before 20b the VM had no way to cancel one task: the tasks PR only stops every task at the end of the run, and the cancellation core was planned with `Task.map` (§27.1, "Task cancellation"), after 7i. So 20b landed that core first, with no public API (as built: `docs/vm/10-io-scheduler.md` §10.2.1 and §10.2.2), and 17a later reuses it:

- **Parent and children links** on each task, and the rule that a task's running children move to its parent when it ends (§27.1).
- **`agc_task_cancel`** for the states a handler task can be in today: ready (it leaves the run queue), parked on an I/O job (the job is detached: it runs to its own end or deadline, its result is dropped, the handle is not closed by it), waiting for a handle's lock (it leaves the FIFO; if it was the `next_owner`, ownership passes on), in `Task.await` (it leaves the target's waiters), in `Task.sleep` (the timer is closed), or waiting in an `HttpClient`'s pool FIFO (it leaves the queue, and a slot reserved for it passes to the next waiter, or becomes free; 20a adds the pool, 20b its cancel). Tasks parked in `Task.await` on a cancelled task wake and halt with `RUNTIME-TASK-CANCELLED` at their own span, as §27.1 says; 20b is what raises this code on the VM. As built, a pool waiter is an exchange that waits for the client's TLS setup or for a slot, and a slot is reserved for it from the moment it is granted until its request is sent (it is still connecting); an exchange that has sent its request runs to its end and its connection is closed, not pooled. The `Task.map` and channel states come with 17a and 17b.
- **Tests that land here, and what 17a adds.** 20b adds the C test of `agc_task_cancel` (`vm/tests/task_cancel_test.c`) on a ready task, a task parked on a timer, a task parked on an I/O job (its result is dropped, the handle stays open), a task waiting for a handle lock, the `next_owner` of a handle lock, a task in a `Task.await`, tasks already parked in `Task.await` on the cancelled task and a later `Task.await` on it (both `RUNTIME-TASK-CANCELLED` at their own span), a task waiting for a pool slot and a reserved pool slot passed to the next waiter, and the move of a finished task's running children to its parent. 17a adds to the same file only what is new there: the `Task.map` group logic and a task parked as a `Task.map` caller (§27.1).
- **A running task** is cancelled too, and the task that calls `close_server` is the common case (a handler that closes its own server): the cancel sets the task's cancel flag, and the task stops at the next safe point after the current builtin returns (the next instruction, as a turn's end is checked, §10.2.1), so `close_server` itself finishes its work first. With N schedulers this is the cancel flag of `docs/vm/10-io-multicore.md` §10.2.3, which a task on another scheduler sees within one turn. The handler's client sees its connection close with no response.
- **The group** (20c) is a parent node in the task tree. `HttpWire.spawn` starts the task as a child of the group, not of the accept loop, and registers its socket with the group. When a handler task ends, its running children move to its parent, which is the group, so `close_server` still cancels them. `HttpWire.close_server` closes the listener, wakes `accept` and `wait`, then cancels every group task and its descendants and closes every group socket. When a connection task ends, its socket is closed and its slot is freed, which wakes a waiting `accept`.
- **End of run** is the one exit path of §14.4 (`end_run` in `vm/main.c`): no task is awaited and no socket is closed one by one; children are killed, the files are flushed and the VM ends with `_exit`, which closes every descriptor. A server's TLS connections get their `close_notify` through the resource's `goodbye` hook (`agc_io_goodbye`), as `TCP` sockets do.

With the multicore schedulers (§10.2.3), cancel uses the cancel flag and wake of §10.2.3; nothing in this section depends on N=1.

### 30.7 How `std/http` is exposed: an explicit import

`std/http` is Agentica code. There are three ways it could reach programs:

1. **Global `HTTP.*` through the compiler prelude** (§25.6). Not before 7i: the prelude waits for faster lists (8d, order step 8), because of its cost contract, and it is meant for code that must be generic or a method on a builtin type, which `std/http` is not.
2. **An implicit import**: the linker adds `std/http` as `HTTP` when a program names `HTTP`. Rejected: it is new magic in the linker for one module, the program would not show where `HTTP` comes from, and it would be a second way to import a `std/` module.
3. **An explicit import**, `import "std/http" as HTTP`, like `std/queue`. **Chosen.** It needs no new compiler mechanism, the program says where the code comes from, a runtime error inside the library names `std/http.agc` as embedded modules already do, and it stays right when the prelude lands (nothing in `std/http` is generic or a method).

Consequences:

- `HTTP` stops being a builtin name: the catalog loses its 23 `HTTP` entries, and 20d removes `"HTTP"` from `reserved-type-names` (`src/checker.rkt:13`), or `import ... as HTTP` would fail at `src/modules.rkt:129`. So `HTTP` becomes a free alias, and the documented alias is `HTTP`; a test checks that `import "std/http" as HTTP` links. Another alias works too; the skill and the site always write `HTTP`.
- A program that calls `HTTP.get` without the import gets `CHECK-UNKNOWN-NAME` at the call with a help that shows `import "std/http" as HTTP`, through the hint table of `grammar.md` §7.
- `HttpRequest`, `HttpResponse`, `HttpClientOptions`, `HttpServerOptions`, `Header`, `HttpClient` and `HttpServer` stay global builtin names, since the C primitives build and take them; programs name them without the alias.
- It is a breaking change: every program that uses HTTP adds one line (30.8).

### 30.8 Migration: what is removed and what it breaks

**Done in 7i, not 20d** (owner decision of 2026-10-13). The removal below happened in 7i, before the server: `examples/http_get.agc` uses `std/http`; `examples/http_server.agc` was removed and comes back with 20c; `tests/http-test.rkt`, the evaluator's HTTP code and the refusal machinery ("Programs the evaluator cannot run", below) are gone. Migration for users: add `import "std/http" as HTTP`; `HTTP.client()` becomes `HTTP.client(HTTP.client_options())`; `HTTP.text(r.body, t)` becomes `r.body`; `read`, `trailers`, `close_body` and `request_stream` have no replacement until streaming (30.11); a server waits for 20c. The text below is the plan as written for 20d, kept for its reasons; the CHANGELOG entries it lists are not written during the private alpha.

**Removed builtins** (with 20d): `HTTP.request_stream`, `HTTP.read`, `HTTP.text`, `HTTP.trailers`, `HTTP.close_body`, `HTTP.begin`, `HTTP.write`, `HTTP.write_bytes`, `HTTP.finish`, `HTTP.respond`, and the zero-argument `HTTP.client()`. Deleted types, four: `Request`, `Response`, `HttpBody` and `HttpWriter`. `Request` and `Response` are replaced by `HttpRequest` and `HttpResponse` (added in 20c and 20a), whose `body` is a `String`; they have new names so that an old program fails at the type with a clear message instead of at a field. Types that stay, unchanged in name: `Header`, `HttpClient`, `HttpServer`, `HttpClientOptions` and `HttpServerOptions` (the last one with its renamed field). Changed: every other `HTTP.*` is now a `std/http` function behind the import (same name and arguments); `HTTP.listen` and `HTTP.listen_tls` take `Fn[HttpRequest, Result[HttpResponse]]`; `HttpServerOptions.header_timeout_ms` becomes `request_timeout_ms`; the `max_body_bytes` default goes from 64 MiB to 1 MiB with a 64 MiB cap; the client's `timeout_ms` now covers the whole response. Each removed name gets a help in the hint table of `grammar.md` §7 (`HTTP.text(r.body, t)` → `r.body`; `HTTP.respond(writer, ...)` → `return ok(HttpResponse(...))`; `HTTP.request_stream` → a whole `HTTP.request`, or streaming at 7.4).

**What it breaks in the repository**, all migrated in 20d:

- Programs: `examples/http_get.agc` and `examples/http_server.agc` (the CI example smoke tests run them).
- Tests: `tests/http-test.rkt` (evaluator HTTP, 89 uses: deleted with the evaluator's HTTP code, its cases rewritten as VM golden fixtures and `tests/vm-http-test.rkt`), the `HTTP` cases of `tests/task-test.rkt` and `tests/checker-test.rkt` (rewritten for the new API), `tests/bytecode-test.rkt` (it uses an `HTTP` call as its out-of-subset example for `LOWER-UNSUPPORTED`; it switches to a `BDD` call until [phase 21](../roadmap/21-bdd-in-agentica.md) removes those), and `tests/vm-diff-common.rkt` (its fallback cases).
- Front end: `"HTTP"` leaves `reserved-type-names` (`src/checker.rkt:13`); the `http-producer` rule of the checker (`src/checker.rkt:759`) and the one-argument `HTTP.client` overload (`src/builtins.rkt:214`) are deleted; the usage text of `src/main.rkt:140` no longer names HTTP as an evaluator program.
- Evaluator: the 23 `HTTP` catalog entries go, so the evaluator's HTTP code is unreachable: 20d deletes `src/http-wire.rkt`, `src/http-client.rkt`, `src/http-server.rkt`, their dispatch in `src/evaluator.rkt` and their types in `src/builtin-types.rkt`, and the `HTTP` part of the fallback in `src/main.rkt`. `src/network.rkt` stays for the evaluator's TCP and TLS until 7i.
- Docs: `docs/grammar.md` ("TCP, TLS and HTTP/1.1": the `HTTP` part rewritten as the `std/http` library, reserved names (`HttpWire` among them; it is not documented for programs), the §7 hints), `site/content/library/network.md` (every HTTP example; `{mode="check"}` where they touch the network), `site/content/getting-started.md` if it mentions HTTP, the programming skill (`references/network.md` rewritten for whole messages and the import; `references/builtins.md` loses the `HTTP` rows; `references/modules.md` lists `std/http`; `SKILL.md`'s "When to read a reference" row), the development skill (`SKILL.md`'s layout lines for `src/http-*.rkt`, `references/vm.md` for `vm/http_*.c`, `references/runtime-notes.md`), `README.md` (the fallback text at lines 36, 91 and 92, and the HTTP examples at line 155), and `AGENTS.md` (the fallback list loses `HTTP`).
- **CHANGELOG** (20d, under "Changed", one entry): "HTTP runs on the bytecode VM and is now simple and synchronous. Import it with `import \"std/http\" as HTTP`. `HTTP.get`, `post` and `request` return a whole `HttpResponse` whose `body` is a `String` (strict UTF-8, at most `max_body_bytes`, 1 MiB by default, up to 64 MiB). A handler is `Fn[HttpRequest, Result[HttpResponse]]` and returns its answer; an `error` becomes a 500. Removed: `HTTP.request_stream`, `read`, `text`, `trailers`, `close_body`, `begin`, `write`, `write_bytes`, `finish`, `respond`, `HTTP.client()` without options, and the `HttpBody`, `HttpWriter`, `Request` and `Response` types. `HttpServerOptions.header_timeout_ms` is now `request_timeout_ms`. Responses are always sent with `Content-Length`. Streaming comes later, on channels." Under "Added" (20a): "`std/http.agc` starts on the VM with its client (`get`, `post`, `request`); the builtin `HTTP` module stays the way to write HTTP programs until the switch. `HttpWire` and `HttpResponse` become reserved names (`CHECK-REDEFINED-NAME` for a user type or alias with one of them)." (20c): "`std/http.agc` gets its server; `HttpRequest` becomes a reserved name."

**Programs the evaluator cannot run (from 20a until 7i).** Every program that imports `std/http` calls `HttpWire`, which only the VM has. Today, a program with a builtin the evaluator does not know reaches the evaluator's catch-all and ends with `RUNTIME-INTERNAL`. So 20a adds one general refusal, before the evaluator gets a program. It is the mechanism that phase 21 also uses for its own VM-only builtins (`Process.spawn_captured`, `Process.output`, `Task.pending_count`; [section 31.9](31-bdd-in-agentica.md#319-what-stays-in-c), roadmap 21a and 21b), so there is one rule, and it lands here first:

- **The mark.** `src/builtins.rkt` keeps a set of names, `vm-only-builtins`: 20a puts every `HttpWire` builtin in it, and 21a and 21b add theirs. No catalog entry changes shape.
- **The check.** `src/lower.rkt` exports `check-vm-only`, a walk over the checked, linked program that returns the whole diagnostic below for the first call to a builtin in that set (or nothing). By the stage rule of AGENTS.md, the stage builds the diagnostic; `src/main.rkt` and `read-program` only print it and set the exit code.
- **The diagnostic** is the one [section 31.9](31-bdd-in-agentica.md#319-what-stays-in-c) already names: `LOWER-UNSUPPORTED` at that call's span, with a message that says the program needs the VM and why it is not on the VM (the first call that the VM cannot run yet, or `--legacy-eval`; `check-vm-only` takes that reason as an argument); for a `std/http` program the span is inside `std/http.agc`, and the message names the module. Exit 1. The evaluator never runs.
- **Where it is checked**, every place that hands a checked program to the evaluator:
  - the fallback branch of `src/main.rkt` (`src/main.rkt:318`), for any `LOWER-UNSUPPORTED`, not only an `HTTP` one (until 20d: `std/http` beside a builtin `HTTP` call; until 21f: beside a `BDD` call);
  - the `--legacy-eval` branch of `src/main.rkt`, which is also how `agentica test` runs a program under test today (`src/bdd.rkt:21`);
  - `read-program` in `src/bdd-runner.rkt` (`src/bdd-runner.rkt:20`), which loads step files into the evaluator for `agentica test` and `BDD.run`.
- **How long.** The `agentica test` part ends with 21f ([phase 21](../roadmap/21-bdd-in-agentica.md)), which replaces that path with the VM runner and `src/bdd-driver.rkt`, deletes `src/bdd-runner.rkt`, and stops passing `--legacy-eval` (§31.12). After 21f only a builtin `HTTP` call still triggers the fallback, until 20d; then nothing does, but its branch and `--legacy-eval` stay until 7i, and so does the check in both. The repository's BDD features do not use HTTP.

### 30.9 What the old C-only design drops

The C design of `docs/vm/10-io-tls-processes-http.md` §10.6 and roadmap 7h's HTTP item was written for the streaming API. Phase 20 keeps its parsing rules and drops:

- the chunked **encoder** (the server never sends chunked bodies, and the client never sends chunked uploads, until 30.11);
- the **streaming** use of the body decoder (`feed` returning body slices to `HttpBody`, `HTTP.request_stream` and `HttpWriter`): the decoder stays incremental over the socket's input, but its slices go into one buffer for the whole body;
- `HttpBody`, `HttpWriter` and the producer task of `request_stream` (`docs/vm/10-io-scheduler.md` §10.2 lists it among the builtins that run a function as a task; 20d updates that line);
- the trailer API (trailers are still checked, then dropped);
- the C server loop and C handler dispatch: the server loops and keep-alive are Agentica (30.5).

Kept as written: picohttpparser v1.4 as a submodule behind `vm/http_parse.h` and `vm/http_pico.c`, the pre-scan, the start-line check, every strict check, the limits of §10.5, saturating size arithmetic, `phr_decode_chunked` not used, the codes that must match, and the hostile-case list.

### 30.10 Tests

Every item keeps its own tests and docs, as AGENTS.md and the stacked-PR rule ask:

- **Golden fixtures** (`tests/fixtures/vm/http-*.agc` and `.expected`), deterministic because a fixture is its own peer, as the `tcp-*` fixtures are: one program runs a server and a client in two tasks and only `main` prints. Cases: GET, POST, HEAD, 204, 304, 404, a handler `error` (500 and its stderr line), an unsendable response (500), keep-alive reuse (two calls on one pooled connection: the second needs no new accept), `Connection: close`, a body at `max_body_bytes` and one byte over (413 on the server, an `error` on the client), a non-UTF-8 body, `close_server` while a handler sleeps (the handler's next line never prints, and a task it spawned never prints), `HTTP.wait` after `close_server`, a handler that sleeps longer than `request_timeout_ms` (100 ms of timeout, a 300 ms sleep) and still gets its reply out, since no deadline covers the handler's run (nothing races, so the outcome does not depend on timing), a handler that calls `HTTP.close_server` and then prints (the line never prints, and its client gets no response), a task spawned by a handler that has already returned, still running when `close_server` is called (it never prints again), `main` returning while a call is in flight, and the option checks. Fixtures that wait on a timeout go in the Racket test below, since goldens record step counts and must not depend on timing (§27.1, "The golden rule").
- **The hostile cases of §10.6**, all of them, against the VM server, sent by a Python raw-socket peer in `tests/vm-http-test.rkt` (standard library only), asserting the status code and that the connection closes, plus the client-side cases (`HTTP/1.0`, status 99 and 600, 101, 15 interim responses accepted and 16 rejected, a bad chunk size, a response body over the limit) served by the same raw peer. A C unit test of the adapter and the body decoder (`vm/tests/http_parse_test.c`) covers the same list at the interface, so a replacement parser must pass it.
- **Interop with independent peers on port 0**, in `tests/vm-http-test.rkt`, standard library only: the VM client against Python's `http.server.ThreadingHTTPServer` (keep-alive, chunked responses, a close-delimited body, a slow server and the timeout, `max_connections` waits) and against an HTTPS server made with Python's `ssl` and the CA of `tests/fixtures/tls/`; the VM server against Python's `http.client` and Node's `http` module (chunked uploads, `Expect: 100-continue`, pipelined keep-alive requests, `HEAD`, many concurrent clients up to `max_connections` and one more that waits). Python and Node are required in CI, as for TCP.
- **Task cancellation** (20b): `vm/tests/task_cancel_test.c`, the list of 30.6.
- **The guards** (20a): a user file, a `pkg/` module and a relative import that call `HttpWire.exchange` each get `CHECK-UNKNOWN-NAME` at the reference with the `std/http` help (`tests/modules-test.rkt`); `HttpWire` is absent from `agentica help`, `help --json` and "did you mean" lists; and one test per place of 30.8 (a `std/http` program beside a builtin `HTTP` call through the fallback, the same program under `--legacy-eval`, and a step file that imports `std/http` loaded by `agentica test` through `read-program`) checks `LOWER-UNSUPPORTED` at the `HttpWire` call, exit 1, and that the evaluator never ran (`tests/vm-diff-common.rkt` and `tests/bdd-test.rkt`).
- **`Expect` order** (20c): a request with `Expect: 100-continue` and a `Content-Length` over the limit gets 413 and the Python raw peer sees no `100 Continue` before it.
- **Performance sanity check**, not a CI gate: 20d adds `benchmarks/http.py` (a Python standard-library load client: N keep-alive requests over C connections) and runs it against `examples/http_server.agc` on the evaluator (the parent commit, before the evaluator's HTTP is deleted) and on the VM, and against the VM client fetching from a Python server; the numbers go in `docs/vm-benchmarks.md`. The VM should not be slower; if it is, the PR finds out why before it merges.

### 30.11 Streaming on channels

At order step 7.4, after `Channel[T]` (§27.2, 17b), three items bring streaming back for the jobs a whole message cannot do. Each is built on channels with their timeouts, backpressure and close rules; chunks are `String` (UTF-8, split only at character boundaries, at most 64 KiB each) until `Bytes` lands (phase 13, order step 7.5), which adds byte streams then.

**Channels are enough; lazy `Stream[T]` is not needed.** An HTTP body is pushed by I/O and read by another task, at its own speed: that is a bounded channel (backpressure when full), with timeouts on each wait, `close` for the end, and `closed?` to tell the end from a timeout (§27.2). A lazy stream (§27.4) is pulled by one consumer through a chain of functions in one task; it would add nothing here, and §27.4 keeps its status ("to evaluate later").

**No defaults needed.** Every streaming call has a fixed argument list and takes the options of the client or server it runs on, so default parameter values (15a, order step 7.5, after these items) never force a second change.

**How errors reach the reader.** A channel can only end, not fail. So a streamed response carries the body channel and a task: `HttpStream(status: Int, headers: List[Header], body: Channel[String], done: Task[Result[Void]])`. The task feeds the channel and closes it on every path (§27.2's rule), and its result says whether the body ended cleanly. The reader runs the canonical receive loop and then `Task.await(stream.done)`. To stop early, the reader closes the channel: the feeder's next `send` returns "channel: closed", it closes the connection (never back to the pool) and ends with an error.

- **20e Streamed downloads** (client): `HTTP.open(client, method, url, headers, body: String) -> Result[HttpStream]` returns at the response head; `std/http` spawns the feeder, which reads with a new primitive `HttpWire.read_chunk` (the next decoded piece, `""` at the end) and sends each piece with the client's `timeout_ms`. Big downloads, progress, and reading an SSE stream line by line.
- **20f Streamed uploads** (client): `HTTP.upload(client, method, url, headers, length: Int, body: Channel[String]) -> Result[HttpResponse]`: the caller's other task feeds the channel and closes it; `length` is the exact byte count, or -1 for chunked (today's `request_stream` rule); the response is whole. It replaces `HTTP.request_stream` without a generic producer: the closure or task that feeds the channel carries whatever data it needs.
- **20g Streamed responses** (server, SSE included): `HTTP.listen_stream(host, port, handler: Fn[HttpRequest, Result[HttpStreamResponse]], options)` and `HTTP.listen_stream_tls(...)`, with `HttpStreamResponse(status: Int, headers: List[Header], body: Channel[String])`. The handler returns at once with the channel; a task it spawned feeds it. The connection sends chunked, or `Content-Length` when the channel is already closed with everything buffered when the handler returns; it writes each piece as it arrives, checks for a client that left on every receive timeout (`idle_timeout_ms`), and closes the channel when the client leaves, so the feeder's next `send` fails and it stops. An SSE handler sends `data: ...\n\n` pieces and, if it wants, comment lines to keep the connection alive. `HTTP.whole(text) -> Channel[String]` gives a closed channel holding one piece, for the routes of a streaming server that answer with one text.

**One way for each job** (the table the skill teaches):

| Job | The one form |
|---|---|
| Send a request and use its whole response (up to 64 MiB) | `HTTP.get`, `post`, `request` |
| Read a response as it arrives: bigger than 64 MiB, endless, or events (SSE) | `HTTP.open` |
| Upload a body produced as it goes, or bigger than 64 MiB | `HTTP.upload` |
| A server whose every route answers with one whole text | `HTTP.listen` |
| A server with at least one route that streams (SSE, big downloads) | `HTTP.listen_stream`, with `HTTP.whole(text)` for its other routes |

The checker cannot stop `HTTP.open` on a small response, so these pass the one-way test by job, as `Task.map` and channels do (§27): each form exists for something the others cannot do (a body that does not fit the limit or never ends), and the skill teaches whole messages first and the streaming form only for those jobs. Left out until a program needs it: an upload and a streamed response in one call (a proxy), and streamed request bodies on the server (big uploads to an Agentica server); each would need its own one-way test.

### 30.12 Later: binary bodies and `TlsContext`

- **Binary bodies** come after `Bytes` (phase 13, §23): byte forms of the body fields and of the stream pieces. They pass the one-way test because a `String` cannot hold arbitrary bytes. Their shape is decided with phase 13; until then a binary body is an `error` (client) or 400 (server).
- **`TlsContext`** (§29, phase 19) comes at order step 7.4, right after 20g. It changes `TLS` and `HTTP` together in one breaking step: `HttpClientOptions` loses `ca_file` and `HTTP.client` takes a context, and `HTTP.listen_tls` and `HTTP.listen_stream_tls` take a context instead of `cert_file` and `key_file`, with one CHANGELOG entry and one migration (§29.5). Until then, phase 20 keeps today's file paths, and `HttpWire.client` builds one `SSL_CTX` per client from its `ca_file`.
- **STARTTLS** (`TLS.upgrade`) comes with `TlsContext` (§29.3): simple HTTP does not need it, since HTTPS is TLS from the first byte.
