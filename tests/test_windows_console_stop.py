"""Console events and a console as standard output, on native Windows.

A VM started in its own process group takes Ctrl+Break the way a terminal gives
it (libuv reports it as SIGBREAK), and ends as a stop: children die, buffered
file data is written, the exit code is 128 + 21. Ctrl+C cannot be sent to a new
group (CREATE_NEW_PROCESS_GROUP turns it off), but libuv reports both through
one console handler, so Ctrl+Break covers that path; tests/test_vm_stop.py sends
Ctrl+C itself, typed into a pseudo console. A pseudo console (ConPTY) is the
console of the tests that write standard output and standard error to a
console, which the VM writes from a pool thread with WriteConsoleW (UTF-8 in,
UTF-16 out, a character cut by the end of one write kept for the next). The
module needs a Windows console, so it does not run under Wine.
"""
import os
import signal
import subprocess
import time

import pytest

from tests.agentica_test import (PYTHON, compile_agc, scaled, start_vm, stop_a_vm_that_fills_its_stdout, vm_command,
                                 vm_environment, wait_until)
from tests.test_vm_stop import FULL_STDOUT  # the same program that fills the pipe on the POSIX systems
from tests.windows_console_support import CHILD, ESCAPES, WAIT_SECONDS, kernel32, run_on_console

pytestmark = pytest.mark.skipif(os.name != "nt", reason="host-only: CTRL_BREAK_EVENT and ConPTY exist on Windows only")

SIGBREAK = 21
NEW_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)

CHILD_PROGRAM = """\
def main() -> Void
  args = System.args()
  f = File.open(args[0], "write", 1000).unwrap!
  File.write(f, "buffered", 1000).unwrap!
  p = Process.spawn(args[1], ["-c", args[2]], 1000).unwrap!
  puts(Process.read_line(p, 5000).unwrap!)
  IO.flush()
  Task.sleep(30000)
end
"""

# 50 KiB fit the 64 KiB buffer of the stream whatever the size of the pipe (4 KiB for a Windows anonymous pipe), so the
# program reaches "ready" while the pipe is full; more would keep it printing.
STUCK_STDOUT = """\
def main() -> Void
  line = "y"
  for i in 0..9
    line = line + line
  end
  n = 0
  while n < 50
    puts(line)
    n += 1
  end
  IO.warn("ready")
  Task.sleep(30000)
end
"""

CONSOLE_PROGRAM = """\
def main() -> Void
  puts("tty line é")
  IO.warn("tty error ü")
  puts("tty end")
end
"""

# One line of 66560 bytes, 1024 more than the 64 KiB buffer, made of the pairs "€é" (3 + 2 bytes). The buffer holds
# 65536 bytes, and 65536 % 5 = 1, so the first write ends after the first byte of a "€": the pool thread has to keep
# that byte for the next write. The cut is 1024 bytes (about two rows) before the end, so it stays on the screen.
CUT_PROGRAM = """\
def main() -> Void
  block = "€é"
  for i in 0..9
    block = block + block
  end
  line = ""
  for i in 0..12
    line = line + block
  end
  puts(line)
  puts("cut end")
end
"""

# A task waits for a line of the console while the program, with one pool thread, writes and reads a file. The run
# ends with main, without waiting for the read. The results go to a file, not to the console that the test reads.
CONSOLE_STDIN = """\
def reader(n: Int) -> Int
  IO.inspect(IO.gets())
  return n
end

def main() -> Void
  Task.spawn(&reader, 1)
  Task.sleep(50)
  File.write_text(System.args()[0], "x", 1000).unwrap!
  text = File.read_text(System.args()[0], 1000).unwrap!
  File.write_text(System.args()[1], "read " + text, 1000).unwrap!
end
"""

# A line typed on the console, written to a file.
CONSOLE_LINE = """\
def main() -> Void
  File.write_text(System.args()[0], IO.gets().unwrap!, 1000).unwrap!
end
"""

# A task waits for standard input while main waits on it: the stop signal ends the run, not the read.
WAITING_FOR_INPUT = """\
def reader(n: Int) -> Result[String]
  return IO.gets()
end

def main() -> Void
  r = Task.spawn(&reader, 1)
  IO.warn("ready")
  IO.inspect(Task.await(r))
end
"""

def bytecode(text, tmp_path, name="program"):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, tmp_path / (name + ".agcb"))


def alive(pid):
    """True while the process exists (SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, then a zero-wait)."""
    handle = kernel32.OpenProcess(0x00100000 | 0x1000, False, pid)
    if not handle:
        return False
    try:
        return kernel32.WaitForSingleObject(handle, 0) == 0x102
    finally:
        kernel32.CloseHandle(handle)


def start_with_child(tmp_path, adopt):
    """The VM in its own process group with a child that ignores Ctrl+Break: (the file it writes, the VM, the child pid)."""
    path = tmp_path / "out.txt"
    vm = adopt(start_vm(bytecode(CHILD_PROGRAM, tmp_path), path, PYTHON, CHILD, flags=["--allow-run"],
                        creationflags=NEW_GROUP))
    return path, vm, int(vm.next_line(WAIT_SECONDS))


def test_ctrl_break_takes_the_exit_path_the_child_dies_buffered_file_data_is_written_and_the_exit_is_149(
    tmp_path, adopt
):
    path, vm, pid = start_with_child(tmp_path, adopt)
    vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    assert vm.wait(WAIT_SECONDS) == 128 + SIGBREAK
    assert path.read_text() == "buffered"
    assert wait_until(lambda: not alive(pid), WAIT_SECONDS, 0.1), "the child is gone"


def test_ctrl_break_with_standard_output_stuck_does_not_wait_for_the_flush_limit(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(STUCK_STDOUT, tmp_path), read_stdout=False, creationflags=NEW_GROUP))
    assert vm.next_stderr_line(WAIT_SECONDS) == "ready"
    time.sleep(0.3)
    start = time.monotonic()
    vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    assert vm.wait(WAIT_SECONDS) == 128 + SIGBREAK
    assert time.monotonic() - start < min(scaled(5), 25), "the run does not wait for the reader"


def test_standard_output_and_standard_error_on_a_console_arrive_in_order_as_text(tmp_path):
    code, shown = run_on_console([*vm_command(), "--", bytecode(CONSOLE_PROGRAM, tmp_path)], vm_environment(),
                                 WAIT_SECONDS)
    text = ESCAPES.sub("", shown)
    assert code == 0, text
    markers = ["tty line é", "tty error ü", "tty end"]
    positions = [text.find(marker) for marker in markers]
    assert -1 not in positions and positions == sorted(positions), text


def test_a_line_longer_than_the_buffer_reaches_a_console_with_no_character_cut_in_two(tmp_path):
    code, shown = run_on_console([*vm_command(), "--", bytecode(CUT_PROGRAM, tmp_path)], vm_environment(),
                                 WAIT_SECONDS)
    text = ESCAPES.sub("", shown)
    assert code == 0, text
    assert "\ufffd" not in text, "a character was cut in two"
    # Rows of the console hold 100 cells, so a run of 20 pairs is inside one row; the count of pairs is not checked,
    # since the console may drop rows that scrolled off between two of its repaints.
    assert "€é" * 20 in text, text[-400:]
    assert text.rfind("cut end") > text.rfind("€é"), text[-400:]


def test_two_ctrl_breaks_in_a_row_end_the_run_with_149_and_the_child_is_gone(tmp_path, adopt):
    _, vm, pid = start_with_child(tmp_path, adopt)
    vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    time.sleep(0.1)
    vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    assert vm.wait(WAIT_SECONDS) == 128 + SIGBREAK
    assert wait_until(lambda: not alive(pid), WAIT_SECONDS, 0.1), "the child is gone"


def test_ctrl_break_with_standard_output_full_ends_the_run_without_a_diagnostic(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(FULL_STDOUT, tmp_path), read_stdout=False, creationflags=NEW_GROUP))
    status = stop_a_vm_that_fills_its_stdout(vm, lambda: vm.process.send_signal(signal.CTRL_BREAK_EVENT), WAIT_SECONDS)
    assert status == 128 + SIGBREAK
    assert vm.stderr_text() == ""


def test_a_task_waiting_for_a_line_of_the_console_leaves_the_one_pool_thread_to_file_calls(tmp_path):
    env = vm_environment({"UV_THREADPOOL_SIZE": "1"})
    result = tmp_path / "result.txt"
    command = [*vm_command(), "--", bytecode(CONSOLE_STDIN, tmp_path), tmp_path / "out.txt", result]
    code, shown = run_on_console(command, env, WAIT_SECONDS)
    assert code == 0, ESCAPES.sub("", shown)
    assert result.read_text() == "read x"


def test_a_line_typed_on_the_console_reaches_a_waiting_reader(tmp_path):
    result = tmp_path / "result.txt"
    code, shown = run_on_console([*vm_command(), "--", bytecode(CONSOLE_LINE, tmp_path), result],
                                 vm_environment({"UV_THREADPOOL_SIZE": "1"}), WAIT_SECONDS, typed="typed line\r")
    assert code == 0, ESCAPES.sub("", shown)
    assert result.read_text() == "typed line"


def test_ctrl_break_ends_a_run_whose_task_waits_for_standard_input(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(WAITING_FOR_INPUT, tmp_path), env={"UV_THREADPOOL_SIZE": "1"}, stdin=True,
                        creationflags=NEW_GROUP))
    assert vm.next_stderr_line(WAIT_SECONDS) == "ready"
    time.sleep(0.2)
    start = time.monotonic()
    vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    assert vm.wait(WAIT_SECONDS) == 128 + SIGBREAK
    assert time.monotonic() - start < min(scaled(5), 25), "the run does not wait for the read"
