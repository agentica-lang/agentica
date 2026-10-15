# VM processes, child channel, TCP, TLS and HTTP

Read before touching processes, the child channel, sockets, OpenSSL or HTTP in `vm/`.

Read first: `references/vm.md` and `references/vm-c.md`.

## Files

| Path | Owns |
|---|---|
| `vm/duplex.c` | The child channel (fd 3) and the duplex stream of `Process.spawn_channel` (Linux only). |
| `vm/process.c` | The `Process` builtins and `System.env`, behind `--allow-run` (Linux only). |
| `vm/stream.c` | what processes and TCP share (`docs/vm/10-io-tls.md` §10.3.1): `agc_inbuf` (one `malloc`'d input buffer with EOF and a sticky read error; `agc_inbuf_room` for libuv's alloc callback, `agc_inbuf_got` for its read callback, `agc_inbuf_ready`, `agc_inbuf_want` for the read size: 4 KiB or what a byte read still needs), `agc_inbuf_take` (drop the first bytes of the pending data and keep `scanned` right), `agc_inbuf_line` (LF in the first 1 MiB + 1 bytes, searched once per byte through `scanned`, CRLF stripped, a final line only at EOF, the read error when bytes without LF end in an error, the caller's texts for too long and end of input; it says when the line was too long so the caller closes) and `agc_inbuf_bytes`, `agc_stream_write` (`uv_try_write`, then one `uv_write` of a `malloc`'d copy in buffers of at most 1 GiB; 0 written, 1 queued, or a libuv error), `agc_new_lock` and `agc_stream_lock` (an unregistered lock record, and the timeout check plus `agc_handle_wait`), and the `network:` timeout texts |
| `vm/tcp.c` | the `TCP` and `TLS` builtins (`agc_tcp_builtins`, Linux only; §10.3.1, TLS in §10.3): one `malloc`'d `net` for a socket or a listener (users: the resource and each request; callbacks: a DNS lookup in flight and one close callback per `tcp_link`, a `malloc`'d `uv_tcp_t` with its `uv_connect_t` that finds the `net` through `owner`), registered when the call starts, so a crash or the in-process harnesses' `agc_io_close` closes it; the VM's own end of the run closes no socket one by one (`_exit` does), and only calls the `goodbye` hook for TLS `close_notify`; requests park on `external` jobs (`park`): connect resolves with `uv_getaddrinfo` and tries each address with a fresh link (`attempt` takes its callback as an argument, so no prototype is needed), listen binds every resolved address on one port (one link per address, chained through `next`; `bind_all` retries a port-0 listen when a later address finds the port taken), accept is one FIFO for all links whose head is marked served by a link's connection callback (`chosen`) and calls `uv_accept` in its `done` half (a failed `uv_accept` closes the listener, since libuv stops watching that link), reads and writes use the `agc_socket` reader and writer locks and `vm/stream.c`; `shut` is the one close (trace `why`), and wakes every waiting request; `no_files` (the fuzzer) makes connect and listen fail with `RUNTIME-INTERNAL` |
| `vm/net.h` | tcp.c's connection object for other C modules (`agc_conn`, `docs/vm/10-io-http.md` §10.7.1): `agc_conn_open` (DNS, connect, TLS with a borrowed `agc_tls_config`) with a watch callback that runs on every state change, `agc_conn_send`/`agc_conn_sent`, `agc_conn_input`/`agc_conn_read` (the `agc_inbuf`), `agc_conn_ready`/`agc_conn_failed`/`agc_conn_error`, `agc_conn_shut` and `agc_conn_release`; also `agc_tls_load_error` |
| `vm/http_parse.h`, `vm/http_pico.c`, `vm/http_body.c` | the HTTP head adapter and body decoder (§10.6, §10.6.1): limits as constants, `agc_http_error` with its status and text, `agc_http_parse_request_head`/`_response_head` (our pre-scan and start-line checks, then picohttpparser, then token, value, obs-fold, Host and status checks), `agc_http_framing`, and the body decoder (`agc_http_body_init/feed/end/free`: Content-Length, chunked with saturating sizes and checked trailers, close-delimited, one `malloc`'d buffer within the limit). No recursion |
| `vm/http_fields.h`, `vm/http_fields.c` | what the client and the server share (`agc_http_closes` on a parsed head and `agc_http_list_closes` on a `List[Header]` use one token check): a growable byte buffer (`agc_http_put`), the header writer with its checks and the managed names (`agc_http_put_headers`, which returns a reason without the `http: ` prefix), the kept header fields (`agc_http_fields`, names lowercased) and their `List[Header]` (`agc_http_header_list`), `agc_http_closes` and `agc_http_error_result` |
| `vm/http_server.c` | The `HttpWire` server builtins: request reading, response writing and the server task group (Linux only). |
| `vm/http_client.c` | `HttpWire.client`, `exchange` and `close_client` (`agc_http_builtins`, Linux only, a stub table elsewhere; §10.7.1): a `malloc`'d `client` per handle with its origins (idle connections, open slots, a FIFO of waiting exchanges), one idle timer and a lazily built `agc_tls_config` (a pool job on the first HTTPS call); each `exchange` parks on an `external` job and moves through config, wait, connect and exchange phases on `agc_conn` watches; a `runnable` queue (`schedule`/`drain`) and callbacks stored in the client avoid both static prototypes and call cycles. GC values (the `HttpResponse`) are built only in `done`. Its `cancel` half (20b): an exchange of a cancelled task that has not sent its request leaves the queue or closes its connection, so its slot passes to the next waiter; one that has sent it runs to its end and is not pooled. Its `goodbye` (`client_goodbye`) sends one TLS close_notify on every idle and active connection when the run ends |
| `vm/tls.h`, `vm/tls_openssl.c` | the TLS adapter (`docs/vm/10-io-tls.md` §10.3): our own types (`agc_tls_config`, `agc_tls`, status OK, WANT_READ, WANT_WRITE, CLOSED or ERROR, `agc_tls_error`, `agc_tls_failure` with code, `errno` and a short detail); `vm/tls_openssl.c` is the only file that includes OpenSSL: init with `OPENSSL_INIT_NO_LOAD_CONFIG \| OPENSSL_INIT_NO_ATEXIT`, TLS 1.2 and security level 2, trust (`SSL_CERT_FILE` or the first readable bundle of a fixed list, `SSL_CERT_DIR` or none; a non-empty `ca_file` replaces them), SNI and `SSL_set1_host` or `X509_VERIFY_PARAM_set1_ip_asc`, two memory BIOs per session, error-queue draining into our codes; stubs that fail with "TLS needs Linux" elsewhere |

- `vm/duplex.c`
  - the child channel (25c, service; `docs/vm/10-io-processes.md` §10.4 "As
    built (25c)"; Linux only, stubs elsewhere): an `agc_duplex` is one
    bidirectional libuv pipe over a socket end with an `agc_inbuf` (line reads,
    1 MiB), at most one reader request and one writer request, a reference count
    (the owner, each request, the pipe handle and the shutdown request) the
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
  - The parent side is used by `process.c` (`agc_duplex_new` over the parent's
    socket end, `agc_duplex_read_line`, `agc_duplex_send`,
    `agc_duplex_close_write`, which ignores a `uv_shutdown` that fails on the
    spot (`ENOTCONN` when the peer is gone), `agc_duplex_overflow`,
    `agc_duplex_release`)
  - the child side is `agc_parent_take` (called by `main.c` after
    `agc_files_init`: takes fd 3 only with `AGENTICA_CHANNEL=3`, a socket or a
    FIFO opened `O_RDWR` (`F_GETFL`; a one-way FIFO would fail the read start
    and park `Test.run` for ever), moves it with `F_DUPFD_CLOEXEC`, forgets it
    in the inherited-file table, removes the variable, registers the duplex as
    `vm->parent`; the libuv handle is attached on first use), the builtins
    `Process.parent_read_line` and `Process.parent_send` (a positive timeout,
    the `vm->parent_locks` pair; `error("process: no parent channel")` without a
    channel; `process: the channel is in use` only when a request in that
    direction is already pending, which keeps a test's call from sharing a
    buffer with `Test.run`'s retry-style request) and the functions `Test.run`
    uses (`agc_parent_open`, true when the channel exists and is not closed, and
    `agc_parent_line` and `agc_parent_send`, which park the calling task with
    `task->retry`, without a timeout)
- `vm/process.c`
  - the `Process` builtins and `System.env` (`agc_process_builtins`, Linux only;
    `docs/vm/10-io-processes.md` §10.4): `System.env` (`builtin_env`) scans
    `host_env()` (the one block-scope `extern char **environ`) for the first
    `name=` entry and decodes the value with U+FFFD per bad byte
  - a name that is empty, or has `=` or NUL, and an unset name are error Results
  - `own_env` says which entries the VM keeps for itself (`AGENTICA_CHANNEL`,
    and `UV_USE_IO_URING` when `drop_uring_env`), and both `builtin_env` and
    `child_env` skip them
  - no flag and no `no_files` check, since
    `File.read_text("/proc/self/environ")` already reads the same data
  - a GC `agc_process` with the registered `state` resource and two unregistered
    lock records (`reader`, `writer`) for `agc_handle_wait`
  - a `malloc`'d `proc` with the `uv_process_t`, three `uv_pipe_t` (real pipes
    from `uv_pipe` given with `UV_INHERIT_FD`), the stdout buffer and the
    pending requests, freed when its user count (resource and requests) and
    handle count (close callbacks) reach zero
  - requests park on `external` jobs that pipe, write and exit callbacks ready
    with `agc_io_ready`
  - stdout is read only while a reader waits, 4 KiB at a time (more only for a
    bigger `read_bytes`)
  - stderr is forwarded in its read callback
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
    capacity (near the limit a chunk goes to the scratch buffer and
    `keep_scratch` copies what fits; `out_cut`, `err_cut`, then dropped into the
    scratch buffer), `output` a wait like `wait` (`await_child`), and a close
    that sends `SIGTERM` and starts the 1 s `grace` timer for `SIGKILL`
    (`retire` closes the timer and the process handle once the child is gone)
  - the end of the run waits for captured children under one `await_exits` bound
    before it kills them (a second bound waits for the exits)
  - the child channel (25c, §10.4 "As built (25c)"): `Process.spawn_channel` is
    `spawn_child` with `channel` true: a `uv_socketpair`, a fourth stdio slot
    that hands the child end over as fd 3, and `child_env`, which rebuilds the
    child environment on every spawn (it removes `AGENTICA_CHANNEL`, removes
    `UV_USE_IO_URING` when `drop_uring_env`, and adds `AGENTICA_CHANNEL=3` for a
    channel spawn only, as a separate `marker` string the caller frees;
    `AGC_CHANNEL_ENV` and `AGC_CHANNEL_FD` are in `vm/services.h`)
  - the parent end is an `agc_duplex` (`vm/duplex.c`) in `proc.channel`, and the
    `agc_process` has a third pair of lock records, `channel.reader` and
    `channel.writer`
  - `channel_read_line`, `channel_send` and `channel_close` call the duplex
    functions with those locks, `shut` closes the channel with the pipes, and
    `read_available` drains the stdout pipe with non-blocking `read`s
    (`drain_out`, at most `DRAIN_LIMIT` = 2 MiB per call, into `out_buf` through
    the same cut rules) before it consumes the pending bytes, holding back an
    incomplete UTF-8 sequence at the end (`whole_prefix`, up to 3 bytes) unless
    the stream ended or failed, and takes them out with `agc_inbuf_take`
  - the trace line of a spawn has `channel=`
- `vm/http_server.c`
  - `HttpWire.read_request`, `write_response`, `server`, `accept`, `spawn`,
    `close_server`, `wait` and `local_port` (`agc_http_server_builtins`, Linux
    only, a stub table elsewhere; §10.7): a `reader` state machine on an
    `agc_conn` watch (first byte, head, body, answer) that applies the order of
    `docs/vm/10-io-http.md` §10.7.3 (parse errors, `Upgrade` 501, `Expect` 417,
    the `Content-Length` limit 413, then `100 Continue`, then the body and its
    UTF-8 check), writes every error answer itself, then lingers (`linger`:
    half-close and drop input until the peer closes or the deadline, so no reset
    loses the answer)
  - the deadline is `first_byte_timeout_ms` until the first byte, then
    `agc_io_extend` restarts it with `timeout_ms`
  - a finished request pauses reading (`agc_conn_pause`) until the next
    `read_request`, so pipelined bytes cannot pile up while a response is
    written.
  - `write_response` takes the request and the response, builds the whole
    response first (status 200..599, no body on 204 and 304 or for `HEAD`,
    `Content-Length` and `Transfer-Encoding` managed, a `Date` header; when the
    request or response says `Connection: close` (`agc_http_list_closes`), the
    handler's `Connection` headers are dropped for one `Connection: close`),
    returns `http: invalid response: ...` without writing when it is bad, else
    `ok(keep)`, and lingers before a close.
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
  - The default `system` links the system OpenSSL dynamically with `pkg-config
    --cflags --libs openssl`
  - the stamp `$(VM_BUILD)/openssl-system` (the first prerequisite of every VM
    binary and `vm-lint`, order-only for every VM object, so it runs before any
    `vm/*.c` compile) fails with a clear message when `pkg-config` or the
    package is missing or older than `OSSL_MIN` (3.0.0: the code uses 3.0 APIs
    such as `SSL_CTX_load_verify_file` and `OPENSSL_VERSION_STRING`), and
    `vm/tls_openssl.c` has an `#error` for older versions and LibreSSL.
  - The mode is not remembered: pass `AGENTICA_OPENSSL=vendored` to every make
    command or export it.
  - `vendored` (only the release) builds the submodule static per build mode:
    out-of-tree `Configure` in `$(VM_BUILD)/openssl/` with `OSSL_OPTS`
    (`no-shared no-tests no-docs no-apps no-module ... no-deprecated`) and the
    mode's `OSSL_CFLAGS` (release hardening, `-g` for GC stress, clang `-g
    -fno-omit-frame-pointer` without `-fsanitize` for the sanitizer build: a
    non-instrumented OpenSSL; ASan's interceptors still check the buffers we
    hand it), output in `configure.log` and `build.log`
  - both commands run under `env -u` for the make and compiler variables, and
    the sub-make is a plain `make` (never `$(MAKE)`, so `make -n` skips it).
  - `$(VM_BUILD)/openssl-flags` is the key of the vendored build only (`make -s
    vm-openssl-key AGENTICA_OPENSSL=vendored`, which refuses the system mode:
    the two command lines, compiler version, OpenSSL version and commit),
    rewritten only when it changes, and the archives depend only on it, so
    `TRACE` and VM flag changes never rebuild OpenSSL and a restored CI cache is
    up to date
  - after editing OpenSSL sources by hand, remove `$(VM_BUILD)/openssl`.
  - Init with `OPENSSL_INIT_NO_LOAD_CONFIG | OPENSSL_INIT_NO_ATEXIT`
  - TLS 1.2 and security level 2 as minimums
  - trust: `SSL_CERT_FILE` or else the first readable distro bundle, and
    `SSL_CERT_DIR` or else no directory (a failing system source is skipped)
  - a non-empty `ca_file` replaces system trust and must load.
  - SNI plus `SSL_set1_host` per connection, `X509_VERIFY_PARAM_set1_ip_asc` (no
    SNI) for IP literals
  - no `SSL_VERIFY_NONE` path.
  - Never hand OpenSSL a GC pointer, and keep file loading off the scheduler
    thread (the config loads in a libuv pool job).
  - The release (`zig cc`, glibc 2.28) sets `AGENTICA_OPENSSL=vendored` and
    `AGENTICA_GC=vendored`
  - `readelf -d` must show no `libssl`, `libcrypto` or `libgc`, and `--version`
    must name the submodule's version.
  - `--version` prints the OpenSSL that runs (`OpenSSL_version`), so a system
    build shows the distro's version.
  - `build/vm/flags` records the mode, so switching it relinks.
  - Bumping: fetch the new 3.5.x tag in the submodule, commit it, rebuild with
    `AGENTICA_OPENSSL=vendored`, rerun the TLS, sanitizer and golden tests.
- **HTTP (7h)**
  - parity is black-box.
  - Well-formed messages: same status, headers, body and `Result` ok or error.
  - Malformed input: both reject (server error status and close, client error
    `Result`)
  - the code may differ except 413, 431 (also trailers), 505 (requests; a bad
    response version is a client error `Result`) and 501 (`CONNECT`, and any
    `Transfer-Encoding` but one `chunked`).
  - Equal duplicate `Content-Length` is accepted
  - conflicting values give 400
  - `Content-Length` with any `Transfer-Encoding` is 400 first.
  - No copying of evaluator quirks or its order of failing lines
  - picohttpparser's leniencies are documented differences
  - framing stays strict. picohttpparser (submodule
    `vm/third_party/picohttpparser`, MIT or Perl, tag v1.4, built at the
    baseline without `-msse4.2`) parses and validates start lines and headers,
    behind `vm/http_parse.h` (our head struct with byte slices,
    `agc_http_parse_request_head`/`agc_http_parse_response_head` returning OK
    with bytes consumed, INCOMPLETE or ERROR with our error enum).
  - Only `vm/http_pico.c` includes `picohttpparser.h`.
  - It is called without `last_len` and only when new bytes complete a line
    (head at most the 8192-byte start line plus 64 KiB of headers)
  - a -1 is 400 or a client error `Result`.
  - A pre-scan checks size limits (431), bare LF and the header count (431 past
    100, before pico runs), skipping one leading CRLF before a request.
  - The pre-scan stops at the end of the start line
  - the start-line check (431 for its length, then 505 or 400) runs before the
    pre-scan looks at any header line.
  - Before pico, the adapter checks a complete start line with the evaluator's
    shape: `HTTP/[0-9.]+` other than exactly `1.1` gives 505 (`GET / HTTP/1`
    too), other bad shapes 400, so it fails at once.
  - On pico's output: target (origin form or `*` with `OPTIONS`, bytes 33–126),
    method token, `CONNECT` 501, obs-fold (`name == NULL`), response version,
    status 100–599, no 101, 15 interim responses accepted and the 16th fails,
    `Host`, framing and smuggling.
  - The body goes through our incremental decoder `vm/http_body.c` (`feed`
    returns bytes consumed, body slices, and NEED_MORE, DONE or ERROR: 413 over
    the limit, 431 for an over-long chunk-size or trailer line or trailers over
    their limits, 400 otherwise; trailers checked with the header rules; no
    `phr_decode_chunked`), so bodies stream and are never buffered whole.
  - Tests target the adapter and check rejections and the codes that must match,
    not messages (`docs/vm/10-io-http.md` 10.6).
- **Processes (7h, in on Linux)**
  - `vm/process.c`, `docs/vm/10-io-processes.md` §10.4.
  - The VM resolves the executable itself (`PATH` only for a bare name, never
    the working directory) and passes the absolute path to `uv_spawn`
  - never verbatim arguments
  - all three stdio piped
  - `UV_USE_IO_URING` is dropped from the child's environment only when the VM
    set it.
  - A Windows port must allow only `.exe`/`.com`, case-insensitive, and must not
    search the current directory.
  - The evaluator keeps a direction's lock after a stream timeout (a legacy bug;
    the VM answers "process is closed")
  - fixtures avoid that path.
  - Pool threads are started with `SIGINT`, `SIGTERM` and `SIGHUP` blocked
    (`agc_io_start` blocks them around `uv_queue_work`)
  - keep that when adding new ways into the libuv pool.
  - Boehm's marker threads do not block them, so the stop handler may run on any
    thread: it only uses lock-free atomics and async-signal-safe calls.
  - The signal tests in `tests/vm-stop-test.rkt` (with
    `tests/fixtures/stop-peer.py`: a FIFO filled so a flush cannot end, a dying
    driver, an inherited pipe) and `tests/vm-diff-common.rkt` signal the driver
    and the VM with libc `kill` through the FFI and bound every wait.
  - Captured children (21a) are what `std/bdd` runs its scenario VMs with: never
    block the VM in their close (only the end-of-run cleanup may wait, bounded),
    and keep the `SIGTERM` first, since the child VM's exit path is what stops
    the programs it started.
  - `tests/vm-diff-common.rkt` checks that with a VM child that started `sleep`,
    closed by `Process.close` and by a `read_line` timeout: the grandchild's pid
    must be gone when the run ends.
  - A second case closes a child that ignores `SIGTERM` (close returns at once,
    the timer's `SIGKILL`, the end-of-run deadline) and one that dies on it
    right before `main` returns
  - each run must end with `end code=0 signal=0` in the `io` trace.
  - Golden fixtures with children keep their step counts independent of timing:
    wait for an event (`wait`, a read, `output`) before a call whose result
    depends on it.
- **TCP (7h, in on Linux)**: `vm/tcp.c`, `docs/vm/10-io-tls.md`
  §10.3.1. TLS sockets and listeners are the same `net` with
  `secure` set (see TLS below).
  The `tcp-*` fixtures are their own peers (a listener and its client tasks
  in one program) and print only from `main` after its awaits, so output and
  step counts do not depend on timing; `recv_bytes` returns what has
  arrived, so a fixture reads bytes only after the writer is done (await it
  first). Network tests bind 127.0.0.1 port 0 and use Node peers; no name
  that needs DNS beyond `/etc/hosts`. A connect timeout has no hermetic test
  (it needs an address that drops SYNs); it was checked by hand. A fixture
  that needs a write to stay parked sends one String far bigger than the
  loopback buffers (64 MiB), never a loop of sends: the number of sends
  that complete depends on the kernel's buffer sizes, and so would the
  step count.
- **TLS (7h, in on Linux)**
  - `TLS.connect` and `TLS.listen` in `vm/tcp.c` on the adapter of `vm/tls.h`
    (`docs/vm/10-io-tls.md` §10.3).
  - A secure `net` first loads its config in a pool job (`start_setup`), then
    resolves and connects or listens as for TCP.
  - The read callback feeds ciphertext to the session, runs the handshake, then
    decrypts into `agc_inbuf`, so line and byte reads, limits, locks and
    timeouts are the TCP ones.
  - Sends copy plaintext to a `malloc`'d buffer and encrypt it 16 KiB at a time,
    one `agc_stream_write` per piece.
  - On a TLS listener a waiting accept takes the connection at once and
    handshakes it under the accept's timeout
  - children in a handshake hang off their request (`handshakes` list), and
    closing the listener closes them.
  - Closing sends `close_notify` with one `uv_try_write`.
  - Messages keep Racket's shapes (`ssl-connect: connect failed (...)`,
    `port->ssl-ports: accept failed (...)`, `ssl-load-...: load failed from:
    "path" (...)`)
  - only the `Result` kind must match the evaluator.
  - A peer that closes without `close_notify` is EOF
    (`SSL_OP_IGNORE_UNEXPECTED_EOF`), as in Racket.
  - `tls` trace points: handshake, handshake_done, handshake_error, setup_error,
    read_error, close.
  - Keep TLS goldens few and small (now `tls-echo` and `tls-errors`, about 60
    steps each): every run of the `--max-steps` sweep does a handshake.
  - Put other TLS cases in `tests/vm-tls-test.rkt`, which runs each once, with
    short timeouts, small payloads and no sleeps.
  - The `tls-*` fixtures take their certificate directory as `@fixtures/tls` in
    `.args` (`fixture-arg` in `tests/vm-diff-common.rkt` makes it absolute,
    since `raco test` and `make goldens` run from different directories).
  - Certificates come from `tests/fixtures/tls/make-certs.sh` (OpenSSL 3.4 or
    newer for the expired one).
- **HTTP client (20a, in on Linux)**: `vm/http_client.c` on `vm/net.h`
  and the parser of `vm/http_parse.h`, called only by `stdlib/http.agc`
  (the std-only guard). The `http-*` fixtures are their own peers (a TCP
  server task in the same program; only `main` prints); the std/http URL
  parser costs about 500 steps per call, so the sweep samples them. Put the
  other cases in `tests/vm-http-test.rkt`, which starts one Python peer
  (`tests/fixtures/http-peer.py`: a `ThreadingHTTPServer`, the same over `ssl`, and a raw socket server with
  canned hostile responses) and runs three programs once. Python 3
  (standard library only) is required in CI, as Node is for TCP: with `CI`
  set the test fails without it, locally it prints a skip. picohttpparser
  is the submodule `vm/third_party/picohttpparser` (v1.4); bumping it: check
  out the new tag inside it, `git add` it, and rerun
  `vm/tests/http_parse_test.c`, the HTTP goldens and `tests/vm-http-test.rkt`.
- **HTTP server (20c, in on Linux)**
  - `vm/http_server.c` on `vm/net.h`, the same parser and `vm/http_fields.c`.
  - The `http-server*` fixtures are their own peers (the `std/http` client, or a
    raw `TCP` client for bytes the client cannot send)
  - a side `TCP` listener tells `main` that a handler started, so
    `close_server`, slow-handler and `main`-returns cases do not depend on
    timing.
  - `tests/vm-http-test.rkt` starts a VM server program (plain and TLS, port 0,
    ports on its first line) and runs `tests/fixtures/http-server-peer.py`
    (every hostile request of §10.6 on a raw socket, the `Expect` cases,
    pipelining, `http.client`, the `max_connections` wait, TLS, and a pipelined
    flood during a stalled 8 MiB response that must stay bounded) and
    `tests/fixtures/http-server-peer.js` (Node `http`: chunked upload, `Expect`,
    keep-alive, `HEAD`, concurrent clients)
  - closing its stdin ends the server.
  - Node and Python are required in CI.
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
  - The client gets its connection from tcp.c through `agc_conn`, never its own
    socket code.
  - Idle pooled connections and the idle timer are unreferenced
    (`agc_conn_hold`), so they never keep a stalled run alive
  - a connection freed while calls wait is parked first and handed over by a 1
    ms referenced timer (a narrow guard against late bytes, not a full one).
  - An idempotent call that fails on a reused connection before any response
    byte is retried once on a new one (`retry`).
  - A close-delimited body over TLS needs `close_notify` (`agc_conn_clean_eof`)
  - a bare FIN gives "truncated HTTP body".
