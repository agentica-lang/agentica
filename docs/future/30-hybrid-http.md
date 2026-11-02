## 30. HTTP on the VM: simple, synchronous, hybrid

**Status:** built: the simple, synchronous HTTP of roadmap phase 20 (client 20a,
cancellation core 20b, server 20c; a call sends a whole request and gets a whole
response, decided by the user on 2026-10-12, since a `Bytes` body is simple for
programs and keeps all byte work in C) and the streaming items on channels (20e
`HTTP.open`, 20f `HTTP.upload`, 20g streamed responses). The contract is the
grammar ([`06d-io-and-network.md`](../grammar/06d-io-and-network.md)) and the
[network page](../../site/content/library/io-and-system/network.md); the parsing
rules, design, errors and tests are in
[`docs/vm/10-io-http.md`](../vm/10-io-http.md) §10.6 and §10.7. This file keeps
the decisions behind streaming and the owner's choice for a small client.

### 30.11 Streaming on channels

Streaming brings back the jobs a whole message cannot do, built on channels with
their timeouts, backpressure and close rules (§27.2).

**Channels are enough; `Lazy[T]` is not needed.** An HTTP body is pushed by I/O
and read by another task at its own speed: a bounded channel (backpressure when
full), timeouts on each wait, `close` for the end, and `closed? and empty?` to
tell the end from a timeout. A `Lazy` (§27.4) is pulled by one consumer through
a chain of functions in one task and would add nothing here.

**How errors reach the reader.** A channel can only end, not fail. So a streamed
response carries the body channel and a task: `HTTP.Stream(status, headers,
body: Channel[Bytes], done: Task[Result[Void]])`. The task feeds the channel and
closes it on every path (§27.2's rule), and its result says whether the body
ended cleanly. The reader runs the canonical receive loop and then awaits
`done`. To stop early the reader closes the channel: the feeder's next `send`
fails, it closes the connection (never back to the pool) and ends with an error.

**One way for each job:** a request whose whole response (up to 64 MiB) is used:
`HTTP.get`, `post`, `request`. A response read as it arrives (bigger than
64 MiB, endless, or events such as SSE): `HTTP.open`. An upload produced as it
goes, or bigger than 64 MiB: `HTTP.upload`. A server, whatever its routes do
(whole answers, streams, uploads too big to hold, WebSockets): `HTTP.serve`,
whose `HTTP.App` answers each request; the per-kind `listen` forms are replaced
by it. The checker cannot stop `HTTP.open` on a small response, so these pass
the one-way test by job, as `Task.map` and channels do (§27): each form exists
for something the others cannot do, and the skill teaches whole messages first.
Left out until a program needs it: an upload and a streamed response in one call
(a proxy), which would need its own one-way test.

### 30.13 A small client with open low layers (owner, 2026-10-16)

The client stays small on purpose: connection, TLS, the per-origin pool,
keep-alive, one deadline and size limits. Redirects, cookies, compression, a DNS
cache, HTTP/2 and a "renew after N requests" rule are not added to the C client
(a server that wants to recycle a connection sends `Connection: close`, which
the client honors). Like Python's `urllib` and `http.client`, it instead exposes
its lower layers, so a program or a library written in Agentica can build what
it needs:

1. **ALPN in TLS** (item 19c, §29.7): the `alpn` option and `TLS.alpn(socket)`.
   Without it an HTTP/2 or gRPC library written in Agentica cannot reach HTTPS
   servers, which offer `h2` only through ALPN; with it such a library needs
   only the public `TCP`, `TLS`, `std/binary` and `Bytes`.
2. **A public HTTP/1.1 connection**: open one connection outside the pool, send
   a request, read the response head, then the body piece by piece, like
   `http.client.HTTPConnection` (`HTTP.start`; `HTTP.open` is its channel form).
   The design keeps the connection usable for a second request when the body was
   read to the end. `HTTP.get` and the pooled client stay the easy layer on top;
   `HttpWire` stays private to `std/http`.

Redirects and cookies, if a program needs them, are a loop over a request in
Agentica code, not a C feature.

### 30.14 Implementation (row 7.4)

One PR per item (20e to 20g); tests are goldens plus Node peers (no Python
server for chunked uploads), and client and server work with Python and Node
peers over HTTP and HTTPS.
