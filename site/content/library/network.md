---
title: TCP, TLS and HTTP
weight: 12
description: TCP and TLS sockets and the HTTP/1.1 client of std/http.
---

Network functions return a `Result` and take timeouts in milliseconds. Sockets,
listeners and clients are handles: `IO.inspect` prints only their type (such as
`<Socket>` or `<Listener>`), they cannot be compared, and they are closed when
the program ends. Most examples here open real connections, so they are
checked but not run.

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

Close a socket or a listener. Closing twice is fine.

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
`import "std/http" as HTTP`; a call to `HTTP.get` without the import fails
with `CHECK-UNKNOWN-NAME` and a help that shows the import. It has a client
only: an HTTP server comes back in a later release.

Every call is whole: it returns after the whole response arrived, and the body
is a `String`, which must be valid UTF-8. Status codes such as 404 or 500 are
normal responses; errors (a bad URL, a refused connection, a timeout, a body
over the limit) are `error` results.

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
`max_body_bytes` at most 64 MiB.

```agentica {mode="check"}
import "std/http" as HTTP

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

```agentica {mode="check"}
import "std/http" as HTTP

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
import "std/http" as HTTP

def main() -> Void
  headers = [Header(name: "set-cookie", value: "a=1"), Header(name: "Set-Cookie", value: "b=2")]
  puts(HTTP.header_values(headers, "Set-Cookie"))
end
```

```output
["a=1", "b=2"]
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
| `HTTP.listen`, `HTTP.respond` and the other server calls | no server yet; it comes back in a later release |
| `Request`, `Response`, `HttpBody`, `HttpWriter`, `HttpServer`, `HttpServerOptions` | `HttpResponse`; the others are gone |
