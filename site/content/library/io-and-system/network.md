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
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int, cert_file: String = "", key_file: String = "") -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

TLS sockets and listeners use the same `TCP` functions, with the same limits and timeouts.

- `TLS.connect` uses TLS 1.2 or later and always checks the certificate and the host name (an IP address host against the certificate's IP addresses).
- An empty `ca_file` uses the system's trusted certificates, read once per process, with the ones the system distrusts rejected. `SSL_CERT_FILE` replaces the store, `SSL_CERT_DIR` adds a directory. A nonempty `ca_file` is a PEM file that replaces them; a missing or empty file fails the connect.

  | System | Store |
  |---|---|
  | Linux | the CA bundle |
  | macOS | the system roots and Keychain trust settings |
  | Windows | the ROOT store (intermediates from its CA store help build a chain but are never roots) |

- `TLS.listen` takes PEM files for the certificate chain and the private key, and fails when a file is bad or the key does not match.
- `TLS.connect` sends a client certificate when `cert_file` and `key_file` name PEM files, checked as `TLS.listen` checks them. Leave both empty to send none; giving only one is an error.
- A peer that closes without TLS's closing message ends the stream like EOF.

```agentica {mode="check"}
def main() -> Void
  socket = TLS.connect("example.com", 443, "", 5000).unwrap!
  sent = TCP.send(socket, "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", 5000)
  puts(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
```

## HTTP client

HTTP is the `std/http` library, written in Agentica: `import HTTP from "std/http"` (without it, `CHECK-UNKNOWN-NAME`). It works the same on Linux, macOS and Windows, over HTTP and HTTPS.

- Every call is whole: it returns after the whole response arrived. The body is `Bytes`, exactly as it came (any content, up to `max_body_bytes`); it is not decompressed. [`HTTP.text`](#httptext) decodes it as UTF-8.
- Status codes such as 404 or 500 are normal responses. `error` results are a bad URL, a refused connection, a timeout, or a body over the limit. Protocol errors start with `http: `, connection errors keep their TCP or TLS text, and a timeout is `network: operation timed out`.
- `GET`, `HEAD`, `OPTIONS`, `PUT` and `DELETE` are retried once on a new connection, within the same timeout, when the server had closed a reused connection and no response byte arrived. Other methods are never retried.
- Header names must be HTTP tokens, values Latin-1 text without control characters.

### HTTP.client and HTTP.client_options

```text
HTTP.client_options() -> HttpClientOptions
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
```

A client reuses open connections for the same scheme, host and port. `client_options()` gives the defaults; build `HttpClientOptions` to change them.

| Option | Default | Limit |
|---|---|---|
| `timeout_ms` | 30 s, for each whole call | positive |
| `idle_timeout_ms` | 30 s, for kept connections | positive |
| `max_connections` | 4, per host | positive, at most 65536 |
| `max_body_bytes` | 1 MiB | positive, at most 64 MiB |
| `ca_file` | `""`: the system's CA certificates | |

- Calls wait in FIFO order for a `max_connections` slot. A call in flight when `close_client` runs fails with `http: client is closed` (unless a connection had already started sending it).
- The client runs as Agentica code in its own tasks, so it spends the run's `--max-steps` budget.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  defaults = HTTP.client_options()
  options = HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: defaults.idle_timeout_ms,
    max_connections: 2, max_body_bytes: defaults.max_body_bytes, ca_file: "")
  client = HTTP.client(options).unwrap!
  HTTP.close_client(client)
end
```

### HTTP.get, HTTP.post and HTTP.request

```text
HTTP.get(client: HttpClient, url: String) -> Result[HttpResponse]
HTTP.post(client: HttpClient, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
```

- `HttpResponse` has `status`, `headers` (names in lowercase) and `body`, which is `Bytes`. `post` sends a `Bytes` body, as Ruby's `Net::HTTP.post(uri, data, header)` does, and `request` takes any method. Send text as `"text".bytes`, and no body as `"".bytes`. The body is at most `max_body_bytes`, and `headers` default to `[]`.
- URLs start with `http://` or `https://`. A bracketed host (`http://[::1]:8080/`) must look like an IPv6 address, else an error result.
- The client adds `Host` and `Content-Length`; a request may not set them, nor `Transfer-Encoding` or `Connection`.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client(HTTP.client_options()).unwrap!
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

### HTTP.text

```text
HTTP.text(body: Bytes, headers: List[Header] = []) -> Result[String]
```

Decodes a body as UTF-8, and nothing else. Pass the `headers` of the same message: when its `Content-Type` has a `charset`, it must be `utf-8` or `us-ascii` (any case, quoted or not), and without one the body is read as UTF-8. A body that is not valid UTF-8, or a body with any other charset (`iso-8859-1`, `shift_jis`, `utf-16`), is an `error` result: the charset error names the charset. Other charsets belong to the planned `agentica-lang/charset` package.

```agentica
import HTTP from "std/http"

def main() -> Void
  utf8 = [Header(name: "content-type", value: "text/plain; charset=UTF-8")]
  latin1 = [Header(name: "content-type", value: "text/plain; charset=iso-8859-1")]
  puts(HTTP.text("café".bytes, utf8).unwrap!)
  puts(HTTP.text("caf".bytes + Bytes.from_list([233]).unwrap!, latin1).ok?)
  puts(HTTP.text(Bytes.from_list([255, 0, 128]).unwrap!).ok?)
end
```

```output
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
HTTP.download_options() -> DownloadOptions
HTTP.download(client: HttpClient, url: String, path: String, options: DownloadOptions) -> Result[Download]
```

- `DownloadOptions` has `timeout_ms`, for the whole call, and `max_total_bytes`, for the body, at most 256 MiB. `DownloadOptions()` gives 30 s and 256 MiB, and so does `download_options()`. `Download` has `status`, `headers` and `bytes_written`; the body itself is in the file, never in the record.
- The download sends a `GET` and streams the body to `path`, so bodies may be arbitrary bytes. The file never grows past `max_total_bytes`.
- The file must not exist: it is made private to the user, so an existing path fails untouched, while a failed download keeps the partial file. Status codes such as 404 are normal responses whose body is still written, so check `status` before using the file.
- The connection is not pooled: it closes when the download ends. There is no redirect follow, and `https` keeps certificate verification on.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client(HTTP.client_options()).unwrap!
  case HTTP.download(client, "http://localhost:8080/asset", "asset.bin", HTTP.download_options())
    ok(saved) -> puts("#{saved.status} #{saved.bytes_written}")
    error(message) -> IO.warn(message)
  end

  HTTP.close_client(client)
end
```

## HTTP server

The server is in `std/http` too: a handler takes the whole request and returns the whole response. It runs one task per connection, with keep-alive.

### HTTP.listen and HTTP.server_options

```text
HTTP.server_options() -> HttpServerOptions
HTTP.listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
```

- `listen` returns at once and serves in the background; `listen_tls` does the same over TLS with a PEM certificate and key. Port 0 picks a free port (`local_port`).
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
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  client = HTTP.client(HTTP.client_options()).unwrap!
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

Handler errors:

- A handler returning `error(message)` gives the client a 500 with an empty body and closes the connection. stderr gets `http: handler error: <message>`.
- A response that cannot be sent gets the same 500 and close, with `http: invalid response: <reason>` on stderr: status outside 200 to 599, a bad header, a `Content-Length` or `Transfer-Encoding` header, or a body with 204 or 304.
- A runtime error in a handler ends only its connection. The program goes on but exits with code 1 at the end, as for any unawaited task crash.

`server_options()` gives the defaults; the same checks as the client options apply.

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
| 501 | `CONNECT` or `Upgrade` |
| 505 | not `HTTP/1.1` |

Before closing, the server drops up to 256 KiB of the peer's remaining input, so the answer is not lost to a reset. A client still sending a large body after a 413 may see a connection reset instead.

### HTTP.listen_stream and Server-Sent Events

```text
HTTP.listen_stream(host: String, port: Int, handler: Fn[HttpRequest, Result[HTTP.StreamResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_stream_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HTTP.StreamResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.whole(data: Bytes) -> Channel[Bytes]

HTTP.StreamResponse(status: Int, headers: List[Header], body: Channel[Bytes])
```

For a body that is not ready when the handler returns: events, tokens as a model makes them, a big file. The handler returns a `StreamResponse` whose `body` is a [channel](/library/concurrency/task/), and a task it started sends the pieces and closes the channel at the end.

- The server sends the head at once, then each piece as it arrives, as one flushed chunk (`Transfer-Encoding: chunked`), and ends the body when the channel closes. The handler sets neither `Content-Length` nor `Transfer-Encoding`. The pieces are `Bytes`, sent as they are with no UTF-8 check, so a stream can carry a file or any binary data (a piece over 512 KiB is split into several chunks). An empty piece is skipped.
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
  server = HTTP.listen_stream("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  client = HTTP.client(HTTP.client_options()).unwrap!
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
  options = HttpServerOptions(request_timeout_ms: 10000, idle_timeout_ms: 5000, max_connections: 64, max_body_bytes: 65536)
  server = HTTP.listen("0.0.0.0", 8080, &handle, options).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end
```
