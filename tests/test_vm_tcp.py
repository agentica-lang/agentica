"""The TCP builtins of the VM against Node peers.

fixtures/tcp-peer.js is the independent peer: `servers` listens on several
ports (fragments, resets, silence, ...) and prints their numbers as JSON;
`clients` connects to a VM server. Everything is on 127.0.0.1 or localhost
with port 0.
"""
import json
import re
import socket
import time

from tests.agentica_test import (FIXTURES, WAIT_SECONDS, Child, TestCase, run, run_vm, scaled, start_vm, tool,
                                 vm_environment)

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
  IO.inspect(TCP.send(stuck, big, 200))
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



REFUSED_HEAD = "tcp-connect: connection failed\n  hostname: 127.0.0.1\n  port number: %d\n"
RESET = 'error("error reading from stream port\\n  system error: Connection reset by peer; errno=104")\n'


class VmTcp(TestCase):
    def setUp(self):
        self.node = tool("node")

    def start_peer(self):
        """The Node servers: returns (peer, ports); the peer prints events such as `closed watch`."""
        peer = self.adopt(Child([self.node, PEER, "servers"]))
        return peer, json.loads(peer.next_line())

    def run_text(self, name, text, env=None):
        return run_vm(self.compile_text(text, name), env=vm_environment(env))

    def test_client_reads_fragments_eof_resets_long_lines_and_timeouts_from_node_peers(self):
        _, ports = self.start_peer()
        args = tuple(ports[name] for name in ("echo", "fragments", "reset", "long", "silent", "silent", "partial", "refused"))
        result = self.run_text("client", CLIENT_PROGRAM % args)
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "ñ\n"
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
            (REFUSED_HEAD % ports["refused"]) + "  system error: Connection refused; errno=111\n")

    def test_server_serves_two_node_clients_at_once_one_task_per_connection(self):
        vm = self.adopt(start_vm(self.compile_text(SERVER_PROGRAM, "server")))
        port = vm.next_line()
        clients = run([self.node, PEER, "clients", port], timeout=WAIT_SECONDS)
        self.assertEqual(clients.code, 0, clients.stderr)
        self.assertEqual(clients.stdout, "clients ok\n")
        self.assertEqual(vm.next_line(), "served")
        self.assertEqual(vm.wait(), 0, vm.stderr_text())

    def test_task_closes_the_connections_it_owns_when_it_crashes_or_returns(self):
        """The Node peer sees both close."""
        peer, ports = self.start_peer()
        vm = self.adopt(start_vm(self.compile_text(OWNERS_PROGRAM % (ports["watch"], ports["watch"]), "owners"),
                                 stdin=True))
        self.assertEqual(vm.next_line(), "false")
        self.assertEqual(vm.next_line(), "ready")
        self.assertEqual(peer.next_line(), "closed watch")
        self.assertEqual(peer.next_line(), "closed watch")
        vm.close_stdin()
        self.assertEqual(vm.wait(), 0, vm.stderr_text())

    def test_listener_on_localhost_takes_ipv4_and_ipv6_clients(self):
        ipv6 = ipv6_localhost()
        vm = self.adopt(start_vm(self.compile_text(LOCALHOST_PROGRAM, "localhost")))
        port = int(vm.next_line())

        def send_line(host, text):
            with socket.create_connection((host, port), timeout=scaled(10)) as connection:
                connection.sendall((text + "\n").encode())

        send_line("127.0.0.1", "v4")
        self.assertEqual(vm.next_line(), "v4")
        if ipv6:
            send_line("::1", "v6")
            self.assertEqual(vm.next_line(), "v6")
        send_line("127.0.0.1", "end")
        self.assertEqual(vm.next_line(), "end")
        self.assertEqual(vm.wait(), 0, vm.stderr_text())

    def test_listen_on_localhost_fails_when_another_program_holds_the_port_on_ipv6(self):
        if not ipv6_localhost():
            self.skipTest("no IPv6 localhost")
        # No SO_REUSEADDR, like the original holder: the VM must find the port taken.
        with socket.socket(socket.AF_INET6) as holder:
            holder.bind(("::1", 0))
            holder.listen(4)
            result = self.run_text("taken", TAKEN_PROGRAM % holder.getsockname()[1])
        self.assertEqual(result.code, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("tcp-listen: listen failed\n  hostname: localhost\n"), result.stdout)

    def trace_env(self):
        trace = self.make_temp_dir() / "vm.trace"
        return trace, {"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": str(trace)}

    def test_two_tasks_writing_to_one_socket_take_the_writer_lock_in_fifo_order(self):
        peer, ports = self.start_peer()
        trace, env = self.trace_env()
        result = self.run_text("writers", WRITERS_PROGRAM % ports["collect"], env)
        self.assertEqual((result.code, result.stdout), (0, "ok()\nok()\nok()\n"), result.stderr)
        size = 8 * 2 ** 21
        self.assertEqual(peer.next_line(), "collect a=%d b=%d c=%d" % (size, size, size))
        self.assertIn(" io lock_wait ", trace.read_text(), "a writer waited for the lock")

    def test_main_returns_while_tasks_wait_on_sockets_and_the_peer_sees_every_socket_close(self):
        peer, ports = self.start_peer()
        trace, env = self.trace_env()
        bytecode = self.compile_text(EXIT_PROGRAM % (ports["watch"], ports["silent"], ports["silent"]), "exit")
        # Only the VM run is timed: compiling through the CLI can be slow on a busy machine.
        started = time.monotonic()
        result = run_vm(bytecode, env=vm_environment(env))
        self.assertEqual((result.code, result.stdout), (0, "<Socket>\ndone\n"), result.stderr)
        self.assertLess(time.monotonic() - started, scaled(20))
        text = trace.read_text()
        self.assertRegex(text, re.compile(r" io end code=0 signal=0$", re.M), text)
        self.assertIn(" io tcp_listen listener=", text, "listen is traced")
        self.assertIn(" io tcp_connected socket=", text, "connect is traced")
        self.assertEqual(peer.next_line(), "closed watch")
