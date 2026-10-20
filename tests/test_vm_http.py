"""The VM HTTP client and server against independent peers.

The client runs against fixtures/http-peer.py (ThreadingHTTPServer, a Python
ssl server and raw hostile sockets). The server runs against Python raw
sockets and http.client (fixtures/http-server-peer.py) and Node http clients
(fixtures/http-server-peer.js). Everything is on 127.0.0.1 with port 0; the
certificates are the ones in fixtures/tls.
"""
import json
import socket
import time

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, Child, check_lines, compile_agc, optional_tool, output_lines, run, run_vm,
                                 scaled, start_vm, vm_environment)

PEER = FIXTURES / "http-peer.py"
SERVER_PEER = FIXTURES / "http-server-peer.py"
SERVER_NODE_PEER = FIXTURES / "http-server-peer.js"
CERTS = FIXTURES / "tls"

PRELUDE = """\
import HTTP from "std/http"

struct Fetch
  pool: HttpClient
  url: String
end

def options(timeout: Int, connections: Int, body: Int, ca: String) -> HttpClientOptions
  return HttpClientOptions(timeout_ms: timeout, idle_timeout_ms: 5000, max_connections: connections, max_body_bytes: body, ca_file: ca)
end

def short(body: String) -> String
  if String.length(body) > 20
    return String.slice(body, 0, 20)
  end
  return body
end

def show(r: Result[HttpResponse]) -> Void
  case r
    ok(response) -> puts("#{response.status} #{short(response.body)} #{String.length(response.body)}")
    error(message) -> puts(String.replace(message, "\\n", " | "))
  end
end

def fetch(f: Fetch) -> Result[String]
  response = try HTTP.get(f.pool, f.url)
  return ok(response.body)
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
  puts("#{hello.status} #{hello.body} #{HTTP.header_values(hello.headers, "X-MULTI")}")
  show(HTTP.get(pool, plain + "/chunked"))
  first = Result.unwrap!(HTTP.get(pool, plain + "/port")).body
  show(HTTP.post(pool, plain + "/post", [Header(name: "X-Kind", value: "form")], "a=1&b=ñ"))
  puts(Result.unwrap!(HTTP.get(pool, plain + "/port")).body == first)
  show(HTTP.get(pool, plain + "/close"))
  puts(Result.unwrap!(HTTP.get(pool, plain + "/port")).body != first)
  show(HTTP.get(pool, plain + "/nothing"))
  HTTP.close_client(pool)
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
  while Result.unwrap!(HTTP.get(watcher, plain + "/held")).body == "0"
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
  secure = Result.unwrap!(HTTP.client(options(5000, 1, 1000, certs + "/ca.pem")))
  show(HTTP.get(secure, "https://localhost:#{port}/hello"))
  show(HTTP.get(secure, "https://LOCALHOST:#{port}/hello"))
  show(HTTP.post(secure, "https://127.0.0.1:#{port}/post", [], "over tls"))
  show(HTTP.get(secure, "https://localhost:#{port}/notify"))
  show(HTTP.get(secure, "https://localhost:#{port}/close"))
  show(HTTP.get(secure, "http://localhost:#{port}/hello"))
  show(HTTP.get(Result.unwrap!(HTTP.client(options(5000, 1, 1000, certs + "/self-signed.pem"))), "https://localhost:#{port}/hello"))
  show(HTTP.get(Result.unwrap!(HTTP.client(options(5000, 1, 1000, certs + "/missing.pem"))), "https://localhost:#{port}/hello"))
end
"""

RAW_PROGRAM = """\
def main() -> Void
  raw = "http://127.0.0.1:#{System.args()[3]}"
  upload = "x"
  while String.length(upload) < 4194304
    upload = upload + upload
  end
  large = Result.unwrap!(HTTP.client(options(5000, 1, 8388608, "")))
  show(HTTP.post(large, raw + "/early", [], upload))
  hostile = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  stale = Result.unwrap!(HTTP.client(options(5000, 1, 1000, "")))
  show(HTTP.get(stale, raw + "/stale"))
  show(HTTP.post(stale, raw + "/after", [], "x"))
  show(HTTP.get(stale, raw + "/stale"))
  show(HTTP.get(stale, raw + "/after"))
  show(HTTP.request(stale, "HEAD", raw + "/headlength", [], ""))
  show(HTTP.get(stale, raw + "/after"))
  for path in ["/http10", "/status99", "/status600", "/upgrade", "/interim15", "/interim16", "/badchunk", "/atlimit", "/big", "/bigchunks", "/barelf", "/fold", "/twolengths", "/smuggle", "/gzip", "/badtrailer", "/truncated", "/headerless", "/nocontent", "/after"]
    show(HTTP.get(hostile, raw + path))
  end
end
"""

SERVER_PROGRAM = """\
import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/big"
    big = "x"
    while String.length(big) < 8388608
      big = big + big
    end
    return ok(HttpResponse(status: 200, headers: [], body: big))
  end
  return ok(HttpResponse(status: 200, headers: [], body: "#{request.method} #{request.path} #{request.body}"))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 2000, idle_timeout_ms: 10000, max_connections: 2, max_body_bytes: 1024)
  server = Result.unwrap!(HTTP.listen("127.0.0.1", 0, &handle, options))
  certs = System.args()[0]
  secure = Result.unwrap!(HTTP.listen_tls("127.0.0.1", 0, certs + "/server.pem", certs + "/server-key.pem", &handle, options))
  puts("#{HTTP.local_port(server)} #{HTTP.local_port(secure)}")
  IO.flush()
  IO.read()
  HTTP.close_server(server)
  HTTP.close_server(secure)
  IO.inspect(HTTP.wait(server))
  IO.inspect(HTTP.wait(secure))
end
"""

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
    "non-utf8 400 closed",
    "no-host 400 closed",
    "two-hosts 400 closed",
    "short-505 505 closed quick",
    "bad-line-open 400 closed quick",
    "partial-head none closed bounded",
    "expect-over-limit HTTP/1.1 413 Content Too Large False closed",
    "expect-continue HTTP/1.1 100 Continue 200 POST /expect hello closed",
    "pipelined ['GET /one ', 'POST /two abc', 'POST /four abc', 'GET /three '] closed",
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
    "node-expect true 200 POST /expect hello",
    "node-keep-alive GET /first  GET /again  true true",
    "node-head 200 11 \"\"",
    "node-concurrent 3 true",
]






def start_peer(adopt):
    """http-peer.py serves until its stdin closes, so the pipe stays open; returns the ports it prints."""
    peer = adopt(Child([PYTHON, PEER], stdin=True))
    return json.loads(peer.next_line())


def run_program(tmp_path, name, text, ports):
    source = tmp_path / (name + ".agc")
    source.write_text(PRELUDE + text, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / (name + ".agcb"))
    result = run_vm(bytecode, env=vm_environment(), args=[CERTS] + [ports[key] for key in ("plain", "tls", "raw")])
    assert result.code == 0, result.stderr
    return result.stdout


def test_client_against_threading_http_server_keep_alive_chunked_close_delimited_timeout_pool_limits(tmp_path, adopt):
    ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "plain", PLAIN_PROGRAM, ports), [
        '200 hello 127.0.0.1 ["a", "b"]',
        "200 ñandú chunks 12",
        "200 form 8 a=1&b=ñ 14",
        "true",
        "200 until the end 13",
        "true",
        "404 missing 7",
        "network: operation timed out",
        "true",
        "true",
        'error("http: client is closed")'], "plain")


def test_client_against_a_python_ssl_server_with_the_clients_ca_file(tmp_path, adopt):
    ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "tls", TLS_PROGRAM, ports), [
        "200 hello localhost 15",
        "200 hello localhost 15",
        "200 None 8 over tls 15",
        "200 closed cleanly 14",
        "http: truncated HTTP body",
        ("prefix", "error reading from stream port | "),
        ("prefix", "ssl-connect: connect failed (certificate verify failed"),
        ("prefix", "ssl-load-verify-source!: load failed from: ")], "tls")


def test_client_against_hostile_raw_responses_and_a_413_that_comes_before_the_upload_ends(tmp_path, adopt):
    ports = start_peer(adopt)
    check_lines(run_program(tmp_path, "raw", RAW_PROGRAM, ports), [
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


def test_server_reads_requests_that_arrive_in_pieces(tmp_path, adopt):
    """A head or body split across reads gets the same answer as one sent whole: a UTF-8 character split across
    reads and chunks, a forbidden trailer split mid-name, and heads too large however slowly they arrive."""
    vm, port = start_server(tmp_path, adopt)
    length = b"POST /length HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: %d\r\n\r\n"
    chunked = b"POST /chunked HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n"
    assert send_in_pieces(port, [length % 6 + b"ab\xc3", b"\xb1cd"]) == ("200", "POST /length ab\u00f1cd")
    assert send_in_pieces(port, [chunked + b"5\r\na", b"b\xc3", b"\xb1c\r\n1\r\nd\r\n0\r\n\r\n"]) == (
        "200", "POST /chunked ab\u00f1cd")
    assert send_in_pieces(port, [chunked + b"3\r\nab\xc3\r\n", b"2\r\n\xb1c\r\n0\r\n\r\n"]) == (
        "200", "POST /chunked ab\u00f1c")
    assert send_in_pieces(port, [length % 3 + b"ab", b"\xc3"])[0] == "400"
    assert send_in_pieces(port, [chunked + b"3\r\nab", b"\xc3\r\n0\r\n\r\n"])[0] == "400"
    assert send_in_pieces(port, [chunked + b"0\r\nConte", b"nt-Length: 2\r\n\r\n"])[0] == "400"
    many = b"GET / HTTP/1.1\r\nHost: x\r\n" + b"".join(b"X-%d: v\r\n" % k for k in range(101)) + b"\r\n"
    assert send_in_pieces(port, [many[:300], many[300:900], many[900:]])[0] == "431"
    unended = b"GET /" + b"a" * 80000
    assert send_in_pieces(port, [unended[k:k + 20000] for k in range(0, len(unended), 20000)])[0] == "431"
    filler = b"X-Fill: " + b"b" * 4000 + b"\r\n"
    large = b"GET / HTTP/1.1\r\nHost: x\r\n" + filler * 20
    assert send_in_pieces(port, [large[k:k + 9000] for k in range(0, len(large), 9000)])[0] == "431"
    vm.close_stdin()
    assert vm.wait() == 0, "the VM server finishes"


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
