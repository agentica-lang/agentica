## An HTTP/1.1 client and server.
##
## Import it with `import HTTP from "std/http"`. Every call is whole: it returns after the whole response arrived, and
## every body is `Bytes`, as it came over the wire; `text` decodes one as UTF-8. Status codes such as 404 or 500 are
## normal responses. A bad URL, a refused connection, a timeout or a body over the limit is an `error` result.

READ_BYTES = 65536
# Chunked framing is read in small pieces, so the decoder sees the bytes of a chunk's framing and no more.
FRAME_BYTES = 512
# A body of at most this many bytes goes in the same send as the head.
SMALL_BODY = 16384
# The most bytes of one read of a body (TCP.recv_bytes takes at most 1 MiB).
BODY_READ_BYTES = 1048576
BAD_TEXT = "400 request body is not valid UTF-8"
# The least time an error answer gets to be sent, even past the request deadline.
ANSWER_MS = 100
# The most input the lingering close reads and drops (as Go's net/http does). It is enough for a peer that sent a
# request in flight when the answer left, and it stops a peer from making the server read for the whole deadline.
DRAIN_BYTES = 262144
# The client's jobs channel holds this many messages before a sender waits.
CLIENT_JOBS = 1024
# The owner task has no deadline of its own: a timeout of its wait only starts the next one.
OWNER_WAIT_MS = 86400000
# How long a caller waits past its deadline for the worker's answer.
REPLY_GRACE_MS = 100
MAX_INTERIM = 15
CLIENT_CLOSED = "http: client is closed"
TIMED_OUT = "network: operation timed out"
CUT_SHORT = "http: connection closed before the response was complete"
TRUNCATED = "http: truncated HTTP body"
TOO_LARGE = "http: body exceeds max_body_bytes"
BAD_BODY = "http: body is not valid UTF-8"
# Texts of the C builtins that std/http matches on (vm/channel.c, vm/tcp.c); each is marked there.
CHANNEL_CLOSED = "channel: closed"
END_OF_INPUT = "network: end of input"
READ_FAILED = "error reading from stream port"
# The answer of a call whose worker or owner task crashed.
FAILED = "http: connection failed"
# No bytes: the empty rest and carry.
NO_BYTES = "".bytes
# The longest a streamed response may wait for its body channel before it looks again. A close of the channel wakes the
# wait at once, so this only bounds a task that is never woken.
STREAM_POLL_MS = 60000
# How long the watcher of a streamed response waits for the client to send or close (a year): a live stream is not
# idle, and a timeout of a read closes the socket.
WATCH_MS = 31536000000
HEX_DIGITS = "0123456789abcdef"
# How a stream's pump ended.
STREAM_CUT = 0
STREAM_DONE = 1
STREAM_EARLY = 2
# The most bytes of a piece in one chunk, and of one TCP.send_bytes (1 MiB at most, with the chunk framing around it).
CHUNK_BYTES = 524288
SEND_BYTES = 1048576
NO_BODY = "a 204 or 304 response cannot have a body"
CRLF = "\r\n".bytes
# The widest body a download may write, in bytes. The client and server bodies stay capped at 64 MiB by
# check_options; only a download streamed to a file may use up to this. DownloadOptions.max_total_bytes defaults to
# this value as a literal (a field default cannot name a constant), so the two must match.
DOWNLOAD_MAX_BYTES = 268435456

struct Target
  scheme: String
  host: String
  port: Int
  target: String
end

# What a server's handler returns: a whole response, or one whose body is a channel (listen_stream).
enum Route
  Whole(Fn[HttpRequest, Result[HttpResponse]])
  Streaming(Fn[HttpRequest, Result[StreamResponse]])
end

struct Service
  server: HttpServer
  route: Route
  options: HttpServerOptions
end

# How a request was answered: whether the connection stays, and the bytes already read of its next request.
struct Sent
  keep: Bool
  rest: Bytes
end

# The pieces a body channel holds right now, and whether the channel is closed with nothing more to come.
struct Ready
  pieces: List[Bytes]
  ended: Bool
end

# What the watcher task of a streamed response needs: the connection, the body to close when the client leaves, and two
# one-slot channels that tell the stream what the watcher saw: left (the client's input ended, so the body was cut, not
# finished) and sent (the client sent bytes while the stream ran).
struct Watch
  socket: Socket
  body: Channel[Bytes]
  left: Channel[Bool]
  sent: Channel[Bool]
end

struct Incoming
  request: HttpRequest
  rest: Bytes
end

struct Body
  pieces: List[String]
  carry: Bytes
end

struct Reading
  socket: Socket
  head: HttpWire.Head
  deadline: Int
  max_body_bytes: Int
end

# The client's owner task keeps, per origin ("scheme://host:port"), the connections open, the idle workers (the one
# freed last at the end) and the jobs that wait for a connection, oldest first from index front: taking one moves
# front, and the list is compacted now and then, so a long queue costs no copy per job.
struct Origin
  open: Int
  idle: List[Int]
  waiting: List[HttpWire.Job]
  front: Int
end

# busy holds the reply channel of each worker's last job, not the job, so a large body is not kept alive.
struct Pool
  client: HttpClient
  options: HttpClientOptions
  jobs: Channel[HttpWire.Job]
  origins: Map[String, Origin]
  inboxes: Map[Int, Channel[HttpWire.Job]]
  busy: Map[Int, Channel[Result[HttpResponse]]]
  next_id: Int
end

# A worker owns one connection. It gets its jobs one at a time on inbox, and tells the owner on jobs when it is free
# or gone.
struct Worker
  id: Int
  # The client, for the TLS context its https connections share (HttpWire.connect_tls).
  client: HttpClient
  options: HttpClientOptions
  jobs: Channel[HttpWire.Job]
  inbox: Channel[HttpWire.Job]
  # The first job without its head and body, with this worker's id: the message that says the worker is gone.
  notice: HttpWire.Job
end

struct Placed
  pool: Pool
  placed: Bool
end

struct Done
  socket: Result[Socket]
  answer: Result[HttpResponse]
  kept: Bool
end

struct Attempt
  answer: Result[HttpResponse]
  kept: Bool
  retry: Bool
end

struct Answer
  socket: Socket
  job: HttpWire.Job
  max_body_bytes: Int
end

# A response read, or why not; started is true once any byte of it came, which rules out a retry.
struct Received
  response: Result[HttpResponse]
  kept: Bool
  started: Bool
end

## How far a download may go: a positive `timeout_ms` for the whole call, from the connect to the last byte
## written, and a positive `max_total_bytes` for the body, at most 256 MiB.
export struct DownloadOptions
  ## The milliseconds the whole download may take.
  timeout_ms: Int = 30000
  ## The most body bytes written to the file.
  max_total_bytes: Int = 268435456
end

## What a download wrote: the response `status` and `headers` with the count of body `bytes_written` to the file.
## The body itself is in the file, never in this record.
export struct Download
  ## The response status, however high: 404 and 500 are normal responses, as with `get`.
  status: Int
  ## The response headers.
  headers: List[Header]
  ## How many body bytes went to the file.
  bytes_written: Int
end

## A response whose body is sent as it is produced: the `status` and `headers` of the head, and a `body` channel of
## pieces. The handler returns it at once and a task it spawned sends the pieces and closes the channel at the end. The
## server sends each piece as soon as it arrives and ends the body when the channel closes. When the client leaves, the
## server closes the channel, so the producer's next `send` returns an error and it stops.
export struct StreamResponse
  ## The status, 200 to 599, and not 204 or 304 unless the body is already closed and empty.
  status: Int
  ## The response headers. The server adds `Transfer-Encoding: chunked` or `Content-Length`: the handler sets neither.
  headers: List[Header]
  ## The pieces of the body, as `Bytes` of any content (an empty one is skipped).
  body: Channel[Bytes]
end

struct Whole
  body: Bytes
  kept: Bool
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
  if String.contains?(options.ca_file, String.from_code(0))
    return error("http: ca_file cannot contain NUL")
  end
  jobs: Channel[HttpWire.Job] = Channel.new(CLIENT_JOBS)
  return ok(HttpWire.service(jobs, options) do |own| supervise_pool(own) end)
end

## Closes the client and its connections. A call still in flight fails with `http: client is closed`; its request
## is not sent, unless a connection had already started sending it.
export def close_client(pool: HttpClient) -> Void
  Channel.close(HttpWire.jobs(pool))
end

## Sends a `GET` request to `url` and returns the response, whose `body` is `Bytes`.
export def get(pool: HttpClient, url: String) -> Result[HttpResponse]
  return request(pool, "GET", url, NO_BYTES)
end

## Sends a `POST` request to `url` with the `Bytes` `body` and `headers`, which default to none, as Ruby's
## `Net::HTTP.post(uri, data, header)` does. Send text as `"...".bytes`.
export def post(pool: HttpClient, url: String, body: Bytes, headers: List[Header] = []) -> Result[HttpResponse]
  return request(pool, "POST", url, body, headers)
end

## Sends a request with any `method`. `url` must start with `http://` or `https://`.
## The client adds `Host` and `Content-Length` itself, so `headers` may not set them, nor `Transfer-Encoding` or
## `Connection`. The `body` is `Bytes` of at most `max_body_bytes` (`"".bytes` sends none); `headers` default to none.
export def request(
  pool: HttpClient,
  method: String,
  url: String,
  body: Bytes,
  headers: List[Header] = [],
) -> Result[HttpResponse]
  where = try parse_url(url)
  options = HttpWire.options(pool)
  head = try HttpWire.encode_request(
    where.scheme,
    where.host,
    where.port,
    method,
    where.target,
    headers,
    body,
    options.max_body_bytes,
  )
  deadline = Time.monotonic_ms() + options.timeout_ms
  reply: Channel[Result[HttpResponse]] = Channel.new(1)
  job = HttpWire.Job(
    origin: "#{where.scheme}://#{where.host}:#{where.port}",
    scheme: where.scheme,
    host: where.host,
    port: where.port,
    method: method,
    head: head,
    body: body,
    deadline: deadline,
    reply: reply,
    worker: 0,
    kept: false,
  )
  case HttpWire.jobs(pool).send(job, options.timeout_ms)
    ok(_) -> return wait_reply(reply, deadline)
    error(message) ->
      if message == CHANNEL_CLOSED
        return error(CLIENT_CLOSED)
      end
      return error(TIMED_OUT)
  end
end

## Returns the default download options: a 30 s timeout and bodies up to 256 MiB. `DownloadOptions()` gives the same.
export def download_options() -> DownloadOptions
  return DownloadOptions()
end

## Downloads the resource at `url` with a `GET` request and writes its body bytes to `path`.
##
## The transfer stays bounded: at most 1 MiB is held at once, the body stops at
## `options.max_total_bytes` with `http: body exceeds max_body_bytes`, and the file never grows past it. The file
## must not exist: it is made with `create_private`, so an existing path is an error and stays intact, while a
## failed download keeps the partial file. Status codes such as 404 or 500 are normal responses, as with `get`:
## the body is still written and the status returned, so check `status` before using the file. There is no
## redirect follow, and the connection is not pooled: it closes when the download ends. The pool gives the TLS
## context and its certificates for `https`, whose verification stays on.
export def download(pool: HttpClient, url: String, path: String, options: DownloadOptions) -> Result[Download]
  if options.timeout_ms <= 0 or options.max_total_bytes <= 0
    return error("http: every download option must be positive")
  end
  if options.max_total_bytes > DOWNLOAD_MAX_BYTES
    return error("http: max_total_bytes must be at most 268435456")
  end
  where = try parse_url(url)
  client_options = HttpWire.options(pool)
  head = try HttpWire.encode_request(
    where.scheme,
    where.host,
    where.port,
    "GET",
    where.target,
    [],
    NO_BYTES,
    client_options.max_body_bytes,
  )
  deadline = Time.monotonic_ms() + options.timeout_ms
  socket = try connect_download(pool, where, deadline)
  case TCP.send(socket, head, try time_left(socket, deadline))
    ok(_) -> return finish_download(socket, path, options, deadline)
    error(message) ->
      TCP.close(socket)
      return error(message)
  end
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

## Returns `body` as a `String`, decoding it as UTF-8 and nothing else. `headers` are those of the same message
## (`response.headers`): when its `Content-Type` has a `charset`, it must be `utf-8`; without one the body is read as
## UTF-8. A body that is not valid UTF-8, or any other charset, is an `error` result; the charset error names the
## charset. Other charsets (Latin-1, Windows-1252, Shift_JIS, UTF-16) are for the `agentica-lang/charset` package.
export def text(body: Bytes, headers: List[Header] = []) -> Result[String]
  charset = charset_of(headers)
  if charset != "" and charset != "utf-8" and charset != "utf8"
    return error("http: charset #{charset} is not supported, decode the body with agentica-lang/charset")
  end
  case String.from_bytes(body)
    ok(decoded) -> return ok(decoded)
    error(_) -> return error(BAD_BODY)
  end
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
  return ok(start(listener, Route.Whole(handler), options))
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
  return ok(start(listener, Route.Whole(handler), options))
end

## Like `listen`, but the handler returns a `StreamResponse`, whose body is a channel the server sends as pieces arrive
## (chunked, each piece flushed), for Server-Sent Events or any body that is not ready when the handler returns. Answer
## the routes that are one text with `HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole(text))`.
export def listen_stream(
  host: String,
  port: Int,
  handler: Fn[HttpRequest, Result[StreamResponse]],
  options: HttpServerOptions,
) -> Result[HttpServer]
  try check_options(
    options.request_timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
  )
  listener = try TCP.listen(host, port)
  return ok(start(listener, Route.Streaming(handler), options))
end

## Like `listen_stream`, but over TLS, with the PEM certificate in `cert_file` and the key in `key_file`.
export def listen_stream_tls(
  host: String,
  port: Int,
  cert_file: String,
  key_file: String,
  handler: Fn[HttpRequest, Result[StreamResponse]],
  options: HttpServerOptions,
) -> Result[HttpServer]
  try check_options(
    options.request_timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
  )
  listener = try TLS.listen(host, port, cert_file, key_file)
  return ok(start(listener, Route.Streaming(handler), options))
end

## Returns a closed channel that holds `data` as its one piece: the body of a `StreamResponse` that is one whole
## text or file. The server then answers with `Content-Length`, as `listen` does.
export def whole(data: Bytes) -> Channel[Bytes]
  body: Channel[Bytes] = Channel.new(1)
  if not data.empty?
    body.send(data, 0)
  end
  body.close
  return body
end

## Returns the port the server listens on.
export def local_port(server: HttpServer) -> Int
  return HttpWire.local_port(server)
end

## Returns `ok()` once the server and its tasks are done.
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

# The charset parameter of the first Content-Type header, in lowercase and unquoted; "" when there is none.
def charset_of(headers: List[Header]) -> String
  types = header_values(headers, "content-type")
  if List.size(types) == 0
    return ""
  end
  parameters = String.split(List.at(types, 0), ";")
  for parameter in List.drop(parameters, 1)
    at = first_of(parameter, "=")
    if at < parameter.length and parameter.slice(0, at).strip.downcase == "charset"
      value = rest_of(parameter, at + 1).strip
      if value.length >= 2 and value.starts_with?("\"") and value.ends_with?("\"")
        value = value.slice(1, value.length - 2)
      end
      return value.downcase
    end
  end
  return ""
end

def first_of(text: String, part: String) -> Int
  return text.index_of(part).unwrap_or(text.length)
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

def start(listener: Listener, route: Route, options: HttpServerOptions) -> HttpServer
  return HttpWire.server(listener, options.max_connections) do |server|
    accept_all(Service(server: server, route: route, options: options))
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
  rest = NO_BYTES
  while true
    case read_request(socket, rest, wait_ms, options)
      ok(incoming) ->
        sent = answer(socket, incoming, service)
        if not sent.keep
          return
        end
        rest = sent.rest
      error(_) -> return
    end
    wait_ms = options.idle_timeout_ms
  end
end

# One whole request. rest holds the bytes the last chunked body read past its end. The first byte may take first_ms;
# then the rest of the request has request_timeout_ms. A request that breaks the rules gets its error answer here, and
# the result is the error.
def read_request(socket: Socket, rest: Bytes, first_ms: Int, options: HttpServerOptions) -> Result[Incoming]
  first = rest
  if first.empty?
    first = try TCP.recv_bytes(socket, 1, first_ms)
    if first.empty?
      return error(END_OF_INPUT)
    end
  end
  deadline = Time.monotonic_ms() + options.request_timeout_ms
  head = try read_head(socket, first, deadline, options.max_body_bytes)
  reading = Reading(socket: socket, head: head, deadline: deadline, max_body_bytes: options.max_body_bytes)
  if head.expect_continue and (head.chunked or head.length > 0) and head.buffered == 0
    try TCP.send(socket, "HTTP/1.1 100 Continue\r\n\r\n", try time_left(socket, deadline))
  end
  if head.chunked
    return read_chunked(reading)
  end
  return read_length(reading)
end

# The head stays in the socket's input until it is whole (HttpWire.read_head), so a slow head holds no bytes here.
def read_head(socket: Socket, rest: Bytes, deadline: Int, max_body_bytes: Int) -> Result[HttpWire.Head]
  left = try time_left(socket, deadline)
  case HttpWire.read_head(socket, rest, max_body_bytes, left)
    ok(head) ->
      if head.status > 0
        return error(refuse(socket, head.status, head.reason, deadline))
      end
      return ok(head)
    error(message) ->
      TCP.close(socket)
      return error(message)
  end
end

def read_length(reading: Reading) -> Result[Incoming]
  body = Body(pieces: [], carry: NO_BYTES)
  left = reading.head.length
  while left > 0
    piece = try more_text(reading, body.carry, smaller(left, BODY_READ_BYTES))
    body = Body(pieces: List.append(body.pieces, piece.text), carry: piece.carry)
    left = left - piece.bytes
  end
  return finish(reading, body, NO_BYTES)
end

def read_chunked(reading: Reading) -> Result[Incoming]
  data = NO_BYTES
  state = HttpWire.chunked(reading.max_body_bytes)
  body = Body(pieces: [], carry: NO_BYTES)
  while not state.done
    if state.remaining > 0
      # The rest of a chunk goes straight into text; only framing goes through the decoder.
      piece = try more_text(reading, body.carry, smaller(state.remaining, BODY_READ_BYTES))
      body = Body(pieces: List.append(body.pieces, piece.text), carry: piece.carry)
      state = HttpWire.chunk_read(state, piece.bytes)
    else
      # A small read: chunk data past the framing is read as text above.
      data = try more_request(reading.socket, FRAME_BYTES, reading.deadline)
      state = try next_chunk(reading, state, data)
      body = try add_text(reading, body, data, state.runs)
    end
  end
  return finish(reading, body, data.drop(state.next))
end

def next_chunk(reading: Reading, state: HttpWire.Chunk, data: Bytes) -> Result[HttpWire.Chunk]
  case HttpWire.chunk(state, data, 0)
    ok(next) -> return ok(next)
    error(problem) -> return error(refuse_problem(reading.socket, problem, reading.deadline))
  end
end

# Adds the runs of data to the body text; an unfinished character waits in carry for the next bytes.
def add_text(reading: Reading, body: Body, data: Bytes, runs: List[Int]) -> Result[Body]
  piece = HttpWire.text(body.carry, data, runs)
  if not piece.valid
    return error(refuse_problem(reading.socket, BAD_TEXT, reading.deadline))
  end
  return ok(Body(pieces: List.append(body.pieces, piece.text), carry: piece.carry))
end

# The next bytes of a body, read straight into text.
def more_text(reading: Reading, carry: Bytes, most: Int) -> Result[HttpWire.Text]
  left = try time_left(reading.socket, reading.deadline)
  piece = try HttpWire.read_text(reading.socket, most, carry, left)
  if not piece.valid
    return error(refuse_problem(reading.socket, BAD_TEXT, reading.deadline))
  end
  if piece.bytes == 0
    TCP.close(reading.socket)
    return error("http: connection closed before the request was complete")
  end
  return ok(piece)
end

def finish(reading: Reading, body: Body, rest: Bytes) -> Result[Incoming]
  if not body.carry.empty?
    return error(refuse_problem(reading.socket, BAD_TEXT, reading.deadline))
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
def more_request(socket: Socket, most: Int, deadline: Int) -> Result[Bytes]
  data = try TCP.recv_bytes(socket, most, try time_left(socket, deadline))
  if data.empty?
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

# Answers a bad request, closes, and returns the error text.
def refuse(socket: Socket, status: Int, reason: String, deadline: Int) -> String
  linger(socket, HttpWire.error_answer(status), deadline)
  return "http: #{reason}"
end

# refuse for a problem written "NNN reason" (HttpWire.chunk, BAD_TEXT): NNN is the answer's status.
def refuse_problem(socket: Socket, problem: String, deadline: Int) -> String
  return refuse(socket, String.to_int!(String.slice(problem, 0, 3)), rest_of(problem, 4), deadline)
end

# Sends text, closes the write side, and reads and drops input until the peer closes, deadline, or DRAIN_BYTES bytes,
# so unread request bytes cannot turn the close into a reset that loses the answer. Then it closes the socket. The
# answer gets at least ANSWER_MS even when the deadline has passed; only the drain is bound by the deadline and the
# byte limit.
def linger(socket: Socket, text: String, deadline: Int) -> Void
  wait = deadline - Time.monotonic_ms()
  if wait < ANSWER_MS
    wait = ANSWER_MS
  end
  if text == "" or Result.ok?(TCP.send(socket, text, wait))
    HttpWire.close_write(socket)
    drain(socket, deadline)
  end
  TCP.close(socket)
end

def drain(socket: Socket, deadline: Int) -> Void
  rest = DRAIN_BYTES
  while rest > 0
    most = READ_BYTES
    if rest < most
      most = rest
    end
    case time_left(socket, deadline)
      ok(left) ->
        case TCP.recv_bytes(socket, most, left)
          ok(data) ->
            if data.empty?
              return
            end
            rest = rest - data.size
          error(_) -> return
        end
      error(_) -> return
    end
  end
end

def answer(socket: Socket, incoming: Incoming, service: Service) -> Sent
  options = service.options
  case service.route
    Route.Whole(handler) ->
      keep = false
      case handler.call(incoming.request)
        ok(response) -> keep = reply_whole(socket, incoming.request, response, options.request_timeout_ms)
        error(message) ->
          IO.warn("http: handler error: #{message}")
          failed(socket, incoming.request, options.request_timeout_ms)
      end
      return Sent(keep: keep, rest: incoming.rest)
    Route.Streaming(handler) ->
      case handler.call(incoming.request)
        ok(response) -> return answer_stream(socket, incoming, response, options)
        error(message) ->
          IO.warn("http: handler error: #{message}")
          failed(socket, incoming.request, options.request_timeout_ms)
      end
      return Sent(keep: false, rest: NO_BYTES)
  end
end

# Sends a whole response; true when the connection stays. A response that cannot be sent gets a 500 and a close.
def reply_whole(socket: Socket, request: HttpRequest, response: HttpResponse, timeout: Int) -> Bool
  case write_response(socket, request, response, timeout)
    ok(keep) -> return keep
    error(message) ->
      if String.starts_with?(message, "http: invalid response: ")
        IO.warn(message)
        failed(socket, request, timeout)
      end
  end
  return false
end

# A streamed response. A body that is already closed is the whole body, which goes out with Content-Length as for
# listen. Otherwise the head goes now, with chunked framing, and each piece follows as it arrives.
def answer_stream(socket: Socket, incoming: Incoming, response: StreamResponse, options: HttpServerOptions) -> Sent
  request = incoming.request
  timeout = options.request_timeout_ms
  ready = take_ready(response.body)
  head_only = HttpResponse(status: response.status, headers: response.headers, body: NO_BYTES)
  case HttpWire.encode_response(request, head_only, Time.now_ms())
    ok(reply) ->
      bodyless = response.status == 204 or response.status == 304
      if ready.ended
        data = Bytes.concat(ready.pieces)
        if bodyless and not data.empty?
          return invalid_stream(socket, request, response.body, NO_BODY, timeout)
        end
        return send_whole(socket, incoming, reply, data, timeout)
      end
      if bodyless
        return invalid_stream(socket, request, response.body, NO_BODY, timeout)
      end
      return stream_out(socket, incoming, response.body, ready.pieces, reply, options)
    error(reason) -> return invalid_stream(socket, request, response.body, reason, timeout)
  end
end

# A body that was complete when the handler returned, with its Content-Length (the encoded head says 0, as its body
# there is empty; a 204 or 304 head has no length and no body). A HEAD request gets the head alone.
def send_whole(socket: Socket, incoming: Incoming, reply: HttpWire.Reply, data: Bytes, timeout: Int) -> Sent
  deadline = Time.monotonic_ms() + timeout
  head = String.replace(reply.head, "\r\nContent-Length: 0\r\n", "\r\nContent-Length: #{data.size}\r\n")
  sent = ok()
  if incoming.request.method == "HEAD" or data.empty?
    sent = TCP.send(socket, head, timeout)
  else
    sent = send_all(socket, head.bytes + data, timeout)
  end
  if not Result.ok?(sent)
    return Sent(keep: false, rest: NO_BYTES)
  end
  if reply.closes
    linger(socket, "", deadline)
    return Sent(keep: false, rest: NO_BYTES)
  end
  return Sent(keep: true, rest: incoming.rest)
end

# Sends bytes in the pieces TCP.send_bytes takes. The whole send has `timeout`, not each piece.
def send_all(socket: Socket, data: Bytes, timeout: Int) -> Result[Void]
  deadline = Time.monotonic_ms() + timeout
  at = 0
  while at < data.size
    count = smaller(SEND_BYTES, data.size - at)
    try TCP.send_bytes(socket, data.slice(at, count), try time_left(socket, deadline))
    at = at + count
  end
  return ok()
end

def invalid_stream(socket: Socket, request: HttpRequest, body: Channel[Bytes], reason: String, timeout: Int) -> Sent
  IO.warn("http: invalid response: #{reason}")
  body.close
  failed(socket, request, timeout)
  return Sent(keep: false, rest: NO_BYTES)
end

# What the body channel holds without waiting. It has ended when the receive fails because the channel is closed and
# empty, which the receive itself says, so a producer that sends and closes meanwhile loses nothing.
def take_ready(body: Channel[Bytes]) -> Ready
  pieces: List[Bytes] = []
  ended = false
  more = true
  while more
    case body.recv(0)
      ok(piece) -> pieces = List.append(pieces, piece)
      error(message) ->
        ended = message == CHANNEL_CLOSED
        more = false
    end
  end
  return Ready(pieces: pieces, ended: ended)
end

# The encoded head says Content-Length: 0 (the body there is empty); a stream has no length, so it says chunked.
def chunked_head(head: String) -> String
  return String.replace(head, "\r\nContent-Length: 0\r\n", "\r\nTransfer-Encoding: chunked\r\n")
end

# Sends the head and then the body as chunks. A HEAD request gets the head and the channel closes, so the producer
# stops. A task watches the socket for the whole stream, so a client that leaves is noticed even when the producer is
# idle: the end of its input closes the body, and the body is then cut, without the last chunk, so the client sees an
# incomplete body. Bytes the client sends during the stream (a pipelined request) are dropped, and the connection
# closes when the stream ends. Otherwise the watcher's read is the wait for the next request.
def stream_out(
  socket: Socket,
  incoming: Incoming,
  body: Channel[Bytes],
  first: List[Bytes],
  reply: HttpWire.Reply,
  options: HttpServerOptions,
) -> Sent
  timeout = options.request_timeout_ms
  if not Result.ok?(TCP.send(socket, chunked_head(reply.head), timeout))
    body.close
    return Sent(keep: false, rest: NO_BYTES)
  end
  if incoming.request.method == "HEAD"
    body.close
    return Sent(keep: end_head(socket, reply, timeout), rest: incoming.rest)
  end
  left: Channel[Bool] = Channel.new(1)
  sent: Channel[Bool] = Channel.new(1)
  watcher = Task.spawn(&watch, Watch(socket: socket, body: body, left: left, sent: sent))
  ended = pump(socket, body, first, left, sent, timeout)
  if ended == STREAM_CUT
    TCP.close(socket)
    return Sent(keep: false, rest: NO_BYTES)
  end
  if reply.closes or not incoming.rest.empty? or ended == STREAM_EARLY
    return end_stream(socket, watcher, timeout)
  end
  return next_request(socket, watcher, options.idle_timeout_ms)
end

# The connection closes after the stream, as linger does: the write side first, then the peer gets the rest of the time
# to close its side, so a reset cannot lose the last chunk.
def end_stream(socket: Socket, watcher: Task[Result[Bytes]], timeout: Int) -> Sent
  HttpWire.close_write(socket)
  case Task.await(watcher, timeout)
    Await.Done(_) -> drain(socket, Time.monotonic_ms() + timeout)
    Await.TimedOut -> TCP.close(socket)
  end
  TCP.close(socket)
  return Sent(keep: false, rest: NO_BYTES)
end

# After a HEAD response: false when the connection closes.
def end_head(socket: Socket, reply: HttpWire.Reply, timeout: Int) -> Bool
  if reply.closes
    linger(socket, "", Time.monotonic_ms() + timeout)
    return false
  end
  return true
end

# The stream ended and the client is still there: the watcher's read is the first byte of its next request.
def next_request(socket: Socket, watcher: Task[Result[Bytes]], idle_ms: Int) -> Sent
  case Task.await(watcher, idle_ms)
    Await.Done(read) ->
      case read
        ok(data) ->
          if not data.empty?
            return Sent(keep: true, rest: data)
          end
        error(_) -> TCP.close(socket)
      end
    Await.TimedOut -> TCP.close(socket)
  end
  return Sent(keep: false, rest: NO_BYTES)
end

# Sends the pieces as they come, then the last chunk. The wait for a piece has no deadline of its own: a slow producer
# is not an error, and the client leaving, the producer closing or the server closing all wake it. A piece gets
# `timeout` to be sent, so a client that stops reading cuts the stream. STREAM_CUT when the body was cut: a send failed
# (the channel is closed for the producer) or the watcher saw the client leave (left has a value). Only a producer's
# close sends the last chunk. STREAM_EARLY when the client sent bytes during the stream (sent has a value, read before
# the last chunk goes out: after it the client may send its next request), STREAM_DONE otherwise.
def pump(
  socket: Socket,
  body: Channel[Bytes],
  first: List[Bytes],
  left: Channel[Bool],
  sent: Channel[Bool],
  timeout: Int,
) -> Int
  for piece in first
    if not Result.ok?(send_piece(socket, piece, timeout))
      body.close
      return STREAM_CUT
    end
  end
  while true
    case body.recv(STREAM_POLL_MS)
      ok(piece) ->
        if not Result.ok?(send_piece(socket, piece, timeout))
          body.close
          return STREAM_CUT
        end
      error(message) ->
        if message == CHANNEL_CLOSED
          break
        end
    end
  end
  if Result.ok?(left.recv(0))
    return STREAM_CUT
  end
  early = Result.ok?(sent.recv(0))
  if not Result.ok?(TCP.send(socket, "0\r\n\r\n", timeout))
    return STREAM_CUT
  end
  if early
    return STREAM_EARLY
  end
  return STREAM_DONE
end

# The piece as chunks: the size in hex, the bytes and the CRLFs, in one send so a chunk is one flush. A piece over
# CHUNK_BYTES is several chunks, all within `timeout`. An empty piece would read as the last chunk, so it sends
# nothing. The bytes go as they are: no UTF-8 check runs on a piece.
def send_piece(socket: Socket, piece: Bytes, timeout: Int) -> Result[Void]
  deadline = Time.monotonic_ms() + timeout
  at = 0
  while at < piece.size
    count = smaller(CHUNK_BYTES, piece.size - at)
    part = piece.slice(at, count)
    chunk = Bytes.concat(["#{hex_of(count)}\r\n".bytes, part, CRLF])
    try TCP.send_bytes(socket, chunk, try time_left(socket, deadline))
    at = at + count
  end
  return ok()
end

def hex_of(number: Int) -> String
  digits = ""
  rest = number
  while rest > 0
    digits = String.slice(HEX_DIGITS, rest % 16, 1) + digits
    rest = rest / 16
  end
  return digits
end

# Reads the socket for the whole stream. The end of the client's input, or a read error, means it left: left is set and
# the body closes, which stops the producer and the sending. Bytes while the stream runs are dropped and set sent (so
# the connection closes at the end), before the body is looked at, since the pump reads sent as the body ends. The read
# goes on, so a client that leaves later is still noticed. Once the body has ended, the first bytes are the start of
# the client's next request and go back as the result.
def watch(watching: Watch) -> Result[Bytes]
  while true
    case TCP.recv_bytes(watching.socket, READ_BYTES, WATCH_MS)
      ok(data) ->
        if data.empty?
          watching.left.send(true, 0)
          watching.body.close
          return ok(data)
        end
        # Set before the test: a pump that ends the stream in between must see these bytes as early, not as a request.
        watching.sent.send(true, 0)
        if watching.body.closed?
          return ok(data)
        end
      error(message) ->
        watching.left.send(true, 0)
        watching.body.close
        return error(message)
    end
  end
  return ok(NO_BYTES)
end

# Writes one whole response with Content-Length. ok(false) when the request or the response asked to close: the
# connection then closes as in linger.
def write_response(socket: Socket, request: HttpRequest, response: HttpResponse, timeout: Int) -> Result[Bool]
  case HttpWire.encode_response(request, response, Time.now_ms())
    ok(reply) -> return send_response(socket, request, response, reply, timeout)
    error(reason) -> return error("http: invalid response: #{reason}")
  end
end

def send_response(
  socket: Socket,
  request: HttpRequest,
  response: HttpResponse,
  reply: HttpWire.Reply,
  timeout: Int,
) -> Result[Bool]
  deadline = Time.monotonic_ms() + timeout
  body = response.body
  if request.method == "HEAD"
    body = NO_BYTES
  end
  if body.size <= SMALL_BODY
    try send_all(socket, reply.head.bytes + body, timeout)
  else
    try TCP.send(socket, reply.head, timeout)
    try send_all(socket, body, try time_left(socket, deadline))
  end
  if reply.closes
    linger(socket, "", deadline)
    return ok(false)
  end
  return ok(true)
end

def failed(socket: Socket, request: HttpRequest, timeout: Int) -> Void
  write_response(
    socket,
    request,
    HttpResponse(status: 500, headers: [Header(name: "Connection", value: "close")], body: NO_BYTES),
    timeout,
  )
end

# The worker answers by the deadline; the grace only covers its last steps.
def wait_reply(reply: Channel[Result[HttpResponse]], deadline: Int) -> Result[HttpResponse]
  case reply.recv(larger(deadline - Time.monotonic_ms(), 0) + REPLY_GRACE_MS)
    ok(answer) -> return answer
    error(_) -> return error(TIMED_OUT)
  end
end

# The client's service task (HttpWire.service runs it, and it owns jobs). It awaits the owner as a Result task, so a
# crash of the owner is observed here, not reported as unobserved. After a crash the client is closed: later calls
# get "http: client is closed", the workers are cancelled with the owner, and calls in flight time out.
def supervise_pool(client: HttpClient) -> Void
  jobs = HttpWire.jobs(client)
  options = HttpWire.options(client)
  pool = Pool(client: client, options: options, jobs: jobs, origins: {}, inboxes: {}, busy: {}, next_id: 1)
  Task.await(Task.spawn(&run_pool, pool))
  jobs.close
  # Connections still open or in their handshake keep the context until they end.
  HttpWire.drop_tls(client)
end

# The client's owner task: it hands each job to an idle worker of its origin, or to a new worker while the origin has
# fewer than max_connections open, or queues it. It ends when the client is closed.
def run_pool(pool: Pool) -> Result[Void]
  jobs = pool.jobs
  while true
    case jobs.recv(OWNER_WAIT_MS)
      ok(job) ->
        if job.worker == 0
          pool = dispatch(pool, job)
        elsif job.kept
          pool = freed(pool, job)
        else
          pool = gone(pool, job)
        end
      error(_) ->
        if jobs.closed?
          shut_pool(pool)
          return ok()
        end
    end
  end
  return ok()
end

def origin_of(pool: Pool, key: String) -> Origin
  return Map.get(pool.origins, key, Origin(open: 0, idle: [], waiting: [], front: 0))
end

# An origin with no connection and no waiting job is dropped, so the map does not grow with every host called.
def with_origin(pool: Pool, key: String, origin: Origin) -> Pool
  if origin.open == 0 and queued(origin) == 0
    return pool.with(origins: Map.delete(pool.origins, key))
  end
  return pool.with(origins: Map.put(pool.origins, key, origin))
end

def dispatch(pool: Pool, job: HttpWire.Job) -> Pool
  if Time.monotonic_ms() >= job.deadline or not HttpWire.awaited?(job.reply)
    return pool
  end
  result = place(pool, job)
  if result.placed
    return result.pool
  end
  origin = origin_of(result.pool, job.origin)
  return with_origin(result.pool, job.origin, origin.with(waiting: List.append(origin.waiting, job)))
end

# Gives job to the idle worker freed last, or to a new worker when a slot is free. A worker that has just timed out
# has closed its inbox: the send fails, and the next idle worker is tried.
def place(pool: Pool, job: HttpWire.Job) -> Placed
  origin = origin_of(pool, job.origin)
  while List.size(origin.idle) > 0
    last = List.size(origin.idle) - 1
    id = List.at(origin.idle, last)
    origin = origin.with(idle: List.take(origin.idle, last))
    case Map.get(pool.inboxes, id)
      some(inbox) ->
        if Result.ok?(inbox.send(job, 0))
          pool = with_origin(pool, job.origin, origin).with(busy: Map.put(pool.busy, id, job.reply))
          return Placed(pool: pool, placed: true)
        end
      none -> origin = origin
    end
  end
  pool = with_origin(pool, job.origin, origin)
  if origin.open >= pool.options.max_connections
    return Placed(pool: pool, placed: false)
  end
  pool = with_origin(pool, job.origin, origin.with(open: origin.open + 1))
  id = pool.next_id
  # The first job waits in the new worker's inbox, so no task keeps it (and its body) for the life of the worker.
  inbox: Channel[HttpWire.Job] = Channel.new(1)
  # A new channel with room for one: this send cannot fail.
  inbox.send(job, 0)
  notice = job.with(head: "", body: NO_BYTES, worker: id, kept: false)
  worker = Worker(id: id, client: pool.client, options: pool.options, jobs: pool.jobs, inbox: inbox, notice: notice)
  Task.spawn(&supervise, worker)
  pool = pool.with(inboxes: Map.put(pool.inboxes, id, inbox), busy: Map.put(pool.busy, id, job.reply), next_id: id + 1)
  return Placed(pool: pool, placed: true)
end

# The worker is free and keeps its connection: it takes the oldest waiting job, or stays idle. Its job is answered,
# so its entry in busy goes: a reply the caller never read is not kept alive while the worker idles.
def freed(pool: Pool, message: HttpWire.Job) -> Pool
  origin = origin_of(pool, message.origin)
  pool = pool.with(busy: Map.delete(pool.busy, message.worker))
  pool = with_origin(pool, message.origin, origin.with(idle: List.append(origin.idle, message.worker)))
  if queued(origin) == 0
    return pool
  end
  return next_waiting(pool, message.origin)
end

# The worker has closed its connection and ended: its slot goes to the oldest waiting job. Its last job's reply gets
# FAILED: a worker that crashed never answered it, and a worker that did answer filled the channel, so the send
# fails, or the caller has taken its answer and nobody reads the channel again.
def gone(pool: Pool, message: HttpWire.Job) -> Pool
  id = message.worker
  case Map.get(pool.busy, id)
    some(reply) -> reply.send(error(FAILED), 0)
    none -> id = id
  end
  origin = origin_of(pool, message.origin)
  idle = List.filter(origin.idle) do |k| k != id end
  pool = pool.with(busy: Map.delete(pool.busy, id), inboxes: Map.delete(pool.inboxes, id))
  pool = with_origin(pool, message.origin, origin.with(open: origin.open - 1, idle: idle))
  return next_waiting(pool, message.origin)
end

# The oldest waiting job that still has time goes out, if a worker or a slot takes it. The caller of a job past its
# deadline has returned its timeout already, and a caller that gave up on its reply was cancelled, so such a job is
# dropped, never sent. A caller that has not parked on its reply yet has not given up.
def next_waiting(pool: Pool, key: String) -> Pool
  origin = origin_of(pool, key)
  while queued(origin) > 0
    job = List.at(origin.waiting, origin.front)
    rest = popped(origin)
    if Time.monotonic_ms() < job.deadline and HttpWire.awaited?(job.reply)
      result = place(with_origin(pool, key, rest), job)
      if result.placed
        return result.pool
      end
      kept = origin_of(result.pool, key).with(waiting: origin.waiting, front: origin.front)
      return with_origin(result.pool, key, kept)
    end
    origin = rest
  end
  return with_origin(pool, key, origin)
end

def queued(origin: Origin) -> Int
  return List.size(origin.waiting) - origin.front
end

# The origin without its oldest waiting job. The taken jobs are dropped once they are half of the list.
def popped(origin: Origin) -> Origin
  front = origin.front + 1
  if front == List.size(origin.waiting)
    return origin.with(waiting: [], front: 0)
  end
  if front >= 32 and front * 2 >= List.size(origin.waiting)
    return origin.with(waiting: List.drop(origin.waiting, front), front: 0)
  end
  return origin.with(front: front)
end

# The client is closed: every job still waiting or in flight fails now, and the idle workers close their
# connections. A job still in a worker's inbox is not sent: the worker sees the close before it runs a job. A worker
# in flight ends when its exchange does; its answer then finds the reply channel full.
def shut_pool(pool: Pool) -> Void
  for origin in Map.values(pool.origins)
    for job in List.drop(origin.waiting, origin.front)
      job.reply.send(error(CLIENT_CLOSED), 0)
    end
  end
  for reply in Map.values(pool.busy)
    reply.send(error(CLIENT_CLOSED), 0)
  end
  for inbox in Map.values(pool.inboxes)
    inbox.close
  end
end

# Runs a worker as a Result task and awaits it, so a crash is observed here, not reported as unobserved, and the
# owner always hears that the worker is gone (the crash closed its socket).
def supervise(worker: Worker) -> Void
  case Task.await(Task.spawn(&work, worker))
    ok(_) -> return
    error(_) ->
      worker.inbox.close
      worker.jobs.send(worker.notice, OWNER_WAIT_MS)
  end
end

# A worker: it runs its first job (already in its inbox) on a new connection, then the jobs the owner gives it on
# that connection, until the connection cannot be kept or stays idle for idle_timeout_ms.
def work(worker: Worker) -> Result[Void]
  job = try worker.inbox.recv(0)
  socket: Result[Socket] = error("")
  while true
    # A closed client has answered every job it handed out with CLIENT_CLOSED, this one too, while it could still
    # wait in the inbox (a receive takes buffered jobs before it reports the close): it is not sent.
    if worker.jobs.closed?
      job.reply.send(error(CLIENT_CLOSED), 0)
      close_socket(socket)
      return ok()
    end
    done = run_job(worker, socket, job)
    # The caller gave up on the reply (cancelled, or its wait timed out): the connection is closed, not pooled, so a
    # timed-out call leaves no connection behind (site/content/library/concurrency/task.md, Task.map).
    awaited = HttpWire.awaited?(job.reply)
    job.reply.send(done.answer, 0)
    # The idle wait below keeps job only for its origin and reply.
    job = job.with(head: "", body: NO_BYTES)
    if not done.kept or not awaited
      close_socket(done.socket)
      tell(worker, job, false)
      return ok()
    end
    socket = done.socket
    if not tell(worker, job, true)
      close_socket(socket)
      return ok()
    end
    case worker.inbox.recv(worker.options.idle_timeout_ms)
      ok(next) -> job = next
      error(_) ->
        # Closed first, so the owner cannot hand over a job after the last look; one given before the close is
        # still taken.
        worker.inbox.close
        case worker.inbox.recv(0)
          ok(next) -> job = next
          error(_) ->
            close_socket(socket)
            tell(worker, job, false)
            return ok()
        end
    end
  end
  return ok()
end

def close_socket(socket: Result[Socket]) -> Void
  case socket
    ok(s) -> TCP.close(s)
    error(_) -> return
  end
end

# Tells the owner that this worker is free (kept) or gone; false when the client is closed.
def tell(worker: Worker, job: HttpWire.Job, kept: Bool) -> Bool
  message = job.with(worker: worker.id, kept: kept)
  return Result.ok?(worker.jobs.send(message, OWNER_WAIT_MS))
end

# One job: on the worker's connection when it has one, else on a new one. A reused connection that fails before any
# byte of the response is retried once on a new connection, for the methods that may be sent twice.
def run_job(worker: Worker, socket: Result[Socket], job: HttpWire.Job) -> Done
  reused = Result.ok?(socket)
  if not reused
    socket = connect(worker, job)
  end
  case socket
    ok(s) ->
      attempt = exchange(Answer(socket: s, job: job, max_body_bytes: worker.options.max_body_bytes), reused)
      if not attempt.retry
        return Done(socket: socket, answer: attempt.answer, kept: attempt.kept)
      end
      TCP.close(s)
      return run_job(worker, error(""), job)
    error(message) -> return Done(socket: socket, answer: error(message), kept: false)
  end
end

def connect(worker: Worker, job: HttpWire.Job) -> Result[Socket]
  left = job.deadline - Time.monotonic_ms()
  if left <= 0
    return error(TIMED_OUT)
  end
  if job.scheme == "https"
    return HttpWire.connect_tls(worker.client, job.host, job.port, left)
  end
  return TCP.connect(job.host, job.port, left)
end

def idempotent?(method: String) -> Bool
  return method == "GET" or method == "HEAD" or method == "OPTIONS" or method == "PUT" or method == "DELETE"
end

# Sends the request and reads the response. A large body is written by a task of its own while the response is
# read, so an answer that comes before the upload ends (an early 413) is read; a small one fits in the socket's
# buffers. A response read after the request failed to go out is still the answer.
def exchange(answer: Answer, reused: Bool) -> Attempt
  job = answer.job
  socket = answer.socket
  left = job.deadline - Time.monotonic_ms()
  if left <= 0
    TCP.close(socket)
    return Attempt(answer: error(TIMED_OUT), kept: false, retry: false)
  end
  if job.body.size <= SMALL_BODY
    sent = send_all(socket, job.head.bytes + job.body, left)
    return finish_exchange(answer, read_response(answer), sent, reused)
  end
  writer = Task.spawn(&send_request, answer)
  received = read_response(answer)
  if not Result.ok?(received.response)
    TCP.close(socket)
  end
  sent: Result[Void] = ok()
  # A writer still busy 1 ms after the whole response came means the server answered before it read the body (an
  # early 413, say). Waiting for the rest until the deadline could keep the connection, but holds the call; closing
  # gives the answer now and loses only the reuse of this connection.
  case Task.await(writer, 1)
    Await.Done(result) -> sent = result
    Await.TimedOut ->
      # The response came before the whole request went out: the connection cannot be kept.
      TCP.close(socket)
      sent = Task.await(writer)
  end
  return finish_exchange(answer, received, sent, reused)
end

def send_request(answer: Answer) -> Result[Void]
  left = answer.job.deadline - Time.monotonic_ms()
  if left <= 0
    return error(TIMED_OUT)
  end
  return send_all(answer.socket, answer.job.head.bytes + answer.job.body, left)
end

# A failure before any byte of the response (the end of input, a read or a write error) is retried on a reused
# connection. When the request did not go out and no response came, the write error is the answer.
def finish_exchange(answer: Answer, received: Received, sent: Result[Void], reused: Bool) -> Attempt
  kept = received.kept and Result.ok?(sent)
  if not kept
    TCP.close(answer.socket)
  end
  case received.response
    ok(response) -> return Attempt(answer: ok(response), kept: kept, retry: false)
    error(message) ->
      lost = message == END_OF_INPUT or String.starts_with?(message, READ_FAILED)
      retry = reused and idempotent?(answer.job.method) and not received.started
      case sent
        error(problem) -> return Attempt(answer: error(problem), kept: false, retry: retry)
        ok(_) ->
          if message == END_OF_INPUT
            message = CUT_SHORT
          end
          return Attempt(answer: error(message), kept: false, retry: retry and lost)
      end
  end
end

def failed_read(message: String, started: Bool) -> Received
  return Received(response: error(message), kept: false, started: started)
end

# The response head (after at most MAX_INTERIM interim ones) and its body.
def read_response(answer: Answer) -> Received
  job = answer.job
  interim = 0
  while true
    case time_left(answer.socket, job.deadline)
      ok(left) ->
        case HttpWire.read_response(answer.socket, job.method == "HEAD", answer.max_body_bytes, left)
          ok(head) ->
            if head.status >= 200
              return read_body(answer, head)
            end
            interim = interim + 1
            if interim > MAX_INTERIM
              return failed_read("http: too many interim responses", true)
            end
          error(message) ->
            if interim > 0 and message == END_OF_INPUT
              return failed_read(CUT_SHORT, true)
            end
            broken = String.starts_with?(message, READ_FAILED)
            first = message == END_OF_INPUT or broken
            return failed_read(message, interim > 0 or not first)
        end
      error(message) -> return failed_read(message, interim > 0)
    end
  end
  return failed_read(TIMED_OUT, true)
end

# A connection is kept only when nothing follows the response in its input and the input has not ended: bytes there
# are a server bug or a response nobody asked for, and the next call must not read them; after an end of input the
# next call would fail. The body is the bytes the framing carries, whatever they hold.
def read_body(answer: Answer, head: HttpWire.Response) -> Received
  whole: Result[Whole] = error("")
  if head.chunked
    whole = read_chunked_body(answer)
  elsif head.until_close
    whole = read_until_close(answer)
  elsif head.length == 0
    whole = ok(Whole(body: NO_BYTES, kept: head.buffered == 0 and not head.ended))
  else
    whole = read_length_body(answer, head.length)
  end
  case whole
    ok(done) ->
      response = HttpResponse(status: head.status, headers: head.headers, body: done.body)
      return Received(response: ok(response), kept: done.kept and not head.closes, started: true)
    error(message) -> return failed_read(message, true)
  end
end

# The next bytes of a body, at most most of them; no bytes means the end of input.
def more_body(answer: Answer, most: Int) -> Result[Bytes]
  return recv_body(answer.socket, most, answer.job.deadline)
end

def read_length_body(answer: Answer, length: Int) -> Result[Whole]
  pieces: List[Bytes] = []
  left = length
  while left > 0
    data = try more_body(answer, smaller(left, BODY_READ_BYTES))
    if data.empty?
      return error(TRUNCATED)
    end
    pieces = List.append(pieces, data)
    left = left - data.size
  end
  return ok(Whole(body: Bytes.concat(pieces), kept: nothing_buffered(answer)))
end

# Bytes read past the end of the body, or still in the input after it, stop the connection from being kept. Framing
# goes through the decoder, whose runs say which bytes of each framing read are body.
def read_chunked_body(answer: Answer) -> Result[Whole]
  data = NO_BYTES
  state = HttpWire.chunked(answer.max_body_bytes)
  pieces: List[Bytes] = []
  while not state.done
    if state.remaining > 0
      data = try more_body(answer, smaller(state.remaining, BODY_READ_BYTES))
      if data.empty?
        return error(TRUNCATED)
      end
      pieces = List.append(pieces, data)
      state = HttpWire.chunk_read(state, data.size)
    else
      data = try more_body(answer, FRAME_BYTES)
      if data.empty?
        return error(TRUNCATED)
      end
      case HttpWire.chunk(state, data, 0)
        ok(next) -> state = next
        error(problem) -> return error("http: #{rest_of(problem, 4)}")
      end
      pieces = add_runs(pieces, data, state.runs)
    end
  end
  return ok(Whole(body: Bytes.concat(pieces), kept: state.next == data.size and nothing_buffered(answer)))
end

# The pieces with the runs of data (start, length pairs) added.
def add_runs(pieces: List[Bytes], data: Bytes, runs: List[Int]) -> List[Bytes]
  at = 0
  while at < List.size(runs)
    pieces = List.append(pieces, data.slice(List.at(runs, at), List.at(runs, at + 1)))
    at = at + 2
  end
  return pieces
end

# Whether the socket's input holds no byte now and has not ended: a read of 0 bytes does not wait.
def nothing_buffered(answer: Answer) -> Bool
  case time_left(answer.socket, answer.job.deadline)
    ok(left) ->
      case HttpWire.read_text(answer.socket, 0, NO_BYTES, left)
        ok(piece) -> return piece.buffered == 0 and not piece.ended
        error(_) -> return false
      end
    error(_) -> return false
  end
end

# A body that ends with the connection: over TLS the end must be the peer's close_notify.
def read_until_close(answer: Answer) -> Result[Whole]
  pieces: List[Bytes] = []
  total = 0
  while true
    data = try more_body(answer, BODY_READ_BYTES)
    if data.empty?
      if not HttpWire.clean_eof?(answer.socket)
        return error(TRUNCATED)
      end
      return ok(Whole(body: Bytes.concat(pieces), kept: false))
    end
    total = total + data.size
    if total > answer.max_body_bytes
      return error(TOO_LARGE)
    end
    pieces = List.append(pieces, data)
  end
  return error(TRUNCATED)
end

# One download connection: on a new socket, which closes when the download ends, since the pool only runs
# whole-response calls. The pool gives the TLS context and its certificates for https.
def connect_download(pool: HttpClient, where: Target, deadline: Int) -> Result[Socket]
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return error(TIMED_OUT)
  end
  if where.scheme == "https"
    return HttpWire.connect_tls(pool, where.host, where.port, left)
  end
  return TCP.connect(where.host, where.port, left)
end

# Opens the destination exclusively, then streams the response into it. Every error below closes both handles;
# the partial file stays, while a path that existed before is never touched.
def finish_download(socket: Socket, path: String, options: DownloadOptions, deadline: Int) -> Result[Download]
  case time_left(socket, deadline)
    ok(left) ->
      case File.open(path, "create_private", left)
        ok(out) -> return stream_download(socket, out, options, deadline)
        error(message) ->
          TCP.close(socket)
          return error(message)
      end
    error(message) ->
      TCP.close(socket)
      return error(message)
  end
end

# The response head (after at most MAX_INTERIM interim ones) streamed into the file.
def stream_download(socket: Socket, out: FileHandle, options: DownloadOptions, deadline: Int) -> Result[Download]
  case download_head(socket, options.max_total_bytes, deadline)
    ok(head) ->
      case save_body(socket, out, head, options.max_total_bytes, deadline)
        ok(written) ->
          case File.close(out, larger(deadline - Time.monotonic_ms(), 1))
            ok(_) ->
              TCP.close(socket)
              return ok(Download(status: head.status, headers: head.headers, bytes_written: written))
            error(message) -> return fail_download(socket, out, deadline, message)
          end
        error(message) -> return fail_download(socket, out, deadline, message)
      end
    error(message) -> return fail_download(socket, out, deadline, message)
  end
end

# Closes both handles after a failure and reports it; the partial file stays for inspection.
def fail_download(socket: Socket, out: FileHandle, deadline: Int, message: String) -> Result[Download]
  File.close(out, larger(deadline - Time.monotonic_ms(), 1))
  TCP.close(socket)
  return error(message)
end

# The response head of a download, with the download budget as the body limit.
def download_head(socket: Socket, budget: Int, deadline: Int) -> Result[HttpWire.Response]
  interim = 0
  while true
    case time_left(socket, deadline)
      ok(left) ->
        case HttpWire.read_response(socket, false, budget, left)
          ok(head) ->
            if head.status >= 200
              return ok(head)
            end
            interim = interim + 1
            if interim > MAX_INTERIM
              return error("http: too many interim responses")
            end
          error(message) ->
            if interim > 0 and message == END_OF_INPUT
              return error(CUT_SHORT)
            end
            return error(message)
        end
      error(message) -> return error(message)
    end
  end
  return error(TIMED_OUT)
end

# Streams the body framing of head into the file and counts its bytes.
def save_body(
  socket: Socket,
  out: FileHandle,
  head: HttpWire.Response,
  budget: Int,
  deadline: Int,
) -> Result[Int]
  if head.chunked
    return save_chunked(socket, out, budget, deadline)
  end
  if head.until_close
    return save_until_close(socket, out, budget, deadline)
  end
  return save_length(socket, out, head.length, budget, deadline)
end

# The next body bytes, at most most of them; no bytes means the peer closed the input.
def recv_body(socket: Socket, most: Int, deadline: Int) -> Result[Bytes]
  return TCP.recv_bytes(socket, most, try time_left(socket, deadline))
end

# Appends data to the download within the whole-call deadline.
def write_body(out: FileHandle, data: Bytes, deadline: Int) -> Result[Void]
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return error(TIMED_OUT)
  end
  return File.write_bytes(out, data, left)
end

# Appends data without letting the file grow past the budget: writes what fits, then reports TOO_LARGE.
def write_bounded(
  out: FileHandle,
  data: Bytes,
  written: Int,
  budget: Int,
  deadline: Int,
) -> Result[Int]
  room = budget - written
  if data.size > room
    if room > 0
      try write_body(out, data.take(room), deadline)
    end
    return error(TOO_LARGE)
  end
  try write_body(out, data, deadline)
  return ok(written + data.size)
end

# A Content-Length body: the head already refused one over the budget, so the count only follows it.
def save_length(socket: Socket, out: FileHandle, length: Int, budget: Int, deadline: Int) -> Result[Int]
  left = length
  written = 0
  while left > 0
    data = try recv_body(socket, smaller(left, BODY_READ_BYTES), deadline)
    if data.empty?
      return error(TRUNCATED)
    end
    written = try write_bounded(out, data, written, budget, deadline)
    left = left - data.size
  end
  return ok(written)
end

# A chunked body: framing goes through the decoder, whose runs say which bytes of each read are body.
def save_chunked(socket: Socket, out: FileHandle, budget: Int, deadline: Int) -> Result[Int]
  data = NO_BYTES
  state = HttpWire.chunked(budget)
  written = 0
  while not state.done
    if state.remaining > 0
      data = try recv_body(socket, smaller(state.remaining, BODY_READ_BYTES), deadline)
      if data.empty?
        return error(TRUNCATED)
      end
      written = try write_bounded(out, data, written, budget, deadline)
      state = HttpWire.chunk_read(state, data.size)
    else
      data = try recv_body(socket, FRAME_BYTES, deadline)
      if data.empty?
        return error(TRUNCATED)
      end
      case HttpWire.chunk(state, data, 0)
        ok(next) -> state = next
        error(problem) -> return error("http: #{rest_of(problem, 4)}")
      end
      written = try write_runs(out, data, state.runs, written, budget, deadline)
    end
  end
  return ok(written)
end

# Appends the runs of data (start, length pairs) to the download.
def write_runs(
  out: FileHandle,
  data: Bytes,
  runs: List[Int],
  written: Int,
  budget: Int,
  deadline: Int,
) -> Result[Int]
  at = 0
  while at < List.size(runs)
    piece = data.slice(List.at(runs, at), List.at(runs, at + 1))
    written = try write_bounded(out, piece, written, budget, deadline)
    at = at + 2
  end
  return ok(written)
end

# A body that ends with the connection: over TLS the end must be the peer's close_notify.
def save_until_close(socket: Socket, out: FileHandle, budget: Int, deadline: Int) -> Result[Int]
  written = 0
  while true
    data = try recv_body(socket, BODY_READ_BYTES, deadline)
    if data.empty?
      if not HttpWire.clean_eof?(socket)
        return error(TRUNCATED)
      end
      return ok(written)
    end
    written = try write_bounded(out, data, written, budget, deadline)
  end
  return error(TRUNCATED)
end

def larger(a: Int, b: Int) -> Int
  if a > b
    return a
  end
  return b
end
