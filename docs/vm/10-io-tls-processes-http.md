### 10.3 TLS

- OpenSSL 3, which Racket's `openssl` module also uses. The default
  dynamic build initializes without `OPENSSL_INIT_NO_LOAD_CONFIG`, so
  OpenSSL loads the system `openssl.cnf` as it does for Racket, and the
  distro's hardening applies. The `OPENSSL=static` build initializes with
  `OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL)`, since its
  configuration path points at the build machine, and sets explicit
  minimums (TLS 1.2, security level 2); this is a documented difference of
  the static build.
- With an empty `ca_file`, use system trust like
  `ssl-secure-client-context`, matching Racket: the CA file and the CA
  directory are two sources, and each is replaced on its own. On Linux the
  default dynamic build loads exactly Racket's sources: the file is
  `SSL_CERT_FILE` or else `X509_get_default_cert_file()`, the directory is
  `SSL_CERT_DIR` or else `X509_get_default_cert_dir()` (both under
  `OPENSSLDIR`), loaded with `SSL_CTX_load_verify_file` and
  `SSL_CTX_load_verify_dir` (3.0 API; no store URI). The `OPENSSL=static` build (10.0) cannot use its built-in
  paths, which point at the build machine: the file is `SSL_CERT_FILE` or
  else the first existing file of a list of distro bundles
  (`/etc/ssl/certs/ca-certificates.crt`,
  `/etc/pki/tls/certs/ca-bundle.crt`, ...), and the directory is
  `SSL_CERT_DIR` or else none. Racket probes such paths only for its
  natipkg OpenSSL build (`RACKET_USE_ALT_PATH`). The static build has two
  documented differences: this CA-bundle probing, and its own TLS
  minimums without `openssl.cnf` (above). On a normal host the
  evaluator and the dynamic VM both use OpenSSL's defaults. On Windows only
  the `ROOT` store, on macOS only the Keychain anchors, never
  OpenSSL's default paths. A non-empty `ca_file` replaces system trust.
  Trust-store usage and disallowed lists are honored only as far as Racket
  honors them.
- Per connection: `SSL_set1_host`, SNI set, IP literals through
  `X509_VERIFY_PARAM_set1_ip_asc`. There is no `SSL_VERIFY_NONE` path.
- Hermetic tests: wrong hostname, self-signed server without `ca_file`, and a
  `ca_file` that excludes system roots.

### 10.3.1 TCP (as built)

**As built (TCP PR, Linux).** `vm/tcp.c` holds the ten `TCP` builtins.
`vm/stream.c` holds the parts it shares with `vm/process.c`: the input
buffer (`agc_inbuf`) with its line and byte takes, the write path
(`uv_try_write`, then one `uv_write` of a `malloc`'d copy), the
lock-or-timeout helper and the `network:` timeout texts. Other systems get
an empty table, so the lowerer's keys fail at load as unknown imports.
`TLS` stays on the evaluator fallback, and a TLS socket never reaches the
VM: a program that calls a `TLS` builtin falls back as a whole.

- **Values.** A `Socket` (`AGC_T_SOCKET`, printed `<Socket>`) is a GC
  `agc_socket` with the registered `state` resource and two lock records,
  `reader` and `writer`, as for `Process` (10.4): `read_line` and
  `recv_bytes` take the reader lock, `send` and `send_bytes` the writer
  lock, through `agc_handle_wait`, so one deadline covers the lock wait
  and the operation. A `Listener` (`AGC_T_LISTENER`, `<Listener>`) is a GC
  `agc_listener` with its `state` resource and the bound port, so
  `TCP.local_port` still answers after `close_listener`, as in the
  evaluator.
- **State.** One `malloc`'d `net` serves sockets and listeners: the
  `uv_getaddrinfo_t`, the `uv_write_t`, its links (`tcp_link`, a `malloc`'d
  `uv_tcp_t` with its `uv_connect_t`; callbacks find the `net` through
  it; a socket has one, a listener one per bound address), the address
  list, the input buffer and the pending requests (the
  opener, one reader, one writer, and a FIFO of accepts). It is freed when
  its users (the resource and each request) and its callbacks (a DNS
  lookup in flight, one close callback per link) reach zero, so no
  callback sees freed memory. The resource is registered when the call
  starts, before any libuv work, so the end of the run always finds every
  handle. Every operation parks only its task on an external job (10.2.2)
  that a libuv callback readies.
- **Connect.** Checks the timeout, then the port (1..65535) and that the
  host has no NUL, then resolves with `uv_getaddrinfo` (`AF_UNSPEC`,
  `SOCK_STREAM`) and tries each address in order with `uv_tcp_connect`, a
  fresh link per try, until one connects; the error of the last try is
  returned. One timer covers the lookup and every try. When it fires, the
  lookup is cancelled if it has not started, the link is closed (the
  connect callback then sees `ECANCELED`), and the call returns
  "network: operation timed out". `TCP_NODELAY` is set on every connected
  and accepted socket.
- **Listen.** Checks the port (0..65535) and the host, resolves with
  `AI_PASSIVE`, then listens on every address, as `grammar.md` and
  Racket's `tcp-listen` do (backlog 128; libuv sets `SO_REUSEADDR`, as
  `reuse? #t`). The first address that binds fixes the port (read with
  `uv_tcp_getsockname` when the program asked for port 0); every other
  address binds to that same port. Duplicate addresses are skipped, and
  so are addresses that fail with `EADDRNOTAVAIL` or `EAFNOSUPPORT` (an
  IPv6 address on a host without IPv6). Any other failure closes every
  handle and fails the listen; when the program asked for port 0 and a
  later address finds the chosen port in use, the VM starts again with a
  new port, up to 8 times. With more than one address, IPv6 handles are
  `IPV6_V6ONLY`, so `::` and `0.0.0.0` can share a port. It has no
  timeout, as in `grammar.md`. The `io` trace event `tcp_listen` names
  the port and the number of bound addresses.
- **Accept.** "listener is closed" is checked first, then the timeout, as
  in the evaluator. Waiting accepts form one FIFO for all of the
  listener's handles. On each handle libuv accepts one connection from
  the kernel into its own slot and calls the connection callback; the
  head waiter is marked served for that handle and woken, and its `done`
  half calls `uv_accept` on the interpreter thread, so a connection never
  waits without an owner, then serves the next waiter if another handle
  holds a connection. While no task waits, libuv keeps that one
  connection per handle and stops watching it. When `uv_accept` fails,
  libuv no longer watches that handle, so the VM closes the listener:
  that accept returns the error and every other waiting accept returns
  "network: listener is closed". An accept error that libuv reports
  through the connection callback goes to the head waiter; when no task
  is waiting in `TCP.accept`, it is traced (`tcp_accept_error`) and
  dropped. A timed-out accept leaves the listener open.
- **Reads.** `recv_bytes` checks 1..1048576 first; then, as for
  `read_line`: the timeout, the reader lock, and that the socket is open.
  The socket is read only while a reader waits (`uv_read_start`, then
  `uv_read_stop` once the request can be answered), 4 KiB at a time, or
  what `recv_bytes` asks for when that is more, so the VM reads at most
  about 4 KiB past what the program asked for, like the evaluator's port
  buffer. `recv_bytes` returns what is buffered, up to its count, as soon
  as there is one byte, and `ok([])` at EOF. `read_line` looks for LF in
  the first 1 MiB + 1 bytes (it remembers how far it has looked, so each
  new chunk is searched once), strips LF or CRLF, returns a final line
  without a terminator at EOF (a lone CR stays) and "network: end of
  input" on an empty EOF. A read error ends a line too: bytes without LF
  followed by a reset return the read error, not a line. A line over 1
  MiB returns "network: line exceeds 1048576 bytes" and closes the
  socket. Invalid UTF-8 returns the
  `bytes->string/utf-8` error and the line is consumed. A read error
  (`ECONNRESET`) returns "error reading from stream port" with the OS
  text, and later reads return it too. `recv_bytes` still returns bytes
  that arrived before the error.
- **Writes.** `send` writes the UTF-8 bytes of its String with no size
  limit, as `grammar.md` says; `send_bytes` checks byte values and the 1
  MiB limit first. Then the timeout, the writer lock and the open check,
  then `uv_try_write`; what is left is copied and sent with one
  `uv_write` (buffers of at most 1 GiB each), and the task parks until
  its callback. `ok()` means every byte reached the kernel's send buffer:
  that is the flush. A failed write (`EPIPE`, `ECONNRESET`) returns
  "error writing to stream port" with the OS text and leaves the socket
  open.
- **Turn costs.** `send`, `send_bytes`, `recv_bytes` and `read_line`
  charge a turn cost by size (`AGC_COST_SIZE`, 10.2.1): the String or
  list they write, and the String or list they return. When the call
  parks, the `done` half charges it, so a call that waits costs the same
  as one that does not. `Process.send`, `send_bytes`, `read_line` and
  `read_bytes` follow the same rule.
- **Timeouts.** A timed-out read or write closes the socket, as
  `grammar.md` says; waiting for the lock alone does not. A timed-out
  connect closes the half-open socket. A timed-out accept leaves the
  listener open.
- **Close.** `TCP.close` and `TCP.close_listener` are idempotent: they
  unregister the resource, close the link (`uv_close`: a pending write
  ends with `ECANCELED`, a pending connect is cancelled), cancel a lookup
  that has not started, free the input buffer and wake every waiting
  request, which returns "network: socket is closed" or "network:
  listener is closed". As with Racket, data the program never read makes
  the kernel answer with RST instead of FIN.
- **End of run.** Sockets and listeners are registered resources, so
  `agc_io_close` closes them all, also while reads, writes, accepts and
  connects are parked (`main` returned, `System.exit`, a runtime error,
  the step limit); the loop then closes cleanly (`io close resources=0
  settled=1`). A DNS lookup already running in the pool cannot be
  cancelled; then the loop stays busy and the VM ends with `_exit`
  (10.2.2).
- **Fuzzing.** Under `no_files` (the fuzzer), `TCP.connect` and
  `TCP.listen` end the run with `RUNTIME-INTERNAL`, so a mutant never
  touches the network. The other TCP builtins need a handle from these
  two.
- **Messages.** The VM's own texts start with `network:` (timeouts,
  closed socket or listener, end of input, the line limit, the read
  size, byte values, `port must be 1..65535` for connect and `0..65535`
  for listen, `host cannot contain NUL`). Connect and listen failures
  keep Racket's shape: `tcp-connect: connection failed` or `tcp-connect:
  host not found` (and `tcp-listen: listen failed` or `tcp-listen: host
  not found`), then `hostname:` and `port number:` lines and the system
  error (`errno=N` for OS errors, libuv's text for resolver errors).
- **Black-box differences** (no parity is required; these are the places
  where `grammar.md` is silent and the VM does not copy the evaluator):
  - After a timed-out read or write closes a socket, the next call
    returns "network: socket is closed" at once, as `grammar.md` now
    says. The evaluator's timed-out thread keeps that direction's lock,
    so its next call waits its whole timeout (the legacy bug of 10.4);
    `grammar.md` keeps that as a temporary exception for TLS sockets.
  - A `read_line` over 1 MiB closes the socket, as `grammar.md` now
    says. The evaluator drops the 1 MiB + 1 bytes it read and leaves the
    stream in the middle of the line, so its next `read_line` returns the
    tail of the long line as if it were a whole line; `grammar.md` keeps
    that as a temporary exception for TLS sockets until TLS moves to the
    VM.
  - A host with a NUL byte is an error (`grammar.md`); Racket cut the
    host at the NUL.
  - A port out of range returns the VM's own message, not Racket's
    contract text.
  - `TCP_NODELAY` is on for every socket; Racket leaves Nagle's algorithm
    on. Each `send` already flushes, so batching is the program's choice,
    and a write, write, read exchange never waits for a delayed ACK.
  - libuv accepts one connection ahead into its own slot while no task is
    in `accept`; the kernel had completed that connection anyway.

### 10.4 Processes

- `--allow-run` is the VM's own flag, checked inside `Process.spawn` at call
  time for every task and handler, as `current-process-allowed?` does.
- The VM resolves the executable itself, with one rule shared with Racket
  and written in `grammar.md` (Processes): a command that contains `/`
  resolves against the program's working directory; a bare name is looked
  up in each `PATH` entry in order. The VM never adds the working
  directory itself: empty entries are skipped, and an explicit relative
  entry such as `.` or `bin` resolves against the working directory, as in
  the shell. It passes the absolute path to `uv_spawn`.
  All three stdio streams are pipes.
  `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS` is never used.
- The file loop sets `UV_USE_IO_URING=0` in the VM's own environment
  (10.2.2). The processes PR must not pass it on: it removes it from the
  child's environment unless the user had set it before the VM started.
- Windows: after resolution, allow only `.exe` and `.com`, case-insensitively,
  and reject names with a trailing dot or space or any `:`. Both backends use this same
  allowlist: the Racket check in `process.rkt` (`windows-runnable-name?`)
  applies it to the last component of the resolved path, and the VM must do
  the same when its process code is ported to Windows. On Windows the
  evaluator also searches the current directory before `PATH` (Racket's
  `find-executable-path`); the VM's port must not.

**As built (processes PR, Linux).** `vm/process.c` holds the eight
`Process` builtins; only it and `vm/loop.c` include `uv.h`. Other systems
get an empty table, so the lowerer's keys fail at load as unknown imports.

- **Values.** A `Process` value (`AGC_T_PROCESS`, printed `<Process>`) is
  a GC `agc_process` with three `agc_resource` pointers: `state`, the
  registered resource whose `native` is the `malloc`'d process state, and
  two lock records, `reader` and `writer`, that are never registered and
  only carry the lock fields of 10.2.2. `read_line` and `read_bytes` take
  the reader lock, `send`, `send_bytes` and `close_stdin` the writer lock,
  through `agc_handle_wait`, as the evaluator's two semaphores; `wait` and
  `close` take neither. So a reader parked on a silent child never blocks
  a writer, and a lock-wait timeout leaves the process running (the
  evaluator's `network-timed` around a semaphore).
- **Spawn.** Checks in the evaluator's order (`--allow-run` before any
  work on the arguments, then a nonempty command and no NUL, then the
  timeout), resolution as above (a path that does not exist or is a
  directory is "executable is unavailable"), then three real pipes made
  with `uv_pipe` and given to the child with `UV_INHERIT_FD` (libuv's
  `UV_CREATE_PIPE` makes socketpairs, which some programs treat
  differently), and the parent's ends opened with `uv_pipe_open`. The
  first spawn of a run also marks every descriptor the VM inherited above
  2 close-on-exec (a walk over `/proc/self/fd` with `fcntl`;
  `close_range` is not declared under the VM's `_POSIX_C_SOURCE` build),
  and the VM opens its own descriptors close-on-exec, so a child sees only
  0, 1 and 2, as with the evaluator. `argv[0]` is the resolved path. The
  child's environment is the VM's, without `UV_USE_IO_URING` when
  `drop_uring_env` says the VM set it. A failed `uv_spawn` (`EACCES`,
  `ENOEXEC`) is an error `Result` with the OS text (`agc_system_error`).
  `Process.spawn` charges a turn cost by the size of its arguments
  (`AGC_COST_SIZE`, 10.2.1); `send`, `send_bytes`, `read_line` and
  `read_bytes` charge by the size they write or return, also when they
  park (10.3.1).
- **State.** The `malloc`'d `proc` holds the `uv_process_t`, the three
  `uv_pipe_t`, one `uv_write_t`, the stdout buffer, and the pending
  requests (one reader, one writer, a list of waits). Callbacks find it with
  `offsetof`. It is freed when its resource was released, every request
  that points to it was dropped, and the close callback of each of its
  libuv handles ran (a user count and a handle count), so no callback ever
  sees freed memory.
- **Operations park only their task** on external jobs (10.2.2) with the
  call's timeout on the job's timer. Reads start `uv_read_start` on stdout
  only while a reader waits and stop as soon as its line or bytes are
  buffered (or at EOF or an error). Each read asks for 4 KiB, or for what
  a `read_bytes` still needs when that is more, so the VM reads at most
  about 4 KiB past what the program asked for, like the evaluator's 4 KiB
  port buffer, and a child that writes much more than the program reads
  blocks on its pipe as it does there. The stdout buffer is the one TCP
  uses (`vm/stream.c`, 10.3.1), so a read error after a partial line
  returns the error, not the partial line. A write first tries
  `uv_try_write`; the rest is copied and sent with `uv_write`, and the
  task parks until its callback. `wait` returns at once when the child has
  exited and its stderr reached EOF; otherwise it parks on a job that
  `exit_cb` or the stderr EOF readies. A timed-out read or write closes
  the process, as the evaluator does; a timed-out `wait` leaves the child
  running.
- **Stderr** is read all the time and each chunk is written and flushed to
  the program's stderr in the read callback, so it reaches the user in
  order with `IO.warn` output and without waiting for a builtin. If that
  write fails, the rest is read and dropped.
- **Close.** `Process.close`, a timed-out read or write, and the end of
  the run (`agc_io_close` releases every resource, also after
  `System.exit`, a runtime error or the step limit) all go through one
  close. If the child still runs, it sends `SIGKILL` and polls `waitpid`
  with `WNOHANG` every 0.1 ms until a `CLOCK_MONOTONIC` deadline 1 second
  away; a child normally dies within the first polls. `Process.close` and
  a stream timeout give their one child its own deadline. A cleanup of all
  children (the end of the run, or a stop signal, below) sends `SIGKILL`
  to every running child first and then reaps them under one shared
  deadline, so the whole cleanup stays within about 1 second, inside the
  driver's 2-second grace (9). A child in uninterruptible sleep (a hung
  network file system, say) can outlast that bound: then, and when the
  kill fails (`EPERM`, for example a child that became another user
  through `sudo`), the VM does not wait. It keeps the `uv_process_t` open
  so that libuv reaps the child when it ends and `exit_cb` closes the
  handle. A failed kill in `Process.close` ends the run with
  `RUNTIME-PROCESS-CLOSE`, as the evaluator's failed cleanup does; inside
  a timed-out read or write the timeout error stands. If such a child is
  still there at the end of the run, `uv_loop_close` fails and the VM ends
  with `_exit` (10.2.2), leaving that child to `init`. Otherwise the pipes
  are closed at once; libuv's own reap later finds no child and does
  nothing. The waiting reader, writer and waits are readied and see
  "process is closed". A second `close` does nothing, and any other
  operation after it returns "process is closed", as in the evaluator. So
  no child outlives a run that ends normally and no zombie or pipe stays
  behind.
- **Signals.** The first spawn of a run makes a guard with one
  `uv_signal_t` each for `SIGINT`, `SIGTERM` and `SIGHUP` (not for a
  signal the VM started with ignored, as under `nohup`), registered as a
  resource so the end of the run releases it. The guard keeps a list of
  the running children and starts its watchers before the first child's
  `uv_spawn`, so a signal that comes during a spawn is seen once the
  child is listed; it stops them when the last running child is reaped,
  so a program with no running child keeps the default actions (and the
  scheduler's stall check). libuv's own handler only writes to a pipe, so
  nothing runs in signal context. When a watcher runs on the loop thread,
  it kills and reaps every running child and raises the signal again
  after stopping the watchers, so the VM ends by that signal as it would
  without children. Stopping a watcher could drop a signal that libuv
  caught but had not dispatched yet (it discards the queued message of a
  stopped watcher), so every stop blocks the three signals on the loop
  thread, compares the watcher's `caught_signals` with its
  `dispatched_signals` (fields of the pinned libuv's `uv_signal_t`), and
  when one was caught it raises it before unblocking: the VM then ends by
  it once the children are gone. The pool threads keep the three signals
  blocked (10.2.2), so no handler runs on another thread while the loop
  thread stops the watchers. The loop runs between turns, so a CPU-bound
  task delays the cleanup by at most one turn. A blocking write to stdout
  delays it until that write ends, which may be never: if nobody reads the
  VM's stdout any more (for example `agentica --vm prog.agc | less` after
  the pager stopped reading and the driver died), the VM stays blocked in
  `write`, never runs its loop, and neither it nor its children react to
  the `SIGTERM` (the parent-death signal of 9 included); the VM has no
  alarm fallback for this. A VM killed by `SIGKILL`, or ended by the
  out-of-memory exit (70, 6.3), leaves its children running (they get EOF
  or `EPIPE` when they next touch a pipe). `agentica --vm` stops the VM
  with `SIGTERM` and kills it only after 2 seconds (9), so a cleanup that
  takes longer than that leaves the rest of the children running.
- **Black-box differences.**
  - A file that exists but cannot be executed (no execute permission, a
    bad format) is an error `Result` from `Process.spawn` on the VM; the
    evaluator returns a process that writes `exec failed` to stderr and
    exits 1.
  - After a read or write timeout closes a process, the evaluator's dead
    stream thread keeps that direction's semaphore, so a later read (or
    write) in the same direction waits its whole timeout and returns
    "network: operation timed out"; the VM returns "process: process is
    closed" at once (an evaluator bug, not copied).
  - A `read_line` or `read_bytes` pending in another task when the
    process is closed (by `Process.close`, or by a send that timed out)
    returns "process: process is closed" on the VM; the evaluator returns
    Racket's port error ("read-byte: input port is closed" and similar).
  - When forwarding the child's stderr fails (the program's stderr is
    `/dev/full`, say), the evaluator's forwarding thread fails and kills
    the child; the VM drops the rest of that stderr and keeps the child.
  - libuv resets signals 1 to 31 to their default action in the child, so
    a signal the VM inherited as ignored (`nohup`) is not ignored in its
    children; Racket's children keep it ignored. The VM does not patch
    libuv for this.
  - `Process.spawn` checks its timeout but does not apply it to the
    lookup and start, which run without a timer; the evaluator runs them
    under it. Only timing can differ.
  - Error texts of failed system calls follow `agc_system_error`.

### 10.5 Limits the C runtime keeps

| Limit | Value | Racket source |
|---|---|---|
| `IO.read_bytes` count | 0..1 MiB | `max-read-bytes`, `evaluator.rkt` |
| Process send, read, line | 1 MiB | `bytes-limit`, `process.rkt` |
| File read, line, text, writes | 1 MiB | `bytes-limit`, `filesystem.rkt` |
| TCP `send_bytes`, `recv_bytes`, line (`TCP.send` of a String has no limit, as in `grammar.md`) | 1 MiB | `bytes-limit`, `network.rkt` |
| Byte values | 0..255 | `valid-bytes`, `network.rkt`; `process.rkt`; `String.from_bytes` |
| `List.repeat` count | 0..1048576 | `evaluator.rkt` |
| HTTP start and header line | 8192 bytes | `wire-line`, `http-wire.rkt` |
| HTTP header block | 65536 bytes | `http-wire.rkt` |
| HTTP headers | 100 | `http-wire.rkt` |
| HTTP interim responses | 15 accepted, the 16th fails | `read-response-head`, `http-wire.rkt` |
| `max_connections` | at most 65536 | `http-client.rkt` |
| HTTP body | `max_body_bytes`, 413; from phase 20 the body is held whole, so the default is 1 MiB and the cap 64 MiB (10.7) | `http-wire.rkt` |
| Process launch | `--allow-run` | `process.rkt` |
| Windows programs other than `.exe`, `.com` | rejected | `process.rkt` |

HTTP numbers: `Content-Length` and chunk sizes accumulate with saturation:
parsing stops once a value exceeds the limit (413), and every comparison is
written `size > limit - total`. A hermetic test sends over-long values.

### 10.6 HTTP parsing

Phase 20 (`docs/future/30-hybrid-http.md` §30) runs HTTP on the VM with a
simpler API: whole messages, `String` bodies, no streaming until channels.
Every parsing and framing rule of this section stays; what changes is how
bodies are handed over (the last bullets, and 10.7). The evaluator's HTTP is
deleted by phase 20, so the codes below are fixed by the hostile-case
goldens, not by a comparison with it.

Parity with the evaluator is black-box (1): the exit code, the stdout and
program stderr of every run except one stopped by `--max-steps`, the
diagnostic code, and the HTTP status or `Result` error kind must match; message text, spans, step counts and library error
strings may differ. For HTTP this means:

- Well-formed messages: the VM and the evaluator agree on the status, the
  headers, the body, and whether a `Result` is ok or an error.
- Malformed or hostile input: both reject it. A server answers with an
  error status and closes the connection; a client request call returns an
  error `Result` (the "error kind" in this section; its message text is
  free). The exact 4xx or 5xx code may differ, except these, which must
  match: 413 (body over the limit), 431 (too many headers or trailers, or
  a line, head or trailer block over its size limit), 505 (a request with
  an HTTP version the evaluator rejects with 505; a bad response version
  is a client error `Result`) and 501 (`CONNECT`, and any
  `Transfer-Encoding` other than one `chunked`).
- The VM does not copy evaluator quirks (for example 431 for a bad chunk
  terminator byte), and it does not have to report the first failing line
  in the evaluator's order.
- Documented differences: picohttpparser's RFC 9112 leniencies, one
  leading empty line before a request and runs of spaces in the start line,
  are accepted. They do not make framing ambiguous. The reason phrase
  accepts what picohttpparser accepts; control bytes in a reason phrase
  give a client error on the VM.
- Framing rules stay strict: `Content-Length` with `Transfer-Encoding`
  (with any `Transfer-Encoding`, this is 400 first), conflicting `Content-Length` values (400), bad chunk sizes and obs-fold
  are rejected. Equal duplicate `Content-Length` values (the header twice,
  or `5, 5`) are accepted as one, like the evaluator (RFC 9110 §8.6).
  `Transfer-Encoding` other than one `chunked` (`gzip`, `gzip, chunked`,
  two `Transfer-Encoding` headers) gives 501.

The VM does not copy `src/http-wire.rkt` check by check. picohttpparser
validates the head; that is why it is a dependency (and its SSE4.2 path
later, `docs/future/19-simd.md` §19). It sits behind our own small adapter, so it can be
swapped later (for example for llhttp), the same way libuv stays inside
the I/O layer.

- `vm/http_parse.h` holds our types only: a parsed head struct (method,
  target, version, status, reason, and the headers with their count, all
  as byte slices into the input buffer) and
  `agc_http_parse_request_head(buf, len, limits, out)` and
  `agc_http_parse_response_head(buf, len, limits, out)`. They return OK
  with the bytes consumed, INCOMPLETE, or ERROR with our own error enum.
- Only `vm/http_pico.c` includes `picohttpparser.h`. No picohttpparser type
  or return code leaks out of it.
- The adapter calls picohttpparser without `last_len`, and only when the
  newly read bytes complete a line (contain LF). Each call parses the whole
  buffered head again. A head is at most the start line (8192 bytes plus
  CRLF) and 64 KiB of headers (10.5), and it has at most about 100 lines
  (the start line, 100 headers and the blank line) before the pre-scan
  stops it, so parsing work is bounded by lines × head size. On INCOMPLETE
  the caller reads more and calls again with the grown buffer.
- A -1 from picohttpparser maps to one error: 400 "invalid HTTP request
  head" for a server, and an error `Result` ("invalid HTTP response head")
  for a client.
- The adapter checks more than picohttpparser, all on our own pre-scan or
  on picohttpparser's output:
  - The pre-scan (one pass over newly read bytes) checks the line and
    head size limits (431), rejects bare LF (kept strict against
    smuggling), and counts header lines: once the count passes 100 it
    returns 431, before picohttpparser runs. Before a request, the
    pre-scan and the start-line check skip one leading CRLF, matching the
    documented leniency, so the header count is not off by one. The
    pre-scan stops at the end of the start line; the start-line check
    (431 for its length, then 505 or 400) runs before the pre-scan looks
    at any header line.
  - Once the start line is complete, and before picohttpparser runs, the
    adapter checks it itself with the evaluator's shape. A request is
    `METHOD SP+ TARGET SP+ VERSION`, a response `VERSION SP+ 3DIGIT`. In
    a request, a version of the form `HTTP/[0-9.]+` gives 505 unless it is
    exactly `HTTP/1.1` (so `HTTP/1`, `HTTP/2`, `HTTP/1.10` and `HTTP/2.0`
    give 505); any other bad shape gives 400. In a response, a bad version
    or shape is a client error `Result`. So a complete bad start line
    always fails at once, even where picohttpparser would still return -2
    for short input.
  - Request target: origin form (`/...`), or `*` with `OPTIONS`; only bytes
    33 to 126; anything else is 400.
  - Method: token characters only (400); `CONNECT` gives 501.
  - obs-fold lines (picohttpparser returns a header with `name == NULL`)
    are rejected with 400.
  - Responses: `HTTP/1.1` only, status 100 to 599, 101 rejected, at most
    15 interim responses (the 16th fails); these give an error `Result`.
  - The `Host` rules, and the body framing and smuggling rules above
    (conflicting `Content-Length` 400, unsupported `Transfer-Encoding`
    501).
- Phase 20 keeps this decoder but not its streaming use: the slices go
  into one `malloc`'d buffer for the whole body, within `max_body_bytes`,
  which becomes one `String` (10.7). `HttpBody`, `HTTP.request_stream`,
  `HttpWriter`, trailers as an API and the chunked encoder are dropped
  until the streaming items (20e to 20g) bring the encoder back on
  channels. The paragraph below is the design it replaces in part.
- The body is never buffered whole by the parsing layer. Our own body
  decoder, `vm/http_body.c` (no third-party code), is an incremental state
  machine. It is set up with the framing (`Content-Length` n, chunked, or
  until close for responses) and the `max_body_bytes` limit; then
  `feed(buf, len)` returns the bytes consumed, zero or more body slices
  pointing into the input, and NEED_MORE, DONE or ERROR: 413 over the
  limit, 431 for an over-long chunk-size or trailer line or for trailers
  over the block-size or count limit, and 400 for every other malformed
  body. Chunk sizes accumulate with saturation;
  `phr_decode_chunked` is not used, since it knows no limits. `HttpBody`,
  `HTTP.request_stream` and `HttpWriter` read and write through it chunk by
  chunk, so a large upload or download never sits whole in memory. Trailer
  lines are checked by the body decoder with the header rules (token
  names, value bytes, the forbidden trailer list, and the size and count
  limits), as `http-wire.rkt`'s `read-headers` with `#:trailers? #t`. The
  encoder that writes chunked output is ours too. Swapping the head parser
  leaves the body decoder unchanged.
- Tests target the adapter interface, so a replacement parser must pass the
  same tests: a C unit test in `vm/tests/`, and fixed, deterministic hostile
  cases run on both backends. They check that both reject (and the code
  where it must match), not message text: `Content-Length` with
  `Transfer-Encoding`, conflicting `Content-Length` (400), equal duplicate
  `Content-Length` twice and as `5, 5` (accepted), `Transfer-Encoding:
  gzip`, `gzip, chunked` and two `Transfer-Encoding` headers (501), huge
  chunk sizes (413), bare LF, over-long lines and heads (431), 100 headers
  accepted and 101 and 150 rejected with 431, trailers over the line,
  block-size or count limit (431), `HTTP/1`, `HTTP/2`, `HTTP/1.10` and
  `HTTP/2.0` (505), an `HTTP/2.0` start line followed by 101 headers in
  one write (505), a malformed version, a leading CRLF before a request
  with 100 headers (accepted), absolute-form and non-ASCII targets, `*`
  without `OPTIONS`, a bad method token, `CONNECT` (501), an obs-fold line,
  bad trailers, and on the client
  side `HTTP/1.0` responses, status 99 and 600, a 101 response, and 15
  interim responses accepted and 16 rejected. One case sends a complete bad
  start line ending in CRLF and leaves the socket open: it is rejected
  before any timeout; another sends the short line `GET / HTTP/1\r\n`,
  which gets 505.

### 10.7 HTTP on the VM: the hybrid split (planned, phase 20)

Planned in `docs/future/30-hybrid-http.md` §30 and roadmap phase 20. HTTP is
split between a small C builtin module, `HttpWire`, and the Agentica module
`std/http.agc`, which programs import as `HTTP`.

- **C (`HttpWire`)**, VM-only and std-only: the linker lets only modules
  embedded from `stdlib/` call it, and gives user code
  `CHECK-UNKNOWN-NAME` with a help that shows the `std/http` import
  (`src/builtins.rkt` lists it in `std-only-modules`, and its builtins in
  `vm-only-builtins`; §30.5, §30.8). It keeps what is byte-level, security-critical or shared
  across tasks: the head parser of 10.6 (`vm/http_parse.h`,
  `vm/http_pico.c`), the body decoder (`vm/http_body.c`) filling one
  `malloc`'d buffer per body, the UTF-8 check, the error answers before
  dispatch (400, 413, 417, 431, 501, 505), response writing with
  `Content-Length` only, the client's connection pool and its `SSL_CTX`
  (one per client, from `ca_file`, until `TlsContext`,
  `docs/future/29-tls-context.md` §29), and the server's task group:
  accept with the `max_connections` slots, group tasks that own their
  sockets, and `close_server`, which cancels the group's tasks through
  `agc_task_cancel` (§30.6; the core of the cancellation planned in
  `docs/future/27-iteration-and-concurrency.md` §27.1, landed early in
  20b, with pool waiters among its states).
- **Agentica (`std/http`)** keeps the rest: options and their checks, URL
  parsing, request building, the accept loop, the per-connection loop,
  keep-alive, handler dispatch, the 500 answers for a handler `error` or an
  unsendable response, and the header helpers. No Agentica code touches a
  body byte by byte: a body crosses once, as a `String`.
- **What is dropped** from the C-only design of 10.6 and roadmap 7h: the
  streaming body API (`HttpBody`, `HttpWriter`, the `request_stream`
  producer task), the trailer API, the chunked encoder (back in 20f and 20g
  for streams on channels), and a server loop and handler dispatch in C.
- **What is kept**: picohttpparser v1.4 behind the adapter, every check of
  10.6, the limits of 10.5 with saturating sizes, and the hostile-case list,
  run against the VM server and client by a Python raw-socket peer.
