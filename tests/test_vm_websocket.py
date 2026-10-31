"""The VM's WebSocket server (HTTP.listen_websocket) against fixtures/websocket_client.py, a RFC 6455 client of its own.

One VM program serves every route. The client writes frames by hand, so the tests send what a correct client never
would and read the close codes the server answers with. Everything is on 127.0.0.1 with port 0.
"""
import ssl
import struct
import time

import pytest

from tests.agentica_test import FIXTURES, compile_agc, scaled, start_vm
from tests.fixtures.websocket_client import BINARY, CLOSE, CONTINUATION, PING, PONG, TEXT, Client

CERTS = FIXTURES / "tls"

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

  return HTTP.upgrade_only(&plain).call(request)
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 2000, idle_timeout_ms: 10000, max_connections: 16)
  server = Result.unwrap!(HTTP.listen_websocket("127.0.0.1", 0, &route, options))
  certs = System.args()[0]
  secure = Result.unwrap!(HTTP.listen_websocket_tls("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: certs + "/server.pem", key_file: certs + "/server-key.pem")).unwrap!, &route, options))
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
"""


def start_server(tmp_path, adopt, flags=()):
    source = tmp_path / "websocket-server.agc"
    source.write_text(SERVER_PROGRAM, encoding="utf-8")
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


@pytest.mark.parametrize("flags", [(), ("--schedulers", "4")], ids=["one-scheduler", "four-schedulers"])
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
    # A route that does not upgrade answers as listen does, on a connection that stays: here a handshake follows.
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
    # The session speaks after 700 ms of silence, with pings every 150 ms: the forwarder and the writer wait and go on.
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
