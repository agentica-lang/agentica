"""The TCP builtins of the VM against Node peers.

fixtures/tcp-peer.js is the independent peer: `servers` listens on several
ports (fragments, resets, silence, ...) and prints their numbers as JSON;
`clients` connects to a VM server. Everything is on 127.0.0.1 or localhost
with port 0.
"""
import errno
import json
import os
import re
import socket
import threading
import time

import pytest

from tests.agentica_test import (FIXTURES, TARGET_OS, TEST_SCHEDULERS, TLS_BUILT, WAIT_SECONDS, Child, compile_text,
                                 run, run_vm, scaled, start_vm, vm_environment)

PEER = FIXTURES / "tcp-peer.js"


def ipv6_localhost():
    """True when ::1 accepts connections here, like the original test's probe."""
    try:
        with socket.socket(socket.AF_INET6) as listener:
            listener.bind(("::1", 0))
            listener.listen(1)
            socket.create_connection(("::1", listener.getsockname()[1]), timeout=scaled(5)).close()
        return True
    except OSError:
        return False


CLIENT_PROGRAM = """\
def main() -> Void
  echo = Result.unwrap!(TCP.connect("localhost", %d, 5000))
  Result.unwrap!(TCP.send_bytes(echo, [195], 5000))
  Result.unwrap!(TCP.send_bytes(echo, [177, 10], 5000))
  puts(Result.unwrap!(TCP.read_line(echo, 5000)))
  TCP.close(echo)
  pieces = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  puts(Result.unwrap!(TCP.read_line(pieces, 5000)))
  IO.inspect(TCP.read_line(pieces, 5000))
  IO.inspect(TCP.read_line(pieces, 5000))
  IO.inspect(TCP.recv_bytes(pieces, 4, 5000))
  TCP.close(pieces)
  reset = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  Result.unwrap!(TCP.send(reset, "x", 5000))
  IO.inspect(TCP.read_line(reset, 5000))
  TCP.close(reset)
  long = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  IO.inspect(TCP.read_line(long, 5000))
  IO.inspect(TCP.read_line(long, 5000))
  silent = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  IO.inspect(TCP.read_line(silent, 100))
  IO.inspect(TCP.send(silent, "x", 1000))
  stuck = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  big = "abcdefgh"
  round = 0
  while round < 22
    big = big + big
    round = round + 1
  end
  sent = TCP.send(stuck, big, 200)
  rounds = 1
  while Result.ok?(sent) && rounds < 16
    sent = TCP.send(stuck, big, 200)
    rounds = rounds + 1
  end
  IO.inspect(sent)
  IO.inspect(TCP.send(stuck, "x", 1000))
  partial = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  IO.inspect(TCP.read_line(partial, 5000))
  refused = TCP.connect("127.0.0.1", %d, 5000)
  puts(Result.message(refused))
end
"""

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
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  a = Task.spawn_owning(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  b = Task.spawn_owning(&serve, Result.unwrap!(TCP.accept(listener, 10000)))
  Task.await(a)
  Task.await(b)
  TCP.close_listener(listener)
  puts("served")
end
"""

OWNERS_PROGRAM = """\
def boom(socket: Socket) -> Result[Int]
  zero = 0
  return ok(1 / zero)
end

def dial(port: Int) -> Void
  Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
end

def main() -> Void
  crashed = Task.spawn_owning(&boom, Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000)))
  puts(Task.await(crashed).ok?)
  Task.await(Task.spawn(&dial, %d))
  puts("ready")
  IO.flush()
  IO.gets()
end
"""

LOCALHOST_PROGRAM = """\
def main() -> Void
  listener = Result.unwrap!(TCP.listen("localhost", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  line = ""
  while line != "end"
    socket = Result.unwrap!(TCP.accept(listener, 10000))
    line = Result.unwrap!(TCP.read_line(socket, 10000))
    puts(line)
    IO.flush()
    TCP.close(socket)
  end
  TCP.close_listener(listener)
end
"""

TAKEN_PROGRAM = """\
def main() -> Void
  listener = TCP.listen("localhost", %d)
  if Result.ok?(listener)
    puts("listening")
  else
    puts(Result.message(listener))
  end
end
"""

WRITERS_PROGRAM = """\
struct Job
  socket: Socket
  text: String
end

def write(job: Job) -> Result[Void]
  return TCP.send(job.socket, job.text, 30000)
end

def fill(letter: String) -> String
  text = "#{letter}#{letter}#{letter}#{letter}#{letter}#{letter}#{letter}#{letter}"
  round = 0
  while round < 21
    text = text + text
    round = round + 1
  end
  return text
end

def main() -> Void
  socket = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  a = Task.spawn(&write, Job(socket: socket, text: fill("a")))
  b = Task.spawn(&write, Job(socket: socket, text: fill("b")))
  c = Task.spawn(&write, Job(socket: socket, text: fill("c")))
  IO.inspect(Task.await(a))
  IO.inspect(Task.await(b))
  IO.inspect(Task.await(c))
  TCP.close(socket)
end
"""

EXIT_PROGRAM = """\
def hold(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 60000)
end

def flood(socket: Socket) -> Void
  chunk = String.join(List.repeat("abcdefgh", 131072), "")
  while Result.ok?(TCP.send(socket, chunk, 60000))
  end
end

def wait_accept(listener: Listener) -> Bool
  return Result.ok?(TCP.accept(listener, 60000))
end

def main() -> Void
  watch = Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000))
  Task.spawn(&hold, Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000)))
  Task.spawn(&flood, Result.unwrap!(TCP.connect("127.0.0.1", %d, 5000)))
  Task.spawn(&wait_accept, Result.unwrap!(TCP.listen("127.0.0.1", 0)))
  Task.sleep(200)
  IO.inspect(watch)
  puts("done")
end
"""



# The UCRT's errno values for libuv's socket errors on Windows (vm/net_windows.c); elsewhere the host's errno.
WINDOWS_ERRNO = {"ECONNREFUSED": 107, "ECONNRESET": 108}


def system_error(name):
    """The `system error:` text of the VM for an errno name: the host's number and its strerror text."""
    code = WINDOWS_ERRNO[name] if TARGET_OS == "windows" else getattr(errno, name)
    return "system error: %s; errno=%d" % (os.strerror(code), code)


REFUSED_HEAD = "tcp-connect: connection failed\n  hostname: 127.0.0.1\n  port number: %d\n"
RESET = 'error("error reading from stream port\\n  %s")\n' % system_error("ECONNRESET")

def start_peer(adopt, node):
    """The Node servers: returns (peer, ports); the peer prints events such as `closed watch`."""
    peer = adopt(Child([node, PEER, "servers"]))
    return peer, json.loads(peer.next_line())


def run_text(tmp_path, name, text, env=None):
    return run_vm(compile_text(text, name, tmp_path), env=vm_environment(env))


def trace_env(tmp_path):
    trace = tmp_path / "vm.trace"
    return trace, {"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": str(trace)}


def test_client_reads_fragments_eof_resets_long_lines_and_timeouts_from_node_peers(tmp_path, adopt, node):
    _, ports = start_peer(adopt, node)
    args = tuple(ports[name] for name in ("echo", "fragments", "reset", "long", "silent", "silent", "partial", "refused"))
    result = run_text(tmp_path, "client", CLIENT_PROGRAM % args)
    assert result.code == 0, result.stderr
    assert result.stdout == ("ñ\n"
                             "ñ😀\n"
                             'ok("tail")\n'
                             'error("network: end of input")\n'
                             "ok([])\n"
                             + RESET +
                             'error("network: line exceeds 1048576 bytes")\n'
                             'error("network: socket is closed")\n'
                             'error("network: operation timed out")\n'
                             'error("network: socket is closed")\n'
                             'error("network: operation timed out")\n'
                             'error("network: socket is closed")\n'
                             + RESET +
                             (REFUSED_HEAD % ports["refused"]) + "  %s\n" % system_error("ECONNREFUSED"))


def test_server_serves_two_node_clients_at_once_one_task_per_connection(tmp_path, adopt, node):
    vm = adopt(start_vm(compile_text(SERVER_PROGRAM, "server", tmp_path)))
    port = vm.next_line()
    clients = run([node, PEER, "clients", port], timeout=WAIT_SECONDS)
    assert clients.code == 0, clients.stderr
    assert clients.stdout == "clients ok\n"
    assert vm.next_line() == "served"
    assert vm.wait() == 0, vm.stderr_text()


def test_task_closes_the_connections_it_owns_when_it_crashes_or_returns(tmp_path, adopt, node):
    """The Node peer sees both close."""
    peer, ports = start_peer(adopt, node)
    vm = adopt(start_vm(compile_text(OWNERS_PROGRAM % (ports["watch"], ports["watch"]), "owners", tmp_path),
                        stdin=True))
    assert vm.next_line() == "false"
    assert vm.next_line() == "ready"
    assert peer.next_line() == "closed watch"
    assert peer.next_line() == "closed watch"
    vm.close_stdin()
    assert vm.wait() == 0, vm.stderr_text()


def test_listener_on_localhost_takes_ipv4_and_ipv6_clients(tmp_path, adopt):
    ipv6 = ipv6_localhost()
    vm = adopt(start_vm(compile_text(LOCALHOST_PROGRAM, "localhost", tmp_path)))
    port = int(vm.next_line())

    def send_line(host, text):
        with socket.create_connection((host, port), timeout=scaled(10)) as connection:
            connection.sendall((text + "\n").encode())

    send_line("127.0.0.1", "v4")
    assert vm.next_line() == "v4"
    if ipv6:
        send_line("::1", "v6")
        assert vm.next_line() == "v6"
    send_line("127.0.0.1", "end")
    assert vm.next_line() == "end"
    assert vm.wait() == 0, vm.stderr_text()


def test_listen_on_localhost_fails_when_another_program_holds_the_port_on_ipv6(tmp_path):
    if not ipv6_localhost():
        pytest.skip("no IPv6 localhost")
    # No SO_REUSEADDR, like the original holder: the VM must find the port taken.
    with socket.socket(socket.AF_INET6) as holder:
        holder.bind(("::1", 0))
        holder.listen(4)
        result = run_text(tmp_path, "taken", TAKEN_PROGRAM % holder.getsockname()[1])
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("tcp-listen: listen failed\n  hostname: localhost\n"), result.stdout


def test_two_tasks_writing_to_one_socket_take_the_writer_lock_in_fifo_order(tmp_path, adopt, node):
    peer, ports = start_peer(adopt, node)
    trace, env = trace_env(tmp_path)
    result = run_text(tmp_path, "writers", WRITERS_PROGRAM % ports["collect"], env)
    assert (result.code, result.stdout) == (0, "ok()\nok()\nok()\n"), result.stderr
    size = 8 * 2 ** 21
    assert peer.next_line() == "collect a=%d b=%d c=%d" % (size, size, size)
    # On several schedulers a writer can finish before the next one starts, so none has to wait; Windows takes a
    # 16 MiB send into its buffers at once, so there too no writer waits.
    if not TEST_SCHEDULERS and TARGET_OS != "windows":
        assert " io lock_wait " in trace.read_text(), "a writer waited for the lock"


def test_main_returns_while_tasks_wait_on_sockets_and_the_peer_sees_every_socket_close(tmp_path, adopt, node):
    peer, ports = start_peer(adopt, node)
    trace, env = trace_env(tmp_path)
    bytecode = compile_text(EXIT_PROGRAM % (ports["watch"], ports["silent"], ports["silent"]), "exit", tmp_path)
    # Only the VM run is timed: compiling through the CLI can be slow on a busy machine.
    started = time.monotonic()
    result = run_vm(bytecode, env=vm_environment(env))
    assert (result.code, result.stdout) == (0, "<Socket>\ndone\n"), result.stderr
    assert time.monotonic() - started < scaled(20)
    text = trace.read_text()
    assert re.compile(r" io end code=0 signal=0$", re.M).search(text), text
    assert " io tcp_listen listener=" in text, "listen is traced"
    assert " io tcp_connected socket=" in text, "connect is traced"
    assert peer.next_line() == "closed watch"


CANCEL_PROGRAM = """\
def dial(port: Int) -> Result[Socket]
  return TCP.connect("127.0.0.1", port, 30000)
end

def wait_accept(listener: Listener) -> Result[Socket]
  return TCP.accept(listener, 60000)
end

def parent(listener: Listener) -> Result[Int]
  Task.spawn(&dial, %d)
  Task.spawn_owning(&wait_accept, listener)
  Task.sleep(0)
  zero = 0
  return ok(1 / zero)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  puts(TCP.local_port(listener))
  puts(Task.await(Task.spawn_owning(&parent, listener)).ok?)
  # The cancelled tasks end as their parked calls let go, not at once.
  rounds = 0
  while Task.pending_count() > 0 && rounds < 500
    Task.sleep(10)
    rounds = rounds + 1
  end
  puts(Task.pending_count())
  IO.flush()
  IO.gets()
end
"""

ECHO_SERVER_PROGRAM = """\
def serve(socket: Socket) -> Void
  line = TCP.read_line(socket, 20000)
  while Result.ok?(line)
    Result.unwrap!(TCP.send(socket, "#{Result.unwrap!(line)}!\\n", 20000))
    line = TCP.read_line(socket, 20000)
  end
  TCP.close(socket)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("%s", 0))
  puts(TCP.local_port(listener))
  IO.flush()
  tasks: List[Task[Void]] = []
  count = 0
  while count < %d
    tasks = List.append(tasks, Task.spawn_owning(&serve, Result.unwrap!(TCP.accept(listener, 20000))))
    count = count + 1
  end
  for task in tasks
    Task.await(task)
  end
  TCP.close_listener(listener)
  puts("served")
  IO.flush()
  IO.gets()
end
"""

DIAL_PROGRAM = """\
struct Call
  host: String
  port: Int
  name: String
end

def call(c: Call) -> Result[String]
  socket = try TCP.connect(c.host, c.port, 10000)
  try TCP.send(socket, "#{c.name}\\n", 10000)
  reply = TCP.read_line(socket, 10000)
  TCP.close(socket)
  return reply
end

def main() -> Void
  tasks: List[Task[Result[String]]] = []
  for k in 0...%d
    tasks = List.append(tasks, Task.spawn(&call, Call(host: "%s", port: %d, name: "c#{k}")))
  end
  for task in tasks
    IO.inspect(Task.await(task))
  end
end
"""


def listener_on(host):
    """A plain Python listener on HOST, port 0, without SO_REUSEADDR."""
    server = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
    server.bind((host, 0))
    server.listen(64)
    server.settimeout(scaled(20))
    return server


def assert_port_free(host, port):
    """The port can be bound by a socket without SO_REUSEADDR: nothing holds it. The close runs on the VM's I/O
    thread, which on several schedulers may be a moment behind the program's output."""
    deadline = time.monotonic() + scaled(5)
    while True:
        with socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET) as probe:
            try:
                probe.bind((host, port))
                return
            except OSError:
                if time.monotonic() > deadline:
                    raise
        time.sleep(0.05)


def test_cancel_during_connect_and_accept_closes_both_and_releases_the_port(tmp_path, adopt):
    """A crashed parent cancels a task in TCP.connect and one in TCP.accept: the Python peer of the connect sees
    the socket close (or never sees it), and the listener's port is free while the VM still runs."""
    with listener_on("127.0.0.1") as peer:
        trace, env = trace_env(tmp_path)
        vm = adopt(start_vm(compile_text(CANCEL_PROGRAM % peer.getsockname()[1], "cancel", tmp_path), stdin=True, env=env))
        port = int(vm.next_line())
        assert vm.next_line() == "false"
        assert vm.next_line() == "0"
        assert_port_free("127.0.0.1", port)
        peer.settimeout(scaled(2))
        try:
            connection, _ = peer.accept()
        except TimeoutError:
            connection = None
        if connection:
            with connection:
                connection.settimeout(scaled(10))
                try:
                    assert connection.recv(1) == b""
                except ConnectionResetError:
                    pass
        vm.close_stdin()
        assert vm.wait() == 0, vm.stderr_text()
    assert re.compile(r" io end code=0 signal=0$", re.M).search(trace.read_text())


def fragmented_call(host, port, name, replies):
    """One client: its line in three writes, the middle one splitting a UTF-8 sequence."""
    with socket.create_connection((host, port), timeout=scaled(20)) as connection:
        data = ("%s-ñ\n" % name).encode()
        cut = data.index(b"\xc3") + 1
        for piece in (data[:2], data[2:cut], data[cut:]):
            connection.sendall(piece)
            time.sleep(0.01)
        reader = connection.makefile("rb")
        replies[name] = reader.readline().decode()
        connection.shutdown(socket.SHUT_WR)
        replies[name + "/eof"] = reader.read()


def serve_python_clients(tmp_path, adopt, host, count):
    vm = adopt(start_vm(compile_text(ECHO_SERVER_PROGRAM % (host, count), "echo", tmp_path), stdin=True))
    port = int(vm.next_line())
    replies = {}
    threads = [threading.Thread(target=fragmented_call, args=(host, port, "p%d" % k, replies)) for k in range(count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(scaled(30))
    for k in range(count):
        assert replies.get("p%d" % k) == "p%d-ñ!\n" % k, replies
        assert replies.get("p%d/eof" % k) == b"", replies
    assert vm.next_line() == "served"
    assert_port_free(host, port)
    vm.close_stdin()
    assert vm.wait() == 0, vm.stderr_text()


def test_server_serves_simultaneous_fragmented_python_clients_and_frees_its_port(tmp_path, adopt):
    serve_python_clients(tmp_path, adopt, "127.0.0.1", 12)


def python_echo(server, count):
    """Answers COUNT connections of SERVER at once, one thread each, with `name!`."""
    def answer(connection):
        with connection:
            reader = connection.makefile("rb")
            line = reader.readline()
            connection.sendall(line.rstrip(b"\n") + b"!\n")
            reader.read()

    threads = []
    for _ in range(count):
        connection, _ = server.accept()
        thread = threading.Thread(target=answer, args=(connection,))
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join(scaled(30))


def dial_python_server(tmp_path, host, count):
    with listener_on(host) as server:
        peer = threading.Thread(target=python_echo, args=(server, count))
        peer.start()
        result = run_text(tmp_path, "dial", DIAL_PROGRAM % (count, host, server.getsockname()[1]))
        peer.join(scaled(30))
    assert result.code == 0, result.stderr
    assert result.stdout == "".join('ok("c%d!")\n' % k for k in range(count))


def test_simultaneous_client_tasks_talk_to_a_python_server(tmp_path):
    dial_python_server(tmp_path, "127.0.0.1", 12)


def test_ipv6_client_and_server_with_python_peers(tmp_path, adopt):
    if not ipv6_localhost():
        pytest.skip("no IPv6 localhost")
    dial_python_server(tmp_path, "::1", 3)
    serve_python_clients(tmp_path, adopt, "::1", 3)


TLS_PROGRAM = """\
def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  IO.inspect(TLS.connect("127.0.0.1", TCP.local_port(listener), "ca.pem", 5000))
  IO.inspect(TLS.listen("127.0.0.1", 0, "cert.pem", "key.pem"))
  TCP.close_listener(listener)
end
"""


def test_tls_returns_an_error_where_it_is_not_built(tmp_path):
    """TCP ships without TLS on Windows: both TLS calls fail cleanly and the run ends normally."""
    if TLS_BUILT:
        pytest.skip("TLS is built here (tests/test_vm_tls.py)")
    result = run_text(tmp_path, "tls", TLS_PROGRAM)
    assert result.code == 0, result.stderr
    assert result.stdout == ('error("ssl-connect: connect failed (TLS needs Linux or macOS)")\n'
                             'error("ssl-make-server-context: setup failed (TLS needs Linux or macOS)")\n')
