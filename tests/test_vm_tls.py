"""The TLS builtins of the VM against Node and Python peers.

fixtures/tls-peer.js (Node) serves the client cases and connects to the VM
server; fixtures/tls-peer.py (Python ssl) is a TLS 1.2 server, an HTTPS server,
a server that requires a client certificate and a client. The certificates are
the ones in fixtures/tls. Everything is on 127.0.0.1 or localhost with port 0.
"""
import json
import os
import queue
import re
import threading

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, TEST_SCHEDULERS, UNDER_WINE, Child, check_lines, cli,
                                 compile_text, output_lines, run, run_vm, scaled, start_vm, vm_environment)

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
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem")).unwrap!))
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
  socket = Result.unwrap!(TLS.connect("localhost", port, TLS.client_context(TlsClientOptions(ca_file: "#{dir}/ca.pem")).unwrap!, 5000))
  Result.unwrap!(TCP.send(socket, "from agentica\\n", 5000))
  puts(Result.unwrap!(TCP.read_line(socket, 5000)))
  IO.inspect(TCP.read_line(socket, 5000))
  TCP.close(socket)
end
"""

MTLS_CLIENT_PROGRAM = """\
def talk(opened: Result[Socket]) -> Result[String]
  socket = try opened
  try TCP.send(socket, "hi\\n", 5000)
  line = try TCP.read_line(socket, 5000)
  TCP.close(socket)
  return ok(line)
end

def main() -> Void
  dir = System.args()[0]
  port = String.to_int!(Result.unwrap!(IO.gets()))
  ca = "#{dir}/ca.pem"
  puts(Result.unwrap!(talk(TLS.connect("localhost", port, TLS.client_context(TlsClientOptions(ca_file: ca, cert_file: "#{dir}/client.pem", key_file: "#{dir}/client-key.pem")).unwrap!, 5000))))
  # Under TLS 1.3 the server's refusal comes after the client's side of the handshake: the connect or the first
  # read fails.
  puts(Result.ok?(talk(TLS.connect("localhost", port, TLS.client_context(TlsClientOptions(ca_file: ca)).unwrap!, 5000))))
end
"""

ALPN_CLIENT_PROGRAM = """\
def offer(port: Int, ca: String, alpn: List[String]) -> Result[String]
  socket = try TLS.connect("localhost", port, try TLS.client_context(TlsClientOptions(ca_file: ca, alpn: alpn)), 5000)
  line = try TCP.read_line(socket, 5000)
  return ok("#{TLS.alpn(socket)} #{line}")
end

def main() -> Void
  port = String.to_int!(IO.gets().unwrap!)
  ca = "#{System.args()[0]}/ca.pem"
  IO.inspect(offer(port, ca, ["http/1.1"]))
  IO.inspect(offer(port, ca, ["spdy/3"]))
end
"""

ALPN_SERVER_PROGRAM = """\
def main() -> Void
  dir = System.args()[0]
  options = TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem", alpn: ["h2", "http/1.1"])
  listener = TLS.listen("127.0.0.1", 0, TLS.server_context(options).unwrap!).unwrap!
  puts(TCP.local_port(listener))
  IO.flush()
  puts(TLS.alpn(TCP.accept(listener, 10000).unwrap!))
  IO.flush()
  puts(TCP.accept(listener, 10000).ok?)
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
  options = HttpClientOptions(timeout_ms: 20000, idle_timeout_ms: 20000, max_connections: 4, max_body_bytes: 1024, tls: some(TLS.client_context(TlsClientOptions(ca_file: "#{System.args()[0]}/ca.pem")).unwrap!))
  pool = Result.unwrap!(HTTP.client(options))
  puts(String.from_bytes(Result.unwrap!(HTTP.get(pool, "#{base}/a")).body).unwrap!)
  Task.spawn(&hang, Call(pool: pool, url: "#{base}/hang"))
  puts(String.from_bytes(Result.unwrap!(HTTP.get(pool, "#{base}/ping")).body).unwrap!)
end
"""

SHARED_CONTEXT_PROGRAM = """\
import HTTP from "std/http"

struct Call
  pool: HttpClient
  url: String
end

def get(call: Call) -> Result[HttpResponse]
  return HTTP.get(call.pool, call.url)
end

def show(r: Result[HttpResponse]) -> String
  case r
    ok(response) -> return String.from_bytes(response.body).unwrap!
    error(message) -> return message
  end
end

def main() -> Void
  base = "https://localhost:#{Result.unwrap!(IO.gets())}"
  ca = System.args()[1]
  tls = Result.unwrap!(TLS.client_context(TlsClientOptions(ca_file: ca)))
  options = HttpClientOptions(tls: some(tls), timeout_ms: 20000)
  pool = Result.unwrap!(HTTP.client(options))
  puts(show(HTTP.get(pool, base + "/first")))
  # The context read its CA file when it was built: spoiling the file changes nothing for it, three connections at
  # once here and a second client that shares it. A new context reads the file again and fails.
  Result.unwrap!(File.write_text(ca, "not a certificate", 5000))
  calls: List[Task[Result[HttpResponse]]] = []
  for n in 0...3
    calls = calls.push(Task.spawn(&get, Call(pool: pool, url: base + "/again")))
  end
  for call in calls
    puts(show(Task.await(call)))
  end
  puts(show(HTTP.get(pool, base + "/last")))
  other = Result.unwrap!(HTTP.client(options))
  puts(show(HTTP.get(other, base + "/other")))
  puts(String.starts_with?(TLS.client_context(TlsClientOptions(ca_file: ca)).message, "ssl-load-verify-source!"))
  # A client with no context builds one with the system trust (SSL_CERT_FILE here) for its first https connection
  # and shares it with the next.
  plain = Result.unwrap!(HTTP.client(HttpClientOptions(timeout_ms: 20000)))
  puts(show(HTTP.get(plain, base + "/system")))
  puts(show(HTTP.get(plain, base + "/system")))
  HTTP.close_client(pool)
  HTTP.close_client(other)
  HTTP.close_client(plain)
end
"""

WAITERS_PROGRAM = """\
import HTTP from "std/http"

struct Call
  pool: HttpClient
  url: String
end

def get(call: Call) -> Result[HttpResponse]
  return HTTP.get(call.pool, call.url)
end

def show(r: Result[HttpResponse]) -> String
  case r
    ok(response) -> return String.from_bytes(response.body).unwrap!
    error(message) -> return message
  end
end

def main() -> Void
  base = "https://localhost:#{System.args()[0]}"
  # The client names no context, so its first https connection builds one with the system trust, and
  # SSL_CERT_FILE is a FIFO: the build blocks until the test writes it. The first call starts the build and waits;
  # the two after it wait behind it. The first one's deadline comes while the build still blocks: it leaves the
  # waiters, and the build goes on for the other two. The client has one timeout, so the two others start half of it
  # after the first: each side of the first one's deadline has half the timeout to spare.
  timeout = String.to_int!(System.args()[1])
  pool = Result.unwrap!(HTTP.client(HttpClientOptions(timeout_ms: timeout)))
  first = Task.spawn(&get, Call(pool: pool, url: base + "/first"))
  Task.sleep(timeout / 2)
  calls = [Task.spawn(&get, Call(pool: pool, url: base + "/a")), Task.spawn(&get, Call(pool: pool, url: base + "/b"))]
  puts(show(Task.await(first)))
  for call in calls
    puts(show(Task.await(call)))
  end
  HTTP.close_client(pool)
end
"""

CLOSE_IN_HANDSHAKE_PROGRAM = """\
import HTTP from "std/http"

struct Call
  pool: HttpClient
  url: String
end

def get(call: Call) -> Result[HttpResponse]
  return HTTP.get(call.pool, call.url)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  options = HttpClientOptions(tls: some(TLS.client_context(TlsClientOptions(ca_file: "#{System.args()[0]}/ca.pem")).unwrap!), timeout_ms: 5000)
  pool = Result.unwrap!(HTTP.client(options))
  call = Task.spawn(&get, Call(pool: pool, url: "https://127.0.0.1:#{TCP.local_port(listener)}/"))
  # The server never answers the ClientHello: the client's connection is in its handshake when the client closes.
  socket = Result.unwrap!(TCP.accept(listener, 5000))
  HTTP.close_client(pool)
  IO.inspect(Task.await(call))
  # The handshake still holds the client's context; it fails when the server goes, and the context goes with it.
  TCP.close(socket)
  Task.sleep(200)
  puts("done")
end
"""

HANDSHAKE_PROGRAM = """\
struct Dial
  port: Int
  ca: String
end

def dial(d: Dial) -> Result[Socket]
  return TLS.connect("localhost", d.port, TLS.client_context(TlsClientOptions(ca_file: d.ca)).unwrap!, 5000)
end

def show(dir: String, r: Result[Socket]) -> String
  case r
    ok(_) -> return "ok"
    error(message) -> return String.replace(message, dir, "<tls>")
  end
end

def handshake(dir: String, name: String, ca: String) -> Void
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: "#{dir}/#{name}.pem", key_file: "#{dir}/#{name}-key.pem")).unwrap!))
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
  IO.inspect(TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server-key.pem", key_file: "#{dir}/server-key.pem")).ok?)
  IO.inspect(TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server.pem")).ok?)
  puts(String.replace(TLS.client_context(TlsClientOptions(ca_file: "#{dir}/missing.pem")).message, dir, "<tls>"))
  plain = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  server = Task.spawn(&plain_server, plain)
  puts("plain server: #{show(dir, TLS.connect("127.0.0.1", TCP.local_port(plain), TLS.client_context(TlsClientOptions(ca_file: ca)).unwrap!, 5000))}")
  Task.await(server)
  secure = Result.unwrap!(TLS.listen("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem")).unwrap!))
  raw = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(secure), 5000))
  Result.unwrap!(TCP.send(raw, "GET / HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n", 5000))
  puts("plain client: #{show(dir, TCP.accept(secure, 5000))}")
end
"""

LIMITS_PROGRAM = """\
def wait(port: Int) -> Void
  waiting = Result.unwrap!(TLS.connect("localhost", port, TLS.client_context(TlsClientOptions(ca_file: "#{System.args()[0]}/ca.pem")).unwrap!, 5000))
  IO.inspect(TCP.read_line(waiting, 30))
  IO.inspect(TCP.recv_bytes(waiting, 1, 1000))
end

def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem")).unwrap!))
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
  return Result.unwrap!(TLS.connect("localhost", port, TLS.client_context(TlsClientOptions(ca_file: "#{System.args()[0]}/ca.pem")).unwrap!, 5000))
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
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem")).unwrap!))
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

CANCEL_PROGRAM = """\
struct Ports
  raw: Int
  secure: Int
end

def ca() -> String
  return "#{System.args()[0]}/ca.pem"
end

def dial(port: Int) -> Result[Socket]
  return TLS.connect("localhost", port, TLS.client_context(TlsClientOptions(ca_file: ca())).unwrap!, 30000)
end

def read(port: Int) -> Result[String]
  socket = Result.unwrap!(TLS.connect("localhost", port, TLS.client_context(TlsClientOptions(ca_file: ca())).unwrap!, 30000))
  return TCP.read_line(socket, 60000)
end

def serve(listener: Listener) -> Bool
  socket = Result.unwrap!(TCP.accept(listener, 30000))
  return TCP.read_line(socket, 60000).ok?
end

def parent(ports: Ports) -> Result[Int]
  Task.spawn(&dial, ports.raw)
  Task.spawn(&read, ports.secure)
  Task.sleep(300)
  zero = 0
  return ok(1 / zero)
end

def main() -> Void
  dir = System.args()[0]
  raw = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  secure = Result.unwrap!(TLS.listen("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem")).unwrap!))
  server = Task.spawn_owning(&serve, secure)
  ports = Ports(raw: TCP.local_port(raw), secure: TCP.local_port(secure))
  puts(Task.await(Task.spawn(&parent, ports)).ok?)
  # The cancelled reader's socket closes, so the server's read ends.
  puts(Task.await(server))
  rounds = 0
  while Task.pending_count() > 0 && rounds < 500
    Task.sleep(10)
    rounds = rounds + 1
  end
  puts(Task.pending_count())
  TCP.close_listener(raw)
end
"""

TRUST_PROGRAM = """\
def main() -> Void
  dir = System.args()[0]
  listener = Result.unwrap!(TLS.listen("127.0.0.1", 0, TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem")).unwrap!))
  task = Task.spawn(&accept_one, listener)
  IO.inspect(Result.ok?(TLS.connect("localhost", TCP.local_port(listener), TLS.client_context(TlsClientOptions()).unwrap!, 5000)))
  Task.await(task)
end

def accept_one(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 5000))
end
"""



def client_program(ports):
    """The Agentica client that dials every Node server in turn (ports maps a server name to its port)."""
    def dial(name, host="localhost"):
        return 'TLS.connect("%s", %d, TLS.client_context(TlsClientOptions(ca_file: ca)).unwrap!, 5000)' % (host, ports[name])

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
        '  Result.unwrap!(TCP.send_bytes(echo, Bytes.from_list([195]).unwrap!, 5000))',
        '  Result.unwrap!(TCP.send_bytes(echo, Bytes.from_list([177, 10]).unwrap!, 5000))',
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
        '  show(TLS.connect("localhost", %d, TLS.client_context(TlsClientOptions(ca_file: ca)).unwrap!, 200))' % ports["stall"],
        '  show(TLS.connect("localhost", %d, TLS.client_context(TlsClientOptions()).unwrap!, 5000))' % ports["echo"],
        'end'])










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
        "ok(<Bytes 0>)",
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


def test_client_certificate_to_a_python_server_that_requires_one_and_refused_without(tmp_path, adopt):
    server, port = python_server(adopt, "mtls")
    result = run_text(tmp_path, "mtls-client", MTLS_CLIENT_PROGRAM, stdin=port + "\n")
    assert (result.code, result.stdout) == (0, "hello Agentica Test Client\nfalse\n"), result.stderr
    assert [server.next_line(), server.next_line()] == ["client Agentica Test Client", "refused"]
    assert server.wait() == 0


def test_alpn_against_python_on_both_sides_the_servers_choice_none_and_a_refusal(tmp_path, adopt):
    server, port = python_server(adopt, "alpn")
    result = run_text(tmp_path, "alpn-client", ALPN_CLIENT_PROGRAM, stdin=port + "\n")
    assert (result.code, result.stdout) == (0, 'ok("http/1.1 http/1.1")\nok(" ")\n'), result.stderr
    assert server.wait() == 0
    vm = adopt(start_vm(compile_text(ALPN_SERVER_PROGRAM, "alpn-server", tmp_path), CERTS))
    port = vm.next_line()
    chosen = run([PYTHON, PYTHON_PEER, "alpn-client", port, "http/1.1,h2"], timeout=scaled(30))
    assert (chosen.code, chosen.stdout) == (0, "h2\n"), chosen.stderr
    assert vm.next_line() == "h2"
    refused = run([PYTHON, PYTHON_PEER, "alpn-client", port, "spdy/3"], timeout=scaled(30))
    assert (refused.code, refused.stdout) == (0, "refused\n"), refused.stderr
    assert vm.next_line() == "false"
    assert vm.wait() == 0, vm.stderr_text()


def test_main_returns_with_an_idle_and_an_active_https_client_connection_both_get_close_notify(tmp_path, adopt):
    server, port = python_server(adopt, "http")
    result = run_text(tmp_path, "https-goodbye", HTTPS_GOODBYE_PROGRAM, stdin=port + "\n")
    assert (result.code, result.stdout) == (0, "ok\nok\n"), result.stderr
    assert [server.next_line(), server.next_line()] == ["close_notify /hang", "close_notify /ping"]
    assert server.wait() == 0


def test_a_tls_context_reads_its_ca_file_once_and_a_client_without_one_shares_a_system_context(tmp_path, adopt):
    server, port = python_server(adopt, "close")
    ca = tmp_path / "ca.pem"
    ca.write_bytes((CERTS / "ca.pem").read_bytes())
    trace, env = trace_env(tmp_path)
    env["SSL_CERT_FILE"] = str(CERTS / "ca.pem")
    result = run_vm(compile_text(SHARED_CONTEXT_PROGRAM, "shared-context", tmp_path), env=vm_environment(env),
                    args=[CERTS, ca], stdin=port + "\n")
    assert (result.code, result.stdout) == (0, "ok\nok\nok\nok\nok\nok\ntrue\nok\nok\n"), result.stderr
    text = trace.read_text()
    # One context built from the file (the second build failed), eight handshakes: six on it, two on the system
    # context that the third client built once.
    assert len(re.findall(r"tls_context role=client ca=file", text)) == 1, text
    assert len(re.findall(r"tls_config socket=\d+ shared=1", text)) == 1, text
    assert len(re.findall(r"tls_handshake_done socket=", text)) == 8, text


def test_close_client_while_a_connection_is_in_its_tls_handshake(tmp_path):
    result = run_text(tmp_path, "close-in-handshake", CLOSE_IN_HANDSHAKE_PROGRAM)
    assert (result.code, result.stdout) == (0, 'error("http: client is closed")\ndone\n'), result.stderr


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
    # The third is the raw connection, which the accepting task may not reach before main ends on several schedulers.
    servers = count(r" tls tls_handshake socket=0 listener=[0-9]+ role=server$")
    several = TEST_SCHEDULERS != "1" and bool(TEST_SCHEDULERS or (os.cpu_count() or 1) > 1)
    assert servers in ((2, 3) if several else (3,)), text


def test_a_crashed_owner_cancels_its_tasks_in_a_tls_handshake_and_a_tls_read(tmp_path):
    """The dial never gets a ServerHello (a plain listener that does not answer); the reader waits in a read on a
    TLS socket. Both are cancelled when their parent crashes, the server sees its peer go, and the run ends."""
    trace, env = trace_env(tmp_path)
    result = run_text(tmp_path, "cancel", CANCEL_PROGRAM, env)
    assert (result.code, result.stdout) == (0, "false\nfalse\n0\n"), result.stderr
    assert re.search(r" io end code=0 signal=0$", trace.read_text(), re.M)


class BlockingFile:
    """A path whose reader blocks until write() is called: a FIFO, or on Windows (which has none) a named pipe.

    The Windows pipe is served by a thread: the VM's open connects to it, and its reads block until write() sends
    the data and closes the pipe, which the reader sees as the end of the file. The thread is a daemon, so a VM that
    never opens the pipe does not keep the test alive."""

    def __init__(self, fifo):
        self._data = queue.Queue()
        if os.name != "nt":
            os.mkfifo(fifo)
            self.path = fifo
            return
        import ctypes
        import _winapi
        self.path = r"\\.\pipe\agentica-test-%d-%d" % (os.getpid(), id(self))
        # PIPE_ACCESS_OUTBOUND (2), and PIPE_TYPE_BYTE | PIPE_WAIT (0): _winapi does not name all of them.
        handle = _winapi.CreateNamedPipe(self.path, 2, 0, 1, 65536, 65536, 0, _winapi.NULL)

        def serve():
            try:
                try:
                    _winapi.ConnectNamedPipe(handle, False)
                except OSError as error:
                    # ERROR_PIPE_CONNECTED: the reader opened the pipe before this call.
                    if error.winerror != 535:
                        raise
                _winapi.WriteFile(handle, self._data.get())
                # Wait until the reader has taken every byte, so closing the pipe cannot drop unread data.
                flush = ctypes.WinDLL("kernel32", use_last_error=True).FlushFileBuffers
                flush.argtypes = [ctypes.c_void_p]
                if not flush(handle):
                    raise ctypes.WinError(ctypes.get_last_error())
            finally:
                _winapi.CloseHandle(handle)

        threading.Thread(target=serve, daemon=True).start()

    def write(self, data):
        if os.name != "nt":
            with open(self.path, "wb") as pipe:
                pipe.write(data)
            return
        self._data.put(data)


# Under Wine the peer is a Linux Python, which can make only a Linux FIFO, and Wine reads that without blocking (an
# empty CA file). The native Windows job runs this case on a named pipe.
@pytest.mark.skipif(UNDER_WINE, reason="Wine does not block on a Linux FIFO; the native Windows job covers it")
def test_https_waiters_on_a_clients_system_context_build_and_one_leaves(tmp_path, adopt):
    server, port = python_server(adopt, "close")
    ca_pipe = BlockingFile(tmp_path / "ca-fifo.pem")
    trace, env = trace_env(tmp_path)
    env["SSL_CERT_FILE"] = str(ca_pipe.path)
    # The first call times out after `timeout`; the two others then have half of theirs left.
    timeout = str(scaled(2000))
    bytecode = compile_text(WAITERS_PROGRAM, "waiters", tmp_path)
    vm = adopt(start_vm(bytecode, port, timeout, env=env))
    try:
        assert vm.next_line() == "network: operation timed out"
    finally:
        # The build holds the pipe open for reading; writing it lets the build, and the VM, finish.
        ca_pipe.write((CERTS / "ca.pem").read_bytes())
    assert [vm.next_line() for _ in range(2)] == ["ok", "ok"]
    assert vm.wait() == 0, vm.stderr_text()
    text = trace.read_text()
    # One build for the waiters.
    assert len(re.findall(r"tls_config socket=\d+ shared=1", text)) == 1, text
    assert len(re.findall(r"tls_handshake_done socket=", text)) == 2, text


DROPPED_CONTEXT_PROGRAM = """\
def listener_of(dir: String) -> Listener
  server = TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", key_file: "#{dir}/server-key.pem"))
  return TLS.listen("127.0.0.1", 0, server.unwrap!).unwrap!
end

def dial(dir: String, port: Int) -> Socket
  tls = TLS.client_context(TlsClientOptions(ca_file: "#{dir}/ca.pem")).unwrap!
  return TLS.connect("localhost", port, tls, 5000).unwrap!
end

# Garbage over many turns, so collections run and the finalizers of the dropped contexts run between turns.
def churn() -> Int
  total = 0
  for n in 0...300
    total += List.repeat(n, 20000).size
    Task.sleep(0)
  end
  return total
end

def echo(listener: Listener) -> Result[Void]
  socket = try TCP.accept(listener, 5000)
  try TCP.send(socket, try TCP.read_line(socket, 5000) + "!\\n", 5000)
  TCP.close(socket)
  return ok()
end

def main() -> Void
  dir = System.args()[0]
  # No value reaches either context after these calls: the listener and the socket hold their own counts.
  listener = listener_of(dir)
  port = TCP.local_port(listener)
  server = Task.spawn do echo(listener) end
  socket = dial(dir, port)
  puts(churn())
  TCP.send(socket, "first\\n", 5000).unwrap!
  puts(TCP.read_line(socket, 5000).unwrap!)
  IO.inspect(Task.await(server))
  # The listener still makes TLS connections after the collections.
  again = Task.spawn do echo(listener) end
  other = dial(dir, port)
  TCP.send(other, "second\\n", 5000).unwrap!
  puts(TCP.read_line(other, 5000).unwrap!)
  IO.inspect(Task.await(again))
end
"""


def test_a_dropped_context_stays_valid_for_its_listener_and_sockets(tmp_path):
    result = run_text(tmp_path, "dropped-context", DROPPED_CONTEXT_PROGRAM)
    assert (result.code, result.stdout) == (0, "6000000\nfirst!\nok()\nsecond!\nok()\n"), result.stderr


@pytest.mark.parametrize("name, call, file, covers", [
    ("a server context to TLS.connect", 'TLS.connect("localhost", 1, server, 1000)', "main.agc", "server"),
    ("a client context to TLS.listen", 'TLS.listen("127.0.0.1", 0, client)', "main.agc", "client"),
    ("a server context in HttpClientOptions.tls", "HTTP.client(HttpClientOptions(tls: some(server)))", "std/http.agc",
     None),
])
def test_a_context_of_the_wrong_role_is_runtime_tls_context_role_at_the_context(tmp_path, name, call, file, covers):
    program = tmp_path / "main.agc"
    program.write_text(
        'import HTTP from "std/http"\n\ndef main() -> Void\n  dir = System.args()[0]\n'
        '  client = TLS.client_context(TlsClientOptions()).unwrap!\n'
        '  server = TLS.server_context(TlsServerOptions(cert_file: "#{dir}/server.pem", '
        'key_file: "#{dir}/server-key.pem")).unwrap!\n'
        f"  IO.inspect({call})\nend\n", encoding="utf-8")
    result = run(cli() + ["--json", "main.agc", CERTS], cwd=tmp_path, env=vm_environment())
    assert result.code == 1, name
    problem = json.loads(result.stderr)
    assert (problem["code"], problem["file"]) == ("RUNTIME-TLS-CONTEXT-ROLE", file), result.stderr
    if covers:
        start, end = problem["range"]["start"], problem["range"]["end"]
        line = program.read_text().splitlines()[start["line"] - 1]
        assert (start["line"], line[start["column"] - 1:end["column"] - 1]) == (7, covers), result.stderr
