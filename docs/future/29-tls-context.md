## 29. TLS contexts

**Status:** planned (roadmap phase 19), decided by the user on 2026-10-12. It is a new feature, so it comes after 7i deletes the evaluator (order 7.2) and runs on the C VM only. It is part of order step 7.4: after phase 17 (`Task.map` and channels, §27) and right after the HTTP streaming items 20e to 20g ([section 30.11](30-hybrid-http.md#3011-streaming-on-channels)), and before default parameter values (15a, order row 7.5a, deferred until after the bootstrap) and `with` (15c, order step 7.6). So its API needs neither: every call has a fixed argument list, and options live in records (29.1). It changes `TLS` and `HTTP` together in one breaking step, with one CHANGELOG entry and one migration (29.5).

**What is asked for:** an opaque handle like Python's `ssl.SSLContext`, built once and reused by many connections, so the CA bundle is loaded once, and so TLS options have one home instead of new arguments on every call.

**What exists when this phase starts** (the TLS catch-up PR, roadmap 7h, keeps today's API; phase 20 keeps it for HTTP):

```text
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: ..., options: HttpServerOptions) -> Result[HttpServer]
HttpClientOptions(..., ca_file: String)
```

(`src/builtins.rkt:66` and `src/builtins.rkt:67`, `docs/grammar/06d-io-and-network.md`; the HTTP forms are those of [the grammar](../grammar/06d-io-and-network.md).) Every call names its trust or its key pair by file path. So the runtime either loads and parses the files on every call (a system CA bundle is about 150 certificates) or keeps a hidden cache keyed by path, which goes stale when a file changes. Phase 20's `HttpClient` builds one OpenSSL `SSL_CTX` per client (`docs/vm/10-io-http.md` §10.7), which helps HTTP clients only. And every new option (a minimum version, ALPN, a client certificate) would be one more argument on each of these calls.

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms): one way to do each thing, values stay immutable, types stay static. Security rules of `docs/vm/10-io-tls.md` §10.3 do not move: certificates are always verified, the hostname is always checked, there is no path that turns verification off.

| § | Item | Roadmap |
|---|---|---|
| 29.1 | `TlsContext`, `TlsClientOptions`, `TlsServerOptions` and the context builders | 19a |
| 29.3 | `TLS.upgrade` (STARTTLS) | 19b |
| 29.4 | `HTTP` takes contexts | 19a |
| 29.5 | One breaking step: the file-path forms are removed | 19a |
| 29.7 | Later options, each with the one-way test | none yet |

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

| Record | Fields | Defaults helper |
|---|---|---|
| `TlsClientOptions` | `ca_file: String` | `TLS.client_options()`: `ca_file: ""`, system trust |
| `TlsServerOptions` | `cert_file: String`, `key_file: String` | none: a server has no default key pair |

**Decisions:**

- **Options records, not arguments.** A context is built from one immutable record per role, as `HTTP.client_options()` and `HttpClientOptions` already work (`src/builtins.rkt:68`). A new option is a new field, never a new argument or a new builder, so default parameter values (15a) never have to change these calls. A new field does break code that constructs the record with every field named, so the later options of 29.7 come after `with` (§25.3, 15c, order step 7.6): from then on the skill teaches `TLS.client_options().with(ca_file: "ca.pem")`, which keeps working when a field is added. Until 15c, the first fields are the only ones, and a program writes `TlsClientOptions(ca_file: "ca.pem")`.
- **One type, two roles.** `TlsContext` is one opaque type, like `SSLContext`, with its role (client or server) fixed at creation. Two types (`TlsClientContext`, `TlsServerContext`) would catch a mix-up at check time, but they double the names for a mistake that fails at the first call anyway. Passing a server context to `TLS.connect` or `HTTP.client`, or a client context to `TLS.listen` or `HTTP.listen_tls`, is a bug in the program, not an I/O failure, so it is a diagnostic, not an `error` result (the rule of §27.1, "Limits"): the new stable code `RUNTIME-TLS-CONTEXT-ROLE`, at the context argument. For `HTTP.client` and `HTTP.listen_tls`, which are `std/http` functions, the diagnostic is raised by the `TLS` or `HttpWire` call inside `std/http.agc`, so its span points there, as embedded-module errors do; the message names the `HTTP` function and its context argument.
- **Errors come early.** `client_context` and `server_context` read and check their files when they are called: a missing or unreadable file, a file with no certificate, a bad key, and a key that does not match the certificate (`SSL_CTX_check_private_key`) are `error` results there, not at the first connect or accept. An empty `ca_file` means system trust; an empty `cert_file` or `key_file` is an `error` result.
- **Trust and minimums** are those of the TLS catch-up PR (`docs/vm/10-io-tls.md` §10.3, roadmap 7h): an empty `ca_file` means system trust, and a non-empty one replaces it. The only change is when the trust is loaded: once, into the context. The vendored static OpenSSL 3.5 build was decided by the user on 2026-10-12; rewriting §10.0, §10.3 and 7h for it is the TLS catch-up PR's job, not this section's.
- **Per connection, as today** (§10.3): `TLS.connect` and `TLS.upgrade` set SNI and `SSL_set1_host` from `host` (an IP literal goes through `X509_VERIFY_PARAM_set1_ip_asc` and sends no SNI). The context holds no hostname, so one context serves every host.
- **Fixed policy, no knobs:** verification on, the hostname check on, and the version floor, ciphers and groups that the TLS catch-up PR sets (§10.3); this phase adds no setting for them (29.7).
- **No defaults needed.** No call here would be better with a default parameter: the system-trust case is `TLS.client_context(TLS.client_options())`, as an HTTP client is `HTTP.client(HTTP.client_options())`. If 15a later allows a call as a default value, a follow-up may give `options` that default in both; it is not planned here.
- **No close.** A context has no `close`: it holds no socket and no descriptor, only memory, and a context that a connection still uses must stay valid (29.6).

**Effects:** `network`, like the other `TLS` builtins. `client_context` and `server_context` read files but need no flag, as `TLS.connect` with a `ca_file` needs none today.

### 29.2 Sharing and immutability

A context never changes after it is built: no builtin sets an option on an existing context, and OpenSSL's `SSL_CTX` is only read after creation (OpenSSL allows any number of `SSL` objects to be made from one `SSL_CTX` at once as long as nobody changes it). So a context can be stored in a struct, captured by a block, passed to many tasks and used by many connections at the same time, with no lock. With the multicore schedulers (`docs/vm/10-io-multicore.md` §10.2.3) this still holds: tasks on different schedulers make their own `SSL` objects from the same context.

### 29.3 STARTTLS: `TLS.upgrade`

```text
TLS.upgrade(socket: Socket, context: TlsContext, host: String, timeout_ms: Int) -> Result[Socket]
```

Some protocols start in plain text and switch to TLS on the same connection (SMTP and IMAP `STARTTLS`, PostgreSQL's `SSLRequest`). `TLS.upgrade` runs the handshake over an open TCP socket and returns a new TLS socket.

- **Role from the context.** With a client context it is the client side and checks `host` as `TLS.connect` does. With a server context it is the server side, and `host` must be `""` (`RUNTIME-TLS-CONTEXT-ROLE` otherwise, at the `host` argument).
- **The old socket is consumed.** On success and on failure, the plain `Socket` passed in is closed for the program: any later call on it returns "network: socket is closed". Bytes that the program had not read yet are the start of the TLS stream, so the call fails if the socket's input buffer is not empty (the peer sent data before the handshake, which STARTTLS forbids). The handshake runs within `timeout_ms`; a timeout closes the connection.
- **Only TCP sockets.** Upgrading a TLS socket (TLS inside TLS) is an `error` result.
- **One way:** it passes the test. There is no other way to start TLS on an open connection: `TLS.connect` opens a new one.
- **Why here and not in phase 20.** Simple HTTP does not need it: HTTPS is TLS from the first byte, `CONNECT` proxies are out of scope (§10.6 rejects `CONNECT` with 501), and HTTP `Upgrade` is rejected (501). It needs a context to carry the trust or the key pair, so it comes with contexts.

### 29.4 HTTP takes contexts

The HTTP API of phase 20 (`docs/grammar/06d-io-and-network.md`) is written in Agentica (`std/http.agc`), so it changes in the same PR as `TLS`:

```text
HTTP.client(options: HttpClientOptions, tls: TlsContext) -> Result[HttpClient]
HTTP.listen_tls(host: String, port: Int, tls: TlsContext, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_stream_tls(host: String, port: Int, tls: TlsContext, handler: Fn[HttpRequest, Result[HttpStreamResponse]], options: HttpServerOptions) -> Result[HttpServer]
```

- `HttpClientOptions` loses its `ca_file` field. Every client takes a context, also one that only speaks `http://`: the context is used only for `https://` URLs, and one system-trust context per program is cheap once it is shared. A separate client builder without a context would be a second way to make a client.
- `HTTP.listen_tls` and `HTTP.listen_stream_tls` (20g) take a server context instead of `cert_file` and `key_file`.
- In C, `HttpWire.client` (`docs/vm/10-io-http.md` §10.7) takes the context instead of a `ca_file`, and the per-client `SSL_CTX` of phase 20 goes away. The client's `malloc`'d record takes its own reference with `SSL_CTX_up_ref` and drops it with `SSL_CTX_free` in `HTTP.close_client` and at the end of the run, so a context the program no longer holds stays valid while a client uses it (29.6). The server side calls `TLS.listen(host, port, tls)`.

### 29.5 One breaking step

**One way:** the file-path forms are removed, not kept beside the context forms. Phase 19a changes, in one PR:

| Before | After |
|---|---|
| `TLS.connect(host, port, ca_file, timeout_ms)` | `TLS.connect(host, port, context, timeout_ms)` |
| `TLS.listen(host, port, cert_file, key_file)` | `TLS.listen(host, port, context)` |
| `HttpClientOptions(..., ca_file: path)` and `HTTP.client(options)` | `HttpClientOptions(...)` without `ca_file`, and `HTTP.client(options, tls)` |
| `HTTP.listen_tls(host, port, cert_file, key_file, handler, options)` | `HTTP.listen_tls(host, port, tls, handler, options)` |
| `HTTP.listen_stream_tls(host, port, cert_file, key_file, handler, options)` | `HTTP.listen_stream_tls(host, port, tls, handler, options)` |

- The old calls are `CHECK-TYPE-MISMATCH` or `CHECK-ARITY` at their arguments, with a help that shows the context form (`TLS.client_context(TlsClientOptions(ca_file: path))`), through the hint table of `grammar.md` §7.
- `TlsContext`, `TlsClientOptions` and `TlsServerOptions` become reserved names (`CHECK-REDEFINED-NAME` for a user type with one of these names; the CHANGELOG says so).
- The PR migrates every program in the repository that uses TLS or HTTPS: the `tls-*` and `http-*` golden fixtures (`tests/fixtures/vm/`), `tests/vm-tls-test.rkt` and `tests/vm-http-test.rkt` (the files the TLS catch-up PR and phase 20 add), any example under `examples/`, the runnable blocks of `site/content/library/io-and-system/network.md`, and the programming skill's `references/network.md`.
- **One CHANGELOG entry** under "Changed", for example: "TLS settings live in a `TlsContext`, built once with `TLS.client_context(options)` or `TLS.server_context(options)` and shared by every connection. `TLS.connect`, `TLS.listen`, `HTTP.client`, `HTTP.listen_tls` and `HTTP.listen_stream_tls` take a context instead of file paths, and `HttpClientOptions` has no `ca_file` field any more. Build the context once, at start-up, and pass it on. `TLS.upgrade` starts TLS on an open TCP socket (STARTTLS)."

### 29.6 VM design

- **Values.** A `TlsContext` (`AGC_T_TLS_CONTEXT`, printed `<TlsContext>`) is a small GC object with the role and a pointer to a `malloc`'d native record that holds the `SSL_CTX *`. The native record holds no GC pointer (`docs/vm/05-values-execution-builtins.md` §5.3, `docs/vm/10-io-scheduler.md` §10.2.2); a GC object pointing to `malloc` memory is the allowed direction. No `SSL_CTX_set_app_data` is used.
- **Connections hold their own reference.** `SSL_new` takes a reference on its `SSL_CTX` (OpenSSL counts them), so a socket stays valid when the program drops its last reference to the context, and the context's memory is freed when its last socket is freed. An `HttpClient` holds one more reference (`SSL_CTX_up_ref`, 29.4), dropped in `close_client` and at the end of the run.
- **How a context is freed: a GC finalizer, as a stated exception.** Today's rule is "no GC finalizers for OS resources; closing is explicit" (§5.3). A context is not an OS resource: it holds no descriptor (its files are read whole when it is built) and has no `close` (29.1), so the rule's reason does not apply, but freeing it only at the end of the run would leak in a long-running server: a server that rotates its certificate every day builds a new context each time, and a program that wrongly builds a context per request would grow without bound. The other choice, keeping contexts in the resource registry until the end of the run with a cap on live contexts, was not taken: the cap would turn a slow program into a failing one in exactly the long-running servers that need contexts most. So:
  - The context's GC object gets a Boehm finalizer (`GC_register_finalizer_no_order`) that calls `SSL_CTX_free` and frees the native record.
  - The VM sets `GC_set_finalize_on_demand(1)`, so Boehm never runs a finalizer inside an allocation; the scheduler calls `GC_invoke_finalizers()` between turns, at the same safe point where it polls the loop (§10.2.1), so OpenSSL is never entered from inside the GC or in the middle of a builtin. With N schedulers (§10.2.3) any scheduler may run them; `SSL_CTX_free` is thread-safe.
  - Native records are also linked in a `malloc`'d list (no GC pointers), so the in-process harnesses free what is left (`agc_io_close`), and ASan's leak check stays clean; the VM's own end of the run ends with `_exit` (§14.4) and frees nothing one by one. The finalizer unlinks its record from that list before it frees it; with N schedulers (§10.2.3) the list has a small lock, taken by creation, the finalizer and `agc_io_close`. Under `AGC_NO_GC` nothing is collected and `agc_io_close` frees everything.
  - `docs/vm/05-values-execution-builtins.md` §5.3 gets the exception in one line: "except `TlsContext`, which holds only memory and is freed by a finalizer run on demand between turns (`docs/future/29-tls-context.md` §29.6)".
- **Fuzzing.** Under `no_files` (the fuzzer), `TLS.client_context` and `TLS.server_context` end the run with `RUNTIME-INTERNAL`, as `TCP.connect` does, so a mutant never reads a file.
- **Turn costs.** Building a context with system trust parses the whole bundle. It is a blocking builtin on the thread pool (the file read and the parse are one job, like a `File` call), so it parks only its task (§10.2.2).
- **Tracing.** The `io` category (14a) gets `tls_context role= ca=system|file` at creation and nothing per connection beyond what the TLS catch-up PR traces.

### 29.7 Options: first and later

**First (19a), kept small:** `ca_file` for clients; `cert_file` and `key_file` for servers. That is exactly what today's file-path forms carry, so the migration is mechanical.

**Later**, each its own item after 19 and after `with` (15c, see 29.1), each a new field of the options records (never a new argument), and each passes the one-way test because nothing else can express it:

| Option | Record | One-way test |
|---|---|---|
| `min_version` (`"1.2"` or `"1.3"`) | both | passes: today the floor is fixed at 1.2 |
| `alpn: List[String]`, with `TLS.alpn(socket) -> String` to read the result | both | passes: no other way to offer protocols |
| Client certificates (mTLS): `cert_file` and `key_file` on `TlsClientOptions`; `client_ca_file` on `TlsServerOptions`, which makes the server require and verify a client certificate | both | passes |
| `ca_data` (PEM text in memory, for a CA that ships inside the program) | client | passes only if it is the one way for in-memory PEM; it does not replace `ca_file` for files |
| Peer certificate info (`TLS.peer_certificate(socket)`: subject, names, validity) | none, a socket builtin | passes |
| Session reuse (resumption) | client: a per-host session store inside the client context, keyed by host and port, with no API | passes (no other way); it needs its own item with a test that a second connection to the same host resumes (Python `ssl` reports `session_reused`) and that a context never offers one host's session to another |

**Never** (decided, not proposed again): `SSL_VERIFY_NONE` or any "insecure" flag, an "optional" verify mode, a hostname-check switch, cipher strings, curve lists, `openssl.cnf` settings, versions below TLS 1.2, and setters on an existing context.

### 29.8 Tests and docs

**Tests** (VM only):

- Golden fixtures (`tests/fixtures/vm/`): a server context and a client context with the test CA of `tests/fixtures/tls/`, a TLS echo in one program (listener and client in two tasks), one context shared by three concurrent connections, `TLS.upgrade` on both sides of one connection, and the creation errors (a missing file, a key that does not match, an empty `cert_file`) as `error` results. `RUNTIME-TLS-CONTEXT-ROLE` for a server context in `TLS.connect`, a client context in `TLS.listen`, and a non-empty `host` in a server-side `TLS.upgrade`, each at its argument span.
- `tests/vm-tls-test.rkt`: independent Python `ssl` peers on port 0 (standard library only): a wrong hostname, a self-signed server without `ca_file`, a `ca_file` that excludes system roots (the cases of §10.3), a STARTTLS exchange where Python plays the SMTP-like server and the VM the client, and the reverse; a `ca_file` replaced on disk after the context is built does not change that context.
- A C test (`vm/tests/`) that a context dropped while a socket made from it is open stays valid until the socket closes, and that the finalizer runs only from `GC_invoke_finalizers` (under the GC stress build).
- Checker tests for the hints of 29.5 (codes and spans).

**Docs:** `grammar.md` ("TCP, TLS and HTTP/1.1": the context API, the records, reserved names, the §7 hints), the programming skill (`references/network.md`: build one context at start-up and share it; `references/diagnostics.md`: `RUNTIME-TLS-CONTEXT-ROLE`), `site/content/library/io-and-system/network.md` (runnable examples in `mode="check"`, since they touch the network), the CHANGELOG entry of 29.5, `docs/vm/10-io-tls.md` §10.3 (contexts, `TLS.upgrade`), `docs/vm/05-values-execution-builtins.md` §5.3 (the finalizer exception), and the development skill's `references/vm.md`.
