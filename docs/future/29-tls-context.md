## 29. TLS contexts

**Status:** 19a and 19b built; 19c planned (roadmap phase 19), decided by the
user on 2026-10-12. It is part of order step 7.4: after phase 17 (`Task.map` and
channels, §27) and right after the HTTP streaming items 20e to 20g ([section
30.11](30-hybrid-http.md#3011-streaming-on-channels)). `with` (15c) is built, so
`TLS.client_options().with(...)` is available; the API needs neither it nor
default parameter values: every call has a fixed argument list, and options live
in records (29.1). It changes `TLS` and `HTTP` together in one breaking step,
with one CHANGELOG entry and one migration (29.5).

**Built (19a):** `TlsContext`, `TLS.client_context`, `TLS.server_context`, the
context forms of `TLS.connect`, `TLS.listen`, the `listen_*_tls` forms and
`HttpClientOptions.tls`. It differs from this section in three points, decided
by the owner: the options are the records
`TlsClientOptions(ca_file = "", cert_file = "", key_file = "")` (the client
certificate of mTLS stays) and `TlsServerOptions(cert_file, key_file)`, with
no `TLS.client_options()` helper; `HttpClientOptions.tls` is an
`Optional[TlsContext] = none` in place of `ca_file`, and with `none` each client
builds its own system-trust context lazily; the `listen_*_tls` forms take a
server context.

**Built (19b):** `TLS.upgrade` as 29.3 says, with two additions: the checks of
the arguments (a closed or TLS socket, the timeout, an empty host for a client
context) are `error` results that leave the socket open, and a send still in
progress on the plain socket fails the upgrade as unread bytes do. 19c (ALPN)
is still planned.

**What is asked for:** an opaque handle like Python's `ssl.SSLContext`, built
once and reused by many connections, so the CA bundle is loaded once, and so TLS
options have one home instead of new arguments on every call.

**What exists today:** every `TLS` and HTTPS call names its trust or its key
pair by file path (the "Before" forms of 29.5;
[the grammar](../grammar/06d-io-and-network.md)). So the runtime either loads
and parses the files on every call (a system CA bundle is about 150
certificates) or keeps a hidden cache keyed by path, which goes stale when a
file changes. An `HttpClient` builds one OpenSSL `SSL_CTX` per client
(`docs/vm/10-io-http.md` §10.7), which helps HTTP clients only. And every new
option (a minimum version, ALPN, a client certificate) would be one more
argument on each call.

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms):
one way to do each thing, values stay immutable, types stay static. Security
rules of `docs/vm/10-io-tls.md` §10.3 do not move: certificates are always
verified, the hostname is always checked, there is no path that turns
verification off.

### 29.1 The API

```agentica
def main() -> Void
  tls = TLS.client_context(TLS.client_options()).unwrap!
  socket = TLS.connect("example.com", 443, tls, 5000).unwrap!
  TCP.send(socket, "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", 5000).unwrap!
  puts(TCP.read_line(socket, 5000).unwrap!)
  TCP.close(socket)
end
```

```text
TLS.client_options() -> TlsClientOptions
TLS.client_context(options: TlsClientOptions) -> Result[TlsContext]
TLS.server_context(options: TlsServerOptions) -> Result[TlsContext]
TLS.connect(host: String, port: Int, context: TlsContext, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, context: TlsContext) -> Result[Listener]
TLS.upgrade(socket: Socket, context: TlsContext, host: String, timeout_ms: Int) -> Result[Socket]   # 19b, 29.3
```

- **Record:** `TlsClientOptions`
  - **Fields:** `ca_file: String`
  - **Defaults helper:** `TLS.client_options()`: `ca_file: ""`, system trust

- **Record:** `TlsServerOptions`
  - **Fields:** `cert_file: String`, `key_file: String`
  - **Defaults helper:** none: a server has no default key pair

**Decisions:**

- **Options records, not arguments.** A context is built from one immutable
  record per role, as `HTTP.client_options()` and `HttpClientOptions` already
  work. A new option is a new field, never a new
  argument or a new builder, so default parameter values (15a) never have to
  change these calls. A new field does break code that constructs the record
  with every field named, so the skill teaches `with` (15c, built):
  `TLS.client_options().with(ca_file: "ca.pem")` keeps working when a field is
  added, and the later options of 29.7 come after it.
- **One type, two roles.** `TlsContext` is one opaque type, like `SSLContext`,
  with its role (client or server) fixed at creation. Two types
  (`TlsClientContext`, `TlsServerContext`) would catch a mix-up at check time,
  but they double the names for a mistake that fails at the first call anyway.
  Passing a server context to `TLS.connect` or `HTTP.client`, or a client
  context to `TLS.listen` or `HTTP.listen_tls`, is a bug in the program, not an
  I/O failure, so it is a diagnostic, not an `error` result (the rule of §27.1,
  "Limits"): the new stable code `RUNTIME-TLS-CONTEXT-ROLE`, at the context
  argument. For `HTTP.client` and `HTTP.listen_tls`, which are `std/http`
  functions, the diagnostic is raised by the `TLS` or `HttpWire` call inside
  `std/http.agc`, so its span points there, as embedded-module errors do; the
  message names the `HTTP` function and its context argument.
- **Errors come early.** `client_context` and `server_context` read and check
  their files when they are called: a missing or unreadable file, a file with no
  certificate, a bad key, and a key that does not match the certificate
  (`SSL_CTX_check_private_key`) are `error` results there, not at the first
  connect or accept. An empty `ca_file` means system trust; an empty `cert_file`
  or `key_file` is an `error` result.
- **Trust and minimums** are those of the TLS catch-up PR
  (`docs/vm/10-io-tls.md` §10.3, roadmap 7h): an empty `ca_file` means system
  trust, and a non-empty one replaces it. The only change is when the trust is
  loaded: once, into the context. The vendored static OpenSSL 3.5 build was
  decided by the user on 2026-10-12; rewriting §10.0, §10.3 and 7h for it is the
  TLS catch-up PR's job, not this section's.
- **Per connection, as today** (§10.3): `TLS.connect` and `TLS.upgrade` set SNI
  and `SSL_set1_host` from `host` (an IP literal goes through
  `X509_VERIFY_PARAM_set1_ip_asc` and sends no SNI). The context holds no
  hostname, so one context serves every host.
- **Fixed policy, no knobs:** verification on, the hostname check on, and the
  version floor, ciphers and groups that the TLS catch-up PR sets (§10.3); this
  phase adds no setting for them (29.7).
- **No defaults needed.** No call here would be better with a default parameter:
  the system-trust case is `TLS.client_context(TLS.client_options())`, as an
  HTTP client is `HTTP.client()`. If 15a later allows a
  call as a default value, a follow-up may give `options` that default in both;
  it is not planned here.
- **No close.** A context has no `close`: it holds no socket and no descriptor,
  only memory, and a context that a connection still uses must stay valid
  (29.6).

**Effects:** `network`, like the other `TLS` builtins. `client_context` and
`server_context` read files, so `--deny-fs` turns them off, as it does
`TLS.connect` with a `ca_file`.

### 29.2 Sharing and immutability

A context never changes after it is built: no builtin sets an option on an
existing context, and OpenSSL's `SSL_CTX` is only read after creation (OpenSSL
allows any number of `SSL` objects to be made from one `SSL_CTX` at once as long
as nobody changes it). So a context can be stored in a struct, captured by a
block, passed to many tasks and used by many connections at the same time, with
no lock. With the multicore schedulers (`docs/vm/10-io-multicore.md` §10.2.3)
this still holds: tasks on different schedulers make their own `SSL` objects
from the same context.

### 29.3 STARTTLS: `TLS.upgrade`

```text
TLS.upgrade(socket: Socket, context: TlsContext, host: String, timeout_ms: Int) -> Result[Socket]
```

Some protocols start in plain text and switch to TLS on the same connection
(SMTP and IMAP `STARTTLS`, PostgreSQL's `SSLRequest`). The status at the top
records two additions as built (19b): the argument checks leave the socket open,
and a send in progress fails the upgrade. `TLS.upgrade` runs the handshake over
an open TCP socket and returns a new TLS socket.

- **Role from the context.** With a client context it is the client side and
  checks `host` as `TLS.connect` does. With a server context it is the server
  side, and `host` must be `""` (`RUNTIME-TLS-CONTEXT-ROLE` otherwise, at the
  `host` argument).
- **The old socket is consumed.** On success and on failure, the plain `Socket`
  passed in is closed for the program: any later call on it returns "network:
  socket is closed". Bytes that the program had not read yet are the start of
  the TLS stream, so the call fails if the socket's input buffer is not empty
  (the peer sent data before the handshake, which STARTTLS forbids). The
  handshake runs within `timeout_ms`; a timeout closes the connection.
- **Only TCP sockets.** Upgrading a TLS socket (TLS inside TLS) is an `error`
  result.
- **One way:** it passes the test. There is no other way to start TLS on an open
  connection: `TLS.connect` opens a new one.
- **Why here and not in phase 20.** Simple HTTP does not need it: HTTPS is TLS
  from the first byte, `CONNECT` proxies are out of scope (§10.6 rejects
  `CONNECT` with 501), and HTTP `Upgrade` is rejected (501). It needs a context
  to carry the trust or the key pair, so it comes with contexts.

### 29.4 HTTP takes contexts

The HTTP API of phase 20 (`docs/grammar/06d-io-and-network.md`) is written in
Agentica (`std/http.agc`), so it changes in the same PR as `TLS`:

```text
HTTP.client(options: HttpClientOptions, tls: TlsContext) -> Result[HttpClient]
HTTP.listen_tls(host: String, port: Int, tls: TlsContext, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_stream_tls(host: String, port: Int, tls: TlsContext, handler: Fn[HttpRequest, Result[HttpStreamResponse]], options: HttpServerOptions) -> Result[HttpServer]
```

- `HttpClientOptions` loses its `ca_file` field. Every client takes a context,
  also one that only speaks `http://`: the context is used only for `https://`
  URLs, and one system-trust context per program is cheap once it is shared. A
  separate client builder without a context would be a second way to make a
  client.
- `HTTP.listen_tls` and `HTTP.listen_stream_tls` (20g) take a server context
  instead of `cert_file` and `key_file`.
- The client (`docs/vm/10-io-http.md` §10.7.1) keeps the context in its options
  and its workers call `TLS.connect` with it. This replaces the std-only handle
  of #394, where `HttpWire.connect_tls` builds one `SSL_CTX` per client from its
  `ca_file`. Each socket holds its own reference to the context
  (`SSL_CTX_up_ref`, 29.6). The server side calls `TLS.listen(host, port, tls)`.

### 29.5 One breaking step

**One way:** the file-path forms are removed, not kept beside the context forms.
Phase 19a changes, in one PR:

- **Before:** `TLS.connect(host, port, ca_file, timeout_ms)`
  - **After:** `TLS.connect(host, port, context, timeout_ms)`

- **Before:** `TLS.listen(host, port, cert_file, key_file)`
  - **After:** `TLS.listen(host, port, context)`

- **Before:** `HttpClientOptions(..., ca_file: path)` and `HTTP.client(options)`
  - **After:** `HttpClientOptions(...)` without `ca_file`, and
    `HTTP.client(options, tls)`

- **Before:** `HTTP.listen_tls(host, port, cert_file, key_file, handler,
  options)`
  - **After:** `HTTP.listen_tls(host, port, tls, handler, options)`

- **Before:** `HTTP.listen_stream_tls(host, port, cert_file, key_file, handler,
  options)`
  - **After:** `HTTP.listen_stream_tls(host, port, tls, handler, options)`

- The old calls are `CHECK-TYPE-MISMATCH` or `CHECK-ARITY` at their arguments,
  with a help that names the context forms (`TLS.client_context` to connect,
  `TLS.server_context` to listen), through the hint table of `grammar.md` §7.
- `TlsContext`, `TlsClientOptions` and `TlsServerOptions` become reserved names
  (`CHECK-REDEFINED-NAME` for a user type with one of these names; the CHANGELOG
  says so).
- The PR migrates every program in the repository that uses TLS or HTTPS (the
  golden fixtures, the TLS and HTTP tests, the examples, the runnable blocks of
  the site network page and the programming skill's `references/network.md`).

### 29.6 VM design

- **Values.** A `TlsContext` (`AGC_T_TLS_CONTEXT`, printed `<TlsContext>`) is a
  small GC object with the role and a pointer to a `malloc`'d native record that
  holds the `SSL_CTX *`. The native record holds no GC pointer
  (`docs/vm/05-values-execution-builtins.md` §5.3, `docs/vm/10-io-scheduler.md`
  §10.2.2); a GC object pointing to `malloc` memory is the allowed direction. No
  `SSL_CTX_set_app_data` is used.
- **Connections hold their own reference.** `SSL_new` takes a reference on its
  `SSL_CTX` (OpenSSL counts them), so a socket stays valid when the program
  drops its last reference to the context, and the context's memory is freed
  when its last socket is freed. An `HttpClient` holds one more reference
  (`SSL_CTX_up_ref`, 29.4), dropped in `close_client` and at the end of the run.
- **How a context is freed: a GC finalizer, as a stated exception.** Today's
  rule is "no GC finalizers for OS resources; closing is explicit" (§5.3). A
  context holds no descriptor (its files are read whole when it is built) and
  has no `close` (29.1), so the rule's reason does not apply, and freeing it
  only at the end of the run would leak in a long-running server that rotates
  its certificate. Keeping contexts in the resource registry with a cap on live
  contexts was not taken: the cap would turn a slow program into a failing one
  in exactly the servers that need contexts most. So the context's GC object
  gets a Boehm finalizer that calls `SSL_CTX_free` and frees the native record;
  the VM sets `GC_set_finalize_on_demand(1)` and the scheduler calls
  `GC_invoke_finalizers()` between turns, so OpenSSL is never entered from
  inside the GC or in the middle of a builtin. Native records are also linked in
  a `malloc`'d list (a small lock with N schedulers) so the in-process harnesses
  free what is left. `docs/vm/05-values-execution-builtins.md` §5.3 records the
  exception.
- **Fuzzing.** Under `no_files` (the fuzzer), `TLS.client_context` and
  `TLS.server_context` end the run with `RUNTIME-INTERNAL`, as `TCP.connect`
  does, so a mutant never reads a file.
- **Turn costs.** Building a context with system trust parses the whole bundle.
  It is a blocking builtin on the thread pool (the file read and the parse are
  one job, like a `File` call), so it parks only its task (§10.2.2).
- **Tracing.** The `io` category (14a) gets `tls_context role= ca=system|file`
  at creation and nothing per connection beyond what the TLS catch-up PR traces.

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
  the result (planned as item 19c, §30.13)
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

VM only: golden fixtures with the test CA of `tests/fixtures/tls/`, independent
Python `ssl` peers on port 0 (the hostname and CA cases of §10.3 and STARTTLS
both ways). Two behaviors need their own test: a `ca_file` replaced on disk
after the context is built does not change that context, and a context dropped
while a socket made from it is open stays valid until the socket closes.

### 29.9 Implementation (row 7.4)

One PR per item: 19a `TlsContext` (breaking, one step: contexts for `TLS` and
`HTTP`, reserved names, migration); 19b `TLS.upgrade`; 19c ALPN. The other later
options of §29.7 are not in this phase. Done when: a program builds one client
context and one server context at start-up and shares them; `TLS`,
`HTTP.client` and `HTTP.listen_tls` take only contexts; STARTTLS works against
Python on both sides.
