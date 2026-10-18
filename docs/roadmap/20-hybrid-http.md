## Phase 20: HTTP on the VM (simple, synchronous, hybrid)

The built parts are specified in [`docs/vm/10-io-http.md`](../vm/10-io-http.md)
(§10.6 parsing, §10.7 design, client, server, answers, tests) and the grammar
([`docs/grammar/06d-io-and-network.md`](../grammar/06d-io-and-network.md));
streaming (20e to 20g) is planned in
[`docs/future/30-hybrid-http.md`][agentica-link-1].
Decided by the user on 2026-10-12. Two parts:

- **20a to 20d, simple HTTP**, are done: the catch-up after TLS (20a
  client), the task cancellation core (20b), and the server (20c, order
  step 7.2.1). 7i deleted the builtin `HTTP` module, so `HTTP` is the
  free import alias of `std/http`, and 20d's switch was done by 7i.
  Record: `docs/vm/10-io-http.md` §10.6–§10.7 and the grammar's
  [`06d-io-and-network.md`](../grammar/06d-io-and-network.md).
- **20e to 20g, streaming**, are new features at order step 7.4, VM-only: after
  phase 17 (`Task.map` at step 7.3, channels at row 7.2.1e), since they are
  built on `Channel[T]` (17b), and right before `TlsContext` (phase 19). Their
  calls have fixed argument lists, so default parameter values (15a, order row
  7.5a) never change them.

Each item is one PR that keeps its own tests and docs (the stacked-PR rule),
lists the docs it updates, and ticks itself here. Simple HTTP keeps today's TLS
parameters (`ca_file`, `cert_file`, `key_file`) until phase 19 changes `TLS` and
`HTTP` together.

**Test peers, by role** (decided by the user on 2026-10-13). Where the VM must
talk to a real implementation, the peer is one whose library does the protocol
work; for raw or hostile cases, it is the language the test file already uses,
so each test file has one peer. So the streaming items (20e to 20g) use Node's
`http`, which decodes chunked in both directions with its own parser and is
event-driven: Python's `http.server` does not decode chunked request bodies, so
a Python server reading the VM's chunked upload would parse chunks with our own
code, which is not an independent implementation. 20a and 20c keep their planned
peers (Python `http.server` and raw sockets, and the Python and Node clients for
the server).

- [x] 20a **Client, and the guards** (`docs/vm/10-io-http.md` §10.7):
  the picohttpparser adapter, the body decoder, `HttpResponse`, the
  `HttpClient` pool, and the `std/http` client; the std-only `HttpWire`
  guard.
- [x] 20b **Task cancellation core** (`docs/vm/10-io-scheduler.md`
  §10.2.1), C only, no public API: parent/children links and
  `agc_task_cancel`.
- [x] 20c **Server** (`docs/vm/10-io-http.md` §10.7): `HttpServer`,
  `HttpRequest`, and the `std/http` server; it took what was left of 20d.
- [ ] 20c-bench **Record the HTTP benchmark numbers** from an idle-machine run
  of `python3 benchmarks/http_bench.py`: fill the results table in
  `docs/vm-benchmarks.md` and note the machine; the script flags rounds that ran
  on a busy machine (`--min-idle`).
- 20d **The switch: done by 7i, the rest merged into 20c.**
- [ ] 20e **Streamed downloads** (§30.11), order step 7.4, after 17b.
  `HttpStream(status, headers, body: Channel[String], done: Task[Result[Void]])`
  and `HTTP.open(client, method, url, headers, body)`: it returns at the
  response head; a feeder task reads pieces with the new primitive
  `HttpWire.read_chunk` (at most 64 KiB, split at UTF-8 boundaries, `""` at the
  end), sends them with the client's `timeout_ms`, closes the channel on every
  path, and ends with `ok()` or the error; a reader that closes the channel
  stops it, and the connection is closed, never pooled. Tests: golden fixtures
  (a body larger than `max_body_bytes` read in pieces, the reader closing early,
  `done` after a clean end); in `tests/test_vm_http.py`, a Node `http` server
  that sends a slow chunked body and one that resets mid-body (`done` gives the
  error; a raw reset may use Node `net`). Docs: `docs/grammar.md`,
  `references/network.md` (the one-form-per-job table of §30.11),
  `site/content/library/io-and-system/network.md`, `docs/vm/10-io-http.md`
  §10.7, the development skill, CHANGELOG ("Added"). Design note (owner,
  §30.13): `HTTP.open` is the public low-level HTTP/1.1 connection, like
  Python's `http.client`; decide in its design whether a connection whose body
  was read to the end can carry a second request.
- [ ] 20f **Streamed uploads** (§30.11), order step 7.4.
  `HTTP.upload(client, method, url, headers, length, body: Channel[String]) ->
Result[HttpResponse]`:
  `length` is the exact byte count or -1 for chunked; a body that ends short or
  long is an `error`; the response is whole. C gets the chunked encoder back for
  requests (`HttpWire` upload primitives). Tests: golden fixtures (fixed length,
  chunked, a wrong length), and Node `http` servers in `tests/test_vm_http.py`
  that read the chunked upload and one that answers early (no Python server:
  `http.server` does not decode chunked request bodies). Docs: as 20e, CHANGELOG
  ("Added").
- [ ] 20g **Streamed responses and SSE** (§30.11), order step 7.4.
  `HttpStreamResponse(status, headers, body: Channel[String])`,
  `HTTP.listen_stream(host, port, handler, options)`,
  `HTTP.listen_stream_tls(host, port, cert_file, key_file, handler, options)`
  and `HTTP.whole(text)`: the connection writes chunked (or `Content-Length` for
  a channel already closed with every piece buffered), writes each piece as it
  arrives, checks for a client that left on each receive timeout
  (`idle_timeout_ms`), and closes the channel when it leaves, so the feeder
  stops. Tests: golden fixtures (an SSE route next to a `HTTP.whole` route, a
  feeder that ends with an error, a client that leaves), and in
  `tests/test_vm_http.py` a Node `http` client that disconnects mid-stream and
  a Python `http.client` reading an SSE stream piece by piece (it decodes
  chunked responses itself, so it is a second independent client). Docs: as 20e,
  with the SSE pattern in `references/network.md`, CHANGELOG ("Added").

**Done when:** `examples/http_get.agc` and `examples/http_server.agc` run on the
VM with `import HTTP from "std/http"` (the first since 7i, the second with 20c);
every hostile case of §10.6 is rejected with its code; the VM's client and
server work with Python and Node peers over HTTP and HTTPS; the performance
check is recorded (item 20c-bench); and, after 20g, a download bigger than 64
MiB, a chunked upload and an SSE stream run through channels with one form
for each job.

[agentica-link-1]: ../future/30-hybrid-http.md#3011-streaming-on-channels
