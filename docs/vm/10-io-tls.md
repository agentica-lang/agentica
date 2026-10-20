### 10.3 TLS

`TLS.connect` and `TLS.listen` run on the VM, on Linux and macOS. Windows
builds the adapter and the trust store but refuses TLS sockets: the context
build fails with `TLS needs Linux or macOS` (`agc_net_tls_enabled`,
`vm/net_os.h`) until the Windows TLS socket tests pass. The release links the vendored
OpenSSL 3.5 LTS statically, and a default source build links the system OpenSSL
3 (`AGENTICA_OPENSSL`, 10.0). The adapter sets its own minimums and reads no
`openssl.cnf`, so both builds behave the same.

- **Adapter.** `vm/tls.h` declares our own types only. `vm/tls_openssl.c`,
  `vm/tls_trust.c` and `vm/tls_trust_posix.c` are the only files that include
  OpenSSL headers. A session uses two memory BIOs, and
  every call returns OK, WANT_READ, WANT_WRITE, CLOSED or ERROR. An error
  carries our code, an `errno` for a system error, and a short detail. OpenSSL's
  error queue is drained in the adapter, and OpenSSL never gets a GC pointer.
- **Error codes** (`agc_tls_error`): `VERIFY_UNTRUSTED`, `VERIFY_EXPIRED`,
  `VERIFY_HOSTNAME`, `VERIFY_FAILED` (any other verify result),
  `HANDSHAKE_FAILED`, `NO_SHARED_VERSION_OR_CIPHER`, `UNEXPECTED_EOF` (the peer
  closed during the handshake), `PROTOCOL` (an error after the handshake),
  `BAD_CA`, `BAD_CERT`, `BAD_KEY`, `KEY_MISMATCH`, `NOMEM` and `INTERNAL`.
- **Setup.** `TLS.connect` checks the timeout, port and host as `TCP.connect`
  does, and rejects a NUL in `ca_file`. `TLS.listen` checks as `TCP.listen`
  does, and rejects a NUL in either path. One pool job then reads the CA,
  certificate and key files, off the scheduler thread, and only then does the VM
  resolve and connect or listen. So a bad certificate or key fails `TLS.listen`
  before the port is bound. The connect timeout covers the setup, lookup,
  connect and handshake.
- **Minimums.** TLS 1.2 and security level 2 (RSA keys of at least 2048 bits) on
  every context. Renegotiation is off.
- **Trust (security rule).** A non-empty `ca_file` replaces system trust. A
  missing or empty file fails the connect with `BAD_CA`. With an empty
  `ca_file`, the trust is `SSL_CERT_FILE` when set, else the system store of
  the platform (`vm/tls_trust.h`). The directory is `SSL_CERT_DIR` when set,
  else none. A source that fails to load is skipped; verification still fails
  closed.
  - The system store is read once per process (`vm/tls_trust.c`, under
    `CRYPTO_THREAD_run_once`, in the first setup pool job that needs it, never
    on the scheduler or I/O thread) and copied into each new context, so a
    trust change while the process runs is not seen. A first load that fails
    also lasts for the whole process, and verification then fails closed.
    This holds on every system, Linux included; there is no retry. Its
    certificates are shared, read-only `X509` objects.
  - A certificate the system distrusts is added with an explicit reject of
    `serverAuth` (`X509_add1_reject_object`), before any trusted copy (the
    store keeps the first copy). OpenSSL's `check_trust` then fails a chain
    through a rejected root or intermediate with `X509_V_ERR_CERT_REJECTED`
    (`crypto/x509/x509_vfy.c`, `obj_trust` in `crypto/x509/x509_trust.c`).
    OpenSSL never looks up the peer's own certificate, so the client's verify
    callback (`agc_tls_trust_verify`) refuses a leaf whose rejected copy is in
    the store. The error is `VERIFY_UNTRUSTED`.
  - Only the certificates are copied. Platform rules beyond them are not
    applied: Apple's date-based distrust and Certificate Transparency policy,
    the constraints trustd puts on system anchors, and the Windows
    `NotBefore` and disallowed-filetime properties.
  - Linux and other POSIX (`tls_trust_posix.c`): the first readable file of
    `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`,
    `/etc/ssl/ca-bundle.pem`, `/etc/pki/tls/cacert.pem`,
    `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`, `/etc/ssl/cert.pem`.
  - macOS (`tls_trust_darwin.c`, Security framework): the user and admin
    trust settings (`SecTrustSettingsCopyCertificates`,
    `SecTrustSettingsCopyTrustSettings`; the user domain overrides the admin
    domain), then the system anchors (`SecTrustCopyAnchorCertificates`). A
    setting counts when its policy is absent or TLS (`kSecPolicyAppleSSL`). An
    empty settings array or a `TrustRoot` result adds a root; `TrustAsRoot` on
    an intermediate has no effect, because without `X509_V_FLAG_PARTIAL_CHAIN`
    (kept off) OpenSSL only ends a chain at a self-signed certificate. A
    `Deny` adds the certificate rejected, so it fails a chain even under a
    system anchor. A grant limited to an application, a host name or a key use
    is ignored. This is stricter than Apple's first-match order, and fails
    closed: any matching `Deny` wins, and a `Deny` limited to one host or
    application rejects the certificate everywhere. No Linux path is read.
  - Windows (`tls_trust_windows.c`, Crypt32): the current user's
    `Disallowed` system store, every certificate added rejected, then the
    `ROOT` store (`CertOpenSystemStoreW`; both views include the machine's
    stores), each certificate whose valid uses (`CertGetEnhancedKeyUsage`)
    include server authentication. A root that Windows would download on
    demand (automatic root update) is not in the store until Windows fetched
    it; `SSL_CERT_FILE` or `ca_file` covers that case.
- **Verification (security rule).** The client always verifies the peer. There
  is no verify-none path. An IP-literal host is checked against IP SANs and
  sends no SNI. Any other host gets SNI and hostname verification, with no
  partial wildcards. The server does not ask for client certificates.
- **Data path.** A TLS socket is the TCP socket of 10.3.1 with a session.
  Decrypted bytes go into the socket's input buffer, so `read_line`,
  `recv_bytes`, the 1 MiB limits, the locks and the timeouts are exactly the TCP
  ones. Sends are encrypted in 16 KiB pieces, and the next piece waits for the
  previous write. A failed write is sticky.
- **Accept.** A waiting `TCP.accept` on a TLS listener runs the server handshake
  under its own timeout, and returns the socket only when the handshake is done.
  A failed handshake returns `port->ssl-ports: accept failed (...)`, and the
  listener stays open. A write error or a failed read during the handshake fails
  it at once with that system error, never as a timeout, and it is reported
  once.
- **EOF (security rule).** A peer that closes without `close_notify` gives a
  plain end of input (`SSL_OP_IGNORE_UNEXPECTED_EOF`). Framing above TLS (lines,
  HTTP lengths) must catch truncation. A TLS error after the handshake is
  `error reading from stream port` with `EPROTO`.
- **Close.** `TCP.close` and a timeout send `close_notify` with one
  `uv_try_write` when the handshake finished and no write is pending, then close
  as TCP does. At the end of the run the same single write goes to each finished
  TLS socket (§10.2.2), and `HttpClient` connections get it too (10.7.1).
- **Messages.** `ssl-connect: connect failed (detail)`,
  `port->ssl-ports: accept failed (detail)`,
  `ssl-load-certificate-chain!: load failed from: "path" (detail)`,
  `ssl-load-private-key!: ...` (also for a key that does not match the
  certificate), and `ssl-load-verify-source!: ...` for `ca_file`. Only the
  `Result` error kind is fixed. A verify failure's detail reads
  `certificate verify failed: <X.509 text>` (the tests match it); other details
  are OpenSSL's text.
- **Trace** (`tls` category, `docs/vm/08-loader-and-cli.md` §9):
  `tls_handshake`, `tls_handshake_done`, `tls_handshake_error`,
  `tls_setup_error`, `tls_read_error`, `tls_close`.
- **Turn costs and fuzzing.** TLS sockets use the TCP builtins, so they charge
  by size (10.2.1). `TLS.connect` and `TLS.listen` charge nothing. Under
  `no_files` both end the run with `RUNTIME-INTERNAL`.
- **Tests.** `vm/tests/tls_test.c` runs two in-memory adapters against each
  other, covering the handshake, `close_notify`, raw EOF, every verify error,
  the load errors, the trust sources (system store, `SSL_CERT_FILE`, and
  `ca_file` over both), rejected roots and leaves (through `X509_verify_cert`
  and a handshake), and a client config that holds the system store with a root
  that verifies (required on macOS and Windows). It needs no socket, so it runs
  on Linux, macOS and Windows. The platform policies have their own tests:
  `vm/tests/tls_trust_darwin_test.c` (trust settings arrays: empty, missing
  result, Deny, narrow grants, Unspecified, other policies) and
  `vm/tests/tls_trust_windows_test.c` (EKU properties on in-memory Crypt32
  stores, and a Disallowed copy that wins over ROOT). The goldens `tls-echo` and
  `tls-errors` are their own peers. `tests/test_vm_tls.py` covers the rest
  against Node (`tests/fixtures/tls-peer.js`) and Python
  (`tests/fixtures/tls-peer.py`): EOF with and without `close_notify`, the 1 MiB
  limit, every verify error on both sides, timeouts, and system trust through
  `SSL_CERT_FILE`. The certificates in `tests/fixtures/tls/` come from
  `make-certs.sh`.

### 10.3.1 TCP (as built)

**As built (TCP PR).** `vm/tcp.c` holds the ten `TCP` builtins, built on
Linux, macOS and Windows. `vm/stream.c` holds what they share with
`vm/process.c`: the input buffer, the write path, the lock-or-timeout helper
and the `network:` texts. Other systems get no `TCP` builtins.

- **Values.** A `Socket` is a GC value with a registered state and two lock
  records, `reader` and `writer`. `read_line` and `recv_bytes` take the reader
  lock, and `send` and `send_bytes` the writer lock, both through
  `agc_handle_wait`, so one deadline covers the lock wait and the operation. A
  `Listener` keeps its bound port, so `TCP.local_port` still answers after
  `close_listener`.
- **Ownership.** The socket's native state is freed when its users (the resource
  and each request) and its callbacks (a DNS lookup, one close callback per
  link) are all done, so no callback sees freed memory. It is registered before
  any libuv work, so the end of the run finds every handle. Each operation parks
  only its task, on an external job.
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
  handles are `IPV6_V6ONLY`. Listen has no timeout.
- **Accept.** `listener is closed` is checked first, then the timeout. Waiting
  accepts form one FIFO for all of a listener's handles, and a connection is
  accepted only into the head waiter's `done` half, so it never waits without an
  owner. If `uv_accept` fails, or libuv reports an accept error (only Windows
  does, once it has stopped listening on that handle), the listener is closed:
  the head accept returns the error, and every other waiting accept returns
  `network: listener is closed`. A
  timed-out accept leaves the listener open.
- **Reads.** `recv_bytes` checks 1..1048576 first, then the timeout, the reader
  lock and the open state. The socket is read only while a reader waits, 4 KiB
  at a time (more when the request asks for more), so the VM reads at most about
  4 KiB past what the program asked. `recv_bytes` returns what is buffered, as
  soon as there is one byte, and `ok([])` at EOF. `read_line` strips LF or CRLF,
  returns a final line without a terminator at EOF (a lone CR stays), and
  returns `network: end of input` on an empty EOF. A line over 1 MiB returns
  `network: line exceeds 1048576 bytes` and closes the socket. Invalid UTF-8
  returns the `bytes->string/utf-8` error, and the line is consumed. A read
  error (`ECONNRESET`) returns `error reading from stream port`, and later reads
  return it too. Bytes that arrived before the error are still returned.
- **Writes.** `send` writes the UTF-8 bytes of its String with no size limit, as
  the grammar says. `send_bytes` checks byte values and the 1 MiB limit first.
  The bytes go out with `uv_try_write`, the rest with one `uv_write`, and the
  task parks until the callback. `ok()` means every byte reached the kernel's
  send buffer. A failed write (`EPIPE`, `ECONNRESET`) returns
  `error writing to stream port` and leaves the socket open.
- **Turn costs.** `send`, `send_bytes`, `recv_bytes` and `read_line` charge by
  size (10.2.1), also when the call parks.
- **Timeouts.** A timed-out read or write closes the socket. Waiting for the
  lock alone does not. A timed-out connect closes the half-open socket. After
  that, the next call returns `network: socket is closed` at once.
- **Close.** `TCP.close` and `TCP.close_listener` are idempotent. They close the
  link (a pending write ends with `ECANCELED`), free the input buffer, and wake
  every waiting request with `network: socket is closed` or
  `network: listener is closed`. Data the program never read makes the kernel
  answer with RST instead of FIN.
- **End of run.** Sockets and listeners are not closed one by one: the exit path
  (10.2.2) ends with `_exit`, so the OS closes them, also while operations are
  parked. A peer sees FIN, or RST when data was left unread. A DNS lookup still
  running in the pool is not waited for.
- **Messages.** The VM's own texts start with `network:`: timeouts, closed
  socket or listener, end of input, the line limit, the read size, byte values,
  `port must be 1..65535` (connect) or `0..65535` (listen), and
  `host cannot contain NUL`. Connect and listen failures are
  `tcp-connect: connection failed` or `tcp-connect: host not found` (and
  `tcp-listen: ...`), with `hostname:` and `port number:` lines and the system
  error.
- **Platforms.** The code is shared; libuv hides the socket types. What it
  does not hide:
  - *Error numbers.* `vm/net_os.h` maps a libuv error to the errno the
    message shows: the negated code on POSIX, the UCRT's errno on Windows
    (`ECONNREFUSED` 107, `ECONNRESET` 108), whose `strerror` names it. Texts
    and numbers differ per system; the message head does not.
  - *Accept.* On Unix libuv reports one connection and waits for `uv_accept`;
    on Windows several `AcceptEx` requests can complete first, so each link
    counts the connections reported and not taken.
  - *Bind.* libuv sets `SO_REUSEADDR` on Unix listeners and nothing on
    Windows, where that option would let another socket take a bound port and
    `SO_EXCLUSIVEADDRUSE` would refuse a port with connections in
    `TIME_WAIT`. So on Windows a listener on a specific address can bind a
    port that another program of the same user holds on the wildcard address,
    where Linux refuses it; two listeners on the same address conflict on
    every system.
  - *Send buffers.* How many bytes the kernel takes before a send parks is
    the host's: on the Windows CI runner one 32 MiB send to a peer that does
    not read returns `ok()` at once, where Linux and macOS park it until the
    timeout.
  - *Refusal.* Windows resends a SYN that a closed port refused before it
    reports `ECONNREFUSED`, so a refused connect, and a name whose first
    address refuses (`localhost` to an IPv4-only server), take longer there;
    the connect timeout covers them.
- **Fuzzing.** Under `no_files`, `TCP.connect` and `TCP.listen` end the run with
  `RUNTIME-INTERNAL`, and the other TCP builtins need a handle from these two.
