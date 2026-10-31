---
title: TCP, TLS and HTTP
weight: 4
description: TCP and TLS sockets and the HTTP/1.1 client and server of std/http.
---

Network functions return a `Result` and take timeouts in milliseconds.

- With `--deny-net` (or `--sandbox`), every connect and listen returns an error that begins with `denied: --deny-net`, before any DNS lookup. With `--deny-fs`, a TLS call that names a file (a CA file, a certificate or a key) returns `denied: --deny-fs`.
- Sockets, listeners, clients and servers are handles: `IO.inspect` prints `<Socket>`, they cannot be compared, and they close when the program ends.
- A handle belongs to the task that opened it and closes when that task ends, so open it in the task that keeps it. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) gives one to a new task.
- Timeouts are positive milliseconds. A timeout covers the whole call, including the wait for another task using the same socket. After a timeout during active I/O the socket is closed, and later calls fail at once with `network: socket is closed`; a timeout while only waiting for a lock keeps it open.

## TCP

### TCP.listen and TCP.local_port

```text
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.local_port(listener: Listener) -> Int
```

Port `0` picks a free port, and `local_port` tells which (ports are 0 to 65535 here, 1 to 65535 in `connect`). A host that holds a NUL is an error. The listener takes every address the host name stands for: `"localhost"` accepts `127.0.0.1` and `::1`.

```agentica
def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  puts(TCP.local_port(listener) > 0)
  TCP.close_listener(listener)
end
```

```output
true
```

### TCP.connect and TCP.accept

```text
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[Socket]
TCP.accept(listener: Listener, timeout_ms: Int) -> Result[Socket]
```

`connect` opens a connection to a server. `accept` waits for the next client of a listener.

### TCP.send and TCP.read_line

```text
TCP.send(socket: Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.read_line(socket: Socket, timeout_ms: Int) -> Result[String]
```

`send` writes UTF-8 text and flushes. `read_line` reads one line without its line ending (LF or CRLF).

- A last line without a line ending counts when the other side closes.
- `read_line` errors at the end of input, when the connection breaks (even mid-line), and for a line over 1 MiB (which also closes the socket).
- TCP is a byte stream: one `send` can arrive in several reads and one `read_line` can cover several sends. A character split between reads is joined before the UTF-8 check.

A program that talks to itself, with a task as the server:

```agentica
def echo_once(listener: Listener) -> Result[Void]
  client = try TCP.accept(listener, 2000)
  line = try TCP.read_line(client, 2000)
  try TCP.send(client, "echo: #{line}\n", 2000)
  TCP.close(client)
  return ok()
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  server = Task.spawn(&echo_once, listener)
  socket = TCP.connect("127.0.0.1", TCP.local_port(listener), 2000).unwrap!
  sent = TCP.send(socket, "hello\n", 2000)
  puts(TCP.read_line(socket, 2000))
  puts(Task.await(server))
  TCP.close(socket)
  TCP.close_listener(listener)
end
```

```output
ok("echo: hello")
ok()
```

### TCP.send_bytes and TCP.recv_bytes

```text
TCP.send_bytes(socket: Socket, bytes: Bytes, timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[Bytes]
```

Raw bytes, as [`Bytes`](/library/data-structures/bytes/). `send_bytes` takes at most 1 MiB per call. `recv_bytes` takes a `max_bytes` from 1 to 1048576 and gives what has arrived, up to `max_bytes`, and empty `Bytes` when the other side has closed.

### TCP.close and TCP.close_listener

```text
TCP.close(socket: Socket) -> Void
TCP.close_listener(listener: Listener) -> Void
```

Closing twice is fine. Close early only when it must not wait for the task to end.

## TLS

```text
TLS.client_context(options: TlsClientOptions) -> Result[TlsContext]
TLS.server_context(options: TlsServerOptions) -> Result[TlsContext]
TLS.connect(host: String, port: Int, context: TlsContext, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, context: TlsContext) -> Result[Listener]
TLS.upgrade(socket: Socket, context: TlsContext, host: String, timeout_ms: Int) -> Result[Socket]
```

```text
struct TlsClientOptions
  ca_file: String = ""
  cert_file: String = ""
  key_file: String = ""
end

struct TlsServerOptions
  cert_file: String
  key_file: String
end
```

A `TlsContext` is the TLS setup of one role, built once and shared by every socket, listener and HTTP client made from it. TLS sockets and listeners use the same `TCP` functions, with the same limits and timeouts.

- `TLS.client_context` and `TLS.server_context` read and check the PEM files when they run, so a bad file fails there, not at each connect. A file that changes later does not change the context: build a new one.
- `TLS.connect` takes a client context and `TLS.listen` a server context; the other role stops the program with `RUNTIME-TLS-CONTEXT-ROLE`. A context stays valid while a socket or listener made from it is open.
- `TLS.connect` uses TLS 1.2 or later and always checks the certificate and the host name (an IP address host against the certificate's IP addresses).
- An empty `ca_file` uses the system's trusted certificates, read once per process, with the ones the system distrusts rejected. `SSL_CERT_FILE` replaces the store, `SSL_CERT_DIR` adds a directory. A nonempty `ca_file` is a PEM file that replaces them; a missing or empty file fails `TLS.client_context`.

  | System | Store |
  |---|---|
  | Linux | the CA bundle |
  | macOS | the system roots and Keychain trust settings |
  | Windows | the ROOT store (intermediates from its CA store help build a chain but are never roots) |

- A server context needs PEM files for the certificate chain and the private key, and fails when a file is bad or the key does not match.
- A client context sends a client certificate when `cert_file` and `key_file` name PEM files, checked as for a server. Leave both empty to send none; giving only one is an error.
- A peer that closes without TLS's closing message ends the stream like EOF.

### TLS.upgrade

`TLS.upgrade` starts TLS on an open TCP socket, for protocols that begin in plain text (SMTP and IMAP `STARTTLS`, PostgreSQL's `SSLRequest`). It returns a new TLS socket.

- With a client context it is the client side and checks `host` as `TLS.connect` does. With a server context it is the server side and `host` must be `""`; another host stops the program with `RUNTIME-TLS-CONTEXT-ROLE`.
- Once its arguments pass their checks, the plain socket is closed for the program, whether the handshake works or not: a later call on it returns `network: socket is closed`.
- Bytes that arrived and were not read yet fail the upgrade (`network: data came before the TLS handshake`): STARTTLS forbids them. A send still in progress on the socket fails it too.
- The handshake runs within `timeout_ms`; a timeout closes the connection. A TLS socket cannot be upgraded again.

An SMTP client reads each reply to its last line, so no byte is left before the handshake:

```agentica {mode="check"}
# An SMTP reply, up to its last line: "250-" goes on, "250 " ends it.
def reply(socket: Socket) -> Result[String]
  line = try TCP.read_line(socket, 5000)
  while line.slice(3, 1) == "-"
    line = try TCP.read_line(socket, 5000)
  end
  return ok(line)
end

def starttls(host: String, context: TlsContext) -> Result[Socket]
  plain = try TCP.connect(host, 587, 5000)
  try reply(plain)
  try TCP.send(plain, "EHLO client.example\r\n", 5000)
  try reply(plain)
  try TCP.send(plain, "STARTTLS\r\n", 5000)
  ready = try reply(plain)
  if !ready.start_with?("220")
    return error(ready)
  end
  return TLS.upgrade(plain, context, host, 5000)
end
```

```agentica {mode="check"}
def main() -> Void
  context = TLS.client_context(TlsClientOptions()).unwrap!
  socket = TLS.connect("example.com", 443, context, 5000).unwrap!
  sent = TCP.send(socket, "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", 5000)
  puts(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
```

### Moving to contexts

Before 0.20.0, TLS calls took PEM paths. Each old form and its new one:

| Before | Now |
|---|---|
| `TLS.connect(host, port, "ca.pem", ms)` | `TLS.connect(host, port, TLS.client_context(TlsClientOptions(ca_file: "ca.pem")).unwrap!, ms)` |
| `TLS.connect(host, port, ca, ms, cert, key)` | `TLS.connect(host, port, TLS.client_context(TlsClientOptions(ca_file: ca, cert_file: cert, key_file: key)).unwrap!, ms)` |
| `TLS.listen(host, port, cert, key)` | `TLS.listen(host, port, TLS.server_context(TlsServerOptions(cert_file: cert, key_file: key)).unwrap!)` |
| `HTTP.listen_tls(host, port, cert, key, handler)` (and the `stream`, `upload` and `websocket` forms) | `HTTP.listen_tls(host, port, server_context, handler)` |
| `HttpClientOptions(ca_file: path)` | `HttpClientOptions(tls: some(TLS.client_context(TlsClientOptions(ca_file: path)).unwrap!))` |
| `HttpClientOptions(ca_file: "")` | `HttpClientOptions()`: `tls` is `none`, the system trust |

Build each context once and share it. `HttpClientOptions` holds a `TlsContext`, so `JSON.schema`, `JSON.decode` and `JSON.encode` refuse it.

## HTTP client

HTTP is the `std/http` library, written in Agentica: `import HTTP from "std/http"` (without it, `CHECK-UNKNOWN-NAME`). It works the same on Linux, macOS and Windows, over HTTP and HTTPS.

- Every call of the client is whole: it returns after the whole response arrived (for a body read piece by piece, see [`HTTP.start`](#httpstart-httpsend_request-httpread_body-and-httpfinish), and for a body on a channel, [`HTTP.open`](#httpopen-and-httpupload)). The body is `Bytes`, exactly as it came (any content, up to `max_body_bytes`); it is not decompressed. [`HTTP.text`](#httptext) decodes it in its charset.
- Status codes such as 404 or 500 are normal responses. `error` results are a bad URL, a refused connection, a timeout, or a body over the limit. Protocol errors start with `http: `, connection errors keep their TCP or TLS text, and a timeout is `network: operation timed out`.
- `GET`, `HEAD`, `OPTIONS`, `PUT` and `DELETE` are retried once on a new connection, within the same timeout, when the server had closed a reused connection and no response byte arrived. Other methods are never retried.
- Header names must be HTTP tokens, values Latin-1 text without control characters.

### HTTP.client

```text
HTTP.client(options: HttpClientOptions = HttpClientOptions()) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
```

A client reuses open connections for the same scheme, host and port. Every field of `HttpClientOptions` has the default below, so `HttpClientOptions(timeout_ms: 5000)` changes one and keeps the others, and `HTTP.client()` uses them all.

| Option | Default | Limit |
|---|---|---|
| `timeout_ms` | 30 s, for each whole call | positive |
| `idle_timeout_ms` | 30 s, for kept connections | positive |
| `max_connections` | 4, per host | positive, at most 65536 |
| `max_body_bytes` | 1 MiB | positive, at most 64 MiB |
| `proxy` | `""`: no proxy | an `http://host:port` origin, see below |
| `tls` | `none`: the system's CA certificates | a client `TlsContext` |

- Calls wait in FIFO order for a `max_connections` slot. A call in flight when `close_client` runs fails with `http: client is closed` (unless a connection had already started sending it).
- With a `proxy` (`HttpClientOptions(proxy: "http://proxy:8080")`) every `http://` request goes to that forward proxy in absolute form (`GET http://host/path HTTP/1.1`, the `Host` header still the target's), and the client keeps and reuses its connections by the proxy, so requests to different hosts share them. It applies to `HTTP.client` and the calls that take a client or options: `get_response`, `post_response`, `HTTP.open`, `HTTP.upload`, `HTTP.download` and `HTTP.start`. The proxy must be an `http://` origin with no path or query, or the call that gets it is an `error`. User info in the proxy URL (`http://user:password@proxy:8080`, both parts percent-decoded, the user without a colon) is the proxy's login: every request to the proxy carries `Proxy-Authorization: Basic ...`, unless the call sets that header itself, and nothing else gets it. A `407` from the proxy is an `error` for the call that met it (`http: the proxy 127.0.0.1:8080 refused the credentials (407)`, or `requires credentials` when the URL has none), and no error repeats the user info. A `Connection` from `HTTP.start` prints its proxy without it; the `HttpClientOptions` you build still holds the URL as you wrote it, so keep the password out of any log that prints it. An `https://` URL with a `proxy` is an `error` (`http: https through a proxy is not supported yet`) and is never sent in the clear: a `CONNECT` tunnel is not built. The environment is not read: the default is no proxy.
- The client runs as Agentica code in its own tasks, so it spends the run's `--max-steps` budget.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client(HttpClientOptions(timeout_ms: 5000, max_connections: 2)).unwrap!
  HTTP.close_client(client)
end
```

Clients that trust the same CA file share one context: build it once and pass it to each.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  tls = TLS.client_context(TlsClientOptions(ca_file: "ca.pem")).unwrap!
  client = HTTP.client(HttpClientOptions(tls: some(tls))).unwrap!
  HTTP.close_client(client)
end
```

### HTTP.get, HTTP.post and HTTP.request

```text
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
HTTP.get_response(url: String, options: HttpClientOptions = HttpClientOptions()) -> Result[HttpResponse]
HTTP.post_response(url: String, body: Bytes, headers: List[Header] = [], options: HttpClientOptions = HttpClientOptions()) -> Result[HttpResponse]
```

- `HttpResponse` has `status`, `headers` (names in lowercase) and `body`, which is `Bytes`. `post` sends a `Bytes` body, as Ruby's `Net::HTTP.post(uri, data, header)` does, and `request` takes any method. Send text as `"text".bytes`, and no body as `"".bytes`. The body is at most `max_body_bytes`, and `headers` default to `[]`.
- For one request use `get_response` and `post_response`, like Ruby's `Net::HTTP.get_response` and `Net::HTTP.post`: each makes a client with `options`, makes the call and closes the client and its connection before it returns, so it needs no `client` and no `close_client`. For many requests use one `HTTP.client()` with `get`, `post` and `request`, which reuses connections; calling `get_response` in a loop opens a connection each time, and over HTTPS also builds a new TLS context and loads the CA bundle each time.
- URLs start with `http://` or `https://`. A bracketed host (`http://[::1]:8080/`) must look like an IPv6 address, else an error result.
- The client adds `Host` and `Content-Length`; a request may not set them, nor `Transfer-Encoding` or `Connection`.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client().unwrap!
  headers = [Header(name: "Content-Type", value: "application/json")]
  case HTTP.post(client, "http://localhost:8080/items", "{\"name\":\"tea\"}".bytes, headers)
    ok(created) -> puts("#{created.status} #{HTTP.text(created.body, created.headers).unwrap!}")
    error(message) -> IO.warn(message)
  end

  deleted = HTTP.request(client, "DELETE", "http://localhost:8080/items/1", "".bytes)
  puts(deleted.ok?)
  HTTP.close_client(client)
end
```

One request, with no client to open or close:

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  case HTTP.get_response("http://localhost:8080/items", HttpClientOptions(timeout_ms: 5000))
    ok(response) -> puts("#{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
    error(message) -> IO.warn(message)
  end
end
```

### HTTP.text

```text
HTTP.text(body: Bytes, headers: List[Header] = []) -> Result[String]
```

Decodes a body as text. Pass the `headers` of the same message: the body is read in the `charset` of its `Content-Type` (any case, quoted or not), and as UTF-8 when there is none. The charsets are the encodings of [`Bytes.decode`](/library/data-structures/bytes/#decode): UTF-8, UTF-16, UTF-32, ASCII, Latin-1 (`iso-8859-1`), ISO-8859-15 and Windows-1252, by any of their names. A body that is not valid in its charset is an `error` result (with the byte offset, except for UTF-8), and any other charset (`shift_jis`, `koi8-r`) is an `error` that names it. Other charsets belong to the planned `agentica-lang/charset` package.

```agentica
import HTTP from "std/http"

def main() -> Void
  utf8 = [Header(name: "content-type", value: "text/plain; charset=UTF-8")]
  latin1 = [Header(name: "content-type", value: "text/plain; charset=iso-8859-1")]
  koi8 = [Header(name: "content-type", value: "text/plain; charset=koi8-r")]
  puts(HTTP.text("café".bytes, utf8).unwrap!)
  puts(HTTP.text("caf".bytes + Bytes.from_list([233]).unwrap!, latin1).unwrap!)
  puts(HTTP.text("caf".bytes, koi8).ok?)
  puts(HTTP.text(Bytes.from_list([255, 0, 128]).unwrap!).ok?)
end
```

```output
café
café
false
false
```

### HTTP.header_values

```text
HTTP.header_values(headers: List[Header], name: String) -> List[String]
```

Finds every value of a header, in order. It ignores case.

```agentica
import HTTP from "std/http"

def main() -> Void
  headers = [Header(name: "set-cookie", value: "a=1"), Header(name: "Set-Cookie", value: "b=2")]
  puts(HTTP.header_values(headers, "Set-Cookie"))
end
```

```output
["a=1", "b=2"]
```

### HTTP.download

```text
HTTP.download(client: HttpClient, url: String, path: String, options: DownloadOptions = DownloadOptions()) -> Result[Download]
```

- `DownloadOptions` has `timeout_ms`, for the whole call, and `max_total_bytes`, for the body, at most 256 MiB. `DownloadOptions()`, the default, gives 30 s and 256 MiB. `Download` has `status`, `headers` and `bytes_written`; the body itself is in the file, never in the record.
- The download sends a `GET` and streams the body to `path`, so bodies may be arbitrary bytes. The file never grows past `max_total_bytes`.
- The file must not exist: it is made private to the user, so an existing path fails untouched, while a failed download keeps the partial file. Status codes such as 404 are normal responses whose body is still written, so check `status` before using the file.
- The connection is not pooled: it closes when the download ends. There is no redirect follow, and `https` keeps certificate verification on.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client().unwrap!
  case HTTP.download(client, "http://localhost:8080/asset", "asset.bin")
    ok(saved) -> puts("#{saved.status} #{saved.bytes_written}")
    error(message) -> IO.warn(message)
  end

  HTTP.close_client(client)
end
```

### HTTP.start, HTTP.send_request, HTTP.read_body and HTTP.finish

```text
HTTP.start(origin: String, options: HttpClientOptions = HttpClientOptions()) -> Result[HTTP.Connection]
HTTP.send_request(conn: HTTP.Connection, method: String, target: String, body: Bytes, headers: List[Header] = []) -> Result[HTTP.ResponseHead]
HTTP.read_body(conn: HTTP.Connection, max_bytes: Int = 65536) -> Result[Bytes]
HTTP.finish(conn: HTTP.Connection) -> Void
```

One connection that the program drives itself, outside the pool, as Ruby's `Net::HTTP.start`, `send_request`, `read_body` and `finish` do (and Python's `http.client.HTTPConnection`). Use it to read a body piece by piece, as it arrives (a big file, a log that never ends, lines of a stream), or to control the connection: which requests go on one socket, and when it closes. For whole responses use `get` and the pooled client, which are simpler.

- `start` takes an origin (`http://host`, `https://host:8443`) with no path or query, and connects now. `https` verifies the certificate with `options.tls` (the system trust when `none`, built again for each `start`, so a program that opens many connections passes `tls: some(context)`). Only `timeout_ms`, `max_body_bytes`, `tls` and `proxy` of the options apply: `timeout_ms` is the time of each call (the connect, each `send_request`, each `read_body`), and `max_body_bytes` the largest request body.
- `send_request` sends the request and returns when the head of the response has been read: `HTTP.ResponseHead` has `status` and `headers` (names in lowercase). `target` is the path and query (`/items?page=2`). `Host` and `Content-Length` are added; the rules for headers are those of `HTTP.request`. An interim `1xx` head is read past.
- `read_body` waits for at least one byte and gives at most `max_bytes` (1 to 1 MiB) of the body, decoded (a chunked body has no framing in it). An empty `Bytes` is the end of the body. A `Content-Length` body is held to its length, a chunked one to its framing, and a body that runs to the close of the connection must end with a clean close (over TLS, the peer's `close_notify`). A response body is at most 256 MiB, the limit of `download`, whatever its framing. A response to `HEAD`, a `204`, a `304` and one with `Content-Length: 0` have no body: the connection is ready at once, with no `read_body` needed (a `read_body` gives the empty end piece).
- After a body has been read to its end, the connection is ready for the next `send_request`, unless the server closed it (`Connection: close`, HTTP/1.0 or a body that ran to the close): then `send_request` is `error("http: the connection is closed")`. The end comes with the last byte, so a program that knows the length may stop reading before the empty piece. The connection is also closed when input is left after the body (a server that sent a second response in the same write, or bytes after the last chunk): reading its answer for the next request would be wrong. A request while the last body is still being read is an `error`, and the connection stays as it was.
- A failure of the connection (a cut body, a bad chunk, a timeout, a response body over the limit, a write that fails) is an `error` and ends it. A request that is refused before anything is written (a bad method, header or target, a body over `max_body_bytes`) is an `error` too, and the connection stays as it was. A server that closed an idle connection shows as an `error` of the next `send_request`: `start` a new one; nothing is retried.
- `finish` closes the socket, drops a body not read to its end, and may be called twice. The connection belongs to the task that opened it (as a socket does), and one call at a time uses it: a second call at once is `error("http: the connection is in use by another call")`.
- There is no redirect follow, cookie or decompression: a program that needs them loops over `send_request`.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  conn = HTTP.start("http://localhost:8080").unwrap!
  head = HTTP.send_request(conn, "GET", "/log", "".bytes).unwrap!
  puts(head.status)
  total = 0
  while true
    piece = HTTP.read_body(conn, 4096).unwrap!
    if piece.empty?
      break
    end

    total = total + piece.size
  end

  puts(total)
  next_head = HTTP.send_request(conn, "GET", "/other", "".bytes)
  puts(next_head.ok?)
  HTTP.finish(conn)
end
```

### HTTP.open and HTTP.upload

```text
HTTP.open(method: String, url: String, body: Bytes, headers: List[Header] = [], options: HttpClientOptions = HttpClientOptions()) -> Result[HTTP.Stream]
HTTP.upload(method: String, url: String, body: Channel[Bytes], length: Int = -1, headers: List[Header] = [], options: HttpClientOptions = HttpClientOptions()) -> Result[HttpResponse]
```

The two forms for a body that goes through a channel, so that another task can use it as it comes: a download that is too big to hold, an endless one (events, the lines of a log), or an upload that is produced as it goes. Each call uses a connection of its own, outside the pool, built on [`HTTP.start`](#httpstart-httpsend_request-httpread_body-and-httpfinish). A call whose whole body fits in memory is simpler with `get`, `post` and `request`.

- `open` sends the request and returns at the head of the response: `HTTP.Stream` has `status`, `headers`, `body` (a `Channel[Bytes]`) and `done` (a `Task[Result[Void]]`). A task feeds `body` with the pieces of the response (at most 64 KiB, never empty, a chunked body already decoded) and closes it on every path. `url` has a path and a query; `method`, `body` and `headers` are those of `request`.
- The reader runs the usual receive loop until the closed error, then awaits `done`: `ok` means the body ended cleanly, and an `error` says why it did not (a cut body, a timeout, a body over 256 MiB). A channel can only end, so `done` is the only way to tell a complete body from a cut one: always await it.
- To stop early, close `body`: the feeding task's next `send` fails, it closes the connection and `done` is `error("channel: closed")`. That works only while data flows. On a quiet stream (a server that has nothing to say) the task waits in its read until `timeout_ms`, so the prompt stop is `Task.cancel(stream.done)`: it closes the connection at once and `done` is an error.
- `options.timeout_ms` is the time of each wait of `open`: the connect, the head, each read of the body and each `send` to the channel. A reader that takes longer than that to ask for the next piece ends the stream, and so does a server that is silent for that long: raise it for events that come rarely. The channel holds 8 pieces, so a slow reader makes the task wait and the server's data wait in the socket.
- `upload` sends the pieces that another task puts in `body`, until it closes the channel, and returns the whole response (as `request`: up to `max_body_bytes`). `method` is `POST`, `PUT` or `PATCH`. `length` is the exact number of bytes, said as `Content-Length`: the body ends when that many bytes were sent, and the producer need not close the channel. `-1` is a chunked body, whose pieces become chunks (a piece over 512 KiB is several) and which ends when the channel closes. A body that is longer than `length`, or a channel that closes short of it, is an `error`, and so is a channel that is silent for longer than `timeout_ms`.
- A channel that closes ends the body, also when its producer died: a producer that can fail should set `length`, so that a short body is an `error`. `upload` closes the channel when it returns, so a producer that is still sending finds the closed error and stops.
- A server that answers and closes before the upload ends (a `413`) does not hide its answer: when a write fails, `upload` reads the head of the response that is waiting (for at most `timeout_ms`) and returns that response, as Python's `http.client` and Go do. Only when there is none is the write failure the `error` (`http: ` and the reason): on Windows a reset connection can drop the server's early answer, so `upload` returns the write error there. Nothing is retried, and neither call follows redirects.

```agentica {mode="check"}
import HTTP from "std/http"

def produce(into: Channel[Bytes]) -> Void
  into.send("line 1\n".bytes, 1000)
  into.send("line 2\n".bytes, 1000)
  into.close
end

def main() -> Void
  stream = HTTP.open("GET", "http://localhost:8080/log", "".bytes).unwrap!
  total = 0
  while true
    case stream.body.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  puts(total)
  puts(Task.await(stream.done).ok?)
  lines: Channel[Bytes] = Channel.new(2)
  Task.spawn(&produce, lines)
  response = HTTP.upload("PUT", "http://localhost:8080/log", lines).unwrap!
  puts(response.status)
end
```

## HTTP server

The server is in `std/http` too: a handler takes the whole request and returns the whole response. It runs one task per connection, with keep-alive.

### HTTP.listen

```text
HTTP.listen(host: String, port: Int, handler: HTTP.Handler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.Handler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
```

- `listen` returns at once and serves in the background; `listen_tls` does the same over TLS with a server `TlsContext` (`TLS.server_context`). Port 0 picks a free port (`local_port`).
- `HttpRequest` has `method`, `target` (as sent, with the query), `path` (before `?`), `headers` (names in lowercase) and `body` (`Bytes`, exactly as the client sent it, whichever the framing; decode text with [`HTTP.text`](#httptext) and `request.headers`).

A server that fetches its own page:

```agentica
import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello".bytes))
  end

  return ok(HttpResponse(status: 404, headers: [], body: "not found".bytes))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle).unwrap!
  client = HTTP.client().unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/").unwrap!
  puts("#{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
end
```

```output
200 hello
404
```

The server adds `Content-Length` (not on 204 and 304, whose body must be empty), a `Date` header unless the handler set one, and `Connection: close` when the request or response asked for it. `HEAD` gets the headers without the body.

#### Handler and middleware

`HTTP.Handler` is the type of a handler, the whole contract between a server and an application: `Fn[HttpRequest, Result[HttpResponse]]`. `HTTP.StreamHandler` is the same for `listen_stream` and `listen_stream_tls`, with `Result[HTTP.StreamResponse]`. `HTTP.UploadHandler` is the one of [`listen_upload`](#httplisten_upload), which also gets the body on a channel. `HTTP.UpgradeHandler` is the one of [`listen_websocket`](#httplisten_websocket), whose handler answers or upgrades. They are type aliases, so `&handle` is a `Handler` when `handle` has that shape, and a framework can hold, store and return handlers by that name.

A middleware is a function from a `Handler` to a `Handler`: it wraps the next handler, and may change the request before it, or the response after it, or answer without calling it. A block must follow a call, so a small helper turns the block into the value (the same reason `keep` exists in the [tour](/tour/blocks/#keep-a-block)). Middlewares stack by calling one with another's result.

```agentica
import HTTP from "std/http"

def handler(f: HTTP.Handler) -> HTTP.Handler
  return f
end

def hello(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "hello".bytes))
end

def log_answer(next: HTTP.Handler, request: HttpRequest) -> Result[HttpResponse]
  response = next.call(request)
  case response
    ok(answer) -> puts("#{request.method} #{request.path} #{answer.status}")
    error(_) -> puts("#{request.method} #{request.path} failed")
  end

  return response
end

# Logs the request line and the status of the answer; an error of the next handler passes through unchanged.
def logged(next: HTTP.Handler) -> HTTP.Handler
  return handler() do |request| log_answer(next, request) end
end

def authorized(next: HTTP.Handler, request: HttpRequest) -> Result[HttpResponse]
  if HTTP.header_values(request.headers, "authorization").empty?
    return ok(HttpResponse(status: 401, headers: [], body: "".bytes))
  end

  return next.call(request)
end

# Answers 401 to a request without an Authorization header, and does not call the next handler.
def guarded(next: HTTP.Handler) -> HTTP.Handler
  return handler() do |request| authorized(next, request) end
end

def main() -> Void
  app = logged(guarded(&hello))
  open = HttpRequest(method: "GET", target: "/", path: "/", headers: [], body: "".bytes)
  signed = HttpRequest(method: "GET", target: "/", path: "/", headers: [Header(name: "authorization", value: "token")], body: "".bytes)
  app.call(open)
  app.call(signed)
end
```

```output
GET / 401
GET / 200
```

Handler errors:

- A handler returning `error(message)` gives the client a 500 with an empty body and closes the connection. stderr gets `http: handler error: <message>`.
- A response that cannot be sent gets the same 500 and close, with `http: invalid response: <reason>` on stderr: status outside 200 to 599, a bad header, a `Content-Length` or `Transfer-Encoding` header, or a body with 204 or 304.
- A runtime error in a handler ends only its connection. The program goes on but exits with code 1 at the end, as for any unawaited task crash.

Every field of `HttpServerOptions` has the default below, so `HttpServerOptions(max_connections: 16)` changes one, and a call without `options` uses them all. The same checks as the client options apply.

| Option | Default | Bounds |
|---|---|---|
| `request_timeout_ms` | 30 s | the first request on a connection, each whole request from its first byte, and the sending of each response (the handler has no time limit) |
| `idle_timeout_ms` | 30 s | the wait between requests on a kept connection |
| `max_connections` | 128 | connections over it wait until one closes |
| `max_body_bytes` | 1 MiB | each connection can hold about four times this in memory, so lower `max_connections` when you raise it |

Bad requests never reach the handler: the server answers and closes the connection.

| Status | Cause |
|---|---|
| 400 | malformed |
| 413 | a body over `max_body_bytes` |
| 417 | an `Expect` other than `100-continue` |
| 431 | headers too long or too many |
| 501 | `CONNECT`, or `Upgrade` (except a WebSocket handshake on a `listen_websocket` server) |
| 505 | not `HTTP/1.1` |

Before closing, the server drops up to 256 KiB of the peer's remaining input, so the answer is not lost to a reset. A client still sending a large body after a 413 may see a connection reset instead.

### HTTP.listen_stream and Server-Sent Events

```text
HTTP.listen_stream(host: String, port: Int, handler: HTTP.StreamHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_stream_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.StreamHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.whole(data: Bytes) -> Channel[Bytes]

HTTP.StreamResponse(status: Int, headers: List[Header], body: Channel[Bytes], length: Optional[Int] = none)
```

For a body that is not ready when the handler returns: events, tokens as a model makes them, a big file. The handler returns a `StreamResponse` whose `body` is a [channel](/library/concurrency/task/), and a task it started sends the pieces and closes the channel at the end.

- The server sends the head at once, then each piece as it arrives, as one flushed chunk (`Transfer-Encoding: chunked`), and ends the body when the channel closes. The handler sets neither `Content-Length` nor `Transfer-Encoding`. The pieces are `Bytes`, sent as they are with no UTF-8 check, so a stream can carry a file or any binary data (a piece over 512 KiB is split into several chunks). An empty piece is skipped.
- A body whose size is known up front (a big file read in pieces) sets `length: some(n)`. The head then has `Content-Length: n` and the pieces go out raw, with no chunk framing. A body that ends short of `n`, or a piece that would pass `n`, closes the connection, so the client sees an incomplete body and never reads past the length. The body ends as soon as `n` bytes are sent, without waiting for the channel to close, so the connection serves the next request at once: the server closes the channel then, and a producer that goes on gets `error("channel: closed")` and stops. A piece after the body is full is not read; a piece that crosses `n` is the cut above. A closed body whose size is not `n` is the 500 of `listen`, as is a `length` on a 204 or 304 answer. `HEAD` gets the head with the length and no body.
- A route that answers with one text or file uses `body: HTTP.whole(data)`, a closed channel holding that `Bytes` (`"text".bytes` for a text). The server then sends `Content-Length`, as `listen` does. It does the same for any body that is already closed when the handler returns.
- The server reads the connection for the whole stream. When the client's input ends (it left, or it only half-closed its sending side) or a send fails, the server closes the channel, so the producer's next `send` returns `error("channel: closed")` and it stops. A producer that sends rarely can look at `body.closed?` as well. The body is then cut without its last chunk, so the client sees an incomplete body, not a finished one. Only the producer closing the channel ends the body cleanly.
- The producer must close the channel on every path. A producer that never closes it holds the stream until the client leaves: there is no maximum age.
- Bytes the client sends during the stream (a pipelined request) are dropped, and the connection closes when the stream ends; the server keeps watching, so a client that leaves later is still noticed.
- A bounded channel (`Channel.new(8)`) is the backpressure: a client that reads slowly makes the server wait, and so the producer's `send` waits.
- A slow producer is not an error. The wait for the next piece has no time limit, and `idle_timeout_ms` counts only between requests, from the end of a stream. `request_timeout_ms` bounds the send of each piece (and of a whole body sent with `Content-Length`): a client that stops reading for that long is cut off, and the channel closes.
- `HEAD` gets the head and the channel closes at once. A 204 or 304 status with a body that is still open, or any other response that cannot be sent, is the same 500 as for `listen`, and the channel closes.
- The server speaks HTTP/1.1 only: an HTTP/1.0 request gets a 505 before any handler runs, streaming or not.

Server-Sent Events are a stream with `Content-Type: text/event-stream` whose pieces are `data: ...` lines ended by a blank line:

```agentica
import HTTP from "std/http"

def produce(events: Channel[Bytes]) -> Void
  for n in 1..3
    if not Result.ok?(events.send("data: tick #{n}\n\n".bytes, 5000))
      break
    end

    Task.sleep(100)
  end

  events.close
end

def handle(request: HttpRequest) -> Result[HTTP.StreamResponse]
  if request.method == "GET" and request.path == "/events"
    events: Channel[Bytes] = Channel.new(8)
    Task.spawn(&produce, events)
    headers = [Header(name: "Content-Type", value: "text/event-stream"), Header(name: "Cache-Control", value: "no-cache")]
    return ok(HTTP.StreamResponse(status: 200, headers: headers, body: events))
  end

  return ok(HTTP.StreamResponse(status: 404, headers: [], body: HTTP.whole("not found\n".bytes)))
end

def main() -> Void
  server = HTTP.listen_stream("127.0.0.1", 0, &handle).unwrap!
  client = HTTP.client().unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/events").unwrap!
  puts(HTTP.header_values(response.headers, "transfer-encoding"))
  puts(HTTP.text(response.body, response.headers).unwrap!)
  puts(HTTP.get(client, base + "/missing").unwrap!.status)
  HTTP.close_client(client)
  HTTP.close_server(server)
end
```

```output
["chunked"]
data: tick 1

data: tick 2

data: tick 3


404
```

`HTTP.get` waits for the whole body, so the client above sees the events together; a browser's `EventSource` or `curl -N` sees each one as it is sent.

### HTTP.listen_upload

```text
HTTP.listen_upload(host: String, port: Int, handler: HTTP.UploadHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_upload_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.UploadHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.read_all(body: HTTP.RequestBody, max_bytes: Int) -> Result[Bytes]
```

`listen` reads the whole body before the handler runs. For an upload too big to hold, or one the handler stores as it comes (a file), `listen_upload` gives the handler the body on a channel. It is the server side of [`HTTP.upload`](#httpopen-and-httpupload), and it has the shape of `listen_stream`: another kind of handler, not a field of `HttpRequest`, so `HttpRequest`, `HTTP.Handler` and every existing handler stay as they are.

`HTTP.UploadHandler` is `Fn[HttpRequest, HTTP.RequestBody, Result[HttpResponse]]`: it gets the request with an empty `body`, the `HTTP.RequestBody`, and returns the whole response, as a `Handler` does.

- `HTTP.RequestBody` has `pieces` (a `Channel[Bytes]`) and `done` (a `Task[Result[Void]]`). A task of the server feeds `pieces` with the body as it arrives (up to 64 KiB each, never empty, a chunked body already decoded) and closes it on every path. A request with no body gets a closed channel at once.
- The handler runs the usual receive loop until the closed error, then awaits `done`: `ok` means the whole body arrived, and an `error` says why it did not (the client left, a bad chunk, a timeout). A channel can only end, so `done` is the only way to tell a whole body from a cut one: always await it.
- The channel holds 8 pieces. A handler that reads slowly makes the server wait, and the client's data waits in the socket, so memory stays bounded.
- `request_timeout_ms` is the wait of each step (each read of the socket, and each piece the handler has not taken), not the time of the whole upload. `max_body_bytes` does not apply: a streamed body is at most 256 MiB, and a handler that wants less counts the bytes and answers `413`.
- The connection stays for the next request only when the whole body had arrived by the time the handler returned. Otherwise (a handler that answers first, with a `413` or a `401`, or a body that failed) the answer gets a `Connection: close` header and the connection closes after it, so a client still sending may see the close before it reads the answer.
- `Expect: 100-continue` is answered with `100` before the handler runs, so a handler cannot refuse an upload before the client sends the body. The checks that come before the handler still answer first: a body over 256 MiB (`413`), and a `Transfer-Encoding` or `Content-Length` that is not valid.
- `HTTP.read_all(body, max_bytes)` collects the body for a handler that wants it whole, so one `listen_upload` server can serve its small routes simply: it returns the pieces joined as a `Result[Bytes]`, an `error` when the body is longer than `max_bytes` (answer `413`) or did not arrive whole (it awaits `done`).
- The handler's `error(message)` is a 500 as for `listen`. Routes that need the whole body in memory are simpler with `listen`.

A server that counts an upload, and the client call that streams one to it:

```agentica
import HTTP from "std/http"

def count(request: HttpRequest, body: HTTP.RequestBody) -> Result[HttpResponse]
  total = 0
  while true
    case body.pieces.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  try Task.await(body.done)
  return ok(HttpResponse(status: 200, headers: [], body: "#{total} bytes".bytes))
end

def feed(into: Channel[Bytes]) -> Void
  into.send("hello ".bytes, 1000)
  into.send("world".bytes, 1000)
  into.close
end

def main() -> Void
  server = HTTP.listen_upload("127.0.0.1", 0, &count).unwrap!
  into: Channel[Bytes] = Channel.new(2)
  Task.spawn(&feed, into)
  url = "http://127.0.0.1:#{HTTP.local_port(server)}/"
  response = HTTP.upload("PUT", url, into).unwrap!
  puts("#{response.status} #{HTTP.text(response.body, response.headers).unwrap!}")
  HTTP.close_server(server)
end
```

```output
200 11 bytes
```

### HTTP.listen_websocket

```text
HTTP.listen_websocket(host: String, port: Int, handler: HTTP.UpgradeHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_websocket_tls(host: String, port: Int, tls: TlsContext, handler: HTTP.UpgradeHandler, options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.accept_websocket(request: HttpRequest, session: HTTP.WebSocketSession, options: HTTP.WebSocketOptions = HTTP.WebSocketOptions()) -> Result[HTTP.Upgrade]
HTTP.upgrade_only(handler: HTTP.Handler) -> HTTP.UpgradeHandler
```

`listen_websocket` serves HTTP/1.1 as `listen` does and also upgrades a request to a WebSocket (RFC 6455). It is a fourth kind of handler next to `listen`, `listen_stream` and `listen_upload`, so `HTTP.Handler` and every existing handler stay as they are. Every other `listen` form answers a request with an `Upgrade` header 501, as before.

`HTTP.UpgradeHandler` is `Fn[HttpRequest, Result[HTTP.Upgrade]]`. `HTTP.Upgrade` is an enum: `Upgrade.Reply(response)` answers the request as `listen` does (and the connection serves the next request), and `Upgrade.Accept(...)` upgrades it; make an `Accept` with `accept_websocket`, never by hand. `upgrade_only` makes an `UpgradeHandler` from an ordinary `Handler`, so a server mixes its plain routes and its WebSocket routes, and a router such as Bond's is wrapped once.

- `accept_websocket(request, session, options)` checks the handshake: a `GET` with `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Version: 13` and a `Sec-WebSocket-Key` that is 16 bytes in base64. A request that is not one gets an `Upgrade.Reply`: `426` with `Sec-WebSocket-Version: 13` for another version, `400` for the rest. The head reader lets only a `GET` with one `Upgrade: websocket` through, so any other `Upgrade` (`h2c`, a `POST`) is the `501` of every server. A route that does not call `accept_websocket` ignores the headers.
- `session` is a `HTTP.WebSocketSession`, `Fn[HTTP.WebSocket, Result[Void]]`. The server writes the `101` answer and runs it in the task of the connection. When it returns, the server sends a close frame (code 1000, or 1011 and a warning for an `error`) unless the session already sent one, waits for the peer's close frame, and closes the connection.
- `HTTP.WebSocket` has `incoming` and `outgoing`, both `Channel[HTTP.Message]` of 8 messages, and `protocol`, the subprotocol that was agreed on (`""` for none). A handler that does not read makes the server stop reading the socket, and one that sends faster than the peer reads waits in `send`. A session must keep taking messages from `incoming` (or end): while it does not, the server does not read the socket, so pings and the peer's close go unanswered. `incoming` closes after the `Close` message, and `outgoing` closes when the connection is over, so a send then is an `error`.
- `HTTP.Message` is `Text(String)`, `Binary(Bytes)`, `Ping(Bytes)`, `Pong(Bytes)` and `Close(Int, String)`, the code and the reason. A received `Text` or `Binary` is a whole message: the fragments are joined, and a text message is checked as UTF-8. The server answers every received ping with a pong and does not hand it on; a `Pong` is handed on. A `Ping` or `Pong` carries at most 125 bytes (more is cut).
- A `Close` is the last message the handler receives, whatever ended the connection: the peer's close frame with its code and reason, a frame that broke the rules (the code of the answer: 1002, 1007 or 1009), or the loss of the connection (code 1006, since no close frame came). Sending `Close(code, reason)` starts the close handshake; a code that cannot be sent (below 1000, 1004 to 1006, 1015 to 2999, past 4999) is sent as 1011, and a reason is cut to 123 bytes.
- The server checks every frame of the peer: it must be masked, with no reserved bit, a known opcode, a control frame whole and of at most 125 bytes, fragments in order, text as UTF-8 and a close code that a peer may send. A broken frame is answered with a close frame (1002 protocol error, 1007 invalid data, 1009 too big) and the connection ends. The server never masks its frames and accepts no extension, so nothing is compressed.
- `HTTP.WebSocketOptions` has `max_message_bytes` (default 1 MiB, 1 to 256 MiB: a message past it, in one frame or joined from fragments, closes with 1009, and a frame that announces it is refused before its payload is read), `idle_ms` (default 0, no limit but a year, since a read that times out closes the socket: the longest the server waits for the peer to send anything, after which the connection is dropped and the handler gets `Close` with 1006), `ping_ms` (default 0, none: the server sends a ping after that many milliseconds with nothing to write, so with `ping_ms` below `idle_ms` the pongs keep a live peer) and `close_ms` (default 5000: how long the server waits for the peer's answer to its close frame) and `protocols` (the subprotocols it speaks, in order of preference: the first one the client offered in `Sec-WebSocket-Protocol` is agreed on).
- `request_timeout_ms` of `HttpServerOptions` bounds the handshake and each write of a frame. A WebSocket counts against `max_connections` for as long as it lives. `idle_timeout_ms` does not apply after the upgrade.
- The server does not check `Origin`. A browser sends it with every handshake, and a handler that serves pages of its own should compare it with `HTTP.header_values(request.headers, "origin")` before it accepts, since a page of another site can open a WebSocket to it with the visitor's cookies.
- Known limit: the mask of a frame is taken off in a loop over the bytes, at about 7 MB/s, so a message of a few MiB costs a fraction of a second of its connection's task. Keep `max_message_bytes` at what the application needs.

An echo server that mixes a plain route and a WebSocket route:

```agentica {mode="check"}
import HTTP from "std/http"

def relay(ws: HTTP.WebSocket, message: HTTP.Message) -> Result[Bool]
  case message
    HTTP.Message.Text(text) ->
      try ws.outgoing.send(HTTP.Message.Text("echo: #{text}"), 5000)
      return ok(true)
    HTTP.Message.Binary(data) ->
      try ws.outgoing.send(HTTP.Message.Binary(data), 5000)
      return ok(true)
    HTTP.Message.Close(_, _) -> return ok(false)
    _ -> return ok(true)
  end
end

def echo(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(60000)
      ok(message) ->
        if not try relay(ws, message)
          return ok()
        end

      error(_) -> return ok()
    end
  end

  return ok()
end

def home(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "home".bytes))
end

def route(request: HttpRequest) -> Result[HTTP.Upgrade]
  if request.path == "/echo"
    return HTTP.accept_websocket(request, &echo)
  end

  return HTTP.upgrade_only(&home).call(request)
end

def main() -> Void
  server = HTTP.listen_websocket("127.0.0.1", 8080, &route).unwrap!
  HTTP.wait(server)
end
```

### HTTP.wait and HTTP.close_server

```text
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
```

- `close_server` stops accepting, closes every connection and cancels the running handlers and their tasks. Calling it again does nothing.
- `wait` returns `ok()` once the server is closed and its handlers and their tasks have ended. A program that only serves waits on it. When `main` returns, the server stops.
- A server belongs to the task that called `HTTP.listen` and closes (freeing its port) when that task ends, so call `listen` in the task that keeps it, such as `main`. Each connection belongs to the task that serves it.

```agentica {mode="check"}
import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "you asked for #{request.path}".bytes))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 10000, max_connections: 64, max_body_bytes: 65536)
  server = HTTP.listen("0.0.0.0", 8080, &handle, options).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end
```
