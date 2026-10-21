---
title: TCP, TLS and HTTP
weight: 4
description: TCP and TLS sockets and the HTTP/1.1 client and server of std/http.
---

Network functions return a `Result` and take timeouts in milliseconds.

- Sockets, listeners, clients and servers are handles: `IO.inspect` prints `<Socket>`, they cannot be compared, and they close when the program ends.
- A handle belongs to the task that opened it and closes when that task ends, so open it in the task that keeps it. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) gives one to a new task.
- A timeout covers the whole call, including the wait for another task using the same socket. After a read or write timeout the socket is closed, and later calls fail at once with `network: socket is closed`.

## TCP

### TCP.listen and TCP.local_port

```text
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.local_port(listener: Listener) -> Int
```

Port `0` picks a free port, and `local_port` tells which (ports are 0 to 65535 here, 1 to 65535 in `connect`). The listener takes every address the host name stands for: `"localhost"` accepts `127.0.0.1` and `::1`.

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

`send` writes text. `read_line` reads one line without its line ending (LF or CRLF).

- A last line without a line ending counts when the other side closes.
- `read_line` errors at the end of input, when the connection breaks (even mid-line), and for a line over 1 MiB (which also closes the socket).
- TCP is a byte stream: one `send` can arrive in several reads and one `read_line` can cover several sends. A character split between reads is joined before the UTF-8 check.
- Reading and writing use separate locks, so one task can read while another writes.

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
TCP.send_bytes(socket: Socket, bytes: List[Int], timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
```

Raw bytes (0 to 255). `recv_bytes` gives what has arrived, up to `max_bytes`, and `ok([])` when the other side has closed.

### TCP.close and TCP.close_listener

```text
TCP.close(socket: Socket) -> Void
TCP.close_listener(listener: Listener) -> Void
```

Closing twice is fine. Close early only when it must not wait for the task to end.

## TLS

```text
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

TLS sockets and listeners use the same `TCP` functions, with the same limits and timeouts.

- `TLS.connect` uses TLS 1.2 or later and always checks the certificate and the host name (an IP address host against the certificate's IP addresses).
- An empty `ca_file` uses the system's trusted certificates, read once per process, with the ones the system distrusts rejected. `SSL_CERT_FILE` replaces the store, `SSL_CERT_DIR` adds a directory. A nonempty `ca_file` is a PEM file that replaces them.

  | System | Store |
  |---|---|
  | Linux | the CA bundle |
  | macOS | the system roots and Keychain trust settings |
  | Windows | the ROOT store (intermediates from its CA store help build a chain but are never roots) |

- `TLS.listen` takes PEM files for the certificate chain and the private key, and fails when a file is bad or the key does not match.
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

- Every call is whole: it returns after the whole response arrived. The body is a `String` and must be valid UTF-8; it is not decompressed.
- Status codes such as 404 or 500 are normal responses. `error` results are a bad URL, a refused connection, a timeout, or a body over the limit.
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
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
```

- `HttpResponse` has `status`, `headers` (names in lowercase) and `body`. `post` sends a text body; `request` takes any method.
- URLs start with `http://` or `https://`. A bracketed host (`http://[::1]:8080/`) must look like an IPv6 address, else an error result.
- The client adds `Host` and `Content-Length`; a request may not set them, nor `Transfer-Encoding` or `Connection`.

```agentica {mode="check"}
import HTTP from "std/http"

def main() -> Void
  client = HTTP.client(HTTP.client_options()).unwrap!
  headers = [Header(name: "Content-Type", value: "application/json")]
  case HTTP.post(client, "http://localhost:8080/items", headers, "{\"name\":\"tea\"}")
    ok(created) -> puts("#{created.status} #{created.body}")
    error(message) -> IO.warn(message)
  end
  deleted = HTTP.request(client, "DELETE", "http://localhost:8080/items/1", [], "")
  puts(deleted.ok?)
  HTTP.close_client(client)
end
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
- `HttpRequest` has `method`, `target` (as sent, with the query), `path` (before `?`), `headers` (names in lowercase) and `body` (valid UTF-8).

A server that fetches its own page:

```agentica
import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.method == "GET" and request.path == "/"
    return ok(HttpResponse(status: 200, headers: [Header(name: "Content-Type", value: "text/plain; charset=utf-8")], body: "hello"))
  end
  return ok(HttpResponse(status: 404, headers: [], body: "not found"))
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  client = HTTP.client(HTTP.client_options()).unwrap!
  base = "http://127.0.0.1:#{HTTP.local_port(server)}"
  response = HTTP.get(client, base + "/").unwrap!
  puts("#{response.status} #{response.body}")
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
| 400 | malformed, or a body that is not UTF-8 |
| 413 | a body over `max_body_bytes` |
| 417 | an `Expect` other than `100-continue` |
| 431 | headers too long or too many |
| 501 | `CONNECT` or `Upgrade` |
| 505 | not `HTTP/1.1` |

Before closing, the server reads and drops up to 256 KiB of the peer's remaining input (until the peer closes or the request deadline), so the answer is not lost to a reset. A peer that keeps sending is cut off at that limit, so a client still sending a large body after a 413 may see a connection reset instead.

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
  return ok(HttpResponse(status: 200, headers: [], body: "you asked for #{request.path}"))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 10000, idle_timeout_ms: 5000, max_connections: 64, max_body_bytes: 65536)
  server = HTTP.listen("0.0.0.0", 8080, &handle, options).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end
```
