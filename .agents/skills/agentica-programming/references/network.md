# TCP, TLS and DNS

`TCP` and `TLS` are reserved; `TCP.Socket` and `TCP.Listener` are members of
`TCP`. Handles are opaque (no constructor, equality, fields or JSON). A handle
belongs to the task that opened it and closes when that task or the run ends
(`tasks.md`). A server loop gives each connection its own task with
`Task.spawn_owning(&serve, socket)`, so a crash closes only that connection.

No flag is needed for network access. With `--deny-net` (or `--sandbox`) every
DNS lookup, connect and listen, `std/http` included, returns an error starting
`denied: --deny-net` before any DNS query. With `--deny-fs`, a TLS call that
names a file returns `denied: --deny-fs`.

```text
DNS.lookup(host: String, timeout_ms: Int = 30000) -> Result[List[String]]
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[TCP.Socket]
TCP.listen(host: String, port: Int) -> Result[TCP.Listener]
TCP.accept(listener: TCP.Listener, timeout_ms: Int) -> Result[TCP.Socket]
TCP.send(socket: TCP.Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.send_bytes(socket: TCP.Socket, bytes: Bytes, timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: TCP.Socket, max_bytes: Int, timeout_ms: Int) -> Result[Bytes]
TCP.recv_bytes(socket: TCP.Socket, max_bytes: Int) -> Result[Bytes]   # no time limit
TCP.read_line(socket: TCP.Socket, timeout_ms: Int) -> Result[String]
TCP.close(socket: TCP.Socket) -> Void
TCP.close_listener(listener: TCP.Listener) -> Void
TCP.local_port(listener: TCP.Listener) -> Int
TCP.remote_address(socket: TCP.Socket) -> String
TLS.alpn(socket: TCP.Socket) -> String
TLS.client_context(options: TLS.ClientOptions) -> Result[TLS.Context]
TLS.server_context(options: TLS.ServerOptions) -> Result[TLS.Context]
TLS.connect(host: String, port: Int, context: TLS.Context, timeout_ms: Int) -> Result[TCP.Socket]
TLS.listen(host: String, port: Int, context: TLS.Context) -> Result[TCP.Listener]
TLS.upgrade(socket: TCP.Socket, context: TLS.Context, host: String, timeout_ms: Int) -> Result[TCP.Socket]

TLS.ClientOptions(ca_file: String = "", cert_file: String = "", key_file: String = "",
                 alpn: List[String] = [])
TLS.ServerOptions(cert_file: String, key_file: String, alpn: List[String] = [])
```

- A `TLS.Context` is the TLS setup of one role, built once (the PEM files are
  read and checked then) and shared by every socket, listener and HTTP client
  made from it. A file changed later needs a new context. `TLS.connect` takes a
  client context and `TLS.listen` a server one; the other role is
  `RUNTIME-TLS-CONTEXT-ROLE`.
- TLS listeners and sockets use the same `TCP.*` calls; only `TLS.connect`,
  `TLS.listen` and `TLS.upgrade` differ.
- `TLS.upgrade` starts TLS on an open TCP socket (STARTTLS) and returns a new
  TLS socket: a client context checks `host`, a server context takes `""`
  (another host is `RUNTIME-TLS-CONTEXT-ROLE`). The plain socket is
  closed whatever the handshake does. Unread bytes in it or a send in
  progress fail the upgrade; a timeout closes the connection.
- Port 0 on listen picks an assigned port. Listen binds every address the host
  resolves to, on one port (`localhost` takes `127.0.0.1` and `::1`); addresses
  the system cannot use are skipped.
- `TCP.remote_address` is the peer's IP without the port, `""` once closed.
- `DNS.lookup` asks the system resolver (hosts file included), as `TCP.connect`
  does: every IPv4 and IPv6 address as text, in its order, no duplicates; an IP
  literal gives itself. Not found is an error starting `network: host not
  found`; an empty name, a NUL and a timeout are errors too.
- TLS (1.2 or later) verifies certificates and hostnames; verification cannot be
  turned off. An empty `ca_file` uses system trust: `SSL_CERT_FILE`, else the
  platform store (Linux CA bundle, macOS Keychain, Windows ROOT store), read
  once per process, plus `SSL_CERT_DIR`. A nonempty one is a PEM CA file that
  replaces system trust; a missing or empty file fails `TLS.client_context`.
- `alpn` (both options) lists the ALPN protocols: a client offers them, a
  server picks the first of its own that the client offers (none in common: the
  handshake fails; a client offering none gets none). `TLS.alpn(socket)` is the
  protocol picked, or `""`. The `std/http` client and TLS server (`http.md`)
  speak HTTP/1.1 only: an `alpn` other than `[]` or `["http/1.1"]` halts with
  `RUNTIME-TLS-CONTEXT-ALPN`.
- A server context takes a PEM certificate chain and key; a bad file or
  mismatched key fails `TLS.server_context`. A client context sends a client
  certificate when `cert_file` and `key_file` name the same PEM forms (both
  empty: none; only one: an error).
- Timeouts are positive milliseconds and cover the whole operation, lock waits
  included. Reads and writes have independent locks: coordinate which task
  reads and the order of writes. A timeout during active I/O closes the socket
  (later calls fail at once with `network: socket is closed`); one only waiting
  for the lock does not. Failures are Results; close is idempotent.
- A function rewired onto a richer path (a new reader of refused answers, say)
  keeps its old latency and starts no blocking I/O: what the new caller needs,
  such as reading a body, is opt-in. Test that it still returns fast when the
  peer stalls.
- Send encodes UTF-8 and flushes; `send_bytes` takes a `Bytes` of at most 1 MiB.
  `recv_bytes` accepts 1..1048576 and returns the available data up to that
  count as `Bytes`, empty at EOF. TCP is a stream, not messages. Without
  `timeout_ms` it waits with no limit (a server waiting for an idle client: a
  timeout would close the socket); a cancel still ends the wait.
- `read_line` handles fragmented UTF-8, strips LF or CRLF and accepts a final
  unterminated line at EOF. It errors on an empty EOF, on a read error (a reset
  mid-line is an error, not a line) and on a line over 1 MiB, which also closes
  the socket.
