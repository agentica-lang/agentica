# VM processes, child channel, TCP, TLS and HTTP

Read before touching processes, the child channel, sockets, OpenSSL or HTTP in
`vm/`.

Read first: `references/vm.md` and `references/vm-c.md`.

## Streams and sockets

- `vm/stream.c` (shared by processes and TCP; `docs/vm/10-io-tls.md` §10.3.1):
  `agc_inbuf_line` takes LF within the first 1 MiB + 1 bytes, strips CRLF,
  returns a final line only at EOF, and reports a line that is too long so the
  caller closes. `agc_stream_write` tries `uv_try_write`, then queues one
  `uv_write` of a copy: 0 written, 1 queued, or a libuv error.
- `vm/tcp.c`: each socket or listener is one `malloc`'d `net`, registered when
  the call starts, so a crash or a harness's `agc_io_close` closes it. The end
  of the run closes no socket one by one (`_exit` does); it calls only the
  `goodbye` hook, which sends TLS `close_notify`.
  - Connect tries each resolved address with a fresh link. Listen binds
    every address on one port (`bind_all` retries a port-0 listen when a later
    address finds the port taken). Accept is one FIFO for all links; a failed
    `uv_accept` closes the listener, since libuv stops watching that link.
    `shut` is the one close and finishes every waiting request. The fuzzer's
    `no_files` makes connect and listen fail with `RUNTIME-INTERNAL`.
  - Errors reaching `agc_system_error` go through `agc_net_errno`
    (`vm/net_os.h`), never a bare `-rc`: Windows libuv codes are not negated
    errno values. A listener link counts reported connections (`backlog`),
    since Windows reports several before the first `uv_accept`.
- Threads: every `net` belongs to the I/O thread (§16.9, "Services"). A builtin
  parks with its `begin_*` step as the START's `more` step. The exception is
  `direct_send`: at N > 1 a plain socket's send calls `agc_net_send`
  (`vm/net_os.h`) on the scheduler with `rt->sync` dropped, under the claim
  `W_DIRECT` of the atomic `wstate`, taken only while `rt->sync` and the
  resource hold the net; `shut_one` defers the close of the links to
  `direct_over` while the claim is held. The send holds the writer lock without
  a job (`agc_handle_hold`), so another task's send waits instead of overtaking
  the rest that a partial send parks with. A WebSocket upgrade head clears
  `direct` in `head_value`, so std/http's frames queue on the I/O thread
  (#1191). A close or release posts `release_step` through `agc_loop_call`.
  `finish` copies what the `done` half needs into the request, and
  `request_done` reads only that and posts `drop_request`. `users` changes only
  on the I/O thread (the first count, `own`, excepted). The `net` fields `id`
  and `closed` are atomic for the scheduler's checks. `cancel`
  (`request_cancel`) and `pause` (`stop_request`) touch the request and the
  `net`, never the resource.
- On a detach (a cancelled task), `request_cancel` takes an accept or a read
  that has taken nothing yet out of its slot at once; a finished one is left to
  its `done` half, and its result is dropped.
- At N = 1 every step runs inline; a read of buffered bytes, or a send that goes
  out at once, returns without a park (`agc_io_here`). N > 1 is covered by
  `vm/tests/net_test.c`, `vm/tests/threads_test.c` and
  `tests/test_vm_multicore.py`.
- `vm/net.h` holds the HTTP server's connection object (`agc_conn`). The HTTP
  client has no C side: `std/http` runs on `TCP`/`TLS` sockets (§10.7.1).
- `vm/tls.h`, `vm/tls_openssl.c`, `vm/tls_trust*.c`: the TLS adapter (§10.3),
  with our own types (`agc_tls_config`, `agc_tls`, `agc_tls_failure`). Only
  these and `vm/digest_openssl.c` include OpenSSL. Each session has two memory
  BIOs, and the error queue drains into our codes. Init, minimums, trust and
  verification: §10.3.
- ALPN: the context build turns `alpn` into the RFC 7301 wire form, which the
  pool job sets on the config (`agc_tls_config_set_alpn`). A server config's
  select callback reads the config, so each accepted connection's `net` holds
  its own count on it. `advance` stores the selected name once, in the atomic
  `net.alpn`, for `TLS.alpn`.
- `vm/tls_context.c`: `TLS.client_context`/`TLS.server_context` build a
  `TlsContext` (a refcounted `agc_tls_config`, freed by a GC finalizer run on
  demand) in one pool job; `agc_tls_context_check` checks the role
  (`RUNTIME-TLS-CONTEXT-ROLE`) before the host's name is copied, and the socket
  or listener takes a count with `agc_tls_config_ref`.
- A TLS socket or listener is the same `net` with `secure` set. `TLS.connect`
  and `TLS.listen` take a context's config and connect or listen as TCP does.
  The read callback feeds ciphertext to the session, runs the handshake, and
  decrypts into `agc_inbuf`, so line and byte reads, limits, locks and timeouts
  are the TCP ones. `TLS.upgrade` moves a plain `net`'s libuv handle
  (`tcp_link`, its `owner` and one `callbacks` count) to a new TLS `net` in its
  START step (`begin_upgrade`); the request holds the plain `net` as its
  `child`, and `drop_request` gives its count back. Sends encrypt 16 KiB at a
  time, one `agc_stream_write` per piece. Children in a handshake hang off their
  request (`handshakes`), and closing the listener closes them.

## Child channel

- `vm/duplex.c`: an `agc_duplex` is one bidirectional libuv pipe over a socket
  end (one socket on Unix, a pipe per direction on Windows; `duplex_os.h`, see
  `references/vm-io.md`), with an `agc_inbuf` (lines, 1 MiB), at most one reader
  and one writer request, and a reference count (owner, each request, the pipe
  handle, the shutdown request).
  - Jobs are `external` with the call's timeout. A read parks until a line
    is buffered; a send parks only when the pipe is full. `request_expired`
    closes the whole channel (`agc_duplex_shut`): a timeout ends the channel
    and nothing else. `ECONNRESET` on a read is end of input.
  - With more than one scheduler, every read, send and shut runs as a
    request whose steps run on the I/O thread (`posted`); the scheduler reads
    only the result.
  - `agc_duplex_overflow` (called by `process.c` when stdout or stderr is
    cut) stores the output-exceeds error and readies a pending reader. Lines
    already buffered still come first.
  - Parent side: `agc_duplex_new` over the parent's socket end.
    `agc_duplex_close_write` ignores a `uv_shutdown` that fails on the spot
    (`ENOTCONN` when the peer is gone).
  - Child side: `agc_parent_take` (called by `agc_launch_vm`) takes the
    descriptors only when `AGENTICA_CHANNEL` is exactly `agc_chan_value()`
    (`3`, or `3,4` on Windows) and `agc_chan_take` accepts them. On POSIX fd 3
    must be a socket or a FIFO opened `O_RDWR`: a one-way FIFO fails the read
    start and parks `Test.run` forever. On Windows fd 3 must grant reading and
    fd 4 writing. The variable is removed, and the duplex becomes
    `vm->parent`.
  - `Process.parent_read_line` and `Process.parent_send` take a positive
    timeout and the `vm->parent_locks` pair. With no channel they fail with
    `process: no parent channel`. `process: the channel is in use` comes only
    when a request in that direction is already pending, so a test's call
    never shares a buffer with `Test.run`'s retry request (those park with
    `task->retry` and no timeout), or while a send that a native callback
    started and was refused for still writes (`sending`).

## Processes

- `vm/process.c` (`agc_process_builtins`; §10.4), on libuv. `--deny-run` turns
  it off.
  - `own_env` filters `AGENTICA_CHANNEL` and `UV_USE_IO_URING` (the latter
    only with `drop_uring_env`); `metrics_env` also filters the metrics
    variables. Windows comparisons are case-insensitive. The first spawn marks
    descriptors above 2 close-on-exec (`agc_each_fd`).
  - Executable lookup: `PATH` only for a bare name, never the working
    directory; a name with `/` is relative to the working directory.
    `uv_spawn` gets the absolute path and never verbatim arguments. All three
    stdio are piped.
  - Lifetime: a GC `agc_process` holds the `state` resource and the lock
    records for `agc_handle_wait`. A `malloc`'d `proc` holds the libuv handles
    and buffers and is freed when its user count (resource and requests) and
    handle count (close callbacks) both reach zero.
  - Threads: the I/O thread owns `proc`. With more than one scheduler
    every call (spawn, read, write, close, wait) parks on a request whose
    steps post to the I/O thread, and the result is copied into the request
    (`finish`) before it is readied. One scheduler keeps the inline fast
    paths.
  - stdout is read only while a reader waits, 4 KiB at a time. stderr is
    forwarded in its read callback (`agc_output_forward`), and reading stops
    while its queue is full (`resume_err` restarts it).
  - One close path, `shut`: `SIGKILL`, with no `waitpid` and no sleep anywhere
    in the file; libuv's exit callback `exited` reaps the child and `retire`
    closes its handle. `Process.close` of a plain child that still runs parks
    its task on a `REQ_CLOSE` request (an `external` job with a 1 s timer,
    readied by `exited`; `expired` returns `Void`, so a child in uninterruptible
    sleep is never waited for). Captured children (`Process.spawn_captured`,
    `Process.output`) hold at most 1 MiB per pipe (`out_cut`, `err_cut`) and
    close with `SIGTERM` and a 1 s `grace` timer for `SIGKILL`. The per-run
    guard (`vm->process_guard`) lists the running children for
    `agc_processes_stop`, the first step of the exit path
    (`docs/vm/10-io-processes.md`, `docs/vm/14-core-invariants.md` §14.4);
    `unlink_child` clears `proc.g`, so a release after the guard is freed never
    reaches it.
  - Channel children (`Process.spawn_channel`): `agc_chan_pair` (a
    `uv_socketpair`, or on Windows two `uv_pipe` pairs with blocking child
    ends) on stdio slots 3 and
    4. `child_env` rebuilds the environment on every spawn and adds
    `AGENTICA_CHANNEL=` for channel spawns only. The parent end is an
    `agc_duplex` in `proc.channel`, which `shut` closes with the pipes.
    `read_available` drains stdout with non-blocking reads under the same
    cut rules (the held-back UTF-8 tail included, §10.4). The spawn trace
    line has `channel=`.
  - Pool threads start with `SIGINT`, `SIGTERM` and `SIGHUP` blocked
    (`agc_io_start` does it around `uv_queue_work`). Keep that for any new
    work in the libuv pool. Boehm's marker threads do not block them, so the
    stop handler may run on any thread: it uses only lock-free atomics and
    async-signal-safe calls.

## HTTP

- The head adapter and body decoder (`vm/http_parse.h`, `vm/http_pico.c`,
  `vm/http_body.c`; §10.6, §10.6.1). The rules of §10.6 apply. Tests check
  codes, not messages.
  - Head parsing runs our pre-scan and start-line checks, then picohttpparser
    (`vm/third_party/picohttpparser`, tag v1.4, built at the baseline without
    `-msse4.2`), then our token, value, obs-fold, Host and status checks
    (§10.6.1). Only `vm/http_pico.c` includes `picohttpparser.h`. It runs
    without `last_len` and only when new bytes complete a line. The head is
    limited to an 8192-byte start line plus 64 KiB of headers. A -1 becomes a
    400 or a client error `Result`.
  - Bodies (Content-Length, chunked with saturating sizes and checked
    trailers, close-delimited) go through our incremental decoder: `feed`
    returns bytes consumed, body slices, and NEED_MORE, DONE or ERROR. There
    is no `phr_decode_chunked`, so bodies stream and are never buffered whole.
- `vm/http_wire.c`: the `HttpWire` helpers std/http uses. They have no I/O and
  no state: each takes bytes or a record and returns a string or a std-only
  record. `chunk` checks every field of a `Chunk` before it rebuilds the decoder
  (`vm/tests/http_wire_test.c`). `read_head` and `read_response` keep the head
  in the input until it is whole, with a scan hint so each line is parsed once;
  `read_head`'s `rest` goes back in front first (`agc_inbuf_unread`).
- `vm/http_service.c`: `HttpWire.service`, `jobs` and `options` (§10.7.1). The
  client's owner task is a root with no parent, so the client outlives a crash
  or cancel of its maker. `Task.pending_count` and `Test.test` leave its tasks
  out, and their timers are weak for the stall check (`rt->timers_weak`). The
  pool itself is `stdlib/http.agc`. Worker sockets are tcp.c sockets, so the end
  of the run sends their TLS close_notify. The client's TLS context
  (`HttpWire.connect_tls`, `HttpWire.drop_tls`) is a reference-counted
  `tls_shared` built once on a pool thread; each connection and the build hold a
  reference, so `drop_tls` never frees it under a handshake.
  `HttpWire.upgrade_tls` (a CONNECT tunnel, `TLS.upgrade` on that context) takes
  one the same way and starts its handshake once the build is over
  (`shared_ready`).
- `vm/http_server.c`: the server task group. The I/O thread owns the listener,
  the open count and the queue of `accept` and `wait` jobs. Builtins change them
  only by posted steps; `closed` is atomic (§10.7.2). It runs at N > 1
  (`make test-multicore-modules`).
  - The `HttpWire.Server` holds a `server` and a group node
    (`agc_task_group`) that runs std/http's accept loop.
    - `spawn` starts the connection task under the group with
    `agc_task_spawn_owning` (the socket goes to the task), marks it `hidden`,
    and sets an `end` hook that only frees the slot. `finish_task` closes the
    socket first. `close_server` (also the owned close) closes the listener,
    wakes the waiters and cancels the group; each cancelled task closes the
    handles it owns as it ends. Closes may nest, which is safe because each
    takes the head of its own task's list. Every wait is an `external` job with
    a `cancel` half.
- `stdlib/http.agc` reads requests, writes responses and runs the client pool;
  the order of checks, the lingering close, the response head rules, connection
  reuse and retry, and the crash accounting of `hidden` server connections are
  `docs/vm/10-io-http.md` (§10.6 to §10.7) and `docs/vm/10-io-scheduler.md`
  (`quiet_more`). The C side only gives `HttpWire` its bytes-in, string-out
  helpers. Handlers cannot reach their own `HttpWire.Server` (values are
  immutable, and the handler is fixed before the server exists), so the
  self-close case is a C test.

## OpenSSL and the build

The modes, the stamp, the vendored build and the release link are
`docs/vm/10-dependencies-and-platforms.md` §10.0 (`OSSL_*` in `mk/vm.mk`).
Rules for a change:

- The mode is not remembered: pass `AGENTICA_OPENSSL=vendored` to every make
  command, or export it. `vm/tls_openssl.c` has an `#error` for OpenSSL older
  than 3.0 and for LibreSSL.
- The vendored sanitizer build uses a non-instrumented OpenSSL; ASan's
  interceptors still check the buffers we pass it. The vendored commands run
  under `env -u` for make and compiler variables, and the sub-make is a plain
  `make` (never `$(MAKE)`, so `make -n` skips it).
- `$(VM_BUILD)/openssl-flags` is the key of the vendored build only
  (`make -s vm-openssl-key AGENTICA_OPENSSL=vendored`), so `TRACE` and VM flag
  changes never rebuild OpenSSL. After hand edits to OpenSSL sources, remove
  `$(VM_BUILD)/openssl`.
- Never hand OpenSSL a GC pointer, and keep file loading off the scheduler
  thread (the config loads in a libuv pool job).
- A static libcrypto on Windows also needs `-lcrypt32 -lgdi32`; on macOS the
  trust loader needs the Security and CoreFoundation frameworks.
- Bumping OpenSSL: `references/vm-build.md`, "Submodules".

## Tests and peers

Read the test files for the cases; these are the rules behind them.

- Processes: `tests/test_vm_diff_8.py` checks that no grandchild outlives its
  run (closed by `Process.close` or a `read_line` timeout; one that ignores
  `SIGTERM`; one that dies on `SIGTERM` right before `main` returns). Signal
  tests (`tests/test_vm_stop.py`, `test_vm_diff_8.py`) signal with `os.kill` and
  bound every wait; each run must end with `end code=0 signal=0` in the `io`
  trace. Captured children run `std/bdd`'s scenario VMs: never block in their
  close (only the bounded end-of-run cleanup may wait), and send `SIGTERM`
  first, since the child VM's exit path stops the programs it started. C tests
  use `vm/tests/process_test.c` with their own executable as the child.
- Golden fixtures keep their step counts independent of timing: wait for an
  event (`wait`, a read, `output`) before a call whose result depends on it;
  avoid the "process is closed" path after a stream timeout. The `tcp-*`,
  `http-*` and `http-server*` fixtures are their own peers (a listener and its
  clients in one program), print only from `main` after its awaits, and read
  bytes only after the writer is done, since `recv_bytes` returns what has
  arrived. A golden that needs a write to stay parked sends one String far
  larger than the loopback buffers (64 MiB), never a loop of sends. A connect
  timeout has no hermetic test (it needs an address that drops SYNs).
- `tests/test_vm_tcp.py`, `test_vm_tls.py`, `test_vm_http.py` run in the macOS
  and Windows jobs of `platforms.yml`; use short timeouts, small payloads, no
  sleeps, and one case per behavior. Node (TCP, TLS, HTTP server) and Python 3
  (TLS, HTTP) are required in CI and skipped locally. Peers print LF on
  Windows too (`sys.stdout.reconfigure(newline="\n")`); a waiters case blocks
  the CA file on a FIFO (a named pipe on Windows, `BlockingFile`).
- Keep TLS goldens few and small (`tls-echo`, `tls-errors`): every `--max-steps`
  sweep run does a handshake. The `tls-*` fixtures take `@fixtures/tls` in
  `.args` (`fixture_arg` in `tests/vm_diff_support.py` makes it absolute);
  certificates come from `tests/fixtures/tls/make-certs.sh` (OpenSSL 3.4 or
  newer for the expired one). The std/http URL parser costs about 500 steps per
  call, so the sweep samples the `http-*` fixtures.
- HTTP server tests: every server is `HTTP.serve` (or `serve_tls`) on port 0
  with the ports on its first line; closing its stdin ends it. A side `TCP`
  listener tells `main` that a handler started, so the close, slow-handler and
  `main`-returns cases do not depend on timing. Hostile requests, pipelining,
  `max_connections` and the bounded flood run against
  `tests/fixtures/http-server-peer.py` and `.js`; streams, uploads, WebSocket
  (`tests/test_vm_websocket.py` with its own RFC 6455 client) and the proxy
  (`tests/test_vm_http_proxy.py`) have their own peers in `tests/fixtures/`.
