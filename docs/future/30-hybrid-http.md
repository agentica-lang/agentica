## 30. HTTP on the VM: simple, synchronous, hybrid

**Status:** the simple, synchronous HTTP of roadmap phase 20 is built (client
20a, cancellation core 20b, server 20c). A call sends a whole request and gets a
whole response, and a handler returns a whole response (decided by the user on
2026-10-12): a `String` body is simple for programs and keeps all byte work in
C. What is built is not in this file: the API, options, limits and answers are
in the grammar ([`06d-io-and-network.md`](../grammar/06d-io-and-network.md),
"HTTP client and server (`std/http`)"), and the parsing rules, design, errors
and tests in [`docs/vm/10-io-http.md`](../vm/10-io-http.md) §10.6 and §10.7.
This file keeps what is not built: streaming on channels (20e and 20f, 30.11)
and what comes later (30.12 to 30.13).

**Streaming** is a new feature, VM-only, at order step 7.4 ([the order
table](../roadmap/README.md#current-implementation-order)): after phase 17
(`Task.map` and channels, [§27](27-iteration-and-concurrency.md)), since it is
built on `Channel[T]` (§27.2), and right before `TlsContext`
([§29](29-tls-context.md), phase 19). The rules are those of [section
25](25-ruby-typed-idioms.md#25-ruby-typed-idioms) (one way to do each thing,
immutable values, static types), the [std-first
rule](../roadmap/README.md#new-library-features-std-first) and the strict
parsing rules of [`docs/vm/10-io-http.md`](../vm/10-io-http.md) §10.6.

### 30.11 Streaming on channels

At order step 7.4, after `Channel[T]` (§27.2, 17b), three items bring streaming
back for the jobs a whole message cannot do. Each is built on channels with
their timeouts, backpressure and close rules; the chunks of the client items
are `String` (UTF-8, split only at character boundaries, at most 64 KiB each),
and wait for binary bodies (#803). The server's (20g) are `Bytes`.

**Channels are enough; `Lazy[T]` is not needed.** An HTTP body is pushed
by I/O and read by another task, at its own speed: that is a bounded channel
(backpressure when full), with timeouts on each wait, `close` for the end, and
`closed?` to tell the end from a timeout (§27.2). A `Lazy` (§27.4) is pulled by
one consumer through a chain of functions in one task; it would add nothing
here.

**No defaults needed.** Every streaming call has a fixed argument list and takes
the options of the client or server it runs on, so default parameter values
(15a, order row 7.5a) never force a second change.

**How errors reach the reader.** A channel can only end, not fail. So a streamed
response carries the body channel and a task:
`HttpStream(status: Int, headers: List[Header], body: Channel[String], done:
Task[Result[Void]])`.
The task feeds the channel and closes it on every path (§27.2's rule), and its
result says whether the body ended cleanly. The reader runs the canonical
receive loop and then `Task.await(stream.done)`. To stop early, the reader
closes the channel: the feeder's next `send` returns "channel: closed", it
closes the connection (never back to the pool) and ends with an error.

- **20e Streamed downloads** (client):
  `HTTP.open(client, method, url, headers, body: String) -> Result[HttpStream]`
  returns at the response head; `std/http` spawns the feeder, which reads with a
  new primitive `HttpWire.read_chunk` (the next decoded piece, `""` at the end)
  and sends each piece with the client's `timeout_ms`. Big downloads, progress,
  and reading an SSE stream line by line.
- **20f Streamed uploads** (client):
  `HTTP.upload(client, method, url, headers, length: Int, body: Channel[String])
-> Result[HttpResponse]`:
  the caller's other task feeds the channel and closes it; `length` is the exact
  byte count, or -1 for chunked (the rule of the removed `HTTP.request_stream`);
  the response is whole. It replaces `HTTP.request_stream` without a generic
  producer: the closure or task that feeds the channel carries whatever data it
  needs. The chunked encoder for requests comes back in C for it.
- **20g Streamed responses** (server, SSE included) is built:
  `HTTP.listen_stream`, `HTTP.listen_stream_tls`, `HTTP.StreamResponse` and
  `HTTP.whole`
  (the [network page](../../site/content/library/io-and-system/network.md), and
  [`docs/vm/10-io-http.md`](../vm/10-io-http.md) §10.7.2). Its body
  is a `Channel[Bytes]`; a piece over 512 KiB is split into chunks.

**One way for each job** (the table the skill teaches):

- **Job:** Send a request and use its whole response (up to 64 MiB)
  - **The one form:** `HTTP.get`, `post`, `request`

- **Job:** Read a response as it arrives: bigger than 64 MiB, endless, or events
  (SSE)
  - **The one form:** `HTTP.open`

- **Job:** Upload a body produced as it goes, or bigger than 64 MiB
  - **The one form:** `HTTP.upload`

- **Job:** A server whose every route answers with one whole text
  - **The one form:** `HTTP.listen`

- **Job:** A server with at least one route that streams (SSE, big downloads)
  - **The one form:** `HTTP.listen_stream`, with `HTTP.whole(data)` for its
    other routes (built)

The checker cannot stop `HTTP.open` on a small response, so these pass the
one-way test by job, as `Task.map` and channels do (§27): each form exists for
something the others cannot do (a body that does not fit the limit or never
ends), and the skill teaches whole messages first and the streaming form only
for those jobs. Left out until a program needs it: an upload and a streamed
response in one call (a proxy), and streamed request bodies on the server (big
uploads to an Agentica server); each would need its own one-way test.

### 30.12 Later: binary bodies and `TlsContext`

- **Binary bodies** are still planned (#803). They need `Bytes`, which has
  landed (0.17.0, #805): byte forms of the body fields and of the stream pieces.
  They pass the one-way test because a `String` cannot hold arbitrary bytes.
  Their shape is decided in #803; until then a binary body is an `error`
  (client) or 400 (server).
- **`TlsContext`** (§29, phase 19) comes at order step 7.4, right after 20g. It
  changes `TLS` and `HTTP` together in one breaking step: `HttpClientOptions`
  loses `ca_file` and `HTTP.client` takes a context, and `HTTP.listen_tls` and
  `HTTP.listen_stream_tls` take a context instead of `cert_file` and `key_file`,
  with one CHANGELOG entry and one migration (§29.5). Until then, phase 20 keeps
  today's file paths, and each client connection's `TLS.connect` builds its own
  `SSL_CTX` from the client's `ca_file`.
- **STARTTLS** (`TLS.upgrade`) comes with `TlsContext` (§29.3): simple HTTP does
  not need it, since HTTPS is TLS from the first byte.

### 30.13 A small client with open low layers (owner, 2026-10-16)

The client stays small on purpose: connection, TLS, the per-origin pool,
keep-alive, one deadline and size limits. Redirects, cookies, compression, a
DNS cache, HTTP/2 and a "renew after N requests" rule are not added to the C
client (a server that wants to recycle a connection sends `Connection: close`,
which the client already honors). Like Python's `urllib` and `http.client`, it
instead exposes its lower layers, so a program or a library written in
Agentica can build what it needs:

1. **ALPN in TLS** (item 19c, §29.7): the `alpn` option and `TLS.alpn(socket)`.
   Without it an HTTP/2 or gRPC library written in Agentica cannot reach
   HTTPS servers, which offer `h2` only through ALPN; with it, such a library
   needs only the public `TCP`, `TLS` and `std/binary`, plus `Bytes` (0.17.0,
   #805).
2. **A public HTTP/1.1 connection** (designed with 20e): open one connection
   outside the pool, send a request, read the response head, then read the
   body piece by piece, like `http.client.HTTPConnection`. `HTTP.open` of 20e
   is the first form of it; its design should keep the connection usable for
   a second request when the body was read to the end, so a program can drive
   one connection itself. `HTTP.get` and the pooled client stay the easy layer
   on top. `HttpWire` itself stays private to `std/http`.

Redirects and cookies, if a program needs them, are a loop over a request in
Agentica code, not a C feature.

### 30.14 Implementation (row 7.4)

One PR per item (20e–20g), each with its own tests and docs; tests are goldens
plus Node peers (no Python server for chunked uploads). Done when: a download
bigger than 64 MiB, a chunked upload and an SSE stream run through channels with
one form for each job, every hostile case of §10.6 is rejected with its code,
and client and server work with Python and Node peers over HTTP and HTTPS.
