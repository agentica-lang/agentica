"""Programs on several scheduler threads (AGENTICA_VM_TEST_MULTICORE=1, --schedulers 4).

More than one scheduler runs only under that test switch until the count is lifted (#345). The goldens of
tests/fixtures/vm must hold at four schedulers too, except where the order of output between tasks is not fixed (the
ORDER set) and for the libraries that still call libuv from their scheduler, which a run with several schedulers
refuses (Process, Duplex and the Test protocol). TCP, TLS and the HTTP server post every step to the I/O thread, so
their fixtures run here. The other cases check what threads must keep: whole lines, exact sums, timers that fire, the end of
the run from any scheduler, standard input and FIFOs, sockets used and closed from several schedulers, and the switch.
`make test-multicore` runs this module; `make vm-tsan-run` runs it on a ThreadSanitizer build.
"""
import json
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading

import pytest

try:
    import fcntl
except ImportError:
    fcntl = None

from tests.agentica_test import FIXTURES, ROOT, compile_text, run, vm_command, vm_environment
from tests import vm_diff_support as diff

SCHEDULERS = os.environ.get("AGENTICA_VM_TEST_SCHEDULER_COUNT", "4")
MULTICORE = {"AGENTICA_VM_TEST_MULTICORE": "1"}
FLAGS = ["--schedulers", SCHEDULERS]
# A race case runs once in the fast tier and 20 times in the slow tier (make test-slow).
RACE = pytest.mark.parametrize("repeats", [1, pytest.param(20, marks=pytest.mark.slow)], ids=["once", "20x"])

# The output of these fixtures depends on how tasks interleave (prints from several tasks, a race against a deadline,
# which of two tasks finds an await cycle, whether a task has run after a yield or a preemption, the count of tasks
# still pending),
# which a run on several threads does not fix. channel-owner-ends counts on a yield (Task.sleep(0)) letting a task it
# spawned send first; a spinning scheduler takes that task at once and runs it beside the yielder.
# http-client-close-queued counts on the same yield: on another thread the new worker may connect before
# close_client runs (the call still gets "http: client is closed", but the server sees a connection).
ORDER = {"channel-fan-in", "channel-owner-ends", "channel-owner-handoff", "channel-returned-order", "handle-spawn-owning",
         "http-client-close-queued", "logger-tasks",
         "task-await-cycle", "task-crash-descendants", "task-crash-result", "task-pending-count", "task-preempt-fail",
         "task-file-close", "tcp-tasks", "test-run-task"}
# Builtins that a run with several schedulers refuses (agc_program_for_threads in vm/builtin_tables.c, and Test.run on
# the parent channel): such a fixture keeps its golden or stops with RUNTIME-INTERNAL.
LOOP_BOUND = re.compile(r"\b(Process|Duplex)\.|\bTest\.run\b")


def vm(bytecode, *flags, args=(), stdin=None, env=None, timeout=None):
    extra = {**MULTICORE, **(env or {})}
    options = {} if timeout is None else {"timeout": timeout}
    return run([*vm_command(), *FLAGS, *flags, "--", bytecode, *args], stdin=stdin, env=vm_environment(extra),
               **options)


def program(tmp_path, name, text):
    return compile_text(text, name, tmp_path)


def fixture_cases():
    cases = []
    for path in diff.fixture_programs():
        if path.stem in ORDER:
            continue
        bound = LOOP_BOUND.search(path.read_text(encoding="utf-8")) is not None
        cases.append(pytest.param(path, bound, id=path.stem))
    return cases


@pytest.mark.parametrize("path,bound", fixture_cases())
def test_a_fixture_keeps_its_golden_on_four_schedulers(path, bound, tmp_path):
    reason = diff.skip_reason(path.name)
    if reason:
        pytest.skip(reason)
    fixture = diff.Fixture.of(path)
    bytecode = diff.compile_agc(path, tmp_path / (path.stem + ".agcb"))
    root = diff.source_root_options() + FLAGS
    if fixture.uses_tmp:
        directory = diff.fresh_tmp(tmp_path)
        try:
            result = diff.untmp(directory, diff.run_vm_process(
                fixture, diff.allow_options(fixture) + diff.style_options("json") + root, bytecode,
                diff.tmp_args(fixture, directory), cwd=tmp_path, env=MULTICORE))
        finally:
            shutil.rmtree(directory, ignore_errors=True)
    else:
        result = diff.run_vm(fixture, bytecode, 0, root=root, cwd=tmp_path, env=MULTICORE)
    seen = diff.outcome(diff.unfixture(result))
    if bound and seen[3] == "RUNTIME-INTERNAL":
        assert refused_at_a_bound_call(result[2]), result[2]
        return
    assert seen == diff.read_expected(path)


def refused_at_a_bound_call(stderr):
    """True when the last diagnostic's span starts on a source line that calls a refused builtin: the refusal, not
    another RUNTIME-INTERNAL (a stall has no span)."""
    try:
        parsed = json.loads(stderr.rstrip("\n").rsplit("\n", 1)[-1])
        name, line = parsed["file"], parsed["range"]["start"]["line"]
    except (ValueError, KeyError, TypeError):
        return False
    if name.startswith("@"):
        source = ROOT / "tests" / name[1:]
    elif name.startswith("std/"):
        source = ROOT / "stdlib" / name[len("std/"):]
    else:
        source = ROOT / name
    lines = source.read_text(encoding="utf-8").splitlines()
    return 0 < line <= len(lines) and LOOP_BOUND.search(lines[line - 1]) is not None


FAN_OUT = """\
def work(n: Int) -> Int
  total = 0
  i = 0
  while i < n
    total = total + i % 7
    i = i + 1
  end
  return total
end

def main() -> Void
  tasks = (1..16).to_a.map do |k|
    Task.spawn(&work, 20000 + k)
  end
  sum = 0
  for t in tasks
    sum = sum + Task.await(t)
  end
  puts(sum)
end
"""


def expected_fan_out():
    return sum(sum(i % 7 for i in range(20000 + k)) for k in range(1, 17))


@RACE
def test_tasks_on_four_schedulers_give_the_exact_sum(tmp_path, repeats):
    bytecode = program(tmp_path, "fan", FAN_OUT)
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stdout, result.stderr) == (0, "%d\n" % expected_fan_out(), "")


PRINTERS = """\
def printer(id: Int) -> Int
  i = 0
  while i < 2000
    puts("task #{id} line #{i} xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    i = i + 1
  end
  return id
end

def main() -> Void
  tasks = (1..8).to_a.map do |k|
    Task.spawn(&printer, k)
  end
  for t in tasks
    Task.await(t)
  end
  IO.warn("done")
end
"""


@RACE
def test_prints_from_eight_tasks_stay_whole_lines(tmp_path, repeats):
    bytecode = program(tmp_path, "printers", PRINTERS)
    line = re.compile(r"task ([1-8]) line (\d+) x{40}")
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stderr) == (0, "done\n")
        lines = result.stdout.splitlines()
        assert len(lines) == 16000
        last = {}
        for text in lines:
            match = line.fullmatch(text)
            assert match, text
            task, number = int(match.group(1)), int(match.group(2))
            assert number == last.get(task, -1) + 1
            last[task] = number


CHANNELS = """\
def producer(ch: Channel[Int]) -> Result[Int]
  i = 1
  while i <= 500
    try ch.send(i, 10000)
    i = i + 1
  end
  return ok(0)
end

def consumer(ch: Channel[Int]) -> Int
  total = 0
  while true
    case ch.recv(200)
      ok(n) -> total = total + n
      error(_) -> break
    end
  end
  return total
end

def main() -> Void
  ch: Channel[Int] = Channel.new(4)
  producers = (1..6).to_a.map do |k|
    Task.spawn(&producer, ch)
  end
  consumers = (1..3).to_a.map do |k|
    Task.spawn(&consumer, ch)
  end
  for p in producers
    Task.await(p)
  end
  total = 0
  for c in consumers
    total = total + Task.await(c)
  end
  puts(total)
end
"""


@RACE
def test_a_contended_channel_loses_and_repeats_no_value(tmp_path, repeats):
    bytecode = program(tmp_path, "channels", CHANNELS)
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stdout, result.stderr) == (0, "%d\n" % (6 * 500 * 501 // 2), "")


LAZY_IO = """\
def producer(ch: Channel[Int]) -> Void
  for i in 1..500
    Result.unwrap!(ch.send(i, 60000))
  end
end

def consumer(ch: Channel[Int]) -> Int
  return ch.lazy(60000).filter do |n| n > 0 end.reduce(0) do |sum, n| sum + n end.unwrap!
end

def lengths(path: String) -> Int
  return File.foreach(path, 1024, 60000).map do |line| line.length end.reduce(0) do |sum, n| sum + n end.unwrap!
end

def main() -> Void
  path = System.args()[0]
  ch: Channel[Int] = Channel.new(4)
  producers = (1..6).to_a.map do |k|
    Task.spawn(&producer, ch)
  end
  consumers = (1..3).to_a.map do |k|
    Task.spawn(&consumer, ch)
  end
  readers = (1..4).to_a.map do |k|
    Task.spawn(&lengths, path)
  end
  for p in producers
    Task.await(p)
  end
  ch.close
  total = 0
  for c in consumers
    total = total + Task.await(c)
  end
  read = 0
  for r in readers
    read = read + Task.await(r)
  end
  puts(total)
  puts(read)
end
"""


# The steps of a terminal over a channel or a file park and touch channel and task lists, so they take rt->sync
# (agc_stepper.unlocked is false for them): three ch.lazy consumers lose and repeat no value, and four File.foreach
# readers each read the whole file, on four schedulers.
@RACE
def test_lazy_terminals_over_a_contended_channel_and_a_file_on_four_schedulers(tmp_path, repeats):
    data = tmp_path / "lines.txt"
    data.write_text("".join("line %d\n" % k for k in range(2000)), encoding="utf-8")
    per_reader = sum(len("line %d" % k) for k in range(2000))
    bytecode = program(tmp_path, "lazy_io", LAZY_IO)
    for _ in range(repeats):
        result = vm(bytecode, args=[str(data)])
        expected = "%d\n%d\n" % (6 * 500 * 501 // 2, 4 * per_reader)
        assert (result.code, result.stdout, result.stderr) == (0, expected, "")


SLEEPERS = """\
def sleeper(ms: Int) -> Int
  Task.sleep(ms)
  return 1
end

def main() -> Void
  tasks = (1..1000).to_a.map do |k|
    Task.spawn(&sleeper, k % 40)
  end
  sum = 0
  for t in tasks
    sum = sum + Task.await(t)
  end
  puts(sum)
end
"""


@RACE
def test_a_thousand_sleepers_all_wake(tmp_path, repeats):
    bytecode = program(tmp_path, "sleepers", SLEEPERS)
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stdout, result.stderr) == (0, "1000\n", "")


CANCELS = """\
def slow(ms: Int) -> Result[Int]
  Task.sleep(ms)
  return ok(ms)
end

def delay(k: Int) -> Int
  if k % 2 == 0
    return 5000
  end
  return 0
end

def main() -> Void
  delays = (1..200).to_a.map do |k|
    delay(k)
  end
  results = Task.map(delays, 50, 100, &slow)
  done = 0
  for r in results
    if r.ok?
      done = done + 1
    end
  end
  puts(done)
  puts(Task.pending_count())
end
"""


@RACE
def test_task_map_cancels_its_late_items_on_every_scheduler(tmp_path, repeats):
    bytecode = program(tmp_path, "cancels", CANCELS)
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stdout, result.stderr) == (0, "100\n0\n", "")


EXIT = """\
def spinner(n: Int) -> Int
  i = 0
  while true
    i = i + 1
  end
  return i
end

def quitter(n: Int) -> Int
  Task.sleep(20)
  puts("bye")
  System.exit(7)
  return n
end

def main() -> Void
  Task.spawn(&spinner, 1)
  Task.spawn(&spinner, 2)
  Task.spawn(&spinner, 3)
  puts(Task.await(Task.spawn(&quitter, 0)))
end
"""


@RACE
def test_system_exit_in_a_task_ends_a_run_whose_other_schedulers_spin(tmp_path, repeats):
    bytecode = program(tmp_path, "exit", EXIT)
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stdout, result.stderr) == (7, "bye\n", "")


RALLIES = """\
struct Pair
  ping: Channel[Int]
  pong: Channel[Int]
end

def echo(p: Pair) -> Int
  n = 0
  while n >= 0
    case p.ping.recv(2000)
      ok(v) ->
        _ = p.pong.send(v + 1, 2000)
        n += 1
      error(_) -> return -1
    end
  end
  return n
end

def play(p: Pair) -> Int
  i = 0
  while i >= 0
    _ = p.ping.send(i, 2000)
    case p.pong.recv(2000)
      ok(v) -> i = v
      error(_) -> return -1
    end
  end
  return i
end

def pair() -> Pair
  p = Pair(ping: Channel.new(1), pong: Channel.new(1))
  _ = Task.spawn(&echo, p)
  return p
end

def rally(k: Int) -> Result[Int]
  return ok(play(pair()))
end

def doomed(k: Int) -> Result[Int]
  (1..3).to_a.each do |j|
    _ = Task.spawn(&play, pair())
  end
  Task.sleep(20)
  return ok(10 / (k - k))
end

def main() -> Void
  results = Task.map((1..8).to_a, 8, 50, &rally)
  timed = 0
  for r in results
    if !r.ok?
      timed += 1
    end
  end
  puts(timed)
  case Task.await(Task.spawn(&doomed, 1))
    ok(_) -> puts("ok")
    error(_) -> puts("crashed")
  end
  while Task.pending_count() > 0
    Task.sleep(1)
  end
  puts(Task.pending_count())
end
"""


@RACE
def test_tasks_that_wake_each_other_end_when_cancelled_from_any_scheduler(tmp_path, repeats):
    # Pairs of tasks wake each other for ever, so most of the time one of each pair waits in the runnext slot of the
    # scheduler that woke it (§16.9, "Wakes between schedulers"). Task.map cancels eight such pairs at their deadline
    # and a crashing owner cancels three more, from whichever scheduler runs the canceller: every task ends (the pending
    # count reaches 0) and the run exits normally. A task cancelled on another scheduler finishes its turn first, so an
    # item that starts only after its deadline (a loaded machine) may spawn its echo after the cancel; that echo starts
    # cancelled (#392). The waits keep a 2 s deadline as a bound.
    bytecode = program(tmp_path, "rallies", RALLIES)
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stdout) == (0, "8\ncrashed\n0\n")
        assert result.stderr.count("RUNTIME-DIVISION-BY-ZERO") == 1


SPAWNS_AFTER_CANCEL = """\
def sleeper(k: Int) -> Int
  %s
  return k
end

def spawner(k: Int) -> Result[Int]
  n = 0
  while n >= 0
    i = 0
    while i < 150
      i += 1
    end
    %s
    n += 1
  end
  return ok(n)
end

def main() -> Void
  IO.inspect(Task.map([1, 2, 3], 3, 20, &spawner))
  tries = 0
  while Task.pending_count() > 0 && tries < 300
    Task.sleep(10)
    tries += 1
  end
  puts(Task.pending_count())
end
"""


# The child sleeps and is left alone, or returns at once and is awaited: the await of a child that started cancelled
# fails in the cancelled task's last turn, which then ends as cancelled, not as a crash.
SPAWN_FORMS = {"spawn": ("Task.sleep(30000)", "Task.spawn(&sleeper, n)"),
               "await": ("", "Task.await(Task.spawn(&sleeper, n))")}


@RACE
@pytest.mark.parametrize("form", sorted(SPAWN_FORMS))
def test_a_task_cancelled_on_another_scheduler_spawns_only_cancelled_children(tmp_path, repeats, form):
    # Three items spawn a sleeper every few hundred steps, so they run nearly all the time (few children wait ahead of
    # them in the queue), and when Task.map cancels them at their 20 ms deadline one is almost always in a turn on another
    # scheduler, which it finishes before the cancel takes effect (§10.2.3). The sleepers spawned in that last turn,
    # after the cancel walk over the item's children, start cancelled (#392): no task is left. Before, they slept their
    # 30 s and the pending count stayed above 0 (the race was hit in 20 of 20 traced runs). In the await form the
    # task then failed with RUNTIME-TASK-CANCELLED as a crash, and the run exited 1.
    bytecode = program(tmp_path, "spawns_after_cancel", SPAWNS_AFTER_CANCEL % SPAWN_FORMS[form])
    for _ in range(repeats):
        result = vm(bytecode)
        timed_out = ", ".join(['error("task: timed out")'] * 3)
        assert (result.code, result.stdout) == (0, "[%s]\n0\n" % timed_out), result.stderr


CRASH = """\
def bad(n: Int) -> Int
  return 10 / (n - n)
end

def spinner(n: Int) -> Int
  i = 0
  while i < n
    i = i + 1
  end
  return i
end

def main() -> Void
  spin = Task.spawn(&spinner, 3000000)
  (1..20).to_a.each do |k|
    Task.spawn(&bad, k)
  end
  puts(Task.await(spin))
  puts(bad(0))
end
"""


@RACE
def test_crashes_on_several_schedulers_then_a_fatal_one_in_main(tmp_path, repeats):
    bytecode = program(tmp_path, "crash", CRASH)
    for _ in range(repeats):
        result = vm(bytecode, "--json")
        seen = diff.outcome((result.code, result.stdout, result.stderr))
        assert seen[:2] == (1, "3000000\n"), result
        assert seen[3] == "RUNTIME-DIVISION-BY-ZERO", result


CONSTANTS = """\
TABLE = (1..100).to_a.map do |k|
  k * 3
end
NAME = "multi" + "core"

def read(k: Int) -> Int
  return TABLE[k] + NAME.size
end

def main() -> Void
  tasks = (0..99).to_a.map do |k|
    Task.spawn(&read, k)
  end
  sum = 0
  for t in tasks
    sum = sum + Task.await(t)
  end
  puts(sum)
end
"""


@RACE
def test_module_constants_are_written_before_other_schedulers_run(tmp_path, repeats):
    bytecode = program(tmp_path, "constants", CONSTANTS)
    for _ in range(repeats):
        result = vm(bytecode)
        assert (result.code, result.stdout, result.stderr) == (0, "%d\n" % (3 * 5050 + 900), "")


READERS = """\
def reader(n: Int) -> Int
  count = 0
  while true
    case IO.gets()
      ok(_) -> count = count + 1
      error(_) -> break
    end
  end
  return count
end

def main() -> Void
  a = Task.spawn(&reader, 0)
  b = Task.spawn(&reader, 1)
  puts(Task.await(a) + Task.await(b))
end
"""


@RACE
def test_two_tasks_share_standard_input_line_by_line(tmp_path, repeats):
    bytecode = program(tmp_path, "readers", READERS)
    text = "".join("line %d\n" % k for k in range(5000))
    for _ in range(repeats):
        result = vm(bytecode, stdin=text)
        assert (result.code, result.stdout, result.stderr) == (0, "5000\n", "")


@pytest.mark.skipif(fcntl is None, reason="needs fcntl")
def test_a_socket_as_standard_input_keeps_its_blocking_flag_for_the_parent(tmp_path):
    bytecode = program(tmp_path, "sock", "def main() -> Void\n  IO.inspect(IO.gets())\nend\n")
    ours, theirs = socket.socketpair()
    try:
        process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode], stdin=theirs.fileno(),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=vm_environment(MULTICORE), text=True)
        try:
            ours.sendall(b"hello\n")
            out, err = process.communicate(timeout=30)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        blocking = not fcntl.fcntl(theirs.fileno(), fcntl.F_GETFL) & os.O_NONBLOCK
    finally:
        ours.close()
        theirs.close()
    assert (process.returncode, out, err, blocking) == (0, 'ok("hello")\n', "", True)


FIFO = """\
def main() -> Void
  input = Result.unwrap!(File.open(System.args()[0], "read", 10000))
  count = 0
  while true
    case File.read_line(input, 10000)
      ok(_) -> count = count + 1
      error(_) -> break
    end
  end
  File.close(input, 10000)
  puts(count)
  case File.read_text(System.args()[1], 10000)
    ok(text) -> puts(text.size)
    error(e) -> puts(e)
  end
  IO.inspect(File.read_line(Result.unwrap!(File.open(System.args()[2], "read", 10000)), 200))
end
"""


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="needs FIFOs")
@RACE
def test_fifos_are_read_through_the_io_thread(tmp_path, repeats):
    bytecode = program(tmp_path, "fifo", FIFO)
    for k in range(repeats):
        lines, whole, stuck = (tmp_path / ("%s-%d" % (name, k)) for name in ("lines", "whole", "stuck"))
        for path in (lines, whole, stuck):
            os.mkfifo(path)

        def feed(path, text):
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)

        writers = [threading.Thread(target=feed, args=(lines, "".join("row %d\n" % n for n in range(3000)))),
                   threading.Thread(target=feed, args=(whole, "y" * 100000))]
        for w in writers:
            w.start()
        # Held open for reading and writing: the last read waits and times out on the poller.
        held = os.open(stuck, os.O_RDWR)
        try:
            result = vm(bytecode, args=(str(lines), str(whole), str(stuck)))
        finally:
            os.close(held)
            for w in writers:
                w.join()
        assert (result.code, result.stdout, result.stderr) == (
            0, "3000\n100000\nerror(\"filesystem: operation timed out\")\n", "")


BLOCKED = """\
def blocked(path: String) -> Result[String]
  input = try File.open(path, "read", 10000)
  return File.read_line(input, %(per_call)d)
end

def main() -> Void
  paths = [System.args()[0], System.args()[0], System.args()[0], System.args()[0], System.args()[0],
    System.args()[0], System.args()[0], System.args()[0]]
  results = Task.map(paths, 8, 100, &blocked)
  failed = 0
  for r in results
    if !r.ok?
      failed = failed + 1
    end
  end
  puts(failed)
  Task.sleep(%(settle)d)
  puts(Task.pending_count())
  IO.inspect(File.read_line(Result.unwrap!(File.open(System.args()[0], "read", 10000)), 50))
end
"""


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="needs FIFOs")
@pytest.mark.parametrize("per_call_ms", [60000, 300], ids=["deadline-never", "deadline-after-cancel"])
@RACE
def test_task_map_cancels_tasks_blocked_on_a_fifo(tmp_path, repeats, per_call_ms):
    # Eight tasks wait in File.read_line on a FIFO that is held open and never written; Task.map's limit of 100 ms
    # cancels them from whichever scheduler runs the caller, so each job is detached by a scheduler (a DETACH request).
    # With a per-call deadline of 300 ms the deadline then passes after the detach. Every task ends, nothing is left
    # pending, and the FIFO still works afterwards.
    settle = 2 * per_call_ms if per_call_ms < 1000 else 50
    bytecode = program(tmp_path, "blocked", BLOCKED % {"per_call": per_call_ms, "settle": settle})
    for k in range(repeats):
        fifo = tmp_path / ("blocked-%d" % k)
        os.mkfifo(fifo)
        held = os.open(fifo, os.O_RDWR)
        try:
            result = vm(bytecode, args=(str(fifo),))
        finally:
            os.close(held)
        assert (result.code, result.stdout, result.stderr) == (
            0, "8\n0\nerror(\"filesystem: operation timed out\")\n", "")


def test_a_process_call_is_refused_on_several_schedulers(tmp_path):
    bytecode = program(tmp_path, "proc", "def main() -> Void\n"
                       "  IO.inspect(Process.spawn_channel(\"sh\", [\"-c\", \"exit 0\"], \".\", 5000).ok?)\nend\n")
    result = vm(bytecode, "--json")
    assert diff.outcome((result.code, result.stdout, result.stderr))[3] == "RUNTIME-INTERNAL"

# TCP and TLS run on several schedulers: every step is a request to the I/O thread, which owns each socket (§16.9).
TLS_DIR = str(FIXTURES / "tls")

NET_ECHO = r"""struct Dial
  port: Int
  ca: String
  lines: Int
end

def open(d: Dial) -> Result[Socket]
  if d.ca == ""
    return TCP.connect("127.0.0.1", d.port, 10000)
  end
  return TLS.connect("localhost", d.port, d.ca, 10000)
end

def serve(socket: Socket) -> Int
  count = 0
  line = TCP.read_line(socket, 10000)
  while line.ok?
    TCP.send(socket, line.unwrap! + "\n", 10000).unwrap!
    count = count + 1
    line = TCP.read_line(socket, 10000)
  end
  TCP.close(socket)
  return count
end

def accept_all(listener: Listener) -> Int
  servers: List[Task[Int]] = []
  socket = TCP.accept(listener, 10000)
  while socket.ok?
    servers = servers.push(Task.spawn_owning(&serve, socket.unwrap!))
    socket = TCP.accept(listener, 10000)
  end
  total = 0
  for t in servers
    total = total + Task.await(t)
  end
  return total
end

def client(d: Dial) -> Int
  socket = open(d).unwrap!
  same = 0
  i = 0
  while i < d.lines
    TCP.send(socket, "#{d.port} #{i}\n", 10000).unwrap!
    if TCP.read_line(socket, 10000).unwrap! == "#{d.port} #{i}"
      same = same + 1
    end
    i = i + 1
  end
  TCP.close(socket)
  return same
end

def main() -> Void
  args = System.args()
  clients = args[0].to_i!
  lines = args[1].to_i!
  dir = ""
  ca = ""
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  if args.size > 2
    dir = args[2]
    ca = "#{dir}/ca.pem"
    TCP.close_listener(listener)
    listener = TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem").unwrap!
  end
  acceptor = Task.spawn(&accept_all, listener)
  d = Dial(port: TCP.local_port(listener), ca: ca, lines: lines)
  tasks = (1..clients).to_a.map do |k|
    Task.spawn(&client, d)
  end
  same = 0
  for t in tasks
    same = same + Task.await(t)
  end
  TCP.close_listener(listener)
  puts(same)
  puts(Task.await(acceptor))
end
"""


@RACE
@pytest.mark.parametrize("clients,lines,secure", [(32, 100, False), (8, 20, True)], ids=["tcp", "tls"])
def test_echo_clients_on_several_schedulers_get_every_line_back(tmp_path, repeats, clients, lines, secure):
    # A listener task hands each connection to a server task; every client task sends its lines one by one and
    # checks each echo. Reads, sends, accepts and connects are issued and resumed on any scheduler.
    bytecode = program(tmp_path, "echo", NET_ECHO)
    args = (str(clients), str(lines)) + ((TLS_DIR,) if secure else ())
    for _ in range(repeats):
        result = vm(bytecode, args=args)
        assert (result.code, result.stdout, result.stderr) == (0, "%d\n%d\n" % (clients * lines, clients * lines), "")


NET_CANCEL = r"""struct Wait
  kind: String
  port: Int
  ca: String
end

def big() -> String
  text = "abcdefgh"
  round = 0
  while round < 23
    text = text + text
    round = round + 1
  end
  return text
end

def wait(w: Wait) -> Result[String]
  if w.kind == "accept"
    listener = try TCP.listen("127.0.0.1", w.port)
    socket = try TCP.accept(listener, 60000)
    TCP.close(socket)
    return ok("accepted")
  end
  if w.kind == "handshake"
    socket = try TLS.connect("localhost", w.port, w.ca, 60000)
    TCP.close(socket)
    return ok("handshaken")
  end
  socket = try TCP.connect("127.0.0.1", w.port, 60000)
  if w.kind == "send"
    try TCP.send(socket, big(), 60000)
    return ok("sent")
  end
  return TCP.read_line(socket, 60000)
end

def hold(w: Wait) -> Result[String]
  return wait(w)
end

def crash(w: Wait) -> Result[Int]
  Task.spawn(&hold, Wait(kind: "read", port: w.port, ca: w.ca))
  Task.spawn(&hold, Wait(kind: "send", port: w.port, ca: w.ca))
  Task.spawn(&hold, Wait(kind: "handshake", port: w.port, ca: w.ca))
  Task.sleep(50)
  zero = 0
  return ok(1 / zero)
end

def main() -> Void
  ca = "#{System.args()[0]}/ca.pem"
  silent = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(silent)
  probe = TCP.listen("127.0.0.1", 0).unwrap!
  free = TCP.local_port(probe)
  TCP.close_listener(probe)
  waits = [
    Wait(kind: "read", port: port, ca: ca),
    Wait(kind: "send", port: port, ca: ca),
    Wait(kind: "handshake", port: port, ca: ca),
    Wait(kind: "accept", port: free, ca: ca),
    Wait(kind: "read", port: port, ca: ca),
    Wait(kind: "send", port: port, ca: ca),
    Wait(kind: "handshake", port: port, ca: ca),
  ]
  results = Task.map(waits, 8, 200, &wait)
  for r in results
    IO.inspect(r)
  end
  owner = Task.spawn(&crash, Wait(kind: "", port: port, ca: ca))
  case Task.await(owner)
    ok(n) -> puts(n)
    error(e) -> puts("owner: #{e}")
  end
  again = TCP.listen("127.0.0.1", free)
  puts(again.ok?)
  TCP.close_listener(again.unwrap!)
  TCP.close_listener(silent)
  tries = 0
  while Task.pending_count() > 0 && tries < 500
    Task.sleep(10)
    tries = tries + 1
  end
  puts(Task.pending_count())
end
"""


@RACE
def test_net_waits_cancelled_from_other_schedulers_end_and_free_their_port(tmp_path, repeats):
    # Task.map's limit cancels tasks parked in read_line, a 64 MiB send, a TLS handshake that the peer never answers
    # and an accept; then a crashing owner cancels its children parked the same way. The jobs are cancelled by
    # whichever scheduler runs the canceller, the run ends, no task is left (the crashed owner's children end on
    # their own schedulers, so main waits for the count to reach 0), and the accept's port is free again.
    bytecode = program(tmp_path, "net_cancel", NET_CANCEL)
    for _ in range(repeats):
        result = vm(bytecode, args=(TLS_DIR,))
        lines = result.stdout.splitlines()
        assert (result.code, lines[:7], lines[8:]) == (0, ['error("task: timed out")'] * 7, ["true", "0"]), result.stderr
        assert lines[7].startswith("owner: task crashed: RUNTIME-DIVISION-BY-ZERO"), lines[7]


NET_DEADLINE = r"""struct Late
  socket: Socket
  delay: Int
end

struct Dial
  port: Int
  ca: String
  deadline: Int
end

def write_late(l: Late) -> Result[Void]
  Task.sleep(l.delay)
  return TCP.send(l.socket, "late\n", 5000)
end

def race(socket: Socket) -> String
  got = TCP.read_line(socket, 20)
  case got
    ok(line) -> return line
    error(e) -> return "#{e} then #{TCP.read_line(socket, 1000)}"
  end
end

def dial(d: Dial) -> String
  case TLS.connect("localhost", d.port, d.ca, d.deadline)
    ok(socket) ->
      TCP.close(socket)
      return "ok"
    error(e) -> return e
  end
end

def serve_tls(listener: Listener) -> Int
  count = 0
  socket = TCP.accept(listener, 2000)
  while socket.ok? || socket.message != "network: listener is closed"
    if socket.ok?
      TCP.close(socket.unwrap!)
    end
    count = count + 1
    socket = TCP.accept(listener, 2000)
  end
  return count
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(listener)
  seen: Map[String, Int] = {}
  k = 0
  while k < 24
    near = TCP.connect("127.0.0.1", port, 5000).unwrap!
    far = TCP.accept(listener, 5000).unwrap!
    writer = Task.spawn(&write_late, Late(socket: far, delay: 14 + k % 12))
    reader = Task.spawn(&race, near)
    outcome = Task.await(reader)
    Task.await(writer)
    seen = seen.put(outcome, seen.get(outcome, 0) + 1)
    TCP.close(near)
    TCP.close(far)
    k = k + 1
  end
  TCP.close_listener(listener)
  for key in seen.keys
    puts(key)
  end
  puts("--")
  dir = System.args()[0]
  secure = TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem").unwrap!
  server = Task.spawn(&serve_tls, secure)
  dials: Map[String, Int] = {}
  k = 1
  while k <= 24
    got = Task.await(Task.spawn(&dial, Dial(port: TCP.local_port(secure), ca: "#{dir}/ca.pem", deadline: k)))
    dials = dials.put(got, dials.get(got, 0) + 1)
    k = k + 1
  end
  TCP.close_listener(secure)
  Task.await(server)
  for key in dials.keys
    puts(key)
  end
end
"""


@RACE
def test_net_deadlines_that_pass_during_a_step_give_the_result_or_the_timeout(tmp_path, repeats):
    # A read whose 20 ms deadline races a writer task that sends at 14 to 25 ms: the line, or the timeout and then a
    # closed socket, never both. TLS connects whose deadline (1 to 24 ms) falls in the handshake: ok or the timeout.
    bytecode = program(tmp_path, "net_deadline", NET_DEADLINE)
    reads = {"late", 'network: operation timed out then error("network: socket is closed")'}
    dials = {"ok", "network: operation timed out"}
    for _ in range(repeats):
        result = vm(bytecode, args=(TLS_DIR,))
        assert (result.code, result.stderr) == (0, "")
        first, second = result.stdout.split("--\n")
        assert set(first.splitlines()) <= reads and set(second.splitlines()) <= dials, result.stdout


NET_CLOSE = r"""struct Dial
  port: Int
  ca: String
end

def big() -> String
  text = "abcdefgh"
  round = 0
  while round < 23
    text = text + text
    round = round + 1
  end
  return text
end

def read(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 60000)
end

def write(socket: Socket) -> Result[Void]
  return TCP.send(socket, big(), 60000)
end

def closer(socket: Socket) -> Void
  Task.sleep(100)
  TCP.close(socket)
end

def open(d: Dial) -> Result[Socket]
  if d.ca == ""
    return TCP.connect("127.0.0.1", d.port, 5000)
  end
  return TLS.connect("localhost", d.port, d.ca, 5000)
end

def own(listener: Listener) -> Result[Int]
  Task.sleep(10)
  zero = 0
  return ok(1 / zero)
end

def parked(listener: Listener, ca: String) -> Void
  dial = Task.spawn(&open, Dial(port: TCP.local_port(listener), ca: ca))
  far = TCP.accept(listener, 5000).unwrap!
  near = Task.await(dial).unwrap!
  reader = Task.spawn(&read, near)
  writer = Task.spawn(&write, near)
  Task.spawn(&closer, near)
  IO.inspect(Task.await(reader))
  IO.inspect(Task.await(writer))
  IO.inspect(TCP.read_line(near, 1000))
  TCP.close(far)
  TCP.close_listener(listener)
end

def main() -> Void
  dir = System.args()[0]
  parked(TCP.listen("127.0.0.1", 0).unwrap!, "")
  parked(TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem").unwrap!, "#{dir}/ca.pem")
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(listener)
  case Task.await(Task.spawn_owning(&own, listener))
    ok(n) -> puts(n)
    error(e) -> puts("owner crashed")
  end
  again = TCP.listen("127.0.0.1", port)
  puts(again.ok?)
  TCP.close_listener(again.unwrap!)
end
"""


@RACE
def test_a_close_from_another_scheduler_ends_parked_reads_and_sends(tmp_path, repeats):
    # On a TCP and on a TLS socket, one task waits in read_line and one in a 64 MiB send that the peer never reads;
    # a third task closes the socket. Both waits end with the closed error. Then a task that owns a listener crashes,
    # and the listener's port can be bound again.
    bytecode = program(tmp_path, "net_close", NET_CLOSE)
    expected = '\n'.join(['error("network: socket is closed")'] * 6 + ["owner crashed", "true", ""])
    for _ in range(repeats):
        result = vm(bytecode, args=(TLS_DIR,))
        assert (result.code, result.stdout) == (0, expected), result.stderr


NET_STOP = r"""def read(socket: Socket) -> Result[String]
  return TCP.read_line(socket, 60000)
end

def accept(listener: Listener) -> Result[Socket]
  return TCP.accept(listener, 60000)
end

def main() -> Void
  dir = System.args()[0]
  plain = TCP.listen("127.0.0.1", 0).unwrap!
  secure = TLS.listen("127.0.0.1", 0, "#{dir}/server.pem", "#{dir}/server-key.pem").unwrap!
  puts("#{TCP.local_port(plain)} #{TCP.local_port(secure)}")
  one = TCP.accept(plain, 10000).unwrap!
  two = TCP.accept(secure, 10000).unwrap!
  Task.spawn(&accept, plain)
  Task.spawn(&read, two)
  waiting = Task.spawn(&read, one)
  Task.sleep(50)
  puts("ready")
  if System.args()[1] == "exit"
    Task.sleep(50)
    System.exit(3)
  end
  IO.inspect(Task.await(waiting))
end
"""


@pytest.mark.skipif(not hasattr(signal, "SIGTERM") or sys.platform == "win32", reason="needs POSIX signals")
@pytest.mark.parametrize("mode", ["signal", "exit"])
def test_a_stop_signal_or_an_exit_closes_open_sockets_and_tls_sessions(tmp_path, mode):
    # A run with a parked accept, a parked TCP read and a parked TLS read gets SIGTERM, or main calls System.exit(3)
    # on its scheduler: the run ends with the signal or 3, and the peer sees EOF on the TCP socket and close_notify on
    # the TLS one (a missing close_notify raises SSLEOFError).
    bytecode = program(tmp_path, "net_stop", NET_STOP)
    process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode, TLS_DIR, mode], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(MULTICORE),
                               text=True)
    try:
        plain_port, secure_port = map(int, process.stdout.readline().split())
        context = ssl.create_default_context(cafile=TLS_DIR + "/ca.pem")
        with socket.create_connection(("127.0.0.1", plain_port), timeout=30) as plain, \
                context.wrap_socket(socket.create_connection(("127.0.0.1", secure_port), timeout=30),
                                    server_hostname="localhost", suppress_ragged_eofs=False) as secure:
            assert process.stdout.readline() == "ready\n"
            if mode == "signal":
                process.send_signal(signal.SIGTERM)
            out, err = process.communicate(timeout=30)
            code = -signal.SIGTERM if mode == "signal" else 3
            assert (process.returncode, out, plain.recv(10), secure.recv(10)) == (code, "", b"", b""), err
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


NET_STALL = r"""def accept(listener: Listener) -> Result[Socket]
  return TCP.accept(listener, 60000)
end

def main() -> Void
  port = System.args()[0].to_i!
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  Task.spawn(&accept, listener)
  short = TCP.connect("127.0.0.1", port, 5000).unwrap!
  long = TCP.connect("127.0.0.1", port, 5000).unwrap!
  IO.inspect(TCP.read_line(short, 300))
  IO.inspect(TCP.read_line(long, 60000))
end
"""


def test_waits_on_live_connections_are_no_stall_on_several_schedulers(tmp_path):
    # Every task waits on a socket whose peer holds it open, or on a live listener: the run waits, a read with a
    # deadline times out, and the other read ends when the peer closes.
    bytecode = program(tmp_path, "net_stall", NET_STALL)
    with socket.create_server(("127.0.0.1", 0)) as server:
        server.settimeout(30)
        process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode, str(server.getsockname()[1])],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=vm_environment(MULTICORE), text=True)
        try:
            peers = [server.accept()[0], server.accept()[0]]
            try:
                process.wait(timeout=0.6)
            except subprocess.TimeoutExpired:
                pass
            assert process.poll() is None
            for peer in peers:
                peer.close()
            out, err = process.communicate(timeout=30)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    assert (process.returncode, out, err) == (
        0, 'error("network: operation timed out")\nerror("network: end of input")\n', "")


def test_more_schedulers_need_the_switch_and_refuse_the_profile_and_blocking_output(tmp_path):
    bytecode = program(tmp_path, "plain", "def main() -> Void\n  puts(1)\nend\n")
    assert run([*vm_command(), *FLAGS, "--", bytecode], env=vm_environment()).code == 2
    assert vm(bytecode, env={"AGENTICA_VM_TRACE": "profile"}).code == 2
    assert vm(bytecode, env={"AGENTICA_VM_TEST_BLOCKING_OUTPUT": "1"}).code == 2
    plain = vm(bytecode)
    assert (plain.code, plain.stdout) == (0, "1\n")


SPIN_AND_WAIT = """\
def spinner(n: Int) -> Int
  i = 0
  while true
    i = i + 1
  end
  return i
end

def reader(path: String) -> Result[String]
  input = try File.open(path, "read", 60000)
  return File.read_line(input, 60000)
end

def main() -> Void
  Task.spawn(&spinner, 1)
  Task.spawn(&spinner, 2)
  waiting = Task.spawn(&reader, System.args()[0])
  puts("ready")
  IO.inspect(Task.await(waiting))
end
"""


@pytest.mark.skipif(not hasattr(os, "mkfifo") or not hasattr(signal, "SIGTERM") or sys.platform == "win32",
                    reason="needs POSIX signals and FIFOs")
def test_a_stop_signal_ends_a_run_with_spinners_and_a_blocked_reader(tmp_path):
    # The I/O thread handles the signal (the schedulers keep it blocked) and ends the run at once, with spinning tasks
    # and a task blocked on a FIFO that is held open and never written.
    bytecode = program(tmp_path, "spin_wait", SPIN_AND_WAIT)
    fifo = tmp_path / "held"
    os.mkfifo(fifo)
    held = os.open(fifo, os.O_RDWR)
    try:
        process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode, str(fifo)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(MULTICORE),
                                   text=True)
        try:
            assert process.stdout.readline() == "ready\n"
            process.send_signal(signal.SIGTERM)
            out, _ = process.communicate(timeout=30)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    finally:
        os.close(held)
    # The VM dies by the signal after its exit path (128 + 15 seen by a shell).
    assert (process.returncode, out) == (-signal.SIGTERM, "")


def test_a_pending_read_of_standard_input_is_no_stall_on_several_schedulers(tmp_path):
    # A read of stdin with a writer that stays: the stdin poller is a live handle, so the run waits. Closing stdin
    # then ends the read with its normal result.
    bytecode = program(tmp_path, "gets", "def main() -> Void\n  IO.inspect(IO.gets())\nend\n")
    process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(MULTICORE),
                               text=True)
    try:
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        assert process.poll() is None
        out, err = process.communicate(input="", timeout=30)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    one = run([*vm_command(), "--", bytecode], stdin="", env=vm_environment())
    assert (process.returncode, out, err) == (one.code, one.stdout, one.stderr)
    assert one.code == 0 and one.stdout.startswith("error(")


def test_the_front_end_runs_a_source_file_on_several_schedulers(tmp_path):
    source = tmp_path / "fan.agc"
    source.write_text(FAN_OUT, encoding="utf-8")
    result = run([vm_command()[0], *FLAGS, str(source)], env=vm_environment(MULTICORE))
    assert (result.code, result.stdout, result.stderr) == (0, "%d\n" % expected_fan_out(), "")


# HTTP runs on several schedulers too: the server's state belongs to the I/O thread (vm/http_server.c), and the
# client in std/http is TCP and TLS sockets, channels and tasks.
HTTP_LOAD = r"""import HTTP from "std/http"

struct Load
  pool: HttpClient
  base: String
  requests: Int
end

def handle(request: HttpRequest) -> Result[HttpResponse]
  if request.path == "/slow"
    Task.sleep(300)
  end
  return ok(HttpResponse(status: 200, headers: [], body: request.path))
end

def load(l: Load) -> Int
  same = 0
  i = 0
  while i < l.requests
    r = HTTP.get(l.pool, "#{l.base}/#{i}")
    if r.ok? && r.unwrap!.body == "/#{i}"
      same = same + 1
    end
    i = i + 1
  end
  return same
end

def slow(l: Load) -> Result[String]
  response = try HTTP.get(l.pool, l.base + "/slow")
  return ok(response.body)
end

# GETs until one fails: the count of answers before the server closed. A wrong body counts as a failure (-1000).
def until_closed(l: Load) -> Int
  answers = 0
  while true
    case HTTP.get(l.pool, "#{l.base}/#{answers}")
      ok(response) ->
        if response.body != "/#{answers}"
          return -1000
        end
        answers = answers + 1
      error(message) -> return answers
    end
  end
  return answers
end

# CLIENTS tasks send REQUESTS requests each, beside callers that Task.map cancels at their 50 ms deadline while their
# requests wait on the server; every request of the load tasks gets its own path back.
def phase(base: String, ca: String, clients: Int, requests: Int) -> Int
  pool = HTTP.client(HTTP.client_options().with(ca_file: ca, max_connections: 8, timeout_ms: 20000)).unwrap!
  l = Load(pool: pool, base: base, requests: requests)
  tasks = (1..clients).to_a.map do |k|
    Task.spawn(&load, l)
  end
  cancelled = Task.map([l, l, l, l], 4, 50, &slow)
  same = 0
  for t in tasks
    same = same + Task.await(t)
  end
  for c in cancelled
    if c.ok?
      same = same - 1000
    end
  end
  HTTP.close_client(pool)
  return same
end

def main() -> Void
  args = System.args()
  certs = args[0]
  clients = args[1].to_i!
  requests = args[2].to_i!
  ca = certs + "/ca.pem"
  options = HttpServerOptions(request_timeout_ms: 10000, idle_timeout_ms: 10000, max_connections: 8, max_body_bytes: 1024)
  plain = HTTP.listen("127.0.0.1", 0, &handle, options).unwrap!
  secure = HTTP.listen_tls("127.0.0.1", 0, certs + "/server.pem", certs + "/server-key.pem", &handle, options).unwrap!
  puts(phase("http://127.0.0.1:#{HTTP.local_port(plain)}", ca, clients, requests))
  puts(phase("https://localhost:#{HTTP.local_port(secure)}", ca, clients, requests))
  # The server closes under load: each caller sends GETs until one fails. Answers came before the close (so it came
  # during the load), every caller then gets an error (none hangs), and wait returns.
  pool = HTTP.client(HTTP.client_options().with(ca_file: ca, max_connections: 8, timeout_ms: 20000)).unwrap!
  l = Load(pool: pool, base: "https://localhost:#{HTTP.local_port(secure)}", requests: 0)
  callers = (1..clients).to_a.map do |k|
    Task.spawn(&until_closed, l)
  end
  Task.sleep(200)
  HTTP.close_server(secure)
  answers = 0
  wrong = 0
  for c in callers
    n = Task.await(c)
    if n < 0
      wrong = wrong + 1
    else
      answers = answers + n
    end
  end
  puts("#{answers > 0} #{wrong}")
  IO.inspect(HTTP.wait(secure))
  HTTP.close_client(pool)
  HTTP.close_server(plain)
  IO.inspect(HTTP.wait(plain))
end
"""


@RACE
@pytest.mark.parametrize("schedulers", ["4", "8"])
def test_http_clients_on_several_schedulers_against_one_server_with_cancels_and_a_close(tmp_path, repeats, schedulers):
    # Many client tasks on one HTTP and one HTTPS server, with cancelled callers and the server closed under load.
    # Each HTTPS client builds its TLS context once, whichever schedulers its connections start on.
    bytecode = program(tmp_path, "http_load", HTTP_LOAD)
    clients, requests = 24, 10
    for k in range(repeats):
        trace = tmp_path / ("trace-%d" % k)
        env = {"AGENTICA_VM_TRACE": "tls", "AGENTICA_VM_TRACE_FILE": str(trace)}
        result = run([*vm_command(), "--schedulers", schedulers, "--", bytecode, TLS_DIR, str(clients),
                      str(requests)], env=vm_environment({**MULTICORE, **env}), timeout=120)
        total = clients * requests
        assert (result.code, result.stdout, result.stderr) == (0, "%d\n%d\ntrue 0\nok()\nok()\n" % (
            total, total), "")
        text = trace.read_text()
        assert len(re.findall(r"tls_config socket=\d+ shared=1", text)) == 2, text


# A max_connections = 1 server whose one connection holds the room, with a second connection in the backlog: the
# accept loop's wait sits in the I/O thread's queue. Two waits for the close that Task.map cancels at their deadline
# leave the queue (the waiter's cancel, at N > 1 on the I/O thread), the server then closes with the accept still
# queued (the release ends it), and the backlog connection is closed with the listener, never handed out.
HTTP_QUEUED = r"""import HTTP from "std/http"

def handle(request: HttpRequest) -> Result[HttpResponse]
  return ok(HttpResponse(status: 200, headers: [], body: "never"))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 60000, idle_timeout_ms: 60000, max_connections: 1, max_body_bytes: 64)
  server = HTTP.listen("127.0.0.1", 0, &handle, options).unwrap!
  port = HTTP.local_port(server)
  held = TCP.connect("127.0.0.1", port, 5000).unwrap!
  queued = TCP.connect("127.0.0.1", port, 5000).unwrap!
  Task.sleep(100)
  waits = Task.map([server, server], 2, 50) do |s|
    HTTP.wait(s)
  end
  for w in waits
    puts(w.ok?)
  end
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
  puts(TCP.read_line(held, 5000).ok?)
  puts(TCP.read_line(queued, 5000).ok?)
  TCP.close(held)
  TCP.close(queued)
end
"""


@RACE
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_http_waits_queued_on_the_io_thread_leave_on_cancel_and_end_at_close(tmp_path, repeats, schedulers):
    bytecode = program(tmp_path, "http_queued", HTTP_QUEUED)
    for _ in range(repeats):
        result = run([*vm_command(), "--schedulers", schedulers, "--", bytecode],
                     env=vm_environment(MULTICORE), timeout=60)
        assert (result.code, result.stdout, result.stderr) == (0, "false\nfalse\nok()\nfalse\nfalse\n", "")
