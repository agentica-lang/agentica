"""Stop signals on the VM.

A SIGTERM, SIGINT or SIGHUP takes the exit path: children die, buffered file
data is written, and the VM dies by the signal. fixtures/stop-peer.py starts
the VM with chosen signal dispositions, fills a FIFO, or plays the driver of a
driven VM. A process killed by a signal has returncode -signal here (the
original test saw 128 + signal).
"""
import os
import signal
import time

import pytest

from tests.agentica_test import (FIFO_FILE_REASON, FIXTURES, PYTHON, UNDER_WINE, WINDOWS, Child, cli, compile_agc, host_only, kill_process,
                                 known_issue, process_alive, scaled, start_vm, stop_a_vm_that_fills_its_stdout, vm_command,
                                 vm_environment, wait_until)

# SIGTERM, SIGINT, SIGHUP and SIGALRM are POSIX signals, so each case that sends one is host-only on Windows, and the
# reason says which case of tests/test_windows_console_stop.py sends Ctrl+Break for the same behavior. The two cases that
# need a full FIFO are host-only: the VM refuses a named pipe as a file on Windows. The Ctrl+C through the CLI has no
# Windows test yet (issue 437).

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

# 70 KiB: more than the 64 KiB that a Linux pipe holds, so the output is stuck there, and less than the 16 KiB pipe of
# macOS plus the 64 KiB buffer of the VM, so the program still reaches the warning there.
STUCK_STDOUT = """\
def main() -> Void
  line = "y"
  for i in 0..9
    line = line + line
  end
  n = 0
  while n < 70
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


NO_FILE_FLUSH = "a flush that a FIFO holds up; " + FIFO_FILE_REASON

# Standard output that stays stuck on Windows: 50 KiB fit the 64 KiB buffer of the stream whatever the size of the pipe
# (4 KiB there), so the program reaches "ready" while the pipe is full.
WINDOWS_STUCK_STDOUT = STUCK_STDOUT.replace("n < 70", "n < 50")


def gone_soon(pid):
    """True when the process ends within WAIT_SECONDS; otherwise it is killed so it cannot outlive the test."""
    if wait_until(lambda: not process_alive(pid), WAIT_SECONDS, 0.1):
        return True
    kill_process(pid)
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


def check_a_driven_vm_with_stuck_standard_output(tmp_path, adopt):
    """The Windows form of the case below: no file flush waits there, so the flush that a dead driver must not wait for
    is the one of standard output, a pipe that the test holds and does not read (so it is full, not broken, when the
    driver dies). The driver is a Python process that starts the VM with --driver-pid, which Windows takes only for a
    private input: the copy that a VM makes with create_private (an access list that names only its owner)."""
    from tests.agentica_test import run_vm
    from tests.test_windows_process_cleanup import COPY_PROGRAM
    if UNDER_WINE:
        pytest.skip("Wine gives the pipe 64 KiB, so the rows fit it and nothing is stuck")
    public = bytecode(WINDOWS_STUCK_STDOUT, tmp_path)
    code = tmp_path / "driven.agcb"
    made = run_vm(bytecode(COPY_PROGRAM, tmp_path, "copy-private"), args=[public, code], env=vm_environment(),
                  cwd=tmp_path)
    assert (made.code, made.stderr) == (0, ""), made
    driver = adopt(Child([PYTHON, PEER, "drive-inherited", *vm_command(), "--", code], capture_stderr=True,
                         read_stdout=False))
    pid = int(driver.next_stderr_line(WAIT_SECONDS))
    ready = driver.next_stderr_line(WAIT_SECONDS)
    assert ready == "ready", ready
    time.sleep(0.3)
    driver.process.kill()
    assert gone_soon(pid), "the VM ends after its driver"


def full_fifo(adopt, tmp_path):
    """A FIFO whose buffer is full, kept by a peer until the test ends."""
    fifo = tmp_path / "fifo"
    peer = adopt(Child([PYTHON, PEER, "fill", fifo], stdin=True))
    assert peer.next_line(WAIT_SECONDS) == "ready"
    return fifo


@host_only(WINDOWS, "SIGTERM, SIGINT and SIGHUP; Windows has Ctrl+Break, and test_ctrl_break_takes_the_exit_path in test_windows_console_stop.py checks the child, the file and the exit code")
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


@host_only(WINDOWS, "a stop signal inherited as ignored (nohup) has no Windows form")
def test_a_stop_signal_the_vm_inherited_as_ignored_stays_ignored(tmp_path, adopt):
    vm = launch(adopt, "ignore", "--", bytecode(READY_AND_SLEEP, tmp_path), capture_stderr=True)
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGHUP)
    os.kill(vm.process.pid, signal.SIGINT)
    time.sleep(0.5)
    assert vm.process.poll() is None, "the ignored signals do not stop the VM"


@host_only(WINDOWS, "SIGALRM does not exist on Windows")
def test_an_outside_sigalrm_keeps_its_default_action(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(READY_AND_SLEEP, tmp_path)))
    assert vm.next_line(WAIT_SECONDS) == "ready"
    os.kill(vm.process.pid, signal.SIGALRM)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGALRM


@host_only(WINDOWS, "SIGTERM and a shell child that traps it; Windows has no SIGTERM to ignore, so test_two_ctrl_breaks_in_a_row in test_windows_console_stop.py checks only that two breaks still end the run with 149 and stop the child")
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


@host_only(WINDOWS, NO_FILE_FLUSH + "; test_ctrl_break_with_standard_output_stuck_does_not_wait_for_the_flush_limit and "
                    "test_two_ctrl_breaks_in_a_row_end_the_run_with_149_and_the_child_is_gone in "
                    "test_windows_console_stop.py check a stop with standard output stuck and a second Ctrl+Break")
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
    if WINDOWS:
        return check_a_driven_vm_with_stuck_standard_output(tmp_path, adopt)
    fifo = full_fifo(adopt, tmp_path)
    driver = adopt(Child([PYTHON, PEER, "drive", *vm_command(), "--", bytecode(STUCK_FLUSH, tmp_path), fifo]))
    pid = int(driver.next_line(WAIT_SECONDS))
    driver.wait(WAIT_SECONDS)
    assert gone_soon(pid), "the VM ends after its driver"


@host_only(WINDOWS, "SIGTERM; test_ctrl_break_with_standard_output_full in test_windows_console_stop.py checks the same run with Ctrl+Break")
def test_a_stop_signal_while_standard_output_is_full_ends_the_run_without_a_diagnostic(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(FULL_STDOUT, tmp_path), read_stdout=False))
    status = stop_a_vm_that_fills_its_stdout(vm, lambda: os.kill(vm.process.pid, signal.SIGTERM), WAIT_SECONDS)
    assert status == -signal.SIGTERM
    assert vm.stderr_text() == ""


@host_only(WINDOWS, "SIGTERM; test_ctrl_break_with_standard_output_stuck in test_windows_console_stop.py checks the same run with Ctrl+Break")
def test_a_stop_signal_with_standard_output_stuck_does_not_wait_for_the_flush_limit(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(STUCK_STDOUT, tmp_path), read_stdout=False))
    assert vm.next_stderr_line(WAIT_SECONDS) == "ready"
    time.sleep(0.3)
    start = time.monotonic()
    os.kill(vm.process.pid, signal.SIGTERM)
    assert vm.wait(WAIT_SECONDS) == -signal.SIGTERM
    assert time.monotonic() - start < min(scaled(5), 25), "the run does not wait for the reader"


@known_issue(WINDOWS, 437, "Ctrl+C through the CLI has no Windows test")
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
