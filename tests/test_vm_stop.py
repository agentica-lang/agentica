"""Stop signals on the VM.

A SIGTERM, SIGINT or SIGHUP takes the exit path: children die, buffered file
data is written, and the VM dies by the signal. fixtures/stop-peer.py starts
the VM with chosen signal dispositions, fills a FIFO, or plays the driver of a
driven VM. A process killed by a signal has returncode -signal here (the
original test saw 128 + signal).
"""
import os
import signal
import threading
import time

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, Child, adopt, cli, compile_agc, process_alive, scaled, start_vm,
                                 vm_command, vm_environment, wait_until)

PEER = FIXTURES / "stop-peer.py"
WAIT_SECONDS = scaled(10)

STUCK_FLUSH = """\
def main() -> Void
  f = File.open(System.args()[0], "write", 5000).unwrap!
  File.write(f, "x", 1000).unwrap!
  puts("ready")
  IO.flush()
end
"""

READY_AND_SLEEP = """\
def main() -> Void
  puts("ready")
  IO.flush()
  Task.sleep(30000)
end
"""

FULL_STDOUT = """\
def main() -> Void
  line = "y"
  for i in 0..12
    line = line + line
  end
  while true
    puts(line)
  end
end
"""

STUCK_STDOUT = """\
def main() -> Void
  line = "y"
  for i in 0..9
    line = line + line
  end
  n = 0
  while n < 100
    puts(line)
    n += 1
  end
  IO.warn("ready")
  Task.sleep(30000)
end
"""


def child_program(trap=""):
    """Writes "buffered" to a file, spawns `sh` (which prints its pid, then sleeps) and waits or spins.

    With a trap the child is spawned captured, so it ignores the signals the trap names.
    """
    return """\
def main() -> Void
  f = File.open(System.args()[0], "write", 1000).unwrap!
  File.write(f, "buffered", 1000).unwrap!
  p = Process.%s("/bin/sh", ["-c", "%secho $$; exec sleep 30"]%s, 1000).unwrap!
  puts(Process.read_line(p, 5000).unwrap!)
  IO.flush()
  if System.args()[1] == "sleep"
    Task.sleep(30000)
  else
    n = 0
    while true
      n = n + 1
    end
  end
end
""" % (("spawn", "", "") if trap == "" else ("spawn_captured", trap, ', "."'))


def gone_soon(pid):
    """True when the process ends within WAIT_SECONDS; otherwise it is killed so it cannot outlive the test."""
    if wait_until(lambda: not process_alive(pid), WAIT_SECONDS, 0.1):
        return True
    os.kill(pid, signal.SIGKILL)
    return False




def bytecode(text, tmp_path, name="program"):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    path = compile_agc(source, tmp_path / (name + ".agcb"))
    os.chmod(path, 0o600)
    return path


def launch(adopt, disposition, *argv, **options):
    """The VM started by stop-peer.py with SIGHUP, SIGINT and SIGTERM set to `disposition` (default or ignore)."""
    return adopt(Child([PYTHON, PEER, "launch", disposition, *vm_command(), *argv], **options))


def check_stopped(pid, path, label):
    assert path.read_text() == "buffered", label
    assert gone_soon(pid), "%s: the child is gone" % label


def full_fifo(adopt, tmp_path):
    """A FIFO whose buffer is full, kept by a peer until the test ends."""
    fifo = tmp_path / "fifo"
    peer = adopt(Child([PYTHON, PEER, "fill", fifo], stdin=True))
    assert peer.next_line(WAIT_SECONDS) == "ready"
    return fifo


def test_a_stop_signal_takes_the_exit_path_children_die_buffered_file_data_is_written_the_vm_dies_by_the_signal(
    tmp_path, adopt
):
    for mode, number in (("sleep", signal.SIGTERM), ("spin", signal.SIGINT), ("sleep", signal.SIGHUP)):
        path = tmp_path / ("out-%s-%d.txt" % (mode, number))
        vm = launch(adopt, "default", "--allow-run", "--", bytecode(child_program(), tmp_path, "program-%s" % mode),
                    path, mode, capture_stderr=True)
        pid = int(vm.next_line(WAIT_SECONDS))
        os.kill(vm.process.pid, number)
        assert vm.wait(WAIT_SECONDS) == -number
        check_stopped(pid, path, "%s %s" % (mode, number))


def test_a_stop_signal_the_vm_inherited_as_ignored_stays_ignored(tmp_path, adopt):
    vm = launch(adopt, "ignore", "--", bytecode(READY_AND_SLEEP, tmp_path), capture_stderr=True)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGHUP)
    os.kill(vm.process.pid, signal.SIGINT)
    time.sleep(0.5)
    assert vm.process.poll() is None, "the ignored signals do not stop the VM"


def test_an_outside_sigalrm_keeps_its_default_action(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(READY_AND_SLEEP, tmp_path)))
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGALRM)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGALRM


def test_a_second_stop_signal_before_the_children_are_stopped_waits_for_them(tmp_path, adopt):
    path = tmp_path / "out.txt"
    code = bytecode(child_program("trap '' TERM; "), tmp_path)
    vm = adopt(start_vm(code, path, "sleep", flags=["--allow-run"]))
    pid = int(vm.next_line(WAIT_SECONDS))
    os.kill(vm.process.pid, signal.SIGTERM)
    time.sleep(0.1)
    os.kill(vm.process.pid, signal.SIGTERM)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGTERM
    assert gone_soon(pid), "the child is gone"


def test_a_second_stop_signal_ends_a_flush_that_cannot_finish_the_first_one_waits_for_it(tmp_path, adopt):
    fifo = full_fifo(adopt, tmp_path)
    vm = launch(adopt, "default", "--", bytecode(STUCK_FLUSH, tmp_path), fifo)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    time.sleep(0.3)
    os.kill(vm.process.pid, signal.SIGINT)
    time.sleep(0.5)
    assert vm.process.poll() is None, "the first signal flushes within the flush limit"
    os.kill(vm.process.pid, signal.SIGTERM)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGTERM


def test_a_driven_vm_whose_driver_died_does_not_wait_for_its_flush(tmp_path, adopt):
    fifo = full_fifo(adopt, tmp_path)
    driver = adopt(Child([PYTHON, PEER, "drive", *vm_command(), "--", bytecode(STUCK_FLUSH, tmp_path), fifo]))
    pid = int(driver.next_line(WAIT_SECONDS))
    driver.wait(WAIT_SECONDS)
    assert gone_soon(pid), "the VM ends after its driver"


def test_a_stop_signal_while_standard_output_is_full_ends_the_run_without_a_diagnostic(tmp_path, adopt):
    # stdout is a pipe that nobody reads until the signal: Child must not drain it.
    vm = adopt(start_vm(bytecode(FULL_STDOUT, tmp_path), read_stdout=False))
    # Read the first line in a thread: a live VM that prints nothing must fail in WAIT_SECONDS, not hang.
    first = []
    reader = threading.Thread(target=lambda: first.append(vm.process.stdout.readline()), daemon=True)
    reader.start()
    reader.join(WAIT_SECONDS)
    assert first and first[0], "the VM printed a line"
    time.sleep(0.3)
    os.kill(vm.process.pid, signal.SIGTERM)
    drain = threading.Thread(target=vm.process.stdout.read, daemon=True)
    drain.start()
    assert vm.wait(WAIT_SECONDS) == -signal.SIGTERM
    drain.join(WAIT_SECONDS)
    assert vm.stderr_text() == ""


def test_a_stop_signal_with_standard_output_stuck_does_not_wait_for_the_flush_limit(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(STUCK_STDOUT, tmp_path), read_stdout=False))
    assert vm.next_stderr_line(WAIT_SECONDS) == "ready"
    time.sleep(0.3)
    start = time.monotonic()
    os.kill(vm.process.pid, signal.SIGTERM)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGTERM
    assert time.monotonic() - start < min(scaled(5), 25), "the run does not wait for the reader"


def test_ctrl_c_through_the_cli_stops_a_child_that_ignores_the_signals_and_writes_the_file(tmp_path, adopt):
    path = tmp_path / "out.txt"
    source = tmp_path / "program.agc"
    source.write_text(child_program("trap '' INT TERM; "), encoding="utf-8")
    # The CLI, the VM and the child share the Child's session and process group, as a terminal's Ctrl-C reaches them.
    cli_child = adopt(Child(cli() + ["--allow-run", source, path, "sleep"],
                            env=vm_environment(), capture_stderr=True))
    pid = int(cli_child.next_line(6 * WAIT_SECONDS))
    os.killpg(cli_child.process.pid, signal.SIGINT)
    cli_child.wait(WAIT_SECONDS)
    check_stopped(pid, path, "cli")
