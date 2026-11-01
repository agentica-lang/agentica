### 10.3 TLS

`TLS.connect` and `TLS.listen` run on the VM, on Linux, macOS and Windows, over
the TCP sockets of 10.3.1 (libuv on every system). The release links the
vendored OpenSSL 3.5 LTS statically, and a default source build links the system
OpenSSL 3 (`AGENTICA_OPENSSL`, 10.0). The adapter sets its own minimums and
reads no `openssl.cnf`, so both builds behave the same.

- **Adapter.** `vm/tls.h` declares our own types only, so no OpenSSL type leaves
  the adapter files. A session uses two memory BIOs, and every call returns OK,
  WANT_READ, WANT_WRITE, CLOSED or ERROR. An error carries our code, an `errno`
  for a system error, and a short detail. The adapter drains OpenSSL's error
  queue, and OpenSSL never gets a GC pointer.
- **Error codes** (`agc_tls_error` in `vm/tls.h`): `VERIFY_FAILED` is any verify
  result other than untrusted, expired or hostname, `UNEXPECTED_EOF` is a peer
  that closed during the handshake, and `PROTOCOL` is an error after the
  handshake.
- **Contexts.** A `TlsContext` (`AGC_T_TLS_CONTEXT`, `vm/tls_context.c`) holds
  one `agc_tls_config` of one role, which counts its owners: the context and
  each socket and listener made from it. So a dropped context stays valid
  until its last socket closes. A GC finalizer gives the context's count back;
  the collector runs finalizers only on demand, at the start of a scheduler's
  next task (`agc_gc_finalize_pending`), never inside an allocation (§5.3).
  The GC does not see the native size of an `SSL_CTX`, so a program builds a
  context once and reuses it. `TLS.client_context` and
  `TLS.server_context` check the options (a NUL in a path, a `cert_file`
  without a `key_file` or the reverse, a server context without both), then
  one pool job with no deadline reads the CA, certificate and key files off the
  scheduler thread. So a bad file fails the context build, never a connect or
  a listen. Both roles load the chain and key the same way (`use_identity` in
  `vm/tls_openssl.c`). A context of the wrong role (a server context for
  `TLS.connect` or `HttpClientOptions.tls`, a client one for `TLS.listen`) is a
  program bug: `RUNTIME-TLS-CONTEXT-ROLE` at the context argument.
- **Setup.** `TLS.connect` checks the timeout, port and host as `TCP.connect`
  does, and `TLS.listen` as `TCP.listen` does; neither reads a file. The
  connect timeout covers the lookup, connect and handshake. An `HttpClient`
  without a context (`HttpWire.connect_tls`) builds one system-trust context
  lazily, in a pool job, the first time it connects, and its connections share
  it.
- **Upgrade.** `TLS.upgrade` (STARTTLS) makes a new TLS socket, whose role is
  the context's; a server context with a host is `RUNTIME-TLS-CONTEXT-ROLE` at
  the host. After the argument checks, the plain socket's resource lets its
  `net` go to the request, so the program sees that socket closed. The
  request's START step on the I/O thread moves the libuv handle to the new
  `net` and closes the plain one, then handshakes as a connect or an accept
  does, under the call's timeout. Bytes the plain `net` read and nobody took,
  a send in flight (its write request lives in the plain `net`), or an ended
  input refuse the move; the plain socket is closed anyway.
- **Minimums.** TLS 1.2 and security level 2 (RSA keys of at least 2048 bits) on
  every context. Renegotiation is off.
- **Trust (security rule).** A non-empty `ca_file` replaces system trust. A
  missing or empty file fails `TLS.client_context` with `BAD_CA`. With an empty
  `ca_file`, the trust is `SSL_CERT_FILE` when set, else the platform's system
  store (`vm/tls_trust.h`). `SSL_CERT_DIR`, when set, adds a directory to
  either; with a `ca_file` it is not read. A source that fails to load is
  skipped, and verification still fails closed.
  - The system store is read once per process (`vm/tls_trust.c`, under
    `CRYPTO_THREAD_run_once`, in the first context pool job that needs it, never
    on the scheduler or I/O thread) and copied into each new context, so a trust
    change while the process runs is not seen. A first load that fails lasts for
    the whole process, and verification then fails closed. This holds on every
    system, Linux included; there is no retry.
  - A certificate the system distrusts is added with an explicit reject of
    `serverAuth` (`X509_add1_reject_object`), before any trusted copy, since the
    store keeps the first copy. OpenSSL's `check_trust` then fails a chain
    through a rejected root or intermediate with `X509_V_ERR_CERT_REJECTED`.
    OpenSSL never looks up the peer's own certificate, so the client's verify
    callback (`agc_tls_trust_verify`) refuses a leaf whose rejected copy is in
    the store. The error is `VERIFY_UNTRUSTED`.
  - Only the certificates are copied. The platform rules beyond them are not
    applied: Apple's date-based distrust and Certificate Transparency policy,
    the constraints trustd puts on system anchors, and the Windows `NotBefore`
    and disallowed-filetime properties.
  - Linux and other POSIX (`tls_trust_posix.c`): the first readable file of the
    CA bundle paths listed there. No other path is read.
  - macOS (`tls_trust_darwin.c`, Security framework): the user and admin trust
    settings, then the system anchors. The user domain overrides the admin
    domain. A setting counts when its policy is absent or TLS. An empty settings
    array or a `TrustRoot` result adds a root. `TrustAsRoot` on an intermediate
    has no effect, because without `X509_V_FLAG_PARTIAL_CHAIN` (kept off)
    OpenSSL ends a chain only at a self-signed certificate. A `Deny` adds the
    certificate as rejected, so it fails a chain even under a system anchor. A
    grant limited to an application, a host name or a key use is ignored. This
    is stricter than Apple's first-match order and fails closed: any matching
    `Deny` wins, and a `Deny` limited to one host rejects the certificate
    everywhere.
  - Windows (`tls_trust_windows.c`, Crypt32): the current user's `Disallowed`
    store first, every certificate in it added rejected. Then the `ROOT` store
    (`CertOpenSystemStoreW`), each certificate whose valid uses include server
    authentication, then the `CA` store as intermediates, as CPython's
    `ssl.load_default_certs` reads `ROOT` and `CA`. Every view includes the
    machine's stores. A `CA` certificate is only a chain certificate, never an
    anchor:
    - one whose subject equals its issuer is left out
      (`agc_tls_trust_add_intermediate_der`), since OpenSSL trusts a self-signed
      certificate in the store. So a server that sends only its leaf still
      verifies when Windows keeps its intermediate;
    - a copy with the subject and public key of a self-signed anchor already in
      the store is left out, because OpenSSL looks issuers up by name and the
      store order is not stable;
    - one whose EKU extension excludes server authentication is left out, on
      every system: OpenSSL would take a store copy first, and a valid
      intermediate's sibling with the same subject and key would fail a chain
      the server sends correctly;
    - one whose Crypt32 EKU property alone excludes server authentication is
      added rejected, so a server that sends it still fails with
      `VERIFY_UNTRUSTED`. It also shadows same-key siblings, which is taken as
      the administrator's intent.

A root that Windows would download on demand is not in the store until
Windows fetched it; `SSL_CERT_FILE` or `ca_file` covers that case.
- **Verification (security rule).** The client always verifies the peer; there
  is no verify-none path. An IP-literal host is checked against IP SANs and
  sends no SNI. Any other host gets SNI and hostname verification, with no
  partial wildcards. The server does not ask for client certificates.
- **ALPN.** The `alpn` field of the options goes into the context in the wire
  form of RFC 7301, checked when the context is built (each name 1 to 255
  bytes, the list at most 65535 bytes). A client context offers it
  (`SSL_CTX_set_alpn_protos`). A server context selects the first of its own
  protocols that the client offers too (`SSL_select_next_proto` in its select
  callback, whose argument is the config, so each accepted connection holds its
  own count on the config), and fails the handshake with the
  `no_application_protocol` alert when there is none; a client that offers no
  ALPN gets none. When the handshake ends, the I/O thread stores the selected
  name in the socket's `net` (an atomic pointer, set once), which `TLS.alpn`
  reads: `""` for none, a plain socket or a closed one. The config also records
  whether its list is none or exactly `http/1.1`: std/http speaks only
  HTTP/1.1, so `HttpWire.service`, `HttpWire.connect_context`,
  `HttpWire.upgrade_context` and `HttpWire.server` halt with
  `RUNTIME-TLS-CONTEXT-ALPN` on any other list.
- **CONNECT tunnels (std-only).** std/http reaches an `https://` target through a
  proxy with a TCP socket that a CONNECT made a pipe, and starts TLS on it with
  `TLS.upgrade`'s machinery, under two names: `HttpWire.upgrade_context(socket,
  context, host, timeout_ms)` for a client `TlsContext` (the `TLS.upgrade` of
  a client context plus the ALPN check above), and `HttpWire.upgrade_tls(client,
  socket, host, timeout_ms)` for the client's shared system-trust context of
  `HttpWire.connect_tls`: the upgraded net takes a count on it (an error when
  the client gave it back), and its handshake starts when the context is built,
  as a connect's DNS does.
- **Data path.** A TLS socket is the TCP socket of 10.3.1 with a session.
  Decrypted bytes go into the socket's input buffer, so `read_line`,
  `recv_bytes`, the 1 MiB limits, the locks and the timeouts are the TCP ones.
  Sends are encrypted in 16 KiB pieces, and each piece waits for the previous
  write. A failed write is sticky.
- **Accept.** A waiting `TCP.accept` on a TLS listener runs the server handshake
  under its own timeout, and returns the socket only when the handshake is done.
  A failed handshake returns `port->ssl-ports: accept failed (...)`, and the
  listener stays open. A write error or a failed read during the handshake fails
  it at once with that system error, never as a timeout, and it is reported
  once.
- **EOF (security rule).** A peer that closes without `close_notify` gives a
  plain end of input (`SSL_OP_IGNORE_UNEXPECTED_EOF`). Framing above TLS (lines,
  HTTP lengths) must catch truncation. A TLS error after the handshake is `error
  reading from stream port` with `EPROTO`.
- **Close.** `TCP.close` and a timeout send `close_notify` with one
  `uv_try_write` when the handshake finished and no write is pending, then close
  as TCP does. At the end of the run the same single write goes to each finished
  TLS socket (§10.2.2), and `HttpClient` connections get it too (10.7.1).
- **Messages.** Only the `Result` error kind is fixed. A verify failure's detail
  reads `certificate verify failed: <X.509 text>` (the tests match it); other
  details are OpenSSL's text. The VM's own prefixes are `ssl-connect:`,
  `port->ssl-ports:`, `ssl-load-certificate-chain!:`, `ssl-load-private-key!:`
  (also for a key that does not match the certificate) and
  `ssl-load-verify-source!:` (for `ca_file`).
- **Turn costs and fuzzing.** TLS sockets use the TCP builtins, so they charge
  by size (10.2.1). `TLS.connect`, `TLS.listen` and the context builds charge
  nothing. Under `no_files` they end the run with `RUNTIME-INTERNAL`.
- **Tests.** `vm/tests/tls_test.c` runs two in-memory adapters against each
  other, with no socket, so it runs on all three systems. The platform trust
  policies have their own tests (`vm/tests/tls_trust_darwin_test.c`,
  `vm/tests/tls_trust_windows_test.c`). The goldens `tls-echo` and `tls-errors`
  are their own peers. `tests/test_vm_tls.py` covers the rest against Node
  (`tests/fixtures/tls-peer.js`) and Python (`tests/fixtures/tls-peer.py`) on
  all three systems. The certificates in `tests/fixtures/tls/` come from
  `make-certs.sh`.

### 10.3.1 TCP (as built)

**As built.** `vm/tcp.c` holds the `TCP` builtins, on Linux, macOS and Windows;
other systems get none. `vm/stream.c` holds what they share with `vm/process.c`:
the input buffer, the write path, the lock-or-timeout helper and the `network:`
texts.

- **Values.** A `Socket` is a GC value with a registered state and two lock
  records, `reader` and `writer`. `read_line` and `recv_bytes` take the reader
  lock, and `send` and `send_bytes` the writer lock, both through
  `agc_handle_wait`, so one deadline covers the lock wait and the operation. A
  `Listener` keeps its bound port, so `TCP.local_port` still answers after
  `close_listener`.
- **Ownership.** The native state is freed when its users (the resource and each
  request) and its callbacks (a DNS lookup, one close callback per link) are all
  done, so no callback sees freed memory. It is registered before any libuv
  work, so the end of the run finds every handle. Each operation parks only its
  task, on an external job.
- **Connect.** The timeout, port (1..65535) and host (no NUL) are checked. The
  host resolves (`AF_UNSPEC`, `SOCK_STREAM`), and each address is tried in order
  until one connects. One timer covers the lookup and every try. On timeout the
  call returns `network: operation timed out`. `TCP_NODELAY` is set on every
  connected and accepted socket.
- **Listen.** The port (0..65535) and host are checked. The listener binds every
  resolved address with backlog 128. The first address that binds fixes the port
  (read back for port 0), and the others bind to that port. Duplicate addresses
  are skipped, and so are `EADDRNOTAVAIL` and `EAFNOSUPPORT` (an IPv6 address on
  a host without IPv6). Any other failure closes every handle and fails the
  listen. For port 0, if a later address finds the chosen port in use, the VM
  starts again with a new port, up to 8 times. With more than one address, IPv6
  handles are `UV_TCP_IPV6ONLY`. Listen has no timeout.
- **Accept.** `network: listener is closed` is checked first, then the timeout.
  Waiting accepts form one FIFO for all of a listener's handles, and a
  connection is accepted only into the head waiter's `done` half, so it never
  waits without an owner. If `uv_accept` fails, or libuv reports an accept error
  (only Windows does, once it has stopped listening on that handle), the
  listener is closed: the head accept returns the error, and every other waiting
  accept returns `network: listener is closed`. A timed-out accept leaves the
  listener open.
- **Reads.** `recv_bytes` checks 1..1048576 first, then the timeout, the reader
  lock and the open state. The socket is read only while a reader waits, 4 KiB
  at a time (more when the request asks for more), so the VM reads at most about
  4 KiB past what the program asked. `recv_bytes` returns what is buffered, as
  soon as there is one byte, and empty `Bytes` at EOF. `read_line` strips LF or
  CRLF, returns a final line without a terminator at EOF (a lone CR stays), and
  returns `network: end of input` on an empty EOF. A line over 1 MiB returns
  `network: line exceeds 1048576 bytes` and closes the socket. Invalid UTF-8
  returns the `bytes->string/utf-8` error, and the line is consumed. A read
  error (`ECONNRESET`) returns `error reading from stream port`, and later reads
  return it too. Bytes that arrived before the error are still returned.
- **Writes.** `send` writes the UTF-8 bytes of its String with no size limit, as
  the grammar says. `send_bytes` checks the 1 MiB limit first. `send_bytes`,
  `recv_bytes` and the HttpWire byte rows take and give `Bytes`, under the
  catalog key `<name>.bytes`.
  The bytes go out with `uv_try_write`, the rest with one `uv_write`, and the
  task parks until the callback. `ok()` means every byte reached the kernel's
  send buffer. A failed write (`EPIPE`, `ECONNRESET`) returns `error writing to
  stream port` and leaves the socket open.
- **Turn costs.** `send`, `send_bytes`, `recv_bytes` and `read_line` charge by
  size (10.2.1), also when the call parks.
- **Timeouts.** A timed-out read or write closes the socket. Waiting for the
  lock alone does not. A timed-out connect closes the half-open socket. After
  that, the next call returns `network: socket is closed` at once.
- **Close.** `TCP.close` and `TCP.close_listener` are idempotent. They close the
  link (a pending write ends with `ECANCELED`), free the input buffer, and wake
  every waiting request with `network: socket is closed` or `network: listener
  is closed`. Data the program never read makes the kernel answer with RST
  instead of FIN.
- **End of run.** Sockets and listeners are not closed one by one. The exit path
  (10.2.2) ends with `_exit`, so the OS closes them, also while operations are
  parked. A peer sees FIN, or RST when data was left unread. A DNS lookup still
  running in the pool is not waited for.
- **Messages.** The VM's own texts start with `network:`: timeouts, closed
  socket or listener, end of input, the line limit, the read size, byte values,
  `port must be 1..65535` (connect) or `0..65535` (listen), and `host cannot
  contain NUL`. Connect and listen failures are `tcp-connect: connection failed`
  or `tcp-connect: host not found` (and `tcp-listen: ...`), with `hostname:` and
  `port number:` lines and the system error.
- **Platforms.** The code is shared; libuv hides the socket types. What it does
  not hide:
  - *Error numbers.* `vm/net_os.h` maps a libuv error to the errno the message
    shows: the negated code on POSIX, the UCRT's errno on Windows
    (`ECONNREFUSED` 107, `ECONNRESET` 108), whose `strerror` names it. Texts and
    numbers differ per system; the message head does not.
  - *Accept.* On Unix libuv reports one connection and waits for `uv_accept`; on
    Windows several `AcceptEx` requests can complete first, so each link counts
    the connections reported and not taken.
  - *Bind.* libuv sets `SO_REUSEADDR` on Unix listeners and nothing on Windows,
    where that option would let another socket take a bound port, and
    `SO_EXCLUSIVEADDRUSE` would refuse a port with connections in `TIME_WAIT`.
    So on Windows a listener on a specific address can bind a port that another
    program of the same user holds on the wildcard address, where Linux refuses
    it; two listeners on the same address conflict on every system.
  - *Send buffers.* How many bytes the kernel takes before a send parks is the
    host's: on the Windows CI runner one 32 MiB send to a peer that does not
    read returns `ok()` at once, where Linux and macOS park it until the
    timeout.
  - *Refusal.* Windows resends a SYN that a closed port refused before it
    reports `ECONNREFUSED`, so a refused connect, and a name whose first address
    refuses (`localhost` to an IPv4-only server), take longer there; the connect
    timeout covers them.
- **Fuzzing.** Under `no_files`, `TCP.connect` and `TCP.listen` end the run with
  `RUNTIME-INTERNAL`, and the other TCP builtins need a handle from these two.
