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

- Every call of the client is whole: it returns after the whole response arrived (for a body read piece by piece, see [`HTTP.start`](#httpstart-httpsend_request-httpread_body-and-httpfinish), and for a body on a channel, [`HTTP.open`](#httpopen-and-httpupload)). The body is `Bytes`, exactly as it came (any content, up to `max_body_bytes`); it is not decompressed. [`HTTP.text`](#httptext) decodes it as UTF-8.
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
| `ca_file` | `""`: the system's CA certificates | |

- Calls wait in FIFO order for a `max_connections` slot. A call in flight when `close_client` runs fails with `http: client is closed` (unless a connection had already started sending it).
- The client runs as Agentica code in its own tasks, so it spends the run's `--max-steps` budget.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client(HttpClientOptions(timeout_ms: 5000, max_connections: 2)).unwrap!
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

- `start` takes an origin (`http://host`, `https://host:8443`) with no path or query, and connects now. `https` verifies the certificate with `options.ca_file` (the system's by default). Only `timeout_ms` and `max_body_bytes` of the options apply: `timeout_ms` is the time of each call (the connect, each `send_request`, each `read_body`), and `max_body_bytes` the largest request body.
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
- A server that answers and closes before the upload ends (a `413`) does not hide its answer: when a write fails, `upload` reads the head of the response that is waiting (for at most `timeout_ms`) and returns that response, as Python's `http.client` and Go do. Only when there is none is the write failure the `error` (`http: ` and the reason). Nothing is retried, and neither call follows redirects.

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
HTTP.listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
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
| 501 | `CONNECT` or `Upgrade` |
| 505 | not `HTTP/1.1` |

Before closing, the server drops up to 256 KiB of the peer's remaining input, so the answer is not lost to a reset. A client still sending a large body after a 413 may see a connection reset instead.

### HTTP.listen_stream and Server-Sent Events

```text
HTTP.listen_stream(host: String, port: Int, handler: Fn[HttpRequest, Result[HTTP.StreamResponse]], options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
HTTP.listen_stream_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HTTP.StreamResponse]], options: HttpServerOptions = HttpServerOptions()) -> Result[HttpServer]
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
