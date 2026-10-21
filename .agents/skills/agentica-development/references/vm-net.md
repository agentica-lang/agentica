# VM processes, child channel, TCP, TLS and HTTP

Read before touching processes, the child channel, sockets, OpenSSL or HTTP in
`vm/`.

Read first: `references/vm.md` and `references/vm-c.md`.

## Files

- **Path:** `vm/duplex.c`
  - **Owns:** The child channel and the duplex stream of
    `Process.spawn_channel`: a libuv stream to read and one to write (one
    socket on Unix, a pipe per direction on Windows). The ends are made and
    taken in `duplex_os.h` (`references/vm-io.md`).

- **Path:** `vm/process.c`
  - **Owns:** The `Process` builtins behind `--allow-run`, using libuv on Unix
    and Windows.

- **Path:** `vm/stream.c`
  - **Owns:** what processes and TCP share (`docs/vm/10-io-tls.md` §10.3.1):
    `agc_inbuf` (one `malloc`'d input buffer with EOF and a sticky read error;
    `agc_inbuf_want` gives the read size: 4 KiB or what a byte read still
    needs), `agc_inbuf_take` (drop the first bytes of the pending data and keep
    `scanned` right), `agc_inbuf_line` (LF in the first 1 MiB + 1 bytes,
    searched once per byte through `scanned`, CRLF stripped, a final line only
    at EOF, the read error when bytes without LF end in an error, the caller's
    texts for too long and end of input; it says when the line was too long so
    the caller closes), the same cuts as a `malloc`'d `agc_inbuf_cut` made on
    the I/O thread, whose value a scheduler builds later, `agc_stream_write`
    (`uv_try_write`, then one `uv_write` of a `malloc`'d copy in buffers of at
    most 1 GiB; 0 written, 1 queued, or a libuv error), `agc_new_lock` and
    `agc_stream_lock` (an unregistered lock record, and the timeout check plus
    `agc_handle_wait`), and the `network:` timeout texts

- **Path:** `vm/tcp.c`
  - **Owns:** the `TCP` and `TLS` builtins (`agc_tcp_builtins`; Linux, macOS
    and Windows; §10.3.1, TLS in §10.3): one `malloc`'d `net`
    for a socket or a listener
    (users: the resource and each request; callbacks: a DNS lookup in flight and
    one close callback per `tcp_link`, a `malloc`'d `uv_tcp_t` with its
    `uv_connect_t` that finds the `net` through `owner`), registered when the
    call starts, so a crash or the in-process harnesses' `agc_io_close` closes
    it; the VM's own end of the run closes no socket one by one (`_exit` does),
    and only calls the `goodbye` hook for TLS `close_notify`; requests park on
    `external` jobs (`park`): connect resolves with `uv_getaddrinfo` and tries
    each address with a fresh link (`attempt` takes its callback as an argument,
    so no prototype is needed), listen binds every resolved address on one port
    (one link per address, chained through `next`; `bind_all` retries a port-0
    listen when a later address finds the port taken), accept is one FIFO for
    all links that `serve` feeds with `uv_accept` (a failed `uv_accept` closes
    the listener, since libuv stops watching that link), reads and writes
    use the `agc_socket` reader and writer locks and `vm/stream.c`; `shut` is
    the one close (trace `why`), and finishes every waiting request; `no_files`
    (the fuzzer) makes connect and listen fail with `RUNTIME-INTERNAL`. Every
    `net` belongs to the I/O thread (§16.9, "Services"): a builtin parks with
    its `begin_*` step as the START's `more` step, a close or a resource's
    release posts `release_step` with `agc_loop_call`, `finish` copies what
    the `done` half needs into the request (`opened`, `closed`, the cut, the
    write status, the accepted child), and `request_done` reads only that and
    posts `drop_request`; `users` changes only on the I/O thread, except the
    first count of a `net` a builtin has just made (`own`, before any other
    thread sees it), and the `net` fields `id` and `closed` are atomic for the
    scheduler's checks. `cancel`
    (`request_cancel`) and `pause` (`stop_request`) touch the request and the
    `net` only, never the resource. At a detach (a cancelled task),
    `request_cancel` takes an accept or a read that has taken nothing yet out
    of its slot at once; a finished one is left to its `done` half,
    whose result is dropped. At N = 1 every step runs inline, and a
    read of buffered bytes or a send that goes out at once returns without a
    park (`agc_io_here`). Tested at N > 1 by `vm/tests/net_test.c` (exact
    orders), `vm/tests/threads_test.c` and the net programs of
    `tests/test_vm_multicore.py`

- **Path:** `vm/net.h`
  - **Owns:** tcp.c's connection object for the HTTP server (`agc_conn`,
    `agc_conn_*` and `agc_net_close`; `agc_conn_observe` is a watch callback on
    every state change) and `agc_tls_load_error`. The client has no C side: it
    is `std/http` on `TCP`/`TLS` sockets (`docs/vm/10-io-http.md` §10.7.1)

- **Path:** `vm/http_parse.h`, `vm/http_pico.c`, `vm/http_body.c`
  - **Owns:** the HTTP head adapter and body decoder (§10.6, §10.6.1): limits as
    constants, `agc_http_error` with its status and text,
    `agc_http_parse_request_head`/`_response_head` (our pre-scan and start-line
    checks, then picohttpparser, then token, value, obs-fold, Host and status
    checks), `agc_http_framing`, and the body decoder
    (`agc_http_body_init/feed/end/free`: Content-Length, chunked with saturating
    sizes and checked trailers, close-delimited, one `malloc`'d buffer within
    the limit). In `discard` mode it only counts: `agc_http_body_step` stops
    after one run of body bytes, and `agc_http_body_skip` counts chunk data the
    caller read itself. No recursion

- **Path:** `vm/http_fields.h`, `vm/http_fields.c`
  - **Owns:** what the client and the server share (`agc_http_closes` on a
    parsed head and `agc_http_list_closes` on a `List[Header]` use one token
    check): a growable byte buffer, the header writer with its checks and the
    managed names (`agc_http_put_headers` returns a reason without the `http: `
    prefix), the kept header fields (names lowercased) and their
    `List[Header]`, and `agc_http_error_result`

- **Path:** `vm/http_wire.c`
  - **Owns:** the `HttpWire` functions std/http's client and server read and
    write with (Linux, macOS and Windows): `chunked`, `chunk`, `chunk_read`,
    `text`, `encode_request`, `encode_response` and `error_answer`. No I/O and
    no state: each takes bytes or a record and returns a string or a std-only
    record (`HttpWire.Chunk`, `HttpWire.Text`, `HttpWire.Reply`). `chunk`
    rebuilds the decoder from a `Chunk` and checks every field first
    (`vm/tests/http_wire_test.c`). `agc_http_head_value`,
    `agc_http_response_value` and `agc_http_text_value` build the `Head`,
    `Response` and `Text` of the reads in `vm/tcp.c`: `HttpWire.read_head` and
    `read_response` (the head stays in the input until it is whole, with a scan
    hint so it is parsed once per line; `read_head`'s `rest` goes back in front
    first, `agc_inbuf_unread`) and `HttpWire.read_text`, next to
    `HttpWire.close_write` and `clean_eof?`.

- **Path:** `vm/http_server.c`
  - **Owns:** The `HttpWire` server task group (Linux, macOS and Windows).
    The I/O thread owns the server's listener, open count and queue
    of `accept` and `wait` jobs; builtins change them only by posted steps
    (`agc_loop_call`), `closed` is atomic, and an accept's done half makes the
    socket from the connection the I/O thread took (§10.7.2). Runs at N > 1:
    the HTTP module is in `make test-multicore-modules`, and
    `tests/test_vm_multicore.py` has a load case with cancels and a close.

- **Path:** `vm/http_service.c`
  - **Owns:** `HttpWire.service`, `jobs` and `options`
    (`agc_http_service_builtins`, Linux, macOS and Windows; §10.7.1). `service`
    runs the client's owner task with `agc_task_service` (`vm/task.c`): a root
    with no parent, so the client outlives a crash or cancel of its maker,
    `Task.pending_count` and `Test.test` leave its tasks out, and their timers
    are weak for the stall check (`rt->timers_weak`). The `HttpClient` value
    holds the jobs channel and the options. The pool itself (owner, one worker
    per connection, FIFO, retry) is `stdlib/http.agc`, on `TCP`, `TLS`,
    `Channel` and `Task`; the workers' sockets are tcp.c sockets, so the end of
    the run sends their TLS close_notify. `service` builds the client first and
    passes it to its owner function. The client's TLS context
    (`HttpWire.connect_tls`, `HttpWire.drop_tls`) is a reference-counted
    `tls_shared` in `vm/tcp.c`, built once on a pool thread; each connection and
    the build hold a reference, so `drop_tls` never frees it under a handshake

- **Path:** `vm/tls.h`, `vm/tls_openssl.c`, `vm/tls_trust.h`, `vm/tls_trust.c`,
  `vm/tls_trust_{posix,darwin,windows}.c`
  - **Owns:** the TLS adapter (`docs/vm/10-io-tls.md` §10.3): our own types
    (`agc_tls_config`, `agc_tls`, status OK, WANT_READ, WANT_WRITE, CLOSED or
    ERROR, `agc_tls_error`, `agc_tls_failure` with code, `errno` and a short
    detail); `vm/tls_openssl.c`, `vm/tls_trust.c` and `vm/tls_trust_posix.c` are
    the TLS files that include OpenSSL (the other is the digest adapter
    `vm/digest_openssl.c`, for `Crypto.sha256`); two memory BIOs per session,
    error-queue draining into our codes; built and used for sockets on every
    system. Init, minimums, trust and verification rules:
    `docs/vm/10-io-tls.md` §10.3

- `vm/duplex.c`
  - the child channel (25c, service; `docs/vm/10-io-processes.md` §10.4 "As
    built (25c)"; Linux and macOS, a pipe path on Windows): an `agc_duplex`
    is one bidirectional libuv pipe over a socket end with an `agc_inbuf`
    (line reads, 1 MiB), at most one reader request and one writer request, a
    reference count (the owner, each request, the pipe handle and the shutdown
    request) the
    `overflow` text and the flags `closed`, `write_closed` and `sent`.
  - `agc_duplex_overflow` (called by `process.c` when stdout or stderr is cut)
    stores the output-exceeds text and readies a pending reader
  - a read that finds no complete line then returns that error, now or later,
    and lines already buffered still come first.
  - The jobs are `external` loop jobs with the call's timeout (`duplex_io`, kind
    name `channel`): a read parks until a line is in the buffer, a send writes
    with `agc_stream_write` and parks only when the pipe is full
  - `request_expired` closes the whole channel (`agc_duplex_shut`), so a timeout
    ends the channel and nothing else
  - `ECONNRESET` on a read is the end of input.
  - With more than one scheduler every read, send and shut is a request whose
    steps run on the I/O thread (`posted`): the scheduler reads only the
    request's result, and the parent channel is attached at start.
  - The parent side is used by `process.c` (`agc_duplex_new` over the parent's
    socket end); `agc_duplex_close_write` ignores a `uv_shutdown` that fails on
    the spot (`ENOTCONN` when the peer is gone)
  - the child side is `agc_parent_take` (called by `agc_launch_vm` in
    `vm/launch.c` after
    `agc_files_init`: takes the descriptors only when `AGENTICA_CHANNEL` is
    exactly the value `agc_chan_value()` gives (`3` on POSIX, `3,4` on
    Windows) and `agc_chan_take` accepts them: on POSIX fd 3 a socket or a FIFO
    opened `O_RDWR` (`F_GETFL`; a one-way FIFO would fail the read start and
    park `Test.run` for ever), moved with `F_DUPFD_CLOEXEC`; on Windows fd 3 a
    pipe that grants reading and fd 4 one that grants writing, duplicated
    without inheritance. The originals are forgotten in the inherited-file
    table and closed, the variable is removed, and the duplex is registered as
    `vm->parent`; the libuv handles are attached on first use), the builtins
    `Process.parent_read_line` and `Process.parent_send` (a positive timeout,
    the `vm->parent_locks` pair; `error("process: no parent channel")` without a
    channel; `process: the channel is in use` only when a request in that
    direction is already pending, which keeps a test's call from sharing a
    buffer with `Test.run`'s retry-style request) and the functions `Test.run`
    uses (`agc_parent_open`, true when the channel exists and is not closed, and
    `agc_parent_line` and `agc_parent_send`, which park the calling task with
    `task->retry`, without a timeout)
- `vm/process.c`
  - the `Process` builtins (`agc_process_builtins`,
    `docs/vm/10-io-processes.md` §10.4) use libuv on Unix and Windows.
  - `own_env` filters `AGENTICA_CHANNEL` and `UV_USE_IO_URING` when
    `drop_uring_env`; `metrics_env` also filters the two metrics variables
    from child environments. Windows comparisons are case-insensitive.
  - child environments own copies of the snapshot from `uv_os_environ`.
  - a GC `agc_process` with the registered `state` resource and two unregistered
    lock records (`reader`, `writer`) for `agc_handle_wait`
  - a `malloc`'d `proc` with the `uv_process_t`, three `uv_pipe_t` (real pipes
    from `uv_pipe` given with `UV_INHERIT_FD`), the stdout buffer and the
    pending requests, freed when its user count (resource and requests) and
    handle count (close callbacks) reach zero
  - requests park on `external` jobs that pipe, write and exit callbacks ready
    with `agc_io_ready`
  - the I/O thread owns `proc`; with more than one scheduler every call
    (spawn, read, write, close, wait) parks on a request whose steps post to
    the I/O thread, and the result is copied into the request (`finish`)
    before it is readied; one scheduler keeps the inline fast paths
  - stdout is read only while a reader waits, 4 KiB at a time (more only for a
    bigger `read_bytes`)
  - stderr is forwarded in its read callback through `agc_output_forward`; the
    read stops while the stderr queue is full and `resume_err` restarts it
  - one close path (`shut`: `SIGKILL`, with no `waitpid` and no sleep anywhere
    in the file; libuv's exit callback `exited` reaps the child and `retire`
    closes its `uv_process_t`; a failed kill in `Process.close` is
    `RUNTIME-PROCESS-CLOSE`) for `close`, stream timeouts and the end of run
  - `Process.close` of a plain child that still runs parks its task on a
    `REQ_CLOSE` request (an `external` job with a 1 s timer, kept in `waits`,
    readied by `exited`; `expired` returns `Void`, so a child in uninterruptible
    sleep is not waited for), while every other close only signals (§10.4 Close)
  - the park is skipped when the kill failed
  - the per-run guard (a registered resource, `vm->process_guard`): the list of
    running children and the loop
  - `agc_processes_stop`, the first step of the one exit path (stop signals are
    `vm/loop.c`'s, not the guard's), calls `close_children` (once per run: a
    second call returns at once), which sends the signals and then
    `await_exits`: `uv_run` ONCE under a 1 s stack timer until the awaited
    children (kill not failed) have exited, and `unlink_child` clears `proc.g`
    so a release after the guard is freed never reaches it
  - the first spawn marks inherited descriptors above 2 close-on-exec
    (`agc_each_fd`)
  - executable lookup (`PATH` only for a bare name, the working directory for a
    name with `/`)
  - captured children (`Process.spawn_captured`, `Process.output`, 21a, §10.4
    "As built (21a)"): `spawn_child` serves both spawns, `cwd` from `dir`, both
    pipes read from the spawn on into `out_buf` and `err_kept` held to 1 MiB of
    capacity (`out_cut`, `err_cut`), `output` a wait like `wait`
    (`await_child`), and a close
    that sends `SIGTERM` and starts the 1 s `grace` timer for `SIGKILL`
    (`retire` closes the timer and the process handle once the child is gone)
  - the end of the run waits for captured children under one `await_exits` bound
    before it kills them (a second bound waits for the exits)
  - the child channel (25c, §10.4 "As built (25c, the child channel)"):
    `Process.spawn_channel` is `spawn_child` with `channel` true:
    `agc_chan_pair` (a `uv_socketpair`, or on Windows two `uv_pipe` pairs whose
    child ends are blocking), stdio slots 3 (and 4) that hand the child ends
    over, and `child_env`, which rebuilds the child environment on every spawn
    (it removes `AGENTICA_CHANNEL`, removes `UV_USE_IO_URING` when
    `drop_uring_env`, and adds `AGENTICA_CHANNEL=` with `agc_chan_value()` for a
    channel spawn only; `AGC_CHANNEL_ENV` is in `vm/services.h`)
  - the parent end is an `agc_duplex` (`vm/duplex.c`) in `proc.channel`, and the
    `agc_process` has a third pair of lock records, `channel.reader` and
    `channel.writer`
  - `channel_read_line`, `channel_send` and `channel_close` call the duplex
    functions with those locks, `shut` closes the channel with the pipes, and
    `read_available` drains the stdout pipe with non-blocking `read`s
    (`drain_out`, into `out_buf` through the same cut rules) before it consumes
    the pending bytes (limits and the held-back UTF-8 tail:
    `docs/vm/10-io-processes.md` §10.4), and takes them out with
    `agc_inbuf_take`
  - the trace line of a spawn has `channel=`
- `stdlib/http.agc` reads requests and writes responses (§10.7.2)
  - the first byte through a 1-byte `TCP.recv_bytes` (its own wait), then the
    head through `HttpWire.read_head`; the order of `docs/vm/10-io-http.md`
    §10.7.3 (parse errors, `Upgrade` 501, `Expect` 417, the `Content-Length`
    limit 413, then `100 Continue`, then the body with its UTF-8 check as the
    bytes arrive) is in `agc_http_head_value`
  - a `Content-Length` body through `HttpWire.read_text`; a chunked one through
    `HttpWire.chunk` on 512-byte reads, with chunk data past the framing read
    by `read_text` and counted by `chunk_read`
  - every error answer is `HttpWire.error_answer`, then the lingering close
    (`close_write`, drop input until the peer closes, the deadline or
    `DRAIN_BYTES` (256 KiB), so no reset loses the answer)
  - bytes past one request stay in the input for the next (a chunked body's
    last read gives them back as `rest`); TCP reads only while a reader waits,
    so pipelined bytes cannot pile up
  - `HttpWire.encode_response` builds the head first (status 200..599, no body
    on 204 and 304 or for `HEAD`, `Content-Length` and `Transfer-Encoding`
    managed, a `Date` header; when the request or response says
    `Connection: close` (`agc_http_list_closes`), the handler's `Connection`
    headers are dropped for one `Connection: close`) and says whether the
    connection closes, or gives the reason without writing
- `vm/http_server.c`
  - `HttpWire.server`, `accept`, `spawn`, `close_server`, `wait` and
    `local_port` (`agc_http_server_builtins`, Linux, macOS and Windows;
    §10.7)
  - The `HttpServer` holds a `server` (listener, open count, `max`, waiting
    `accept` and `wait` jobs poked by the listener watch, a freed slot and the
    close) and a group node (`agc_task_group`) in which `server` starts
    `std/http`'s accept loop: `spawn` starts the connection task under it with
    `agc_task_spawn_owning` (the hand-off of `Task.spawn_owning`: the socket
    goes to the connection task), marks it `hidden` and sets its `end` hook,
    which only frees the slot (the one close path, `finish_task`, closes the
    socket first)
  - `close_server` (also the owned close) closes the listener, wakes the waiters
    and cancels the group (`agc_task_cancel`: each cancelled task closes the
    handles it owns as it ends; the closes may nest, which is safe because each
    takes the head of its own task's list).
  - Every wait is an `external` job with a `cancel` half

## Design notes

- **OpenSSL 3.5 (7h, in on Linux)**
  - `AGENTICA_OPENSSL` picks it (`docs/vm/10-dependencies-and-platforms.md`
    §10.0).
  - The default `system` links the system OpenSSL dynamically (`pkg-config`).
    A stamp (`OSSL_DEP` in the Makefile) fails with a clear message when
    `pkg-config` or the package is missing or older than `OSSL_MIN` (3.0.0: the
    code uses 3.0 APIs such as `SSL_CTX_load_verify_file`), and
    `vm/tls_openssl.c` has an `#error` for older versions and LibreSSL.
  - The mode is not remembered: pass `AGENTICA_OPENSSL=vendored` to every make
    command or export it.
  - `vendored` (the release and the Platforms jobs) builds the submodule static
    per build mode (`OSSL_OPTS` and `OSSL_CFLAGS` in the Makefile; the
    sanitizer build uses a non-instrumented OpenSSL, and ASan's interceptors
    still check the buffers we hand it). Both commands run under `env -u` for
    the make and compiler variables, and the sub-make is a plain `make` (never
    `$(MAKE)`, so `make -n` skips it).
  - `$(VM_BUILD)/openssl-flags` is the key of the vendored build only (`make -s
    vm-openssl-key AGENTICA_OPENSSL=vendored`, which refuses the system mode),
    rewritten only when it changes, and the archives depend only on it, so
    `TRACE` and VM flag changes never rebuild OpenSSL and a restored CI cache is
    up to date
  - after editing OpenSSL sources by hand, remove `$(VM_BUILD)/openssl`.
  - Init, minimums, trust sources and verification (security rules):
    `docs/vm/10-io-tls.md` §10.3.
  - Never hand OpenSSL a GC pointer, and keep file loading off the scheduler
    thread (the config loads in a libuv pool job).
  - The release (`zig cc`, glibc 2.28) sets `AGENTICA_OPENSSL=vendored` and
    `AGENTICA_GC=vendored`
  - `make vendored-check` lists the binary's shared libraries: no `libssl`,
    `libcrypto`, `libgc` or
    `msys-2.0.dll`, and `--version` must name the submodule's version. On
    Windows a static libcrypto also needs `-lcrypt32 -lgdi32`; on macOS the
    trust loader needs the Security and CoreFoundation frameworks.
  - `--version` prints the OpenSSL that runs (`OpenSSL_version`), so a system
    build shows the distro's version.
  - `build/vm/flags` records the mode, so switching it relinks.
  - Bumping: fetch the new 3.5.x tag in the submodule, commit it, rebuild with
    `AGENTICA_OPENSSL=vendored`, rerun the TLS, sanitizer and golden tests.
- **HTTP (7h)**
  - The rules (codes, strict framing, the adapter's checks, the body decoder)
    are `docs/vm/10-io-http.md` §10.6. Parity with the old evaluator is
    black-box: well-formed messages give the same status, headers, body and
    `Result` ok or error, and malformed input is rejected by both. Do not copy
    evaluator quirks or its order of failing lines.
  - picohttpparser (submodule `vm/third_party/picohttpparser`, MIT or Perl,
    tag v1.4, built at the baseline without `-msse4.2`) parses and validates
    start lines and headers behind `vm/http_parse.h` (our head struct with byte
    slices, `agc_http_parse_request_head`/`agc_http_parse_response_head`
    returning OK with bytes consumed, INCOMPLETE or ERROR with our error
    enum). Only `vm/http_pico.c` includes `picohttpparser.h`. It is called
    without `last_len` and only when new bytes complete a line (head at most
    the 8192-byte start line plus 64 KiB of headers); a -1 is 400 or a client
    error `Result`.
  - The pre-scan skips one leading CRLF before a request and stops at the end
    of the start line.
  - The body goes through our incremental decoder `vm/http_body.c` (`feed`
    returns bytes consumed, body slices, and NEED_MORE, DONE or ERROR; no
    `phr_decode_chunked`), so bodies stream and are never buffered whole.
  - Tests target the adapter and check rejections and the codes that must
    match, not messages (`docs/vm/10-io-http.md` 10.6).
- **Processes (7h, in on Linux)**
  - `vm/process.c`, `docs/vm/10-io-processes.md` §10.4.
  - The VM resolves the executable itself (`PATH` only for a bare name, never
    the working directory) and passes the absolute path to `uv_spawn`
  - never verbatim arguments
  - all three stdio piped
  - `UV_USE_IO_URING` is dropped from the child's environment only when the VM
    set it.
  - The evaluator keeps a direction's lock after a stream timeout (a legacy bug;
    the VM answers "process is closed")
  - fixtures avoid that path.
  - Pool threads are started with `SIGINT`, `SIGTERM` and `SIGHUP` blocked
    (`agc_io_start` blocks them around `uv_queue_work`)
  - keep that when adding new ways into the libuv pool.
  - Boehm's marker threads do not block them, so the stop handler may run on any
    thread: it only uses lock-free atomics and async-signal-safe calls.
  - The signal tests (`tests/test_vm_stop.py`, `tests/test_vm_diff_8.py`)
    signal the driver and the VM with `os.kill` and bound every wait.
  - Captured children (21a) are what `std/bdd` runs its scenario VMs with: never
    block the VM in their close (only the end-of-run cleanup may wait, bounded),
    and keep the `SIGTERM` first, since the child VM's exit path is what stops
    the programs it started.
  - `tests/test_vm_diff_8.py` checks that with a VM child that started `sleep`,
    closed by `Process.close` and by a `read_line` timeout: the grandchild's pid
    must be gone when the run ends.
  - A second case closes a child that ignores `SIGTERM` (close returns at once,
    the timer's `SIGKILL`, the end-of-run deadline) and one that dies on it
    right before `main` returns
  - each run must end with `end code=0 signal=0` in the `io` trace.
  - Golden fixtures with children keep their step counts independent of timing:
    wait for an event (`wait`, a read, `output`) before a call whose result
    depends on it.
- **TCP (7h; Linux, macOS, Windows)**: `vm/tcp.c`, `docs/vm/10-io-tls.md`
  §10.3.1 (its "Platforms" item has the host differences). An errno that
  reaches `agc_system_error` goes through `agc_net_errno` (`vm/net_os.h`),
  never a bare `-rc`: Windows libuv codes are not negated errno values. A
  listener link counts reported connections (`backlog`), since Windows
  reports several before the first `uv_accept`. `tests/test_vm_tcp.py` runs
  in the macOS and Windows jobs of `platforms.yml`; its expected `system
  error:` texts come from `system_error()`.
  TLS sockets and listeners are the same `net` with
  `secure` set (see TLS below).
  The `tcp-*` fixtures are their own peers (a listener and its client tasks
  in one program) and print only from `main` after its awaits, so output and
  step counts do not depend on timing; `recv_bytes` returns what has
  arrived, so a fixture reads bytes only after the writer is done (await it
  first). A connect timeout has no hermetic
  test (it needs an address that drops SYNs); it was checked by hand. A golden
  fixture that needs a write to stay parked sends one String far bigger than
  the loopback buffers (64 MiB), never a loop of sends: the number of sends
  that complete depends on the kernel's buffer sizes, and so would the step
  count. Windows takes even a 32 MiB send whole, so a pytest case (no step
  counts) that needs a send to time out loops sends, bounded, until one
  fails (`CLIENT_PROGRAM` in `tests/test_vm_tcp.py`).
- **TLS (7h; Linux, macOS, Windows)**
  - `TLS.connect` and `TLS.listen` in `vm/tcp.c` on the adapter of `vm/tls.h`
    (`docs/vm/10-io-tls.md` §10.3).
  - A secure `net` first loads its config in a pool job (`start_setup`), then
    resolves and connects or listens as for TCP.
  - The read callback feeds ciphertext to the session, runs the handshake, then
    decrypts into `agc_inbuf`, so line and byte reads, limits, locks and
    timeouts are the TCP ones.
  - Sends copy plaintext to a `malloc`'d buffer and encrypt it 16 KiB at a time,
    one `agc_stream_write` per piece.
  - Children in a handshake hang off their request (`handshakes` list), and
    closing the listener closes them. The accept timeout, `close_notify`, the
    message shapes and the EOF rule are in `docs/vm/10-io-tls.md` §10.3.
  - Keep TLS goldens few and small (`tls-echo` and `tls-errors`): every run of
    the `--max-steps` sweep does a handshake.
  - Put other TLS cases in `tests/test_vm_tls.py`, which runs each once, with
    short timeouts, small payloads and no sleeps. It runs in the macOS and
    Windows jobs of `platforms.yml`, HTTPS cases included; the waiters case
    blocks its CA file on a FIFO, or on Windows a named pipe (`BlockingFile`).
    Peers print LF on Windows too (`sys.stdout.reconfigure(newline="\n")`).
  - The `tls-*` fixtures take their certificate directory as `@fixtures/tls` in
    `.args` (`fixture_arg` in `tests/vm_diff_support.py` makes it absolute,
    since the tests and `make goldens` run from different directories).
  - Certificates come from `tests/fixtures/tls/make-certs.sh` (OpenSSL 3.4 or
    newer for the expired one).
- **HTTP client (20a; Linux, macOS, Windows)**: `stdlib/http.agc` on
  `vm/http_service.c`, `vm/http_wire.c` and the reads of `vm/tcp.c` (the
  std-only guard). The `http-client-service` and `test-client-no-leftover`
  fixtures hold the service task's rules. The `http-*` fixtures are their own
  peers (a TCP server task in the same program; only `main` prints); the
  std/http URL parser costs about 500 steps per call, so the sweep samples them.
  Put the other cases in `tests/test_vm_http.py`, which starts one Python peer
  per client case (`tests/fixtures/http-peer.py`: a `ThreadingHTTPServer`, the
  same over `ssl`, and a raw socket server with canned hostile responses) and
  runs three programs once. Python 3 (standard library only) is required in CI,
  as Node is for TCP: with `CI` set the test fails without it, locally it prints
  a skip. Bumping picohttpparser (`vm/third_party/picohttpparser`): check out
  the new tag inside it, `git add` it, and rerun `vm/tests/http_parse_test.c`,
  the HTTP goldens and `tests/test_vm_http.py`.
- **HTTP server (20c; Linux, macOS, Windows)**
  - `vm/http_server.c` on `vm/net.h`; `vm/http_wire.c` on the same parser and
    `vm/http_fields.c`.
  - The `http-server*` fixtures are their own peers (the `std/http` client, or a
    raw `TCP` client for bytes the client cannot send)
  - a side `TCP` listener tells `main` that a handler started, so
    `close_server`, slow-handler and `main`-returns cases do not depend on
    timing.
  - `tests/test_vm_http.py` starts a VM server program (plain and TLS, port 0,
    ports on its first line) and runs `tests/fixtures/http-server-peer.py`
    (every hostile request of §10.6 on a raw socket, the `Expect` cases,
    pipelining, `http.client`, the `max_connections` wait, TLS, and a pipelined
    flood during a stalled 8 MiB response that must stay bounded) and
    `tests/fixtures/http-server-peer.js` (Node `http`: chunked upload, `Expect`,
    keep-alive, `HEAD`, concurrent clients)
  - closing its stdin ends the server.
  - Node and Python are required in CI.
  - The module runs in the macOS and Windows jobs of `platforms.yml` too. Its
    Python peers print LF on Windows, and the flood case reads the VM's memory
    with `ps`, or on Windows with `GetProcessMemoryInfo` (ctypes).
  - A connection task is `hidden`: of its unobserved crashes only the first per
    test (or per run) stays in the crash list, the others count on it
    (`quiet_more`), so a long-running server does not grow the list
  - observed crashes leave the list.
  - Handlers cannot reach their own `HttpServer` (values are immutable and the
    handler is fixed before the server exists), so the self-close case is the C
    test of a task that cancels itself
  - `http-server-owner-crash` crashes the task that owns a server with a live
    connection (handed over with `Task.spawn_owning`), and
    `http-server-owner-cancel` cancels the task that owns one, which frees the
    port.
  - One worker task per connection, under a supervisor that awaits it as a
    `Result` task (a crash frees the slot and answers `http: connection
    failed`); its idle `Channel.recv` timeout is the idle timer. A worker whose
    caller gave up on the reply (`HttpWire.awaited?`: the channel's
    `abandoned` flag, set when a parked receiver leaves without a value)
    closes the connection instead of pooling it, and the owner drops such a
    waiting job.
  - A connection is kept only with nothing left after the response (the
    `buffered` and `ended` fields of `HttpWire.Response` and `HttpWire.Text`,
    and a 0-byte `read_text` after a chunked body).
  - An idempotent call that fails on a reused connection before any response
    byte is retried once on a new one (`run_job`).
  - A close-delimited body over TLS needs `close_notify`
    (`HttpWire.clean_eof?`)
  - a bare FIN gives "truncated HTTP body".

Native process regression tests (`vm/tests/process_test.c`) use their own C
executable as the child. Windows channel pairs have random names, one local
instance and a protected owner-only DACL.
