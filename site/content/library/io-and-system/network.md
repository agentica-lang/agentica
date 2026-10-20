---
title: TCP, TLS and HTTP
weight: 4
description: TCP and TLS sockets and the HTTP/1.1 client and server of std/http.
---

Network functions return a `Result` and take timeouts in milliseconds. Sockets,
listeners, clients and servers are handles: `IO.inspect` prints only their type (such as
`<Socket>` or `<Listener>`), they cannot be compared, and they are closed when
the program ends. Most examples here open real connections, so they are
checked but not run.

A socket, listener or server belongs to the task that opened it, and it is closed when that task ends, however it ends, so open one in the task that keeps it. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) gives one to a task it starts.

A timeout covers the whole call, including the wait for another task using
the same socket. When a read or write times out, the socket is closed, and
later calls on it fail at once with `network: socket is closed`.

## TCP

### TCP.listen and TCP.local_port

```text
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.local_port(listener: Listener) -> Int
```

Listens for connections. Port `0` picks a free port; `local_port` tells which.
The listener takes every address the host name stands for, on the same port:
`"localhost"` accepts clients of both `127.0.0.1` and `::1`. Ports go from 0
to 65535 here and from 1 to 65535 in `connect`.

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

`connect` opens a connection to a server. `accept` waits for the next client of
a listener.

```agentica {mode="check"}
def main() -> Void
  socket = TCP.connect("example.com", 80, 5000).unwrap!
  sent = TCP.send(socket, "HEAD / HTTP/1.0\r\n\r\n", 5000)
  puts(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
```

### TCP.send and TCP.read_line

```text
TCP.send(socket: Socket, text: String, timeout_ms: Int) -> Result[Void]
TCP.read_line(socket: Socket, timeout_ms: Int) -> Result[String]
```

`send` writes text. `read_line` reads one line without its line ending (LF or
CRLF). A last line without a line ending counts when the other side closes;
`read_line` returns an error at the end of input, when the connection breaks
(even in the middle of a line), and for a line over 1 MiB, which also closes
the socket. This program talks to itself, using a task for the server side:

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

TCP is a stream of bytes, not messages: one `send` can arrive in several reads, and one `read_line` can cover several sends. A character split between two reads is joined before the line is checked as UTF-8.

Reading and writing use separate locks, so one task can read while another task writes to the same socket.

### TCP.send_bytes and TCP.recv_bytes

```text
TCP.send_bytes(socket: Socket, bytes: List[Int], timeout_ms: Int) -> Result[Void]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
```

Send and receive raw bytes (0 to 255). `recv_bytes` gives what has arrived, up
to `max_bytes`, and `ok([])` when the other side has closed.

```agentica {mode="check"}
def main() -> Void
  socket = TCP.connect("127.0.0.1", 7000, 1000).unwrap!
  sent = TCP.send_bytes(socket, [1, 2, 3], 1000)
  puts(TCP.recv_bytes(socket, 1024, 1000))
  TCP.close(socket)
end
```

### TCP.close and TCP.close_listener

```text
TCP.close(socket: Socket) -> Void
TCP.close_listener(listener: Listener) -> Void
```

Close a socket or a listener. Closing twice is fine. A socket or a listener belongs to the task that opened it and is closed when that task ends, so close it yourself only when it must close earlier. Give a connection to another task with [`Task.spawn_owning`](/library/concurrency/task/#taskspawn_owning), and that task closes it when it ends.

## TLS

```text
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

TLS sockets and listeners use the same `TCP` functions, with the same limits
and timeouts. `TLS.connect` uses TLS 1.2 or later and always checks the
certificate and the host name (an IP address host is checked against the
certificate's IP addresses). An empty `ca_file` uses the system's trusted
certificates (`SSL_CERT_FILE` replaces the system bundle, and `SSL_CERT_DIR` adds a directory of certificates); a nonempty
`ca_file` is a PEM file that replaces them. `TLS.listen` takes PEM files for
the certificate chain and the private key, and fails when a file is bad or the
key does not match. A peer that closes without TLS's closing message ends the
stream like EOF.

```agentica {mode="check"}
def main() -> Void
  socket = TLS.connect("example.com", 443, "", 5000).unwrap!
  sent = TCP.send(socket, "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", 5000)
  puts(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
```

## HTTP client

HTTP is the `std/http` library, written in Agentica. Import it with
`import HTTP from "std/http"`; a call to `HTTP.get` without the import fails
with `CHECK-UNKNOWN-NAME` and a help that shows the import. It has a client
(this section) and a server (the next one).

Every call is whole: it returns after the whole response arrived, and the body
is a `String`, which must be valid UTF-8. Status codes such as 404 or 500 are
normal responses; errors (a bad URL, a refused connection, a timeout, a body
over the limit) are `error` results.

A `GET`, `HEAD`, `OPTIONS`, `PUT` or `DELETE` sent on a reused connection that the server had already closed is retried once on a new connection, within the same timeout, when no response byte arrived; `POST`, `PATCH` and the other methods are never retried. The body is not decompressed: `Content-Encoding` stays as the server sent it. Header names must be HTTP tokens, and header values must be Latin-1 text without control characters. A handler that sets `Content-Length` or `Transfer-Encoding` gets a 500 with an empty body.

### HTTP.client and HTTP.client_options

```text
HTTP.client_options() -> HttpClientOptions
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Void
```

A client keeps open connections and reuses them for the same scheme, host and
port. `client_options()` gives the defaults: a 30 s `timeout_ms` for each
whole call, a 30 s `idle_timeout_ms` for kept connections, 4
`max_connections` per host and a 1 MiB `max_body_bytes`, with the system's
CA certificates (`ca_file: ""`). Build `HttpClientOptions` to change them;
every number must be positive, `max_connections` at most 65536 and
`max_body_bytes` at most 64 MiB. Calls wait in FIFO order for one of the `max_connections` slots. A call still in flight when `close_client` runs fails with `http: client is closed`. The client's work runs as Agentica code in tasks of its own, so it spends the `--max-steps` budget of the run.

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

The `HttpResponse` has `status`, `headers` (names in lowercase) and `body`.
`post` sends a text body; `request` takes any method. URLs start with
`http://` or `https://`. The client adds `Host` and `Content-Length` itself,
so a request may not set them, nor `Transfer-Encoding` or `Connection`.

A host in brackets, as in `http://[::1]:8080/`, must look like an IPv6 address (hex digits, `:` and `.`); any other bracketed host is an error result.

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

`header_values` finds every value of a header, ignoring case, in order.

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

The server is part of `std/http` too. A handler takes the whole request and returns the whole response; the server reads requests, calls the handler and writes its answers, one task per connection, with keep-alive.

### HTTP.listen and HTTP.server_options

```text
HTTP.server_options() -> HttpServerOptions
HTTP.listen(host: String, port: Int, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
```

`listen` returns at once and serves in the background; `listen_tls` does the same over TLS with a PEM certificate and key. Port 0 picks a free port, which `local_port` returns. The `HttpRequest` has `method`, `target` (as sent, with the query), `path` (the target before `?`), `headers` (names in lowercase) and `body` (valid UTF-8). This program serves itself and fetches its own page:

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

The server adds `Content-Length` (not on 204 and 304, whose body must be empty), a `Date` header unless the handler set one, and `Connection: close` when the request or the response asked for it. A `HEAD` request gets the headers without the body. When the handler returns `error(message)`, or a response that cannot be sent (a status outside 200 to 599, a bad header, a `Content-Length` or `Transfer-Encoding` header, a body with 204 or 304), the client gets a 500 with an empty body, the connection closes, and stderr gets one line: `http: handler error: <message>` or `http: invalid response: <reason>`. A runtime error in a handler ends only its connection: the client sees the connection close, and the program goes on, but it exits with code 1 at the end, as for any task crash nothing awaited.

`server_options()` gives a 30 s `request_timeout_ms`, a 30 s `idle_timeout_ms`, 128 `max_connections` and a 1 MiB `max_body_bytes`, with the same checks as the client options. `request_timeout_ms` bounds the wait for the first request on a connection, then each whole request from its first byte, then the sending of each response from the moment the handler returns; the handler itself has no time limit. `idle_timeout_ms` bounds the wait between requests on a kept connection. Connections over `max_connections` wait until one closes. Bad requests never reach the handler: the server answers 400 (malformed, or a body that is not UTF-8), 413 (a body over `max_body_bytes`), 417 (an `Expect` other than `100-continue`), 431 (headers too long or too many), 501 (`CONNECT`, `Upgrade`) or 505 (not `HTTP/1.1`) and closes the connection. Each connection can hold about four times `max_body_bytes` in memory, so when you raise `max_body_bytes`, lower `max_connections`.

### HTTP.wait and HTTP.close_server

```text
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
```

`close_server` stops accepting, closes every connection and cancels the running handlers and every task they started. Calling it again does nothing. `wait` returns `ok()` once the server is closed, so a program that only serves waits on it. When `main` returns, the server stops with the program. A server belongs to the task that called `HTTP.listen`: when that task ends, the server is closed and its port is free, so call `listen` in the task that keeps the server, such as `main`. Each connection belongs to the task that serves it, so a crash in a handler closes only its connection.

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

### Moving from the builtin HTTP module

Earlier versions had a builtin `HTTP` module. Add the import, then:

| Before | Now |
|---|---|
| `HTTP.client()` | `HTTP.client(HTTP.client_options())` |
| `HTTP.text(response.body, timeout)` | `response.body` |
| `HTTP.read`, `HTTP.trailers`, `HTTP.close_body`, `HTTP.request_stream` | a whole `HTTP.request`; streaming is planned |
| binary bodies read with `HTTP.read` | no replacement yet: a body that is not UTF-8 is an error |
| `max_body_bytes` of 64 MiB by default | 1 MiB by default |
| `timeout_ms` for the response headers | `timeout_ms` for the whole response |
| a handler `def handle(request: Request, writer: HttpWriter) -> Void` | `def handle(request: HttpRequest) -> Result[HttpResponse]` |
| `HTTP.respond(writer, status, headers, text, timeout)` | `return ok(HttpResponse(status: status, headers: headers, body: text))` |
| `HTTP.begin`, `HTTP.write`, `HTTP.write_bytes`, `HTTP.finish` | one whole `HttpResponse`; streaming responses are planned |
| `header_timeout_ms` in `HttpServerOptions` | `request_timeout_ms` |
| `Request`, `Response`, `HttpBody`, `HttpWriter` | `HttpRequest` and `HttpResponse`; the others are gone |
