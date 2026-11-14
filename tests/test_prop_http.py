"""Property tests (Hypothesis) of the VM HTTP server and client against Python's http.client and raw sockets.

The profiles and the seed of each tier are in tests/conftest.py. One VM serves every example of a run.
"""
import contextlib
import http.client
import queue
import re
import socket
import threading
import time
from importlib.util import find_spec

import pytest

from tests.agentica_test import compile_agc, require, scaled, start_vm, timeout
from tests.test_vm_http import read_after_close

# make test falls back to the system pytest when Poetry is missing, and that one may lack Hypothesis: the module then
# skips at import locally and fails in CI.
require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import example, given, strategies as st  # noqa: E402

HEADER_ECHO_PROGRAM = """\
import HTTP from "std/http"

# The request body, read as UTF-8, goes back as the value of X-Out.
def handle(request: HTTP.Request) -> Result[HTTP.Response]
  value = try String.from_bytes(request.body)
  return ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "X-Out", value: value)], body: "".bytes))
end

def main() -> Void
  options = HTTP.ServerOptions(request_timeout_ms: 10000, idle_timeout_ms: 10000, max_connections: 4, max_body_bytes: 65536)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  port = HTTP.local_port(server)
  puts(port)
  IO.flush()
  client = HTTP.client(HTTP.ClientOptions(timeout_ms: 10000, idle_timeout_ms: 10000, max_connections: 1, max_body_bytes: 65536, tls: none)).unwrap!
  # Each line is a case number and the hex of one value. The answer repeats the number, then the status and the hex of
  # the X-Out the client read (or "-"), or "error" and why the request failed.
  while !IO.eof?
    words = gets!.split(" ")
    case HTTP.post(client, "http://127.0.0.1:#{port}/", OpenSSL.Digest.hexdecode(words[1]).unwrap!)
      ok(reply) ->
        out = reply.headers.detect do |h| h.name == "x-out" end
        shown = "-"
        if out.ok?
          shown = OpenSSL.Digest.hexencode(out.unwrap!.value.bytes)
        end
        puts("#{words[0]} #{reply.status} #{shown}")
      error(message) -> puts("#{words[0]} error #{message}")
    end
    IO.flush()
  end
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
"""

# The longest value the server sends: the line "X-Out: <value>" is at most AGC_HTTP_MAX_LINE (8192) bytes on the wire.
MAX_HEADER_VALUE = 8192 - len("X-Out: ")
HEADER_CHARS = st.one_of(
    st.characters(min_codepoint=0x20, max_codepoint=0x7E),
    st.characters(min_codepoint=0x80, max_codepoint=0xFF),  # obs-text: one byte each on the wire
    st.characters(max_codepoint=0x1F) | st.just("\x7f"),  # control characters; only tab is allowed
    st.characters(min_codepoint=0x100, exclude_categories=("Cs",)),  # no surrogates: the body that carries it is UTF-8
)
HEADER_VALUES = st.one_of(
    st.text(HEADER_CHARS, max_size=20),
    # Around the line limit: one character (ASCII or Latin-1) repeated up to it, then a short tail.
    st.builds(lambda fill, count, tail: fill * count + tail, st.sampled_from("aé"),
              st.integers(MAX_HEADER_VALUE - 3, MAX_HEADER_VALUE), st.text(HEADER_CHARS, max_size=3)),
)


def sendable_header_value(value):
    """RFC 9110 5.5 field-value within the line limit: Latin-1 with no control character but tab."""
    return len(value) <= MAX_HEADER_VALUE and all(c == "\t" or " " <= c <= "\xff" and c != "\x7f" for c in value)


class EchoVm:
    """HEADER_ECHO_PROGRAM and its port. Each case carries a number, so an answer that came after its case timed out is
    skipped instead of being read as the answer of the next case."""

    def __init__(self, vm):
        self.vm = vm
        self.port = int(vm.next_line())
        self.cases = 0

    def client_read(self, body):
        """The VM client's POST of `body`: its status and the X-Out it read (None when absent), or "error" and why."""
        assert self.vm.process.poll() is None, "the VM ended (exit %r)" % self.vm.process.poll()
        self.cases += 1
        self.vm.process.stdin.write(b"%d %s\n" % (self.cases, body.hex().encode("ascii")))
        self.vm.process.stdin.flush()
        while True:
            line = self.vm.next_line(timeout=scaled(30))
            parts = line.split(" ", 2)
            assert len(parts) == 3, "unexpected line from the VM: %r" % line
            number, status, shown = parts
            if number == str(self.cases):
                break
        if status == "error":
            return status, shown
        return status, None if shown == "-" else bytes.fromhex(shown).decode("utf-8")


@pytest.fixture(scope="module")
def header_echo(tmp_path_factory):
    """One EchoVm for every example of the property."""
    directory = tmp_path_factory.mktemp("header-echo")
    source = directory / "header-echo.agc"
    source.write_text(HEADER_ECHO_PROGRAM, encoding="utf-8")
    vm = start_vm(compile_agc(source, directory / "header-echo.agcb"), stdin=True)
    try:
        yield EchoVm(vm)
        vm.close_stdin()
        assert vm.wait() == 0, "the VM server finishes"
        assert vm.next_line() == "ok()"
    finally:
        vm.stop()


# 1000 examples of the slow tier took about 4 s on a laptop; the limit leaves room for a busy runner and the shrinking
# of a failure, so the Hypothesis report and its seed are printed rather than cut by the per-test limit.
@timeout(300)
@given(HEADER_VALUES)
@example("a" * MAX_HEADER_VALUE)
@example("a" * (MAX_HEADER_VALUE + 1))
@example("é" * MAX_HEADER_VALUE)
@example("é" * (MAX_HEADER_VALUE + 1))
def test_server_sends_a_header_value_only_when_it_is_valid_and_both_clients_read_it_back(header_echo, value):
    """Property (#1184): the server sends a value if and only if it is a valid field value, else it answers 500. A
    value it sends is its Latin-1 bytes on the wire, and http.client and the VM client read back the same text, without
    the spaces and tabs around it (RFC 9110 5.5; http.client keeps those at the end)."""
    body = value.encode("utf-8")
    sent = sendable_header_value(value)
    got = read_after_close(header_echo.port, b"POST / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
                           b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
    head = got.partition(b"\r\n\r\n")[0] + b"\r\n"
    if sent:
        assert head.startswith(b"HTTP/1.1 200 ") and b"\r\nX-Out: " + value.encode("latin-1") + b"\r\n" in head, head
    else:
        assert head.startswith(b"HTTP/1.1 500 ") and b"X-Out" not in head, head
    conn = http.client.HTTPConnection("127.0.0.1", header_echo.port, timeout=scaled(10))
    try:
        conn.request("POST", "/", body=body)
        reply = conn.getresponse()
        reply.read()
        assert reply.status == (200 if sent else 500)
        if sent:
            assert reply.getheader("X-Out").rstrip(" \t") == value.strip(" \t")
    finally:
        conn.close()
    assert header_echo.client_read(body) == (("200", value.strip(" \t")) if sent else ("500", None))


REQUEST_ECHO_PROGRAM = """\
import HTTP from "std/http"

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

# The answer is the request as the app saw it: method, target and path, a line per header, then the body, each in hex.
def handle(request: HTTP.Request) -> Result[HTTP.Response]
  lines = ["#{hex(request.method.bytes)} #{hex(request.target.bytes)} #{hex(request.path.bytes)}"]
  for h in request.headers
    lines = lines.push("#{hex(h.name.bytes)} #{hex(h.value.bytes)}")
  end

  lines = lines.push(hex(request.body))
  ok(HTTP.Response(status: 200, headers: [], body: lines.join("\\n").bytes))
end

def main() -> Void
  options = HTTP.ServerOptions(request_timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 8, max_body_bytes: 65536)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  puts(HTTP.local_port(server))
  IO.flush()
  _ = gets
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
"""

CLIENT_PROGRAM = """\
import HTTP from "std/http"

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def shown(result: Result[HTTP.Response]) -> String
  case result
    ok(r) ->
      parts = ["ok", r.status.to_s]
      for h in r.headers
        parts = parts.push("#{hex(h.name.bytes)}:#{hex(h.value.bytes)}")
      end

      parts = parts.push(hex(r.body))
      parts.join(" ")
    error(e) -> "error #{hex(e.message.bytes)}"
  end
end

# Each line is a case number, a method and a URL. The answer repeats the number, then "ok", the status, a name:value
# per header and the body, each in hex, or "error" and the hex of why.
def main() -> Void
  client = HTTP.client(HTTP.ClientOptions(timeout_ms: 5000, max_body_bytes: 65536, max_connections: 1)).unwrap!
  while !IO.eof?
    words = gets!.split(" ")
    puts("#{words[0]} #{shown(HTTP.request(client, words[1], words[2], "".bytes))}")
    IO.flush()
  end

  HTTP.close_client(client)
end
"""

TOKEN_CHARS = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
TOKENS = st.text(TOKEN_CHARS, min_size=1, max_size=8)
FRAMING_NAMES = ("content-length", "transfer-encoding", "connection", "host", "expect", "upgrade", "te", "trailer")
# Field values without the spaces around them: visible ASCII, obs-text, and spaces and tabs inside.
FIELD_VALUES = st.text(st.characters(min_codepoint=0x21, max_codepoint=0x7E)
                       | st.characters(min_codepoint=0x80, max_codepoint=0xFF) | st.sampled_from(" \t"),
                       max_size=12).map(lambda value: value.strip(" \t"))
FIELDS = st.lists(st.tuples(TOKENS.filter(lambda n: n.lower() not in FRAMING_NAMES), FIELD_VALUES), max_size=5)
SPACES = st.sampled_from(["", " ", "\t", "  ", " \t"])


@st.composite
def pieces(draw, data):
    """`data` cut at a few random places, as TCP may deliver it."""
    cuts = sorted(draw(st.sets(st.integers(1, max(1, len(data) - 1)), max_size=4))) if len(data) > 1 else []
    return [data[a:b] for a, b in zip([0, *cuts], [*cuts, len(data)])]


@st.composite
def chunked(draw, body, extension=True):
    """`body` as chunks of random sizes, with chunk extensions, an optional trailer section, and the hex in any case."""
    out = b""
    at = 0
    while at < len(body):
        size = draw(st.integers(1, 64))
        chunk = body[at:at + size]
        at += size
        digits = draw(st.sampled_from(["%x", "%X", "%04x"])) % len(chunk)
        ext = draw(st.sampled_from([b"", b";a=b", b';x="y z"', b";n"])) if extension else b""
        out += digits.encode("ascii") + ext + b"\r\n" + chunk + b"\r\n"
    trailers = draw(st.lists(st.tuples(TOKENS.filter(lambda n: n.lower() not in FRAMING_NAMES), FIELD_VALUES),
                             max_size=2))
    return out + b"0\r\n" + b"".join(b"%s: %s\r\n" % (n.encode(), v.encode("latin-1")) for n, v in trailers) + b"\r\n"


@st.composite
def requests(draw):
    """A valid request with Connection: close, and the method, target, headers and body the app must see."""
    method = draw(st.sampled_from(["GET", "POST", "PUT", "DELETE", "PATCH"]) | TOKENS.filter(lambda m: m != "CONNECT"))
    target = "/" + draw(st.text("abc/%?=&;:@!$'()*+,-._~", max_size=12))
    fields = draw(FIELDS)
    body = draw(st.binary(max_size=300))
    head = "%s %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" % (method, target)
    head += "".join("%s:%s%s%s\r\n" % (n, draw(SPACES), v, draw(SPACES)) for n, v in fields)
    seen = [("host", "x"), ("connection", "close")] + [(n.lower(), v) for n, v in fields]
    if draw(st.booleans()):
        raw = (head + "Transfer-Encoding: chunked\r\n\r\n").encode("latin-1") + draw(chunked(body))
        seen.append(("transfer-encoding", "chunked"))
    else:
        raw = (head + "Content-Length: %d\r\n\r\n" % len(body)).encode("latin-1") + body
        seen.append(("content-length", str(len(body))))
    return raw, (method, target, target.partition("?")[0], seen, body)


def send_pieces(port, parts):
    """Send `parts` with a pause between them, close the write side and return what came back before the close."""
    with socket.create_connection(("127.0.0.1", port), timeout=scaled(10)) as conn:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        for part in parts:
            conn.sendall(part)
            time.sleep(0.001)
        conn.shutdown(socket.SHUT_WR)
        got = b""
        try:
            while chunk := conn.recv(65536):
                got += chunk
        except ConnectionResetError:
            pass
    return got


def seen_by_app(answer):
    lines = answer.partition(b"\r\n\r\n")[2].decode("ascii").split("\n")
    method, target, path = (bytes.fromhex(word).decode("utf-8") for word in lines[0].split(" "))
    fields = [tuple(bytes.fromhex(word).decode("utf-8") for word in line.split(" ")) for line in lines[1:-1]]
    return method, target, path, fields, bytes.fromhex(lines[-1])


@pytest.fixture(scope="module")
def request_echo(tmp_path_factory):
    """The port of one REQUEST_ECHO_PROGRAM server for every example."""
    directory = tmp_path_factory.mktemp("request-echo")
    source = directory / "request-echo.agc"
    source.write_text(REQUEST_ECHO_PROGRAM, encoding="utf-8")
    vm = start_vm(compile_agc(source, directory / "request-echo.agcb"), stdin=True)
    try:
        yield int(vm.next_line())
        vm.process.stdin.write(b"\n")
        vm.close_stdin()
        assert vm.wait() == 0, "the VM server finishes"
        assert vm.next_line() == "ok()"
    finally:
        vm.stop()


@timeout(300)
@given(requests().flatmap(lambda case: st.tuples(pieces(case[0]), st.just(case[1]))))
def test_server_reads_a_valid_request_whole_however_it_arrives(request_echo, case):
    """Property: the app sees the method, target, path, lowercase header names, values without the spaces around them
    and the body of any valid request, whether the body comes with Content-Length or chunked (with extensions and
    trailers), and wherever TCP cuts the bytes."""
    parts, want = case
    answer = send_pieces(request_echo, parts)
    assert answer.startswith(b"HTTP/1.1 200 "), (b"".join(parts), answer[:200])
    assert seen_by_app(answer) == want, b"".join(parts)


@st.composite
def damaged(draw, data):
    """`data` with one to three bytes put in, taken out or changed."""
    data = bytearray(data)
    for _ in range(draw(st.integers(1, 3))):
        at = draw(st.integers(0, len(data)))
        byte = draw(st.sampled_from(b"\r\n :;0\x00\x7f\xff") | st.integers(0, 255))
        kind = draw(st.sampled_from(["insert", "delete", "change"]))
        if kind == "insert":
            data[at:at] = bytes([byte])
        elif at < len(data):
            if kind == "delete":
                del data[at]
            else:
                data[at] = byte
    return bytes(data)


@timeout(300)
@given(requests().flatmap(lambda case: damaged(case[0])).flatmap(lambda raw: st.tuples(st.just(raw), pieces(raw))))
def test_server_answers_a_damaged_request_with_responses_or_a_close(request_echo, case):
    """Property: a request with bytes put in, taken out or changed gets whole HTTP/1.1 responses or a plain close,
    never a hang, a crash or other bytes. A damaged head can leave bytes that read as a next request, so there may be
    more than one response, and only the last may refuse (4xx or 5xx, with Connection: close). The first 200 shows the
    method and target of the request line."""
    raw, parts = case
    answer = send_pieces(request_echo, parts)
    replies = []
    while answer:
        head, _, rest = answer.partition(b"\r\n\r\n")
        assert head.startswith(b"HTTP/1.1 ") and rest is not None, (raw, answer[:200])
        length = re.search(rb"\r\nContent-Length: (\d+)\r", head + b"\r")
        assert length, (raw, head)
        replies.append((int(head[9:12]), head + b"\r\n", rest[:int(length[1])]))
        answer = rest[int(length[1]):]
    for status, head, _ in replies[:-1]:
        assert status == 200, (raw, replies)
    if replies and replies[-1][0] != 200:
        status, head, _ = replies[-1]
        assert 400 <= status < 600 and b"\r\nConnection: close\r\n" in head, (raw, replies)
    if replies and replies[0][0] == 200:
        method, target, _, _, _ = seen_by_app(replies[0][1] + b"\r\n" + replies[0][2])
        line = raw.removeprefix(b"\r\n").partition(b"\r\n")[0]
        assert line.split(b" ")[0] == method.encode() and target.encode() in line.split(b" "), (raw, replies)


class ResponsePeer:
    """A raw socket HTTP server for the VM client: each request head it reads gets the next planned response, sent in
    the planned pieces, and the connection closes after it when the plan says so."""

    def __init__(self):
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.plans = queue.Queue()
        self.conn = None
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            self.conn = conn
            with conn:
                conn.settimeout(scaled(10))
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                buffer = b""
                try:
                    while True:
                        while b"\r\n\r\n" not in buffer:
                            chunk = conn.recv(65536)
                            if not chunk:
                                raise ConnectionResetError
                            buffer += chunk
                        buffer = buffer.partition(b"\r\n\r\n")[2]
                        parts, close = self.plans.get(timeout=scaled(10))
                        for part in parts:
                            conn.sendall(part)
                            time.sleep(0.001)
                        if close:
                            break
                except (OSError, queue.Empty):
                    pass

    def close(self):
        for sock in (self.listener, self.conn):
            if sock is not None:
                with contextlib.suppress(OSError):
                    sock.shutdown(socket.SHUT_RDWR)
        with contextlib.suppress(OSError):
            socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
        self.thread.join(5)
        self.listener.close()


class ClientVm:
    def __init__(self, vm, peer):
        self.vm = vm
        self.peer = peer
        self.cases = 0

    def fetch(self, method, parts, close):
        """The VM client's request: ("ok", status, headers, body) or ("error", why)."""
        assert self.vm.process.poll() is None, "the VM ended (exit %r)" % self.vm.process.poll()
        self.peer.plans.put((parts, close))
        self.cases += 1
        self.vm.process.stdin.write(b"%d %s http://127.0.0.1:%d/x\n" % (self.cases, method.encode(), self.peer.port))
        self.vm.process.stdin.flush()
        number, status, *rest = self.vm.next_line(timeout=scaled(30)).split(" ")
        assert number == str(self.cases)
        if status == "error":
            return status, bytes.fromhex(rest[0]).decode("utf-8")
        headers = [tuple(bytes.fromhex(word).decode("utf-8") for word in field.split(":")) for field in rest[1:-1]]
        return status, int(rest[0]), headers, bytes.fromhex(rest[-1])


@pytest.fixture(scope="module")
def client_vm(tmp_path_factory):
    directory = tmp_path_factory.mktemp("client")
    source = directory / "client.agc"
    source.write_text(CLIENT_PROGRAM, encoding="utf-8")
    peer = ResponsePeer()
    vm = start_vm(compile_agc(source, directory / "client.agcb"), stdin=True)
    try:
        yield ClientVm(vm, peer)
        vm.close_stdin()
        assert vm.wait() == 0, vm.stderr_text()
    finally:
        vm.stop()
        peer.close()


@st.composite
def responses(draw):
    """A valid response to `method`, whether the connection closes after it, and what the client must read."""
    method = draw(st.sampled_from(["GET", "HEAD", "DELETE"]))
    status = draw(st.sampled_from([200, 201, 204, 304, 404, 418, 500, 599]) | st.integers(200, 599))
    reason = draw(st.sampled_from(["OK", "", "Some Reason", "x\x80y"]))
    fields = draw(FIELDS)
    body = draw(st.binary(max_size=300))
    framing = draw(st.sampled_from(["length", "chunked", "close"]))
    close = framing == "close" or draw(st.booleans())
    interim = draw(st.sampled_from([b"", b"HTTP/1.1 100 Continue\r\n\r\n",
                                    b"HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n"]))
    head = "HTTP/1.1 %d%s\r\n" % (status, " " + reason if reason or draw(st.booleans()) else "")
    head += "".join("%s:%s%s%s\r\n" % (n, draw(SPACES), v, draw(SPACES)) for n, v in fields)
    seen = [(n.lower(), v) for n, v in fields]
    if framing == "length":
        head += "Content-Length: %d\r\n" % len(body)
        seen.append(("content-length", str(len(body))))
    elif framing == "chunked":
        head += "Transfer-Encoding: chunked\r\n"
        seen.append(("transfer-encoding", "chunked"))
    if close:
        head += "Connection: close\r\n"
        seen.append(("connection", "close"))
    raw = interim + head.encode("latin-1") + b"\r\n"
    empty = method == "HEAD" or status in (204, 304)
    if not empty:
        raw += draw(chunked(body)) if framing == "chunked" else body
    return method, raw, close, (status, seen, b"" if empty else body)


@timeout(300)
@given(responses().flatmap(lambda case: st.tuples(st.just(case), pieces(case[1]))))
def test_client_reads_a_valid_response_whole_however_it_arrives(client_vm, case):
    """Property: the VM client reads the status, lowercase header names, values without the spaces around them and the
    body of any valid response (Content-Length, chunked or until the close; after 1xx heads; none for HEAD, 204 and
    304), on a new or a kept connection, wherever TCP cuts the bytes."""
    (method, raw, close, (status, seen, body)), parts = case
    assert client_vm.fetch(method, parts, close) == ("ok", status, seen, body), raw


@timeout(300)
@given(responses().flatmap(lambda case: st.tuples(st.just(case[0]), damaged(case[1]))))
def test_client_survives_a_damaged_response(client_vm, case):
    """Property: a response with bytes put in, taken out or changed gives a response or an error, never a hang or a
    crash, and the client then reads a valid response on a new connection."""
    method, raw = case
    client_vm.fetch(method, [raw], True)
    assert client_vm.fetch("GET", [b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"], False) == (
        "ok", 200, [("content-length", "2")], b"ok")
