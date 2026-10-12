---
title: TCP, TLS and HTTP
weight: 12
description: TCP and TLS sockets, an HTTP/1.1 client and an HTTP/1.1 server.
---

Network functions return a `Result` and take timeouts in milliseconds. Sockets,
servers and clients are handles: `IO.inspect` prints only their type (such as
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

### HTTP.client and HTTP.client_options

```text
HTTP.client() -> Result[HttpClient]
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.client_options() -> HttpClientOptions
HTTP.close_client(client: HttpClient) -> Void
```

A client keeps a pool of connections. `client_options` gives the defaults;
build an `HttpClientOptions` record to change them.

```agentica
def main() -> Void
  defaults = HTTP.client_options()
  puts(defaults.timeout_ms)
  options = HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 30000, max_connections: 2, max_body_bytes: 1048576, ca_file: "")
  client = HTTP.client(options).unwrap!
  HTTP.close_client(client)
end
```

```output
30000
```

### HTTP.get

```text
HTTP.get(client: HttpClient, url: String) -> Result[Response]
```

Sends a GET request. The `Response` has `status`, `headers` and `body`. Status
codes like 404 are normal responses, not errors.

```agentica {mode="check"}
def main() -> Void
  client = HTTP.client().unwrap!
  response = HTTP.get(client, "http://example.com/").unwrap!
  puts(response.status)
  puts(HTTP.text(response.body, 5000).unwrap!.length > 0)
end
```

### HTTP.post and HTTP.request

```text
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[Response]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[Response]
```

`post` sends a text body. `request` takes any method. Headers are
`Header(name: ..., value: ...)` records.

```agentica {mode="check"}
def main() -> Void
  client = HTTP.client().unwrap!
  headers = [Header(name: "Content-Type", value: "application/json")]
  created = HTTP.post(client, "http://localhost:8080/items", headers, "{\"name\":\"tea\"}").unwrap!
  puts(created.status)
  deleted = HTTP.request(client, "DELETE", "http://localhost:8080/items/1", [], "").unwrap!
  puts(deleted.status)
end
```

### HTTP.text, HTTP.read and HTTP.close_body

```text
HTTP.text(body: HttpBody, timeout_ms: Int) -> Result[String]
HTTP.read(body: HttpBody, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
HTTP.close_body(body: HttpBody) -> Void
```

`text` reads a whole body (up to 1 MiB) as text. `read` reads the next bytes;
`ok([])` means the body is done. `close_body` drops a body you do not want.

```agentica {mode="check"}
def main() -> Void
  client = HTTP.client().unwrap!
  response = HTTP.get(client, "http://localhost:8080/big").unwrap!
  total = 0
  chunk = HTTP.read(response.body, 65536, 5000).unwrap!
  while chunk.size > 0
    total += chunk.size
    chunk = HTTP.read(response.body, 65536, 5000).unwrap!
  end
  puts("#{total} bytes")
end
```

### HTTP.header_values and HTTP.trailers

```text
HTTP.header_values(headers: List[Header], name: String) -> List[String]
HTTP.trailers(body: HttpBody) -> Result[List[Header]]
```

`header_values` finds every value of a header, ignoring case. `trailers` gives
the trailer headers after the whole body has been read.

```agentica
def main() -> Void
  headers = [Header(name: "set-cookie", value: "a=1"), Header(name: "Set-Cookie", value: "b=2")]
  puts(HTTP.header_values(headers, "Set-Cookie"))
end
```

```output
["a=1", "b=2"]
```

### HTTP.request_stream

```text
HTTP.request_stream(client: HttpClient, method: String, url: String, headers: List[Header], length: Int, producer: Fn[A, HttpWriter, Result[Void]], argument: A) -> Result[Response]
```

Uploads a body piece by piece. The producer function gets `argument` and a
writer. A `length` of `-1` sends the body in chunks.

```agentica {mode="check"}
def send_lines(lines: List[String], writer: HttpWriter) -> Result[Void]
  for line in lines
    try HTTP.write(writer, line + "\n", 5000)
  end
  return ok()
end

def main() -> Void
  client = HTTP.client().unwrap!
  response = HTTP.request_stream(client, "POST", "http://localhost:8080/upload", [], -1, &send_lines, ["a", "b"]).unwrap!
  puts(response.status)
end
```

## HTTP server

### HTTP.listen, HTTP.local_port, HTTP.wait and HTTP.close_server

```text
HTTP.listen(host: String, port: Int, handler: Fn[Request, HttpWriter, Void], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Void]
HTTP.close_server(server: HttpServer) -> Void
HTTP.server_options() -> HttpServerOptions
```

`listen` starts a server that calls the handler for each request. A `Request`
has `method`, `target`, `path`, `headers` and `body`. `wait` blocks until the
server is closed.

```agentica {mode="check"}
def handle(request: Request, writer: HttpWriter) -> Void
  sent = HTTP.respond(writer, 200, [], "you asked for #{request.path}\n", 5000)
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 8080, &handle, HTTP.server_options()).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  done = HTTP.wait(server)
end
```

A server and a client in one program:

```agentica
def handle(request: Request, writer: HttpWriter) -> Void
  sent = HTTP.respond(writer, 200, [], "hello from #{request.path}", 2000)
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 0, &handle, HTTP.server_options()).unwrap!
  client = HTTP.client().unwrap!
  url = "http://127.0.0.1:#{HTTP.local_port(server)}/tea"
  response = HTTP.get(client, url).unwrap!
  puts(response.status)
  puts(HTTP.text(response.body, 2000))
  HTTP.close_client(client)
  HTTP.close_server(server)
end
```

```output
200
ok("hello from /tea")
```

### HTTP.listen_tls

```text
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[Request, HttpWriter, Void], options: HttpServerOptions) -> Result[HttpServer]
```

The same as `listen`, over TLS with PEM certificate and key files.

### HTTP.respond

```text
HTTP.respond(writer: HttpWriter, status: Int, headers: List[Header], text: String, timeout_ms: Int) -> Result[Void]
```

Sends a whole response in one call.

### HTTP.begin, HTTP.write, HTTP.write_bytes and HTTP.finish

```text
HTTP.begin(writer: HttpWriter, status: Int, headers: List[Header], length: Int, timeout_ms: Int) -> Result[Void]
HTTP.write(writer: HttpWriter, text: String, timeout_ms: Int) -> Result[Void]
HTTP.write_bytes(writer: HttpWriter, bytes: List[Int], timeout_ms: Int) -> Result[Void]
HTTP.finish(writer: HttpWriter, trailers: List[Header], timeout_ms: Int) -> Result[Void]
```

Stream a response in parts. A `length` of `-1` sends chunks; any other length
must match the bytes you write.

```agentica {mode="check"}
def stream(request: Request, writer: HttpWriter) -> Void
  started = HTTP.begin(writer, 200, [Header(name: "content-type", value: "text/plain")], -1, 5000)
  for n in [1, 2, 3]
    part = HTTP.write(writer, "part #{n}\n", 5000)
  end
  done = HTTP.finish(writer, [], 5000)
end

def main() -> Void
  server = HTTP.listen("127.0.0.1", 8080, &stream, HTTP.server_options()).unwrap!
  waited = HTTP.wait(server)
end
```
