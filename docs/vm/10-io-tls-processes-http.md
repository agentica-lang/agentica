### 10.3 TLS

**As built (TLS PR, Linux).** `TLS.connect` and `TLS.listen` run on the
VM; a TLS program no longer falls back to the evaluator. The release links
the vendored OpenSSL 3.5 LTS statically; a default source build links the
system OpenSSL 3 dynamically (`AGENTICA_OPENSSL`, 10.0). The adapter sets
its own minimums (TLS 1.2, security level 2) and loads no `openssl.cnf`, so
the behaviour is the same with both.

- **Adapter.** `vm/tls.h` declares our own types only (`agc_tls_config`,
  `agc_tls`, `agc_tls_status`, `agc_tls_error`, `agc_tls_failure`);
  `vm/tls_openssl.c` is the only file that includes OpenSSL headers. A
  config wraps one `SSL_CTX` (client: trust store; server: certificate
  chain and key); a session wraps one `SSL` with two memory BIOs.
  Ciphertext goes in with `agc_tls_feed_in` (and `agc_tls_feed_eof` at the
  transport's EOF) and comes out with `agc_tls_out_peek` and
  `agc_tls_out_consume` (a full consume resets the BIO, so no copy);
  plaintext goes through `agc_tls_read` and `agc_tls_write`. Every call
  returns OK, WANT_READ, WANT_WRITE, CLOSED or ERROR, and an error fills an
  `agc_tls_failure`: our error code, an `errno` for a system error (a
  missing file), and a short detail (OpenSSL's reason text, or
  `certificate verify failed: ` and the X.509 verify text). OpenSSL's
  error queue is drained in the adapter and never leaks to other calls.
  OpenSSL never gets a GC pointer: plaintext is copied into a `malloc`'d
  buffer first, and reads land in the socket's `malloc`'d input buffer.
  A later `TlsContext` (`docs/future/29-tls-context.md`) is a config held
  by a value instead of by one connection; nothing here blocks it.
- **Error codes** (`agc_tls_error`): `VERIFY_UNTRUSTED` (unknown issuer,
  self-signed), `VERIFY_EXPIRED` (expired or not yet valid),
  `VERIFY_HOSTNAME` (DNS name or IP address mismatch), `VERIFY_FAILED`
  (any other verify result), `HANDSHAKE_FAILED`,
  `NO_SHARED_VERSION_OR_CIPHER` (protocol version or cipher, group or
  signature algorithm reasons, and the peer's protocol version alert),
  `UNEXPECTED_EOF` (the peer closed during the handshake), `PROTOCOL` (an
  error after the handshake), `BAD_CA`, `BAD_CERT`, `BAD_KEY`,
  `KEY_MISMATCH`, `NOMEM` and `INTERNAL`. The `tls` trace prints them in
  lower case.
- **Setup.** `TLS.connect` checks the timeout, the port and the host as
  `TCP.connect` does, and a NUL in `ca_file`; `TLS.listen` checks the
  port and host as `TCP.listen` does, and a NUL in either path ("network:
  path cannot contain NUL"). Then one libuv pool job builds the config
  (reading the CA file or the certificate and key with OpenSSL's file
  loaders, off the scheduler thread), and only then the VM resolves the
  host and connects or listens, as for TCP. So, as in the evaluator, a bad
  certificate or key fails `TLS.listen` before the port is bound. The
  pool job is started with the stop signals blocked, like every other
  pool job (10.2.2). The connect timeout covers the setup, the lookup,
  the connect and the handshake.
- **Minimums.** TLS 1.2 and security level 2 (RSA keys of at least 2048
  bits), set on every context; renegotiation is off. No `openssl.cnf` is
  read.
- **Trust.** A non-empty `ca_file` replaces system trust (a missing or
  empty file fails the connect: `BAD_CA`). With an empty `ca_file` the
  file is `SSL_CERT_FILE` when set, or else the first readable file of
  `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`,
  `/etc/ssl/ca-bundle.pem`, `/etc/pki/tls/cacert.pem`,
  `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` and
  `/etc/ssl/cert.pem`; the directory is `SSL_CERT_DIR` when set (OpenSSL's
  `:`-separated list) or else none. A system source that fails to load is
  skipped, as OpenSSL's own default paths are. Windows (the `ROOT` store)
  and macOS (the Keychain anchors) are for when those ports resume.
- **Per connection.** The client verifies the peer (`SSL_VERIFY_PEER`;
  there is no verify-none path). A host that parses as an IPv4 or IPv6
  literal is checked against IP SANs with `X509_VERIFY_PARAM_set1_ip_asc`
  and sends no SNI; any other host gets SNI and `SSL_set1_host` (no
  partial wildcards). The server does not ask for client certificates.
- **Data path.** A TLS socket is the TCP `net` of 10.3.1 with a session.
  libuv reads ciphertext into a 16 KiB `malloc`'d buffer; the read
  callback feeds it to the session, runs the handshake while it is not
  done, then decrypts everything available into the socket's input
  buffer (`agc_inbuf`), so `read_line`, `recv_bytes`, the 1 MiB limits,
  the locks and the timeouts are exactly the TCP ones. During the
  handshake the socket is read all the time; after it, only while a
  reader waits, as for TCP. `send` and `send_bytes` copy the plaintext and
  encrypt it in 16 KiB pieces; each piece's records are written with the
  shared `agc_stream_write` (try first, then one `uv_write` of a copy),
  and the next piece is encrypted when that write completes, so a large
  send never holds more than one piece of ciphertext. Records the
  session writes by itself (handshake, alerts, key updates) take the same
  path. The writer parks until every byte reached the kernel. A failed
  write is sticky on a TLS socket: later sends return the same error.
- **Accept.** On a TLS listener a waiting `TCP.accept` takes the
  connection at once (`uv_accept` in the connection callback), runs the
  server handshake under the accept's timeout, and returns the socket
  only when it is done; a failed handshake returns "port->ssl-ports:
  accept failed (...)", as in the evaluator, and the listener stays open.
  Connections in a handshake hang off their accept request; closing the
  listener (or the end of the run) closes them too.
- **Handshake I/O errors.** A write error or a failed `uv_read_start`
  during the handshake fails it at once with that system error, never a
  timeout, and a failed handshake is reported only once.
- **EOF.** A peer that closes without `close_notify` gives a plain end of
  input, as in the evaluator (`SSL_OP_IGNORE_UNEXPECTED_EOF`); the
  framing above TLS (lines, HTTP lengths) must catch truncation. A
  transport error after the handshake is the TCP read error; a TLS error
  after it is "error reading from stream port" with `EPROTO`.
- **Close.** `TCP.close`, a timeout and the end of the run send
  `close_notify` with one `uv_try_write` when the handshake finished and
  no write is pending, then close as TCP does.
- **Messages** keep Racket's shapes: "ssl-connect: connect failed
  (detail)", "port->ssl-ports: accept failed (detail)",
  "ssl-load-certificate-chain!: load failed from: \"path\" (detail)",
  "ssl-load-private-key!: ..." (also for a key that does not match the
  certificate), "ssl-load-verify-source!: ..." for `ca_file`; a system
  error (a missing file) ends with the usual "system error: ...;
  errno=N" lines instead of a detail. Only the `Result` error kind must
  match the evaluator; the detail is OpenSSL's text.
- **Trace** (`tls` category, `docs/vm/08-loader-and-cli.md` §9):
  `tls_handshake` (role, host), `tls_handshake_done` (protocol, cipher),
  `tls_handshake_error` (error code, detail), `tls_setup_error`,
  `tls_read_error` and `tls_close` (why, right after `tcp_close`). A server-side connection shows
  `socket=0` and its `listener` until the accept returns its id.
- **Turn costs.** TLS sockets use the TCP builtins, so reads and writes
  charge by size (10.2.1, `AGC_COST_SIZE`); `TLS.connect` and
  `TLS.listen` charge nothing.
- **Fuzzing.** Under `no_files`, `TLS.connect` and `TLS.listen` end the run
  with `RUNTIME-INTERNAL`, like their TCP twins.
- **Tests.** `vm/tests/tls_test.c` runs two in-memory adapters against
  each other (handshake with tiny record slices, a 100 KB transfer,
  `close_notify`, raw EOF, every verify error, an EOF and a plain-text
  request in the handshake, and the load errors). Two small goldens are
  their own peers: `tls-echo` (one echo through a VM server and client)
  and `tls-errors` (argument and load errors); each run of the
  `--max-steps` sweep does a full handshake, so they stay near 60 steps.
  Everything else runs once in `tests/vm-tls-test.rkt`, against Node
  (`tests/fixtures/tls-peer.js`) and Python (`tests/fixtures/tls-peer.py`)
  peers or as a VM program that is its own peer: one-byte records, EOF
  with and without `close_notify`, a reset, 100,000-byte lines, the 1 MiB
  limit, a silent peer, every verify error on both sides, a TLS
  1.0/1.1-only server, plain text both ways, a stalled and a pending
  handshake, timeouts, system trust through `SSL_CERT_FILE`, a TLS 1.2
  Python server, Node clients on TLS 1.3 and 1.2, a Python client, a
  client that does not trust the VM's server, and the end of a run with
  TLS sockets, a handshake and an 8 MiB send pending (the smallest size
  that fills loopback buffers of 4 MiB plus the receive window). The certificates in `tests/fixtures/tls/` come from
  `make-certs.sh` (see its `README.md`).
- **Black-box differences.** After a timed-out read or write the next
  call returns "network: socket is closed" at once, and a line over 1 MiB
  closes the socket, as for TCP (the evaluator kept a dead lock and the
  rest of the line). A missing or empty `ca_file` fails at connect with
  its own message; the evaluator ignored it and failed verification.

### 10.3.1 TCP (as built)

**As built (TCP PR, Linux).** `vm/tcp.c` holds the ten `TCP` builtins.
`vm/stream.c` holds the parts it shares with `vm/process.c`: the input
buffer (`agc_inbuf`) with its line and byte takes, the write path
(`uv_try_write`, then one `uv_write` of a `malloc`'d copy), the
lock-or-timeout helper and the `network:` timeout texts. Other systems get
an empty table, so the lowerer's keys fail at load as unknown imports.
TLS sockets are the same `net` with a TLS session on top (10.3).

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
    so its next call waits its whole timeout (the legacy bug of 10.4).
    TLS sockets now behave the same way (10.3).
  - A `read_line` over 1 MiB closes the socket, as `grammar.md` now
    says. The evaluator drops the 1 MiB + 1 bytes it read and leaves the
    stream in the middle of the line, so its next `read_line` returns the
    tail of the long line as if it were a whole line. TLS sockets now
    behave the same way (10.3).
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
  VM's stdout any more (for example `agentica prog.agc | less` after
  the pager stopped reading and the driver died), the VM stays blocked in
  `write`, never runs its loop, and neither it nor its children react to
  the `SIGTERM` (the parent-death signal of 9 included); the VM has no
  alarm fallback for this. A VM killed by `SIGKILL`, or ended by the
  out-of-memory exit (70, 6.3), leaves its children running (they get EOF
  or `EPIPE` when they next touch a pipe). `agentica` stops the VM
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

**As built (21a, captured processes, Linux).** `Process.spawn_captured`
and `Process.output` (`docs/future/31-bdd-in-agentica.md` §31.9) live in
`vm/process.c` beside the eight builtins above and share their code; a
`proc` has a `captured` flag.

- **Spawn.** `spawn_child` serves both spawns. The checks keep the order
  above, with `dir` (nonempty, no NUL) after the arguments and before the
  timeout. The command resolves first, against the VM's working directory;
  then `dir` becomes a host path like a file path (raw `getcwd` bytes for a
  relative one) and must be a directory (`stat`), else "directory is
  unavailable" (trace `spawn_failed reason=dir`). It goes to
  `uv_process_options_t.cwd`; `"."` passes no `cwd` at all.
- **Reading.** Both pipes are read from the spawn on, never stopped, into
  two `agc_inbuf`s: `out_buf` (the one `read_line` and `read_bytes` use)
  and `err_kept`. A chunk is read straight into the buffer while 4 KiB
  more still fits under 1 MiB of pending bytes; nearer the limit it is
  read into the 4 KiB scratch buffer and only what fits is copied
  (`keep_scratch`), so a buffer's capacity never passes 1 MiB. A byte
  that does not fit marks the stream (`out_cut`, `err_cut`), and its later
  chunks are read into the scratch buffer and dropped, so the child never
  blocks. For stdout the
  limit counts unread bytes, so reading makes room again until the first
  cut; stderr is never consumed. A cut readies the waiting reader, and
  `read_ready` and `take` check the two marks before the buffer, so a
  zero-byte `read_bytes` returns the error without parking.
- **Output.** `Process.output` is a wait like `Process.wait` (same list,
  no lock, the same `await_child` path); its condition is stdout at EOF or
  a read error and stderr at EOF. The record is built from the pending
  bytes with U+FFFD for invalid UTF-8 (`agc_utf8_decode`), nothing is
  consumed, and the call charges a turn cost by the bytes it copies. The
  lowerer appends `ProcessOutput` to the struct table as it does
  `FileInfo`; the C side finds it with `agc_builtin_struct`.
- **Close.** `shut` sends `SIGTERM` to a running captured child and starts
  a 1-second `uv_timer_t` (`grace`); the pipes close and the program sees
  "process is closed" at once. The timer sends `SIGKILL`; libuv's exit
  callback reaps the child and closes the process handle and the timer
  (`retire`), so `Process.close` and a stream timeout never block. The
  end of the run (and a stop signal) first sends `SIGKILL` to plain
  children and `SIGTERM` to captured ones that have not had it, polls the
  captured ones under one 1-second deadline (`outlast`), then sends
  `SIGKILL` to those left and reaps everything under a second 1-second
  deadline. A captured child that handles `SIGTERM` quickly ends the
  cleanup in milliseconds; one that ignores it holds the run about one
  second, and only a child stuck in the kernel can make it two. A failed
  `SIGTERM` in `Process.close` is `RUNTIME-PROCESS-CLOSE`, as a failed
  kill is.
- **VM only.** Until 7i deleted the evaluator, both names were in
  `vm-only-builtins`, so the fallback and `--legacy-eval` refused them with
  `LOWER-UNSUPPORTED` (`docs/vm/08-loader-and-cli.md` §9).

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

#### 10.6.1 As built (20a)

- `vm/http_parse.h` has no limits parameter: the limits are the constants
  `AGC_HTTP_MAX_LINE` (8192), `AGC_HTTP_MAX_BLOCK` (65536) and
  `AGC_HTTP_MAX_HEADERS` (100). The calls are
  `agc_http_parse_request_head(buf, len, out, used, error)` and
  `agc_http_parse_response_head(...)`, returning `AGC_HTTP_OK`,
  `AGC_HTTP_INCOMPLETE` or `AGC_HTTP_ERROR` with an `agc_http_error`;
  `agc_http_error_code` gives its status (400, 413, 431, 501, 505) and
  `agc_http_error_text` its message. `agc_http_framing` turns a parsed head
  into the body framing (`Content-Length`, chunked, or until close for a
  response). A response head with status 100 to 199 is returned without
  framing; the caller counts interim responses.
- `vm/http_body.c` is the decoder of the last bullets, filling one buffer:
  `agc_http_body_init(body, frame, length, limit)`, then
  `agc_http_body_feed(body, data, len, used)` (NEED_MORE, DONE or ERROR)
  and `agc_http_body_end` at EOF (DONE for a close-delimited body, else
  "truncated"). A `Content-Length` body is reserved whole up front, after
  the limit check. Trailers are checked and dropped.
- Only `vm/http_pico.c` and the Makefile know picohttpparser; it is built
  like yyjson, as one object (`build/vm/<config>/picohttpparser.o`).
- Tests: `vm/tests/http_parse_test.c` runs the hostile list on the adapter
  and the decoder (request and response heads; each body fed whole and
  byte by byte); `tests/vm-http-test.rkt` sends the client-side cases from
  a Python raw-socket peer (`tests/fixtures/http-peer.py`). The server-side
  cases over a socket come with the server (20c).

### 10.7 HTTP on the VM: the hybrid split (phase 20; the client and the server are built)

Status after 7i and 20c: the builtin `HTTP` module is gone (deleted with
the evaluator, decided by the owner on 2026-10-13), so `std/http` is the
only HTTP, imported as `HTTP`, with the client (20a, 10.7.1) and the server
(20c, 10.7.2).

Planned in `docs/future/30-hybrid-http.md` §30 and roadmap phase 20. HTTP is
split between a small C builtin module, `HttpWire`, and the Agentica module
`std/http.agc`, which programs import as `HTTP`.

- **C (`HttpWire`)**, VM-only and std-only: the linker lets only modules
  embedded from `stdlib/` call it, and gives user code
  `CHECK-UNKNOWN-NAME` with a help that shows the `std/http` import
  (`src/builtins.rkt` lists it in `std-only-modules`; §30.5, §30.8). It keeps what is byte-level, security-critical or shared
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

#### 10.7.1 As built: the client (20a)

`HttpWire` has three client builtins; the server ones are in 10.7.2.

```text
HttpWire.client(timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String) -> Result[HttpClient]
HttpWire.exchange(client: HttpClient, scheme: String, host: String, port: Int, method: String, target: String, headers: List[Header], body: String) -> Result[HttpResponse]
HttpWire.close_client(client: HttpClient) -> Void
```

- The client takes every option once, and `exchange` reads `timeout_ms`
  and `max_body_bytes` from it, since `std/http` cannot read them back from
  the opaque handle. `std/http` checks the option ranges first.
- `vm/http_client.c` (Linux; other platforms get a stub table) holds the
  pool: per origin (scheme, host, port) a list of idle connections, the
  number of open slots and a FIFO of waiting exchanges. A finished
  exchange parks its connection as idle or frees its slot, and the first
  waiter gets it. Idle connections close after `idle_timeout_ms` (one timer
  per client; the clock is updated before each check) or when the peer
  closes them. An origin with no open connection, no waiter and no
  exchange is freed.
- Retry: an exchange that leased an idle connection and then fails with
  EOF, a read error or a write error before any response byte (no interim
  response, nothing buffered) is retried once on a new connection, at the
  head of the waiters and within the same timeout, when its method is
  `GET`, `HEAD`, `OPTIONS`, `PUT` or `DELETE`. This covers the race where
  the server closes an idle keep-alive connection as the request is sent.
  The request bytes are kept until the exchange ends for this.
- Connections are tcp.c's: `vm/net.h` exports its connection object
  (`agc_conn_open`, `agc_conn_send`, `agc_conn_read`, ...) with a watch
  callback, so DNS, connect, TLS through memory BIOs and the close rules
  stay in one place. The client's `SSL_CTX` is built on the libuv pool on
  the first HTTPS call and shared by its connections.
- `exchange` checks the method, target, host and header bytes, adds `Host`
  (the port only when it is not the scheme's default; an IPv6 host in
  brackets) and `Content-Length` (when the body is not empty or the method
  is `POST`, `PUT` or `PATCH`), and refuses user `Host`,
  `Content-Length`, `Transfer-Encoding` and `Connection` headers. It writes
  the request while it reads the response, so a server may answer (413, for
  example) before the upload ends. Interim responses are skipped (at most
  15); 101 is an error. The connection goes back to the pool only after a
  complete exchange with no `Connection: close` on either side and a framed
  body. Header names are lowercased, values are decoded as Latin-1, and the
  body must be valid UTF-8.
- After 204 or 304 the connection is not kept when the response still
  announced a body (a nonzero `Content-Length`, or chunked). After `HEAD`
  it is kept: no body follows a `HEAD` response whatever it announces
  (RFC 9110 §9.3.2). Bytes already buffered when an exchange ends close
  the connection. A connection freed while calls wait is parked as idle
  and handed to the first waiter by the client's timer 1 ms later, so
  bytes that arrive in that window close it first. This is a narrow guard,
  not a promise: a call that leases an idle connection right away (two
  calls in a row from one task) can still read bytes a server sends late.
  Idle connections and the idle timer are unreferenced in libuv
  (`agc_conn_hold`), so a pool never hides a stalled run.
- Over TLS, a close-delimited body must end with `close_notify`: tcp.c
  records whether the TLS layer closed before the TCP FIN
  (`agc_conn_clean_eof`), and a bare FIN gives "http: truncated HTTP body".
  OpenSSL cannot tell this itself here, since `SSL_OP_IGNORE_UNEXPECTED_EOF`
  makes a bare FIN look like `close_notify` (both set
  `SSL_RECEIVED_SHUTDOWN`).
- One `timeout_ms` covers the call, from the wait for a slot to the last
  body byte; on timeout the connection is closed and the call returns
  "network: operation timed out". `close_client` closes idle connections
  and fails every call in flight with "http: client is closed".
- Errors are `http: ` plus the text of 10.6, or the network error text of
  tcp.c for DNS, connect, TLS, read and write failures.
- `HttpResponse`, `Header`, `HttpClientOptions` and `FileInfo` carry their
  field types from `builtin-records`, so `JSON.encode`, `JSON.decode` and
  `JSON.schema` work on them on the VM (the `http-json` golden).
- Turn cost (`AGC_COST_SIZE`): charged when the call ends, after the
  exchange is freed, for the header list, the request's bytes (head and
  body) and the response's body and header fields.

#### 10.7.2 As built: the server (20c)

```text
HttpWire.read_request(socket: Socket, first_byte_timeout_ms: Int, timeout_ms: Int, max_body_bytes: Int) -> Result[HttpRequest]
HttpWire.write_response(socket: Socket, response: HttpResponse, head_only: Bool, close: Bool, timeout_ms: Int) -> Result[Void]
HttpWire.server(listener: Listener, max_connections: Int) -> HttpServer
HttpWire.accept(server: HttpServer) -> Result[Socket]
HttpWire.spawn(server: HttpServer, socket: Socket, f: Fn[Socket, Void]) -> Void
HttpWire.close_server(server: HttpServer) -> Void
HttpWire.wait(server: HttpServer) -> Result[Void]
HttpWire.local_port(server: HttpServer) -> Int
```

- `vm/http_server.c` (Linux; a stub table elsewhere) holds them, on tcp.c's
  connection object (`vm/net.h`) with a watch callback, as the client does.
  Header lists and the header writer are shared with the client in
  `vm/http_fields.c`.
- `read_request` waits up to `first_byte_timeout_ms` for the first byte of
  a request (bytes already buffered, or a raw byte heard on the socket, so
  a TLS handshake counts), then restarts its job's timer with `timeout_ms`
  (`agc_io_extend`), which bounds the rest of the request. The checks run
  in the order of §30.4: the parse errors of 10.6, any `Upgrade` header
  (501), an `Expect` other than one `100-continue` (417), a
  `Content-Length` over `max_body_bytes` (413), then `100 Continue` when
  `Expect` asked for it and the body is still to come, then the body and
  its UTF-8 check (400). Every error answer is written by C:
  `HTTP/1.1 CODE REASON`, `Content-Length: 0` and `Connection: close`.
  After it is sent the write side is shut (`agc_conn_half_close`, with
  `close_notify` over TLS) and input is read and dropped until the peer
  closes or the request's deadline, so request bytes the server never read
  cannot turn the close into a reset that loses the answer. Then the
  socket closes and the call returns `error("http: <reason>")`. EOF before
  the first byte is `error("network: end of input")`; EOF in the middle of
  a request is "http: connection closed before the request was complete";
  the deadline closes the socket and returns "network: operation timed
  out" with no answer. Header names are lowercased and values decoded as
  Latin-1; `path` is the target before `?`.
- `write_response` builds the whole response before it writes: a status
  of 200 to 599 (the reason phrase is the standard one, or empty), the
  header checks of the client (`Content-Length` and `Transfer-Encoding`
  are refused: "Content-Length and Transfer-Encoding are set by the
  server"), no body with 204 or 304, a `Date` header unless the handler set
  one, `Content-Length` except on 204 and 304, `Connection: close` when
  `close` is true and the handler did not send it, and the body unless
  `head_only`. A bad response is `error("http: invalid response: <reason>")`
  with nothing written. `timeout_ms` bounds the write from the call.
- The `HttpServer` handle holds the listener, the number of open
  connections, `max_connections` (1 to 65536) and the jobs of tasks parked
  in `accept` or `wait`, and a group node: a task that never runs
  (`agc_task_group`), the parent of the connection tasks. `accept` returns
  an accepted socket once fewer than `max_connections` are open, and parks
  otherwise; the listener's watch, a freed slot and the close wake it.
  Accept failures are traced and retried. A TLS socket is returned before
  its handshake: tcp.c makes the session at accept and runs the handshake
  on the first read or write, under that call's timeout.
- `spawn` starts `f(socket)` as a child of the group
  (`agc_task_spawn_in`), moves the socket to it, marks it `hidden` and sets
  its end hook (`agc_task.end`), which closes the socket and frees the
  slot when the task ends in any way. The children of a connection task
  that ended move to the group, as 20b's rule moves them to any parent.
- `close_server` (also the close of an owned server when its owner
  crashes) is idempotent: it closes the listener, wakes `accept` (which
  then returns "http: server is closed") and `wait` (which returns
  `ok()`), and drops the group (`agc_task_drop`): it marks the subtree,
  cancels it with `agc_task_cancel`, and closes every handle a task of it
  owns (`agc_close_owned`), so the connection sockets and the sockets a
  handler's spawned task opened close too. A handler that closes its own
  server stops after that builtin, as a running task does under 20b; no
  program can do that today (a handler cannot reach its `HttpServer`), and
  the C test of `agc_task_drop` covers it.
- A crash in a connection task ends that connection (§37.5): its socket
  closes and its client sees the close with no response. Connection tasks
  are `hidden`: no await can observe them, so of their unobserved crashes
  only the first per test (or per run outside `Test.run`) is kept in the
  crash list, and the others are counted on it. With observed crashes
  leaving the list, the list stays bounded however many handlers crash.
- `std/http` runs the accept loop as a task and, for each socket,
  `spawn`s the connection loop: `read_request` (the first request waits
  `request_timeout_ms` for its first byte, later ones `idle_timeout_ms`),
  the handler with no time limit, then `write_response` with a fresh
  `request_timeout_ms`. A handler `error` or a response that
  `write_response` refuses gives a 500 with `Connection: close` and one
  `IO.warn` line (`http: handler error: ...` or `http: invalid response:
  ...`). The connection closes after `Connection: close` on either side.
- Turn cost (`AGC_COST_SIZE`): `read_request` charges the body, the header
  count and their bytes when it ends; `write_response` charges the
  response's bytes.
- Tests: the `http-server*` goldens; `tests/vm-http-test.rkt` runs a VM
  server (plain and TLS) against `tests/fixtures/http-server-peer.py` (the
  hostile list of 10.6 on raw sockets, with status and close, the `Expect`
  cases, pipelining, `http.client`, the `max_connections` wait, a silent
  TLS client and a plain request on the TLS port) and
  `tests/fixtures/http-server-peer.js` (Node `http`).
