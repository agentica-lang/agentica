"""The TLS builtins of the VM against Node and Python peers.

fixtures/tls-peer.js (Node) serves the client cases and connects to the VM
server; fixtures/tls-peer.py (Python ssl) is a TLS 1.2 server, an HTTPS server
and a client. The certificates are the ones in fixtures/tls. Everything is on
127.0.0.1 or localhost with port 0.
"""
import json
import re

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, Child, compile_agc, output_lines, run, run_vm, scaled, start_vm,
                                 tool, vm_environment)

NODE_PEER = FIXTURES / "tls-peer.js"
PYTHON_PEER = FIXTURES / "tls-peer.py"
CERTS = FIXTURES / "tls"

SERVER_PROGRAM = """\
def serve(socket: Socket) -> Void
  line = TCP.read_line(socket, 10000)
  while Result.ok?(line)
    Result.unwrap!(TCP.send(socket, "hello #{Result.unwrap!(line)}\\n", 10000))
    line = TCP.read_line(socket, 10000)
  end
  TCP.close(socket)
end

def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  puts(TCP.local_port(listener))
  IO.flush()
  a = Task.spawn_owning(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  b = Task.spawn_owning(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  Task.await(a)
  Task.await(b)
  puts("served")
  IO.flush()
  bad = TCP.accept(listener, 10000)
  puts(Result.message(bad))
  IO.flush()
  serve(Result.unwrap!(TCP.accept(listener, 10000)))
  TCP.close_listener(listener)
  puts("done")
end
"""

PYTHON_CLIENT_PROGRAM = """\
def main() -> Void
  dir = System.args()[0]
  port = String.to_int!(Result.unwrap!(IO.gets()))
  socket = Result.unwrap!(TLS.connect("localhost", port, "#{dir}/ca.pem", 5000))
  Result.unwrap!(TCP.send(socket, "from agentica\\n", 5000))
  puts(Result.unwrap!(TCP.read_line(socket, 5000)))
  IO.inspect(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
"""

HTTPS_GOODBYE_PROGRAM = """\
import HTTP from "std/http"

struct Call
  pool: HttpClient
  url: String
end

def hang(call: Call) -> Result[HttpResponse]
  return HTTP.get(call.pool, call.url)
end

def main() -> Void
  base = "https://localhost:#{Result.unwrap!(IO.gets())}"
  options = HttpClientOptions(timeout_ms: 20000, idle_timeout_ms: 20000, max_connections: 4, max_body_bytes: 1024, ca_file: "#{System.args()[0]}/ca.pem")
  pool = Result.unwrap!(HTTP.client(options))
  puts(Result.unwrap!(HTTP.get(pool, "#{base}/a")).body)
  Task.spawn(&hang, Call(pool: pool, url: "#{base}/hang"))
  puts(Result.unwrap!(HTTP.get(pool, "#{base}/ping")).body)
end
"""

HANDSHAKE_PROGRAM = """\
struct Dial
  port: Int
  ca: String
end

def dial(d: Dial) -> Result[Socket]
  return TLS.connect("localhost", d.port, d.ca, 5000)
end

def show(dir: String, r: Result[Socket]) -> String
  case r
    ok(_) -> return "ok"
    error(message) -> return String.replace(message, dir, "<tls>")
  end
end

def handshake(dir: String, name: String, ca: String) -> Void
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/#{name}.pem", "#{dir}/#{name}-key.pem"))
  task = Task.spawn(&dial, Dial(port: TCP.local_port(listener), ca: ca))
  accepted = TCP.accept(listener, 5000)
  puts("#{name}: #{show(dir, Task.await(task))}")
  puts("  server: #{show(dir, accepted)}")
  TCP.close_listener(listener)
end

def plain_server(listener: Listener) -> Void
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  Result.unwrap!(TCP.send(socket, "hello\\n", 5000))
  TCP.recv_bytes(socket, 4096, 5000)
  TCP.close(socket)
end

def main() -> Void
  dir = System.args()[0]
  ca = "#{dir}/ca.pem"
  handshake(dir, "server", ca)
  handshake(dir, "wrong-host", ca)
  handshake(dir, "server", "#{dir}/self-signed.pem")
  IO.inspect(TLS.listen("127.0.0.1", 0, "#{dir}/server-key.pem", "#{dir}/server-key.pem").ok?)
  IO.inspect(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server.pem").ok?)
  puts(show(dir, TLS.connect("localhost", 443, "#{dir}/missing.pem", 1000)))
  plain = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  server = Task.spawn(&plain_server, plain)
  puts("plain server: #{show(dir, TLS.connect("127.0.0.1", TCP.local_port(plain), ca, 5000))}")
  Task.await(server)
  secure = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  raw = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(secure), 5000))
  Result.unwrap!(TCP.send(raw, "GET / HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n", 5000))
  puts("plain client: #{show(dir, TCP.accept(secure, 5000))}")
end
"""

LIMITS_PROGRAM = """\
def wait(port: Int) -> Void
  waiting = Result.unwrap!(TLS.connect("localhost", port, "#{System.args()[0]}/ca.pem", 5000))
  IO.inspect(TCP.read_line(waiting, 30))
  IO.inspect(TCP.recv_bytes(waiting, 1, 1000))
end

def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  task = Task.spawn(&wait, TCP.local_port(listener))
  quiet = Result.unwrap!(TCP.accept(listener, 5000))
  Task.await(task)
  raw = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(listener), 5000))
  IO.inspect(TCP.accept(listener, 30))
  TCP.close(raw)
  TCP.close(quiet)
  TCP.close_listener(listener)
  IO.inspect(TCP.accept(listener, 1000))
end
"""

EXIT_PROGRAM = """\
struct Flood
  port: Int
  chunk: String
end

def connect(port: Int) -> Socket
  return Result.unwrap!(TLS.connect("localhost", port, "#{System.args()[0]}/ca.pem", 5000))
end

def hold(port: Int) -> Result[String]
  return TCP.read_line(connect(port), 5000)
end

def wait_accept(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 5000))
end

def flood(job: Flood) -> Result[Void]
  return TCP.send(connect(job.port), job.chunk, 5000)
end

def started(n: Int) -> Int
  return n
end

def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  port = TCP.local_port(listener)
  Task.spawn(&hold, port)
  silent = Result.unwrap!(TCP.accept(listener, 5000))
  Task.spawn(&flood, Flood(port: port, chunk: String.join(List.repeat(String.join(List.repeat("abcdefgh", 128), ""), 8192), "")))
  sink = Result.unwrap!(TCP.accept(listener, 5000))
  raw = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  Task.spawn(&wait_accept, listener)
  Task.await(Task.spawn(&started, 0))
  IO.inspect(silent)
  IO.inspect(sink)
  IO.inspect(raw)
  puts("done")
end
"""

TRUST_PROGRAM = """\
def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem"))
  task = Task.spawn(&accept_one, listener)
  IO.inspect(Result.ok?(TLS.connect("localhost", TCP.local_port(listener), "", 5000)))
  Task.await(task)
end

def accept_one(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 5000))
end
"""



def client_program(ports):
    """The Agentica client that dials every Node server in turn (ports maps a server name to its port)."""
    def dial(name, host="localhost"):
        return 'TLS.connect("%s", %d, ca, 5000)' % (host, ports[name])

    return "".join(line + "\n" for line in [
        'def show(r: Result[Socket]) -> Void',
        '  case r',
        '    ok(_) -> puts("ok")',
        '    error(m) -> puts(m)',
        '  end',
        'end',
        '',
        'def main() -> Void',
        '  ca = "#{System.args()[0]}/ca.pem"',
        '  echo = Result.unwrap!(%s)' % dial("echo"),
        '  Result.unwrap!(TCP.send_bytes(echo, [195], 5000))',
        '  Result.unwrap!(TCP.send_bytes(echo, [177, 10], 5000))',
        '  puts(Result.unwrap!(TCP.read_line(echo, 5000)))',
        '  TCP.close(echo)',
        '  pieces = Result.unwrap!(%s)' % dial("fragments", "127.0.0.1"),
        '  puts(Result.unwrap!(TCP.read_line(pieces, 5000)))',
        '  IO.inspect(TCP.read_line(pieces, 5000))',
        '  IO.inspect(TCP.read_line(pieces, 5000))',
        '  IO.inspect(TCP.recv_bytes(pieces, 4, 5000))',
        '  TCP.close(pieces)',
        '  abrupt = Result.unwrap!(%s)' % dial("abrupt"),
        '  IO.inspect(TCP.read_line(abrupt, 5000))',
        '  IO.inspect(TCP.read_line(abrupt, 5000))',
        '  IO.inspect(TCP.read_line(abrupt, 5000))',
        '  reset = Result.unwrap!(%s)' % dial("reset"),
        '  Result.unwrap!(TCP.send(reset, "x", 5000))',
        '  IO.inspect(TCP.read_line(reset, 5000))',
        '  TCP.close(reset)',
        '  big = Result.unwrap!(%s)' % dial("big"),
        '  puts(String.length(Result.unwrap!(TCP.read_line(big, 5000))))',
        '  Result.unwrap!(TCP.send(big, String.join(List.repeat("b", 100000), "") + "\\n", 5000))',
        '  puts(Result.unwrap!(TCP.read_line(big, 5000)))',
        '  TCP.close(big)',
        '  long = Result.unwrap!(%s)' % dial("long"),
        '  IO.inspect(TCP.read_line(long, 5000))',
        '  IO.inspect(TCP.read_line(long, 5000))',
        '  silent = Result.unwrap!(%s)' % dial("silent"),
        '  IO.inspect(TCP.read_line(silent, 100))',
        '  IO.inspect(TCP.send(silent, "x", 1000))',
        '  show(%s)' % dial("wrong"),
        '  show(%s)' % dial("expired"),
        '  show(%s)' % dial("self"),
        '  show(%s)' % dial("old"),
        '  show(%s)' % dial("plain"),
        '  show(TLS.connect("localhost", %d, ca, 200))' % ports["stall"],
        '  show(TLS.connect("localhost", %d, "", 5000))' % ports["echo"],
        'end'])


@pytest.fixture
def node():
    return tool("node")


@pytest.fixture
def adopt(request):
    """Stop a Child when the test ends (also after a failure or Ctrl-C); return it."""
    def register(child):
        request.addfinalizer(child.stop)
        return child

    return register


def check_lines(text, expected, message):
    """One output line per expectation: a string is equal, ("prefix", text) is a prefix."""
    lines = output_lines(text)
    assert len(lines) == len(expected), message + "\n" + text
    for line, want in zip(lines, expected):
        if isinstance(want, str):
            assert line == want, message
        else:
            assert line.startswith(want[1]), "%s: %r should start with %r" % (message, line, want[1])


def compile_text(text, name, tmp_path):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, tmp_path / (name + ".agcb"))


def run_text(tmp_path, name, text, env=None, stdin=None):
    return run_vm(compile_text(text, name, tmp_path), env=vm_environment(env), args=[CERTS], stdin=stdin)


def trace_env(tmp_path):
    trace = tmp_path / "vm.trace"
    return trace, {"AGENTICA_VM_TRACE": "io,tls", "AGENTICA_VM_TRACE_FILE": str(trace)}


def python_server(adopt, mode):
    """A Python TLS peer in `mode` (server or http); returns it and the port it prints."""
    server = adopt(Child([PYTHON, PYTHON_PEER, mode]))
    return server, server.next_line()


def test_client_against_node_tls_servers_data_eof_resets_limits_timeouts_and_verify_errors(tmp_path, adopt, node):
    peer = adopt(Child([node, NODE_PEER, "servers"]))
    ports = json.loads(peer.next_line())
    result = run_text(tmp_path, "client", client_program(ports))
    assert result.code == 0, result.stderr
    check_lines(result.stdout, [
        "ñ",
        "ñ😀",
        'ok("tail")',
        'error("network: end of input")',
        "ok([])",
        'ok("abc")',
        'ok("partial")',
        'error("network: end of input")',
        ("prefix", 'error("error reading from stream port\\n  system error: '),
        "100000",
        "100000 true",
        'error("network: line exceeds 1048576 bytes")',
        'error("network: socket is closed")',
        'error("network: operation timed out")',
        'error("network: socket is closed")',
        "ssl-connect: connect failed (certificate verify failed: hostname mismatch)",
        "ssl-connect: connect failed (certificate verify failed: certificate has expired)",
        "ssl-connect: connect failed (certificate verify failed: self-signed certificate)",
        ("prefix", "ssl-connect: connect failed ("),
        ("prefix", "ssl-connect: connect failed ("),
        "network: operation timed out",
        "ssl-connect: connect failed (certificate verify failed: unable to get local issuer certificate)"],
        result.stderr)


def test_ssl_cert_file_is_the_trust_store_when_ca_file_is_empty(tmp_path):
    trusted = run_text(tmp_path, "trust", TRUST_PROGRAM, {"SSL_CERT_FILE": CERTS / "ca.pem"})
    assert (trusted.code, trusted.stdout) == (0, "true\n"), trusted.stderr
    untrusted = run_text(tmp_path, "trust", TRUST_PROGRAM, {"SSL_CERT_FILE": CERTS / "self-signed.pem"})
    assert (untrusted.code, untrusted.stdout) == (0, "false\n"), untrusted.stderr


def test_server_serves_node_clients_tls_13_and_12_and_python_and_fails_an_untrusting_clients_accept(
    tmp_path, adopt, node
):
    vm = adopt(start_vm(compile_text(SERVER_PROGRAM, "server", tmp_path), CERTS))
    port = vm.next_line()
    nodes = run([node, NODE_PEER, "clients", port], timeout=scaled(30))
    assert nodes.code == 0, nodes.stderr
    assert nodes.stdout == "clients ok\nuntrusting UNABLE_TO_VERIFY_LEAF_SIGNATURE\n"
    assert vm.next_line() == "served"
    assert vm.next_line().startswith("port->ssl-ports: accept failed (")
    python = run([PYTHON, PYTHON_PEER, "client", port], timeout=scaled(30))
    assert python.code == 0, python.stderr
    assert python.stdout == "hello python TLSv1.3\n"
    assert vm.next_line() == "done"
    assert vm.wait() == 0, vm.stderr_text()


def test_client_against_a_python_tls_12_server_closed_with_close_notify(tmp_path, adopt):
    server, port = python_server(adopt, "server")
    result = run_text(tmp_path, "python-client", PYTHON_CLIENT_PROGRAM, stdin=port + "\n")
    assert (result.code, result.stdout) == (0, 'python TLSv1.2 FROM AGENTICA\nerror("network: end of input")\n'), \
        result.stderr
    assert server.wait() == 0


def test_main_returns_with_an_idle_and_an_active_https_client_connection_both_get_close_notify(tmp_path, adopt):
    server, port = python_server(adopt, "http")
    result = run_text(tmp_path, "https-goodbye", HTTPS_GOODBYE_PROGRAM, stdin=port + "\n")
    assert (result.code, result.stdout) == (0, "ok\nok\n"), result.stderr
    assert [server.next_line(), server.next_line()] == ["close_notify /hang", "close_notify /ping"]
    assert server.wait() == 0


def test_handshake_and_load_errors_on_both_sides_of_a_vm_client_and_server(tmp_path):
    result = run_text(tmp_path, "handshakes", HANDSHAKE_PROGRAM)
    assert result.code == 0, result.stderr
    check_lines(result.stdout, [
        "server: ok",
        "  server: ok",
        "wrong-host: ssl-connect: connect failed (certificate verify failed: hostname mismatch)",
        ("prefix", "  server: port->ssl-ports: accept failed ("),
        "server: ssl-connect: connect failed (certificate verify failed: unable to get local issuer certificate)",
        ("prefix", "  server: port->ssl-ports: accept failed ("),
        "false",
        "false",
        'ssl-load-verify-source!: load failed from: "<tls>/missing.pem"',
        ("prefix", "  system error: "),
        ("prefix", "plain server: ssl-connect: connect failed ("),
        ("prefix", "plain client: port->ssl-ports: accept failed (")],
        result.stderr)


def test_timeouts_close_a_tls_socket_a_pending_handshake_times_out_a_closed_listener_stays_closed(tmp_path):
    result = run_text(tmp_path, "limits", LIMITS_PROGRAM)
    assert (result.code, result.stdout) == (0, 'error("network: operation timed out")\n'
                                              'error("network: socket is closed")\n'
                                              'error("network: operation timed out")\n'
                                              'error("network: listener is closed")\n'), result.stderr


def test_main_returns_while_tls_tasks_wait_the_run_ends_without_draining_them(tmp_path):
    trace, env = trace_env(tmp_path)
    result = run_text(tmp_path, "exit", EXIT_PROGRAM, env)
    assert (result.code, result.stdout) == (0, "<Socket>\n<Socket>\n<Socket>\ndone\n"), result.stderr
    text = trace.read_text()

    def count(pattern):
        return len(re.findall(pattern, text, re.M))

    assert count(r" io end code=0 signal=0$") == 1, text
    assert count(r" tls tls_handshake_done ") == 4
    assert count(r" tls tls_handshake socket=0 listener=[0-9]+ role=server$") == 3
