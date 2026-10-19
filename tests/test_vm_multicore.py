"""Programs on several scheduler threads (AGENTICA_VM_TEST_MULTICORE=1, --schedulers 4).

More than one scheduler runs only under that test switch until the count is lifted (#345). The goldens of
tests/fixtures/vm must hold at four schedulers too, except where the order of output between tasks is not fixed (the
ORDER set) and for the libraries that still call libuv from their scheduler, which a run with several schedulers
refuses (TCP, TLS, HTTP, Process, Duplex and the Test protocol). The other cases check what threads must keep: whole
lines, exact sums, timers that fire, the end of the run from any scheduler, standard input and FIFOs, and the switch.
`make test-multicore` runs this module; `make vm-tsan-run` runs it on a ThreadSanitizer build.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import threading

import pytest

try:
    import fcntl
except ImportError:
    fcntl = None

from tests.agentica_test import FIXTURES, compile_text, run, vm_command, vm_environment
from tests import vm_diff_support as diff

SCHEDULERS = os.environ.get("AGENTICA_VM_TEST_SCHEDULER_COUNT", "4")
MULTICORE = {"AGENTICA_VM_TEST_MULTICORE": "1"}
FLAGS = ["--schedulers", SCHEDULERS]
# A race case runs once in the fast tier and 20 times in the slow tier (make test-slow).
RACE = pytest.mark.parametrize("repeats", [1, pytest.param(20, marks=pytest.mark.slow)], ids=["once", "20x"])

# The output of these fixtures depends on how tasks interleave (prints from several tasks, a race against a deadline,
# which of two tasks finds an await cycle, whether a task has run after a yield or a preemption, the count of tasks
# still pending),
# which a run on several threads does not fix.
ORDER = {"channel-fan-in", "channel-owner-handoff", "channel-returned-order", "logger-tasks",
         "task-await-cycle", "task-crash-descendants", "task-crash-result", "task-pending-count", "task-preempt-fail",
         "task-file-close", "test-run-task"}
# Builtins that a run with several schedulers refuses (agc_program_for_threads in vm/builtin_tables.c, and Test.run on
# the parent channel): such a fixture keeps its golden or stops with RUNTIME-INTERNAL.
LOOP_BOUND = re.compile(r"\b(TCP|TLS|HTTP|HTTPServer|Process)\.|\bTest\.run\b")


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
        return
    assert seen == diff.read_expected(path)


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


def test_a_network_call_is_refused_on_several_schedulers(tmp_path):
    bytecode = program(tmp_path, "net", "def main() -> Void\n  IO.inspect(TCP.listen(\"127.0.0.1\", 0))\nend\n")
    result = vm(bytecode, "--json")
    assert diff.outcome((result.code, result.stdout, result.stderr))[3] == "RUNTIME-INTERNAL"


def test_more_schedulers_need_the_switch_and_refuse_the_profile_and_blocking_output(tmp_path):
    bytecode = program(tmp_path, "plain", "def main() -> Void\n  puts(1)\nend\n")
    plain = run([*vm_command(), *FLAGS, "--", bytecode], env=vm_environment())
    assert plain.code == 2 and "schedulers were asked for" in plain.stderr
    assert vm(bytecode).stdout == "1\n"
    profile = vm(bytecode, env={"AGENTICA_VM_TRACE": "profile"})
    assert profile.code == 2 and "profile" in profile.stderr
    blocking = vm(bytecode, env={"AGENTICA_VM_TEST_BLOCKING_OUTPUT": "1"})
    assert blocking.code == 2 and "BLOCKING_OUTPUT" in blocking.stderr


def test_the_front_end_runs_a_source_file_on_several_schedulers(tmp_path):
    source = tmp_path / "fan.agc"
    source.write_text(FAN_OUT, encoding="utf-8")
    result = run([vm_command()[0], *FLAGS, str(source)], env=vm_environment(MULTICORE))
    assert (result.code, result.stdout, result.stderr) == (0, "%d\n" % expected_fan_out(), "")
