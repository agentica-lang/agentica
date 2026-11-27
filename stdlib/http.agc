## An HTTP/1.1 client and server.
##
## Import it with `import HTTP from "std/http"`. Every call is whole: it returns after the whole response arrived, and
## every body is `Bytes`, as it came over the wire; `text` decodes one as UTF-8. Status codes such as 404 or 500 are
## normal responses. A bad URL, a refused connection, a timeout or a body over the limit is an `error` result.
##
## `HTTP.Request`, `HTTP.Response`, `HTTP.Header`, `HTTP.ClientOptions`, `HTTP.ServerOptions`, `HTTP.Client` and
## `HTTP.Server` are the builtin types `HttpWire.Request`, `HttpWire.Response`, and so on. The signatures below, the
## diagnostic, `help` and a printed value show the `HTTP.` names as written.

import WebSocketWire from "std/internal/websocket"
import URI from "std/uri"

export HttpWire.Request
export HttpWire.Response
export HttpWire.Header
export HttpWire.ClientOptions
export HttpWire.ServerOptions
export HttpWire.Client
export HttpWire.Server

## How far a download may go. `timeout_ms` bounds the whole call, from the connect to the rename, and
## `max_total_bytes` the body bytes written; `none`, the default of both, is no limit, and a value must be positive.
## The client's `read_timeout_ms` still bounds each wait for the head and for body bytes, so a silent server ends the
## call. `sha256`, when given, is the hex SHA-256 digest (64 digits, either case) the body must have.
struct DownloadOptions
  ## The milliseconds the whole download may take, or `none` for no limit.
  timeout_ms: Optional[Int] = none
  ## The most body bytes written to the file, or `none` for no limit.
  max_total_bytes: Optional[Int] = none
  ## The hex SHA-256 digest the body must have, or `none` for no check.
  sha256: Optional[String] = none
end

## What a download wrote: the response `status` and `headers` with the count of body `bytes_written` to the file.
## The body itself is in the file, never in this record.
struct Download
  ## The response status, however high: 404 and 500 are normal responses, as with `get_response`.
  status: Int
  ## The response headers.
  headers: List[HttpWire.Header]
  ## How many body bytes went to the file.
  bytes_written: Int
end

## An HTTP/1.1 connection that the program drives itself, as `Net::HTTP.start` gives: one request at a time, and the
## body read piece by piece. Open it with `start`, send with `send_request`, read with `read_body` and end it with
## `finish`. The fields are the connection's own: do not read them. It belongs to the task that opened it, as a socket
## does, and one call at a time uses it.
struct Connection
  ## The socket, a plain one or a TLS one.
  socket: TCP.Socket
  ## `http` or `https`, the host and the port, which the request head names.
  scheme: String
  host: String
  port: Int
  ## The options it was opened with: `timeout_ms` is the time of each `send_request` (the write and the head),
  ## `read_timeout_ms` the time of each `read_body`, and `max_body_bytes` the largest request body. A `proxy` has no
  ## user info here, so printing a connection shows no password.
  options: HttpWire.ClientOptions
  ## The `Proxy-Authorization` value of the proxy's user info ("" with none), alone in a channel that holds one value:
  ## a channel prints as `<Channel>`, where a field would print the login.
  login: Channel[String]
  ## The one `Exchange` of the connection, in a channel that holds a single value: a call takes it and puts it back,
  ## so a second call at the same time finds it empty and says so.
  cell: Channel[Exchange]
end

## The head of a response read on a `Connection`: the `status` and `headers` (names in lowercase). The body is still
## on the connection, for `read_body`.
struct ResponseHead
  ## The status, however high: 404 and 500 are normal responses. An interim `1xx` head is read past.
  status: Int
  ## The response headers.
  headers: List[HttpWire.Header]
end

## A response whose body arrives on a channel, from `open`: the `status` and `headers` of the head, the `body` channel
## and the `done` task that feeds it. The task reads the connection and sends each piece (up to 64 KiB, never empty),
## and it closes the channel on every path, so the reader runs the usual receive loop until the closed error and then
## awaits `done`: `ok` means the body ended cleanly, an `error` says why it did not (a cut body, a timeout, a bad
## chunk). To stop early the reader closes the channel: the task's next `send` fails, it closes the connection and
## `done` is an `error`. That works only while data flows: on a quiet stream the task waits in its read until
## `read_timeout_ms` (for ever when it is 0), so the prompt stop is `Task.cancel(stream.done)`, which closes the
## connection at once. The connection belongs to the task and is never reused.
struct Stream
  status: Int
  headers: List[HttpWire.Header]
  body: Channel[Bytes]
  done: Task[Result[Void]]
end

## A response whose body is sent as it is produced: the `status` and `headers` of the head, and a `body` channel of
## pieces. The handler returns it at once and a task it spawned sends the pieces and closes the channel at the end. The
## server sends each piece as soon as it arrives and ends the body when the channel closes. When the client leaves, the
## server closes the channel, so the producer's next `send` returns an error and it stops.
struct StreamResponse
  ## The status, 200 to 599, and not 204 or 304 unless the body is already closed and empty.
  status: Int
  ## The response headers. The server adds `Transfer-Encoding: chunked` or `Content-Length`: the handler sets neither.
  headers: List[HttpWire.Header]
  ## The pieces of the body, as `Bytes` of any content (an empty one is skipped).
  body: Channel[Bytes]
  ## The size of the whole body in bytes, when the handler knows it (a file). The head then says `Content-Length` and
  ## the pieces go out as they are, with no chunk framing, so a client can show progress and a range answer can
  ## stream. The producer must send exactly that many bytes and then close the channel: a body that ends short, or
  ## a piece that would pass the length, cuts the connection (the client sees an incomplete body), and a body that is
  ## closed when the handler returns and has another size is a 500. Not for a 204 or a 304. `none` is the default: the
  ## body is chunked.
  length: Optional[Int] = none
end

## A route that takes the request whole: the request in, the whole response out. `app` makes an `App` from it. A
## middleware is a function from a `Handler` to a `Handler`.
type Handler = Fn[HttpWire.Request, Result[HttpWire.Response]]

## The body of a request as it arrives, on a channel, for an `App`: the `pieces` channel (`Bytes` of any content, up
## to 64 KiB each, never empty, a chunked body already decoded) and the `done` task that feeds it. The task closes the
## channel on every path, so the app runs the usual receive loop until the closed error and then awaits `done`: `ok`
## means the body arrived whole, an `error` says why it did not (the client left, a bad chunk, a timeout, a body over
## `max_body_bytes`). An app that answers before the whole body arrived ends the connection after its answer.
struct RequestBody
  pieces: Channel[Bytes]
  done: Task[Result[Void]]
end

## A message of a WebSocket, in either direction. `Text` and `Binary` are whole messages: the server joins the
## fragments of a message it receives, and a text message is checked as UTF-8. `Ping` and `Pong` carry at most 125
## bytes. The server answers every ping it receives with a pong, and does not hand it to the handler. `Close` is the
## end: the code (1000 to 1003 and 1007 to 1014 are the registered codes, 3000 to 4999 are for programs) and a reason
## of at most 123 bytes. It is always the last message the handler receives, and when the connection ended with no
## close frame (the peer left, a timeout) its code is 1006. `Prepared` is a text or binary message already framed by
## `prepare`, so a broadcast does not frame its message for every socket; the server never receives one.
enum Message
  Text(String)
  Binary(Bytes)
  Ping(Bytes)
  Pong(Bytes)
  Close(Int, String)
  Prepared(Bytes)
end

## An upgraded connection, for the session function of `accept_websocket`: messages from the peer arrive on `incoming`
## and the messages to send go on `outgoing`. `protocol` is the subprotocol that was agreed, or "". Both channels hold
## 8 messages, so a handler that does not read makes the server stop reading the socket, and a handler that sends
## faster than the peer reads waits. A session must keep taking messages from `incoming` (or end): while it does not,
## the server does not read the socket, so the pings and the close of the peer go unanswered. `incoming` closes after
## the `Close` message, and `outgoing` closes when the connection is over, so a send then is an error.
struct WebSocket
  incoming: Channel[Message]
  outgoing: Channel[Message]
  protocol: String
end

## The function that runs a WebSocket after its handshake: it gets the `WebSocket` and returns when it is done. When it
## returns, the server sends a close frame (code 1000, or 1011 for an `error`) if the session did not, waits for the
## peer's, and closes the connection.
type WebSocketSession = Fn[WebSocket, Result[Void]]

## The limits of a WebSocket. `max_message_bytes` is the largest message, joined from its fragments (1 to 256 MiB): a
## larger one closes the connection with code 1009. `idle_ms` is the longest the server waits for the peer to send
## anything, 0 for no limit but a year (a read that times out closes the socket); a timeout drops the connection, and
## the handler receives `Close` with code 1006. `ping_ms` makes the server send a ping after that many milliseconds
## without anything to write, 0 for none: with a `ping_ms` below `idle_ms` the pongs keep a live peer from being
## dropped. `close_ms` is how long the server waits for the peer's answer to its close frame. `protocols` are the
## subprotocols the server speaks, in order of preference. `outgoing_queue` is how many messages `outgoing` holds (1 to
## 1048576) before a send waits: the writer takes everything queued at that moment and writes it in one go.
struct WebSocketOptions
  max_message_bytes: Int = 1048576
  idle_ms: Int = 0
  ping_ms: Int = 0
  close_ms: Int = 5000
  protocols: List[String] = []
  outgoing_queue: Int = 8
end

## What `accept_websocket` decides for a request, for an `Answer.Upgrade`: `Reply` answers it as a whole response (and
## the connection serves the next request), `Accept` upgrades it. Make an `Accept` with `accept_websocket`.
enum Upgrade
  Reply(HttpWire.Response)
  Accept(WebSocketSession, WebSocketOptions, String, String)
end

## What an `App` returns for a request. `Whole` is a whole response, as a `Handler` returns. `Stream` is a response
## whose body arrives on a channel. `Upgrade` is what `accept_websocket` makes: its
## `Accept` runs a WebSocket on the connection, and its `Reply` (a request that is no handshake) is sent as `Whole`.
enum Answer
  Whole(HttpWire.Response)
  Stream(StreamResponse)
  Upgrade(Upgrade)
end

## The function that `serve` and `serve_tls` call for each request: the request with an empty `body`, the
## `RequestBody` that carries the body as it arrives, and the `Answer` out. A route that wants the body whole calls
## `read_all`; `app` makes an `App` from a `Handler`. A middleware is a function from an `App` to an `App`.
type App = Fn[HttpWire.Request, RequestBody, Result[Answer]]

## The proxy that the environment names for `url`, to pass as `HTTP.ClientOptions(proxy: ...)`, or `""` when there is
## none. It is the only call that reads the environment: a client never does, so nothing changes until a program asks.
## It follows curl. An `http://` URL reads `http_proxy` and an `https://` URL `https_proxy`; the lower-case name wins
## over `HTTP_PROXY` or `HTTPS_PROXY`, even when it is set and empty (which means no proxy). `HTTP_PROXY` is ignored
## when `REQUEST_METHOD` is set, as in a CGI program, where a request's `Proxy` header becomes it (httpoxy); on
## Windows, whose names do not differ by case, an `http://` URL then gets no proxy. `ALL_PROXY` is not read. A value
## with no `://` is read as `http://` (`proxy.example:8080`), and one with another scheme is returned as it is, so the
## client that gets it says it is not an `http://` origin.
##
## `no_proxy` (or `NO_PROXY`) is a list, separated by commas or spaces, that says where no proxy is used, and the
## result is then `""`: `*` is every host; `example.com` and `.example.com` are that domain and its subdomains; an
## entry may end in `:port` (`[::1]:8080` for an IPv6 literal); an IP literal matches only itself, and an IPv4 range
## such as `10.0.0.0/8` matches its addresses (an IPv6 range is not read). Empty entries and an entry that is not
## valid are ignored, one trailing dot of a host or an entry does not count, and the case of a host is not
## significant. A `url` that is not valid gives `""`: the call that gets it reports it.
##
## An `https://` URL gets `https_proxy`, which `HTTP` then reaches with a `CONNECT` tunnel.
def proxy_from_env(url: String) -> String
  case parse_url(url)
    ok(where) ->
      return "" if no_proxy_for?(where)

      proxy_of_scheme(where.scheme)
    error(_) -> ""
  end
end

## Sends a `GET` request to `url` on a connection of its own and returns the response, like Ruby's
## `Net::HTTP.get_response(uri)`. It is the call for one request: it opens one connection with `options` (default
## `HTTP.ClientOptions()`), makes the call in the calling task and closes the connection before it returns. Many
## requests to the same host belong on a connection of `start`, or on the `http-client` package, which pools them.
##
## `options` is a 30 s `timeout_ms` for the whole call (the connect, the head and the body), a 10 s
## `connect_timeout_ms` inside it and a 300 s `read_timeout_ms` for each wait for body bytes (0 for none), 1 MiB
## bodies, the system CA certificates and no proxy (set `tls: some(context)` to use a client context of
## `TLS.client_context` instead of the system certificates). `idle_timeout_ms` and `max_connections` are not used by
## any call now. `connect_to` is an IP address (empty by default) that the connection goes to instead of resolving the
## host of the URL; `Host`, the TLS server name and the certificate check still use the host of the URL. It is an error
## for a host name or any spelling that is not the strict form of an address (IPv4 `a.b.c.d` with no leading zero, IPv6
## without brackets, not IPv4-mapped), and together with a proxy. Every number in `options` must be positive, except
## `read_timeout_ms`, which is 0 (no limit) or positive; `max_body_bytes` is at most 64 MiB, or the result is an error:
## it bounds the bodies held in memory (`get_response`, `post_response` and the response of `upload`), and a bigger
## body goes through `download`, `read_body` or `open`, which stream it with no limit. With a `proxy`
## (`http://host:port`, an origin with no path) an `http://` request goes through that forward proxy in absolute form
## (`GET http://host/path HTTP/1.1`, `Host` still the target's). An `https://` request opens a `CONNECT host:port`
## tunnel through the proxy and speaks TLS inside it, verified against the target (a non-2xx answer to the `CONNECT` is
## an error that names the proxy). A `proxy` that is not an `http://` origin is an error. The user info of the `proxy`
## (`http://user:password@host:8080`, percent-decoded) is sent to the proxy as `Proxy-Authorization: Basic`, and a
## `407` from it is an error that names the proxy and not the credentials. The call adds `Host` and `Content-Length`
## itself, so a request may not set them, nor `Transfer-Encoding` or `Connection`.
def get_response(url: String, options: HttpWire.ClientOptions = HttpWire.ClientOptions()) -> Result[HttpWire.Response]
  request_once("GET", url, NO_BYTES, [], options)
end

## Sends a `POST` request on a connection of its own, as `get_response` does for `GET`: the `Bytes` `body`, `headers`
## (default none) and `options` (default `HTTP.ClientOptions()`), then the connection is closed. Like Ruby's
## `Net::HTTP.post(uri, data, header)`.
def post_response(
  url: String,
  body: Bytes,
  headers: List[HttpWire.Header] = [],
  options: HttpWire.ClientOptions = HttpWire.ClientOptions(),
) -> Result[HttpWire.Response]
  request_once("POST", url, body, headers, options)
end

## Downloads the resource at `url` with a `GET` request and writes its body bytes to `path`. `options` is optional
## and defaults to `DownloadOptions()`: no limit on the size of the body, and none on the time but a year. The
## connect takes at most `client.connect_timeout_ms` and each wait for the head or for body bytes
## `client.read_timeout_ms`; `client` (default `ClientOptions()`) also gives the `proxy`, `tls` and `connect_to` of the
## connection, and its options must be valid as for `start`.
##
## The body never sits in memory: at most 1 MiB is held at once. It goes to a new private file in the folder of `path`,
## named `.<name>.<8 hex digits>.agc-part`, which `Path.replace` puts at `path` in one step only when the body ended
## cleanly, its size is within `options.max_total_bytes` and its digest is `options.sha256` (else `http.digest`): an
## existing file or link at `path` is then replaced, and a directory is an error. A failure removes the new file and
## leaves `path` as it was, and so does a cancelled task or a timeout of the task (the file is a `"temp"` file of
## `File.open`); a program that ends by SIGKILL or a crash can leave it behind. Status codes such as 404 or 500 are
## normal responses, as with `get_response`: the body is still written and the status returned, so check `status`
## before using the file. There is no redirect follow, and the connection is not pooled: it closes when the download
## ends. `https` verifies the certificate with the context of `client.tls`, or with the system trust, built for this
## download.
def download(
  url: String,
  path: String,
  options: DownloadOptions = DownloadOptions(),
  client: HttpWire.ClientOptions = HttpWire.ClientOptions(),
) -> Result[Download]
  try check_download(options)
  try check_client(client)

  try check_proxy(client)
  where = try parse_url(url)
  via = try connect_target(where, client)
  head = try HttpWire.encode_request(
    where.scheme,
    where.host,
    where.port,
    "GET",
    request_target(client, where),
    with_login(client, where.scheme, []),
    NO_BYTES,
    client.max_body_bytes,
  )

  deadline = after(options.timeout_ms.unwrap_or(WATCH_MS))
  try replaceable(path, deadline)
  # What a 407 from the proxy is told as; empty when there is no proxy or the request is in a tunnel, whose 407 is the
  # server's own answer.
  denied = ""
  if proxy_asked?(client, where.scheme, 407)
    denied = client_denied(client)
  end

  socket = try connect_download(client, via, deadline)
  case TCP.send_bytes(socket, head_bytes(head), try time_left(socket, deadline))
    ok(_) -> finish_download(socket, path, options, deadline, denied, read_ms(client))
    error(message) ->
      TCP.close(socket)
      error(message)
  end
end

## Opens a connection to the `origin` (`http://host` or `https://host:8443`, with no path) and returns it, as
## Ruby's `Net::HTTP.start` does. The connection is made now. Only `connect_timeout_ms` (the connect, at most
## `timeout_ms`), `timeout_ms` (each `send_request`, which writes the request and reads the head), `read_timeout_ms`
## (each `read_body`, 0 for none), `max_body_bytes` (the largest request body), `tls` (over `https`, the
## certificate is verified with that client context, the system trust by default, built again for each `start`) and
## `proxy` (an `http` origin is then reached through the proxy, which each `send_request` addresses in absolute form)
## of `options` apply: nothing is pooled. The connection is for one request at a time and stays open for the next one
## when the response had a body that was read to its end (`read_body` gave an empty piece) and the server did not
## close it. A response body has no size limit, since `read_body` gives it piece by piece. Close it with `finish`.
## For whole requests use `get_response`.
def start(origin: String, options: HttpWire.ClientOptions = HttpWire.ClientOptions()) -> Result[Connection]
  try check_client(options)

  where = try parse_url(origin)
  if where.target != "/"
    return error("http: start takes an origin such as http://host:8080, with no path or query", kind: "argument")
  end
  open_connection(where, options)
end

## Sends a request on the connection and returns when the head of the response has been read, as Ruby's
## `Net::HTTP#send_request` does. `target` is the path with its query (`/items?page=2`); `method`, `body` (`Bytes`, at
## most `max_body_bytes`; `"".bytes` sends none) and `headers` (default none) are as for `post_response`, and the
## connection adds `Host` and `Content-Length`. The body of the response is not read: call `read_body` until it gives
## an empty piece (a response with no body, such as one to `HEAD` or a `204`, leaves the connection ready at once). An
## `error` is a request refused before it was written, which leaves the connection as it was, a connection that is
## closed or has a response still to be read, or a failure of the connection, which then ends. A server that closed an
## idle connection shows as an `error` here: `start` a new one.
def send_request(
  conn: Connection,
  method: String,
  target: String,
  body: Bytes,
  headers: List[HttpWire.Header] = [],
) -> Result[ResponseHead]
  sent_by(conn, method, target, body, headers, after(conn.options.timeout_ms))
end

## Reads the next piece of the body of the last response, at most `max_bytes` (1 to 1 MiB, 64 KiB by default), as
## Ruby's `Net::HTTP#read_body` does with a block. It waits for at least one byte, and an empty `Bytes` is the end of
## the body: the connection is then ready for the next `send_request`, or closed when the server said so. It is the
## end as soon as the last byte has been read, so a program that knows the length may stop before the empty piece. A
## chunked body is decoded and a `Content-Length` one is held to its length. A cut body, a bad chunk and a timeout are
## an `error`, and end the connection.
def read_body(conn: Connection, max_bytes: Int = 65536) -> Result[Bytes]
  if max_bytes < 1 or max_bytes > BODY_READ_BYTES
    return error("http: max_bytes must be 1 to 1048576", kind: "argument")
  end
  read_piece(conn, max_bytes, after(read_ms(conn.options)))
end

## Ends the connection and frees its socket, as Ruby's `Net::HTTP#finish` does. A response body not read to its end is
## dropped. It is safe to call twice.
def finish(conn: Connection) -> Void
  end_connection(conn)
end

## Sends a request on a connection of its own and returns at the head of the response, whose body arrives on a channel
## (`Stream`), for a body that is too big to hold, that never ends (events, lines of a log) or that another task reads
## as it comes. `url` has a path and query; `method`, `body` (`Bytes`, at most `max_body_bytes`) and `headers` are as
## for `post_response`. `options.timeout_ms` is the time until the head arrives, the connect included (the connect
## itself takes at most `connect_timeout_ms`). After the head, `read_timeout_ms` is the time of each wait: each read of
## the body and each `send` to the channel, so a reader that takes longer than that to ask for the next piece ends the
## stream, and so does a server that is silent for that long. 0 is no limit, for a stream that may stay quiet: it ends
## with the body, with `Task.cancel(stream.done)` or when the server closes it. The body has no size limit: the reader
## stops when it likes. The connection is not pooled and ends with the body. For whole responses use `get_response`.
def open(
  method: String,
  url: String,
  body: Bytes,
  headers: List[HttpWire.Header] = [],
  options: HttpWire.ClientOptions = HttpWire.ClientOptions(),
) -> Result[Stream]
  try check_client(options)

  where = try parse_url(url)
  head_by = after(options.timeout_ms)
  conn = try open_connection(where, options)
  case sent_by(conn, method, where.target, body, headers, head_by)
    ok(head) ->
      pieces: Channel[Bytes] = Channel.new(STREAM_PIECES)
      # A response with no body left the socket closed already when the server closes (`finished_exchange`), and a
      # closed socket cannot be handed to a task: the stream is then over at once.
      if spent?(conn)
        pieces.close
        return ok(Stream(status: head.status, headers: head.headers, body: pieces, done: Task.spawn(&ended, pieces)))
      end

      done = Task.spawn_owning(&feed_stream, Feed(conn: conn, pieces: pieces))
      ok(Stream(status: head.status, headers: head.headers, body: pieces, done: done))
    error(message) ->
      end_connection(conn)
      error(message)
  end
end

## Sends a request whose body comes from a channel, and returns the whole response. The caller's other task sends the
## pieces (`Bytes` of any content) and closes the channel at the end. `length` is the exact byte count, which the
## request then says as `Content-Length` and which ends the body as soon as that many bytes were sent (the producer
## need not close the channel), or -1 (the default) for a chunked body, which ends when the channel closes. `method` is
## `POST`, `PUT` or `PATCH`; `headers` and `options` are as for `post_response`, and `options.max_body_bytes` limits
## the response body, not the upload. The connect takes at most `connect_timeout_ms`; `read_timeout_ms` is the time of
## each wait for a piece from the channel and of each send (0 for none); `timeout_ms` is the time from the end of the
## upload to the head of the response. A body that is longer or shorter than `length`, or a channel that stays silent
## for longer than `read_timeout_ms`, is an `error` and ends the connection. A channel that closes ends the body, also
## when its producer died, so a producer that can fail should set `length`. A server that answers and closes before the
## upload ends (a 413) does not hide its answer: when a write fails, the head of the response that is waiting is read
## and returned, and the write failure is the `error` only when there is none. The connection is not pooled. The
## channel is closed when the call returns, so a producer that is still sending finds the closed error and stops.
def upload(
  method: String,
  url: String,
  body: Channel[Bytes],
  length: Int = -1,
  headers: List[HttpWire.Header] = [],
  options: HttpWire.ClientOptions = HttpWire.ClientOptions(),
) -> Result[HttpWire.Response]
  answer = upload_whole(method, url, body, length, headers, options)
  body.close
  answer
end

## Returns every value of the header `name`, ignoring case, in order.
def header_values(headers: List[HttpWire.Header], name: String) -> List[String]
  wanted = String.downcase(name)
  found: List[String] = []
  for header in headers
    if String.downcase(header.name) == wanted
      found = List.append(found, header.value)
    end
  end
  found
end

## Returns `body` as a `String`, decoded in the `charset` of the `Content-Type` of `headers`, those of the same
## message (`response.headers`), or as UTF-8 when there is none. The charsets are the encodings of `Bytes.decode`
## (UTF-8, UTF-16, UTF-32, ASCII, Latin-1, ISO-8859-15 and Windows-1252, by any of their names, in any case). A body
## that is not valid in its charset is an `error` result, with the offset for a charset other than UTF-8, and any
## other charset is an `error` that names it: those (Shift_JIS, GB18030, KOI8-R) are for the `agentica-lang/charset`
## package.
def text(body: Bytes, headers: List[HttpWire.Header] = []) -> Result[String]
  charset = charset_of(headers)
  if charset == "" or UTF8_CHARSETS.include?(charset.replace("_", "-"))
    case String.from_bytes(body)
      ok(decoded) -> return ok(decoded)
      error(_) -> return error(BAD_BODY, kind: "text.encoding")
    end
  end
  # Every encoding writes the empty text, so this asks whether Bytes.decode knows the name.
  if not "".encode(charset).ok?
    shown = charset
    if shown.length > MAX_SHOWN
      shown = shown.slice(0, MAX_SHOWN)
    end
    return error(
      "http: charset #{shown} is not supported, decode the body with agentica-lang/charset",
      kind: "text.encoding",
    )
  end
  case body.decode(charset)
    ok(decoded) -> ok(decoded)
    error(e) -> error(e.with(message: "http: #{e.message}"))
  end
end

## Collects the body for an `App` that wants it whole, so one server can serve small routes simply next to the big
## ones: the pieces of `body` joined, at most `max_bytes` (0 or more), after the end of the body was checked. It is an
## `error` when the body is longer than `max_bytes` (the app then answers 413, and the server closes the connection
## after that answer) and when `done` says the body did not arrive whole.
def read_all(body: RequestBody, max_bytes: Int) -> Result[Bytes]
  return error("http: max_bytes must be 0 or more", kind: "argument") if max_bytes < 0
  pieces: List[Bytes] = []
  total = 0
  while true
    case body.pieces.recv(OWNER_WAIT_MS)
      ok(piece) ->
        total = total + piece.size
        return error(BODY_TOO_LONG, kind: "http.too_large", code: 413) if total > max_bytes
        pieces = pieces.push(piece)
      error(_) -> break
    end
  end
  try Task.await(body.done)
  ok(Bytes.concat(pieces))
end

## Checks that `request` is a WebSocket handshake and makes the `Upgrade` that runs `session` on it. The request must
## be a `GET` with `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-Version: 13` and a `Sec-WebSocket-Key`
## of 16 bytes in base64. A request that is not gets an `Upgrade.Reply`: 426 with `Sec-WebSocket-Version: 13` for
## another version, 400 for the rest. The first of `options.protocols` that the client offers in
## `Sec-WebSocket-Protocol` is agreed on (`WebSocket.protocol`). No extension is accepted, so no frame is compressed.
## The server does not check `Origin`: a browser sends it with every handshake, and a handler that serves pages of its
## own should compare it with `header_values(request.headers, "origin")` before it accepts. It is an `error` when
## `options` is out of range.
def accept_websocket(
  request: HttpWire.Request,
  session: WebSocketSession,
  options: WebSocketOptions = WebSocketOptions(),
) -> Result[Upgrade]
  try check_websocket_options(options)
  case handshake_problem(request)
    some(response) -> ok(Upgrade.Reply(response))
    none -> ok(accepted(request, session, options))
  end
end

## Frames a `Text` or `Binary` message once, for a broadcast: the `Prepared` message it returns is sent on any
## number of `outgoing` channels, and each writer sends its bytes as they are, where a `Text` would be framed again
## for every socket. The peer receives the same frame as for the message itself. Any other message is returned as it
## is.
def prepare(message: Message) -> Message
  case message
    Message.Text(text) -> Message.Prepared(WebSocketWire.text_frame(text))
    Message.Binary(data) -> Message.Prepared(WebSocketWire.binary_frame(data))
    _ -> message
  end
end

## Starts an HTTP server on `host` and `port` that serves every kind of route on one port, and returns at once; it
## serves in the background. Port 0 picks a free port, which `local_port` returns. The server closes when the task that
## called `serve` ends. `app` gets each request with its body on a channel (`RequestBody`) and answers with a whole
## response, a stream or a WebSocket upgrade (`Answer`); `app(handler)` makes one from a `Handler`, for a route that
## takes the request whole. Every body is at most `max_body_bytes` of `options` (1 MiB unless raised, up to 256 MiB): a
## request whose `Content-Length` is larger is answered 413 before `app` runs and before any `100 Continue`. A route
## that wants less counts the bytes or calls `read_all`. The connection serves the next request only when the body was
## read whole by the time `app` returned (a body that had all arrived counts, read or not); otherwise the answer says
## `Connection: close`, and an upgrade is refused. The server sets no limit on the time of `app`. `options` is optional
## and defaults to `HTTP.ServerOptions()`: 30 s `request_timeout_ms` and `idle_timeout_ms`, 128 connections and 1 MiB
## bodies.
def serve(
  host: String,
  port: Int,
  app: App,
  options: HttpWire.ServerOptions = HttpWire.ServerOptions(),
) -> Result[HttpWire.Server]
  try check_options(
    options.request_timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
    SERVER_MAX_BODY,
  )

  listener = try TCP.listen(host, port)
  ok(start_server(listener, app, options))
end

## Like `serve`, but over TLS, with the certificate and key of `tls`, a server context. `options` is optional and
## defaults to `HTTP.ServerOptions()`.
def serve_tls(
  host: String,
  port: Int,
  tls: TLS.Context,
  app: App,
  options: HttpWire.ServerOptions = HttpWire.ServerOptions(),
) -> Result[HttpWire.Server]
  try check_options(
    options.request_timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
    SERVER_MAX_BODY,
  )

  listener = try TLS.listen(host, port, tls)
  ok(start_server(listener, app, options))
end

## Makes an `App` from a `Handler`, for a route that wants the request whole: the body is read first, at most
## `max_body_bytes` (1 MiB unless given; a negative one counts as 0), and `handler` gets the request with it; its
## response is the `Whole` answer. A body that is larger, by its `Content-Length` or as it arrives, is answered 413,
## a chunk line or trailer section over the head limits 431 and a bad chunk 400, all with `Connection: close` and
## without calling `handler`; a body cut or stalled (the client left, a timeout) closes the connection. The server sets
## no limit on the time of `handler`.
def app(handler: Handler, max_body_bytes: Int = 1048576) -> App
  limit = max_body_bytes
  if limit < 0
    limit = 0
  end
  ->(request, body) { whole_answer(handler, limit, request, body) }
end

## The answer that refuses a request body `read_all` could not read, from its error: 413 for a body over its limit
## (the error `"http: body exceeds max_bytes"`), 431 for a chunk line or trailer section over the head limits (an
## error that starts with `"http: request fields too large: "`), 400 for any other (a bad chunk, a body cut or
## stalled).
## It is a whole response with `Connection: close` and no body. `app` answers so; a route that reads the body itself,
## before a stream for one, returns `ok(body_refusal(message))` for the error.
def body_refusal(message: String) -> Answer
  return Answer.Whole(closing_answer(413)) if message == BODY_TOO_LONG
  return Answer.Whole(closing_answer(431)) if message.start_with?(FIELDS_TOO_LARGE)
  Answer.Whole(closing_answer(400))
end

## Returns a closed channel that holds `data` as its one piece: the body of a `StreamResponse` that is one whole
## text or file. The server then answers with `Content-Length`, as for a whole response.
def whole(data: Bytes) -> Channel[Bytes]
  body: Channel[Bytes] = Channel.new(1)
  if not data.empty?
    _ = body.send(data, 0)
  end
  body.close
  body
end

## Returns the port the server listens on.
def local_port(server: HttpWire.Server) -> Int = HttpWire.local_port(server)

## Returns `ok()` once the server and its tasks are done.
def wait(server: HttpWire.Server) -> Result[Void] = HttpWire.wait(server)

## Stops accepting, closes every connection and cancels the running handlers. Calling it again does nothing.
def close_server(server: HttpWire.Server) -> Void
  HttpWire.close_server(server)
end

## Stops accepting, closes the idle connections, lets the requests in flight finish (with `Connection: close`) and,
## after `timeout_ms`, closes what is left as `close_server` does. Returns when the server is closed.
def shutdown(server: HttpWire.Server, timeout_ms: Int = 30000) -> Void
  wait_ms = timeout_ms
  if wait_ms < 0
    wait_ms = 0
  end
  HttpWire.stop(server, Time.monotonic_ms() + wait_ms)
  _ = HttpWire.wait(server)
end

private

READ_BYTES = 65536
# Chunked framing is read in small pieces, so the decoder sees the bytes of a chunk's framing and no more.
FRAME_BYTES = 512
# A body of at most this many bytes goes in the same send as the head.
SMALL_BODY = 16384
# The most bytes of one read of a body (TCP.recv_bytes takes at most 1 MiB).
BODY_READ_BYTES = 1048576
# The least time an error answer gets to be sent, even past the request deadline.
ANSWER_MS = 100
# The most input the lingering close reads and drops (as Go's net/http does). It is enough for a peer that sent a
# request in flight when the answer left, and it stops a peer from making the server read for the whole deadline.
DRAIN_BYTES = 262144
# The owner task has no deadline of its own: a timeout of its wait only starts the next one.
OWNER_WAIT_MS = 86400000
MAX_INTERIM = 15
# What a connection is doing: waiting for a request, in the body of a response, closed after a body that ended it
# (SPENT: reading says the body is over, a request is refused), or over (finished or failed).
IDLE = 0
READING = 1
SPENT = 2
OVER = 3
# How the body of a response is framed.
BY_LENGTH = 0
BY_CHUNKS = 1
BY_CLOSE = 2
# How many pieces a Stream holds before its task waits for the reader.
STREAM_PIECES = 8
# How many pieces of a request body an app can leave unread before the server waits.
UPLOAD_PIECES = 8
CONNECTION_OVER = "http: the connection is closed"
TIMED_OUT = "network: operation timed out"
CUT_SHORT = "http: connection closed before the response was complete"
TRUNCATED = "http: truncated HTTP body"
TOO_LARGE = "http: body exceeds max_body_bytes"
BAD_BODY = "http: body is not valid UTF-8"
# The names of UTF-8 that text reads with String.from_bytes, matched as Bytes.decode matches them (charset_of
# lowercases, text reads `_` as `-`), so every spelling of UTF-8 gets the same error; and the most characters of a
# refused charset that its error repeats.
UTF8_CHARSETS = Set.new(["utf-8", "utf8"])
MAX_SHOWN = 64
# Texts of the C builtins that std/http matches on (vm/channel.c, vm/tcp.c); each is marked there.
CHANNEL_CLOSED = "channel: closed"
END_OF_INPUT = "network: end of input"
# vm/tcp.c upgrade_error: bytes came with the CONNECT answer, before the TLS handshake began.
BEFORE_TLS = "network: data came before the TLS handshake"
# No bytes: the empty rest of a read and the empty body.
NO_BYTES = "".bytes
# The length of a streamed body that has none: it is chunked. No real length is -1, since a negative `length` is a 500
# before the stream starts (`length_problem`).
UNSIZED = -1
# The longest a streamed response may wait for its body channel before it looks again. A close of the channel wakes the
# wait at once, so this only bounds a task that is never woken.
STREAM_POLL_MS = 60000
# How long the watcher of a streamed response waits for the client to send or close (a year): a live stream is not
# idle, and a timeout of a read closes the socket.
WATCH_MS = 31536000000
HEX_DIGITS = "0123456789abcdef"
# The messages the `incoming` channel of a WebSocket holds before the reader waits (`outgoing` holds
# `WebSocketOptions.outgoing_queue`), and how long a task waits for a channel when nothing is due (a day). A timeout of
# that wait only starts the next one: with `ping_ms` set the tasks wait one ping interval instead, and the tests drive
# that path; with `ping_ms == 0` the same loops run once a day, which no test can reach (the constant cannot be
# changed from a program), and it is the same code with a longer wait.
WS_QUEUE = 8
# The most bytes of queued frames the writer joins into one write. A frame that crosses it still goes whole.
WS_BATCH_BYTES = 65536
# The most messages `outgoing` may hold: the most a channel holds.
WS_MAX_QUEUE = 1048576
WS_WAIT_MS = 86400000
# The most bytes a ping or a pong carries (a control frame is at most 125).
WS_CONTROL_BYTES = 125
WS_VERSION = "13"
# How a stream's pump ended.
STREAM_CUT = 0
STREAM_DONE = 1
STREAM_EARLY = 2
# The most bytes of a piece in one chunk, and of one TCP.send_bytes (1 MiB at most, with the chunk framing around it).
CHUNK_BYTES = 524288
SEND_BYTES = 1048576
# The most bytes of the pieces of a chunked body that go out as one chunk when they wait together.
STREAM_JOIN_BYTES = 65536
BAD_PROXY = "http: the proxy must be http://host:8080 or http://user:pass@host:8080, with no path or query"
# Said without the user info: an error never repeats the credentials.
BAD_LOGIN = "http: the proxy user info must be user:password in percent-encoding, and the user cannot hold a colon"
NO_BODY = "a 204 or 304 response cannot have a body"
WRONG_SIZE = "the body is not the length it was given"
HEAD_TOO_LARGE = "headers are too large"
CRLF = "\r\n".bytes
# The ceiling of a server's `max_body_bytes` and of a WebSocket message. A client's whole bodies stay capped at
# CLIENT_MAX_BODY by check_options; the streamed ones (download, read_body, open) have no limit, NO_BODY_LIMIT.
SERVER_MAX_BODY = 268435456
NO_BODY_LIMIT = 9223372036854775807
# The time a failed download takes to close and remove its new file, apart from the call's deadline.
CLEANUP_MS = 30000
DIGEST_MISMATCH = "http: the body does not match the sha256 digest"
# The most characters of the file name that the hidden name of a growing download keeps.
PART_NAME = 32
CLIENT_MAX_BODY = 67108864
# The error of an awaited task that was cancelled (Task.await), as the feeder of a closing server gives it.
TASK_CANCELLED = "task: cancelled"
# The error of a connection that a graceful stop ends before its next request.
SERVER_STOPPING = "http: server is stopping"
# The size of the accept loop's list of connections at which it first drops the ended ones.
PRUNE_CONNS = 64
# The error of `read_all` for a body over its limit, which `body_refusal` answers 413.
BODY_TOO_LONG = "http: body exceeds max_bytes"
# The start of the error of a chunked body with a line or trailer section over the head limits, which
# `body_refusal` answers 431, as the server answers such a head.
FIELDS_TOO_LARGE = "http: request fields too large: "

# The file a download writes, the name it has while it grows and the path it is renamed to at the end.
struct Saving
  out: File.Handle
  temp: String
  path: String
end

struct Target
  scheme: String
  host: String
  port: Int
  target: String
end

# The proxy of the options: where it is, and the `Proxy-Authorization` value its user info makes ("" with none).
struct Proxy
  target: Target
  login: String
end

# A connection's `idle` channel and its own task, which it puts there while it waits for a request.
struct Waiting
  idle: Channel[TaskRef]
  me: TaskRef
end

struct Service
  server: HttpWire.Server
  app: App
  options: HttpWire.ServerOptions
  ended: Task[Result[Void]]
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
  socket: TCP.Socket
  body: Channel[Bytes]
  left: Channel[Bool]
  sent: Channel[Bool]
end

struct Incoming
  request: HttpWire.Request
  rest: Bytes
end

struct Reading
  socket: TCP.Socket
  head: HttpWire.Head
  deadline: Int
  max_body_bytes: Int
end

# What the task that feeds the body of an upload needs: the request read up to its body, the wait of each step, the
# channel of pieces, and a one-slot channel that gets the bytes the framing read past the end of the body (the start
# of the next request) before the pieces close.
struct Feeding
  reading: Reading
  step_ms: Int
  pieces: Channel[Bytes]
  rest: Channel[Bytes]
end

# What the tasks of a WebSocket share: the socket, the channels (`incoming` and `outgoing` are the handler's), the last
# word of the reader (`control` holds one item, and `wake` rouses the writer), the options, the wait of a write and the
# bytes read past the handshake.
struct Wire
  socket: TCP.Socket
  incoming: Channel[Message]
  outgoing: Channel[Message]
  control: Channel[Control]
  wake: Message
  options: WebSocketOptions
  write_ms: Int
  rest: Bytes
end

# What the reader tells the writer, once, before it stops: the answer to the peer's close, a frame that ends the
# connection after a protocol error, and the news that the peer is gone.
enum Control
  Echo(Bytes)
  Fail(Bytes)
  Gone
end

# What the writer joins from `outgoing` for one write: the frames in order (empty when it took nothing to write),
# whether the last one is our close frame, and whether the gather met the wake of the reader.
struct Batch
  data: Bytes
  closes: Bool
  woken: Bool
end

# What reading one frame gave: the frame (its head, its unmasked payload and the bytes read past it), a problem with
# it, or the loss of the connection.
enum Read
  Got(WebSocketWire.Head, Bytes, Bytes)
  Bad(WebSocketWire.Problem)
  Lost
end

# Bytes cut off the front of what was read, and what remains.
struct Cut
  front: Bytes
  rest: Bytes
end

# Where a connection is: `phase` is IDLE, READING, SPENT or OVER. While READING, `framing` says how the body ends,
# `left` is what a body with a length still owes (for a body that runs to the end of input, what it has given),
# `chunks` is the decoder of a chunked body, and `closes` whether the connection ends with the body
# (`Connection: close`, HTTP/1.0 or a body that runs to the end of input).
struct Exchange
  phase: Int
  framing: Int
  left: Int
  chunks: HttpWire.Chunk
  closes: Bool
end

# A request written by a task of its own, while the response is read.
struct Outgoing
  socket: TCP.Socket
  head: String
  body: Bytes
  by: Int
end

# One step of a body: the piece read and where the response stands after it.
struct Step
  piece: Bytes
  exchange: Exchange
end

struct Whole
  body: Bytes
  kept: Bool
end

# What the task of a Stream owns: the connection it reads and the channel it feeds.
struct Feed
  conn: Connection
  pieces: Channel[Bytes]
end

# One request on a connection that lives for it alone, in the task of the caller: it ends with the call, and with the
# task when that is cancelled. `timeout_ms` is the whole call, the connect, the head and the body.
def request_once(
  method: String,
  url: String,
  body: Bytes,
  headers: List[HttpWire.Header],
  options: HttpWire.ClientOptions,
) -> Result[HttpWire.Response]
  try check_client(options)

  try check_proxy(options)
  where = try parse_url(url)
  # A request that cannot be written fails before a socket is opened, and is written once: the encoded head is what
  # `whole_response` sends.
  request = try HttpWire.encode_request(
    where.scheme,
    where.host,
    where.port,
    method,
    request_target(options, where),
    with_login(options, where.scheme, headers),
    body,
    options.max_body_bytes,
  )

  by = after(options.timeout_ms)
  conn = try open_connection(where, options)
  answer = whole_response(conn, request, method, body, by)
  end_connection(conn)
  answer
end

# The response of `request_once`, whole, to the encoded `request` on a connection that has had none. `send_encoded`
# returns the error of a `407` from the proxy, so it is not looked for here (`upload_answer` has its own check, since
# it reads the head itself).
def whole_response(
  conn: Connection,
  request: String,
  method: String,
  body: Bytes,
  by: Int,
) -> Result[HttpWire.Response]
  _ = try take_exchange(conn)
  return answered_early(conn, request, method, body, by) if body.size > SMALL_BODY

  head = try send_encoded(conn, request, method == "HEAD", body, by)
  whole = try read_whole(conn, conn.options.max_body_bytes, by)
  ok(HttpWire.Response(status: head.status, headers: head.headers, body: whole))
end

# A large body is written by a task of its own while the response is read, so an answer that comes before the upload
# ends (an early 413) is read; a small body fits in the socket's buffers. A writer still busy 1 ms after the whole
# response came means the server answered before it read the body: the connection is closed, which gives the answer
# now. A response read after the request failed to go out is still the answer; with none, the write error is.
def answered_early(
  conn: Connection,
  request: String,
  method: String,
  body: Bytes,
  by: Int,
) -> Result[HttpWire.Response]
  writer = Task.spawn(&write_outgoing, Outgoing(socket: conn.socket, head: request, body: body, by: by))
  received = read_answer(conn, method == "HEAD", by)
  sent: Result[Void] = ok()
  case Task.await(writer, 1)
    Await.Done(result) -> sent = result
    Await.TimedOut ->
      TCP.close(conn.socket)
      sent = Task.await(writer)
  end
  case received
    ok(_) -> received
    error(_) ->
      case sent
        error(problem) -> error(problem)
        ok(_) -> received
      end
  end
end

def read_answer(conn: Connection, head_only: Bool, by: Int) -> Result[HttpWire.Response]
  case read_head_of(conn.socket, head_only, NO_BODY_LIMIT, by)
    ok(head) ->
      answer = try head_taken(conn, head)
      whole = try read_whole(conn, conn.options.max_body_bytes, by)
      ok(HttpWire.Response(status: answer.status, headers: answer.headers, body: whole))
    error(message) ->
      end_connection(conn)
      error(message)
  end
end

def write_outgoing(outgoing: Outgoing) -> Result[Void]
  socket = outgoing.socket
  try TCP.send_bytes(socket, head_bytes(outgoing.head), try time_left(socket, outgoing.by))
  at = 0
  while at < outgoing.body.size
    piece = outgoing.body.slice(at, smaller(SEND_BYTES, outgoing.body.size - at))
    try TCP.send_bytes(socket, piece, try time_left(socket, outgoing.by))
    at = at + piece.size
  end
  ok()
end

def settled(phase: Int, closes: Bool) -> Exchange
  chunks = HttpWire.chunked(NO_BODY_LIMIT)
  Exchange(phase: phase, framing: BY_LENGTH, left: 0, chunks: chunks, closes: closes)
end

# What the request line says of the target: the path with its query, or, through a proxy, the whole URL (RFC 9112
# 3.2.2, absolute-form), whose authority is the one the `Host` header has. An `https` request is inside a CONNECT
# tunnel and is written as it is with no proxy.
def request_target(options: HttpWire.ClientOptions, where: Target) -> String
  return where.target if options.proxy == "" or where.scheme == "https"

  "http://#{host_authority(where.host, where.port)}#{where.target}"
end

# The target of a request on `conn`, in the form `request_target` gives.
def connection_target(conn: Connection, target: String) -> String
  request_target(conn.options, Target(scheme: conn.scheme, host: conn.host, port: conn.port, target: target))
end

# The host and port as the `Host` header of `encode_request` writes them: an IPv6 literal in brackets, the default port
# of `http` left out.
def host_authority(host: String, port: Int) -> String
  name = host
  if host.include?(":")
    name = "[#{host}]"
  end

  return name if port == 80

  "#{name}:#{port}"
end

# Where a request to `where` connects: the host itself, or the proxy of the options for `http`. An `https` request
# keeps the target's origin: the connection opens the tunnel itself (`tunnel_context`).
def connect_target(where: Target, options: HttpWire.ClientOptions) -> Result[Target]
  return ok(where) if options.proxy == "" or where.scheme == "https"

  proxy_target(options)
end

# The proxy of the options: an `http://host:port` origin.
def proxy_target(options: HttpWire.ClientOptions) -> Result[Target]
  proxy = try proxy_of(options)
  ok(proxy.target)
end

# The proxy of the options and its login. The user info is cut out of the URL before `parse_url` sees it, which refuses
# it; the last `@` ends it, so a password may hold a raw one. Both parts are percent-decoded, and the URL is not
# kept or quoted anywhere after this: an error names neither the user info nor the URL.
def proxy_of(options: HttpWire.ClientOptions) -> Result[Proxy]
  url = options.proxy
  split = first_of(url, "://")
  return error(BAD_PROXY, kind: "argument") if split == String.length(url)

  rest = rest_of(url, split + 3)
  stop = first_of(rest, "/")
  stop = smaller(stop, first_of(rest, "?"))
  stop = smaller(stop, first_of(rest, "#"))
  authority = String.slice(rest, 0, stop)
  at = last_at(authority)
  login = ""
  origin = url
  if at >= 0
    login = try login_of(String.slice(authority, 0, at))
    origin = "#{String.slice(url, 0, split + 3)}#{rest_of(authority, at + 1)}#{rest_of(rest, stop)}"
  end

  case parse_url(origin)
    ok(target) -> return ok(Proxy(target: target, login: login)) if target.scheme == "http" and target.target == "/"
    error(_) -> return error(BAD_PROXY, kind: "argument")
  end

  error(BAD_PROXY, kind: "argument")
end

# The index of the last `@` of `text`, or -1.
def last_at(text: String) -> Int
  found = -1
  for position in 0...String.length(text)
    if String.slice(text, position, 1) == "@"
      found = position
    end
  end

  found
end

# The `Proxy-Authorization` value (RFC 7617, Basic) of the `user:password` user info of a proxy URL, percent-decoded.
# The user name cannot hold a colon, which ends it in the credentials.
def login_of(info: String) -> Result[String]
  return error(BAD_LOGIN, kind: "argument") if info == ""

  colon = first_of(info, ":")
  user = try unescaped(String.slice(info, 0, colon))
  password = ""
  if colon < String.length(info)
    password = try unescaped(rest_of(info, colon + 1))
  end

  return error(BAD_LOGIN, kind: "argument") if user == "" or user.include?(":")

  ok("Basic #{Base64.strict_encode64("#{user}:#{password}".bytes)}")
end

# A part of the user info, percent-decoded, with an error that does not quote it.
def unescaped(text: String) -> Result[String]
  case URI.decode_uri_component(text)
    ok(decoded) -> ok(decoded)
    error(_) -> error(BAD_LOGIN, kind: "argument")
  end
end

# The headers of a request that goes through the proxy of `options`: the ones given, and the login of the proxy's user
# info unless the caller set `Proxy-Authorization` itself. Only the proxy gets it: the header is part of this request,
# which a forward proxy reads and does not pass on. A connection keeps its login apart: see `connection_headers`.
def with_login(
  options: HttpWire.ClientOptions,
  scheme: String,
  headers: List[HttpWire.Header],
) -> List[HttpWire.Header]
  # An `https` request is inside the tunnel, where the target reads it: the login went with the CONNECT only.
  return headers if options.proxy == "" or scheme == "https"

  case proxy_of(options)
    ok(proxy) -> add_login(proxy.login, headers)
    error(_) -> headers
  end
end

# The headers of a request on `conn`, with the login its options no longer hold. Only the call that holds the
# connection's exchange (or owns the connection) reads the login, so taking it and putting it back is safe.
def connection_headers(conn: Connection, headers: List[HttpWire.Header]) -> List[HttpWire.Header]
  return headers if conn.scheme == "https"

  case conn.login.recv(0)
    ok(login) ->
      _ = conn.login.send(login, 0)
      add_login(login, headers)
    error(_) -> headers
  end
end

def add_login(login: String, headers: List[HttpWire.Header]) -> List[HttpWire.Header]
  return headers if login == "" or not header_values(headers, "proxy-authorization").empty?

  List.append(headers, HttpWire.Header(name: "Proxy-Authorization", value: login))
end

# Whether the request on `conn` carried a login.
def offered?(conn: Connection) -> Bool
  case conn.login.recv(0)
    ok(login) ->
      _ = conn.login.send(login, 0)
      login != ""
    error(_) -> false
  end
end

# The error of a `407` from the proxy of `options`: it names the proxy, never the credentials. `offered` says whether
# the request carried a login.
def proxy_denied(options: HttpWire.ClientOptions, offered: Bool) -> String
  case proxy_of(options)
    ok(proxy) ->
      name = proxy_name(proxy.target)
      return "http: the proxy #{name} requires credentials (407): put user:password in the proxy URL" if not offered

      "http: the proxy #{name} refused the credentials (407)"
    error(message) -> "#{message}"
  end
end

# The 407 of a proxy as an error, with `message` from `proxy_denied` or `client_denied`.
def denied_error[T](message: String) -> Result[T] = error(message, kind: "http.protocol", code: 407)

# `proxy_denied` for the options of a client, whose user info is still in `proxy`.
def client_denied(options: HttpWire.ClientOptions) -> String
  case proxy_of(options)
    ok(proxy) -> proxy_denied(options, proxy.login != "")
    error(message) -> "#{message}"
  end
end

# True for a `407` answered by the proxy of `options` to an `http` request, which is an error for the call, not a
# response. Inside a tunnel (`https`) a 407 is the target's own answer.
def proxy_asked?(options: HttpWire.ClientOptions, scheme: String, status: Int) -> Bool
  status == 407 and options.proxy != "" and scheme == "http"
end

# `host:port` of a target as an error shows it: an IPv6 literal in brackets and the port always there.
def proxy_name(where: Target) -> String
  name = where.host
  if name.include?(":")
    name = "[#{name}]"
  end

  "#{name}:#{where.port}"
end

# The proxy of the environment for a URL scheme (`http` or `https`), as `http://host:port` text, or "".
def proxy_of_scheme(scheme: String) -> String
  lower = "http_proxy"
  upper = "HTTP_PROXY"
  # A CGI program (REQUEST_METHOD set) may have an HTTP_PROXY made from the request's Proxy header: httpoxy.
  cgi = Result.ok?(System.env("REQUEST_METHOD"))
  trusted = not cgi
  if scheme == "https"
    lower = "https_proxy"
    upper = "HTTPS_PROXY"
    trusted = true
  elsif cgi and System.os() == "windows"
    # Windows names are not case-sensitive: http_proxy is HTTP_PROXY, which a request may have made.
    return ""
  end

  value = env_value(lower, upper, trusted).strip
  return value if value == "" or value.include?("://")

  "http://#{value}"
end

# The variable `lower`, else `upper` when `upper_read`: the lower-case one wins, empty or not, as in curl. ""
# when unset.
def env_value(lower: String, upper: String, upper_read: Bool) -> String
  case System.env(lower)
    ok(value) -> value
    error(_) ->
      return "" if not upper_read

      Result.unwrap_or(System.env(upper), "")
  end
end

# True when `no_proxy` names the target `where`.
def no_proxy_for?(where: Target) -> Bool
  # Commas and spaces both separate entries, as in curl 7.86 and later.
  for entry in String.split(String.replace(env_value("no_proxy", "NO_PROXY", true), ",", " "), " ")
    item = String.downcase(entry.strip)
    return true if item == "*" or (item != "" and exempt?(item, where))
  end

  false
end

# One `no_proxy` entry against a target: `host`, `.domain`, `host:port`, `[v6]:port` or an IPv4 `a.b.c.d/bits`.
def exempt?(item: String, where: Target) -> Bool
  host = item
  port = 0
  if item.start_with?("[")
    close = first_of(item, "]")
    return false if close == String.length(item)

    host = String.slice(item, 1, close - 1)
    after = rest_of(item, close + 1)
    if after != ""
      return false if not after.start_with?(":")

      port = entry_port(rest_of(after, 1))
    end
  elsif List.size(String.split(item, ":")) == 2
    colon = first_of(item, ":")
    host = String.slice(item, 0, colon)
    port = entry_port(rest_of(item, colon + 1))
  end

  return false if port < 0 or (port > 0 and port != where.port)

  # One trailing dot (the root of a fully qualified name) is not part of the name, on either side.
  name = without_dot(where.host)
  return in_range?(host, name) if host.include?("/")

  suffix = without_dot(host)
  if suffix.start_with?("*.")
    suffix = rest_of(suffix, 1)
  end

  if suffix.start_with?(".")
    suffix = rest_of(suffix, 1)
  end

  return false if suffix == ""

  # An IP literal is matched by the same address or by a range, never by the tail of its digits (0.1 and 10.0.0.1).
  return name == suffix if ipv4_number(name) >= 0 or name.include?(":")

  name == suffix or name.end_with?(".#{suffix}")
end

# The name without one trailing dot.
def without_dot(name: String) -> String
  return String.slice(name, 0, String.length(name) - 1) if String.length(name) > 1 and name.end_with?(".")

  name
end

# The port of a `no_proxy` entry, or -1 when it is not 1..65535.
def entry_port(text: String) -> Int
  return -1 if text == "" or String.length(text) > 5 or not plain?(text, true)

  port = text.to_i!
  return -1 if port < 1 or port > 65535

  port
end

# True when the IPv4 address `host` is in the range `spec` (`10.0.0.0/8`); anything else is not in a range.
def in_range?(spec: String, host: String) -> Bool
  parts = String.split(spec, "/")
  # An entry the environment gives may be anything: only 1 or 2 digits are a prefix length.
  return false if List.size(parts) != 2 or parts[1] == "" or not plain?(parts[1], true) or String.length(parts[1]) > 2

  bits = parts[1].to_i!
  base = ipv4_number(parts[0])
  address = ipv4_number(host)
  return false if bits > 32 or base < 0 or address < 0

  # The bits below the prefix are cut off by dividing them away.
  step = 1
  for _ in 0...(32 - bits)
    step = step * 2
  end

  base / step == address / step
end

# An IPv4 address `a.b.c.d` as one number, or -1 when `text` is not one.
def ipv4_number(text: String) -> Int
  parts = String.split(text, ".")
  return -1 if List.size(parts) != 4

  total = 0
  for part in parts
    return -1 if part == "" or String.length(part) > 3 or not plain?(part, true) or part.to_i! > 255

    total = total * 256 + part.to_i!
  end

  total
end

def check_proxy(options: HttpWire.ClientOptions) -> Result[Void]
  return ok() if options.proxy == ""

  try proxy_target(options)
  ok()
end

# The connection to the host of `where`, idle and with no request yet. Its options keep the proxy without the user
# info, which only the header of each request needs.
def open_connection(where: Target, options: HttpWire.ClientOptions) -> Result[Connection]
  via = try connect_target(where, options)
  socket = try at_connect(open_socket(via, options))
  login: Channel[String] = Channel.new(1)
  kept = options
  if options.proxy != ""
    proxy = try proxy_of(options)
    _ = login.send(proxy.login, 0)
    kept = options.with(proxy: "http://#{host_authority(proxy.target.host, proxy.target.port)}")
  else
    _ = login.send("", 0)
  end

  cell: Channel[Exchange] = Channel.new(1)
  _ = cell.send(settled(IDLE, false), 0)
  ok(
    Connection(
      socket: socket,
      scheme: where.scheme,
      host: where.host,
      port: where.port,
      options: kept,
      login: login,
      cell: cell,
    ),
  )
end

# The socket of `start`: TLS with the context of `options.tls` for `https` (one with the system trust, built for this
# connection, when it names none), TCP for `http`.
def open_socket(where: Target, options: HttpWire.ClientOptions) -> Result[TCP.Socket]
  return tunnel_context(where, options) if where.scheme == "https" and options.proxy != ""

  wait = connect_ms(options, options.timeout_ms)
  return pinned_context(where, options, wait) if where.scheme == "https" and options.connect_to != ""

  if where.scheme == "https"
    case options.tls
      some(context) -> return HttpWire.connect_context(where.host, where.port, context, wait)
      none ->
        context = try TLS.client_context(TLS.ClientOptions())
        return HttpWire.connect_context(where.host, where.port, context, wait)
    end
  end
  reaching(TCP.connect(address_of(options, where.host), where.port, wait), options, where)
end

# The `https` socket of `start`, `open` and `upload` with `connect_to`: TCP to that address, then TLS to the name of
# the URL on the context of `options.tls` (or one with the system trust built for this connection).
def pinned_context(where: Target, options: HttpWire.ClientOptions, wait: Int) -> Result[TCP.Socket]
  context = try tunnel_trust(options)
  deadline = Time.monotonic_ms() + wait
  socket = try TCP.connect(options.connect_to, where.port, wait)
  left = try time_left(socket, deadline)
  upgraded = HttpWire.upgrade_context(socket, context, where.host, left)
  closing_on_error(upgraded, socket, options, where.host, where.port)
end

# The result of connecting to `where`, which is the proxy when the options have one: a failure names the proxy, so the
# caller does not take it for the target being down.
def reaching(connected: Result[TCP.Socket], options: HttpWire.ClientOptions, where: Target) -> Result[TCP.Socket]
  case connected
    ok(socket) -> ok(socket)
    error(e) ->
      return error(e) if options.proxy == ""

      error(e.with(message: "http: cannot reach the proxy #{proxy_name(where)}: #{e.message}"))
  end
end

# The `https` socket of `start`, `open` and `upload` through a proxy: the tunnel, then TLS inside it on the context of
# `options.tls`, or on one with the system trust built for this connection (as without a proxy).
def tunnel_context(where: Target, options: HttpWire.ClientOptions) -> Result[TCP.Socket]
  # The context is built first, so that its failure never leaves a tunnel socket behind.
  context = try tunnel_trust(options)
  deadline = Time.monotonic_ms() + connect_ms(options, options.timeout_ms)
  socket = try tunnel(options, where.host, where.port, deadline)
  left = try time_left(socket, deadline)
  upgraded = HttpWire.upgrade_context(socket, context, where.host, left)
  closing_on_error(upgraded, socket, options, where.host, where.port)
end

def tunnel_trust(options: HttpWire.ClientOptions) -> Result[TLS.Context]
  case options.tls
    some(context) -> ok(context)
    none -> TLS.client_context(TLS.ClientOptions())
  end
end

# `answer`, with `socket` closed when it is an error: a failed upgrade leaves the plain socket open only when its
# arguments were refused. Bytes that came with the CONNECT answer are the proxy's fault, so that error names the proxy
# and the tunnel; a TLS failure is the target's and stays as it is.
def closing_on_error(
  answer: Result[TCP.Socket],
  socket: TCP.Socket,
  options: HttpWire.ClientOptions,
  host: String,
  port: Int,
) -> Result[TCP.Socket]
  case answer
    ok(secured) -> ok(secured)
    error(message) ->
      TCP.close(socket)
      return error(message) if "#{message}" != BEFORE_TLS

      case proxy_of(options)
        ok(proxy) -> tunnel_failed(proxy, tunnel_name(host, port), message)
        error(_) -> error(message)
      end
  end
end

def tunnel_name(host: String, port: Int) -> String
  proxy_name(Target(scheme: "https", host: host, port: port, target: "/"))
end

# An error after the CONNECT went out, told with the proxy and the target, never with the login. It keeps the kind and
# the code of `e`.
def tunnel_failed[T](proxy: Proxy, target: String, e: Error) -> Result[T]
  error(
    e.with(
      message: "http: the tunnel to #{target} through the proxy #{proxy_name(proxy.target)} failed: #{e.message}",
    ),
  )
end

# A CONNECT tunnel to `host:port` through the proxy of `options`, as a plain socket the proxy now relays: CONNECT
# with the proxy's login (RFC 9110 9.3.6), then the head of the answer. A 2xx opens the tunnel; any other status is
# an error that names the proxy (a 407 as for an `http` request) and never the login or the answer's body.
def tunnel(options: HttpWire.ClientOptions, host: String, port: Int, deadline: Int) -> Result[TCP.Socket]
  proxy = try proxy_of(options)
  left = deadline - Time.monotonic_ms()
  return error(TIMED_OUT, kind: "net.timeout") if left <= 0

  socket = try reaching(TCP.connect(proxy.target.host, proxy.target.port, left), options, proxy.target)
  target = tunnel_name(host, port)
  case tunnel_opened(socket, proxy, target, deadline)
    ok(status) ->
      return ok(socket) if status >= 200 and status < 300

      TCP.close(socket)
      return denied_error(proxy_denied(options, proxy.login != "")) if status == 407

      error(
        "http: the proxy #{proxy_name(proxy.target)} refused the tunnel to #{target} (#{status})",
        kind: "http.protocol",
        code: status,
      )
    error(e) ->
      TCP.close(socket)
      tunnel_failed(proxy, target, e)
  end
end

# The CONNECT sent over `socket` and the status of the head that answers it.
def tunnel_opened(socket: TCP.Socket, proxy: Proxy, target: String, deadline: Int) -> Result[Int]
  head = "CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n"
  if proxy.login != ""
    head = "#{head}Proxy-Authorization: #{proxy.login}\r\n"
  end

  try TCP.send(socket, "#{head}\r\n", try time_left(socket, deadline))
  # The answer has no body to read: a 2xx is followed by the tunnel and the others are dropped with the socket.
  response = try read_head_of(socket, true, NO_BODY_LIMIT, deadline)
  ok(response.status)
end

# The one value of the cell of `conn`, which the call now holds. An empty cell means another call has it.
def take_exchange(conn: Connection) -> Result[Exchange]
  case conn.cell.recv(0)
    ok(exchange) -> ok(exchange)
    error(_) -> error("http: the connection is in use by another call", kind: "argument")
  end
end

def put_exchange(conn: Connection, exchange: Exchange) -> Void
  _ = conn.cell.send(exchange, 0)
end

# Closes the socket and leaves the connection over, whatever it was doing. A cell that another call holds is left to
# it: its next step fails on the closed socket.
def end_connection(conn: Connection) -> Void
  TCP.close(conn.socket)
  _ = conn.cell.recv(0)
  _ = conn.cell.send(settled(OVER, true), 0)
end

# The request head and body written and the response head read: the connection is now in the response, or ended.
def send_encoded(
  conn: Connection,
  request: String,
  head_only: Bool,
  body: Bytes,
  deadline: Int,
) -> Result[ResponseHead]
  case sent_request(conn, request, head_only, body, deadline)
    ok(head) -> head_taken(conn, head)
    error(message) ->
      end_connection(conn)
      error(message)
  end
end

# The connection after a response head: in its body, or ended by a proxy that asked for a login.
def head_taken(conn: Connection, head: HttpWire.ResponseHead) -> Result[ResponseHead]
  if proxy_asked?(conn.options, conn.scheme, head.status)
    end_connection(conn)
    return denied_error(proxy_denied(conn.options, offered?(conn)))
  end

  put_exchange(conn, finished_exchange(conn, exchange_of(head)))
  ok(ResponseHead(status: head.status, headers: head.headers))
end

# The head sent, the body after it, and the response head read (a HEAD request has no body in its answer).
def sent_request(
  conn: Connection,
  head: String,
  head_only: Bool,
  body: Bytes,
  deadline: Int,
) -> Result[HttpWire.ResponseHead]
  try write_outgoing(Outgoing(socket: conn.socket, head: head, body: body, by: deadline))
  read_head_of(conn.socket, head_only, NO_BODY_LIMIT, deadline)
end

# Where the connection stands after a head: reading its body, which a response with no body makes an empty one that
# `finished_exchange` settles at once.
def exchange_of(head: HttpWire.ResponseHead) -> Exchange
  framing = BY_LENGTH
  if head.chunked
    framing = BY_CHUNKS
  end
  if head.until_close
    framing = BY_CLOSE
  end
  chunks = HttpWire.chunked(NO_BODY_LIMIT)
  Exchange(phase: READING, framing: framing, left: head.length, chunks: chunks, closes: head.closes)
end

# A body that has been read to its end leaves the connection idle. It is closed instead when the server said so or
# when input is left after the body (a second response sent at once, or bytes after the last chunk): the next request
# would read that stale input as its answer.
def finished_exchange(conn: Connection, exchange: Exchange) -> Exchange
  return exchange if exchange.phase != READING or not body_ended?(exchange)
  if exchange.closes or not Result.unwrap_or(HttpWire.idle?(conn.socket, conn.options.timeout_ms), false)
    TCP.close(conn.socket)
    return settled(SPENT, true)
  end
  settled(IDLE, false)
end

def body_ended?(exchange: Exchange) -> Bool
  return exchange.chunks.done if exchange.framing == BY_CHUNKS
  return exchange.left == 0 if exchange.framing == BY_LENGTH
  false
end

# The next piece of a body, and the response after it. A piece is never empty unless the body is over.
def next_piece(socket: TCP.Socket, exchange: Exchange, most: Int, deadline: Int) -> Result[Step]
  return next_chunked(socket, exchange, most, deadline) if exchange.framing == BY_CHUNKS
  return next_until_close(socket, exchange, most, deadline) if exchange.framing == BY_CLOSE
  return ok(Step(piece: NO_BYTES, exchange: exchange)) if exchange.left == 0
  data = try recv_body(socket, smaller(exchange.left, most), deadline)
  return error(TRUNCATED, kind: "http.protocol") if data.empty?
  next = Exchange(
    phase: READING,
    framing: BY_LENGTH,
    left: exchange.left - data.size,
    chunks: exchange.chunks,
    closes: exchange.closes,
  )

  ok(Step(piece: data, exchange: next))
end

# A chunked body: the decoder says which bytes of each read are body, and a read may be all framing, so it goes on
# until there is a piece or the body is over.
def next_chunked(socket: TCP.Socket, exchange: Exchange, most: Int, deadline: Int) -> Result[Step]
  state = exchange.chunks
  while true
    return ok(Step(piece: NO_BYTES, exchange: with_chunks(exchange, state))) if state.done
    if state.remaining > 0
      data = try recv_body(socket, smaller(state.remaining, most), deadline)
      return error(TRUNCATED, kind: "http.protocol") if data.empty?
      return ok(Step(piece: data, exchange: with_chunks(exchange, HttpWire.chunk_read(state, data.size))))
    end
    data = try recv_body(socket, smaller(FRAME_BYTES, most), deadline)
    return error(TRUNCATED, kind: "http.protocol") if data.empty?
    case HttpWire.chunk(state, data, 0)
      ok(after) ->
        state = after
        if state.done and state.next != data.size
          # The framing read went past the last chunk: those bytes were taken from the input and are lost.
          exchange = Exchange(phase: READING, framing: BY_CHUNKS, left: 0, chunks: exchange.chunks, closes: true)
        end
        pieces = run_pieces(data, state.runs)
        return ok(Step(piece: Bytes.concat(pieces), exchange: with_chunks(exchange, state))) if not pieces.empty?
      error(problem) -> return error(problem.with(message: "http: #{rest_of(problem.message, 4)}"))
    end
  end
  error(TRUNCATED, kind: "http.protocol")
end

def with_chunks(exchange: Exchange, state: HttpWire.Chunk) -> Exchange
  Exchange(phase: READING, framing: BY_CHUNKS, left: 0, chunks: state, closes: exchange.closes)
end

# The pieces of data that the runs (start, length pairs) of the decoder name.
def run_pieces(data: Bytes, runs: List[Int]) -> List[Bytes]
  pieces: List[Bytes] = []
  at = 0
  while at < List.size(runs)
    pieces = pieces.push(data.slice(List.at(runs, at), List.at(runs, at + 1)))
    at = at + 2
  end
  pieces
end

# A body that ends with the connection: over TLS the end must be the peer's close_notify, else it was cut. The end
# is a body of length 0 that closes the connection, which `finished_exchange` does.
def next_until_close(socket: TCP.Socket, exchange: Exchange, most: Int, deadline: Int) -> Result[Step]
  data = try recv_body(socket, most, deadline)
  if data.empty?
    return error(TRUNCATED, kind: "http.protocol") if not HttpWire.clean_eof?(socket)
    done = Exchange(phase: READING, framing: BY_LENGTH, left: 0, chunks: exchange.chunks, closes: true)
    return ok(Step(piece: NO_BYTES, exchange: done))
  end
  ok(Step(piece: data, exchange: exchange))
end

def upload_whole(
  method: String,
  url: String,
  body: Channel[Bytes],
  length: Int,
  headers: List[HttpWire.Header],
  options: HttpWire.ClientOptions,
) -> Result[HttpWire.Response]
  try check_client(options)

  if method != "POST" and method != "PUT" and method != "PATCH"
    return error("http: upload takes POST, PUT or PATCH", kind: "argument")
  end
  return error("http: length must be -1 (chunked) or the number of bytes", kind: "argument") if length < UNSIZED
  where = try parse_url(url)
  conn = try open_connection(where, options)
  answer = uploaded(conn, where.target, method, body, length, headers)
  end_connection(conn)
  answer
end

# `send_request` with the time by which the head of the answer must have come.
def sent_by(
  conn: Connection,
  method: String,
  target: String,
  body: Bytes,
  headers: List[HttpWire.Header],
  deadline: Int,
) -> Result[ResponseHead]
  exchange = try take_exchange(conn)
  if exchange.phase == READING
    put_exchange(conn, exchange)
    return error("http: the body of the last response is not read to its end", kind: "argument")
  end
  if exchange.phase == OVER or exchange.phase == SPENT
    put_exchange(conn, exchange)
    return error(CONNECTION_OVER, kind: "http.closed")
  end
  # A request that cannot be encoded (a bad method, header or target, a body over the limit) was never written, so
  # the connection is as healthy as before. Only a failure after the first byte ends it.
  encoded = HttpWire.encode_request(
    conn.scheme,
    conn.host,
    conn.port,
    method,
    connection_target(conn, target),
    connection_headers(conn, headers),
    body,
    conn.options.max_body_bytes,
  )

  case encoded
    ok(request) -> send_encoded(conn, request, method == "HEAD", body, deadline)
    error(message) ->
      put_exchange(conn, exchange)
      error(message)
  end
end

def spent?(conn: Connection) -> Bool
  case take_exchange(conn)
    ok(exchange) ->
      put_exchange(conn, exchange)
      exchange.phase == SPENT or exchange.phase == OVER
    error(_) -> false
  end
end

def ended(_pieces: Channel[Bytes]) -> Result[Void] = ok()

# The task of a Stream: it ends the channel and the connection on every path, so the reader's loop ends.
def feed_stream(feed: Feed) -> Result[Void]
  outcome = feed_pieces(feed.conn, feed.pieces)
  feed.pieces.close
  end_connection(feed.conn)
  outcome
end

def feed_pieces(conn: Connection, pieces: Channel[Bytes]) -> Result[Void]
  while true
    piece = try read_body(conn, READ_BYTES)
    return ok() if piece.empty?
    try pieces.send(piece, read_ms(conn.options))
  end
  ok()
end

# The request head and the body from the channel, then the whole response. The head is encoded with an empty body,
# which says Content-Length: 0 for a POST, PUT or PATCH: `stream_head` puts the real framing there.
def uploaded(
  conn: Connection,
  target: String,
  method: String,
  body: Channel[Bytes],
  length: Int,
  headers: List[HttpWire.Header],
) -> Result[HttpWire.Response]
  timeout = read_ms(conn.options)
  head = try HttpWire.encode_request(
    conn.scheme,
    conn.host,
    conn.port,
    method,
    connection_target(conn, target),
    connection_headers(conn, headers),
    NO_BYTES,
    conn.options.max_body_bytes,
  )

  framed = try stream_head(head, length)
  # A failure to write is not the end: a server that refused the upload (a 413) answers and closes, and its answer is
  # waiting in the input. It is returned when it can be read; else the failure is.
  written: Result[Void] = ok()
  case TCP.send_bytes(conn.socket, head_bytes(framed), timeout)
    ok(_) -> written = try upload_pieces(conn.socket, body, length, timeout)
    error(e) -> written = write_failed(e)
  end
  case read_head_of(conn.socket, false, SERVER_MAX_BODY, after(conn.options.timeout_ms))
    ok(response) -> upload_answer(conn, response)
    error(message) ->
      case written
        ok(_) -> error(message)
        error(failed) -> error(failed)
      end
  end
end

# The response of an upload, whole, from its head on.
def upload_answer(conn: Connection, response: HttpWire.ResponseHead) -> Result[HttpWire.Response]
  if proxy_asked?(conn.options, conn.scheme, response.status)
    end_connection(conn)
    return denied_error(proxy_denied(conn.options, offered?(conn)))
  end

  try take_exchange(conn)
  put_exchange(conn, finished_exchange(conn, exchange_of(response)))
  whole = try read_whole(conn, conn.options.max_body_bytes, after(WATCH_MS))
  ok(HttpWire.Response(status: response.status, headers: response.headers, body: whole))
end

# Sends each piece of the channel as it comes: as chunks, until the channel closes and then the last chunk, or with a
# `length`, as they are and only while they fit in it, ending at the last byte (the producer need not close the
# channel). The result is `ok()` when everything was written, the failed write when one failed, and an `error` for a
# problem of the body itself (too long, too short, a silent channel), which no answer of the server changes.
def upload_pieces(socket: TCP.Socket, body: Channel[Bytes], length: Int, timeout: Int) -> Result[Result[Void]]
  count = 0
  while length == UNSIZED or count < length
    case body.recv(timeout)
      ok(piece) ->
        if length != UNSIZED and count + piece.size > length
          return error("http: the upload body is longer than its length", kind: "argument")
        end
        count = count + piece.size
        case emit(socket, with_queued(body, piece, length), timeout, length, 0)
          ok(_) -> nil
          error(e) -> return ok(write_failed(e))
        end
      error(message) ->
        return error(message) if "#{message}" != CHANNEL_CLOSED
        break
    end
  end
  if length == UNSIZED
    case TCP.send(socket, "0\r\n\r\n", timeout)
      ok(_) -> return ok(ok())
      error(e) -> return ok(write_failed(e))
    end
  end
  return error("http: the upload body is shorter than its length", kind: "argument") if count != length
  ok(ok())
end

# A failed write of an upload, with its kind and code.
def write_failed(e: Error) -> Result[Void] = error(e.with(message: "http: #{e.message}"))

# The next piece of the body of the last response, which must have come by `deadline`.
def read_piece(conn: Connection, max_bytes: Int, deadline: Int) -> Result[Bytes]
  exchange = try take_exchange(conn)
  if exchange.phase == OVER
    put_exchange(conn, exchange)
    return error(CONNECTION_OVER, kind: "http.closed")
  end
  if exchange.phase == IDLE or exchange.phase == SPENT
    put_exchange(conn, exchange)
    return ok(NO_BYTES)
  end
  case next_piece(conn.socket, exchange, max_bytes, deadline)
    ok(step) ->
      put_exchange(conn, finished_exchange(conn, step.exchange))
      ok(step.piece)
    error(message) ->
      end_connection(conn)
      error(message)
  end
end

# True when the head announced a `Content-Length` over `most`: the body is refused before it is read, as one that grows
# past the limit is.
def announced_over?(conn: Connection, most: Int) -> Bool
  case take_exchange(conn)
    ok(exchange) ->
      put_exchange(conn, exchange)
      exchange.phase == READING and exchange.framing == BY_LENGTH and exchange.left > most
    error(_) -> false
  end
end

# The rest of the body of the last response, as one value of at most `most` bytes, which must have come by `by`
# (each piece also within `read_timeout_ms`).
def read_whole(conn: Connection, most: Int, by: Int) -> Result[Bytes]
  return error(TOO_LARGE, kind: "http.too_large", code: 413) if announced_over?(conn, most)

  pieces: List[Bytes] = []
  total = 0
  while true
    piece = try read_piece(conn, BODY_READ_BYTES, smaller(after(read_ms(conn.options)), by))
    return ok(Bytes.concat(pieces)) if piece.empty?
    total = total + piece.size
    return error(TOO_LARGE, kind: "http.too_large", code: 413) if total > most
    pieces = pieces.push(piece)
  end
  error(TRUNCATED, kind: "http.protocol")
end

# The options of a client: the numbers are positive, but `read_timeout_ms`, whose 0 is no limit.
# The options of a download: positive limits and a digest of 64 hex digits.
def check_download(options: DownloadOptions) -> Result[Void]
  if options.timeout_ms.unwrap_or(1) <= 0 or options.max_total_bytes.unwrap_or(1) <= 0
    return error("http: every download option must be positive", kind: "argument")
  end
  case options.sha256
    some(hex) ->
      return ok() if hex.length == 64 and OpenSSL.Digest.hexdecode(hex).ok?
      error("http: sha256 must be 64 hex digits", kind: "argument")
    none -> ok()
  end
end

def check_client(options: HttpWire.ClientOptions) -> Result[Void]
  try check_options(
    options.timeout_ms,
    options.idle_timeout_ms,
    options.max_connections,
    options.max_body_bytes,
    CLIENT_MAX_BODY,
  )

  return error("http: every option must be positive", kind: "argument") if options.connect_timeout_ms <= 0
  if options.read_timeout_ms < 0
    return error("http: read_timeout_ms must be 0 (no limit) or positive", kind: "argument")
  end
  check_connect_to(options)
end

# `connect_to` is empty or an IP address in the strict forms below (so the resolver reads it as the same address and
# never as a name), and does not go with a proxy.
def check_connect_to(options: HttpWire.ClientOptions) -> Result[Void]
  address = options.connect_to
  return ok() if address == ""

  if not ipv4_address?(address) and not ipv6_address?(address)
    return error(
      "http: connect_to must be a destination IP address (IPv4 a.b.c.d or IPv6, not 0.0.0.0 or ::)",
      kind: "argument",
    )
  end

  return error("http: connect_to cannot be used with a proxy", kind: "argument") if options.proxy != ""

  ok()
end

# Four decimal numbers from 0 to 255 with no leading zero: the resolver reads `012` as octal and `010` as 8. `0.0.0.0`
# is refused with the unspecified IPv6 address: it is no destination, and on Linux it reaches the local host.
def ipv4_address?(text: String) -> Bool
  parts = String.split(text, ".")
  return false if List.size(parts) != 4

  for part in parts
    return false if part == "" or String.length(part) > 3 or not plain?(part, true)
    return false if part.start_with?("0") and String.length(part) > 1
    return false if part.to_i! > 255
  end
  text != "0.0.0.0"
end

# At most 8 groups of 1 to 4 hex digits, one `::` at most, and no dotted tail. The unspecified address (`::`) and an
# IPv4-mapped one (`::ffff:a.b.c.d` or its hex form) are refused: a caller passes the IPv4 address itself, so a check
# of it has one form to classify.
def ipv6_address?(text: String) -> Bool
  groups = ipv6_groups(text)
  return false if groups == []
  return false if ipv4_mapped?(groups)

  for group in groups
    return true if group != 0
  end
  false
end

# The 8 numbers of an IPv6 address with its `::` filled in, or `[]` when `text` is not one in the strict form.
def ipv6_groups(text: String) -> List[Int]
  invalid: List[Int] = []
  halves = String.split(text, "::")
  return invalid if text == "" or List.size(halves) > 2

  head = hex_groups(halves[0])
  return invalid if head == [-1]
  if List.size(halves) == 1
    return invalid if List.size(head) != 8
    return head
  end

  tail = hex_groups(halves[1])
  return invalid if tail == [-1] or List.size(head) + List.size(tail) > 7

  groups = head
  for _ in 0..(7 - List.size(head) - List.size(tail))
    groups = groups.push(0)
  end
  for group in tail
    groups = groups.push(group)
  end
  groups
end

def ipv4_mapped?(groups: List[Int]) -> Bool
  for k in 0..4
    return false if groups[k] != 0
  end
  groups[5] == 65535
end

# The numbers of the groups of `text`, separated by `:`; `[-1]` when a group is empty, longer than 4 or not hex.
def hex_groups(text: String) -> List[Int]
  groups: List[Int] = []
  return groups if text == ""

  for part in String.split(text, ":")
    return [-1] if part == "" or String.length(part) > 4

    value = 0
    for c in String.split(part, "")
      digit = hex_digit(String.code(c))
      return [-1] if digit < 0

      value = value * 16 + digit
    end
    groups = groups.push(value)
  end
  groups
end

def hex_digit(code: Int) -> Int
  return code - 48 if code >= 48 and code <= 57
  return code - 55 if code >= 65 and code <= 70
  return code - 87 if code >= 97 and code <= 102
  -1
end

# The address of a connect: `connect_to` when the options set it, else the host of the URL, which the system resolver
# then resolves. `Host`, the TLS server name and the certificate check always take the host of the URL.
def address_of(options: HttpWire.ClientOptions, host: String) -> String
  return host if options.connect_to == ""
  options.connect_to
end

# The wait for a connect: `connect_timeout_ms`, and never more than `left` of the call.
def connect_ms(options: HttpWire.ClientOptions, left: Int) -> Int = smaller(options.connect_timeout_ms, left)

# The wait of one read of a body, or of one piece of an upload: `read_timeout_ms`, a year for 0, since a timeout of a
# read closes the socket and so no wait is without an end. A wait never passes the deadline of the call it is in.
def read_ms(options: HttpWire.ClientOptions) -> Int
  return WATCH_MS if options.read_timeout_ms == 0
  smaller(options.read_timeout_ms, WATCH_MS)
end

# The time `ms` from now, at most a year: a huge timeout does not overflow the clock.
def after(ms: Int) -> Int = Time.monotonic_ms() + smaller(ms, WATCH_MS)

# The timeout of a connect says so in its details (`phase` is `connect`), so a caller tells it from a read's timeout.
def at_connect[T](answer: Result[T]) -> Result[T]
  case answer
    ok(value) -> ok(value)
    error(e) ->
      return error(e) if e.kind != "net.timeout"
      error(e.with(details: e.details.put("phase", "connect")))
  end
end

# `most_body` is the ceiling of `max_body_bytes`: CLIENT_MAX_BODY for a client, SERVER_MAX_BODY for a server.
def check_options(
  timeout_ms: Int,
  idle_timeout_ms: Int,
  max_connections: Int,
  max_body_bytes: Int,
  most_body: Int,
) -> Result[Void]
  if timeout_ms <= 0 or idle_timeout_ms <= 0 or max_connections <= 0 or max_body_bytes <= 0
    return error("http: every option must be positive", kind: "argument")
  end
  return error("http: max_connections must be at most 65536", kind: "argument") if max_connections > 65536
  return error("http: max_body_bytes must be at most #{most_body}", kind: "argument") if max_body_bytes > most_body
  ok()
end

# The charset parameter of the first Content-Type header, in lowercase and unquoted; "" when there is none.
def charset_of(headers: List[HttpWire.Header]) -> String
  types = header_values(headers, "content-type")
  return "" if List.size(types) == 0
  parameters = String.split(List.at(types, 0), ";")
  for parameter in List.drop(parameters, 1)
    at = first_of(parameter, "=")
    if at < parameter.length and parameter.slice(0, at).strip.downcase == "charset"
      value = rest_of(parameter, at + 1).strip
      if value.length >= 2 and value.start_with?("\"") and value.end_with?("\"")
        value = value.slice(1, value.length - 2)
      end
      return value.downcase
    end
  end
  ""
end

def first_of(text: String, part: String) -> Int = text.index_of(part).unwrap_or(text.length)

def rest_of(text: String, start: Int) -> String = String.slice(text, start, String.length(text) - start)

def plain?(text: String, digits_only: Bool) -> Bool
  for c in String.split(text, "")
    code = String.code(c)
    return false if code < 33 or code > 126 or (digits_only and (code < 48 or code > 57))
  end
  true
end

def ipv6?(text: String) -> Bool
  return false if not text.include?(":")
  for c in String.split(text, "")
    code = String.code(c)
    if not ((code >= 48 and code <= 58) or (code >= 65 and code <= 70) or (code >= 97 and code <= 102) or code == 46)
      return false
    end
  end
  true
end

def bad_url() -> Result[Target]
  error("http: the URL must be http:// or https:// with a host, and without user info", kind: "argument")
end

def parse_url(url: String) -> Result[Target]
  split = first_of(url, "://")
  scheme = String.downcase(String.slice(url, 0, split))
  return bad_url() if split == String.length(url) or (scheme != "http" and scheme != "https")
  rest = rest_of(url, split + 3)
  rest = String.slice(rest, 0, first_of(rest, "#"))
  stop = first_of(rest, "/")
  query = first_of(rest, "?")
  if query < stop
    stop = query
  end
  authority = String.slice(rest, 0, stop)
  target = rest_of(rest, stop)
  if not target.start_with?("/")
    target = "/#{target}"
  end
  host = authority
  port_text = ""
  if authority.start_with?("[")
    close = first_of(authority, "]")
    return bad_url() if close == String.length(authority)
    host = String.slice(authority, 1, close - 1)
    return bad_url() if not ipv6?(host)
    after = rest_of(authority, close + 1)
    if after != ""
      return bad_url() if after == ":" or not after.start_with?(":")
      port_text = rest_of(after, 1)
    end
  elsif authority.include?(":")
    colon = first_of(authority, ":")
    host = String.slice(authority, 0, colon)
    port_text = rest_of(authority, colon + 1)
    return bad_url() if port_text == ""
  end
  return bad_url() if host == "" or authority.include?("@") or not plain?(host, false) or not plain?(port_text, true)
  port = 80
  if scheme == "https"
    port = 443
  end
  return error("http: the port must be 1..65535", kind: "argument") if String.length(port_text) > 5
  if port_text != ""
    port = port_text.to_i!
  end
  return error("http: the port must be 1..65535", kind: "argument") if port < 1 or port > 65535
  ok(Target(scheme: scheme, host: String.downcase(host), port: port, target: target))
end

def start_server(listener: TCP.Listener, app: App, options: HttpWire.ServerOptions) -> HttpWire.Server
  # The `done` of every request with no body. It ends here, in the caller's task: `close_server` cancels the
  # server's tasks, and a task of its own could end cancelled before it ran.
  ended = Task.spawn(&no_body)
  _ = Task.await(ended)
  HttpWire.server(listener, options.max_connections) do |server|
    accept_all(Service(server: server, app: app, options: options, ended: ended))
  end
end

# The accept loop. Each connection has an `idle` channel, which holds the connection's task while it waits for a
# request and closes when the connection ends. A graceful stop (`shutdown`) ends the accepts, and then this task
# drains the connections.
def accept_all(service: Service) -> Void
  conns: List[Channel[TaskRef]] = []
  prune_at = PRUNE_CONNS
  while true
    case HttpWire.accept(service.server)
      ok(socket) ->
        idle: Channel[TaskRef] = Channel.new(1)
        conns = conns.push(idle)
        if conns.length >= prune_at
          conns = conns.select do |c| not c.closed? end
          prune_at = larger(PRUNE_CONNS, 2 * conns.length)
        end
        HttpWire.spawn(service.server, socket) do |s| serve_tracked(s, service, idle) end
      error(_) ->
        deadline = HttpWire.stopping(service.server)
        if deadline >= 0
          drain_server(service.server, conns, deadline)
        end
        return
    end
  end
end

# Waits for each connection to end until `deadline`, then closes the server. A connection's task in `idle` waits for
# a request, so it is cancelled at once. `idle` closes when its connection ends in any way.
def drain_server(server: HttpWire.Server, conns: List[Channel[TaskRef]], deadline: Int) -> Void
  for idle in conns
    case idle.recv(0)
      ok(task) -> Task.cancel(task)
      error(_) -> nil
    end
  end
  for idle in conns
    while true
      case idle.recv(larger(0, deadline - Time.monotonic_ms()))
        ok(task) -> Task.cancel(task)
        error(_) -> break
      end
    end
  end
  HttpWire.close_server(server)
end

# A monitor closes `idle` when the connection's task ends, also by a crash or a cancel; its message is dropped.
def serve_tracked(socket: TCP.Socket, service: Service, idle: Channel[TaskRef]) -> Void
  me = Task.current()
  Task.monitor(me, idle) do |_|
    idle.close
    me
  end

  serve_connection(socket, service, Waiting(idle: idle, me: me))
end

# One task per connection: each request's head is read first, then `answer_app` feeds its body to the app and sends
# the answer. The first request may take `request_timeout_ms` to start, the next ones `idle_timeout_ms`.
def serve_connection(socket: TCP.Socket, service: Service, idle: Waiting) -> Void
  options = service.options
  wait_ms = options.request_timeout_ms
  rest = NO_BYTES
  while true
    case start_request(socket, rest, wait_ms, service, idle)
      ok(reading) ->
        sent = answer_app(reading, service)
        return if not sent.keep
        rest = sent.rest
      error(_) -> return
    end
    wait_ms = options.idle_timeout_ms
  end
end

# A request up to its body: the head read and checked against `max_body_bytes` as the largest body, and `100 Continue`
# sent when the client waits for it. While it waits for the first byte, the connection's task is in `idle`, where a
# graceful stop takes it to cancel it; a stop that began before the send, or took the task as the byte came, ends the
# connection.
def start_request(socket: TCP.Socket, rest: Bytes, first_ms: Int, service: Service, idle: Waiting) -> Result[Reading]
  options = service.options
  first = rest
  if first.empty?
    _ = idle.idle.send(idle.me, 0)
    stopped = HttpWire.stopping(service.server) >= 0
    if not stopped
      first = try TCP.recv_bytes(socket, 1, first_ms)
    end
    return error(SERVER_STOPPING, kind: "http.closed") if not Result.ok?(idle.idle.recv(0)) or stopped
    return error(END_OF_INPUT, kind: "net.eof") if first.empty?
  end
  deadline = Time.monotonic_ms() + options.request_timeout_ms
  max_body_bytes = options.max_body_bytes
  head = try read_head(socket, first, deadline, max_body_bytes)
  if head.expect_continue and (head.chunked or head.length > 0) and head.buffered == 0
    try TCP.send(socket, "HTTP/1.1 100 Continue\r\n\r\n", try time_left(socket, deadline))
  end
  ok(Reading(socket: socket, head: head, deadline: deadline, max_body_bytes: max_body_bytes))
end

# The head stays in the socket's input until it is whole (HttpWire.read_head), so a slow head holds no bytes here.
# The parser answers 501 to every `Upgrade` except a WebSocket handshake, which goes on to the app.
def read_head(socket: TCP.Socket, rest: Bytes, deadline: Int, max_body_bytes: Int) -> Result[HttpWire.Head]
  left = try time_left(socket, deadline)
  case HttpWire.read_head(socket, rest, max_body_bytes, left)
    ok(head) ->
      return refuse(socket, head.status, head.reason, deadline) if head.status > 0
      ok(head)
    error(message) ->
      TCP.close(socket)
      error(message)
  end
end

# The response, with `Connection: close` added unless the body of the request was read whole.
def closing_unless(response: HttpWire.Response, whole: Bool) -> HttpWire.Response
  return response if whole
  headers = response.headers.push(HttpWire.Header(name: "Connection", value: "close"))
  HttpWire.Response(status: response.status, headers: headers, body: response.body)
end

# One request, whose body goes to the app as it arrives: a task feeds it on a channel, and the answer goes out as a
# whole response, a stream or an upgrade. When the app returns, the pieces close and the server waits for the feeder's
# last word, at most ANSWER_MS: the bytes read past a whole body, or the close of `left` when the body failed or the
# closed pieces stopped it. So a body that was all there (an empty chunked one, say) counts as read whatever the app
# did with it, and a request with no body counts as read at once. Otherwise the answer says `Connection: close`, an
# upgrade is refused, and after the answer the feeder is cancelled, the input drained and the connection closed.
def answer_app(reading: Reading, service: Service) -> Sent
  app = service.app
  options = service.options
  socket = reading.socket
  head = reading.head
  request = HttpWire.Request(
    method: head.method,
    target: head.target,
    path: head.path,
    headers: head.headers,
    body: NO_BYTES,
    remote_addr: TCP.remote_address(socket),
  )

  if not head.chunked and head.length == 0
    # Nothing to feed: the app gets closed pieces and a task that has already ended ok, so `read_all` waits for
    # nothing that a closing server could cancel.
    body = RequestBody(pieces: closed_pieces(), done: service.ended)
    answer = app.call(request, body)
    return send_answer(socket, request, answer, true, stopping?(service), NO_BYTES, options)
  end
  pieces: Channel[Bytes] = Channel.new(UPLOAD_PIECES)
  left: Channel[Bytes] = Channel.new(1)
  feeder = Task.spawn(
    &feed_request,
    Feeding(reading: reading, step_ms: options.request_timeout_ms, pieces: pieces, rest: left),
  )

  result = app.call(request, RequestBody(pieces: pieces, done: feeder))
  pieces.close
  past = left.recv(ANSWER_MS)
  if cancelled?(feeder)
    # A closing server cancels the feeder (or the app did), and then no answer goes out: the app read a body that is
    # gone (`app` answers 400 for it).
    TCP.close(socket)
    return Sent(keep: false, rest: NO_BYTES)
  end
  whole = Result.ok?(past)
  sent = send_answer(socket, request, result, whole, stopping?(service), Result.unwrap_or(past, NO_BYTES), options)
  if whole
    _ = Task.await(feeder)
    return sent
  end
  Task.cancel(feeder)
  drain(socket, Time.monotonic_ms() + ANSWER_MS)
  TCP.close(socket)
  Sent(keep: false, rest: NO_BYTES)
end

def stopping?(service: Service) -> Bool = HttpWire.stopping(service.server) >= 0

# The pieces of a request with no body.
def closed_pieces() -> Channel[Bytes]
  pieces: Channel[Bytes] = Channel.new(1)
  pieces.close
  pieces
end

# The feeder of a request with no body.
def no_body() -> Result[Void] = ok()

# Whether the feeder ended cancelled. A feeder that still reads a body the app left unread gets 1 ms before it counts
# as not cancelled.
def cancelled?(feeder: Task[Result[Void]]) -> Bool
  case Task.await(feeder, 1)
    Await.Done(outcome) ->
      case outcome
        error(message) -> "#{message}" == TASK_CANCELLED
        ok(_) -> false
      end
    Await.TimedOut -> false
  end
end

# Sends the answer of an app. `whole` says whether the request body was read whole, and `rest` holds the bytes read
# past it (the start of the next request). An upgrade needs the whole body: before that, the connection is not free
# to change protocols, so an `Accept` is refused with a 500 and a `Reply` closes after it. A server that is `stopping`
# closes the connection after its answer and answers an accepted upgrade 503.
def send_answer(
  socket: TCP.Socket,
  request: HttpWire.Request,
  result: Result[Answer],
  whole: Bool,
  stopping: Bool,
  rest: Bytes,
  options: HttpWire.ServerOptions,
) -> Sent
  timeout = options.request_timeout_ms
  incoming = Incoming(request: request, rest: rest)
  case result
    ok(answer) ->
      case answer
        Answer.Whole(response) ->
          keep = reply_whole(socket, request, closing_unless(response, whole and not stopping), timeout)
          return Sent(keep: keep, rest: rest)
        Answer.Stream(response) ->
          return answer_stream(socket, incoming, stream_closing_unless(response, whole and not stopping), options)
        Answer.Upgrade(upgrade) ->
          if stopping
            refusal = closing_answer(503)
            case upgrade
              Upgrade.Reply(response) -> refusal = closing_unless(response, false)
              Upgrade.Accept(_, _, _, _) -> nil
            end
            return Sent(keep: reply_whole(socket, request, refusal, timeout), rest: NO_BYTES)
          end
          return answer_upgrade(socket, incoming, upgrade, options) if whole
          case upgrade
            Upgrade.Reply(response) -> reply_whole(socket, request, closing_unless(response, false), timeout)
            Upgrade.Accept(_, _, _, _) ->
              IO.warn("http: invalid response: an upgrade before the request body was read")
              failed(socket, request, timeout)
          end
      end
    error(message) ->
      IO.warn("http: handler error: #{message}")
      failed(socket, request, timeout)
  end
  Sent(keep: false, rest: NO_BYTES)
end

# The streamed response, with `Connection: close` added unless the body of the request was read whole.
def stream_closing_unless(response: StreamResponse, whole: Bool) -> StreamResponse
  return response if whole
  headers = response.headers.push(HttpWire.Header(name: "Connection", value: "close"))
  StreamResponse(status: response.status, headers: headers, body: response.body, length: response.length)
end

# The answer of `app(handler)`: the body read whole (the `body_refusal` of its error when it cannot be), then the
# handler's response.
def whole_answer(handler: Handler, max_body_bytes: Int, request: HttpWire.Request, body: RequestBody) -> Result[Answer]
  return ok(Answer.Whole(closing_answer(413))) if announced_length(request.headers) > max_body_bytes
  case read_all(body, max_body_bytes)
    ok(data) ->
      whole = HttpWire.Request(
        method: request.method,
        target: request.target,
        path: request.path,
        headers: request.headers,
        body: data,
        remote_addr: request.remote_addr,
      )

      ok(Answer.Whole(try handler.call(whole)))
    error(message) -> ok(body_refusal("#{message}"))
  end
end

# The `Content-Length` of a request, 0 without one. The head reader has already checked it, so it is digits.
def announced_length(headers: List[HttpWire.Header]) -> Int
  values = header_values(headers, "content-length")
  return 0 if values.empty? or not plain?(values[0], true)
  values[0].to_i!
end

def closing_answer(status: Int) -> HttpWire.Response
  HttpWire.Response(status: status, headers: [HttpWire.Header(name: "Connection", value: "close")], body: NO_BYTES)
end

# Checked when accept_websocket runs, so a bad number is an error there, not a hang later.
def check_websocket_options(options: WebSocketOptions) -> Result[Void]
  if options.max_message_bytes < 1 or options.max_message_bytes > SERVER_MAX_BODY
    return error("http: max_message_bytes must be 1 to 268435456", kind: "argument")
  end

  if options.idle_ms < 0 or options.ping_ms < 0
    return error("http: idle_ms and ping_ms must be 0 or more", kind: "argument")
  end

  return error("http: close_ms must be 1 or more", kind: "argument") if options.close_ms < 1

  if options.outgoing_queue < 1 or options.outgoing_queue > WS_MAX_QUEUE
    return error("http: outgoing_queue must be 1 to #{WS_MAX_QUEUE}", kind: "argument")
  end

  ok()
end

# The answer to a request that is not a WebSocket handshake, when it is not: 426 for another version, 400 otherwise.
def handshake_problem(request: HttpWire.Request) -> Optional[HttpWire.Response]
  headers = request.headers
  return some(handshake_refusal(400, "a WebSocket handshake is a GET", [])) if request.method != "GET"

  if not listed?(headers, "upgrade", "websocket") or not listed?(headers, "connection", "upgrade")
    return some(handshake_refusal(400, "not a WebSocket handshake", []))
  end

  if not listed?(headers, "sec-websocket-version", WS_VERSION)
    version = [HttpWire.Header(name: "Sec-WebSocket-Version", value: WS_VERSION)]
    return some(handshake_refusal(426, "unsupported WebSocket version", version))
  end

  keys = header_values(headers, "sec-websocket-key")
  if keys.size != 1 or not WebSocketWire.valid_key?(keys[0].strip)
    return some(handshake_refusal(400, "invalid Sec-WebSocket-Key", []))
  end

  none
end

def handshake_refusal(status: Int, reason: String, headers: List[HttpWire.Header]) -> HttpWire.Response
  HttpWire.Response(status: status, headers: headers, body: reason.bytes)
end

# True when a header called `name` lists `token`, in any of its lines.
def listed?(headers: List[HttpWire.Header], name: String, token: String) -> Bool
  for value in header_values(headers, name)
    return true if WebSocketWire.has_token?(value, token)
  end

  false
end

def accepted(request: HttpWire.Request, session: WebSocketSession, options: WebSocketOptions) -> Upgrade
  key = header_values(request.headers, "sec-websocket-key")[0].strip
  protocol = agreed_protocol(request.headers, options.protocols)
  Upgrade.Accept(session, options, WebSocketWire.accept_key(key), protocol)
end

# The first protocol of the server's list that the client offered, or "".
def agreed_protocol(headers: List[HttpWire.Header], ours: List[String]) -> String
  offered: List[String] = []
  for value in header_values(headers, "sec-websocket-protocol")
    for name in value.split(",")
      offered = offered.push(name.strip)
    end
  end

  for name in ours
    for wanted in offered
      return name if wanted == name
    end
  end

  ""
end

def answer_upgrade(socket: TCP.Socket, incoming: Incoming, upgrade: Upgrade, options: HttpWire.ServerOptions) -> Sent
  case upgrade
    Upgrade.Reply(response) ->
      keep = reply_whole(socket, incoming.request, response, options.request_timeout_ms)
      Sent(keep: keep, rest: incoming.rest)
    Upgrade.Accept(session, limits, key, protocol) ->
      case check_accept(limits, key, protocol)
        ok(_) -> run_websocket(socket, incoming.rest, session, limits, key, protocol, options)
        error(message) ->
          IO.warn("http: handler error: #{message}")
          failed(socket, incoming.request, options.request_timeout_ms)
      end

      Sent(keep: false, rest: NO_BYTES)
  end
end

# An `Upgrade.Accept` is made by `accept_websocket`, but its fields are public, so the server checks what it writes
# into the 101 answer (the key must be an accept key, the protocol a token) and the limits as `accept_websocket` does.
def check_accept(limits: WebSocketOptions, key: String, protocol: String) -> Result[Void]
  try check_websocket_options(limits)
  if not WebSocketWire.valid_accept?(key) or not WebSocketWire.token?(protocol)
    return error("http: an Upgrade.Accept must come from accept_websocket", kind: "argument")
  end

  ok()
end

# Writes the 101 answer, then runs the session in this task with a reader and a writer around it: the reader parses
# frames into `incoming`, and the writer turns `outgoing` into frames and is the only task that writes the socket, so
# frames never interleave. The session ends the connection: the close frame it leaves (or 1000) goes out and the writer
# finishes when the peer answered or `close_ms` passed; the reader is cancelled after.
def run_websocket(
  socket: TCP.Socket,
  rest: Bytes,
  session: WebSocketSession,
  limits: WebSocketOptions,
  key: String,
  protocol: String,
  options: HttpWire.ServerOptions,
) -> Void
  case TCP.send(socket, switching_head(key, protocol), options.request_timeout_ms)
    ok(_) -> run_session(socket, rest, session, limits, protocol, options.request_timeout_ms)
    error(_) -> TCP.close(socket)
  end
end

def switching_head(key: String, protocol: String) -> String
  head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
  head = "#{head}Sec-WebSocket-Accept: #{key}\r\n"
  if protocol != ""
    head = "#{head}Sec-WebSocket-Protocol: #{protocol}\r\n"
  end

  "#{head}\r\n"
end

def run_session(
  socket: TCP.Socket,
  rest: Bytes,
  session: WebSocketSession,
  limits: WebSocketOptions,
  protocol: String,
  write_ms: Int,
) -> Void
  incoming: Channel[Message] = Channel.new(WS_QUEUE)
  outgoing: Channel[Message] = Channel.new(limits.outgoing_queue)
  control: Channel[Control] = Channel.new(1)
  wire = Wire(
    socket: socket,
    incoming: incoming,
    outgoing: outgoing,
    control: control,
    wake: Message.Close(-1, "wake #{OpenSSL.Random.hex(8)}"),
    options: limits,
    write_ms: write_ms,
    rest: rest,
  )

  writer = Task.spawn(&write_frames, wire)
  reader = Task.spawn(&read_frames, wire)
  code = session_code(session.call(WebSocket(incoming: incoming, outgoing: outgoing, protocol: protocol)))
  incoming.close
  # A close the session already sent makes this one a no-op in the writer; a connection that is over has closed
  # `outgoing`, so the send fails at once. Once the reader left its last word the connection ends by it: this close
  # must not overtake it.
  if control.empty?
    offer(outgoing, Message.Close(code, ""), limits.close_ms)
  end
  Task.await(writer)
  Task.cancel(reader)
  TCP.close(socket)
end

# The close code for what a session returned: 1000, or 1011 (and a warning) for an error.
# A send whose failure does not matter: the channel was closed, or its reader is gone.
def offer[T](channel: Channel[T], value: T, wait_ms: Int) -> Void
  case channel.send(value, wait_ms)
    ok(_) -> return
    error(_) -> return
  end
end

def session_code(result: Result[Void]) -> Int
  case result
    ok(_) -> WebSocketWire.CLOSE_NORMAL
    error(message) ->
      IO.warn("http: websocket session error: #{message}")
      WebSocketWire.CLOSE_INTERNAL
  end
end

# The frame of a message.
def frame_of(message: Message) -> Bytes
  case message
    Message.Text(text) -> WebSocketWire.text_frame(text)
    Message.Binary(data) -> WebSocketWire.binary_frame(data)
    Message.Ping(data) -> WebSocketWire.ping_frame(cut_control(data))
    Message.Pong(data) -> WebSocketWire.pong_frame(cut_control(data))
    Message.Close(code, reason) -> WebSocketWire.close_frame(sendable_code(code), reason)
    Message.Prepared(frame) ->
      return frame if WebSocketWire.data_frame?(frame)

      # Bytes that are no frame `prepare` makes are the handler's mistake, as a close code that cannot be sent is.
      IO.warn("http: websocket Prepared message is not a frame of HTTP.prepare: closing with 1011")
      WebSocketWire.close_frame(WebSocketWire.CLOSE_INTERNAL, "")
  end
end

# Whether a frame `frame_of` made closes the connection: a close, or a `Prepared` it turned into one. The opcode is
# read off the frame, so a message is checked once.
def closing_frame?(frame: Bytes) -> Bool = WebSocketWire.close?(frame.at(0) % 16)

def cut_control(data: Bytes) -> Bytes = data.take(WS_CONTROL_BYTES)

# The code of a close frame a handler asked for; one that cannot be sent is the handler's mistake: 1011.
def sendable_code(code: Int) -> Int
  return code if WebSocketWire.valid_code?(code)

  WebSocketWire.CLOSE_INTERNAL
end

# Sends when the channel has room, waiting as long as it takes: a send that times out only starts the next wait. False
# when the channel is closed.
def send_when_room[T](channel: Channel[T], value: T) -> Bool
  while true
    case channel.send(value, WS_WAIT_MS)
      ok(_) -> return true
      error(_) -> return false if channel.closed?
    end
  end

  false
end

# The only task that writes the socket. It reads `outgoing` itself and writes every frame queued at that moment in one
# write, in order, up to `WS_BATCH_BYTES`. It ends the connection: after the peer's answer to a close frame we sent,
# the answer to a close of the peer's, a frame that reports a protocol error, the loss of the peer, or `close_ms`
# without an answer. Once our close frame is out nothing else is written, and what the handler sends is read and
# dropped, so a send never waits for a connection that is closing.
#
# There is no `select`, so the writer waits on `outgoing` alone. The reader puts its last word in `control` and then
# leaves a message in `outgoing` to rouse the writer (see `tell_writer`); the writer looks at `control` before it
# waits, and skips the wake when it takes it. If the handler closed `outgoing` itself, the writer waits on `control`
# instead: the connection still ends by the peer. The peer's close is answered after what the handler queued before it.
def write_frames(wire: Wire) -> Void
  closing = false
  woken = false
  deadline = 0
  drained = false
  while true
    if not wire.control.empty?
      end_by_control(wire, closing, woken)
      return
    end

    if closing and Time.monotonic_ms() >= deadline
      end_websocket(wire, false)
      return
    end

    if drained
      case wire.control.recv(writer_wait(wire.options, closing, deadline))
        ok(item) ->
          obey(wire, item, closing, woken)
          return
        error(_) ->
          if not keep_waiting(wire, closing)
            end_websocket(wire, false)
            return
          end
      end
    else
      case wire.outgoing.recv(writer_wait(wire.options, closing, deadline))
        ok(message) ->
          if not closing
            batch = gather(wire, message, false)
            if not Result.ok?(write_batch(wire, batch))
              end_websocket(wire, false)
              return
            end

            woken = woken or batch.woken
            if batch.closes
              closing = true
              deadline = Time.monotonic_ms() + wire.options.close_ms
            end
          end
        error(_) ->
          if wire.outgoing.closed? and wire.outgoing.empty?
            drained = true
          elsif not wire.outgoing.closed? and not keep_waiting(wire, closing)
            end_websocket(wire, false)
            return
          end
      end
    end
  end
end

# The frames of `first` and of every message queued behind it, joined in order. It stops after our close frame (the
# writer drops the rest), once `WS_BATCH_BYTES` are reached, and at the wake of the reader, which is not written (see
# `wake?`): what follows the wake was queued after the reader's last word and is dropped, e.g. a close that the session
# leaves when it returns. The gather of the writer's loop also stops as soon as `control` holds an item, since the wake
# may not be queued yet; the `flushing` one, which answers the peer's close, does not (`control` holds its item).
def gather(wire: Wire, first: Message, flushing: Bool) -> Batch
  frames: List[Bytes] = []
  size = 0
  closes = false
  woken = false
  message = first
  more = true
  while more
    more = false
    if wake?(wire, message)
      woken = true
    else
      frame = frame_of(message)
      frames = List.append(frames, frame)
      size = size + frame.size
      closes = closing_frame?(frame)
      if not closes and size < WS_BATCH_BYTES and (flushing or wire.control.empty?)
        case wire.outgoing.recv(0)
          ok(next) ->
            message = next
            more = true
          error(_) -> more = false
        end
      end
    end
  end

  return Batch(data: NO_BYTES, closes: false, woken: woken) if frames.empty?

  return Batch(data: frames[0], closes: closes, woken: woken) if frames.size == 1

  Batch(data: Bytes.concat(frames), closes: closes, woken: woken)
end

# Whether a message is the wake that `tell_writer` queued (`wire.wake`, a close nobody else can build: its reason is
# random for each connection, drawn from the system so that a seeded `Random` of the session is not shifted). It is
# never written.
def wake?(wire: Wire, message: Message) -> Bool
  case message
    Message.Close(code, reason) ->
      case wire.wake
        Message.Close(_, token) -> code == -1 and reason == token
        _ -> false
      end
    _ -> false
  end
end

# Writes the joined frames of a batch (nothing for an empty one) within `write_ms`.
def write_batch(wire: Wire, batch: Batch) -> Result[Void]
  return ok() if batch.data.empty?

  send_all(wire.socket, batch.data, wire.write_ms)
end

# What the writer does when its wait ended with no message: the connection ends when our close frame got no answer in
# `close_ms` or the channel is closed; else a ping is due (when `ping_ms` is set) or the wait starts again.
def keep_waiting(wire: Wire, closing: Bool) -> Bool
  return false if closing or wire.control.closed?

  return true if wire.options.ping_ms == 0

  Result.ok?(send_all(wire.socket, WebSocketWire.ping_frame(NO_BYTES), wire.write_ms))
end

# How long the writer waits for the next message: for the peer's answer once we closed, else until a ping is due.
def writer_wait(options: WebSocketOptions, closing: Bool, deadline: Int) -> Int
  return smaller(options.close_ms, larger(deadline - Time.monotonic_ms(), 0)) if closing

  quiet_wait(options)
end

# The wait of a task that has nothing to do until something comes: the interval of the pings, else a day. A timeout
# only starts the next wait.
def quiet_wait(options: WebSocketOptions) -> Int
  return options.ping_ms if options.ping_ms > 0

  WS_WAIT_MS
end

# The item that waits in `control` ends the connection. `woken`: the writer already read the wake, so everything
# queued before it was written.
def end_by_control(wire: Wire, closing: Bool, woken: Bool) -> Void
  case wire.control.recv(0)
    ok(item) -> obey(wire, item, closing, woken)
    error(_) -> end_websocket(wire, false)
  end
end

# Ends the connection as the reader says. The close frame of an `Echo` or a `Fail` goes out unless ours already did.
def obey(wire: Wire, item: Control, closing: Bool, woken: Bool) -> Void
  case item
    Control.Echo(frame) ->
      if closing or woken
        end_with(wire, frame, closing)
        return
      end

      case flush_queued(wire)
        ok(closes) -> end_with(wire, frame, closes)
        error(_) -> end_websocket(wire, false)
      end
    Control.Fail(frame) -> end_with(wire, frame, closing)
    Control.Gone -> end_websocket(wire, false)
  end
end

# Writes what the handler queued before the peer's close arrived, so the answer comes after it: everything up to the
# wake, in batches. True when a batch ended with a close frame of the handler: it is our close, and the answer is not
# sent. What the handler queued after the wake (an answer to the peer's close, say) is not written.
def flush_queued(wire: Wire) -> Result[Bool]
  while true
    case wire.outgoing.recv(0)
      ok(first) ->
        batch = gather(wire, first, true)
        try write_batch(wire, batch)
        return ok(true) if batch.closes

        return ok(false) if batch.woken
      error(_) -> return ok(false)
    end
  end

  ok(false)
end

# Sends the close frame of the reader unless ours is out already (`closing`), then ends the connection, lingering so
# the peer can read it.
def end_with(wire: Wire, frame: Bytes, closing: Bool) -> Void
  if not closing and not Result.ok?(send_all(wire.socket, frame, wire.write_ms))
    end_websocket(wire, false)
    return
  end

  end_websocket(wire, true)
end

# The end of the connection: the channels close, and the socket after what the peer already sent was read and dropped
# (so the close cannot turn into a reset that loses the last frame), when the reader is done with it.
def end_websocket(wire: Wire, lingers: Bool) -> Void
  wire.control.close
  wire.outgoing.close
  if lingers
    HttpWire.close_write(wire.socket)
    drain(wire.socket, Time.monotonic_ms() + ANSWER_MS)
  end

  TCP.close(wire.socket)
end

# The task that reads the socket: frames become messages on `incoming` until the peer's close, a problem, or the loss
# of the connection. Each of those leaves a `Close` for the handler, and `incoming` closes after it.
def read_frames(wire: Wire) -> Void
  rest = wire.rest
  assembly = WebSocketWire.new_assembly()
  going = true
  while going
    case read_frame(wire, rest, assembly.total)
      Read.Got(head, payload, more) ->
        rest = more
        if WebSocketWire.control?(head.opcode)
          going = on_control(wire, head, payload)
        else
          case WebSocketWire.take(assembly, head, payload, wire.options.max_message_bytes)
            WebSocketWire.Taken.More(next) -> assembly = next
            WebSocketWire.Taken.Whole(text, data, next) ->
              assembly = next
              going = deliver(wire, message_of(text, data))
            WebSocketWire.Taken.Broken(problem) ->
              fail(wire, problem)
              going = false
          end
        end
      Read.Bad(problem) ->
        fail(wire, problem)
        going = false
      Read.Lost ->
        lost(wire)
        going = false
    end
  end

  wire.incoming.close
end

def message_of(text: Bool, data: Bytes) -> Message
  return Message.Text(Result.unwrap_or(String.from_bytes(data), "")) if text

  Message.Binary(data)
end

# Hands a message to the handler, waiting for room; false when the handler is gone (the channel closed).
def deliver(wire: Wire, message: Message) -> Bool = send_when_room(wire.incoming, message)

# What a control frame does. True when the connection goes on.
def on_control(wire: Wire, head: WebSocketWire.Head, payload: Bytes) -> Bool
  return answer_ping(wire, payload) if WebSocketWire.ping?(head.opcode)

  if WebSocketWire.close?(head.opcode)
    on_close(wire, payload)
    return false
  end

  deliver(wire, Message.Pong(payload))
end

# The pong of a ping goes through `outgoing`, behind what the handler sent. True when the connection goes on: a
# handler that closed `outgoing` itself only loses the pong.
def answer_ping(wire: Wire, payload: Bytes) -> Bool
  return true if send_when_room(wire.outgoing, Message.Pong(payload))

  not wire.control.closed?
end

# The peer's close frame: the answer goes first, so the peer is not kept waiting for a handler that is slow to read.
def on_close(wire: Wire, payload: Bytes) -> Void
  case WebSocketWire.parse_close(payload)
    WebSocketWire.Closing.Peer(code, reason) ->
      tell_writer(wire, Control.Echo(WebSocketWire.close_frame(code, "")))
      last_word(wire, code, reason)
    WebSocketWire.Closing.Invalid(problem) -> fail(wire, problem)
  end
end

# A frame broke the rules: the close frame with the code goes out and ends the connection, and the handler is told.
def fail(wire: Wire, problem: WebSocketWire.Problem) -> Void
  tell_writer(wire, Control.Fail(WebSocketWire.close_frame(problem.code, problem.reason)))
  last_word(wire, problem.code, problem.reason)
end

def lost(wire: Wire) -> Void
  tell_writer(wire, Control.Gone)
  last_word(wire, WebSocketWire.CLOSE_ABNORMAL, "connection lost")
end

# The last message of the handler, given the time of a close and no more.
def last_word(wire: Wire, code: Int, reason: String) -> Void
  offer(wire.incoming, Message.Close(code, reason), wire.options.close_ms)
end

# The last word of the reader. The item goes first, so a writer that wakes finds it. The wake (`wire.wake`) goes in
# `outgoing` behind what the handler queued, and the writer stops at it: the messages before it go out ahead of the
# answer, the ones after it are dropped. So it waits for room as long as the connection lives; it is the writer that
# makes room, or closes `outgoing` when the connection ends.
def tell_writer(wire: Wire, item: Control) -> Void
  offer(wire.control, item, 0)
  _ = send_when_room(wire.outgoing, wire.wake)
end

# One frame: the head, its tail, then the payload unmasked. A frame that breaks a rule is `Bad` before its payload is
# read, so a message past the cap (`held` bytes of its earlier fragments and this frame) is never allocated.
def read_frame(wire: Wire, rest: Bytes, held: Int) -> Read
  case take_bytes(wire, rest, 2)
    error(_) -> Read.Lost
    ok(first) ->
      head = WebSocketWire.head_of(first.front)
      case WebSocketWire.check_head(head)
        some(problem) -> Read.Bad(problem)
        none -> read_tail(wire, head, first.rest, held)
      end
  end
end

def read_tail(wire: Wire, head: WebSocketWire.Head, rest: Bytes, held: Int) -> Read
  case take_bytes(wire, rest, WebSocketWire.tail_size(head))
    error(_) -> Read.Lost
    ok(tail) ->
      whole = WebSocketWire.complete(head, tail.front)
      case WebSocketWire.check_length(whole, wire.options.max_message_bytes, held)
        some(problem) -> Read.Bad(problem)
        none -> read_payload(wire, whole, tail.rest)
      end
  end
end

def read_payload(wire: Wire, head: WebSocketWire.Head, rest: Bytes) -> Read
  case take_bytes(wire, rest, head.length)
    error(_) -> Read.Lost
    ok(payload) -> Read.Got(head, WebSocketWire.unmask(payload.front, head.key), payload.rest)
  end
end

# Exactly `count` bytes, taken from `rest` and then from the socket; what was read past them is the new rest. A read
# that waits longer than `idle_ms` closes the socket (the peer is silent), and an end of input is an error.
def take_bytes(wire: Wire, rest: Bytes, count: Int) -> Result[Cut]
  return ok(Cut(front: rest.take(count), rest: rest.drop(count))) if rest.size >= count

  pieces = [rest]
  have = rest.size
  while have < count
    data = try TCP.recv_bytes(wire.socket, read_size(count - have), read_wait(wire.options))
    return error(END_OF_INPUT, kind: "net.eof") if data.empty?

    pieces = pieces.push(data)
    have = have + data.size
  end

  all = Bytes.concat(pieces)
  ok(Cut(front: all.take(count), rest: all.drop(count)))
end

# A small need reads what has arrived (up to READ_BYTES), so the head and tail of a frame are not two reads; a large
# one reads at most BODY_READ_BYTES at a time.
def read_size(need: Int) -> Int
  return READ_BYTES if need < READ_BYTES

  smaller(need, BODY_READ_BYTES)
end

# A timeout of a read closes the socket, so there is no wait without an end: with no `idle_ms` it is a year.
def read_wait(options: WebSocketOptions) -> Int
  return options.idle_ms if options.idle_ms > 0

  WATCH_MS
end

# The task of an upload: it sends the pieces of the body to the channel and closes it on every path. When the body
# ends, the bytes read past it go to `rest` first, so a handler that sees the channel closed finds the outcome ready.
def feed_request(feeding: Feeding) -> Result[Void]
  outcome = feed_body(feeding)
  case outcome
    ok(past) ->
      _ = feeding.rest.send(past, 0)
      feeding.pieces.close
      ok()
    error(message) ->
      feeding.pieces.close
      feeding.rest.close
      error(message)
  end
end

# The bytes read past the end of the body, or the reason it failed.
def feed_body(feeding: Feeding) -> Result[Bytes]
  reading = feeding.reading
  socket = reading.socket
  return feed_chunked(feeding) if reading.head.chunked
  left = reading.head.length
  while left > 0
    data = try more_request(socket, smaller(left, READ_BYTES), Time.monotonic_ms() + feeding.step_ms)
    try feeding.pieces.send(data, feeding.step_ms)
    left = left - data.size
  end
  ok(NO_BYTES)
end

def feed_chunked(feeding: Feeding) -> Result[Bytes]
  reading = feeding.reading
  socket = reading.socket
  state = HttpWire.chunked(reading.max_body_bytes)
  data = NO_BYTES
  while not state.done
    deadline = Time.monotonic_ms() + feeding.step_ms
    if state.remaining > 0
      data = try more_request(socket, smaller(state.remaining, READ_BYTES), deadline)
      try feeding.pieces.send(data, feeding.step_ms)
      state = HttpWire.chunk_read(state, data.size)
    else
      data = try more_request(socket, FRAME_BYTES, deadline)
      case HttpWire.chunk(state, data, 0)
        ok(next) -> state = next
        error(problem) -> return error(feed_problem(problem))
      end
      pieces = run_pieces(data, state.runs)
      if not pieces.empty?
        try feeding.pieces.send(Bytes.concat(pieces), feeding.step_ms)
      end
    end
  end
  ok(data.drop(state.next))
end

# The error of a chunked body the feeder cannot go on with ("NNN reason" from HttpWire.chunk): one over the limit is
# BODY_TOO_LONG, as `read_all` says it, so `body_refusal` answers it 413, and a 431 starts with FIELDS_TOO_LARGE. It
# keeps the kind and the code of the problem.
def feed_problem(problem: Error) -> Error
  text = problem.message
  return problem.with(message: BODY_TOO_LONG) if text.start_with?("413")
  return problem.with(message: FIELDS_TOO_LARGE + rest_of(text, 4)) if text.start_with?("431")
  problem.with(message: "http: #{rest_of(text, 4)}")
end

def smaller(a: Int, b: Int) -> Int
  return a if a < b
  b
end

# The next bytes of a request that has started: the end of input here closes the connection with no answer.
def more_request(socket: TCP.Socket, most: Int, deadline: Int) -> Result[Bytes]
  data = try TCP.recv_bytes(socket, most, try time_left(socket, deadline))
  if data.empty?
    TCP.close(socket)
    return error("http: connection closed before the request was complete", kind: "http.closed")
  end
  ok(data)
end

# The milliseconds left before deadline. When none are left the socket closes, as a timeout in TCP closes it.
def time_left(socket: TCP.Socket, deadline: Int) -> Result[Int]
  left = deadline - Time.monotonic_ms()
  if left <= 0
    TCP.close(socket)
    return error("network: operation timed out", kind: "net.timeout")
  end
  ok(left)
end

# Answers a bad request, closes, and returns the error, with the status as its code: 413 and 431 are limits.
def refuse[T](socket: TCP.Socket, status: Int, reason: String, deadline: Int) -> Result[T]
  linger(socket, HttpWire.error_answer(status), deadline)
  return error("http: #{reason}", kind: "http.too_large", code: status) if status == 413 or status == 431

  error("http: #{reason}", kind: "http.protocol", code: status)
end

# Sends text, closes the write side, and reads and drops input until the peer closes, deadline, or DRAIN_BYTES bytes,
# so unread request bytes cannot turn the close into a reset that loses the answer. Then it closes the socket. The
# answer gets at least ANSWER_MS even when the deadline has passed; only the drain is bound by the deadline and the
# byte limit.
def linger(socket: TCP.Socket, text: String, deadline: Int) -> Void
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

def drain(socket: TCP.Socket, deadline: Int) -> Void
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
            return if data.empty?
            rest = rest - data.size
          error(_) -> return
        end
      error(_) -> return
    end
  end
end

# Sends a whole response; true when the connection stays. A response that cannot be sent gets a 500 and a close.
def reply_whole(socket: TCP.Socket, request: HttpWire.Request, response: HttpWire.Response, timeout: Int) -> Bool
  case write_response(socket, request, response, timeout)
    ok(keep) -> return keep
    error(message) ->
      if "#{message}".start_with?("http: invalid response: ")
        IO.warn("#{message}")
        failed(socket, request, timeout)
      end
  end
  false
end

# A streamed response. A body that is already closed is the whole body, which goes out with Content-Length as for a
# whole response. Otherwise the head goes now, with chunked framing (or with the Content-Length of `length` and no
# framing), and each piece follows as it arrives.
def answer_stream(
  socket: TCP.Socket,
  incoming: Incoming,
  response: StreamResponse,
  options: HttpWire.ServerOptions,
) -> Sent
  request = incoming.request
  timeout = options.request_timeout_ms
  ready = take_ready(response.body)
  length = response.length.unwrap_or(UNSIZED)
  bodyless = response.status == 204 or response.status == 304
  data = NO_BYTES
  if ready.ended
    data = Bytes.concat(ready.pieces)
  end
  # A closed body gives the head its Content-Length here; a 204 or 304 with one is refused below.
  sized = data
  if bodyless
    sized = NO_BYTES
  end

  encoded = HttpWire.Response(status: response.status, headers: response.headers, body: sized)
  case HttpWire.encode_response(request, encoded, Time.now_ms())
    ok(reply) ->
      problem = length_problem(response, ready.ended, data.size, bodyless)
      return invalid_stream(socket, request, response.body, problem, timeout) if not problem.empty?
      if ready.ended
        return invalid_stream(socket, request, response.body, NO_BODY, timeout) if bodyless and not data.empty?
        return send_whole(socket, incoming, reply, data, timeout)
      end
      return invalid_stream(socket, request, response.body, NO_BODY, timeout) if bodyless
      if length == 0
        # Nothing to stream: it goes out like an empty closed body, so that there is no gap between the head (which the
        # client has complete) and the end of the stream, where its next request could be taken for stream bytes.
        response.body.close
        if Bytes.concat(ready.pieces).size > 0
          return invalid_stream(socket, request, response.body, WRONG_SIZE, timeout)
        end
        return send_whole(socket, incoming, reply, NO_BYTES, timeout)
      end
      case stream_head(reply.head, length)
        ok(head) ->
          framed = HttpWire.Reply(head: head, closes: reply.closes)
          stream_out(socket, incoming, response.body, ready.pieces, framed, length, options)
        error(_) -> invalid_stream(socket, request, response.body, HEAD_TOO_LARGE, timeout)
      end
    error(reason) -> invalid_stream(socket, request, response.body, "#{reason}", timeout)
  end
end

# Why the length of a streamed response cannot be used, or "" when it can (or there is none). A body that is closed
# already is sent whole, so its size must be the length: nothing has gone out, so the answer can still be a 500.
def length_problem(response: StreamResponse, ended: Bool, size: Int, bodyless: Bool) -> String
  case response.length
    some(length) ->
      return "the length of a streamed body cannot be negative" if length < 0
      return NO_BODY if bodyless
      return WRONG_SIZE if ended and size != length
      ""
    none -> ""
  end
end

# A body that was complete when the handler returned, with its Content-Length in the encoded head (a 204 or 304 head
# has no length and no body). A HEAD request gets the head alone.
def send_whole(socket: TCP.Socket, incoming: Incoming, reply: HttpWire.Reply, data: Bytes, timeout: Int) -> Sent
  deadline = Time.monotonic_ms() + timeout
  head = reply.head
  sent = ok()
  if incoming.request.method == "HEAD" or data.empty?
    sent = TCP.send_bytes(socket, head_bytes(head), timeout)
  else
    sent = send_all(socket, head_bytes(head) + data, timeout)
  end
  return Sent(keep: false, rest: NO_BYTES) if not Result.ok?(sent)
  if reply.closes
    linger(socket, "", deadline)
    return Sent(keep: false, rest: NO_BYTES)
  end
  Sent(keep: true, rest: incoming.rest)
end

# Sends bytes in the pieces TCP.send_bytes takes. The whole send has `timeout`, not each piece.
def send_all(socket: TCP.Socket, data: Bytes, timeout: Int) -> Result[Void]
  deadline = Time.monotonic_ms() + timeout
  at = 0
  while at < data.size
    count = smaller(SEND_BYTES, data.size - at)
    try TCP.send_bytes(socket, data.slice(at, count), try time_left(socket, deadline))
    at = at + count
  end
  ok()
end

def invalid_stream(
  socket: TCP.Socket,
  request: HttpWire.Request,
  body: Channel[Bytes],
  reason: String,
  timeout: Int,
) -> Sent
  IO.warn("http: invalid response: #{reason}")
  body.close
  failed(socket, request, timeout)
  Sent(keep: false, rest: NO_BYTES)
end

# What the body channel holds without waiting. It has ended when the receive fails because the channel is closed and
# empty, which the receive itself says, so a producer that sends and closes meanwhile loses nothing. A close with a
# reason is not an end: the stream starts, and pump cuts it.
def take_ready(body: Channel[Bytes]) -> Ready
  pieces: List[Bytes] = []
  ended = false
  more = true
  while more
    case body.recv(0)
      ok(piece) -> pieces = List.append(pieces, piece)
      error(e) ->
        ended = e.kind == "channel.closed"
        more = false
    end
  end
  Ready(pieces: pieces, ended: ended)
end

# The bytes of an encoded head. The head is a String of characters up to U+00FF (a header value is Latin-1), so each
# character is one byte on the wire and a value with `é` goes out as the single byte 0xE9, as HTTP/1.1 allows.
# `unwrap!` cannot fail: encode_request and encode_response refuse any header value above U+00FF, and the rest of
# the head (method, target, host, status line, names) is ASCII.
def head_bytes(head: String) -> Bytes = head.encode("latin-1").unwrap!

# The encoded head says Content-Length: 0 (the body there is empty): a stream with no known length says chunked, and
# one with a length says it. The new line can be longer, so the block is measured again, by the rule of scan_head in
# vm/http_pico.c: every byte after the start line, the empty line included, at most 65536 (AGC_HTTP_MAX_BLOCK).
def stream_head(head: String, length: Int) -> Result[String]
  framing = "Transfer-Encoding: chunked"
  if length != UNSIZED
    framing = "Content-Length: #{length}"
  end

  framed = String.replace(head, "\r\nContent-Length: 0\r\n", "\r\n#{framing}\r\n")
  block = framed.length - framed.index_of("\r\n").unwrap_or(0) - 2
  return error("http: #{HEAD_TOO_LARGE}", kind: "http.too_large", code: 431) if block > 65536
  ok(framed)
end

# Sends the head and then the body, as chunks or (with a `length`) as it is. A HEAD request gets the head and the
# channel closes, so the producer stops. A task watches the socket for the whole stream, so a client that leaves is
# noticed even when the producer is idle: the end of its input closes the body, and the body is then cut, without the
# last chunk, so the client sees an incomplete body. Bytes the client sends during the stream (a pipelined request)
# are dropped, and the connection closes when the stream ends. Otherwise the watcher's read is the wait for the next
# request.
def stream_out(
  socket: TCP.Socket,
  incoming: Incoming,
  body: Channel[Bytes],
  first: List[Bytes],
  reply: HttpWire.Reply,
  length: Int,
  options: HttpWire.ServerOptions,
) -> Sent
  timeout = options.request_timeout_ms
  if not Result.ok?(TCP.send_bytes(socket, head_bytes(reply.head), timeout))
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
  ended = pump(socket, body, first, length, left, sent, timeout)
  if ended == STREAM_CUT
    TCP.close(socket)
    return Sent(keep: false, rest: NO_BYTES)
  end
  return end_stream(socket, watcher, timeout) if reply.closes or not incoming.rest.empty? or ended == STREAM_EARLY
  next_request(socket, watcher, options.idle_timeout_ms)
end

# The connection closes after the stream, as linger does: the write side first, then the peer gets the rest of the time
# to close its side, so a reset cannot lose the last chunk.
def end_stream(socket: TCP.Socket, watcher: Task[Result[Bytes]], timeout: Int) -> Sent
  HttpWire.close_write(socket)
  case Task.await(watcher, timeout)
    Await.Done(_) -> drain(socket, Time.monotonic_ms() + timeout)
    Await.TimedOut -> TCP.close(socket)
  end
  TCP.close(socket)
  Sent(keep: false, rest: NO_BYTES)
end

# After a HEAD response: false when the connection closes.
def end_head(socket: TCP.Socket, reply: HttpWire.Reply, timeout: Int) -> Bool
  if reply.closes
    linger(socket, "", Time.monotonic_ms() + timeout)
    return false
  end
  true
end

# The stream ended and the client is still there: the watcher's read is the first byte of its next request.
def next_request(socket: TCP.Socket, watcher: Task[Result[Bytes]], idle_ms: Int) -> Sent
  case Task.await(watcher, idle_ms)
    Await.Done(read) ->
      case read
        ok(data) -> return Sent(keep: true, rest: data) if not data.empty?
        error(_) -> TCP.close(socket)
      end
    Await.TimedOut -> TCP.close(socket)
  end
  Sent(keep: false, rest: NO_BYTES)
end

# What the watcher has seen so far: STREAM_CUT when the client left, STREAM_EARLY when it sent bytes, else STREAM_DONE.
# It is read before the last byte of the body goes out (the last chunk, or the last byte of a body with a length),
# because after it the client may send its next request, which the watcher would then take for bytes of the stream.
def watched(left: Channel[Bool], sent: Channel[Bool]) -> Int
  return STREAM_CUT if Result.ok?(left.recv(0))
  return STREAM_EARLY if Result.ok?(sent.recv(0))
  STREAM_DONE
end

# Sends the pieces as they come, then the last chunk (a body with a length has none). The wait for a piece has no
# deadline of its own: a slow producer is not an error, and the client leaving, the producer closing or the server
# closing all wake it. A piece gets `timeout` to be sent, so a client that stops reading cuts the stream. STREAM_CUT
# when the body was cut: a send failed (the channel is closed for the producer), the watcher saw the client leave
# (left has a value), the producer closed with a reason, or a body with a length ended short or a piece would pass
# it. Only a producer's close ends the body, or its length when it has one. STREAM_EARLY when the client sent bytes
# during the stream (sent has a value, read before the last chunk or the last byte of a body with a length goes out:
# after it the client may send its next request), STREAM_DONE otherwise.
def pump(
  socket: TCP.Socket,
  body: Channel[Bytes],
  first: List[Bytes],
  length: Int,
  left: Channel[Bool],
  sent: Channel[Bool],
  timeout: Int,
) -> Int
  count = 0
  early = STREAM_DONE
  for piece in packed(first, length)
    if length != UNSIZED and count + piece.size == length
      # Closed before the watcher is read and before the last byte goes out: a request that the watcher reads after
      # the close is the next request, not a dropped pipelined one (it tells them apart by `body.closed?`), and one
      # that it read before is seen in `sent`.
      body.close
      early = watched(left, sent)
      return STREAM_CUT if early == STREAM_CUT
    end
    case emit(socket, piece, timeout, length, count)
      ok(total) -> count = total
      error(_) ->
        body.close
        return STREAM_CUT
    end
    if length != UNSIZED and count == length
      # A piece that was already queued after the one that fills the length is not read.
      break
    end
  end
  while true
    if length != UNSIZED and count == length
      # The client has the whole body and may already send its next request, so the stream ends now and does not wait
      # for the producer to close the channel (closed above, before the last byte went out: the producer's next `send`
      # fails, and a piece that it sent after the length is not read).
      break
    end
    case body.recv(STREAM_POLL_MS)
      ok(piece) ->
        if length != UNSIZED and count + piece.size == length
          body.close
          early = watched(left, sent)
          return STREAM_CUT if early == STREAM_CUT
        end
        case emit(socket, with_queued(body, piece, length), timeout, length, count)
          ok(total) -> count = total
          error(_) ->
            body.close
            return STREAM_CUT
        end
      error(e) ->
        break if e.kind == "channel.closed"
        # A close with a reason cuts the body; a timeout waits again.
        return STREAM_CUT if e.kind != "channel.timeout"
    end
  end
  return STREAM_CUT if length != UNSIZED and count != length
  if length == UNSIZED
    early = watched(left, sent)
    return STREAM_CUT if early == STREAM_CUT or not Result.ok?(TCP.send(socket, "0\r\n\r\n", timeout))
  end
  early
end

# A piece of a chunked body (a stream or an upload) with the pieces that already wait behind it in `body`: one chunk,
# one send. It never waits. A body with a length is not joined: its pieces are counted one by one against the length.
def with_queued(body: Channel[Bytes], piece: Bytes, length: Int) -> Bytes
  return piece if length != UNSIZED

  pieces = [piece]
  size = piece.size
  while size < STREAM_JOIN_BYTES
    case body.recv(0)
      ok(next) ->
        if not next.empty?
          pieces = List.append(pieces, next)
          size = size + next.size
        end
      error(_) -> break
    end
  end
  return piece if pieces.size == 1

  Bytes.concat(pieces)
end

def packed(pieces: List[Bytes], length: Int) -> List[Bytes]
  return pieces if length != UNSIZED or pieces.size < 2

  groups: List[Bytes] = []
  group: List[Bytes] = []
  size = 0
  for piece in pieces
    group = List.append(group, piece)
    size = size + piece.size
    if size >= STREAM_JOIN_BYTES
      groups = List.append(groups, Bytes.concat(group))
      group = []
      size = 0
    end
  end
  return groups if group.empty?

  List.append(groups, Bytes.concat(group))
end

# Sends one piece and gives the bytes sent so far: as chunks, or with a `length`, as they are and only while they fit
# in it (a piece that would pass it is not sent: an error, so the body is cut).
def emit(socket: TCP.Socket, piece: Bytes, timeout: Int, length: Int, count: Int) -> Result[Int]
  if length == UNSIZED
    try send_piece(socket, piece, timeout)
    return ok(count)
  end
  return error("longer than its length", kind: "argument") if count + piece.size > length
  try send_all(socket, piece, timeout)
  ok(count + piece.size)
end

# The piece as chunks: the size in hex, the bytes and the CRLFs, in one send so a chunk is one flush. A piece over
# CHUNK_BYTES is several chunks, all within `timeout`. An empty piece would read as the last chunk, so it sends
# nothing. The bytes go as they are: no UTF-8 check runs on a piece.
def send_piece(socket: TCP.Socket, piece: Bytes, timeout: Int) -> Result[Void]
  deadline = Time.monotonic_ms() + timeout
  at = 0
  while at < piece.size
    count = smaller(CHUNK_BYTES, piece.size - at)
    part = piece.slice(at, count)
    chunk = Bytes.concat(["#{hex_of(count)}\r\n".bytes, part, CRLF])
    try TCP.send_bytes(socket, chunk, try time_left(socket, deadline))
    at = at + count
  end
  ok()
end

def hex_of(number: Int) -> String
  digits = ""
  rest = number
  while rest > 0
    digits = String.slice(HEX_DIGITS, rest % 16, 1) + digits
    rest = rest / 16
  end
  digits
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
          _ = watching.left.send(true, 0)
          watching.body.close
          return ok(data)
        end
        # Set before the test: a pump that ends the stream in between must see these bytes as early, not as a request.
        _ = watching.sent.send(true, 0)
        return ok(data) if watching.body.closed?
      error(message) ->
        _ = watching.left.send(true, 0)
        watching.body.close
        return error(message)
    end
  end
  ok(NO_BYTES)
end

# Writes one whole response with Content-Length. ok(false) when the request or the response asked to close: the
# connection then closes as in linger.
def write_response(
  socket: TCP.Socket,
  request: HttpWire.Request,
  response: HttpWire.Response,
  timeout: Int,
) -> Result[Bool]
  case HttpWire.encode_response(request, response, Time.now_ms())
    ok(reply) -> send_response(socket, request, response, reply, timeout)
    error(reason) -> error(reason.with(message: "http: invalid response: #{reason.message}"))
  end
end

def send_response(
  socket: TCP.Socket,
  request: HttpWire.Request,
  response: HttpWire.Response,
  reply: HttpWire.Reply,
  timeout: Int,
) -> Result[Bool]
  deadline = Time.monotonic_ms() + timeout
  body = response.body
  if request.method == "HEAD"
    body = NO_BYTES
  end
  if body.size <= SMALL_BODY
    try send_all(socket, head_bytes(reply.head) + body, timeout)
  else
    try TCP.send_bytes(socket, head_bytes(reply.head), timeout)
    try send_all(socket, body, try time_left(socket, deadline))
  end
  if reply.closes
    linger(socket, "", deadline)
    return ok(false)
  end
  ok(true)
end

def failed(socket: TCP.Socket, request: HttpWire.Request, timeout: Int) -> Void
  _ = write_response(
    socket,
    request,
    HttpWire.Response(status: 500, headers: [HttpWire.Header(name: "Connection", value: "close")], body: NO_BYTES),
    timeout,
  )
end

# One download connection: on a new socket, which closes when the download ends. It is made as the one of `start` is,
# within what is left of the download's time.
def connect_download(options: HttpWire.ClientOptions, where: Target, deadline: Int) -> Result[TCP.Socket]
  left = deadline - Time.monotonic_ms()
  return error(TIMED_OUT, kind: "net.timeout") if left <= 0
  at_connect(open_socket(where, options.with(timeout_ms: left)))
end

# Opens a new temp file next to `path`, then streams the response into it. The file goes away when its handle closes
# unless it was moved to `path` first, so every error below, a cancel and a timeout of the task included, leaves no
# file; `path` is only touched by the rename after a clean end.
def finish_download(
  socket: TCP.Socket,
  path: String,
  options: DownloadOptions,
  deadline: Int,
  denied: String,
  step: Int,
) -> Result[Download]
  temp = part_path(path)
  case time_left(socket, deadline)
    ok(left) ->
      case File.open(temp, "temp", left)
        ok(out) -> stream_download(socket, Saving(out: out, temp: temp, path: path), options, deadline, denied, step)
        error(message) ->
          TCP.close(socket)
          error(message)
      end
    error(message) ->
      TCP.close(socket)
      error(message)
  end
end

# The response head (after at most MAX_INTERIM interim ones) streamed into the file, which then takes `path`.
def stream_download(
  socket: TCP.Socket,
  saving: Saving,
  options: DownloadOptions,
  deadline: Int,
  denied: String,
  step: Int,
) -> Result[Download]
  budget = options.max_total_bytes.unwrap_or(NO_BODY_LIMIT)
  case download_head(socket, budget, smaller(deadline, after(step)))
    ok(head) ->
      return fail_download(socket, saving, denied_error(denied)) if head.status == 407 and denied != ""

      case save_body(socket, saving.out, head, budget, deadline, step)
        ok(written) ->
          case settle(saving, options.sha256, deadline)
            ok(_) ->
              TCP.close(socket)
              _ = File.close(saving.out, CLEANUP_MS)
              ok(Download(status: head.status, headers: head.headers, bytes_written: written))
            error(message) -> fail_download(socket, saving, error(message))
          end
        error(message) -> fail_download(socket, saving, error(message))
      end
    error(message) -> fail_download(socket, saving, error(message))
  end
end

# Closes both handles after a failure and reports it. The close removes the new file, with a time of its own since the
# call's deadline may be what failed; a Path.replace that timed out may still finish in the pool, and then the new name
# is gone and the close removes nothing.
def fail_download(socket: TCP.Socket, saving: Saving, failed: Result[Download]) -> Result[Download]
  _ = File.close(saving.out, CLEANUP_MS)
  TCP.close(socket)
  failed
end

# The finished file written out and checked against the digest, then renamed over `path` in one step while its handle
# is still open, so `path` always names the old file or the new one.
def settle(saving: Saving, sha256: Optional[String], deadline: Int) -> Result[Void]
  try File.flush(saving.out, try file_left(deadline))
  try check_digest(saving.temp, sha256, deadline)
  Path.replace(saving.temp, saving.path, try file_left(deadline))
end

# The hidden name a download grows under, in the folder of `path`: `.<name>.<8 hex digits>.agc-part`, with at most
# PART_NAME characters of the name, so it stays short whatever `path` is.
def part_path(path: String) -> String
  name = last_part(last_part(path, "/"), "\\")
  folder = path.slice(0, path.length - name.length)
  "#{folder}.#{name.slice(0, smaller(name.length, PART_NAME))}.#{OpenSSL.Random.hex(4)}.agc-part"
end

# What follows the last `separator` in `text`, or all of it when there is none.
def last_part(text: String, separator: String) -> String
  return "" if text.end_with?(separator)
  text.split(separator).last
end

def check_digest(temp: String, sha256: Optional[String], deadline: Int) -> Result[Void]
  case sha256
    some(hex) ->
      return ok() if try File.sha256(temp, try file_left(deadline)) == try OpenSSL.Digest.hexdecode(hex)
      error(DIGEST_MISMATCH, kind: "http.digest")
    none -> ok()
  end
end

# Whether a download may end at `path`: nothing is there yet, or a file or a link that it replaces. It is checked
# before the connect, so a directory fails at once; Path.replace refuses one that appears later.
def replaceable(path: String, deadline: Int) -> Result[Void]
  case File.lstat(path, try file_left(deadline))
    ok(info) ->
      return ok() if info.kind == "file" or info.kind == "link"
      error("http: the download path is a #{info.kind}, not a file", kind: "argument")
    error(_) -> ok()
  end
end

def file_left(deadline: Int) -> Result[Int]
  left = deadline - Time.monotonic_ms()
  return error(TIMED_OUT, kind: "net.timeout") if left <= 0
  ok(left)
end

# The response head of a download, with the download budget as the body limit.
def download_head(socket: TCP.Socket, budget: Int, deadline: Int) -> Result[HttpWire.ResponseHead]
  read_head_of(socket, false, budget, deadline)
end

# The head of the final response (after at most MAX_INTERIM interim ones), with the framing of a response to HEAD when
# `head_only`, and `budget` as the largest body the head may announce.
def read_head_of(socket: TCP.Socket, head_only: Bool, budget: Int, deadline: Int) -> Result[HttpWire.ResponseHead]
  interim = 0
  while true
    case time_left(socket, deadline)
      ok(left) ->
        case HttpWire.read_response(socket, head_only, budget, left)
          ok(head) ->
            return ok(head) if head.status >= 200
            interim = interim + 1
            return error("http: too many interim responses", kind: "http.protocol") if interim > MAX_INTERIM
          error(message) ->
            return error(CUT_SHORT, kind: "http.closed") if interim > 0 and "#{message}" == END_OF_INPUT
            return error(message)
        end
      error(message) -> return error(message)
    end
  end
  error(TIMED_OUT, kind: "net.timeout")
end

# Streams the body framing of head into the file and counts its bytes.
def save_body(
  socket: TCP.Socket,
  out: File.Handle,
  head: HttpWire.ResponseHead,
  budget: Int,
  deadline: Int,
  step: Int,
) -> Result[Int]
  return save_chunked(socket, out, budget, deadline, step) if head.chunked
  return save_until_close(socket, out, budget, deadline, step) if head.until_close
  save_length(socket, out, head.length, budget, deadline, step)
end

# The next body bytes, at most most of them; no bytes means the peer closed the input.
def recv_body(socket: TCP.Socket, most: Int, deadline: Int) -> Result[Bytes]
  TCP.recv_bytes(socket, most, try time_left(socket, deadline))
end

# The same, waiting at most `step` for the bytes (`read_timeout_ms`): a body that goes quiet ends the call early.
def recv_step(socket: TCP.Socket, most: Int, deadline: Int, step: Int) -> Result[Bytes]
  TCP.recv_bytes(socket, most, smaller(try time_left(socket, deadline), step))
end

# Appends data to the download within the whole-call deadline.
def write_body(out: File.Handle, data: Bytes, deadline: Int) -> Result[Void]
  left = deadline - Time.monotonic_ms()
  return error(TIMED_OUT, kind: "net.timeout") if left <= 0
  File.write_bytes(out, data, left)
end

# Appends data without letting the file grow past the budget: writes what fits, then reports TOO_LARGE.
def write_bounded(out: File.Handle, data: Bytes, written: Int, budget: Int, deadline: Int) -> Result[Int]
  room = budget - written
  if data.size > room
    if room > 0
      try write_body(out, data.take(room), deadline)
    end
    return error(TOO_LARGE, kind: "http.too_large", code: 413)
  end
  try write_body(out, data, deadline)
  ok(written + data.size)
end

# A Content-Length body: the head already refused one over the budget, so the count only follows it.
def save_length(
  socket: TCP.Socket,
  out: File.Handle,
  length: Int,
  budget: Int,
  deadline: Int,
  step: Int,
) -> Result[Int]
  left = length
  written = 0
  while left > 0
    data = try recv_step(socket, smaller(left, BODY_READ_BYTES), deadline, step)
    return error(TRUNCATED, kind: "http.protocol") if data.empty?
    written = try write_bounded(out, data, written, budget, deadline)
    left = left - data.size
  end
  ok(written)
end

# A chunked body: framing goes through the decoder, whose runs say which bytes of each read are body.
def save_chunked(socket: TCP.Socket, out: File.Handle, budget: Int, deadline: Int, step: Int) -> Result[Int]
  data = NO_BYTES
  state = HttpWire.chunked(budget)
  written = 0
  while not state.done
    if state.remaining > 0
      data = try recv_step(socket, smaller(state.remaining, BODY_READ_BYTES), deadline, step)
      return error(TRUNCATED, kind: "http.protocol") if data.empty?
      written = try write_bounded(out, data, written, budget, deadline)
      state = HttpWire.chunk_read(state, data.size)
    else
      data = try recv_step(socket, FRAME_BYTES, deadline, step)
      return error(TRUNCATED, kind: "http.protocol") if data.empty?
      case HttpWire.chunk(state, data, 0)
        ok(next) -> state = next
        error(problem) -> return error(problem.with(message: "http: #{rest_of(problem.message, 4)}"))
      end
      written = try write_runs(out, data, state.runs, written, budget, deadline)
    end
  end
  ok(written)
end

# Appends the runs of data (start, length pairs) to the download.
def write_runs(out: File.Handle, data: Bytes, runs: List[Int], written: Int, budget: Int, deadline: Int) -> Result[Int]
  at = 0
  while at < List.size(runs)
    piece = data.slice(List.at(runs, at), List.at(runs, at + 1))
    written = try write_bounded(out, piece, written, budget, deadline)
    at = at + 2
  end
  ok(written)
end

# A body that ends with the connection: over TLS the end must be the peer's close_notify.
def save_until_close(socket: TCP.Socket, out: File.Handle, budget: Int, deadline: Int, step: Int) -> Result[Int]
  written = 0
  while true
    data = try recv_step(socket, BODY_READ_BYTES, deadline, step)
    if data.empty?
      return error(TRUNCATED, kind: "http.protocol") if not HttpWire.clean_eof?(socket)
      return ok(written)
    end
    written = try write_bounded(out, data, written, budget, deadline)
  end
  error(TRUNCATED, kind: "http.protocol")
end

def larger(a: Int, b: Int) -> Int
  return a if a > b
  b
end
