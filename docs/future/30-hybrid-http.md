## 30. HTTP on the VM: simple, synchronous, hybrid

**Status:** the simple, synchronous HTTP of roadmap phase 20 is built: the
client (20a), the task cancellation core (20b) and the server (20c; 20d, the
switch to `std/http`, was done by 7i and what was left of it merged into 20c).
It was decided by the user on 2026-10-12: a call sends a whole request and gets
a whole response, a handler returns a whole response, and there is no streaming.
The earlier design, C-only `HttpBody` and `HttpWriter` streams, was replaced by
whole messages because a `String` body is simple for programs and keeps all byte
work in C.

What is built is specified here, not in this file:

| What | Where |
|---|---|
| The API, options, limits, answers and the migration from the builtin `HTTP` module | [`docs/grammar/06d-io-and-network.md`](../grammar/06d-io-and-network.md), "HTTP client and server (`std/http`)"; the migration table in [`site/content/library/io-and-system/network.md`](../../site/content/library/io-and-system/network.md); the hints for removed names in [`07-diagnostics.md`](../grammar/07-diagnostics.md) |
| Parsing rules, the design decisions, the client, the server, errors and status codes, the tests | [`docs/vm/10-io-http.md`](../vm/10-io-http.md) §10.6 and §10.7 |
| Task cancellation for `close_server` | [`docs/vm/10-io-scheduler.md`](../vm/10-io-scheduler.md) §10.2.1 and §10.2.2 |
| Programs and the site | the programming skill's `references/network.md` and `site/content/library/io-and-system/network.md` |

This file keeps what is not built: streaming on channels (20e to 20g, 30.11) and
what comes later (30.12). Sections 30.1 to 30.10 moved to the places above.

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
their timeouts, backpressure and close rules; chunks are `String` (UTF-8, split
only at character boundaries, at most 64 KiB each) until `Bytes` lands (phase
13, order row 7.2.4), which adds byte streams then.

**Channels are enough; lazy `Stream[T]` is not needed.** An HTTP body is pushed
by I/O and read by another task, at its own speed: that is a bounded channel
(backpressure when full), with timeouts on each wait, `close` for the end, and
`closed?` to tell the end from a timeout (§27.2). A lazy stream (§27.4, planned
there for the lines of a file) is pulled by one consumer through a chain of
functions in one task; it would add nothing here.

**No defaults needed.** Every streaming call has a fixed argument list and takes
the options of the client or server it runs on, so default parameter values
(15a, order row 7.5a) never force a second change.

**How errors reach the reader.** A channel can only end, not fail. So a streamed
response carries the body channel and a task:
`HttpStream(status: Int, headers: List[Header], body: Channel[String], done: Task[Result[Void]])`.
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
  `HTTP.upload(client, method, url, headers, length: Int, body: Channel[String]) -> Result[HttpResponse]`:
  the caller's other task feeds the channel and closes it; `length` is the exact
  byte count, or -1 for chunked (the rule of the removed `HTTP.request_stream`);
  the response is whole. It replaces `HTTP.request_stream` without a generic
  producer: the closure or task that feeds the channel carries whatever data it
  needs. The chunked encoder for requests comes back in C for it.
- **20g Streamed responses** (server, SSE included):
  `HTTP.listen_stream(host, port, handler: Fn[HttpRequest, Result[HttpStreamResponse]], options)`
  and `HTTP.listen_stream_tls(...)`, with
  `HttpStreamResponse(status: Int, headers: List[Header], body: Channel[String])`.
  The handler returns at once with the channel; a task it spawned feeds it. The
  connection sends chunked, or `Content-Length` when the channel is already
  closed with everything buffered when the handler returns; it writes each piece
  as it arrives, checks for a client that left on every receive timeout
  (`idle_timeout_ms`), and closes the channel when the client leaves, so the
  feeder's next `send` fails and it stops. An SSE handler sends `data: ...\n\n`
  pieces and, if it wants, comment lines to keep the connection alive.
  `HTTP.whole(text) -> Channel[String]` gives a closed channel holding one
  piece, for the routes of a streaming server that answer with one text.

**One way for each job** (the table the skill teaches):

| Job | The one form |
|---|---|
| Send a request and use its whole response (up to 64 MiB) | `HTTP.get`, `post`, `request` |
| Read a response as it arrives: bigger than 64 MiB, endless, or events (SSE) | `HTTP.open` |
| Upload a body produced as it goes, or bigger than 64 MiB | `HTTP.upload` |
| A server whose every route answers with one whole text | `HTTP.listen` |
| A server with at least one route that streams (SSE, big downloads) | `HTTP.listen_stream`, with `HTTP.whole(text)` for its other routes |

The checker cannot stop `HTTP.open` on a small response, so these pass the
one-way test by job, as `Task.map` and channels do (§27): each form exists for
something the others cannot do (a body that does not fit the limit or never
ends), and the skill teaches whole messages first and the streaming form only
for those jobs. Left out until a program needs it: an upload and a streamed
response in one call (a proxy), and streamed request bodies on the server (big
uploads to an Agentica server); each would need its own one-way test.

### 30.12 Later: binary bodies and `TlsContext`

- **Binary bodies** come after `Bytes` (phase 13, §23): byte forms of the body
  fields and of the stream pieces. They pass the one-way test because a `String`
  cannot hold arbitrary bytes. Their shape is decided with phase 13; until then
  a binary body is an `error` (client) or 400 (server).
- **`TlsContext`** (§29, phase 19) comes at order step 7.4, right after 20g. It
  changes `TLS` and `HTTP` together in one breaking step: `HttpClientOptions`
  loses `ca_file` and `HTTP.client` takes a context, and `HTTP.listen_tls` and
  `HTTP.listen_stream_tls` take a context instead of `cert_file` and `key_file`,
  with one CHANGELOG entry and one migration (§29.5). Until then, phase 20 keeps
  today's file paths, and `HttpWire.client` builds one `SSL_CTX` per client from
  its `ca_file`.
- **STARTTLS** (`TLS.upgrade`) comes with `TlsContext` (§29.3): simple HTTP does
  not need it, since HTTPS is TLS from the first byte.
