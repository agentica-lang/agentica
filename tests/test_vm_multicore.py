"""Programs on several scheduler threads (--schedulers 4).

A run has one scheduler per logical core unless it asks for a count; these cases pin four, so they mean the same on
any machine. The goldens of tests/fixtures/vm are taken at one scheduler (tests/vm_diff_support.py) and must hold at
four too, except where the order of output between tasks is not fixed (the ORDER set), which keeps its golden at
`--schedulers 1`. TCP, TLS, the HTTP server, processes, the child channel and the Test protocol post every step to the
I/O thread, so their fixtures run here. The other cases check what threads must keep: whole lines, exact sums, timers
that fire, the end of the run from any scheduler, standard input and FIFOs, sockets and processes used and closed from
several schedulers, and what still needs one scheduler.
`make test-multicore` runs this module; `make vm-tsan-run` runs it on a ThreadSanitizer build.
"""
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import threading

import pytest

try:
    import fcntl
except ImportError:
    fcntl = None

from tests.agentica_test import (FIXTURES, PYTHON, WINDOWS, compile_text, host_only, kill_process, known_issue,
                                 process_alive, run, scaled, vm_command, vm_environment, wait_readable, wait_until)
from tests import vm_diff_support as diff

SCHEDULERS = os.environ.get("AGENTICA_VM_TEST_SCHEDULER_COUNT", "4")
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
# process-close-crash prints the crashes of two tasks; process-close-cancel, test-assertions and test-crash-observed
# count on Task.sleep(0) letting another task run first (a close that ends before its owner crashes, the tasks of a
# test that crash before it returns). process-channel-close counts on Task.sleep(100) being long enough for its tasks
# to build a 1 MB text and park before the close, which a ThreadSanitizer build is too slow for. The cases further down
# that wait on a line or a task's end instead (test_a_crash_cancels_a_task_inside_process_close..., ...channel_calls...,
# ...observes_task_crashes...) keep that coverage at four schedulers.
ORDER = {"channel-fan-in", "channel-owner-ends", "channel-owner-handoff", "channel-returned-order", "handle-spawn-owning",
         "http-client-close-queued", "logger-tasks", "process-channel-close", "process-close-cancel",
         "process-close-crash",
         "task-await-cycle", "task-crash-descendants", "task-crash-result", "task-pending-count", "task-preempt-fail",
         "task-file-close", "tcp-tasks", "test-assertions", "test-crash-observed", "test-run-task"}


def vm(bytecode, *flags, args=(), stdin=None, env=None, timeout=None):
    extra = env or {}
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
        cases.append(pytest.param(path, id=path.stem))
    return cases


def golden_outcome(path, tmp_path, flags, env=None):
    """The outcome of the fixture at PATH run as its golden is taken, with FLAGS added; a skip when it has a reason."""
    reason = diff.skip_reason(path.name)
    if reason:
        pytest.skip(reason)
    fixture = diff.Fixture.of(path)
    bytecode = diff.compile_agc(path, tmp_path / (path.stem + ".agcb"))
    root = diff.source_root_options() + flags
    if fixture.uses_tmp:
        directory = diff.fresh_tmp(tmp_path)
        try:
            result = diff.untmp(directory, diff.run_vm_process(
                fixture, diff.allow_options(fixture) + diff.style_options("json") + root, bytecode,
                diff.tmp_args(fixture, directory), cwd=tmp_path, env=env))
        finally:
            shutil.rmtree(directory, ignore_errors=True)
    else:
        result = diff.run_vm(fixture, bytecode, 0, root=root, cwd=tmp_path, env=env)
    return diff.outcome(diff.unfixture(result))


@pytest.mark.parametrize("path", fixture_cases())
def test_a_fixture_keeps_its_golden_on_four_schedulers(path, tmp_path):
    assert golden_outcome(path, tmp_path, FLAGS) == diff.read_expected(path)


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


# Crypto.sha256 runs without the shared lock (vm/crypto.c), so eight tasks hash 64 KiB each at once.
SHA256_TASKS = """\
def digest(seed: Int) -> Result[List[Int]]
  data = (0..65535).to_a.map do |i|
    (i * 31 + seed * 7 + i / 256) % 256
  end
  return ok(Crypto.sha256(data))
end

def main() -> Void
  results = Task.map((1..8).to_a, 8, 30000, &digest)
  for r in results
    puts(r.unwrap!)
  end
end
"""


def test_sha256_in_eight_tasks_on_four_schedulers_matches_hashlib(tmp_path):
    result = vm(program(tmp_path, "sha256", SHA256_TASKS))
    assert (result.code, result.stderr) == (0, "")
    expected = [list(hashlib.sha256(bytes((i * 31 + seed * 7 + i // 256) % 256 for i in range(65536))).digest())
                for seed in range(1, 9)]
    assert [json.loads(line) for line in result.stdout.splitlines()] == expected


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


@host_only(fcntl is None, "the blocking flag of a descriptor (fcntl O_NONBLOCK) exists on POSIX only")
def test_a_socket_as_standard_input_keeps_its_blocking_flag_for_the_parent(tmp_path):
    bytecode = program(tmp_path, "sock", "def main() -> Void\n  IO.inspect(IO.gets())\nend\n")
    ours, theirs = socket.socketpair()
    try:
        process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode], stdin=theirs.fileno(),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=vm_environment(), text=True)
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


@host_only(not hasattr(os, "mkfifo"), "Windows has no FIFO files")
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


@host_only(not hasattr(os, "mkfifo"), "Windows has no FIFO files")
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


# Processes, the child channel and the Test protocol run on several schedulers: every libuv step is a request to the
# I/O thread, which owns each child's handles and buffers (§16.9). Most children are Python programs; the cases whose
# children are sh scripts that need POSIX process ids, descriptor 3 or ps do not run on Windows yet (#486).
SH_CHILDREN = known_issue(WINDOWS, 486, "the children are sh scripts that need POSIX process ids, descriptor 3 or ps")
POSIX_SIGNALS = host_only(WINDOWS or not hasattr(signal, "SIGTERM"), "Windows has no POSIX stop signals")
MULTICORE_CHILDREN = {"AGENTICA_SCHEDULERS": SCHEDULERS}

PROC_FAN = r"""def echo(n: Int) -> String
  first = "import sys; x = sys.stdin.readline().strip(); print('got-' + x, flush=True); "
  script = first + "sys.stderr.write('err-' + x + '\\n'); sys.exit(7)"
  p = Process.spawn_captured(System.args()[0], ["-c", script], ".", 20000).unwrap!
  sent = Process.send(p, "#{n}\n", 20000)
  line = Process.read_line(p, 20000)
  status = Process.wait(p, 20000)
  out = Process.output(p, 20000).unwrap!
  Process.close(p)
  return "#{sent} #{line} #{status} #{out.stderr.strip()}"
end

def plain(n: Int) -> String
  p = Process.spawn(System.args()[0], ["-c", "import sys; sys.exit(#{n})"], 20000).unwrap!
  status = Process.wait(p, 20000)
  Process.close(p)
  return "#{status}"
end

def main() -> Void
  tasks = (1..8).to_a.map do |k|
    Task.spawn(&echo, k)
  end
  plains = (1..8).to_a.map do |k|
    Task.spawn(&plain, k)
  end
  for t in tasks
    puts(Task.await(t))
  end
  for t in plains
    puts(Task.await(t))
  end
end
"""


@RACE
def test_children_of_tasks_on_several_schedulers_send_read_wait_and_close(tmp_path, repeats):
    # Sixteen tasks each run a child: a captured one is sent a line and read, waited for, its stderr kept, and closed;
    # a plain one is waited for. Every result is the one of a single scheduler.
    bytecode = program(tmp_path, "proc_fan", PROC_FAN)
    expected = "".join('ok() ok("got-%d") ok(7) err-%d\n' % (k, k) for k in range(1, 9))
    expected += "".join("ok(%d)\n" % k for k in range(1, 9))
    for _ in range(repeats):
        result = vm(bytecode, "--allow-run", args=(PYTHON,), timeout=120)
        assert (result.code, result.stdout, result.stderr) == (0, expected, "")


PROC_CANCEL = r"""def big() -> String
  text = "abcdefgh"
  round = 0
  while round < 17
    text = text + text
    round = round + 1
  end
  return text
end

def reader(p: Process) -> Result[String]
  return Process.read_line(p, 60000)
end

def waiter(p: Process) -> Result[Int]
  return Process.wait(p, 60000)
end

def sender(p: Process) -> Result[Void]
  return Process.send(p, big(), 60000)
end

def watch(pid: String) -> Process
  script = "while kill -0 #{pid} 2>/dev/null; do sleep 0.02; done; echo gone"
  return Process.spawn("sh", ["-c", script], 5000).unwrap!
end

def main() -> Void
  p = Process.spawn_captured("sh", ["-c", "exec sleep 60"], ".", 5000).unwrap!
  r = Task.spawn(&reader, p)
  w = Task.spawn(&waiter, p)
  s = Task.spawn(&sender, p)
  Task.sleep(50)
  Task.cancel(r)
  Task.cancel(w)
  Task.cancel(s)
  IO.inspect(Task.await(r))
  IO.inspect(Task.await(w))
  IO.inspect(Task.await(s))
  IO.inspect(Process.read_line(p, 100))
  Process.close(p)
  IO.inspect(Process.wait(p, 100))
  owned = Process.spawn("sh", ["-c", "echo $$; exec sleep 60"], 5000).unwrap!
  pid = Process.read_line(owned, 5000).unwrap!
  o = Task.spawn_owning(&reader, owned)
  Task.sleep(20)
  Task.cancel(o)
  IO.inspect(Task.await(o))
  IO.inspect(Process.read_line(watch(pid), 5000))
end
"""


@SH_CHILDREN
@RACE
def test_process_waits_cancelled_from_other_schedulers_end_and_the_owner_kills_its_child(tmp_path, repeats):
    # A read, a wait and a 1 MiB send that the child never reads are parked on one child and cancelled from main:
    # each task ends cancelled. The read keeps the reader lock until its job ends, so main's read times out on it; the
    # close ends every job and the run. A task that owns a child is cancelled: its end kills the child.
    bytecode = program(tmp_path, "proc_cancel", PROC_CANCEL)
    expected = ['error("task: cancelled")'] * 3 + ['error("network: operation timed out")',
                                                    'error("process: process is closed")', 'error("task: cancelled")',
                                                    'ok("gone")']
    for _ in range(repeats):
        result = vm(bytecode, "--allow-run", timeout=60)
        assert (result.code, result.stdout.splitlines(), result.stderr) == (0, expected, "")


PROC_DEADLINE = r"""def main() -> Void
  args = System.args()
  waits: Map[String, Int] = {}
  reads: Map[String, Int] = {}
  k = 0
  while k < 16
    pause = "0.0#{2 + k % 4}"
    p = Process.spawn(args[0], [args[1], args[2].replace("PAUSE", pause)], 5000).unwrap!
    got = "#{Process.wait(p, 30)}"
    waits = waits.put(got, waits.get(got, 0) + 1)
    Process.close(p)
    q = Process.spawn_captured(args[0], [args[1], args[3].replace("PAUSE", pause)], ".", 5000).unwrap!
    line = "#{Process.read_line(q, 30)}"
    if line != "ok(\"hi\")"
      line = "#{line} then #{Process.read_line(q, 1000)}"
    end
    reads = reads.put(line, reads.get(line, 0) + 1)
    Process.close(q)
    k = k + 1
  end
  for key in waits.keys
    puts(key)
  end
  puts("--")
  for key in reads.keys
    puts(key)
  end
end
"""


# The children of PROC_DEADLINE: sh where there is one, so they start at once and the race is close; Python on Windows.
DEADLINE_CHILDREN = ((PYTHON, "-c", "import sys, time; time.sleep(PAUSE); sys.exit(4)",
                      "import time; time.sleep(PAUSE); print('hi', flush=True)") if WINDOWS else
                     ("sh", "-c", "sleep PAUSE; exit 4", "sleep PAUSE; echo hi"))


@RACE
def test_process_exits_and_lines_that_race_a_deadline_give_the_result_or_the_timeout(tmp_path, repeats):
    # A wait whose 30 ms deadline races the exit of a child that sleeps 20 to 50 ms: the status or the timeout (a wait
    # that times out leaves the child as it is). A read that races a line the same way: the line, or the timeout,
    # which closes the child, so the next read finds it closed; never the timeout and then the line. On Windows the
    # Python children take 50 ms or more to start, so there the case covers only the timeout branch.
    bytecode = program(tmp_path, "proc_deadline", PROC_DEADLINE)
    waits = {"ok(4)", 'error("network: operation timed out")'}
    reads = {'ok("hi")', 'error("network: operation timed out") then error("process: process is closed")'}
    for _ in range(repeats):
        result = vm(bytecode, "--allow-run", args=DEADLINE_CHILDREN, timeout=60)
        assert (result.code, result.stderr) == (0, "")
        first, second = result.stdout.split("--\n")
        assert set(first.splitlines()) <= waits and set(second.splitlines()) <= reads, result.stdout


PROC_STOP = r"""def read(p: Process) -> Result[String]
  return Process.read_line(p, 60000)
end

def wait(p: Process) -> Result[Int]
  return Process.wait(p, 60000)
end

def leave(code: Int) -> Int
  Task.sleep(50)
  System.exit(code)
  return code
end

def main() -> Void
  plain = Process.spawn("sh", ["-c", "echo $$; exec sleep 60"], 5000).unwrap!
  captured = Process.spawn_captured("sh", ["-c", "echo $$; exec sleep 60"], ".", 5000).unwrap!
  pids = "#{Process.read_line(plain, 5000).unwrap!} #{Process.read_line(captured, 5000).unwrap!}"
  Task.spawn(&read, plain)
  Task.spawn(&wait, captured)
  puts(pids)
  IO.flush()
  if System.args()[0] == "exit"
    Task.spawn(&leave, 3)
  end
  Task.sleep(60000)
end
"""


@pytest.mark.parametrize("mode", [pytest.param("signal", marks=POSIX_SIGNALS), pytest.param("exit", marks=SH_CHILDREN)])
def test_a_stop_signal_or_an_exit_kills_the_children_of_a_run_on_several_schedulers(tmp_path, mode):
    # A plain and a captured child, each with a task parked on it; the run gets SIGTERM, or a task calls
    # System.exit(3) on its scheduler. The run ends with the signal or 3, and both children are gone.
    bytecode = program(tmp_path, "proc_stop", PROC_STOP)
    process = subprocess.Popen([*vm_command(), *FLAGS, "--allow-run", "--", bytecode, mode], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(),
                               text=True)
    pids = []
    try:
        pids = process.stdout.readline().split()
        assert len(pids) == 2
        if mode == "signal":
            process.send_signal(signal.SIGTERM)
        out, err = process.communicate(timeout=30)
        code = -signal.SIGTERM if mode == "signal" else 3
        assert (process.returncode, out, err) == (code, "", "")
        assert wait_until(lambda: not any(process_alive(pid) for pid in pids), timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        for pid in pids:
            kill_process(pid)


PROC_CHANNEL = r"""struct Batch
  p: Process
  from: Int
end

def reply(line: String) -> Result[Void]
  return Process.parent_send("echo:" + line + "\n", 5000)
end

def child() -> Void
  replies: List[Task[Result[Void]]] = []
  line = Process.parent_read_line(5000)
  while line.ok?
    replies = replies.push(Task.spawn(&reply, line.unwrap!))
    line = Process.parent_read_line(5000)
  end
  for t in replies
    Task.await(t).unwrap!
  end
  Process.parent_send("end:#{line.message}\n", 5000).unwrap!
end

def send_batch(b: Batch) -> Result[Void]
  k = 0
  while k < 25
    try Process.channel_send(b.p, "#{b.from + k}\n", 5000)
    k = k + 1
  end
  return ok()
end

def parent(binary: String, bytecode: String) -> Void
  p = Process.spawn_channel(binary, ["run", "--", bytecode, binary, bytecode, "child"], ".", 5000).unwrap!
  senders = [0, 100, 200, 300].map do |from|
    Task.spawn(&send_batch, Batch(p: p, from: from))
  end
  got: List[String] = []
  k = 0
  while k < 100
    got = got.push(Process.channel_read_line(p, 5000).unwrap!)
    k = k + 1
  end
  for t in senders
    Task.await(t).unwrap!
  end
  IO.inspect(Process.channel_close(p, 5000))
  puts(got.sort.join(","))
  IO.inspect(Process.channel_read_line(p, 5000))
  IO.inspect(Process.channel_read_line(p, 5000))
  IO.inspect(Process.wait(p, 5000))
  Process.close(p)
end

def main() -> Void
  args = System.args()
  if args.size == 3 && args[2] == "child"
    child()
  else
    parent(args[0], args[1])
  end
end
"""


@RACE
def test_the_child_channel_between_two_runs_on_several_schedulers(tmp_path, repeats):
    # The parent and its child both run on four schedulers. Four parent tasks send 100 lines on the channel while main
    # reads the replies; the child answers each line from a task of its own (Process.parent_send from several
    # schedulers). The parent closes its side, the child reads the end, says so and exits 0.
    bytecode = program(tmp_path, "proc_channel", PROC_CHANNEL)
    replies = ",".join(sorted("echo:%d" % (base + k) for base in (0, 100, 200, 300) for k in range(25)))
    expected = "ok()\n%s\nok(\"end:process: end of input\")\nerror(\"process: end of input\")\nok(0)\n" % replies
    for _ in range(repeats):
        result = vm(bytecode, "--allow-run", args=(vm_command()[0], bytecode), env=MULTICORE_CHILDREN, timeout=60)
        assert (result.code, result.stdout, result.stderr) == (0, expected, "")


PROC_CLOSE_CANCEL = r"""def closer(p: Process) -> Void
  sent = Process.send(p, "closing\n", 5000)
  Process.close(p)
end

def parent(p: Process) -> Result[Int]
  Task.spawn_owning(&closer, p)
  line = Process.read_line(p, 5000)
  return ok(10 / List.size(System.args()))
end

def main() -> Void
  p = Process.spawn("sh", ["-c", "echo $$; exec cat"], 5000).unwrap!
  pid = Process.read_line(p, 5000).unwrap!
  t = Task.spawn_owning(&parent, p)
  puts(Task.await(t).ok?)
  script = "while kill -0 #{pid} 2>/dev/null; do sleep 0.02; done; echo gone"
  watcher = Process.spawn("sh", ["-c", script], 5000).unwrap!
  IO.inspect(Process.read_line(watcher, 5000))
  puts(Task.pending_count())
end
"""


@SH_CHILDREN
@RACE
def test_a_crash_cancels_a_task_inside_process_close_on_another_scheduler(tmp_path, repeats):
    # process-close-cancel without its yield: the closer sends a line to `cat` and then closes the child it owns; the
    # parent crashes once the echo (or the closed error) comes back, so its cancel reaches the closer around or inside
    # Process.close. The closer prints nothing, so every order gives the same output: the child is gone and no task is
    # left.
    bytecode = program(tmp_path, "proc_close_cancel", PROC_CLOSE_CANCEL)
    for _ in range(repeats):
        result = vm(bytecode, "--allow-run", timeout=60)
        assert (result.code, result.stdout) == (0, 'false\nok("gone")\n0\n')
        assert "RUNTIME-DIVISION-BY-ZERO" in result.stderr


# The child reads one byte of the channel, then says so on stdout: the sender's 1 MB write has begun and the rest of it
# stays parked, since the child reads no more.
CHANNEL_CHILD = "head -c 1 <&3 >/dev/null; echo started; exec sleep 60"

PROC_CHANNEL_CLOSE = r"""def reader(p: Process) -> String
  return Process.channel_read_line(p, 60000).inspect
end

def sender(p: Process) -> String
  chunk = List.repeat("x", 1048000).join("")
  sent = Process.channel_send(p, chunk, 60000)
  while sent.ok?
    sent = Process.channel_send(p, chunk, 60000)
  end
  return sent.inspect
end

def holder(p: Process) -> Result[Int]
  Task.spawn(&reader, p)
  Task.spawn(&sender, p)
  started = Process.read_line(p, 30000).unwrap!
  return ok(10 / List.size(System.args()) + started.length)
end

def main() -> Void
  script = "CHILD"
  p = Process.spawn_channel("sh", ["-c", script], ".", 5000).unwrap!
  r = Task.spawn(&reader, p)
  s = Task.spawn(&sender, p)
  puts(Process.read_line(p, 30000).unwrap!)
  Process.close(p)
  puts(Task.await(r))
  puts(Task.await(s))
  q = Process.spawn_channel("sh", ["-c", script], ".", 5000).unwrap!
  t = Task.spawn_owning(&holder, q)
  puts(Task.await(t).ok?)
  Process.close(q)
  while Task.pending_count() > 0
    Task.sleep(1)
  end
  puts(Task.pending_count())
end
""".replace("CHILD", CHANNEL_CHILD)


@SH_CHILDREN
@RACE
def test_a_close_ends_channel_calls_parked_on_other_schedulers(tmp_path, repeats):
    # process-channel-close without its 100 ms sleeps: main closes the child once the child has read the first byte of
    # the sender's 1 MB write, so the send is parked; the read is parked or not yet made (then the process is closed
    # already). The owner of a second child crashes at the same point: its tasks end and nothing is left. A cancel
    # that reaches a task on another scheduler lands a little later, so main waits for the count to reach 0; a task
    # left behind hangs the run until the timeout.
    bytecode = program(tmp_path, "proc_channel_close", PROC_CHANNEL_CLOSE)
    reads = {'error("process: channel is closed")', 'error("process: process is closed")'}
    for _ in range(repeats):
        result = vm(bytecode, "--allow-run", timeout=60)
        assert result.code == 0, result.stderr
        started, read, send, crashed, pending = result.stdout.splitlines()
        assert (started, send, crashed, pending) == ("started", 'error("process: channel is closed")', "false", "0")
        assert read in reads
        assert "RUNTIME-DIVISION-BY-ZERO" in result.stderr


# A spawn whose START is still in the I/O thread's inbox when main returns must not start a child after the end of the
# run has reaped the children: nobody would kill it.
SPAWN_AT_END = r"""def spawner(mark: String) -> Int
  n = 0
  while n < 100000
    p = Process.spawn("sh", ["-c", "while :; do sleep 0.1; done", mark], 5000)
    n = n + 1
  end
  return n
end

def main() -> Void
  mark = System.args()[0]
  Task.spawn(&spawner, mark)
  Task.spawn(&spawner, mark)
  Task.spawn(&spawner, mark)
  Task.sleep(30)
  puts("done")
end
"""


def marked(mark):
    """The ids of the processes whose command line holds `mark`."""
    # -ww: without it ps cuts each line at 80 columns when its output is not a terminal.
    listing = subprocess.run(["ps", "-ww", "-eo", "pid=,args="], capture_output=True, text=True, check=True).stdout
    return [line.split(None, 1)[0] for line in listing.splitlines() if mark in line]


@SH_CHILDREN
@RACE
def test_spawns_racing_the_end_of_the_run_leave_no_child_behind(tmp_path, repeats):
    # Three tasks spawn children in a loop while main returns: every child that started is killed by the end of the
    # run, and a spawn still queued then starts none. A child left behind loops with the mark as $0; its own children
    # live 0.1 s, so killing the marked shell leaves nothing.
    bytecode = program(tmp_path, "spawn_at_end", SPAWN_AT_END)
    mark = "agc-orphan-%d-%d" % (os.getpid(), repeats)
    # Not run(): it kills the run's process group at the end, which would hide a child left behind.
    command = [*vm_command(), *FLAGS, "--allow-run", "--", bytecode, mark]
    try:
        # A run without the fix leaves a child behind about half the time: ten make it near certain.
        for _ in range(10 * repeats):
            result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    env=vm_environment(), timeout=60, check=False)
            assert (result.returncode, result.stdout, result.stderr) == (0, "done\n", "")
            assert wait_until(lambda: not marked(mark), timeout=3), marked(mark)
    finally:
        for pid in marked(mark):
            kill_process(pid)


UNITS = r"""def square(n: Int) -> Int
  return n * n
end

def main() -> Void
  Test.run([
    Test.test("tasks on several schedulers") do
      tasks = (1..8).to_a.map do |k|
        Task.spawn(&square, k)
      end
      total = 0
      for t in tasks
        total = total + Task.await(t)
      end
      Test.eq(total, 204)
    end,
    Test.test("a child process") do
      p = try Process.spawn_captured(PYTHON, ["-c", "print('hi')"], ".", 20000)
      line = try Process.read_line(p, 5000)
      Process.close(p)
      Test.eq(line, "hi")
    end,
    Test.test("a failing case") do
      Test.eq(1, 2)
    end
  ])
end
"""


def stable(report):
    """The report without what changes from run to run: the durations and the seed."""
    for entry in report["files"]:
        for scenario in entry["scenarios"]:
            scenario.pop("duration_ms", None)
    report.pop("duration_ms", None)
    report.pop("seed", None)
    return report


def same_report(tmp_path, name, text):
    """`agentica test --json` of the test file TEXT with every VM on one, then four schedulers: both exit 1 with the
    same report, which is returned."""
    source = tmp_path / name
    source.write_text(text, encoding="utf-8")
    command = [vm_command()[0], "test", "--allow-run", "--json", str(source)]
    one = run(command, env=vm_environment({"AGENTICA_SCHEDULERS": "1"}))
    several = run(command, env=vm_environment(MULTICORE_CHILDREN))
    assert (several.code, several.stderr) == (one.code, one.stderr) == (1, "")
    report = stable(json.loads(several.stdout))
    assert report == stable(json.loads(one.stdout))
    return report


def test_agentica_test_runs_a_test_file_on_several_schedulers(tmp_path):
    # `agentica test` with every VM on four schedulers: the runner and the test file speak the Test protocol over the
    # parent channel, and the report is the one of a single scheduler.
    report = same_report(tmp_path, "units_test.agc", UNITS.replace("PYTHON", json.dumps(PYTHON)))
    assert [s["status"] for s in report["files"][0]["scenarios"]] == ["passed", "passed", "failed"]


TEST_CRASHES = r"""def divide(n: Int) -> Int
  return 10 / n
end

def hold(ch: Channel[Int]) -> Int
  return 10 / Channel.recv(ch, 60000).unwrap_or(0)
end

def check_in_task(n: Int) -> Result[Void]
  return Test.eq(n, 4)
end

# The test's own task is counted: 1 means every task it spawned has returned or crashed.
def settle() -> Void
  while Task.pending_count() > 1
    Task.sleep(1)
  end
end

def main() -> Void
  Test.run([
    Test.test("two crashes, one reported") do
      Task.spawn(&divide, 0)
      Task.spawn(&divide, 0)
      settle()
      ok()
    end,
    Test.test("a crash fails only this test") do
      Test.eq(divide(0), 1)
    end,
    Test.test("a pending task is stopped") do
      ch: Channel[Int] = Channel.new(1)
      Task.spawn(&hold, ch)
      ok()
    end,
    Test.test("an assertion in a spawned task") do
      Task.await(Task.spawn(&check_in_task, 3))
      ok()
    end,
    Test.test("the crashes were observed") do
      Test.error?(Task.unobserved_crash())
    end
  ])
end
"""


def test_agentica_test_observes_task_crashes_and_leftovers_on_several_schedulers(tmp_path):
    # test-assertions and test-crash-observed without their yields: a test waits for its crashing tasks to end, so
    # the crash is seen on any scheduler; a leftover task waits on a channel, so it is pending when its test returns.
    # The report is the one of a single scheduler.
    scenarios = same_report(tmp_path, "crashes_test.agc", TEST_CRASHES)["files"][0]["scenarios"]
    assert [s["error"] and s["error"]["code"] for s in scenarios] == [
        "RUNTIME-TASK-CRASHED", "RUNTIME-DIVISION-BY-ZERO", "RUNTIME-TEST-PENDING-TASKS", "RUNTIME-TEST-ASSERTION",
        None]


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
    # Windows takes a 64 MiB send into its buffers at once (as in test_vm_tcp.py), so there the send may end first,
    # and on Windows this case does not prove that a parked send is cancelled; the other systems do.
    bytecode = program(tmp_path, "net_cancel", NET_CANCEL)
    timed_out = 'error("task: timed out")'
    sends = {timed_out, 'ok("sent")'} if WINDOWS else {timed_out}
    for _ in range(repeats):
        result = vm(bytecode, args=(TLS_DIR,))
        lines = result.stdout.splitlines()
        assert (result.code, lines[0], lines[2:5], lines[6], lines[8:]) == (
            0, timed_out, [timed_out] * 3, timed_out, ["true", "0"]), result.stderr
        assert {lines[1], lines[5]} <= sends, result.stdout
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


OWNER_CRASH = r"""def crash() -> Result[Int]
  zero = 0
  return ok(1 / zero)
end

def own_listener(listener: Listener) -> Result[Int]
  return crash()
end

def own_socket(socket: Socket) -> Result[Int]
  return crash()
end

def own_process(p: Process) -> Result[Int]
  return crash()
end

def accepted(got: Result[Socket]) -> String
  case got
    ok(socket) ->
      TCP.close(socket)
      return "accepted"
    error(e) -> return e
  end
end

def tally(seen: Map[String, Int], label: String, got: String) -> Map[String, Int]
  key = "#{label}: #{got}"
  return seen.put(key, seen.get(key, 0) + 1)
end

def main() -> Void
  python = System.args()[0]
  seen: Map[String, Int] = {}
  round = 0
  while round < 40
    listener = TCP.listen("127.0.0.1", 0).unwrap!
    port = TCP.local_port(listener)
    waiting = TCP.connect("127.0.0.1", port, 5000).unwrap!
    Task.await(Task.spawn_owning(&own_listener, listener))
    seen = tally(seen, "accept", accepted(TCP.accept(listener, 1)))
    TCP.close(waiting)

    server = TCP.listen("127.0.0.1", 0).unwrap!
    near = TCP.connect("127.0.0.1", TCP.local_port(server), 5000).unwrap!
    far = TCP.accept(server, 5000).unwrap!
    Task.await(Task.spawn_owning(&own_socket, far))
    seen = tally(seen, "send", "#{TCP.send(far, "x\n", 1000)}")
    seen = tally(seen, "peer", "#{TCP.read_line(near, 5000)}")
    TCP.close(near)
    TCP.close_listener(server)

    child = Process.spawn(python, ["-c", "import time; time.sleep(60)"], 5000).unwrap!
    Task.await(Task.spawn_owning(&own_process, child))
    seen = tally(seen, "wait", "#{Process.wait(child, 1000)}")
    round = round + 1
  end
  for key in seen.keys.sort
    puts("#{key} x#{seen.get(key, 0)}")
  end
end
"""

OWNER_CRASH_PORT = r"""def own(listener: Listener) -> Result[Int]
  zero = 0
  return ok(1 / zero)
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(listener)
  Task.await(Task.spawn_owning(&own, listener))
  puts("#{port}")
  IO.gets()
end
"""


@RACE
def test_handles_of_a_crashed_owner_are_closed_when_its_await_returns(tmp_path, repeats):
    # #402: a listener, a socket and a child that a task owns itself are closed by the time the caller's Task.await of
    # that crashed task returns: the I/O thread runs the close step, posted at the owner's end, before any step that
    # the woken caller posts. It does not pin the order inside finish_task (the close and the wake both run under
    # rt->sync, and the FIFO inbox orders the close first either way); the descendant cases below cover the gap that
    # order did leave. Each run checks 40 rounds of each kind.
    bytecode = program(tmp_path, "owner_crash", OWNER_CRASH)
    expected = ['accept: network: listener is closed x40', 'peer: error("network: end of input") x40',
                'send: error("network: socket is closed") x40', 'wait: error("process: process is closed") x40']
    for _ in range(repeats):
        result = vm(bytecode, "--allow-run", args=(PYTHON,), timeout=120)
        assert (result.code, result.stdout.splitlines()) == (0, expected), result.stderr


@RACE
def test_the_port_of_a_crashed_owner_refuses_a_peer_once_its_await_returns(tmp_path, repeats):
    # #402, seen from outside the run: the peer connects as soon as the run prints the port, which the run does after
    # the await of the listener's crashed owner. The listener is closed by then, so the connection is refused.
    bytecode = program(tmp_path, "owner_crash_port", OWNER_CRASH_PORT)
    for _ in range(5 * repeats):
        process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=vm_environment())
        try:
            assert wait_readable(process.stdout.fileno(), 30), "the run printed no port"
            port = int(process.stdout.readline())
            with pytest.raises(ConnectionRefusedError):
                socket.create_connection(("127.0.0.1", port), timeout=5).close()
            process.stdin.close()
            assert process.wait(timeout=30) == 0
        finally:
            kill_process(process.pid)
            process.stdout.close()


OWNER_DESCENDANTS = r"""struct Ending
  kind: String
  up: Channel[Channel[Int]]
  down: Channel[Channel[Int]]
end

def spin(listener: Listener) -> Result[Int]
  k = 0
  while k < 50000000
    k = k + 1
  end
  return ok(k)
end

def wait(listener: Listener) -> Result[Int]
  case TCP.accept(listener, 60000)
    ok(socket) -> TCP.close(socket)
    error(e) -> return ok(0)
  end
  return ok(1)
end

def crash() -> Result[Int]
  zero = 0
  return ok(1 / zero)
end

def crash_busy(listener: Listener) -> Result[Int]
  Task.spawn_owning(&spin, listener)
  return crash()
end

def crash_wait(listener: Listener) -> Result[Int]
  Task.spawn_owning(&wait, listener)
  return crash()
end

def cancel_busy(listener: Listener) -> Result[Int]
  Task.spawn_owning(&spin, listener)
  Task.sleep(60000)
  return ok(0)
end

def middle(listener: Listener) -> Result[Int]
  Task.spawn_owning(&spin, listener)
  return spin(listener)
end

def crash_nested(listener: Listener) -> Result[Int]
  Task.spawn_owning(&middle, listener)
  Task.sleep(2)
  return crash()
end

def cancel_nested(listener: Listener) -> Result[Int]
  Task.spawn_owning(&middle, listener)
  Task.sleep(60000)
  return ok(0)
end

def spin_channel(inner: Channel[Int]) -> Result[Int]
  k = 0
  while k < 50000000
    k = k + 1
  end
  return ok(k)
end

def hand_on(up: Channel[Channel[Int]]) -> Result[Int]
  inner: Channel[Int] = Channel.new(1)
  Task.spawn_owning(&spin_channel, inner)
  try up.send(inner, 5000)
  Task.sleep(60000)
  return ok(0)
end

def ended_middle(e: Ending) -> Result[Channel[Int]]
  if e.kind.starts_with?("map")
    results = Task.map([e.up], 1, 20, &hand_on)
    return e.up.recv(5000)
  end
  middle = Task.spawn(&hand_on, e.up)
  inner = try e.up.recv(5000)
  Task.cancel(middle)
  return ok(inner)
end

def ending(e: Ending) -> Result[Int]
  inner = try ended_middle(e)
  try e.down.send(inner, 5000)
  if e.kind.ends_with?("crash")
    return crash()
  end
  Task.sleep(60000)
  return ok(0)
end

def sent(got: Result[Void]) -> String
  case got
    ok(_) -> return "sent"
    error(e) -> return e
  end
end

def start(kind: String, listener: Listener) -> Task[Result[Int]]
  case kind
    "crash-busy" -> return Task.spawn_owning(&crash_busy, listener)
    "crash-wait" -> return Task.spawn_owning(&crash_wait, listener)
    "crash-nested" -> return Task.spawn_owning(&crash_nested, listener)
    "cancel-nested" -> return Task.spawn_owning(&cancel_nested, listener)
    _ -> return Task.spawn_owning(&cancel_busy, listener)
  end
end

def accepted(got: Result[Socket]) -> String
  case got
    ok(socket) ->
      TCP.close(socket)
      return "accepted"
    error(e) -> return e
  end
end

def main() -> Void
  seen: Map[String, Int] = {}
  for kind in ["crash-busy", "crash-wait", "crash-nested", "cancel-busy", "cancel-nested"]
    round = 0
    while round < 100
      listener = TCP.listen("127.0.0.1", 0).unwrap!
      waiting = TCP.connect("127.0.0.1", TCP.local_port(listener), 5000).unwrap!
      owner = start(kind, listener)
      if kind.starts_with?("cancel")
        Task.sleep(2)
        Task.cancel(owner)
      end
      Task.await(owner)
      key = "#{kind}: #{accepted(TCP.accept(listener, 1))}"
      seen = seen.put(key, seen.get(key, 0) + 1)
      TCP.close(waiting)
      round = round + 1
    end
  end
  for kind in ["map-cancel", "map-crash", "middle-cancel", "middle-crash"]
    round = 0
    while round < 100
      up: Channel[Channel[Int]] = Channel.new(1)
      down: Channel[Channel[Int]] = Channel.new(1)
      owner = Task.spawn(&ending, Ending(kind: kind, up: up, down: down))
      inner = down.recv(5000).unwrap!
      if kind.ends_with?("cancel")
        Task.cancel(owner)
      end
      Task.await(owner)
      key = "#{kind}: #{sent(inner.send(1, 1))}"
      seen = seen.put(key, seen.get(key, 0) + 1)
      round = round + 1
    end
  end
  for key in seen.keys.sort
    puts("#{key} x#{seen.get(key, 0)}")
  end
end
"""


@RACE
def test_handles_held_by_cancelled_descendants_are_closed_when_the_await_of_their_ancestor_returns(tmp_path, repeats):
    # #402, the nested case: the owner hands the listener on to a child (and, nested, the child to a grandchild), then
    # crashes or is cancelled. The cancel of a descendant that runs on another scheduler (busy, or just starting its
    # accept) is deferred to the end of its turn, so the owner's end waits for it (hold in vm/task.c): Task.await of
    # the owner returns only once the listener is closed, and the pending connection is never accepted. Without the
    # hold, about a quarter of the rounds accept it. The map-* and middle-* kinds cover a descendant that an earlier
    # cancel holds already: the owner cancels the middle task (or Task.map times out the item) whose child owns a
    # channel and keeps running, the child moves up to the owner, then the owner crashes or is cancelled. The owner's
    # end must wait for the child through the top of its holder chain; a send to the child's channel right after the
    # await must fail. Before that fix about half of those rounds sent. 100 rounds of each kind per run.
    bytecode = program(tmp_path, "owner_descendants", OWNER_DESCENDANTS)
    kinds = ["cancel-busy", "cancel-nested", "crash-busy", "crash-nested", "crash-wait"]
    expected = [f"{kind}: network: listener is closed x100" for kind in kinds]
    expected += [f"{kind}: channel: closed x100" for kind in ["map-cancel", "map-crash", "middle-cancel", "middle-crash"]]
    for _ in range(repeats):
        result = vm(bytecode, timeout=120)
        assert (result.code, result.stdout.splitlines()) == (0, expected), result.stderr


DEEP_CANCEL = r"""struct Level
  depth: Int
  ready: Channel[Int]
end

def spin(ready: Channel[Int]) -> Result[Int]
  try ready.send(1, 60000)
  k = 0
  while k < 2000000000
    k = k + 1
  end
  return ok(k)
end

def level(l: Level) -> Result[Int]
  if l.depth == 0
    return spin(l.ready)
  end
  Task.spawn(&level, Level(depth: l.depth - 1, ready: l.ready))
  Task.sleep(600000)
  return ok(0)
end

def main() -> Void
  ready: Channel[Int] = Channel.new(1)
  root = Task.spawn(&level, Level(depth: System.args()[0].to_i.unwrap!, ready: ready))
  ready.recv(60000).unwrap!
  # The leaf must be running, not waiting in a run queue: a queued task ends at once and the walk never holds it.
  Task.sleep(50)
  t0 = Time.monotonic_ms()
  Task.cancel(root)
  puts("cancel #{Time.monotonic_ms() - t0}")
  IO.inspect(Task.await(root))
end
"""


def test_one_cancel_of_a_deep_line_with_a_busy_leaf_costs_linear_time(tmp_path):
    # #499: the leaf runs on another scheduler, so the cancel walk holds it, and each ancestor it ends moves the leaf
    # up into the next one. Holding the leaf again at every level climbed its whole holder chain: one Task.cancel at
    # depth 32000 took about 26 s under rt->sync. The walk is linear now (a few ms); the bound leaves room for slow runs.
    bytecode = program(tmp_path, "deep_cancel", DEEP_CANCEL)
    result = vm(bytecode, args=["32000"], timeout=scaled(120))
    lines = result.stdout.splitlines()
    assert (result.code, lines[1:]) == (0, ["error(\"task: cancelled\")"]), result.stderr
    assert int(lines[0].removeprefix("cancel ")) < scaled(1500), lines[0]


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


@pytest.mark.parametrize("mode", [pytest.param("signal", marks=POSIX_SIGNALS), pytest.param("exit", marks=known_issue(
    WINDOWS, 489, "System.exit resets the open sockets on Windows"))])
def test_a_stop_signal_or_an_exit_closes_open_sockets_and_tls_sessions(tmp_path, mode):
    # A run with a parked accept, a parked TCP read and a parked TLS read gets SIGTERM, or main calls System.exit(3)
    # on its scheduler: the run ends with the signal or 3, and the peer sees EOF on the TCP socket and close_notify on
    # the TLS one (a missing close_notify raises SSLEOFError).
    bytecode = program(tmp_path, "net_stop", NET_STOP)
    process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode, TLS_DIR, mode], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(),
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
                                   env=vm_environment(), text=True)
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


def test_the_profile_and_blocking_output_take_one_scheduler_and_refuse_a_chosen_count(tmp_path):
    """The default count gives way to one scheduler next to the profile trace or the blocking output; a count above 1
    asked for by the flag or the variable is refused."""
    bytecode = program(tmp_path, "plain", "def main() -> Void\n  puts(1)\nend\n")
    for extra in ({"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": str(tmp_path / "profile")},
                  {"AGENTICA_VM_TEST_BLOCKING_OUTPUT": "1"}):
        assert vm(bytecode, env=extra).code == 2
        chosen = run([*vm_command(), "--", bytecode], env=vm_environment({**extra, "AGENTICA_SCHEDULERS": "2"}))
        assert chosen.code == 2 and "needs one scheduler" in chosen.stderr
        default = run([*vm_command(), "--", bytecode], env=vm_environment(extra))
        assert (default.code, default.stdout) == (0, "1\n")
    plain = vm(bytecode)
    assert (plain.code, plain.stdout) == (0, "1\n")


@pytest.mark.parametrize("path", [path for path in diff.fixture_programs() if path.stem in ORDER], ids=lambda p: p.stem)
def test_a_fixture_whose_order_depends_on_tasks_keeps_its_golden_with_the_flag_at_one(path, tmp_path):
    """`--schedulers 1` alone, with AGENTICA_SCHEDULERS unset, gives the order of the golden."""
    unset = {"AGENTICA_SCHEDULERS": None}
    assert golden_outcome(path, tmp_path, ["--schedulers", "1"], env=unset) == diff.read_expected(path)


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


@host_only(WINDOWS or not hasattr(os, "mkfifo") or not hasattr(signal, "SIGTERM"),
           "Windows has no POSIX stop signals and no FIFO files")
def test_a_stop_signal_ends_a_run_with_spinners_and_a_blocked_reader(tmp_path):
    # The I/O thread handles the signal (the schedulers keep it blocked) and ends the run at once, with spinning tasks
    # and a task blocked on a FIFO that is held open and never written.
    bytecode = program(tmp_path, "spin_wait", SPIN_AND_WAIT)
    fifo = tmp_path / "held"
    os.mkfifo(fifo)
    held = os.open(fifo, os.O_RDWR)
    try:
        process = subprocess.Popen([*vm_command(), *FLAGS, "--", bytecode, str(fifo)], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(),
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
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(),
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
    result = run([vm_command()[0], *FLAGS, str(source)], env=vm_environment())
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
                      str(requests)], env=vm_environment(env), timeout=120)
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
                     env=vm_environment(), timeout=60)
        assert (result.code, result.stdout, result.stderr) == (0, "false\nfalse\nok()\nfalse\nfalse\n", "")
