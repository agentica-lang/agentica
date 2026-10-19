"""Programs that reach the shared-state locks of the VM, run with every lock on (AGENTICA_VM_TEST_SHARED=1).

In that mode a mutator of the shared lists that runs without rt->sync, or a lock that is still held when a turn ends,
stops the run with RUNTIME-INTERNAL. `make test-shared` runs the other binary modules the same way; these cases are the
paths those modules do not reach: a builtin that fails while it holds the lock, a stepper that cancels tasks, a wait
for a handle's lock that times out, and a second reader of standard input that waits for the first.
"""
import subprocess
import time

from tests.agentica_test import RUN_TIMEOUT, compile_text, run_vm, vm_command, vm_environment

SHARED = {"AGENTICA_VM_TEST_SHARED": "1"}

CRASH_IN_BUILTIN = """\
def bad_map(n: Int) -> Result[Int]
  Task.map([1, 2], n, 100) do |x|
    ok(x)
  end
  return ok(n)
end

def main() -> Void
  crashed = Task.spawn(&bad_map, 0)
  other = Task.spawn(&bad_map, 1)
  puts(Task.await(other))
  puts(Task.await(crashed))
  puts(Task.await(Task.spawn(&bad_map, 2)))
end
"""

MAP_TIMEOUT = """\
def slow(ms: Int) -> Result[Int]
  Task.sleep(ms)
  return ok(ms)
end

def main() -> Void
  puts(Task.map([5000, 0, 5000], 3, 40, &slow))
end
"""

HANDLE_WAIT_TIMEOUT = """\
def reader(s: Socket) -> Result[String]
  return TCP.read_line(s, 400)
end

def impatient(s: Socket) -> Result[String]
  return TCP.read_line(s, 20)
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  client = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(listener), 5000))
  server = Result.unwrap!(TCP.accept(listener, 5000))
  holder = Task.spawn(&reader, client)
  Task.sleep(0)
  waiter = Task.spawn(&impatient, client)
  puts(Task.await(waiter))
  puts(Task.await(holder))
end
"""

CANCELLED_WAITER = """\
def reader(s: Socket) -> Result[String]
  return TCP.read_line(s, 400)
end

def patient(s: Socket) -> Result[String]
  return TCP.read_line(s, 20000)
end

def parent(s: Socket) -> Result[Int]
  Task.spawn(&patient, s)
  Task.sleep(0)
  Task.sleep(0)
  return ok([1][3])
end

def main() -> Void
  listener = Result.unwrap!(TCP.listen("127.0.0.1", 0))
  client = Result.unwrap!(TCP.connect("127.0.0.1", TCP.local_port(listener), 5000))
  server = Result.unwrap!(TCP.accept(listener, 5000))
  holder = Task.spawn(&reader, client)
  Task.sleep(0)
  puts(Task.await(Task.spawn(&parent, client)))
  puts(Task.await(holder))
end
"""

STDIN_PARKS = """\
def reader(n: Int) -> String
  return IO.read()
end

def main() -> Void
  first = Task.spawn(&reader, 1)
  Task.sleep(0)
  second = IO.read()
  puts("main read #{second.length} bytes")
  puts("task read #{Task.await(first).length} bytes")
end
"""


def run_shared(program, tmp_path, name, **options):
    bytecode = compile_text(program, name, tmp_path)
    return run_vm(bytecode, env=vm_environment(SHARED), **options)


def test_a_builtin_that_fails_in_a_task_gives_back_the_lock(tmp_path):
    result = run_shared(CRASH_IN_BUILTIN, tmp_path, "crash_in_builtin")
    assert "RUNTIME-INTERNAL" not in result.stderr
    assert "RUNTIME-INVALID-COUNT" in result.stderr
    assert result.stdout.splitlines()[0] == "ok(1)"


def test_task_map_cancels_the_items_that_time_out(tmp_path):
    result = run_shared(MAP_TIMEOUT, tmp_path, "map_timeout")
    assert result.code == 0, result.stderr
    assert result.stdout.count("task: timed out") == 2
    assert "ok(0)" in result.stdout


def test_a_wait_for_a_handle_lock_that_times_out_leaves_the_queue(tmp_path):
    result = run_shared(HANDLE_WAIT_TIMEOUT, tmp_path, "handle_wait_timeout")
    assert result.code == 0, result.stderr
    assert result.stdout.count("operation timed out") == 2


def test_a_task_cancelled_while_it_waits_for_a_handle_lock_leaves_the_queue(tmp_path):
    result = run_shared(CANCELLED_WAITER, tmp_path, "cancelled_waiter")
    assert "RUNTIME-INTERNAL" not in result.stderr
    assert "task crashed: RUNTIME-INDEX-OUT-OF-RANGE" in result.stdout
    assert "operation timed out" in result.stdout


def test_a_second_reader_of_standard_input_waits_for_the_first(tmp_path):
    bytecode = compile_text(STDIN_PARKS, "stdin_parks", tmp_path)
    process = subprocess.Popen([*map(str, vm_command()), "--", str(bytecode)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=vm_environment(SHARED))
    time.sleep(0.2)
    out, err = process.communicate(b"hello\n", timeout=RUN_TIMEOUT)
    assert process.returncode == 0, err
    assert sorted(out.decode().splitlines()) == ["main read 0 bytes", "task read 6 bytes"]
