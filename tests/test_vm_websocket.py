"""The VM's WebSocket server (HTTP.serve) against fixtures/websocket_client.py, a RFC 6455 client of its own.

One VM program serves every route. The client writes frames by hand, so the tests send what a correct client never
would and read the close codes the server answers with. Everything is on 127.0.0.1 with port 0.
"""
import ssl
import struct
import threading
import time
from collections import Counter

import pytest

from tests.agentica_test import FIXTURES, compile_agc, scaled, start_vm
from tests.fixtures.websocket_client import BINARY, CLOSE, CONTINUATION, PING, PONG, TEXT, Client

CERTS = FIXTURES / "tls"
SCHEDULERS = [(), ("--schedulers", "4")]

SERVER_PROGRAM = """\
import HTTP from "std/http"

# Echoes text and binary, tells stdout about pongs and the end.
def relay(ws: HTTP.WebSocket, message: HTTP.Message) -> Result[Bool]
  case message
    HTTP.Message.Text(text) ->
      try ws.outgoing.send(HTTP.Message.Text(text), 5000)
      return ok(true)
    HTTP.Message.Binary(data) ->
      try ws.outgoing.send(HTTP.Message.Binary(data), 5000)
      return ok(true)
    HTTP.Message.Pong(data) ->
      puts("pong #{data.size}")
      IO.flush()
      return ok(true)
    HTTP.Message.Ping(_) -> return ok(true)
    HTTP.Message.Close(code, reason) ->
      puts("closed #{code} #{reason}")
      IO.flush()
      return ok(false)
  end
end

def echo(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(10000)
      ok(message) ->
        if not try relay(ws, message)
          return ok()
        end
      error(_) -> return ok()
    end
  end

  return ok()
end

# The server speaks first, then closes with a reason and waits for the peer's close.
def greet(ws: HTTP.WebSocket) -> Result[Void]
  try ws.outgoing.send(HTTP.Message.Text("hello"), 5000)
  try ws.outgoing.send(HTTP.Message.Close(4001, "bye"), 5000)
  return echo(ws)
end

def pinging(ws: HTTP.WebSocket) -> Result[Void]
  try ws.outgoing.send(HTTP.Message.Ping("abc".bytes), 5000)
  return echo(ws)
end

def protocol(ws: HTTP.WebSocket) -> Result[Void]
  try ws.outgoing.send(HTTP.Message.Text("protocol [#{ws.protocol}]"), 5000)
  return echo(ws)
end

# Says nothing for longer than the interval of the pings, then speaks: a quiet outgoing channel must not end the session.
def late(ws: HTTP.WebSocket) -> Result[Void]
  Task.sleep(700)
  try ws.outgoing.send(HTTP.Message.Text("late"), 5000)
  return echo(ws)
end

# Waits for any message of the peer.
def await_go(ws: HTTP.WebSocket) -> Result[Void]
  case ws.incoming.recv(10000)
    ok(_) -> return ok()
    error(message) -> return error(message)
  end
end

# A burst of numbered texts with a ping now and then and a close at the end, sent faster than the writer takes them.
# Half way it waits for the peer's "go", which the peer sends after a ping, so the pong is queued before the close.
# What the handler sends after its close is dropped, and its sends do not fail.
def burst(ws: HTTP.WebSocket) -> Result[Void]
  i = 0
  while i < 1000
    if i == 500
      try await_go(ws)
    end

    try ws.outgoing.send(HTTP.Message.Text("m#{i}"), 5000)
    if i % 100 == 99
      try ws.outgoing.send(HTTP.Message.Ping("p#{i}".bytes), 5000)
    end
    i = i + 1
  end

  try ws.outgoing.send(HTTP.Message.Close(4002, "done"), 5000)
  _ = ws.outgoing.send(HTTP.Message.Text("after 1"), 5000)
  _ = ws.outgoing.send(HTTP.Message.Binary("after 2".bytes), 5000)
  return echo(ws)
end

# Queues 128 KiB messages without waiting, until the queue is full or 400 are in, and says how many it took: a peer that
# does not read fills the socket, then the writer waits, then the queue fills.
def fill(ws: HTTP.WebSocket) -> Result[Void]
  padding = "x" * 131072
  sent = 0
  while sent < 400
    case ws.outgoing.send(HTTP.Message.Binary("#{sent}:#{padding}".bytes), 0)
      ok(_) -> sent = sent + 1
      error(_) -> break
    end
  end

  puts("accepted #{sent}")
  IO.flush()
  try ws.outgoing.send(HTTP.Message.Close(4003, "end"), 5000)
  return echo(ws)
end

# Closes its own outgoing channel: the writer then waits for the peer's end alone.
def shut(ws: HTTP.WebSocket) -> Result[Void]
  ws.outgoing.close
  return echo(ws)
end

# Queues a big message that fills the socket (the peer does not read), then A, a close of its own and B behind it.
def order(ws: HTTP.WebSocket) -> Result[Void]
  padding = "x" * 16000000
  _ = ws.outgoing.send(HTTP.Message.Binary(padding.bytes), 0)
  try ws.outgoing.send(HTTP.Message.Text("A"), 5000)
  try ws.outgoing.send(HTTP.Message.Close(4000, "bye"), 5000)
  try ws.outgoing.send(HTTP.Message.Text("B"), 5000)
  puts("queued")
  IO.flush()
  return echo(ws)
end

# Queues, behind a write that blocks (the peer does not read), 16 MB, "A", five of 100 KB and 300 of 1 KB, then waits.
def pile(ws: HTTP.WebSocket) -> Result[Void]
  padding = "x" * 16000000
  _ = ws.outgoing.send(HTTP.Message.Binary(padding.bytes), 0)
  try ws.outgoing.send(HTTP.Message.Text("A"), 5000)
  piece = ("p" * 100000).bytes
  small = ("s" * 1000).bytes
  i = 0
  while i < 5
    try ws.outgoing.send(HTTP.Message.Binary(piece), 5000)
    i = i + 1
  end

  while i < 305
    try ws.outgoing.send(HTTP.Message.Binary(small), 5000)
    i = i + 1
  end

  puts("queued")
  IO.flush()
  return echo(ws)
end

# A close that a session can build and that looks like what the server keeps for itself: it is sent as any invalid code.
def fakewake(ws: HTTP.WebSocket) -> Result[Void]
  try ws.outgoing.send(HTTP.Message.Text("a"), 5000)
  try ws.outgoing.send(HTTP.Message.Close(0, "wake"), 5000)
  return echo(ws)
end

# Messages that cross the 64 KiB a write takes: small, one that crosses it, big, small, and sizes at the edge.
def edge(ws: HTTP.WebSocket) -> Result[Void]
  sizes = [100, 65400, 70000, 8, 65536, 65535, 9, 65530]
  i = 0
  while i < sizes.size
    head = "e#{i}:"
    try ws.outgoing.send(HTTP.Message.Binary((head + "x" * (sizes[i] - head.size)).bytes), 5000)
    i = i + 1
  end

  try ws.outgoing.send(HTTP.Message.Close(4004, "edge"), 5000)
  return echo(ws)
end

def failing(ws: HTTP.WebSocket) -> Result[Void]
  return error("the session failed")
end

def plain(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "plain #{request.path}".bytes))
end

def route(request: HttpRequest) -> Result[HTTP.Upgrade]
  if request.path == "/echo"
    return HTTP.accept_websocket(request, &echo)
  end

  if request.path == "/small"
    return HTTP.accept_websocket(request, &echo, HTTP.WebSocketOptions(max_message_bytes: 1000))
  end

  if request.path == "/idle"
    return HTTP.accept_websocket(request, &echo, HTTP.WebSocketOptions(idle_ms: 400))
  end

  if request.path == "/keepalive"
    return HTTP.accept_websocket(request, &echo, HTTP.WebSocketOptions(idle_ms: 600, ping_ms: 200))
  end

  if request.path == "/late"
    return HTTP.accept_websocket(request, &late, HTTP.WebSocketOptions(ping_ms: 150, idle_ms: 3000))
  end

  if request.path == "/forged"
    return ok(HTTP.Upgrade.Accept(&echo, HTTP.WebSocketOptions(), "forged", ""))
  end

  if request.path == "/badoptions"
    return HTTP.accept_websocket(request, &echo, HTTP.WebSocketOptions(max_message_bytes: 0))
  end

  if request.path == "/greet"
    return HTTP.accept_websocket(request, &greet, HTTP.WebSocketOptions(close_ms: 300))
  end

  if request.path == "/ping"
    return HTTP.accept_websocket(request, &pinging)
  end

  if request.path == "/protocol"
    return HTTP.accept_websocket(request, &protocol, HTTP.WebSocketOptions(protocols: ["chat", "superchat"]))
  end

  if request.path == "/fail"
    return HTTP.accept_websocket(request, &failing)
  end

  if request.path == "/order"
    return HTTP.accept_websocket(request, &order)
  end

  if request.path == "/pile"
    return HTTP.accept_websocket(request, &pile, HTTP.WebSocketOptions(outgoing_queue: 400))
  end

  if request.path == "/fakewake"
    return HTTP.accept_websocket(request, &fakewake)
  end

  if request.path == "/edge"
    return HTTP.accept_websocket(request, &edge, HTTP.WebSocketOptions(outgoing_queue: 16))
  end

  if request.path == "/shut"
    return HTTP.accept_websocket(request, &shut)
  end

  if request.path == "/burst"
    return HTTP.accept_websocket(request, &burst, HTTP.WebSocketOptions(outgoing_queue: 256))
  end

  if request.path == "/fill-small"
    return HTTP.accept_websocket(request, &fill, HTTP.WebSocketOptions(outgoing_queue: 2))
  end

  if request.path == "/fill-big"
    return HTTP.accept_websocket(request, &fill, HTTP.WebSocketOptions(outgoing_queue: 1000))
  end

  if request.path == "/badqueue"
    return HTTP.accept_websocket(request, &echo, HTTP.WebSocketOptions(outgoing_queue: 0))
  end

  return ok(HTTP.Upgrade.Reply(try plain(request)))
end

def app(request: HttpRequest, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  return ok(HTTP.Answer.Upgrade(try route(request)))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: WRITE_MS, idle_timeout_ms: 10000, max_connections: 16)
  server = Result.unwrap!(HTTP.serve("127.0.0.1", 0, &app, options))
  certs = System.args()[0]
  secure = Result.unwrap!(HTTP.serve_tls("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: certs + "/server.pem", key_file: certs + "/server-key.pem")).unwrap!, &app, options))
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
"""


# The server's request_timeout_ms, which bounds each write: the 16 MB messages must reach the peer within it.
WRITE_MS = scaled(2000)
# The receive buffer of a peer that reads a 16 MB message: small, as on macOS, so the write is partial many times.
SMALL_BUFFER = 65536


def start_server(tmp_path, adopt, flags=()):
    source = tmp_path / "websocket-server.agc"
    source.write_text(SERVER_PROGRAM.replace("WRITE_MS", str(WRITE_MS)), encoding="utf-8")
    vm = adopt(start_vm(compile_agc(source, tmp_path / "websocket-server.agcb"), CERTS, flags=flags, stdin=True))
    port, tls_port = vm.next_line().split()
    return vm, int(port), int(tls_port)


def closing(vm):
    """The `closed` line of the handler that ended last, with the `pong` lines before it."""
    lines = []
    while not lines or not lines[-1].startswith("closed "):
        lines.append(vm.next_line())
    return lines


def finish(vm):
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"
    assert vm.next_line() == "ok()"
    assert vm.next_line() == "ok()"


@pytest.mark.parametrize("flags", SCHEDULERS, ids=["one-scheduler", "four-schedulers"])
def test_messages_fragments_pings_and_both_close_handshakes_work_over_plain_and_tls_connections(tmp_path, adopt, flags):
    """Text and binary messages (with the 7-bit, 16-bit and 64-bit lengths, up to the 1 MiB cap), a message split in fragments inside a
    character with a ping between them, the pong of the server, a ping from the server, the subprotocol, a close that
    the client starts and one the server starts, a plain request that keeps its connection, and wss."""
    vm, port, tls_port = start_server(tmp_path, adopt, flags)
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/echo")
        for size in (5, 300, 70000, 1048576):
            c.binary(bytes(range(256)) * (size // 256) + bytes(size % 256))
            assert c.message() == (BINARY, bytes(range(256)) * (size // 256) + bytes(size % 256))
        c.text("h\u00e9llo")
        assert c.message() == (TEXT, "h\u00e9llo".encode())
        c.send(PING, b"abc")
        assert c.message() == (PONG, b"abc")
        # "\u00f1" is two bytes, cut between the fragments, and a ping comes between them.
        c.send(TEXT, b"a\xc3", fin=False)
        c.send(PING, b"mid")
        c.send(CONTINUATION, b"\xb1b", fin=False)
        c.send(CONTINUATION, b"c")
        assert c.message() == (PONG, b"mid")
        assert c.message() == (TEXT, "a\u00f1bc".encode())
        c.close_with(1000, "done")
        assert c.close_frame() == (1000, "")
        assert c.ended()
    assert vm.next_line() == "closed 1000 done"
    # The server starts the close: a text first, then the close with a code of its own.
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/greet")
        assert c.message() == (TEXT, b"hello")
        assert c.close_frame() == (4001, "bye")
        c.close_with(4001, "thanks")
        assert vm.next_line() == "closed 4001 thanks"
        assert c.ended()
    # A ping of the server is answered, and the handler hears the pong.
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/ping")
        assert c.message() == (PING, b"abc")
        c.send(PONG, b"abc")
        assert vm.next_line() == "pong 3"
        c.close_with(1012)
        assert c.close_frame() == (1012, "")
    assert vm.next_line() == "closed 1012 "
    # A session that closed its own outgoing channel still has its close handshake answered.
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/shut")
        c.close_with(1001, "bye")
        assert c.close_frame() == (1001, "")
        assert c.ended()
    assert vm.next_line() == "closed 1001 bye"
    # The subprotocol is the first of the server's list that the client offered.
    with Client(port, timeout=scaled(10)) as c:
        headers = c.connect("/protocol", {"Sec-WebSocket-Protocol": "other, superchat, chat"})
        assert headers["sec-websocket-protocol"] == "chat"
        assert c.message() == (TEXT, b"protocol [chat]")
    assert vm.next_line() == "closed 1006 connection lost"
    with Client(port, timeout=scaled(10)) as c:
        assert "sec-websocket-protocol" not in c.connect("/protocol")
        assert c.message() == (TEXT, b"protocol []")
    assert vm.next_line() == "closed 1006 connection lost"
    # A route that does not upgrade answers a whole response, on a connection that stays: here a handshake follows.
    with Client(port, timeout=scaled(10)) as c:
        assert c.request("/plain", upgrade=False, version=None, key="none")[0] == 200
        assert c.request("/plain", upgrade=False, version=None, key="none")[0] == 200
        c.connect("/echo")
        c.text("after plain")
        assert c.message() == (TEXT, b"after plain")
    assert vm.next_line() == "closed 1006 connection lost"
    context = ssl.create_default_context(cafile=str(CERTS / "ca.pem"))
    with Client(tls_port, secure=context, timeout=scaled(10)) as c:
        c.connect("/echo")
        c.text("over tls")
        assert c.message() == (TEXT, b"over tls")
        c.close_with(1000)
        assert c.close_frame() == (1000, "")
    assert vm.next_line() == "closed 1000 "
    finish(vm)


RULES = [
    ("unmasked", lambda c: c.text("x", masked=False), 1002),
    ("reserved-bit", lambda c: c.text("x", rsv=1), 1002),
    ("unknown-opcode", lambda c: c.send(3, b"x"), 1002),
    ("fragmented-ping", lambda c: c.send(PING, b"x", fin=False), 1002),
    ("long-ping", lambda c: c.send(PING, b"x" * 126), 1002),
    ("stray-continuation", lambda c: c.send(CONTINUATION, b"x"), 1002),
    ("new-message-in-a-fragmented-one", lambda c: (c.text("a", fin=False), c.text("b")), 1002),
    ("invalid-utf8", lambda c: c.send(TEXT, b"\xff\xfe"), 1007),
    ("text-cut-inside-a-character", lambda c: c.send(TEXT, b"\xc3"), 1007),
    ("over-the-cap", lambda c: c.send(BINARY, b"", length=2000), 1009),
    # The second frame only announces its 600 bytes: the message is refused before its payload is read.
    ("over-the-cap-in-fragments", lambda c: (c.binary(b"x" * 600, fin=False), c.send(CONTINUATION, b"", length=600)), 1009),
    ("close-code-1005", lambda c: c.close_with(1005), 1002),
    ("close-with-one-byte", lambda c: c.send(CLOSE, b"x"), 1002),
    ("close-reason-not-utf8", lambda c: c.send(CLOSE, struct.pack(">H", 1000) + b"\xff"), 1007),
]


def test_frames_that_break_the_rules_close_the_connection_with_the_code_of_rfc_6455(tmp_path, adopt):
    """Each broken frame gets its close code (1002, 1007 or 1009) in a frame of the server, the connection ends, and
    the handler is told with the same code; a size past the cap is refused before its payload is read."""
    vm, port, _ = start_server(tmp_path, adopt)
    for name, act, code in RULES:
        with Client(port, timeout=scaled(10)) as c:
            c.connect("/small")
            act(c)
            assert c.close_frame()[0] == code, name
            assert c.ended(), name
        assert vm.next_line().startswith("closed %d " % code), name
    finish(vm)


def test_requests_that_are_not_a_handshake_are_answered_and_never_upgraded(tmp_path, adopt):
    """A handshake with another version is 426 with the version it speaks, the rest are 400, an Upgrade other than
    a GET for websocket is the 501 of every server, and a route that does not upgrade ignores the headers."""
    vm, port, _ = start_server(tmp_path, adopt)
    with Client(port, timeout=scaled(10)) as c:
        assert c.request("/echo", upgrade=False, version=None, key="none")[0] == 400
        status, headers, _ = c.request("/echo", version="8")
        assert (status, headers["sec-websocket-version"]) == (426, "13")
        assert c.request("/echo", key="none")[0] == 400
        assert c.request("/echo", key="abc")[0] == 400
        assert c.request("/plain")[0] == 200
        # An Accept that accept_websocket did not make, and limits it did not accept, are the handler's error.
        assert c.request("/forged")[0] == 500
        assert c.ended()
    with Client(port, timeout=scaled(10)) as c:
        assert c.request("/badoptions")[0] == 500
        assert c.ended()
    with Client(port, timeout=scaled(10)) as c:
        assert c.request("/badqueue")[0] == 500
        assert c.ended()
    with Client(port, timeout=scaled(10)) as c:
        c.sock.sendall(b"GET /echo HTTP/1.1\r\nHost: x\r\nUpgrade: h2c\r\nConnection: Upgrade\r\n\r\n")
        assert c.response()[0] == 501
        assert c.ended()
    with Client(port, timeout=scaled(10)) as c:
        assert c.request("/echo", method="POST")[0] == 501
        assert c.ended()
    finish(vm)


def test_idle_peers_are_dropped_pings_keep_a_live_one_and_a_lost_or_silent_peer_ends_the_session(tmp_path, adopt):
    """idle_ms drops a silent peer (the handler hears 1006), ping_ms pings keep a peer that answers, a peer that
    leaves without a close frame is 1006, a close frame the peer never answers ends after close_ms, and a session that
    returns an error closes with 1011."""
    vm, port, _ = start_server(tmp_path, adopt)
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/idle")
        assert c.ended()
    assert vm.next_line() == "closed 1006 connection lost"
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/keepalive")
        started = time.monotonic()
        pings = 0
        while pings < 6:
            opcode, payload = c.message()
            assert opcode == PING
            c.send(PONG, payload)
            pings += 1
        assert time.monotonic() - started > 0.6, "the connection outlived idle_ms because of the pings"
        c.text("alive")
        while True:
            opcode, payload = c.message()
            if opcode == TEXT:
                break
            assert opcode == PING
        assert payload == b"alive"
    lines = closing(vm)
    assert lines[-1] == "closed 1006 connection lost" and set(lines[:-1]) == {"pong 0"}
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/echo")
    assert closing(vm) == ["closed 1006 connection lost"]
    # The session speaks after 700 ms of silence, with pings every 150 ms: the writer waits and goes on.
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/late")
        started = time.monotonic()
        while True:
            opcode, payload = c.message()
            if opcode == TEXT:
                break
            assert opcode == PING
            c.send(PONG, payload)
        assert payload == b"late" and time.monotonic() - started > 0.6
        c.text("still here")
        while True:
            opcode, payload = c.message()
            if opcode == TEXT:
                break
            c.send(PONG, payload)
        assert payload == b"still here"
    assert closing(vm)[-1] == "closed 1006 connection lost"
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/greet")
        assert c.message() == (TEXT, b"hello")
        assert c.close_frame() == (4001, "bye")
        assert c.ended(), "the server gave up after close_ms"
    assert closing(vm) == ["closed 1006 connection lost"]
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/fail")
        assert c.close_frame() == (1011, "")
        c.close_with(1011)
        assert c.ended()
    vm.close_stdin()
    assert vm.wait() == 0
    assert "http: websocket session error: the session failed" in vm.stderr_text()


@pytest.mark.parametrize("flags", SCHEDULERS, ids=["one-scheduler", "four-schedulers"])
def test_queued_messages_are_written_in_order_with_the_close_last_and_nothing_after_it(tmp_path, adopt, flags):
    """A session that queues 1000 texts and pings faster than the writer takes them (a queue of 256, so the writer
    joins them into writes) gets every frame at the peer in order, a ping of the peer is answered meanwhile, the
    close frame is the last one, and what the session sends after its close is never written."""
    vm, port, _ = start_server(tmp_path, adopt, flags)
    with Client(port, timeout=scaled(20)) as c:
        c.connect("/burst")
        c.send(PING, b"early")
        c.text("go")
        texts, pings, pongs = [], [], []
        while True:
            opcode, payload = c.message()
            if opcode == TEXT:
                texts.append(payload.decode())
            elif opcode == PING:
                pings.append(payload.decode())
            elif opcode == PONG:
                pongs.append(payload)
            else:
                assert opcode == CLOSE
                assert struct.unpack(">H", payload[:2])[0] == 4002 and payload[2:] == b"done"
                break
        assert texts == ["m%d" % i for i in range(1000)]
        assert pings == ["p%d" % i for i in range(99, 1000, 100)]
        assert pongs == [b"early"]
        c.close_with(4002)
        assert c.ended(), "no frame came after the close frame"
    assert vm.next_line() == "closed 4002 "
    finish(vm)


@pytest.mark.parametrize("flags", SCHEDULERS, ids=["one-scheduler", "four-schedulers"])
def test_the_outgoing_queue_size_is_an_option_and_a_full_queue_still_makes_the_sender_fail(tmp_path, adopt, flags):
    """With outgoing_queue 2 a session that queues big messages meanwhile the peer does not read is refused once the
    socket and the queue are full; with 1000 it queues all 400. Every message taken arrives whole and in order, and
    the close comes after them."""
    vm, port, _ = start_server(tmp_path, adopt, flags)
    taken = {}
    for path, limit in (("/fill-small", 400), ("/fill-big", 401)):
        with Client(port, timeout=scaled(30)) as c:
            c.connect(path)
            line = vm.next_line()
            assert line.startswith("accepted ")
            taken[path] = int(line.split()[1])
            assert 0 < taken[path] < limit
            time.sleep(0.2)
            for i in range(taken[path]):
                opcode, payload = c.message()
                assert opcode == BINARY and payload.startswith(b"%d:x" % i) and len(payload) == 131072 + len(b"%d:" % i)
            assert c.close_frame() == (4003, "end")
            c.close_with(4003)
            assert c.ended()
        assert vm.next_line() == "closed 4003 "
    assert taken["/fill-small"] < 400, "a queue of 2 fills"
    assert taken["/fill-big"] == 400, "a queue of 1000 does not"
    finish(vm)


@pytest.mark.parametrize("flags", SCHEDULERS, ids=["one-scheduler", "four-schedulers"])
def test_the_close_frame_of_the_reader_is_not_overtaken_by_the_close_the_server_adds_when_the_session_returns(tmp_path, adopt, flags):
    """The session of /echo returns the moment it hears the peer's close or a broken frame, while the writer sleeps or
    reads the wake: the answer must still be the echo of the peer's code, or the code of the broken frame, never the 1000
    the server adds for a session that returns. Eight clients at once, 2400 connections: it is a race between tasks."""
    vm, port, _ = start_server(tmp_path, adopt, flags)
    wrong = []

    def worker(worker_id):
        for round_ in range(100):
            code = 4000 + worker_id
            for act, expected in (
                (lambda c: c.close_with(code), code),
                (lambda c: c.text("x", masked=False), 1002),
                (lambda c: c.send(TEXT, b"\xff\xfe"), 1007),
            ):
                try:
                    with Client(port, timeout=scaled(20)) as c:
                        c.connect("/echo")
                        act(c)
                        got = c.close_frame()[0]
                        if got != expected:
                            wrong.append((worker_id, round_, expected, got))
                except Exception as error:
                    wrong.append((worker_id, round_, expected, repr(error)))

    threads = [threading.Thread(target=worker, args=(n,)) for n in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert wrong == []
    codes = Counter()
    for _ in range(2400):
        codes[vm.next_line().split()[1]] += 1
    assert codes["1002"] == codes["1007"] == 800
    assert sum(codes["400%d" % n] for n in range(8)) == 800
    finish(vm)


@pytest.mark.parametrize("flags", SCHEDULERS, ids=["one-scheduler", "four-schedulers"])
def test_a_close_of_the_session_queued_before_the_close_of_the_peer_is_our_close_and_nothing_follows_it(tmp_path, adopt, flags):
    """The writer is blocked in a write of 16 MB while the session queues A, its own close (4000) and B; the peer
    then closes without reading. The writer writes A and the close of the session, not B, and not an answer to the
    peer's close: the handshake is complete."""
    vm, port, _ = start_server(tmp_path, adopt, flags)
    with Client(port, timeout=scaled(30), receive_buffer=SMALL_BUFFER) as c:
        c.connect("/order")
        assert vm.next_line() == "queued"
        c.close_with(1000)
        time.sleep(0.5)
        opcode, payload = c.message()
        assert opcode == BINARY and len(payload) == 16000000
        assert c.message() == (TEXT, b"A")
        assert c.close_frame() == (4000, "bye")
        assert c.ended(), "nothing came after the close frame of the session"
    assert vm.next_line() == "closed 1000 "
    finish(vm)


def test_frames_that_cross_the_write_cap_arrive_whole_and_in_order(tmp_path, adopt):
    """Binary messages of 100, 65400, 70000, 8, 65536, 65535, 9 and 65530 bytes, queued together: a write stops reading
    the queue once 64 KiB are joined, and a frame past it goes whole. Each arrives with its own bytes, the close last."""
    vm, port, _ = start_server(tmp_path, adopt)
    with Client(port, timeout=scaled(20)) as c:
        c.connect("/edge")
        for i, size in enumerate((100, 65400, 70000, 8, 65536, 65535, 9, 65530)):
            opcode, payload = c.message()
            head = b"e%d:" % i
            assert opcode == BINARY and payload == head + b"x" * (size - len(head)), i
        assert c.close_frame() == (4004, "edge")
        c.close_with(4004)
        assert c.ended()
    assert vm.next_line() == "closed 4004 "
    finish(vm)


@pytest.mark.parametrize("flags", SCHEDULERS, ids=["one-scheduler", "four-schedulers"])
def test_everything_the_session_queued_before_the_close_of_the_peer_goes_out_before_the_answer(tmp_path, adopt, flags):
    """The writer is blocked in a write of 16 MB while the session queues "A", five messages of 100 KB and 300 of 1 KB
    (about 800 KB, many writes); the peer then closes without reading. All of it arrives, in order, then the answer."""
    vm, port, _ = start_server(tmp_path, adopt, flags)
    with Client(port, timeout=scaled(30), receive_buffer=SMALL_BUFFER) as c:
        c.connect("/pile")
        assert vm.next_line() == "queued"
        c.close_with(1001)
        time.sleep(0.5)
        opcode, payload = c.message()
        assert opcode == BINARY and len(payload) == 16000000
        assert c.message() == (TEXT, b"A")
        for _ in range(5):
            assert c.message() == (BINARY, b"p" * 100000)
        for _ in range(300):
            assert c.message() == (BINARY, b"s" * 1000)
        assert c.close_frame() == (1001, "")
        assert c.ended()
    assert vm.next_line() == "closed 1001 "
    finish(vm)


def test_a_close_a_session_builds_that_looks_like_the_wake_of_the_server_is_sent_as_any_invalid_code(tmp_path, adopt):
    """The server rouses its writer with a close message that a session cannot build: Close(0, "wake") is an invalid
    code, so it goes out as 1011 like any other."""
    vm, port, _ = start_server(tmp_path, adopt)
    with Client(port, timeout=scaled(10)) as c:
        c.connect("/fakewake")
        assert c.message() == (TEXT, b"a")
        assert c.close_frame() == (1011, "wake")
        c.close_with(1011)
        assert c.ended()
    assert vm.next_line() == "closed 1011 "
    finish(vm)
