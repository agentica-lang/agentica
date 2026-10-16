"""Task.map: the cases whose outcome depends on the clock or on a peer.

Run alone by `make vm-task-map` (and not by `make test`, see PY_ALONE in the
Makefile), so the VMs have the CPU to themselves. The golden fixtures
(tests/fixtures/vm/task-map-*) hold everything that does not depend on timing.
Here: the bound on the items in flight, a timeout that cancels the item and
everything it started, a read that is detached when its item times out, HTTP
requests against a local ThreadingHTTPServer, and RUNTIME-TASK-CANCELLED. The
bounds that must hold are exact or one-sided, and the upper bounds are generous.
"""
import json
import os
import re
import select
import socket
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from tests.agentica_test import TestCase, run_vm, scaled, start_vm

# A program writes a time as @250@ (milliseconds); timed() scales it like every other deadline, so a loaded runner
# stretches the sleeps and the deadlines together and the order of events does not change.
TIME = re.compile(r"@(\d+)@")


def timed(program):
    return TIME.sub(lambda match: str(scaled(int(match.group(1)))), program)


IN_FLIGHT_PROGRAM = """\
def work(n: Int) -> Result[Int]
  puts("start #{n}")
  Task.sleep(@250@)
  puts("end #{n}")
  return ok(n * 10)
end

def main() -> Void
  t0 = Time.monotonic_ms()
  narrow = Task.map(Range.to_a(0..7), 2, 5000) do |n|
    work(n)
  end
  t1 = Time.monotonic_ms()
  wide = Task.map(Range.to_a(0..7), 8, 5000) do |n|
    work(n)
  end
  t2 = Time.monotonic_ms()
  puts("narrow #{narrow}")
  puts("narrow ms #{t1 - t0}")
  puts("wide #{wide}")
  puts("wide ms #{t2 - t1}")
end
"""

TIMEOUT_PROGRAM = """\
def late(n: Int) -> Void
  Task.sleep(@1500@)
  puts("late child #{n} printed")
end

def main() -> Void
  results = Task.map([1, 2, 3, 4], 4, @200@) do |n|
    if n == 2
      Task.spawn(&late, n)
      Task.sleep(60000)
    end
    if n == 3
      Task.sleep(@1000@)
      puts("item 3 ran on after its timeout")
    end
    ok(n)
  end
  puts(results)
  Task.sleep(@2500@)
  puts("main done")
end
"""

GRANDCHILD_PROGRAM = """\
def grandchild(n: Int) -> Void
  Task.sleep(@1200@)
  puts("grandchild printed")
end

def child(n: Int) -> Void
  Task.spawn(&grandchild, n)
end

def main() -> Void
  results = Task.map([1], 1, @200@) do |n|
    Task.spawn(&child, n)
    Task.sleep(60000)
    ok(n)
  end
  puts(results)
  Task.sleep(@2000@)
  puts("main done")
end
"""

NESTED_PROGRAM = """\
def outer(n: Int) -> Result[Int]
  inner = Task.map([1, 2, 3], 1, 5000) do |i|
    puts("start #{i}")
    Task.sleep(@400@)
    puts("end #{i}")
    ok(i)
  end
  return ok(inner.size)
end

def main() -> Void
  results = Task.map([1], 1, @150@) do |n|
    outer(n)
  end
  puts(results)
  Task.sleep(@1800@)
  puts("main done")
end
"""

DETACHED_READ_PROGRAM = """\
def main() -> Void
  port = Result.unwrap!(String.to_int(System.args()[0]))
  socket = Result.unwrap!(TCP.connect("127.0.0.1", port, 5000))
  results = Task.map([1], 1, @300@) do |n|
    line = try TCP.read_line(socket, 20000)
    ok(line)
  end
  puts(results)
  puts("main reads")
  IO.inspect(TCP.read_line(socket, 20000))
  TCP.close(socket)
end
"""

HTTP_PRELUDE = """\
import HTTP from "std/http"

def client() -> HttpClient
  options = HttpClientOptions(timeout_ms: 20000, idle_timeout_ms: 30000, max_connections: 16, max_body_bytes: 1000,
                              ca_file: "")
  return HTTP.client(options).unwrap!
end

def base() -> String
  return "http://127.0.0.1:#{System.args()[0]}"
end
"""

HTTP_PROGRAM = HTTP_PRELUDE + """
def main() -> Void
  pool = client()
  t0 = Time.monotonic_ms()
  bounded = Task.map(Range.to_a(0..8), 3, 20000) do |i|
    response = try HTTP.get(pool, "#{base()}/a/#{i}")
    ok(response.body)
  end
  t1 = Time.monotonic_ms()
  everyone = Task.map(Range.to_a(0..7), 8, 20000) do |i|
    response = try HTTP.get(pool, "#{base()}/b/#{i}")
    ok(response.body)
  end
  t2 = Time.monotonic_ms()
  puts("bounded #{bounded}")
  puts("bounded ms #{t1 - t0}")
  puts("everyone #{everyone}")
  puts("everyone ms #{t2 - t1}")
end
"""

HTTP_TIMEOUT_PROGRAM = HTTP_PRELUDE + """
def main() -> Void
  pool = client()
  results = Task.map(["/slow"], 1, @300@) do |path|
    response = try HTTP.get(pool, base() + path)
    ok(response.body)
  end
  puts(results)
  puts("call done")
  IO.flush()
  Task.sleep(@3500@)
  puts("main done")
end
"""

CANCELLED_AFTER_PROGRAM = """\
def sleeper(n: Int) -> Int
  Task.sleep(60000)
  return n
end

def main() -> Void
  handles: Channel[Task[Int]] = Channel.new(1)
  results = Task.map([1], 1, @200@) do |n|
    child = Task.spawn(&sleeper, n)
    Result.unwrap!(handles.send(child, 1000))
    Task.sleep(60000)
    ok(n)
  end
  puts(results)
  child = Result.unwrap!(handles.recv(1000))
  puts(Task.await(child))
  puts("not reached")
end
"""

CANCELLED_PARKED_PROGRAM = """\
def sleeper(n: Int) -> Int
  Task.sleep(60000)
  return n
end

def run_map(handles: Channel[Task[Int]]) -> Int
  results = Task.map([1], 1, @300@) do |n|
    child = Task.spawn(&sleeper, n)
    Result.unwrap!(handles.send(child, 1000))
    Task.sleep(60000)
    ok(n)
  end
  return results.size
end

def main() -> Void
  handles: Channel[Task[Int]] = Channel.new(1)
  Task.spawn(&run_map, handles)
  child = Result.unwrap!(handles.recv(5000))
  puts("main awaits")
  puts(Task.await(child))
  puts("not reached")
end
"""

# Receiver 1 is a Task.map item that waits in recv for longer than its deadline; receiver 2 starts waiting after it.
# The sender sends after the item timed out, so the value goes to receiver 2.
HAND_OFF_TIMED_OUT_PROGRAM = """\
def second(jobs: Channel[Int]) -> Void
  Task.sleep(50)
  IO.inspect(jobs.recv(5000))
end

def sender(jobs: Channel[Int]) -> Void
  Task.sleep(@700@)
  IO.inspect(jobs.send(7, 1000))
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(1)
  Task.spawn(&second, jobs)
  Task.spawn(&sender, jobs)
  results = Task.map([1], 1, @250@) do |n|
    got = try jobs.recv(5000)
    ok(got)
  end
  puts(results)
  Task.sleep(@1000@)
end
"""

# The sender hands the value to the item and then holds the CPU in one builtin (a sort does not yield) past the item's
# deadline. The deadline is the sender's wait plus half the time of the same sort run beforehand, so the sender sends
# before the deadline and the sort ends after it, on a fast machine and on a slow one. The item runs before the caller
# of Task.map looks at the clock, so it keeps the value; nothing is lost and receiver 2 gets nothing.
HAND_OFF_HELD_PROGRAM = """\
struct Hold
  jobs: Channel[Int]
  big: List[String]
  wait: Int
  start: Int
  tail: Int
end

def second(hold: Hold) -> Void
  Task.sleep(5)
  IO.inspect(hold.jobs.recv(hold.tail))
end

def sender(hold: Hold) -> Void
  Task.sleep(hold.wait)
  sent = Time.monotonic_ms()
  Result.unwrap!(hold.jobs.send(7, 1000))
  sorted = List.sort(hold.big)
  puts("sent #{sent - hold.start} held #{Time.monotonic_ms() - sent}")
end

def main() -> Void
  big = Range.to_a(1..1000000).map do |x| "k#{x}" end
  before = Time.monotonic_ms()
  trial = List.sort(big)
  trial_ms = Time.monotonic_ms() - before
  wait = @100@
  deadline = wait + trial_ms / 2
  puts("deadline #{deadline}")
  jobs: Channel[Int] = Channel.new(1)
  start = Time.monotonic_ms()
  Task.spawn(&second, Hold(jobs: jobs, big: big, wait: 0, start: start, tail: deadline + @1000@))
  Task.spawn(&sender, Hold(jobs: jobs, big: big, wait: wait, start: start, tail: 0))
  results = Task.map([1], 1, deadline) do |n|
    got = try jobs.recv(60000)
    ok(got)
  end
  puts(results)
  Task.sleep(deadline + @1500@)
end
"""

SEED_PROGRAM = """\
def main() -> Void
  reverse = System.args()[0] == "reverse"
  results = Task.map(Range.to_a(0..5), 3, 5000) do |i|
    if reverse
      Task.sleep((6 - i) * 25)
    else
      Task.sleep(i * 25)
    end
    ok(Random.int(0, 1000000))
  end
  puts(results)
end
"""


TIMED_OUT = '[error("task: timed out")]'


def position(text, needle):
    """The line and column (both from 1) of the first `needle` in `text`."""
    index = text.index(needle)
    return text.count("\n", 0, index) + 1, index - (text.rfind("\n", 0, index) + 1) + 1


def in_flight(lines, first, count):
    """The most start lines without their end lines in `count` lines of start/end events from `first`."""
    now = most = 0
    for line in lines[first:first + count]:
        now += 1 if line.startswith("start") else -1
        assert now >= 0, lines
        most = max(most, now)
    return most


class Peer(ThreadingHTTPServer):
    """The HTTP peer: it records the requests in flight and keeps a connection open to see who closes it."""
    daemon_threads = True
    # The default queue holds 5 connections, and one call opens 8 at once.
    request_queue_size = 32

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.events = []
        self.closed_at = None
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def record(self, kind, path):
        with self.lock:
            self.events.append((kind, path))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        kind, _, number = self.path[1:].partition("/")
        self.server.record("start", self.path)
        if kind == "a":
            time.sleep(scaled(0.3))
        elif kind == "b":
            # The later the request, the shorter the wait, so the responses end in reverse order.
            time.sleep(scaled(0.5 + 0.05 * (7 - int(number))))
        else:
            time.sleep(scaled(2.0))
        body = ("item " + number if number else "slow").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.server.record("end", self.path)
        if kind == "slow":
            # A client that keeps the connection in its pool leaves it open; one that drops it shows end of file.
            readable = select.select([self.connection], [], [], scaled(8.0))[0]
            if readable and self.connection.recv(1, socket.MSG_PEEK) == b"":
                self.server.closed_at = time.monotonic()


class VmTaskMap(TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if os.environ.get("AGENTICA_VM_BINARY"):
            raise unittest.SkipTest("AGENTICA_VM_BINARY names another binary")

    def run_lines(self, program, name, *args, flags=()):
        result = run_vm(self.compile_text(timed(program), name), *flags, args=args)
        self.assertEqual(result.code, 0, result.stderr)
        return result.stdout.splitlines()

    def diagnostic(self, program, name, *args):
        """The JSON diagnostic of a run that halts, from either output stream."""
        result = run_vm(self.compile_text(timed(program), name), "--json", args=args)
        self.assertEqual(result.code, 1, result.stdout + result.stderr)
        text = result.stderr if result.stderr.strip().startswith("{") else result.stdout
        return json.loads(text.strip().splitlines()[-1])

    def peer(self):
        peer = Peer()
        self.addCleanup(peer.server_close)
        self.addCleanup(peer.shutdown)
        return peer

    def test_the_limit_bounds_the_items_in_flight_and_the_results_keep_input_order(self):
        lines = self.run_lines(IN_FLIGHT_PROGRAM, "in-flight")
        events, report = lines[:32], lines[32:]
        self.assertEqual(in_flight(events, 0, 16), 2)
        self.assertEqual(in_flight(events, 16, 16), 8)
        ok = "[" + ", ".join("ok(%d)" % (n * 10) for n in range(8)) + "]"
        self.assertEqual(report[0], "narrow " + ok)
        self.assertEqual(report[2], "wide " + ok)
        # Four waves of one sleep (a timer can fire a millisecond early); the serial run takes eight.
        sleep = scaled(250)
        self.assertGreaterEqual(int(report[1].split()[2]), 3.6 * sleep)
        self.assertLess(int(report[3].split()[2]), 7.2 * sleep)

    def test_http_requests_overlap_within_the_limit_and_come_back_in_input_order(self):
        peer = self.peer()
        lines = self.run_lines(HTTP_PROGRAM, "http", str(peer.server_address[1]))
        events = [(kind, path) for kind, path in peer.events]
        for group, limit in (("/a/", 3), ("/b/", 8)):
            flight = most = 0
            for kind, path in events:
                if path.startswith(group):
                    flight += 1 if kind == "start" else -1
                    most = max(most, flight)
            self.assertEqual(most, limit, group)
        ended = [path for kind, path in events if kind == "end" and path.startswith("/b/")]
        self.assertEqual(sorted(ended), sorted("/b/%d" % n for n in range(8)))
        self.assertNotEqual(ended, ["/b/%d" % n for n in range(8)], "the peer answers the later requests first")
        self.assertEqual(lines[0], "bounded [" + ", ".join('ok("item %d")' % n for n in range(9)) + "]")
        self.assertEqual(lines[2], "everyone [" + ", ".join('ok("item %d")' % n for n in range(8)) + "]")
        # Three waves of 300 ms at least. The eight slow requests take 4.2 s one after the other.
        self.assertGreaterEqual(int(lines[1].split()[2]), 2.7 * scaled(300))
        self.assertLess(int(lines[3].split()[2]), scaled(3500))

    def test_an_item_that_times_out_is_cancelled_with_everything_it_started(self):
        started = time.monotonic()
        lines = self.run_lines(TIMEOUT_PROGRAM, "timeout")
        self.assertEqual(lines, ['[ok(1), error("task: timed out"), error("task: timed out"), ok(4)]', "main done"])
        self.assertLess(time.monotonic() - started, scaled(30), "the item that sleeps 60 s does not hold the run")

    def test_a_grandchild_of_a_timed_out_item_is_cancelled_after_its_parent_ended(self):
        lines = self.run_lines(GRANDCHILD_PROGRAM, "grandchild")
        self.assertEqual(lines, [TIMED_OUT, "main done"])

    def test_a_nested_map_in_a_timed_out_item_starts_no_more_items(self):
        lines = self.run_lines(NESTED_PROGRAM, "nested")
        self.assertEqual(lines, ["start 1", TIMED_OUT, "main done"])

    def test_a_read_in_a_timed_out_item_is_detached_and_its_socket_stays_open(self):
        listener = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(listener.close)

        def serve():
            connection, _ = listener.accept()
            with connection:
                time.sleep(scaled(1.0))
                connection.sendall(b"first\n")
                time.sleep(scaled(0.6))
                connection.sendall(b"second\n")
                time.sleep(scaled(0.5))

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        lines = self.run_lines(DETACHED_READ_PROGRAM, "detached", str(listener.getsockname()[1]))
        # The read of the item took "first" and dropped it; the socket was not closed, so main reads the next line.
        self.assertEqual(lines, [TIMED_OUT, "main reads", 'ok("second")'])
        thread.join(scaled(10))

    def test_a_timed_out_http_item_leaves_no_pooled_connection(self):
        peer = self.peer()
        vm = self.adopt(start_vm(self.compile_text(timed(HTTP_TIMEOUT_PROGRAM), "http-timeout"),
                                 str(peer.server_address[1])))
        self.assertEqual(vm.next_line(), TIMED_OUT)
        self.assertEqual(vm.next_line(), "call done")
        self.assertEqual(vm.next_line(), "main done")
        finished = time.monotonic()
        # The detached request ends after 2 s and the client drops the connection then, long before the run ends.
        self.assertIsNotNone(peer.closed_at, "the peer saw no end of file")
        self.assertLess(peer.closed_at, finished - 0.5)
        self.assertEqual(vm.wait(), 0)

    def test_await_of_a_handle_that_a_timed_out_item_passed_out_is_task_cancelled(self):
        programs = ((CANCELLED_AFTER_PROGRAM, "cancelled-after"), (CANCELLED_PARKED_PROGRAM, "cancelled-parked"))
        for program, name in programs:
            with self.subTest(name):
                diagnostic = self.diagnostic(program, name)
                self.assertEqual(diagnostic["code"], "RUNTIME-TASK-CANCELLED")
                line, column = position(program, "Task.await(child)")
                self.assertEqual(diagnostic["range"]["start"], {"line": line, "column": column})

    def test_a_timed_out_receiver_leaves_the_channel_queue(self):
        lines = self.run_lines(HAND_OFF_TIMED_OUT_PROGRAM, "hand-off-timed-out")
        self.assertEqual(lines[0], TIMED_OUT)
        # The sender's result and the value that receiver 2 gets; which prints first is not the point.
        self.assertEqual(sorted(lines[1:]), ["ok()", "ok(7)"])

    def test_a_value_handed_to_an_item_before_its_deadline_is_kept_when_the_deadline_passes_in_the_same_turn(self):
        # The run is conclusive only if the sender sent before the deadline and its sort ended after it, each by a
        # margin. A stall at the wrong moment makes it inconclusive, and then it runs again.
        for attempt in range(3):
            lines = self.run_lines(HAND_OFF_HELD_PROGRAM, "hand-off-held")
            deadline = int(re.search(r"^deadline (\d+)$", "\n".join(lines), re.M).group(1))
            sent, held = map(int, re.search(r"^sent (\d+) held (\d+)$", "\n".join(lines), re.M).groups())
            if sent + 30 < deadline < sent + held - 30:
                break
        else:
            self.fail("the sort did not cross the deadline in 3 runs: %s" % lines)
        # The item runs before the caller of Task.map looks at the clock, so it keeps the value, and receiver 2 gets
        # nothing: the value is neither lost nor copied.
        self.assertIn("[ok(7)]", lines)
        self.assertIn('error("channel: timed out")', lines)
        self.assertNotIn("ok(7)", lines)

    def test_the_arguments_are_diagnostics_at_their_own_span(self):
        cases = [
            ("limit 0", "Task.map([1], 0, 100)", "0, 100", "RUNTIME-INVALID-COUNT"),
            ("limit 1025", "Task.map([1], 1025, 100)", "1025", "RUNTIME-INVALID-COUNT"),
            ("empty list", "Task.map(empty, 0, 100)", "0, 100", "RUNTIME-INVALID-COUNT"),
            ("timeout 0", "Task.map([1], 2, 0)", "0)", "RUNTIME-INVALID-DURATION"),
            ("timeout -5", "Task.map([1], 2, -5)", "-5", "RUNTIME-INVALID-DURATION"),
        ]
        for name, call, argument, code in cases:
            with self.subTest(name):
                program = "def main() -> Void\n  empty: List[Int] = []\n  puts(%s do |n| ok(n) end)\nend\n" % call
                diagnostic = self.diagnostic(program, "arguments")
                self.assertEqual(diagnostic["code"], code)
                line, column = position(program, call)
                column += call.index(argument)
                self.assertEqual(diagnostic["range"]["start"], {"line": line, "column": column})

    def test_a_seed_gives_the_same_random_numbers_whatever_order_the_items_end_in(self):
        results = [self.run_lines(SEED_PROGRAM, "seed", order, flags=("--seed", "7"))[0]
                   for order in ("forward", "reverse", "forward")]
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0], results[2])
        self.assertGreater(len(set(re.findall(r"ok\((\d+)\)", results[0]))), 1, "each item has its own stream")
