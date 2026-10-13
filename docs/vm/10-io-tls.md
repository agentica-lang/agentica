### 10.3 TLS

**As built (TLS PR, Linux).** `TLS.connect` and `TLS.listen` run on the
VM. The release links
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
  host and connects or listens, as for TCP. So a bad certificate or key fails `TLS.listen` before the port is bound. The
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
  accept failed (...)", and the listener stays open.
  Connections in a handshake hang off their accept request; closing the
  listener (or the end of the run) closes them too.
- **Handshake I/O errors.** A write error or a failed `uv_read_start`
  during the handshake fails it at once with that system error, never a
  timeout, and a failed handshake is reported only once.
- **EOF.** A peer that closes without `close_notify` gives a plain end of
  input (`SSL_OP_IGNORE_UNEXPECTED_EOF`); the
  framing above TLS (lines, HTTP lengths) must catch truncation. A
  transport error after the handshake is the TCP read error; a TLS error
  after it is "error reading from stream port" with `EPROTO`.
- **Close.** `TCP.close` and a timeout send `close_notify` with one
  `uv_try_write` when the handshake finished and no write is pending, then
  close as TCP does. The end of the run does not close sockets one by one
  (10.2.2): `agc_io_goodbye` calls the `goodbye` hook `tcp.c` sets on each
  socket resource, which sends that same one write, and `_exit` closes the
  descriptor. An `HttpClient` has the same hook for its idle and active
  connections (10.7.1).
- **Messages** have these shapes: "ssl-connect: connect failed
  (detail)", "port->ssl-ports: accept failed (detail)",
  "ssl-load-certificate-chain!: load failed from: \"path\" (detail)",
  "ssl-load-private-key!: ..." (also for a key that does not match the
  certificate), "ssl-load-verify-source!: ..." for `ca_file`; a system
  error (a missing file) ends with the usual "system error: ...;
  errno=N" lines instead of a detail. Only the `Result` error kind is fixed; the detail is OpenSSL's text.
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
- **Timeouts and limits.** After a timed-out read or write the next
  call returns "network: socket is closed" at once, and a line over 1 MiB
  closes the socket, as for TCP. A missing or empty `ca_file` fails at
  connect with its own message.

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
  `TCP.local_port` still answers after `close_listener`.
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
  `AI_PASSIVE`, then listens on every address, as the grammar says
  (backlog 128; libuv sets `SO_REUSEADDR`). The first address that binds fixes the port (read with
  `uv_tcp_getsockname` when the program asked for port 0); every other
  address binds to that same port. Duplicate addresses are skipped, and
  so are addresses that fail with `EADDRNOTAVAIL` or `EAFNOSUPPORT` (an
  IPv6 address on a host without IPv6). Any other failure closes every
  handle and fails the listen; when the program asked for port 0 and a
  later address finds the chosen port in use, the VM starts again with a
  new port, up to 8 times. With more than one address, IPv6 handles are
  `IPV6_V6ONLY`, so `::` and `0.0.0.0` can share a port. It has no
  timeout. The `io` trace event `tcp_listen` names
  the port and the number of bound addresses.
- **Accept.** "listener is closed" is checked first, then the timeout.
  Waiting accepts form one FIFO for all of the
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
  about 4 KiB past what the program asked for. `recv_bytes` returns what is buffered, up to its count, as soon
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
  limit, as the grammar says; `send_bytes` checks byte values and the 1
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
  the grammar says; waiting for the lock alone does not. A timed-out
  connect closes the half-open socket. A timed-out accept leaves the
  listener open.
- **Close.** `TCP.close` and `TCP.close_listener` are idempotent: they
  unregister the resource, close the link (`uv_close`: a pending write
  ends with `ECANCELED`, a pending connect is cancelled), cancel a lookup
  that has not started, free the input buffer and wake every waiting
  request, which returns "network: socket is closed" or "network:
  listener is closed". Data the program never read makes
  the kernel answer with RST instead of FIN.
- **End of run.** Sockets and listeners are not closed one by one: the
  one exit path (10.2.2) drains nothing and ends with `_exit`, so the OS
  closes them, also while reads, writes, accepts and connects are parked
  (`main` returned, `System.exit`, a runtime error, the step limit, a stop
  signal). A peer sees FIN, or RST when data was left unread; a TLS peer
  gets no `close_notify`. A DNS lookup still running in the pool is not
  waited for.
- **Fuzzing.** Under `no_files` (the fuzzer), `TCP.connect` and
  `TCP.listen` end the run with `RUNTIME-INTERNAL`, so a mutant never
  touches the network. The other TCP builtins need a handle from these
  two.
- **Messages.** The VM's own texts start with `network:` (timeouts,
  closed socket or listener, end of input, the line limit, the read
  size, byte values, `port must be 1..65535` for connect and `0..65535`
  for listen, `host cannot contain NUL`). Connect and listen failures
  have the shape `tcp-connect: connection failed` or `tcp-connect:
  host not found` (and `tcp-listen: listen failed` or `tcp-listen: host
  not found`), then `hostname:` and `port number:` lines and the system
  error (`errno=N` for OS errors, libuv's text for resolver errors).
- **Behavior notes.**
  - After a timed-out read or write closes a socket, the next call
    returns "network: socket is closed" at once, as the grammar says.
    TLS sockets behave the same way (10.3).
  - A `read_line` over 1 MiB closes the socket, as the grammar says. TLS
    sockets behave the same way (10.3).
  - A host with a NUL byte is an error.
  - A port out of range returns the VM's own message.
  - `TCP_NODELAY` is on for every socket. Each `send` already flushes, so
    batching is the program's choice, and a write, write, read exchange
    never waits for a delayed ACK.
  - libuv accepts one connection ahead into its own slot while no task is
    in `accept`; the kernel had completed that connection anyway.

