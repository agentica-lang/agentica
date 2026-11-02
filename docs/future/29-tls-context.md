## 29. TLS contexts

**Status:** built: 19a (`TlsContext`, one breaking step for `TLS` and `HTTP`),
19b (`TLS.upgrade`) and 19c (ALPN), roadmap phase 19, decided by the user on
2026-10-12, as part of order step 7.4. The contract is the grammar
([`06d-io-and-network.md`](../grammar/06d-io-and-network.md)) and the network
library page; this section keeps the decisions, the VM design and the later
options. Differences from the first design, decided by the owner:

- The options are records, `TlsClientOptions(ca_file = "", cert_file = "",
  key_file = "", alpn = [])` (the client certificate of mTLS stays) and
  `TlsServerOptions(cert_file, key_file, alpn = [])`, with no
  `TLS.client_options()` helper.
- `HttpClientOptions.tls` is an `Optional[TlsContext] = none` in place of
  `ca_file`; with `none` each client builds its own system-trust context lazily.
  The `listen_*_tls` forms take a server context.
- `TLS.upgrade`: argument checks (a closed or TLS socket, the timeout, an empty
  host for a client context) are `error` results that leave the socket open, and
  a send in progress on the plain socket fails the upgrade as unread bytes do.
- ALPN: a server picks the first of its own protocols that the client offers too
  and refuses the handshake when none is in common. `std/http` speaks only
  HTTP/1.1, so it halts with `RUNTIME-TLS-CONTEXT-ALPN` on a context whose
  `alpn` is not `[]` or `["http/1.1"]`.

**What was asked for:** an opaque handle like Python's `ssl.SSLContext`, built
once and reused by many connections, so the CA bundle is loaded once and TLS
options have one home instead of new arguments on every call. Before it, every
call named its trust or key pair by file path, so the runtime either parsed the
files on every call (a system bundle is about 150 certificates) or kept a hidden
cache keyed by path, which goes stale when a file changes.

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms).
The security rules of `docs/vm/10-io-tls.md` §10.3 do not move: certificates are
always verified, the hostname is always checked, and no path turns verification
off.

### 29.1 The API

```text
TLS.client_context(options: TlsClientOptions) -> Result[TlsContext]
TLS.server_context(options: TlsServerOptions) -> Result[TlsContext]
TLS.connect(host: String, port: Int, context: TlsContext, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, context: TlsContext) -> Result[Listener]
TLS.upgrade(socket: Socket, context: TlsContext, host: String, timeout_ms: Int) -> Result[Socket]
```

**Decisions:**

- **Options records, not arguments.** A context is built from one immutable
  record per role, as `HTTP.client_options()` and `HttpClientOptions` work. A new
  option is a new field, never a new argument or builder, so default parameter
  values never have to change these calls. A new field breaks code that
  constructs the record with every field named, so the skill teaches `with`
  (15c): `TlsClientOptions().with(ca_file: "ca.pem")`.
- **One type, two roles.** `TlsContext` is one opaque type, like `SSLContext`,
  with its role fixed at creation. Two types would catch a mix-up at check time
  but double the names for a mistake that fails at the first call anyway. A
  server context passed to `TLS.connect` or `HTTP.client`, or a client context to
  `TLS.listen` or `HTTP.listen_tls`, is a program bug, not an I/O failure, so it
  is the diagnostic `RUNTIME-TLS-CONTEXT-ROLE` at the context argument (for
  `std/http` functions the span points inside `std/http.agc`, and the message
  names the `HTTP` function).
- **Errors come early.** `client_context` and `server_context` read and check
  their files when called: a missing file, a file with no certificate, a bad
  key, a key that does not match the certificate (`SSL_CTX_check_private_key`)
  and an empty `cert_file` or `key_file` are `error` results there, not at the
  first connect or accept. An empty `ca_file` means system trust; a non-empty
  one replaces it. Trust is loaded once, into the context.
- **Per connection:** `TLS.connect` and `TLS.upgrade` set SNI and `SSL_set1_host`
  from `host` (an IP literal goes through `X509_VERIFY_PARAM_set1_ip_asc` and
  sends no SNI). The context holds no hostname, so one context serves every host.
- **Fixed policy, no knobs:** verification, the hostname check, the version floor,
  ciphers and groups of §10.3 (29.7).
- **No defaults, no close.** No call is better with a default parameter (the
  system-trust case is `TLS.client_context(TlsClientOptions())`). A context has
  no `close`: it holds no socket or descriptor, only memory, and a context a
  connection still uses must stay valid (29.6).

**Effects:** `network`; `client_context` and `server_context` read files, so
`--deny-fs` turns them off.

### 29.2 Sharing and immutability

A context never changes after it is built (no builtin sets an option on it, and
OpenSSL allows any number of `SSL` objects from one `SSL_CTX` at once as long as
nobody changes it). So it can be stored in a struct, captured by a block, passed
to many tasks and used by many connections at once with no lock, also with the
multicore schedulers (`docs/vm/10-io-multicore.md` §10.2.3).

### 29.3 STARTTLS: `TLS.upgrade`

Some protocols start in plain text and switch to TLS on the same connection
(SMTP and IMAP `STARTTLS`, PostgreSQL's `SSLRequest`). `TLS.upgrade` runs the
handshake over an open TCP socket and returns a new TLS socket.

- **Role from the context.** A client context is the client side and checks
  `host` as `TLS.connect` does; a server context is the server side and `host`
  must be `""` (`RUNTIME-TLS-CONTEXT-ROLE` otherwise, at the `host` argument).
- **The old socket is consumed**, on success and on failure: any later call on it
  returns "network: socket is closed". The call fails if the socket's input
  buffer is not empty (the peer sent data before the handshake, which STARTTLS
  forbids). A timeout closes the connection.
- **Only TCP sockets:** upgrading a TLS socket is an `error` result.
- **Why here and not in phase 20.** HTTPS is TLS from the first byte, `CONNECT`
  proxies and HTTP `Upgrade` are rejected (501, §10.6), and it needs a context to
  carry the trust or the key pair.

### 29.4 HTTP takes contexts

`std/http.agc` changed in the same PR as `TLS`: `HTTP.client(options, tls)`,
`HTTP.listen_tls(host, port, tls, handler, options)` and
`HTTP.listen_stream_tls(...)` (both replaced by `serve_tls` with the same server
context). `HttpClientOptions` lost `ca_file`. Every client takes a context, also
one that only speaks `http://` (used only for `https://` URLs; one system-trust
context per program is cheap once shared); a client builder without a context
would be a second way to make a client. The client keeps the context in its
options and its workers call `TLS.connect` with it, replacing the std-only
handle of #394 that built one `SSL_CTX` per client; each socket holds its own
reference (`SSL_CTX_up_ref`, 29.6).

The file-path forms were removed, not kept beside the context forms (one way):
the old calls are `CHECK-TYPE-MISMATCH` or `CHECK-ARITY` with a help naming the
context forms (the hint table of `grammar.md` §7), and `TlsContext`,
`TlsClientOptions` and `TlsServerOptions` are reserved names.

### 29.6 VM design

- **Values.** A `TlsContext` (`AGC_T_TLS_CONTEXT`, printed `<TlsContext>`) is a
  small GC object with the role and a pointer to a `malloc`'d native record that
  holds the `SSL_CTX *` and no GC pointer (`docs/vm/05-values-execution-builtins.md`
  §5.3; a GC object pointing to `malloc` memory is the allowed direction).
- **Connections hold their own reference.** `SSL_new` takes a reference on its
  `SSL_CTX`, so a socket stays valid when the program drops its last reference
  to the context, and the memory is freed when the last socket is. An
  `HttpClient` holds one more (`SSL_CTX_up_ref`), dropped in `close_client` and
  at the end of the run.
- **Freed by a GC finalizer, as a stated exception** to "no GC finalizers for OS
  resources; closing is explicit" (§5.3): a context holds no descriptor (its
  files are read whole when it is built) and has no `close`, and freeing it only
  at the end of the run would leak in a long-running server that rotates its
  certificate. A registry with a cap on live contexts was not taken: the cap
  would turn a slow program into a failing one in exactly the servers that need
  contexts most. The Boehm finalizer calls `SSL_CTX_free` and frees the native
  record; the VM sets `GC_set_finalize_on_demand(1)` and the scheduler calls
  `GC_invoke_finalizers()` between turns, so OpenSSL is never entered from
  inside the GC or in the middle of a builtin. Native records are also linked in
  a `malloc`'d list (a small lock with N schedulers) so the in-process harnesses
  free what is left.
- **Fuzzing.** Under `no_files`, both context builders end the run with
  `RUNTIME-INTERNAL`, as `TCP.connect` does, so a mutant never reads a file.
- **Turn costs.** Building a context with system trust parses the whole bundle;
  it is one blocking job on the thread pool, so it parks only its task
  (§10.2.2). **Tracing:** the `io` category gets `tls_context role=
  ca=system|file` at creation.

### 29.7 Options: first and later

**First (19a), kept small:** `ca_file` for clients; `cert_file` and `key_file`
for servers. That is exactly what today's file-path forms carry, so the
migration is mechanical.

**Later**, each its own item after 19 and after `with` (15c, see 29.1), each a
new field of the options records (never a new argument), and each passes the
one-way test because nothing else can express it:

- **Option:** `min_version` (`"1.2"` or `"1.3"`)
  - **Record:** both
  - **One-way test:** passes: today the floor is fixed at 1.2

- **Option:** `alpn: List[String]`, with `TLS.alpn(socket) -> String` to read
  the result (built in item 19c, §30.13)
  - **Record:** both
  - **One-way test:** passes: no other way to offer protocols

- **Option:** Client certificates (mTLS): `cert_file` and `key_file` on
  `TlsClientOptions`; `client_ca_file` on `TlsServerOptions`, which makes the
  server require and verify a client certificate
  - **Record:** both
  - **One-way test:** passes

- **Option:** `ca_data` (PEM text in memory, for a CA that ships inside the
  program)
  - **Record:** client
  - **One-way test:** passes only if it is the one way for in-memory PEM; it
    does not replace `ca_file` for files

- **Option:** Peer certificate info (`TLS.peer_certificate(socket)`: subject,
  names, validity)
  - **Record:** none, a socket builtin
  - **One-way test:** passes

- **Option:** Session reuse (resumption)
  - **Record:** client: a per-host session store inside the client context,
    keyed by host and port, with no API
  - **One-way test:** passes (no other way); it needs its own item with a test
    that a second connection to the same host resumes (Python `ssl` reports
    `session_reused`) and that a context never offers one host's session to
    another

**Never** (decided, not proposed again): `SSL_VERIFY_NONE` or any "insecure"
flag, an "optional" verify mode, a hostname-check switch, cipher strings, curve
lists, `openssl.cnf` settings, versions below TLS 1.2, and setters on an
existing context.

### 29.8 Tests

VM only: golden fixtures with the test CA of `tests/fixtures/tls/` and
independent Python `ssl` peers on port 0 (the hostname and CA cases of §10.3, and
STARTTLS both ways). Two behaviors need their own test: a `ca_file` replaced on
disk after the context is built does not change that context, and a context
dropped while a socket made from it is open stays valid until the socket closes.
