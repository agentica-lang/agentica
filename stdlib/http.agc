## An HTTP/1.1 client and server.
##
## Import it with `import HTTP from "std/http"`. Every call is whole: it returns after the whole response arrived, and
## the body is a `String`. Status codes such as 404 or 500 are normal responses. A bad URL, a refused connection, a
## timeout or a body over the limit is an `error` result.

READ_BYTES = 65536
# Chunked framing is read in small pieces, since chunk data goes straight into text.
FRAME_BYTES = 512
SMALL_BODY = 16384
TEXT_BYTES = 1048576
BAD_TEXT = "400 request body is not valid UTF-8"

struct Target
  scheme: String
  host: String
  port: Int
  target: String
end

struct Service
  server: HttpServer
  handler: Fn[HttpRequest, Result[HttpResponse]]
  options: HttpServerOptions
end

struct Incoming
  request: HttpRequest
  rest: List[Int]
end

struct Body
  pieces: List[String]
  carry: List[Int]
end

struct Reading
  socket: Socket
  head: HttpWire.Head
  deadline: Int
  max_body_bytes: Int
end

## Returns the default client options: 30 s timeouts, up to 4 connections, 1 MiB bodies and the system CA certificates.
export def client_options() -> HttpClientOptions
  return HttpClientOptions(
    timeout_ms: 30000,
    idle_timeout_ms: 30000,
    max_connections: 4,
    max_body_bytes: 1048576,
    ca_file: "",
  )
end

## Creates a client that keeps connections open and reuses them. Every number in `options` must be positive,
## `max_connections` at most 65536 and `max_body_bytes` at most 64 MiB, or the result is an error. Close the client
## with `close_client`.
export def client(options: HttpClientOptions) -> Result[HttpClient]
  try check_options(options.timeout_ms, options.idle_timeout_ms, options.max_connections, options.max_body_bytes)
  return HttpWire.client(
    options.timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
    options.ca_file,
  )
end

## Closes the client and its connections. A call still in flight fails.
export def close_client(pool: HttpClient) -> Void
  HttpWire.close_client(pool)
end

## Sends a `GET` request to `url` and returns the response.
export def get(pool: HttpClient, url: String) -> Result[HttpResponse]
  return request(pool, "GET", url, [], "")
end

## Sends a `POST` request to `url` with `headers` and the text `body`.
export def post(pool: HttpClient, url: String, headers: List[Header], body: String) -> Result[HttpResponse]
  return request(pool, "POST", url, headers, body)
end

## Sends a request with any `method`. `url` must start with `http://` or `https://`.
## The client adds `Host` and `Content-Length` itself, so `headers` may not set them, nor `Transfer-Encoding` or
## `Connection`.
export def request(
  pool: HttpClient,
  method: String,
  url: String,
  headers: List[Header],
  body: String,
) -> Result[HttpResponse]
  where = try parse_url(url)
  return HttpWire.exchange(pool, where.scheme, where.host, where.port, method, where.target, headers, body)
end

## Returns every value of the header `name`, ignoring case, in order.
export def header_values(headers: List[Header], name: String) -> List[String]
  wanted = String.downcase(name)
  found: List[String] = []
  for header in headers
    if String.downcase(header.name) == wanted
      found = List.append(found, header.value)
    end
  end
  return found
end

## Returns the default server options: 30 s `request_timeout_ms` and `idle_timeout_ms`, 128 connections and 1 MiB
## bodies.
export def server_options() -> HttpServerOptions
  return HttpServerOptions(
    request_timeout_ms: 30000,
    idle_timeout_ms: 30000,
    max_connections: 128,
    max_body_bytes: 1048576,
  )
end

## Starts an HTTP server on `host` and `port` and returns at once; it serves in the background. `handler` takes the
## whole request and returns the whole response. Port 0 picks a free port, which `local_port` returns. The server
## closes when the task that called `listen` ends.
export def listen(
  host: String,
  port: Int,
  handler: Fn[HttpRequest, Result[HttpResponse]],
  options: HttpServerOptions,
) -> Result[HttpServer]
  try check_options(
    options.request_timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
  )
  listener = try TCP.listen(host, port)
  return ok(start(listener, handler, options))
end

## Like `listen`, but over TLS, with the PEM certificate in `cert_file` and the key in `key_file`.
export def listen_tls(
  host: String,
  port: Int,
  cert_file: String,
  key_file: String,
  handler: Fn[HttpRequest, Result[HttpResponse]],
  options: HttpServerOptions,
) -> Result[HttpServer]
  try check_options(
    options.request_timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
  )
  listener = try TLS.listen(host, port, cert_file, key_file)
  return ok(start(listener, handler, options))
end

## Returns the port the server listens on.
export def local_port(server: HttpServer) -> Int
  return HttpWire.local_port(server)
end

## Waits until the server is closed, then returns `ok()`.
export def wait(server: HttpServer) -> Result[Void]
  return HttpWire.wait(server)
end

## Stops accepting, closes every connection and cancels the running handlers. Calling it again does nothing.
export def close_server(server: HttpServer) -> Void
  HttpWire.close_server(server)
end

def check_options(timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int) -> Result[Void]
  if timeout_ms <= 0 or idle_timeout_ms <= 0 or max_connections <= 0 or max_body_bytes <= 0
    return error("http: every option must be positive")
  end
  if max_connections > 65536
    return error("http: max_connections must be at most 65536")
  end
  if max_body_bytes > 67108864
    return error("http: max_body_bytes must be at most 67108864")
  end
  return ok()
end

def first_of(text: String, part: String) -> Int
  return Result.unwrap_or(String.index_of(text, part), String.length(text))
end

def rest_of(text: String, start: Int) -> String
  return String.slice(text, start, String.length(text) - start)
end

def plain?(text: String, digits_only: Bool) -> Bool
  for c in String.split(text, "")
    code = String.code(c)
    if code < 33 or code > 126 or (digits_only and (code < 48 or code > 57))
      return false
    end
  end
  return true
end

def ipv6?(text: String) -> Bool
  if not String.contains?(text, ":")
    return false
  end
  for c in String.split(text, "")
    code = String.code(c)
    if not ((code >= 48 and code <= 58) or (code >= 65 and code <= 70) or (code >= 97 and code <= 102) or code == 46)
      return false
    end
  end
  return true
end

def bad_url() -> Result[Target]
  return error("http: the URL must be http:// or https:// with a host, and without user info")
end

def parse_url(url: String) -> Result[Target]
  split = first_of(url, "://")
  scheme = String.downcase(String.slice(url, 0, split))
  if split == String.length(url) or (scheme != "http" and scheme != "https")
    return bad_url()
  end
  rest = rest_of(url, split + 3)
  rest = String.slice(rest, 0, first_of(rest, "#"))
  stop = first_of(rest, "/")
  query = first_of(rest, "?")
  if query < stop
    stop = query
  end
  authority = String.slice(rest, 0, stop)
  target = rest_of(rest, stop)
  if not String.starts_with?(target, "/")
    target = "/#{target}"
  end
  host = authority
  port_text = ""
  if String.starts_with?(authority, "[")
    close = first_of(authority, "]")
    if close == String.length(authority)
      return bad_url()
    end
    host = String.slice(authority, 1, close - 1)
    if not ipv6?(host)
      return bad_url()
    end
    after = rest_of(authority, close + 1)
    if after != ""
      if after == ":" or not String.starts_with?(after, ":")
        return bad_url()
      end
      port_text = rest_of(after, 1)
    end
  elsif String.contains?(authority, ":")
    colon = first_of(authority, ":")
    host = String.slice(authority, 0, colon)
    port_text = rest_of(authority, colon + 1)
    if port_text == ""
      return bad_url()
    end
  end
  if host == "" or String.contains?(authority, "@") or not plain?(host, false) or not plain?(port_text, true)
    return bad_url()
  end
  port = 80
  if scheme == "https"
    port = 443
  end
  if String.length(port_text) > 5
    return error("http: the port must be 1..65535")
  end
  if port_text != ""
    port = String.to_int!(port_text)
  end
  if port < 1 or port > 65535
    return error("http: the port must be 1..65535")
  end
  return ok(Target(scheme: scheme, host: String.downcase(host), port: port, target: target))
end

def start(listener: Listener, handler: Fn[HttpRequest, Result[HttpResponse]], options: HttpServerOptions) -> HttpServer
  return HttpWire.server(listener, options.max_connections) do |server|
    accept_all(Service(server: server, handler: handler, options: options))
  end
end

def accept_all(service: Service) -> Void
  while true
    case HttpWire.accept(service.server)
      ok(socket) -> HttpWire.spawn(service.server, socket) do |s| serve(s, service) end
      error(_) -> return
    end
  end
end

def serve(socket: Socket, service: Service) -> Void
  options = service.options
  wait_ms = options.request_timeout_ms
  rest: List[Int] = []
  while true
    case read_request(socket, rest, wait_ms, options)
      ok(incoming) ->
        if not answer(socket, incoming.request, service)
          return
        end
        rest = incoming.rest
      error(_) -> return
    end
    wait_ms = options.idle_timeout_ms
  end
end

# One whole request, from the bytes left over from the last one and then the socket. The first byte may take
# first_ms; then the rest of the request has request_timeout_ms. A request that breaks the rules gets its error answer
# here, and the result is the error.
def read_request(socket: Socket, rest: List[Int], first_ms: Int, options: HttpServerOptions) -> Result[Incoming]
  data = rest
  if List.size(data) == 0
    data = try TCP.recv_bytes(socket, READ_BYTES, first_ms)
    if List.size(data) == 0
      return error("network: end of input")
    end
  end
  deadline = Time.monotonic_ms() + options.request_timeout_ms
  head = try request_head(socket, data, 0, deadline, options.max_body_bytes)
  while not head.complete
    data = List.concat(data, try more_request(socket, READ_BYTES, deadline))
    head = try request_head(socket, data, head.used, deadline, options.max_body_bytes)
  end
  reading = Reading(socket: socket, head: head, deadline: deadline, max_body_bytes: options.max_body_bytes)
  if head.expect_continue and (head.chunked or head.length > 0) and List.size(data) == head.used
    try TCP.send(socket, "HTTP/1.1 100 Continue\r\n\r\n", try time_left(socket, deadline))
  end
  if head.chunked
    return read_chunked(reading, data)
  end
  return read_length(reading, data)
end

def request_head(
  socket: Socket,
  data: List[Int],
  scanned: Int,
  deadline: Int,
  max_body_bytes: Int,
) -> Result[HttpWire.Head]
  case HttpWire.request_head(data, scanned, max_body_bytes)
    ok(head) -> return ok(head)
    error(problem) -> return error(refuse(socket, problem, deadline))
  end
end

def read_length(reading: Reading, first: List[Int]) -> Result[Incoming]
  at = reading.head.used
  take = smaller(List.size(first) - at, reading.head.length)
  body = try add_text(reading, Body(pieces: [], carry: []), first, [at, take])
  left = reading.head.length - take
  while left > 0
    piece = try more_text(reading, body.carry, smaller(left, TEXT_BYTES))
    body = Body(pieces: List.append(body.pieces, piece.text), carry: piece.carry)
    left = left - piece.bytes
  end
  return finish(reading, body, List.drop(first, at + take))
end

def read_chunked(reading: Reading, first: List[Int]) -> Result[Incoming]
  data = first
  state = try next_chunk(reading, HttpWire.chunked(reading.max_body_bytes), data, reading.head.used)
  body = try add_text(reading, Body(pieces: [], carry: []), data, state.runs)
  while not state.done
    if state.remaining > 0
      # The rest of a chunk goes straight into text; only framing goes through the decoder.
      piece = try more_text(reading, body.carry, smaller(state.remaining, TEXT_BYTES))
      body = Body(pieces: List.append(body.pieces, piece.text), carry: piece.carry)
      state = HttpWire.chunk_read(state, piece.bytes)
    else
      # A small read: chunk data past the framing is read as text above.
      data = try more_request(reading.socket, FRAME_BYTES, reading.deadline)
      state = try next_chunk(reading, state, data, 0)
      body = try add_text(reading, body, data, state.runs)
    end
  end
  return finish(reading, body, List.drop(data, state.next))
end

def next_chunk(reading: Reading, state: HttpWire.Chunk, data: List[Int], at: Int) -> Result[HttpWire.Chunk]
  case HttpWire.chunk(state, data, at)
    ok(next) -> return ok(next)
    error(problem) -> return error(refuse(reading.socket, problem, reading.deadline))
  end
end

# Adds the runs of data to the body text; an unfinished character waits in carry for the next bytes.
def add_text(reading: Reading, body: Body, data: List[Int], runs: List[Int]) -> Result[Body]
  case HttpWire.text(body.carry, data, runs)
    ok(piece) -> return ok(Body(pieces: List.append(body.pieces, piece.text), carry: piece.carry))
    error(_) -> return error(refuse(reading.socket, BAD_TEXT, reading.deadline))
  end
end

# The next bytes of a Content-Length body, read straight into text.
def more_text(reading: Reading, carry: List[Int], most: Int) -> Result[HttpWire.Text]
  left = try time_left(reading.socket, reading.deadline)
  case HttpWire.read_text(reading.socket, most, carry, left)
    ok(piece) ->
      if piece.bytes == 0
        TCP.close(reading.socket)
        return error("http: connection closed before the request was complete")
      end
      return ok(piece)
    error(message) ->
      if message == "invalid UTF-8"
        return error(refuse(reading.socket, BAD_TEXT, reading.deadline))
      end
      return error(message)
  end
end

def finish(reading: Reading, body: Body, rest: List[Int]) -> Result[Incoming]
  if List.size(body.carry) > 0
    return error(refuse(reading.socket, BAD_TEXT, reading.deadline))
  end
  head = reading.head
  request = HttpRequest(
    method: head.method,
    target: head.target,
    path: head.path,
    headers: head.headers,
    body: String.join(body.pieces, ""),
  )
  return ok(Incoming(request: request, rest: rest))
end

def smaller(a: Int, b: Int) -> Int
  if a < b
    return a
  end
  return b
end

# The next bytes of a request that has started: the end of input here closes the connection with no answer.
def more_request(socket: Socket, most: Int, deadline: Int) -> Result[List[Int]]
  data = try TCP.recv_bytes(socket, most, try time_left(socket, deadline))
  if List.size(data) == 0
    TCP.close(socket)
    return error("http: connection closed before the request was complete")
  end
  return ok(data)
end

# The milliseconds left before deadline. When none are left the socket closes, as a timeout in TCP closes it.
def time_left(socket: Socket, deadline: Int) -> Result[Int]
  left = deadline - Time.monotonic_ms()
  if left <= 0
    TCP.close(socket)
    return error("network: operation timed out")
  end
  return ok(left)
end

# Answers a bad request, closes, and returns the error text. problem is "NNN reason" from HttpWire: NNN is the
# answer's status.
def refuse(socket: Socket, problem: String, deadline: Int) -> String
  linger(socket, HttpWire.error_answer(String.to_int!(String.slice(problem, 0, 3))), deadline)
  return "http: #{rest_of(problem, 4)}"
end

# Sends text, closes the write side, and reads and drops input until the peer closes or deadline, so unread request
# bytes cannot turn the close into a reset that loses the answer. Then it closes the socket.
def linger(socket: Socket, text: String, deadline: Int) -> Void
  case time_left(socket, deadline)
    ok(left) ->
      if text == "" or Result.ok?(TCP.send(socket, text, left))
        HttpWire.close_write(socket)
        drain(socket, deadline)
      end
    error(_) -> return
  end
  TCP.close(socket)
end

def drain(socket: Socket, deadline: Int) -> Void
  while true
    case time_left(socket, deadline)
      ok(left) ->
        case TCP.recv_bytes(socket, READ_BYTES, left)
          ok(data) ->
            if List.size(data) == 0
              return
            end
          error(_) -> return
        end
      error(_) -> return
    end
  end
end

def answer(socket: Socket, request: HttpRequest, service: Service) -> Bool
  timeout = service.options.request_timeout_ms
  case service.handler.call(request)
    ok(response) ->
      case write_response(socket, request, response, timeout)
        ok(keep) -> return keep
        error(message) ->
          if String.starts_with?(message, "http: invalid response: ")
            IO.warn(message)
            failed(socket, request, timeout)
          end
      end
    error(message) ->
      IO.warn("http: handler error: #{message}")
      failed(socket, request, timeout)
  end
  return false
end

# Writes one whole response with Content-Length. ok(false) when the request or the response asked to close: the
# connection then closes as in linger.
def write_response(socket: Socket, request: HttpRequest, response: HttpResponse, timeout: Int) -> Result[Bool]
  head: List[Int] = []
  case HttpWire.encode_response(request, response, Time.now_ms())
    ok(bytes) -> head = bytes
    error(reason) -> return error("http: invalid response: #{reason}")
  end
  deadline = Time.monotonic_ms() + timeout
  body = response.body
  if request.method == "HEAD"
    body = ""
  end
  case String.from_bytes(head)
    ok(text) ->
      if String.length(body) <= SMALL_BODY
        try TCP.send(socket, text + body, timeout)
      else
        try TCP.send(socket, text, timeout)
        try TCP.send(socket, body, try time_left(socket, deadline))
      end
    error(_) ->
      try TCP.send_bytes(socket, head, timeout)
      if body != ""
        try TCP.send(socket, body, try time_left(socket, deadline))
      end
  end
  if HttpWire.closes?(request.headers) or HttpWire.closes?(response.headers)
    linger(socket, "", deadline)
    return ok(false)
  end
  return ok(true)
end

def failed(socket: Socket, request: HttpRequest, timeout: Int) -> Void
  write_response(
    socket,
    request,
    HttpResponse(status: 500, headers: [Header(name: "Connection", value: "close")], body: ""),
    timeout,
  )
end
