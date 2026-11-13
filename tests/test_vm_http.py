"""The VM HTTP client and server against independent peers.

The client runs against fixtures/http-peer.py (ThreadingHTTPServer, a Python
ssl server and raw hostile sockets). The server runs against Python raw
sockets and http.client (fixtures/http-server-peer.py) and Node http clients
(fixtures/http-server-peer.js). Everything is on 127.0.0.1 with port 0; the
certificates are the ones in fixtures/tls.

The servers run on the module's scheduler count (tests/agentica_test.py,
TEST_SCHEDULERS): one per logical core in `make test` (CI checks that the
runner has four or more), one in `make test-shared` and four in
`make vm-tsan-run`.
"""
import http.client
import json
import os
import socket
import ssl
import threading
import time

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, WINDOWS, Child, check_lines, compile_agc, compile_text, optional_tool,
                                 output_lines, run, run_vm, scaled, start_vm, vm_environment)
from tests.test_vm_tcp import ipv6_localhost

PEER = FIXTURES / "http-peer.py"
SERVER_PEER = FIXTURES / "http-server-peer.py"
SERVER_NODE_PEER = FIXTURES / "http-server-peer.js"
STREAM_PEER = FIXTURES / "http-stream-peer.py"
CERTS = FIXTURES / "tls"

PRELUDE = """\
import HTTP from "std/http"

struct Fetch
  pool: HTTP.Client
  url: String
end

struct Producer
  pieces: List[Bytes]
  into: Channel[Bytes]
  close: Bool
end

def options(timeout: Int, connections: Int, body: Int, ca: String) -> HTTP.ClientOptions
  return HTTP.ClientOptions(timeout_ms: timeout, idle_timeout_ms: 5000, max_connections: connections, max_body_bytes: body, tls: some(TLS.client_context(TLS.ClientOptions(ca_file: ca)).unwrap!))
end

# A body as text; one that is not UTF-8 says so, since these shows print text.
def decoded(body: Bytes) -> String
  return Result.unwrap_or(String.from_bytes(body), "<not UTF-8>")
end

def short(body: Bytes) -> String
  text = decoded(body)
  if String.length(text) > 20
    return String.slice(text, 0, 20)
  end
  return text
end

def show(r: Result[HTTP.Response]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{short(response.body)} #{String.length(decoded(response.body))}")
    error(e) -> puts(String.replace(e.message, "\\n", " | "))
  end
end

def fetch(f: Fetch) -> Result[String]
  response = try HTTP.get(f.pool, f.url)
  return HTTP.text(response.body, response.headers)
end

def same(a: Task[Result[String]], b: Task[Result[String]], c: Task[Result[String]]) -> Bool
  x = Result.unwrap!(Task.await(a))
  y = Result.unwrap!(Task.await(b))
  z = Result.unwrap!(Task.await(c))
  return x == y and y == z
end

def apart(a: Task[Result[String]], b: Task[Result[String]], c: Task[Result[String]]) -> Bool
  x = Result.unwrap!(Task.await(a))
  y = Result.unwrap!(Task.await(b))
  z = Result.unwrap!(Task.await(c))
  return x != y and y != z and x != z
end


"""

PLAIN_PROGRAM = """\
def main() -> Void
  plain = "http://127.0.0.1:#{System.args()[1]}"
  pool = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  hello = Result.unwrap!(HTTP.get(pool, plain + "/hello"))
  puts("#{hello.status} #{decoded(hello.body)} #{HTTP.header_values(hello.headers, "X-MULTI")}")
  show(HTTP.get(pool, plain + "/chunked"))
  binary = Result.unwrap!(HTTP.get(pool, plain + "/binary"))
  puts("#{binary.status} #{binary.body.size} #{binary.body[0]} #{binary.body[2]} #{HTTP.text(binary.body, binary.headers).ok?}")
  chunked = Result.unwrap!(HTTP.get(pool, plain + "/binary-chunked"))
  puts("#{chunked.body.size} #{chunked.body.to_a}")
  show(HTTP.post(pool, plain + "/echo", Bytes.from_list([255, 0, 128, 13, 10]).unwrap!))
  latin = Result.unwrap!(HTTP.get(pool, plain + "/latin1"))
  puts("#{latin.body.size} #{latin.body[3]} #{HTTP.text(latin.body, latin.headers).ok?}")
  first = Result.unwrap!(HTTP.get(pool, plain + "/port")).body
  show(HTTP.post(pool, plain + "/post", "a=1&b=ñ".bytes, [HTTP.Header(name: "X-Kind", value: "form")]))
  puts(Result.unwrap!(HTTP.get(pool, plain + "/port")).body == first)
  show(HTTP.get(pool, plain + "/close"))
  puts(Result.unwrap!(HTTP.get(pool, plain + "/port")).body != first)
  show(HTTP.get(pool, plain + "/nothing"))
  show(HTTP.post(pool, plain + "/post", "".bytes))
  show(HTTP.request(pool, "DELETE", plain + "/item", "".bytes))
  HTTP.close_client(pool)
  show(HTTP.get_response(plain + "/chunked"))
  show(HTTP.post_response(plain + "/post", "a=1&b=ñ".bytes, [HTTP.Header(name: "X-Kind", value: "form")]))
  show(HTTP.get_response(plain + "/slow", HTTP.ClientOptions(timeout_ms: 200)))
  show(HTTP.get_response("ftp://127.0.0.1/"))
  show(HTTP.get_response(plain + "/nothing", HTTP.ClientOptions(max_body_bytes: 0)))
  puts(Task.pending_count())
  slow = Result.unwrap!(HTTP.client(options(200, 1, 1000, "")))
  show(HTTP.get(slow, plain + "/slow"))
  one = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  a = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  b = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  c = Task.spawn(&fetch, Fetch(pool: one, url: plain + "/port"))
  puts(same(a, b, c))
  three = Result.unwrap!(HTTP.client(options(5000, 3, 1000, "")))
  a = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  b = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  c = Task.spawn(&fetch, Fetch(pool: three, url: plain + "/gate"))
  puts(apart(a, b, c))
  closing = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  pending = Task.spawn(&fetch, Fetch(pool: closing, url: plain + "/hold"))
  watcher = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  while Result.unwrap!(HTTP.get(watcher, plain + "/held")).body == "0".bytes
    Task.sleep(1)
  end
  HTTP.close_client(closing)
  IO.inspect(Task.await(pending))
end
"""

TLS_PROGRAM = """\
def main() -> Void
  certs = System.args()[0]
  port = System.args()[2]
  # The deadline of each call, scaled: a TLS handshake with the Python server can take seconds on a loaded runner.
  limit = System.args()[4].to_i!
  secure = Result.unwrap!(HTTP.client(options(limit, 1, 1000, certs + "/ca.pem")))
  show(HTTP.get(secure, "https://localhost:#{port}/hello"))
  show(HTTP.get(secure, "https://LOCALHOST:#{port}/hello"))
  show(HTTP.post(secure, "https://127.0.0.1:#{port}/post", "over tls".bytes))
  show(HTTP.get(secure, "https://localhost:#{port}/notify"))
  show(HTTP.get(secure, "https://localhost:#{port}/close"))
  show(HTTP.get(secure, "http://localhost:#{port}/hello"))
  show(HTTP.get(Result.unwrap!(HTTP.client(options(limit, 1, 1000, certs + "/self-signed.pem"))), "https://localhost:#{port}/hello"))
  # A context reads its CA file when it is built, so a missing one fails there, before any client.
  puts(TLS.client_context(TLS.ClientOptions(ca_file: certs + "/missing.pem")).message.split("\\n")[0])
end
"""

# `HTTP.start`: one connection driven by the program, against the Python threading server. `drain` reads a body in pieces
# of at most `most` bytes and shows the text with the count of pieces (the end is an empty piece).
CONNECTION_PROGRAM = """\
def drain(conn: HTTP.Connection, most: Int) -> String
  all: List[Bytes] = []
  while true
    case HTTP.read_body(conn, most)
      ok(piece) ->
        if piece.empty?
          return "#{decoded(Bytes.concat(all))} in #{all.size}"
        end
        all = all.push(piece)
      error(message) -> return "error: #{message}"
    end
  end
  return "unreachable"
end

def why(started: Result[HTTP.Connection]) -> String
  case started
    ok(conn) ->
      HTTP.finish(conn)
      return "started"
    error(e) -> return e.message
  end
end

def answer(conn: HTTP.Connection, method: String, target: String, body: String, most: Int) -> String
  case HTTP.send_request(conn, method, target, body.bytes, [HTTP.Header(name: "X-Kind", value: "conn")])
    ok(head) -> return "#{head.status} #{drain(conn, most)}"
    error(message) -> return "error: #{message}"
  end
end

def main() -> Void
  origin = "http://127.0.0.1:#{System.args()[1]}"
  conn = Result.unwrap!(HTTP.start(origin, options(5000, 1, 1000, "")))
  head = Result.unwrap!(HTTP.send_request(conn, "GET", "/hello", "".bytes))
  puts("#{head.status} #{HTTP.header_values(head.headers, "x-multi")} #{drain(conn, 4)}")
  first = answer(conn, "GET", "/port", "", 1000)
  puts(first == answer(conn, "GET", "/port", "", 1000))
  puts(answer(conn, "GET", "/chunked", "", 5))
  puts(first == answer(conn, "GET", "/port", "", 1000))
  puts(answer(conn, "POST", "/post", "a=1&b=ñ", 1000))
  puts(answer(conn, "HEAD", "/hello", "", 1000))
  puts(first == answer(conn, "GET", "/port", "", 1000))
  Result.unwrap!(HTTP.send_request(conn, "HEAD", "/hello", "".bytes))
  puts(first == answer(conn, "GET", "/port", "", 1000))
  binary = Result.unwrap!(HTTP.send_request(conn, "GET", "/binary", "".bytes))
  one = Result.unwrap!(HTTP.read_body(conn, 2))
  two = Result.unwrap!(HTTP.read_body(conn, 2))
  puts("#{binary.status} #{one.to_a} #{two.to_a} #{Result.unwrap!(HTTP.read_body(conn)).size}")
  puts(first == answer(conn, "GET", "/port", "", 1000))
  Result.unwrap!(HTTP.send_request(conn, "GET", "/hello", "".bytes))
  puts(answer(conn, "GET", "/port", "", 1000))
  puts(drain(conn, 1000))
  puts(answer(conn, "GET", "/port", "", 1000) == first)
  puts(HTTP.read_body(conn, 0))
  puts(answer(conn, "GET", "/close", "", 4))
  puts(answer(conn, "GET", "/hello", "", 4))
  HTTP.finish(conn)
  HTTP.finish(conn)
  puts(HTTP.read_body(conn))
  puts(HTTP.send_request(conn, "GET", "/hello", "".bytes))
  puts(why(HTTP.start(origin + "/path", options(5000, 1, 1000, ""))))
  puts(why(HTTP.start("ftp://127.0.0.1", options(5000, 1, 1000, ""))))
  small = Result.unwrap!(HTTP.start(origin, options(5000, 1, 4, "")))
  puts(answer(small, "POST", "/post", "12345", 1000))
  puts(answer(small, "BAD METHOD", "/hello", "", 1000))
  puts(answer(small, "GET", "/hello", "", 1000))
  HTTP.finish(small)
  slow = Result.unwrap!(HTTP.start(origin, options(300, 1, 1000, "")))
  puts(answer(slow, "GET", "/slow", "", 1000))
  puts(answer(slow, "GET", "/hello", "", 1000))
  puts(Task.pending_count())
end
"""

CONNECTION_RAW_PROGRAM = """\
def drain(conn: HTTP.Connection) -> String
  text = ""
  while true
    case HTTP.read_body(conn, 1000)
      ok(piece) ->
        if piece.empty?
          return "#{text.size} bytes"
        end
        text = text + decoded(piece)
      error(message) -> return "error: #{message} after #{text.size}"
    end
  end
  return "unreachable"
end

def main() -> Void
  raw = "http://127.0.0.1:#{System.args()[3]}"
  for path in ["/truncated", "/badchunk", "/http10", "/atlimit", "/bigchunks", "/after", "/headerless", "/nocontent", "/two", "/tail"]
    conn = Result.unwrap!(HTTP.start(raw, options(5000, 1, 8, "")))
    case HTTP.send_request(conn, "GET", path, "".bytes)
      ok(head) -> puts("#{path} #{head.status} #{drain(conn)} #{HTTP.send_request(conn, "GET", path, "".bytes).ok?}")
      error(message) -> puts("#{path} error: #{message}")
    end
    HTTP.finish(conn)
  end
end
"""

CONNECTION_TLS_PROGRAM = """\
def why(started: Result[HTTP.Connection]) -> String
  case started
    ok(conn) ->
      HTTP.finish(conn)
      return "started"
    error(e) -> return e.message
  end
end

def main() -> Void
  certs = System.args()[0]
  port = System.args()[2]
  # The deadline of each call, scaled: a TLS handshake with the Python server can take seconds on a loaded runner.
  limit = System.args()[4].to_i!
  origin = "https://localhost:#{port}"
  conn = Result.unwrap!(HTTP.start(origin, options(limit, 1, 1000, certs + "/ca.pem")))
  hello = Result.unwrap!(HTTP.send_request(conn, "GET", "/hello", "".bytes))
  puts("#{hello.status} #{decoded(Result.unwrap!(HTTP.read_body(conn)))}")
  puts(Result.unwrap!(HTTP.read_body(conn)).size)
  notify = Result.unwrap!(HTTP.send_request(conn, "GET", "/notify", "".bytes))
  puts("#{notify.status} #{decoded(Result.unwrap!(HTTP.read_body(conn)))} #{Result.unwrap!(HTTP.read_body(conn)).size}")
  puts(HTTP.send_request(conn, "GET", "/hello", "".bytes).ok?)
  puts(why(HTTP.start(origin, options(limit, 1, 1000, certs + "/self-signed.pem"))))
  puts(why(HTTP.start("http://localhost:#{port}", options(limit, 1, 1000, ""))))
end
"""

STREAM_OPEN_PROGRAM = """\
# The bytes the channel gives; with a stop, the reader closes the channel after that many pieces (as a reader that has
# seen enough does). The pieces are not counted: how the reads cut a body is up to the connection.
def count(stream: HTTP.Stream, stop: Int, pause: Int) -> Int
  Task.sleep(pause)
  pieces = 0
  total = 0
  while true
    case stream.body.recv(5000)
      ok(piece) ->
        pieces = pieces + 1
        total = total + piece.size
        if pieces == stop
          stream.body.close
        end
      error(_) -> break
    end
  end
  return total
end

def text_of(stream: HTTP.Stream) -> String
  all: List[Bytes] = []
  while true
    case stream.body.recv(5000)
      ok(piece) -> all = all.push(piece)
      error(_) -> break
    end
  end
  return decoded(Bytes.concat(all))
end

def ended(stream: HTTP.Stream) -> String
  case Task.await(stream.done)
    ok(_) -> return "done ok"
    error(message) -> return "done error: #{message}"
  end
end

def refused(opened: Result[HTTP.Stream]) -> String
  case opened
    ok(stream) -> return "opened #{stream.status}"
    error(message) -> return "error: #{message}"
  end
end

# Whether the peer saw the client of /quiet close its socket, within about two seconds.
def peer_saw_close(plain: String) -> Bool
  for _ in 1..40
    case HTTP.get_response(plain + "/quiet-closed")
      ok(response) ->
        if decoded(response.body) == "1"
          return true
        end
      error(_) -> return false
    end

    Task.sleep(50)
  end
  return false
end

def main() -> Void
  plain = "http://127.0.0.1:#{System.args()[1]}"
  raw = "http://127.0.0.1:#{System.args()[3]}"
  fast = options(5000, 1, 1000, "")
  chunked = Result.unwrap!(HTTP.open("GET", plain + "/chunked", "".bytes, [], fast))
  puts("#{chunked.status} #{HTTP.header_values(chunked.headers, "transfer-encoding")} #{text_of(chunked)} #{ended(chunked)}")
  form = Result.unwrap!(HTTP.open("POST", plain + "/post", "a=1&b=ñ".bytes, [HTTP.Header(name: "X-Kind", value: "form")], fast))
  puts("#{form.status} #{text_of(form)} #{ended(form)}")
  missing = Result.unwrap!(HTTP.open("GET", plain + "/nothing", "".bytes))
  puts("#{missing.status} #{text_of(missing)} #{ended(missing)}")
  head = Result.unwrap!(HTTP.open("HEAD", plain + "/hello", "".bytes))
  puts("#{head.status} #{count(head, 0, 0)} #{ended(head)}")
  big = Result.unwrap!(HTTP.open("GET", plain + "/megabytes", "".bytes, [], options(10000, 1, 1000, "")))
  puts("#{count(big, 0, 300)} #{ended(big)}")
  endless = Result.unwrap!(HTTP.open("GET", plain + "/endless", "".bytes))
  puts("#{count(endless, 3, 0) >= 15} #{ended(endless)}")
  cut = Result.unwrap!(HTTP.open("GET", raw + "/truncated", "".bytes))
  puts("#{count(cut, 0, 0)} #{ended(cut)}")
  puts(refused(HTTP.open("GET", plain + "/slow", "".bytes, [], options(300, 1, 1000, ""))))
  puts(refused(HTTP.open("GET", "ftp://127.0.0.1/", "".bytes)))
  puts(refused(HTTP.open("BAD METHOD", plain + "/hello", "".bytes)))
  quiet = Result.unwrap!(HTTP.open("GET", plain + "/quiet", "".bytes, [], options(20000, 1, 1000, "")))
  puts(decoded(Result.unwrap!(quiet.body.recv(5000))))
  Task.cancel(quiet.done)
  puts(Result.ok?(Task.await(quiet.done)))
  puts(peer_saw_close(plain))
  puts(Task.pending_count())
end
"""

UPLOAD_HELPERS = """\
def produce(producer: Producer) -> Void
  for piece in producer.pieces
    _ = producer.into.send(piece, 5000)
  end
  if producer.close
    producer.into.close
  end
end

def doubled(unit: Bytes, times: Int) -> Bytes
  data = unit
  for _ in 1..times
    data = Bytes.concat([data, data])
  end
  return data
end

def upload(method: String, pieces: List[Bytes], length: Int, timeout: Int, close: Bool) -> String
  return upload_to("/upload", method, pieces, length, timeout, close)
end

def upload_to(path: String, method: String, pieces: List[Bytes], length: Int, timeout: Int, close: Bool) -> String
  plain = "http://127.0.0.1:#{System.args()[1]}"
  into: Channel[Bytes] = Channel.new(2)
  Task.spawn(&produce, Producer(pieces: pieces, into: into, close: close))
  case HTTP.upload(method, plain + path, into, length, [HTTP.Header(name: "X-Kind", value: "up")], options(timeout, 1, 1000, ""))
    ok(response) -> return "#{response.status} #{decoded(response.body)}"
    error(message) -> return "error: #{message}"
  end
end

"""

STREAM_UPLOAD_PROGRAM = UPLOAD_HELPERS + """\
def main() -> Void
  small = ["ab".bytes, "".bytes, "cd".bytes, "é".bytes]
  puts(upload("POST", small, -1, 5000, true))
  puts(upload("POST", small, 6, 5000, true))
  puts(upload("PUT", [], -1, 5000, true))
  puts(upload("PATCH", [], 0, 5000, true))
  mega = doubled("x".bytes, 20)
  puts(upload("PUT", [mega, "z".bytes], -1, 5000, true))
  puts(upload("POST", [mega, mega], 2097152, 5000, true))
  puts(upload("POST", small, 3, 5000, true))
  puts(upload("POST", small, 8, 5000, true))
  puts(upload("POST", small, -1, 300, false))
  puts(upload("POST", small, 6, 300, false))
  puts(upload("PATCH", [], 0, 300, false))
  puts(upload("GET", small, -1, 5000, true))
  puts(upload("POST", small, -2, 5000, true))
end
"""
STREAM_REFUSE_PROGRAM = UPLOAD_HELPERS + """\
def main() -> Void
  mega = doubled("x".bytes, 20)
  puts(upload_to("/refuse", "POST", [mega, mega, mega, mega, mega, mega, mega, mega, mega, mega, mega, mega], -1, 5000, true))
end
"""

RAW_PROGRAM = """\
def main() -> Void
  raw = "http://127.0.0.1:#{System.args()[3]}"
  limit = System.args()[4].to_i!
  upload = "x"
  while String.length(upload) < 4194304
    upload = upload + upload
  end
  large = Result.unwrap!(HTTP.client(options(limit, 1, 8388608, "")))
  show(HTTP.post(large, raw + "/early", upload.bytes))
  hostile = Result.unwrap!(HTTP.client(options(limit, 1, 1000, "")))
  stale = Result.unwrap!(HTTP.client(options(limit, 1, 1000, "")))
  show(HTTP.get(stale, raw + "/stale"))
  show(HTTP.post(stale, raw + "/after", "x".bytes))
  show(HTTP.get(stale, raw + "/stale"))
  show(HTTP.get(stale, raw + "/after"))
  show(HTTP.request(stale, "HEAD", raw + "/headlength", "".bytes))
  show(HTTP.get(stale, raw + "/after"))
  for path in ["/http10", "/status99", "/status600", "/upgrade", "/interim15", "/interim16", "/badchunk", "/atlimit", "/big", "/bigchunks", "/barelf", "/fold", "/twolengths", "/smuggle", "/gzip", "/badtrailer", "/truncated", "/headerless", "/nocontent", "/after"]
    show(HTTP.get(hostile, raw + path))
  end
end
"""

SERVER_PROGRAM = """\
import HTTP from "std/http"

def handle(request: HTTP.Request) -> Result[HTTP.Response]
  if request.path == "/big"
    big = "x"
    while String.length(big) < 8388608
      big = big + big
    end
    return ok(HTTP.Response(status: 200, headers: [], body: big.bytes))
  end
  if request.path == "/latin1"
    sent = request.headers.detect do |h| h.name == "x-in" end
    seen = ""
    if sent.ok?
      seen = sent.unwrap!.value
    end
    return ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "X-Out", value: "café " + seen)], body: "in #{seen} #{seen.length}".bytes))
  end
  if request.path == "/long"
    # 5000 characters are 5000 bytes on the wire but 10000 in the UTF-8 head String: under the 8192 of a line.
    big = "é"
    while String.length(big) < 5000
      big = big + big
    end
    return ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "X-Out", value: String.slice(big, 0, 5000))], body: "".bytes))
  end
  if request.path == "/wide"
    return ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "X-Out", value: "\u0100")], body: "".bytes))
  end
  if request.path == "/split"
    return ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "X-Out", value: "a\\r\\nX-Evil: 1")], body: "".bytes))
  end
  # The body is Bytes: its text when it is UTF-8, else its byte values.
  shown = Result.unwrap_or(HTTP.text(request.body, request.headers), "bytes #{request.body.to_a}")
  return ok(HTTP.Response(status: 200, headers: [], body: "#{request.method} #{request.path} #{shown}".bytes))
end

def main() -> Void
  options = HTTP.ServerOptions(request_timeout_ms: 2000, idle_timeout_ms: 10000, max_connections: 2, max_body_bytes: 1024)
  server = Result.unwrap!(HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options))
  certs = System.args()[0]
  secure = Result.unwrap!(HTTP.serve_tls("127.0.0.1", 0, TLS.server_context(TLS.ServerOptions(cert_file: certs + "/server.pem", key_file: certs + "/server-key.pem")).unwrap!, HTTP.app(&handle), options))
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
"""

# An upload server: the app of serve reports what it saw of each body on stdout, one line per request
# ("PATH BYTES DONE"), where DONE is how the feeder ended. /slow waits before it reads, so the channel fills and the
# socket backs up; /early and /stop answer without reading the whole body.
UPLOAD_SERVER_PROGRAM = """\
import HTTP from "std/http"

def outcome(body: HTTP.RequestBody) -> String
  case Task.await(body.done)
    ok(_) -> return "done ok"
    error(message) -> return "done error: #{message}"
  end
end

def drained(body: HTTP.RequestBody, pause: Int) -> List[Bytes]
  Task.sleep(pause)
  all: List[Bytes] = []
  while true
    case body.pieces.recv(5000)
      ok(piece) -> all = all.push(piece)
      error(_) -> break
    end
  end

  return all
end

def answer(status: Int, text: String) -> Result[HTTP.Response]
  return ok(HTTP.Response(status: status, headers: [], body: text.bytes))
end

def handle(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Response]
  if request.path == "/early"
    puts("/early")
    IO.flush()
    return answer(200, "early")
  end

  if request.path == "/stop"
    first = Result.unwrap_or(body.pieces.recv(5000), "".bytes)
    puts("/stop #{first.size}")
    IO.flush()
    return answer(413, "stopped")
  end

  if request.path == "/fail"
    drained(body, 0)
    return error("the handler failed")
  end

  if request.path == "/all"
    case HTTP.read_all(body, 8)
      ok(data) -> return answer(200, "all #{data.size}")
      error(e) -> return answer(413, e.message)
    end
  end

  pause = 0
  if request.path == "/slow"
    pause = 300
  end

  data = Bytes.concat(drained(body, pause))
  shown = Result.unwrap_or(String.from_bytes(data), "<not UTF-8>")
  done = outcome(body)
  puts("#{request.method} #{request.path} #{request.body.size} #{data.size} #{done}")
  IO.flush()
  if data.size > 40
    shown = "#{data.size} bytes"
  end

  return answer(200, "#{request.path} #{shown} #{done}")
end

def app(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  return ok(HTTP.Answer.Whole(try handle(request, body)))
end

def main() -> Void
  options = HTTP.ServerOptions(request_timeout_ms: 2000, idle_timeout_ms: 10000, max_connections: 8, max_body_bytes: 4194304)
  server = Result.unwrap!(HTTP.serve("127.0.0.1", 0, &app, options))
  certs = System.args()[0]
  secure = Result.unwrap!(HTTP.serve_tls("127.0.0.1", 0, TLS.server_context(TLS.ServerOptions(cert_file: certs + "/server.pem", key_file: certs + "/server-key.pem")).unwrap!, &app, options))
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
"""

# A streaming server: /ticks sends four pieces TICK_MS (STREAM_TICK_MS) apart, /endless sends until the client leaves
# and then tells /said, and the timeouts are shorter than the pause, so a live stream that is only slow must not be cut.
STREAM_SERVER_PROGRAM = """\
import HTTP from "std/http"

TICK_MS = @tick_ms

struct Feed
  said: Channel[String]
  body: Channel[Bytes]
end

def ticks(feed: Feed) -> Void
  for n in 1..4
    if n > 1
      Task.sleep(TICK_MS)
    end
    _ = feed.body.send("data: #{n}\\n\\n".bytes, 5000)
  end
  feed.body.close
end

# Four bytes that are not UTF-8, in two pieces, then text.
def binary(feed: Feed) -> Void
  _ = feed.body.send(Bytes.from_list([255, 0]).unwrap!, 5000)
  _ = feed.body.send(Bytes.from_list([128, 254]).unwrap!, 5000)
  _ = feed.body.send("end".bytes, 5000)
  feed.body.close
end

# Pieces for the routes that give a length: the server sends them as they are, with Content-Length and no chunks.
def sized(feed: Feed) -> Void
  _ = feed.body.send("abc".bytes, 5000)
  Task.sleep(TICK_MS)
  _ = feed.body.send("defgh".bytes, 5000)
  feed.body.close
end

def three(feed: Feed) -> Void
  # Not ready when the server looks, so it streams: a body that is closed already is sent whole, or is a 500.
  Task.sleep(TICK_MS)
  _ = feed.body.send("abc".bytes, 5000)
  feed.body.close
end

def five_and_more(feed: Feed) -> Void
  # Not ready when the server looks, so it streams: a body that is closed already is sent whole, or is a 500.
  Task.sleep(TICK_MS)
  _ = feed.body.send("abc".bytes, 5000)
  _ = feed.body.send("defgh".bytes, 5000)
  feed.body.close
end

def exact_and_more(feed: Feed) -> Void
  # Not ready when the server looks, so it streams: a body that is closed already is sent whole, or is a 500.
  Task.sleep(TICK_MS)
  _ = feed.body.send("abcde".bytes, 5000)
  _ = feed.body.send("f".bytes, 5000)
  feed.body.close
end

# The length is full at once and the producer closes much later: the client has its answer and sends its next request
# in between, so the server must end the stream at the length and not wait for the close.
def late_close(feed: Feed) -> Void
  Task.sleep(TICK_MS)
  _ = feed.body.send("abcde".bytes, 5000)
  Task.sleep(400)
  feed.body.close
end

def nothing_then_close(feed: Feed) -> Void
  Task.sleep(400)
  feed.body.close
end

def endless(feed: Feed) -> Void
  while Result.ok?(feed.body.send("data: again\\n\\n".bytes, 5000))
    Task.sleep(20)
  end
  _ = feed.said.send("stopped", 5000)
end

def stream(feed: Feed, job: Fn[Feed, Void]) -> Result[HTTP.StreamResponse]
  Task.spawn(job, feed)
  headers = [HTTP.Header(name: "Content-Type", value: "text/event-stream")]
  return ok(HTTP.StreamResponse(status: 200, headers: headers, body: feed.body))
end

def sized_stream(feed: Feed, job: Fn[Feed, Void], length: Int) -> Result[HTTP.StreamResponse]
  Task.spawn(job, feed)
  return ok(HTTP.StreamResponse(status: 200, headers: [], body: feed.body, length: some(length)))
end

def handler_of(f: Fn[HTTP.Request, Result[HTTP.StreamResponse]]) -> Fn[HTTP.Request, Result[HTTP.StreamResponse]]
  return f
end

def routes(said: Channel[String]) -> Fn[HTTP.Request, Result[HTTP.StreamResponse]]
  return handler_of() do |request|
    body: Channel[Bytes] = Channel.new(2)
    feed = Feed(said: said, body: body)
    if request.path == "/ticks"
      return stream(feed, &ticks)
    end
    if request.path == "/endless"
      return stream(feed, &endless)
    end
    if request.path == "/binary"
      return stream(feed, &binary)
    end
    if request.path == "/latin1-chunked"
      Task.spawn(&three, feed)
      return ok(HTTP.StreamResponse(status: 200, headers: [HTTP.Header(name: "X-Out", value: "café")], body: feed.body))
    end
    if request.path == "/latin1-sized"
      Task.spawn(&three, feed)
      return ok(HTTP.StreamResponse(status: 200, headers: [HTTP.Header(name: "X-Out", value: "café")], body: feed.body, length: some(3)))
    end
    if request.path == "/sized"
      return sized_stream(feed, &sized, 8)
    end
    if request.path == "/sized-short"
      return sized_stream(feed, &three, 8)
    end
    if request.path == "/sized-long"
      return sized_stream(feed, &five_and_more, 5)
    end
    if request.path == "/sized-extra"
      return sized_stream(feed, &exact_and_more, 5)
    end
    if request.path == "/sized-late"
      return sized_stream(feed, &late_close, 5)
    end
    if request.path == "/sized-queued"
      # The piece past the length is already in the channel when the handler returns, and the producer never closes.
      queued: Channel[Bytes] = Channel.new(4)
      _ = queued.send("abcde".bytes, 5000)
      _ = queued.send("f".bytes, 5000)
      return ok(HTTP.StreamResponse(status: 200, headers: [], body: queued, length: some(5)))
    end
    if request.path == "/sized-zero"
      return sized_stream(feed, &nothing_then_close, 0)
    end
    if request.path == "/sized-negative"
      return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole("hello".bytes), length: some(-3)))
    end
    if request.path == "/sized-204"
      return ok(HTTP.StreamResponse(status: 204, headers: [], body: HTTP.whole("".bytes), length: some(0)))
    end
    if request.path == "/sized-whole"
      return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole("hello".bytes), length: some(5)))
    end
    if request.path == "/sized-wrong"
      return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole("hello".bytes), length: some(9)))
    end
    if request.path == "/binary-whole"
      return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole(Bytes.from_list([255, 0, 128, 254]).unwrap!)))
    end
    text = "whole"
    if request.path == "/said"
      text = said.recv(10000).unwrap_or("nothing")
    end
    return ok(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole(text.bytes)))
  end
end

def app_of(f: HTTP.App) -> HTTP.App
  return f
end

# The body read first (a body that cannot be read is refused as HTTP.app does), then the stream of the route.
def stream_answer(route: Fn[HTTP.Request, Result[HTTP.StreamResponse]], request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  case HTTP.read_all(body, 1024)
    ok(_) -> return ok(HTTP.Answer.Stream(try route.call(request)))
    error(e) -> return ok(HTTP.body_refusal(e.message))
  end
end

def streamed(said: Channel[String]) -> HTTP.App
  route = routes(said)
  return app_of() do |request, body| stream_answer(route, request, body) end
end

def main() -> Void
  said: Channel[String] = Channel.new(8)
  options = HTTP.ServerOptions(request_timeout_ms: 300, idle_timeout_ms: 300, max_connections: 8, max_body_bytes: 1024)
  server = Result.unwrap!(HTTP.serve("127.0.0.1", 0, streamed(said), options))
  certs = System.args()[0]
  secure = Result.unwrap!(HTTP.serve_tls("127.0.0.1", 0, TLS.server_context(TLS.ServerOptions(cert_file: certs + "/server.pem", key_file: certs + "/server-key.pem")).unwrap!, streamed(said), options))
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
"""

# The pause between the pieces of the stream server, scaled like the other deadlines: the peer times the pieces
# against it, and a loaded runner stretches what a fixed pause leaves of a margin.
STREAM_TICK_MS = scaled(500)


def stream_server_program():
    return STREAM_SERVER_PROGRAM.replace("@tick_ms", str(STREAM_TICK_MS))

STREAM_PYTHON_LINES = [
    "plain 200 chunked None text/event-stream ['data: 1\\n\\n', 'data: 2\\n\\n', 'data: 3\\n\\n', 'data: 4\\n\\n']",
    "plain-timing apart",
    "plain-keep-alive 200 5 whole True",
    "tls 200 chunked None text/event-stream ['data: 1\\n\\n', 'data: 2\\n\\n', 'data: 3\\n\\n', 'data: 4\\n\\n']",
    "tls-timing apart",
    "tls-keep-alive 200 5 whole True",
    "plain-sized 200 None 8 ['abc', 'defgh']",
    "plain-sized-timing apart",
    "plain-sized-keep-alive 200 5 whole True",
    "tls-sized 200 None 8 ['abc', 'defgh']",
    "tls-sized-timing apart",
    "tls-sized-keep-alive 200 5 whole True",
    "sized-short 200 8 incomplete b'abc'",
    "sized-long 200 5 incomplete b'abc'",
    "sized-extra 200 5 b'abcde'",
    "sized-late 200 5 b'abcde' whole True",
    "head 200 chunked b'' whole True",
    "sized-head 200 8 None b'' whole True",
    "sized-queued 200 5 b'abcde' whole True",
    "sized-zero 200 0 b'' whole True",
    "sized-whole 200 5 b'hello'",
    "sized-wrong 500",
    "sized-negative 500",
    "sized-204 500",
    "binary 200 b'\\xff\\x00\\x80\\xfeend' framed",
    "binary-whole 200 4 b'\\xff\\x00\\x80\\xfe'",
    "tls-binary 200 b'\\xff\\x00\\x80\\xfeend' framed",
    "tls-binary-whole 200 4 b'\\xff\\x00\\x80\\xfe'",
    "plain-leave-first 200 ['data: again\\n\\n']",
    "plain-leave stopped",
    "tls-leave-first 200 ['data: again\\n\\n']",
    "tls-leave stopped",
    "silent-leave stopped",
    "half-close True False",
    "half-close stopped",
    "http-1.0 505 0",
]

SERVER_PYTHON_LINES = [
    "length-and-chunked 400 closed",
    "two-lengths 400 closed",
    "equal-lengths 200 closed",
    "equal-length-list 200 closed",
    "gzip 501 closed",
    "gzip-chunked 501 closed",
    "two-encodings 501 closed",
    "huge-chunk 413 closed",
    "bad-chunk 400 closed",
    "bare-lf 400 closed",
    "long-line 431 closed",
    "long-head 431 closed",
    "headers-100 200 closed",
    "headers-101 431 closed",
    "headers-150 431 closed",
    "long-trailer 431 closed",
    "many-trailers 431 closed",
    "bad-trailer 400 closed",
    "http-1 505 closed",
    "http-2 505 closed",
    "http-1.10 505 closed",
    "http-2.0 505 closed",
    "http-1.0 505 closed",
    "http-2.0-headers 505 closed",
    "bad-version 400 closed",
    "leading-crlf 200 closed",
    "absolute-target 400 closed",
    "non-ascii-target 400 closed",
    "star-get 400 closed",
    "star-options 200 closed",
    "bad-method 400 closed",
    "connect 501 closed",
    "upgrade 501 closed",
    "fold 400 closed",
    "expect-other 417 closed",
    "over-limit 413 closed",
    "chunked-over-limit 413 closed",
    "no-host 400 closed",
    "two-hosts 400 closed",
    "short-505 505 closed quick",
    "bad-line-open 400 closed quick",
    "partial-head none closed bounded",
    "expect-over-limit HTTP/1.1 413 Content Too Large False closed",
    "expect-continue HTTP/1.1 100 Continue 200 POST /expect hello closed",
    "pipelined ['GET /one ', 'POST /two abc', 'POST /four abc', 'GET /three '] closed",
    "binary-length 200 POST /binary bytes [255, 254] closed",
    "binary-chunked 200 POST /binary bytes [255, 0, 128] closed",
    "client-chunked 200 POST /chunked abñcd",
    "client-head 200 11 b''",
    "client-again 200 GET /again  True",
    "slots 2 waiting",
    "slot-freed 200 GET /waiting  closed",
    "tls-keep-alive 200 GET /one  200 POST /two over tls True",
    "tls-silent closed bounded",
    "tls-plain closed",
    "flood bounded",
]

SERVER_NODE_LINES = [
    "node-chunked 200 true POST /chunked abñcd",
    "node-binary 200 true POST /binary bytes [255, 0, 128]",
    "node-expect true 200 POST /expect hello",
    "node-keep-alive GET /first  GET /again  true true",
    "node-head 200 11 \"\"",
    "node-concurrent 3 true",
]






def start_peer(adopt):
    """http-peer.py serves until its stdin closes, so the pipe stays open; returns the peer and the ports it prints."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    return peer, json.loads(peer.next_line())


def run_program(tmp_path, name, text, ports):
    source = tmp_path / (name + ".agc")
    source.write_text(PRELUDE + text, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / (name + ".agcb"))
    # The fifth argument is the client deadline of RAW_PROGRAM, TLS_PROGRAM and CONNECTION_TLS_PROGRAM: a call that a
    # correct run must finish, so it is scaled.
    args = [CERTS] + [ports[key] for key in ("plain", "tls", "raw")] + [str(scaled(5000))]
    result = run_vm(bytecode, env=vm_environment(), args=args)
    assert result.code == 0, result.stderr
    return result.stdout


def test_client_against_threading_http_server_keep_alive_chunked_close_delimited_timeout_pool_limits(tmp_path, adopt):
    _, ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "plain", PLAIN_PROGRAM, ports), [
        '200 hello 127.0.0.1 ["a", "b"]',
        "200 ñandú chunks 12",
        "200 3 255 128 false",
        "5 [255, 0, 128, 13, 10]",
        "200 5 ff00800d0a 12",
        "4 233 true",
        "200 form 8 a=1&b=ñ 14",
        "true",
        "200 until the end 13",
        "true",
        "404 missing 7",
        "200 None 0  7",
        "200 deleted /item None 18",
        "200 ñandú chunks 12",
        "200 form 8 a=1&b=ñ 14",
        "network: operation timed out",
        "http: the URL must be http:// or https:// with a host, and without user info",
        "http: every option must be positive",
        "0",
        "network: operation timed out",
        "true",
        "true",
        'error("http: client is closed")'], "plain")


def test_client_against_a_python_ssl_server_with_the_clients_ca_file(tmp_path, adopt):
    _, ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "tls", TLS_PROGRAM, ports), [
        "200 hello localhost 15",
        "200 hello localhost 15",
        "200 None 8 over tls 15",
        "200 closed cleanly 14",
        "http: truncated HTTP body",
        ("prefix", "could not read from the stream | "),
        ("prefix", "network: TLS connect failed (certificate verify failed"),
        ("prefix", "network: cannot load ca_file ")], "tls")


def test_public_connection_reads_bodies_in_pieces_and_serves_a_second_request_on_the_same_socket(tmp_path, adopt):
    _, ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "connection", CONNECTION_PROGRAM, ports), [
        '200 ["a", "b"] hello 127.0.0.1 in 4',
        "true",
        "200 ñandú chunks in 5",
        "true",
        "200 conn 8 a=1&b=ñ in 1",
        "200  in 0",
        "true",
        "true",
        "200 [255, 0] [128] 0",
        "true",
        "error: http: the body of the last response is not read to its end",
        "hello 127.0.0.1 in 1",
        "true",
        'error("http: max_bytes must be 1 to 1048576")',
        "200 until the end in 4",
        "error: http: the connection is closed",
        'error("http: the connection is closed")',
        'error("http: the connection is closed")',
        "http: start takes an origin such as http://host:8080, with no path or query",
        "http: the URL must be http:// or https:// with a host, and without user info",
        "error: http: request body exceeds max_body_bytes",
        "error: http: invalid method",
        "200 hello 127.0.0.1 in 1",
        "error: network: operation timed out",
        "error: http: the connection is closed",
        "0"], "connection")


def test_public_connection_against_hostile_raw_responses(tmp_path, adopt):
    _, ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "connection-raw", CONNECTION_RAW_PROGRAM, ports), [
        "/truncated 200 error: http: truncated HTTP body after 3 false",
        "/badchunk 200 error: http: invalid chunk size after 0 false",
        "/http10 error: http: HTTP version is unsupported",
        "/atlimit 200 1000 bytes false",
        "/bigchunks 200 1024 bytes false",
        "/after 200 2 bytes false",
        "/headerless error: network: end of input",
        "/nocontent 204 0 bytes false",
        "/two 200 3 bytes false",
        "/tail 200 3 bytes false"], "connection-raw")


def test_open_streams_a_response_body_on_a_channel_with_backpressure_and_an_early_stop(tmp_path, adopt):
    _, ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "stream-open", STREAM_OPEN_PROGRAM, ports), [
        '200 ["chunked"] ñandú chunks done ok',
        "200 form 8 a=1&b=ñ done ok",
        "404 missing done ok",
        "200 0 done ok",
        "3145728 done ok",
        "true done error: channel: closed",
        "3 done error: http: truncated HTTP body",
        "error: network: operation timed out",
        "error: http: the URL must be http:// or https:// with a host, and without user info",
        "error: http: invalid method",
        "hi",
        "false",
        "true",
        "0"], "stream-open")


def test_upload_sends_a_body_from_a_channel_chunked_or_with_its_length(tmp_path, adopt):
    _, ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "stream-upload", STREAM_UPLOAD_PROGRAM, ports), [
        "200 POST chunked 3 6 bef7c249",
        "200 POST length 6 6 bef7c249",
        "200 PUT chunked 0 0 e3b0c442",
        "200 PATCH length 0 0 e3b0c442",
        "200 PUT chunked 3 1048577 235d78ad",
        "200 POST length 2097152 2097152 6932fd31",
        "error: http: the upload body is longer than its length",
        "error: http: the upload body is shorter than its length",
        "error: channel: timed out",
        "200 POST length 6 6 bef7c249",
        "200 PATCH length 0 0 e3b0c442",
        "error: http: upload takes POST, PUT or PATCH",
        "error: http: length must be -1 (chunked) or the number of bytes"], "stream-upload")


# The server closes with the upload unread. Whether its answer is still readable after the reset depends on the system:
# Windows drops the input of a reset connection, so there the write failure is all the client may have.
def test_upload_returns_the_answer_of_a_server_that_refuses_it_and_closes(tmp_path, adopt):
    _, ports = start_peer(adopt)
    first = output_lines(run_program(tmp_path, "stream-refuse", STREAM_REFUSE_PROGRAM, ports))[0]
    assert first == "413 big!" or (WINDOWS and first.startswith("error: http: ")), first


def test_public_connection_over_tls_verifies_the_certificate_and_ends_a_body_that_runs_to_the_close(tmp_path, adopt):
    _, ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "connection-tls", CONNECTION_TLS_PROGRAM, ports), [
        "200 hello localhost",
        "0",
        "200 closed cleanly 0",
        "false",
        ("prefix", "network: TLS connect failed (certificate verify failed"),
        "started"], "connection-tls")


def test_client_against_hostile_raw_responses_and_a_413_that_comes_before_the_upload_ends(tmp_path, adopt):
    peer, ports = start_peer(adopt)
    try:
        check_raw_lines(run_program(tmp_path, "raw", RAW_PROGRAM, ports))
    except AssertionError:
        print(peer_early_line(peer))
        raise


def peer_early_line(peer):
    """What the raw peer saw of /early (its line is printed once the connection ends), for a failure report."""
    try:
        return peer.next_line(timeout=scaled(2))
    except AssertionError as problem:
        return "the peer printed no /early line: %s" % problem


def check_raw_lines(text):
    check_lines(text, [
        "413 big! 4",
        "200 stale 5",
        "http: connection closed before the response was complete",
        "200 stale 5",
        "200 ok 2",
        "200  0",
        "200 reused 6",
        "http: HTTP version is unsupported",
        "http: invalid HTTP head",
        "http: invalid response status",
        "http: protocol upgrades are unsupported",
        "200 ok 2",
        "http: too many interim responses",
        "http: invalid chunk size",
        "200 xxxxxxxxxxxxxxxxxxxx 1000",
        "http: body exceeds max_body_bytes",
        "http: body exceeds max_body_bytes",
        "http: HTTP requires CRLF",
        "http: folded HTTP header lines are not allowed",
        "http: invalid content length",
        "http: ambiguous HTTP body framing",
        "http: unsupported transfer encoding",
        "http: invalid trailer",
        "http: truncated HTTP body",
        "http: connection closed before the response was complete",
        "204  0",
        "200 ok 2"], "raw")


def test_server_against_python_raw_sockets_python_http_client_and_node_http_clients(tmp_path, adopt):
    # Node is optional locally (that part is left out, like the original test); CI fails without it.
    node = optional_tool("node")
    source = tmp_path / "server.agc"
    source.write_text(SERVER_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "server.agcb")
    vm = adopt(start_vm(bytecode, CERTS, stdin=True))
    port, tls_port = vm.next_line().split()
    python_run = run([PYTHON, SERVER_PEER, port, "2", tls_port, CERTS, str(vm.process.pid)], timeout=scaled(120))
    assert python_run.code == 0, python_run.stderr
    assert output_lines(python_run.stdout) == SERVER_PYTHON_LINES
    if node:
        node_run = run([node, SERVER_NODE_PEER, port, "2"], timeout=scaled(120))
        assert node_run.code == 0, node_run.stderr
        assert output_lines(node_run.stdout) == SERVER_NODE_LINES
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"
    assert vm.next_line() == "ok()"
    assert vm.next_line() == "ok()"
    assert vm.stderr_text() == ""


def test_streaming_server_sends_each_chunk_when_it_is_ready_and_stops_the_producer_of_a_client_that_left(
        tmp_path, adopt):
    """http.client reads the chunks of /ticks as they arrive and times them, over plain TCP and TLS; HEAD, keep-alive
    after a stream, a client that leaves mid-stream (its producer must learn of it) and an HTTP/1.0 client. A stream
    with a length goes out with Content-Length and no chunks: whole, cut short, cut for a piece past the length and
    ended when the length is full (the next request on the connection works though the producer closes much
    later, also for a length of 0), whatever a producer sends after it (a piece that crosses it is a cut); a negative length and a length on a 204 are a
    500."""
    source = tmp_path / "stream-server.agc"
    source.write_text(stream_server_program(), encoding="utf-8")
    vm = adopt(start_vm(compile_agc(source, tmp_path / "stream-server.agcb"), CERTS, stdin=True))
    port, tls_port = vm.next_line().split()
    peer = run([PYTHON, STREAM_PEER, port, tls_port, str(CERTS), str(STREAM_TICK_MS)], timeout=scaled(120))
    assert peer.code == 0, peer.stderr
    assert output_lines(peer.stdout) == STREAM_PYTHON_LINES
    # A body the stream route cannot read gets the answer HTTP.app gives, not a 500: over the 1024-byte limit, a bad
    # chunk.
    chunked = b"POST /whole HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
    for body, status in [(b"401\r\n" + b"a" * 1025 + b"\r\n0\r\n\r\n", b"413"), (b"zz\r\nab\r\n0\r\n\r\n", b"400")]:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=scaled(10)) as conn:
            conn.sendall(chunked + body)
            head, _ = raw_answer(conn, True)
            assert head.split(b" ")[1] == status and b"\r\nconnection: close" in head, head
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"
    assert vm.next_line() == "ok()"
    assert vm.next_line() == "ok()"
    # The only things said are the answers that were refused: a closed body of 5 bytes with a length of 9, a negative
    # length, and a length on a 204.
    assert vm.stderr_text() == (
        "http: invalid response: the body is not the length it was given\n"
        "http: invalid response: the length of a streamed body cannot be negative\n"
        "http: invalid response: a 204 or 304 response cannot have a body\n")


def test_streamed_response_sends_latin1_header_values_as_single_bytes(tmp_path, adopt):
    """The head of a stream is rewritten (chunked, or its length) before it is turned into bytes: the value still goes
    out as one byte."""
    source = tmp_path / "stream-latin1.agc"
    source.write_text(stream_server_program(), encoding="utf-8")
    vm = adopt(start_vm(compile_agc(source, tmp_path / "stream-latin1.agcb"), CERTS, stdin=True))
    port, _ = vm.next_line().split()
    ask = b"GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"

    def read_stream(path):
        # The write side stays open: a client that half-closes is one that left, and the producer is stopped.
        with socket.create_connection(("127.0.0.1", int(port)), timeout=scaled(10)) as conn:
            conn.sendall(ask % path)
            got = b""
            while chunk := conn.recv(65536):
                got += chunk
        return got

    got = read_stream(b"/latin1-chunked")
    assert got.startswith(b"HTTP/1.1 200 ") and b"\r\nX-Out: caf\xe9\r\n" in got, got
    assert b"\r\nTransfer-Encoding: chunked\r\n" in got and got.endswith(b"3\r\nabc\r\n0\r\n\r\n"), got
    got = read_stream(b"/latin1-sized")
    assert b"\r\nX-Out: caf\xe9\r\n" in got and b"\r\nContent-Length: 3\r\n" in got and got.endswith(b"\r\n\r\nabc"), got
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"


def start_server(tmp_path, adopt):
    """Starts SERVER_PROGRAM; returns the VM child and its plain port."""
    source = tmp_path / "server.agc"
    source.write_text(SERVER_PROGRAM, encoding="utf-8")
    vm = adopt(start_vm(compile_agc(source, tmp_path / "server.agcb"), CERTS, stdin=True))
    return vm, vm.next_line().split()[0]


def send_in_pieces(port, pieces):
    """Sends each piece after a pause, so the server reads them apart; returns the status and body."""
    with socket.create_connection(("127.0.0.1", int(port)), timeout=scaled(10)) as conn:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        for k, piece in enumerate(pieces):
            if k:
                time.sleep(0.05)
            conn.sendall(piece)
        conn.shutdown(socket.SHUT_WR)
        got = b""
        while chunk := conn.recv(65536):
            got += chunk
    top, _, body = got.partition(b"\r\n\r\n")
    return top.split(b" ")[1].decode(), body.decode()


def read_after_close(port, data):
    """Sends data, closes the write side and returns what the server sent before it closed."""
    with socket.create_connection(("127.0.0.1", int(port)), timeout=scaled(10)) as conn:
        conn.sendall(data)
        conn.shutdown(socket.SHUT_WR)
        got = b""
        while chunk := conn.recv(65536):
            got += chunk
    return got


def test_server_reads_requests_that_arrive_in_pieces(tmp_path, adopt):
    """A head or body split across reads gets the same answer as one sent whole: a UTF-8 character split across
    reads and chunks (and an unfinished one, which is just bytes), bodies of exactly the limit, bodies cut short by a
    close, a forbidden trailer split mid-name, and heads too large however slowly they arrive."""
    vm, port = start_server(tmp_path, adopt)
    length = b"POST /length HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: %d\r\n\r\n"
    chunked = b"POST /chunked HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
    assert send_in_pieces(port, [length % 6 + b"ab\xc3", b"\xb1cd"]) == ("200", "POST /length ab\u00f1cd")
    assert send_in_pieces(port, [chunked + b"5\r\na", b"b\xc3", b"\xb1c\r\n1\r\nd\r\n0\r\n\r\n"]) == (
        "200", "POST /chunked ab\u00f1cd")
    assert send_in_pieces(port, [chunked + b"3\r\nab\xc3\r\n", b"2\r\n\xb1c\r\n0\r\n\r\n"]) == (
        "200", "POST /chunked ab\u00f1c")
    assert send_in_pieces(port, [length % 3 + b"ab", b"\xc3"]) == ("200", "POST /length bytes [97, 98, 195]")
    assert send_in_pieces(port, [chunked + b"3\r\nab", b"\xc3\r\n0\r\n\r\n"]) == (
        "200", "POST /chunked bytes [97, 98, 195]")
    assert send_in_pieces(port, [chunked + b"0\r\nConte", b"nt-Length: 2\r\n\r\n"])[0] == "400"
    # A body of exactly max_body_bytes (1024 in SERVER_PROGRAM) is served, with either framing.
    full = b"a" * 1024
    assert send_in_pieces(port, [length % 1024 + full]) == ("200", "POST /length " + full.decode())
    assert send_in_pieces(port, [chunked + b"400\r\n" + full + b"\r\n0\r\n\r\n"]) == (
        "200", "POST /chunked " + full.decode())
    # A body that the close cuts short gets no answer, with either framing.
    assert read_after_close(port, length % 10 + b"abc") == b""
    assert read_after_close(port, chunked + b"5\r\nab") == b""
    many = b"GET / HTTP/1.1\r\nHost: x\r\n" + b"".join(b"X-%d: v\r\n" % k for k in range(101)) + b"\r\n"
    assert send_in_pieces(port, [many[:300], many[300:900], many[900:]])[0] == "431"
    unended = b"GET /" + b"a" * 80000
    assert send_in_pieces(port, [unended[k:k + 20000] for k in range(0, len(unended), 20000)])[0] == "431"
    filler = b"X-Fill: " + b"b" * 4000 + b"\r\n"
    large = b"GET / HTTP/1.1\r\nHost: x\r\n" + filler * 20
    assert send_in_pieces(port, [large[k:k + 9000] for k in range(0, len(large), 9000)])[0] == "431"
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"


def read_answers(conn, count):
    """The status lines and bodies of `count` answers read from a raw socket, which are Content-Length framed."""
    got = b""
    answers = []
    while len(answers) < count:
        while b"\r\n\r\n" not in got:
            more = conn.recv(65536)
            assert more, "the connection closed before answer %d: %r" % (len(answers), got)
            got += more
        head, _, got = got.partition(b"\r\n\r\n")
        length = [int(line.split(b":")[1]) for line in head.split(b"\r\n") if line.lower().startswith(b"content-length")]
        while len(got) < length[0]:
            more = conn.recv(65536)
            assert more, "the connection closed inside an answer body"
            got += more
        answers.append((head.split(b" ")[1].decode(), got[:length[0]].decode()))
        got = got[length[0]:]
    return answers


def test_server_writes_and_reads_latin1_header_values_as_single_bytes(tmp_path, adopt):
    """A value with a Latin-1 character (obs-text) goes out as its one byte and comes back as the same text, whatever
    the peer: a raw socket sees byte 0xE9, http.client reads the header as ISO-8859-1."""
    vm, port = start_server(tmp_path, adopt)
    request = b"GET /latin1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\nX-In: na\xefve\r\n\r\n"
    got = read_after_close(port, request)
    head, _, body = got.partition(b"\r\n\r\n")
    assert head.startswith(b"HTTP/1.1 200 "), got
    assert b"\r\nX-Out: caf\xe9 na\xefve\r\n" in head + b"\r\n", got
    assert body.decode("utf-8") == "in na\u00efve 5"
    conn = http.client.HTTPConnection("127.0.0.1", int(port), timeout=scaled(10))
    conn.request("GET", "/latin1", headers={"X-In": "\u00fcber"})
    reply = conn.getresponse()
    assert reply.getheader("X-Out") == "caf\u00e9 \u00fcber"
    assert reply.read().decode("utf-8") == "in \u00fcber 4"
    conn.close()
    # The line limit counts wire bytes, as the parser does: 5000 Latin-1 characters are one byte each.
    got = read_after_close(port, b"GET /long HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    assert got.startswith(b"HTTP/1.1 200 ") and b"\r\nX-Out: " + b"\xe9" * 5000 + b"\r\n" in got, got[:200]
    # Above U+00FF and control characters are refused: the handler's answer becomes a 500 with no header of it.
    for path in (b"/wide", b"/split"):
        got = read_after_close(port, b"GET " + path + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        assert got.startswith(b"HTTP/1.1 500 ") and b"X-Out" not in got and b"X-Evil" not in got, got
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"


LATIN1_CLIENT_PROGRAM = """\
import HTTP from "std/http"

def main() -> Void
  options = HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 1024, tls: none)
  client = Result.unwrap!(HTTP.client(options))
  reply = Result.unwrap!(HTTP.request(client, "GET", "http://127.0.0.1:" + System.args()[0] + "/", "".bytes, [HTTP.Header(name: "X-Name", value: "caf\u00e9")]))
  back = reply.headers.detect { |h| h.name == "x-back" }.unwrap!.value
  puts("#{back} #{back.length}")
end
"""


def test_client_writes_and_reads_latin1_header_values_as_single_bytes(tmp_path):
    listener = socket.create_server(("127.0.0.1", 0))
    listener.settimeout(scaled(30))
    seen = []
    failures = []

    def serve():
        try:
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(scaled(30))
                data = b""
                while b"\r\n\r\n" not in data:
                    data += conn.recv(65536)
                seen.append(data)
                conn.sendall(b"HTTP/1.1 200 OK\r\nX-Back: na\xefve\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        except Exception as error:
            failures.append(error)

    thread = threading.Thread(target=serve)
    thread.start()
    try:
        source = tmp_path / "latin1-client.agc"
        source.write_text(LATIN1_CLIENT_PROGRAM, encoding="utf-8")
        result = run_vm(compile_agc(source, tmp_path / "latin1-client.agcb"), env=vm_environment(),
                        args=[str(listener.getsockname()[1])])
    finally:
        thread.join(scaled(30))
        listener.close()
    assert not failures, failures
    assert result.code == 0, result.stderr
    assert output_lines(result.stdout) == ["na\u00efve 5"]
    assert b"\r\nX-Name: caf\xe9\r\n" in seen[0], seen


def test_upload_server_hands_the_body_to_the_handler_piece_by_piece_and_keeps_the_connection(tmp_path, adopt):
    """serve: a body of either framing arrives on a channel (3 MiB through a handler that waits before it reads,
    so the socket backs up), the connection stays for the next request, also when it arrived in the same write as the
    end of a chunked body; a handler that answers first, or a body that is cut or bad, ends the connection; over TLS
    too."""
    source = tmp_path / "upload-server.agc"
    source.write_text(UPLOAD_SERVER_PROGRAM, encoding="utf-8")
    vm = adopt(start_vm(compile_agc(source, tmp_path / "upload-server.agcb"), CERTS, stdin=True))
    port, tls_port = vm.next_line().split()
    port = int(port)
    big = bytes(range(256)) * (3 * 4096)
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        head = b"POST /slow HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % len(big)
        conn.sendall(head + big)
        assert read_answers(conn, 1) == [("200", "/slow %d bytes done ok" % len(big))]
        assert vm.next_line() == "POST /slow 0 %d done ok" % len(big)
        # The same connection takes a request with no body, which gets a closed channel at once.
        conn.sendall(b"GET /count HTTP/1.1\r\nHost: x\r\n\r\n")
        assert read_answers(conn, 1) == [("200", "/count  done ok")]
        assert vm.next_line() == "GET /count 0 0 done ok"
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        # A chunked body whose last chunk is followed, in the same write, by a whole second request.
        chunked = (b"POST /count HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                   b"3\r\nab\xc3\r\n3\r\n\xb1cd\r\n0\r\n\r\n")
        conn.sendall(chunked + b"POST /count HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nzz")
        assert read_answers(conn, 2) == [("200", "/count ab\u00f1cd done ok"), ("200", "/count zz done ok")]
        assert vm.next_line() == "POST /count 0 6 done ok"
        assert vm.next_line() == "POST /count 0 2 done ok"
    # A handler that answers before it read the body: its answer arrives and the connection ends.
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /early HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n" + b"x" * 1000)
        raw = b""
        conn.settimeout(scaled(10))
        try:
            while True:
                more = conn.recv(65536)
                if not more:
                    break
                raw += more
        except OSError:
            pass
        assert raw.startswith(b"HTTP/1.1 200") and raw.endswith(b"early"), raw
        assert b"connection: close" in raw.lower(), "the answer says it closes, whatever the timing"
        assert vm.next_line() == "/early"
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /stop HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n")
        assert read_answers(conn, 1) == [("413", "stopped")]
        assert vm.next_line() == "/stop 3"
    # A body cut by the client's close, and a bad chunk: the handler sees the failure in `done`.
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /count HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n0123456789")
        conn.shutdown(socket.SHUT_WR)
        assert vm.next_line() == (
            "POST /count 0 10 done error: http: connection closed before the request was complete")
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /count HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n")
        assert read_answers(conn, 1) == [("200", "/count  done error: http: invalid chunk size")]
        assert vm.next_line() == "POST /count 0 0 done error: http: invalid chunk size"
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /fail HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nok")
        assert read_answers(conn, 1)[0][0] == "500"
    # HTTP.read_all: a body within its limit, then one past it (413 from the handler, and the connection closes).
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /all HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")
        assert read_answers(conn, 1) == [("200", "all 5")]
        conn.sendall(b"POST /all HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n" + b"x" * 20)
        assert read_answers(conn, 1)[0][0] == "413"
    # Expect: 100-continue is answered before the handler runs, and the body that follows is streamed as usual.
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /count HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
        interim = b""
        while b"\r\n\r\n" not in interim:
            more = conn.recv(4096)
            assert more, "the 100 arrives before the body"
            interim += more
        assert interim.startswith(b"HTTP/1.1 100")
        conn.sendall(b"abcd")
        assert read_answers(conn, 1) == [("200", "/count abcd done ok")]
        assert vm.next_line() == "POST /count 0 4 done ok"
    # A body that stops arriving: each step waits request_timeout_ms (2 s), then `done` is an error.
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(20)) as conn:
        conn.sendall(b"POST /count HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n0123456789")
        line = vm.next_line()
        assert line.startswith("POST /count 0 10 done error: "), line
    import http.client
    import ssl
    context = ssl.create_default_context(cafile=str(CERTS / "ca.pem"))
    secure = http.client.HTTPSConnection("localhost", int(tls_port), timeout=scaled(20), context=context)
    secure.request("POST", "/count", body=iter([b"ab", b"cd"]), encode_chunked=True)
    answer = secure.getresponse()
    assert (answer.status, answer.read().decode()) == (200, "/count abcd done ok")
    assert vm.next_line() == "POST /count 0 4 done ok"
    secure.close()
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"
    assert vm.next_line() == "ok()"
    assert vm.next_line() == "ok()"
    assert vm.stderr_text() == "http: handler error: the handler failed\n"


def test_error_answer_arrives_and_the_lingering_close_stops_reading_after_a_byte_limit(tmp_path, adopt):
    """After a 413 the server drops input only up to a limit, so a peer that keeps sending is cut off long before
    the request deadline (2 s in SERVER_PROGRAM) and cannot make the server read for all of it."""
    vm, port = start_server(tmp_path, adopt)
    with socket.create_connection(("127.0.0.1", int(port)), timeout=scaled(10)) as conn:
        conn.sendall(b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n")
        answer = b""
        while b"\r\n\r\n" not in answer:
            more = conn.recv(4096)
            assert more, "the answer arrives before the server closes"
            answer += more
        assert answer.split(b" ")[1] == b"413"
        junk = b"x" * 65536
        sent = 0
        started = time.monotonic()
        try:
            while time.monotonic() - started < 1.5:
                sent += conn.send(junk)
        except OSError:
            # Reset, aborted or broken pipe, depending on the system. A send timeout would also land here, so the
            # time is checked too.
            assert time.monotonic() - started < 1.5, "the server cut the peer off only after %d bytes" % sent
        else:
            pytest.fail("the server kept reading for %d bytes" % sent)
        # Loopback buffers hold a few MB at most; an unbounded drain reads about 130 MB/s.
        assert sent < 64 * 1024 * 1024
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"


REMOTE_ADDR_PROGRAM = """\
import HTTP from "std/http"

def plain(request: HTTP.Request) -> Result[HTTP.Response]
  return ok(HTTP.Response(status: 200, headers: [], body: request.remote_addr.bytes))
end

def stream(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  try HTTP.read_all(body, 1024)
  return ok(HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: [], body: HTTP.whole(request.remote_addr.bytes))))
end

def upload(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  try HTTP.read_all(body, 1024)
  return ok(HTTP.Answer.Whole(try plain(request)))
end

def main() -> Void
  certs = System.args()[0]
  tls = TLS.server_context(TLS.ServerOptions(cert_file: certs + "/server.pem", key_file: certs + "/server-key.pem")).unwrap!
  servers = [
    HTTP.serve("localhost", 0, HTTP.app(&plain)).unwrap!,
    HTTP.serve("localhost", 0, &stream).unwrap!,
    HTTP.serve("localhost", 0, &upload).unwrap!,
    HTTP.serve_tls("localhost", 0, tls, HTTP.app(&plain)).unwrap!,
  ]
  ports = servers.map do |server| HTTP.local_port(server).to_s end
  puts(ports.join(" "))
  IO.flush()
  _ = IO.gets()
  servers.each do |server| HTTP.close_server(server) end
end
"""


def test_every_kind_of_server_gives_the_handler_the_clients_address_without_the_port(tmp_path, adopt):
    """http.client from 127.0.0.1 and ::1 (where IPv6 localhost exists; CI must have it) to serve on localhost, with a
    handler under HTTP.app, a stream, an app that reads the body itself, and serve_tls: each answers
    request.remote_addr."""
    hosts = ["127.0.0.1"]
    if ipv6_localhost():
        hosts.append("::1")
    elif os.environ.get("CI"):
        pytest.fail("no IPv6 localhost on this CI runner")
    vm = adopt(start_vm(compile_text(REMOTE_ADDR_PROGRAM, "remote-addr", tmp_path), CERTS, stdin=True))
    ports = [int(port) for port in vm.next_line().split()]
    context = ssl.create_default_context(cafile=str(CERTS / "ca.pem"))
    context.check_hostname = False  # the certificate names localhost, and the client dials an address
    seen = []
    for host in hosts:
        for kind, port in zip(["app", "stream", "upload", "tls"], ports):
            if kind == "tls":
                connection = http.client.HTTPSConnection(host, port, timeout=scaled(10), context=context)
            else:
                connection = http.client.HTTPConnection(host, port, timeout=scaled(10))
            connection.request("POST", "/", body=b"x")
            response = connection.getresponse()
            seen.append((kind, response.status, response.read().decode()))
            connection.close()
    assert seen == [(kind, 200, host) for host in hosts for kind in ["app", "stream", "upload", "tls"]]
    vm.close_stdin()
    assert vm.wait() == 0, vm.stderr_text()


# One `serve` server for every kind of route: a page through `HTTP.app` (with a 16-byte body limit, and 4 MiB on /big),
# a file sent in pieces with its length, an upload counted as it arrives (/upload, and /count, which answers 200 even
# when the body failed), and a WebSocket echo. Each upload and WebSocket end goes to stdout. Every body is at most 2 MiB
# (`max_body_bytes`).
SERVE_PROGRAM = """\
import HTTP from "std/http"

def page(request: HTTP.Request) -> Result[HTTP.Response]
  return ok(HTTP.Response(status: 200, headers: [], body: "page #{request.method} #{request.path} #{request.body.size}".bytes))
end

# 1000 bytes of the digit n.
def piece(n: Int) -> Bytes
  text = ""
  for _ in 0..999
    text = text + "#{n}"
  end

  return text.bytes
end

def produce(pieces: Channel[Bytes]) -> Void
  for n in 0..9
    if not Result.ok?(pieces.send(piece(n), 5000))
      break
    end
  end

  pieces.close
end

def file() -> HTTP.Answer
  pieces: Channel[Bytes] = Channel.new(2)
  Task.spawn(&produce, pieces)
  return HTTP.Answer.Stream(HTTP.StreamResponse(status: 200, headers: [], body: pieces, length: some(10000)))
end

def store(body: HTTP.RequestBody) -> Result[HTTP.Answer]
  total = 0
  while true
    case body.pieces.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  try Task.await(body.done)
  puts("stored #{total}")
  IO.flush()
  return ok(HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: "stored #{total}".bytes)))
end

# Counts the body as it arrives and says how `done` ended, then answers 200 whatever happened.
def count(body: HTTP.RequestBody) -> HTTP.Answer
  total = 0
  while true
    case body.pieces.recv(5000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end

  done = "ok"
  case Task.await(body.done)
    ok(_) -> done = "ok"
    error(e) -> done = e.message
  end
  puts("counted #{total} #{done}")
  IO.flush()
  return HTTP.Answer.Whole(HTTP.Response(status: 200, headers: [], body: "counted".bytes))
end

def echo(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(10000)
      ok(HTTP.Message.Text(text)) -> try ws.outgoing.send(HTTP.Message.Text("echo #{text}"), 5000)
      ok(HTTP.Message.Close(code, _)) ->
        puts("closed #{code}")
        IO.flush()
        return ok()
      ok(_) -> puts("other")
      error(_) -> return ok()
    end
  end

  return ok()
end

def handle(request: HTTP.Request, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  if request.path == "/ws"
    return ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &echo)))
  end

  if request.path == "/file"
    return ok(file())
  end

  if request.path == "/upload"
    return store(body)
  end

  if request.path == "/early"
    return ok(HTTP.Answer.Whole(HTTP.Response(status: 401, headers: [], body: "no".bytes)))
  end

  if request.path == "/count"
    return ok(count(body))
  end

  if request.path == "/big"
    return HTTP.app(&page, 4194304).call(request, body)
  end

  return HTTP.app(&page, 16).call(request, body)
end

def main() -> Void
  options = HTTP.ServerOptions(
    request_timeout_ms: 5000,
    idle_timeout_ms: 10000,
    max_connections: 16,
    max_body_bytes: 2097152,
  )
  server = HTTP.serve("127.0.0.1", 0, &handle, options).unwrap!
  certs = System.args()[0]
  tls = TLS.server_context(TLS.ServerOptions(cert_file: certs + "/server.pem", key_file: certs + "/server-key.pem")).unwrap!
  secure = HTTP.serve_tls("127.0.0.1", 0, tls, &handle, options).unwrap!
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
"""


def test_serve_answers_a_page_a_file_an_upload_and_a_websocket_on_one_port(tmp_path, adopt):
    """HTTP.serve: on one keep-alive connection of http.client, a page, a file sent in pieces with its Content-Length
    (and its HEAD), an upload of either framing counted as it arrives, and a small POST read whole by HTTP.app; a body
    over the limit of HTTP.app is a 413 that closes. Then a plain request and a WebSocket on one raw connection
    (fixtures/websocket_client.py), and a page, a file and an upload over serve_tls."""
    import http.client
    import ssl

    from tests.fixtures.websocket_client import TEXT, Client

    vm, port, tls_port = start_serve(tmp_path, adopt)
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=scaled(20))

    def ask(method, path, body=None, chunked=False):
        """The status and body of an answer, which must be framed by its Content-Length."""
        conn.request(method, path, body=body, encode_chunked=chunked)
        response = conn.getresponse()
        data = response.read()
        assert response.getheader("Content-Length") == str(len(data))
        return response.status, data

    assert ask("GET", "/") == (200, b"page GET / 0")
    local = conn.sock.getsockname()
    expected = b"".join(str(n).encode() * 1000 for n in range(10))
    assert ask("GET", "/file") == (200, expected)
    conn.request("HEAD", "/file")
    response = conn.getresponse()
    assert (response.status, response.getheader("Content-Length"), response.read()) == (200, "10000", b"")
    big = bytes(range(256)) * 4096
    assert ask("PUT", "/upload", big) == (200, b"stored 1048576")
    assert vm.next_line() == "stored 1048576"
    assert ask("PUT", "/upload", iter([big, b"tail"]), chunked=True) == (200, b"stored 1048580")
    assert vm.next_line() == "stored 1048580"
    assert ask("POST", "/", b"hello") == (200, b"page POST / 5")
    assert conn.sock.getsockname() == local, "every answer kept the connection"
    conn.request("POST", "/", body=b"x" * 17)
    response = conn.getresponse()
    assert (response.status, response.getheader("Connection")) == (413, "close")
    response.read()
    conn.close()

    with Client(port, timeout=scaled(10)) as c:
        status, _, _ = c.request("/", upgrade=False, version=None, key="none")
        assert status == 200
        c.connect("/ws")
        c.text("hi")
        assert c.message() == (TEXT, b"echo hi")
        c.close_with(1000)
        assert c.close_frame() == (1000, "")
        assert c.ended()
    assert vm.next_line() == "closed 1000"

    context = ssl.create_default_context(cafile=str(CERTS / "ca.pem"))
    conn = http.client.HTTPSConnection("localhost", tls_port, timeout=scaled(20), context=context)
    assert ask("GET", "/") == (200, b"page GET / 0")
    assert ask("GET", "/file") == (200, expected)
    assert ask("PUT", "/upload", iter([b"ab", b"cd"]), chunked=True) == (200, b"stored 4")
    assert vm.next_line() == "stored 4"
    conn.close()
    finish_serve(vm)


def test_serve_refuses_a_body_over_max_body_bytes_before_the_app_and_before_100_continue(tmp_path, adopt):
    """HTTP.serve: a Content-Length over max_body_bytes (2 MiB in SERVE_PROGRAM) with Expect: 100-continue gets a 413
    that closes, with no 100 first and no app run; a body within the cap gets its 100 and reaches the app. A chunked
    body that grows past the cap reaches a raw app only up to the cap, and then `done` fails; under HTTP.app, whose own
    limit is higher, it is a 413. Each of these answers closes the connection."""
    vm, port, _ = start_serve(tmp_path, adopt)
    cap = 2097152

    def closing_status(request):
        """Sends `request` and returns the status of the answer, which must close the connection."""
        with socket.create_connection(("127.0.0.1", port), timeout=scaled(10)) as conn:
            try:
                conn.sendall(request)
            except OSError:
                pass  # the server may close before it took every byte; its answer is still read
            head, _ = raw_answer(conn, True)
            assert b"\r\nconnection: close" in head, head
            return head.split(b" ")[1]

    assert closing_status(b"PUT /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n"
                          b"Content-Length: %d\r\n\r\n" % (cap + 1)) == b"413"
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(10)) as conn:
        conn.sendall(b"PUT /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
        head, rest = raw_answer(conn, False)
        assert head.startswith(b"http/1.1 100"), head
        conn.sendall(b"abcd")
        got = rest
        while not got.endswith(b"stored 4"):
            more = conn.recv(65536)
            assert more, "the connection closed: %r" % got
            got += more
        assert b"http/1.1 200" in got.lower(), got
    assert vm.next_line() == "stored 4", "only the body within the cap reached the app"
    over = b"%x\r\n%s\r\n1\r\nz\r\n0\r\n\r\n" % (cap, b"x" * cap)
    chunked = b"Host: x\r\nTransfer-Encoding: chunked\r\n\r\n"
    assert closing_status(b"PUT /count HTTP/1.1\r\n" + chunked + over) == b"200"
    assert vm.next_line() == "counted %d http: body exceeds max_bytes" % cap
    assert closing_status(b"PUT /big HTTP/1.1\r\n" + chunked + over) == b"413"
    finish_serve(vm)


def start_serve(tmp_path, adopt):
    source = tmp_path / "serve.agc"
    source.write_text(SERVE_PROGRAM, encoding="utf-8")
    vm = adopt(start_vm(compile_agc(source, tmp_path / "serve.agcb"), CERTS, stdin=True))
    port, tls_port = vm.next_line().split()
    return vm, int(port), int(tls_port)


def finish_serve(vm):
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"
    assert vm.next_line() == "ok()"
    assert vm.next_line() == "ok()"


def raw_answer(conn, until_close):
    """The head (lower case) of the next answer on a raw socket, and its Content-Length body; with `until_close`,
    everything up to the close."""
    got = b""
    while b"\r\n\r\n" not in got or until_close:
        more = conn.recv(65536)
        if not more:
            break
        got += more
    head, _, rest = got.partition(b"\r\n\r\n")
    return head.lower(), rest


def test_serve_keeps_a_connection_only_for_a_body_that_arrived_and_upgrades_only_then(tmp_path, adopt):
    """HTTP.serve: an empty chunked body that the app never reads still counts as read, so the connection stays, and a
    handshake with an empty chunked body upgrades. An answer that comes before the body arrived says `Connection:
    close` and the connection ends; an upgrade while the body is still coming is a 500 that closes, with a warning."""
    vm, port, _ = start_serve(tmp_path, adopt)
    upgrade = b"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
    key = b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    chunked = b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(10)) as conn:
        conn.sendall(b"POST /early HTTP/1.1\r\nHost: x\r\n" + chunked)
        head, rest = raw_answer(conn, False)
        assert head.split(b" ")[1] == b"401" and b"connection: close" not in head, head
        while len(rest) < 2:
            rest += conn.recv(65536)
        conn.sendall(b"GET /ws HTTP/1.1\r\nHost: x\r\n" + upgrade + key + chunked)
        head, _ = raw_answer(conn, False)
        assert head.split(b" ")[1] == b"101", head
    for request, status in [(b"PUT /early HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n" + b"x" * 1000, b"401"),
                            (b"GET /ws HTTP/1.1\r\nHost: x\r\n" + upgrade + key + b"Content-Length: 10\r\n\r\n", b"500")]:
        with socket.create_connection(("127.0.0.1", port), timeout=scaled(10)) as conn:
            conn.sendall(request)
            head, _ = raw_answer(conn, True)
            assert head.split(b" ")[1] == status, head
            assert b"\r\nconnection: close" in head, head
    assert vm.next_line() == "closed 1006"
    finish_serve(vm)
    assert "http: invalid response: an upgrade before the request body was read" in vm.stderr_text()
