"""Stop signals on the VM (ported from vm-stop-test.rkt).

A SIGTERM, SIGINT or SIGHUP takes the exit path: children die, buffered file
data is written, and the VM dies by the signal. fixtures/stop-peer.py starts
the VM with chosen signal dispositions, fills a FIFO, or plays the driver of a
driven VM. A process killed by a signal has returncode -signal here (the
Racket test saw 128 + signal).
"""
import os
import signal
import threading
import time

from tests.agentica_test import (FIXTURES, PYTHON, Child, TestCase, cli, process_alive, scaled, start_vm, vm_binary,
                                 vm_environment, wait_until)

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


class VmStop(TestCase):
    def bytecode(self, text):
        path = self.compile_text(text, "program")
        os.chmod(path, 0o600)
        return path

    def launch(self, disposition, *argv, **options):
        """The VM started by stop-peer.py with SIGHUP, SIGINT and SIGTERM set to `disposition` (default or ignore)."""
        return self.adopt(Child([PYTHON, PEER, "launch", disposition, vm_binary(), *argv], **options))

    def check_stopped(self, pid, path, label):
        self.assertEqual(path.read_text(), "buffered", label)
        self.assertTrue(gone_soon(pid), "%s: the child is gone" % label)

    def full_fifo(self):
        """A FIFO whose buffer is full, kept by a peer until the test ends."""
        fifo = self.make_temp_dir() / "fifo"
        peer = self.adopt(Child([PYTHON, PEER, "fill", fifo], stdin=True))
        self.assertEqual(peer.next_line(WAIT_SECONDS), "ready")
        return fifo

    def test_a_stop_signal_takes_the_exit_path_children_die_buffered_file_data_is_written_the_vm_dies_by_the_signal(self):
        for mode, number in (("sleep", signal.SIGTERM), ("spin", signal.SIGINT), ("sleep", signal.SIGHUP)):
            with self.subTest(mode=mode, signal=number):
                path = self.make_temp_dir() / "out.txt"
                vm = self.launch("default", "--allow-run", "--", self.bytecode(child_program()), path, mode,
                                 capture_stderr=True)
                pid = int(vm.next_line(WAIT_SECONDS))
                os.kill(vm.process.pid, number)
                self.assertEqual(vm.wait(WAIT_SECONDS), -number)
                self.check_stopped(pid, path, "%s %s" % (mode, number))

    def test_a_stop_signal_the_vm_inherited_as_ignored_stays_ignored(self):
        vm = self.launch("ignore", "--", self.bytecode(READY_AND_SLEEP), capture_stderr=True)
        self.assertEqual(vm.next_line(WAIT_SECONDS), "ready")
        os.kill(vm.process.pid, signal.SIGHUP)
        os.kill(vm.process.pid, signal.SIGINT)
        time.sleep(0.5)
        self.assertIsNone(vm.process.poll(), "the ignored signals do not stop the VM")

    def test_an_outside_sigalrm_keeps_its_default_action(self):
        vm = self.adopt(start_vm(self.bytecode(READY_AND_SLEEP)))
        self.assertEqual(vm.next_line(WAIT_SECONDS), "ready")
        os.kill(vm.process.pid, signal.SIGALRM)
        self.assertEqual(vm.wait(WAIT_SECONDS), -signal.SIGALRM)

    def test_a_second_stop_signal_before_the_children_are_stopped_waits_for_them(self):
        path = self.make_temp_dir() / "out.txt"
        bytecode = self.bytecode(child_program("trap '' TERM; "))
        vm = self.adopt(start_vm(bytecode, path, "sleep", flags=["--allow-run"]))
        pid = int(vm.next_line(WAIT_SECONDS))
        os.kill(vm.process.pid, signal.SIGTERM)
        time.sleep(0.1)
        os.kill(vm.process.pid, signal.SIGTERM)
        self.assertEqual(vm.wait(WAIT_SECONDS), -signal.SIGTERM)
        self.assertTrue(gone_soon(pid), "the child is gone")

    def test_a_second_stop_signal_ends_a_flush_that_cannot_finish_the_first_one_waits_for_it(self):
        fifo = self.full_fifo()
        vm = self.launch("default", "--", self.bytecode(STUCK_FLUSH), fifo)
        self.assertEqual(vm.next_line(WAIT_SECONDS), "ready")
        time.sleep(0.3)
        os.kill(vm.process.pid, signal.SIGINT)
        time.sleep(0.5)
        self.assertIsNone(vm.process.poll(), "the first signal flushes within the flush limit")
        os.kill(vm.process.pid, signal.SIGTERM)
        self.assertEqual(vm.wait(WAIT_SECONDS), -signal.SIGTERM)

    def test_a_driven_vm_whose_driver_died_does_not_wait_for_its_flush(self):
        fifo = self.full_fifo()
        driver = self.adopt(Child([PYTHON, PEER, "drive", vm_binary(), "--", self.bytecode(STUCK_FLUSH), fifo]))
        pid = int(driver.next_line(WAIT_SECONDS))
        driver.wait(WAIT_SECONDS)
        self.assertTrue(gone_soon(pid), "the VM ends after its driver")

    def test_a_stop_signal_while_standard_output_is_full_ends_the_run_without_a_diagnostic(self):
        # stdout is a pipe that nobody reads until the signal: Child must not drain it.
        vm = self.adopt(start_vm(self.bytecode(FULL_STDOUT), read_stdout=False))
        # Read the first line in a thread: a live VM that prints nothing must fail in WAIT_SECONDS, not hang.
        first = []
        reader = threading.Thread(target=lambda: first.append(vm.process.stdout.readline()), daemon=True)
        reader.start()
        reader.join(WAIT_SECONDS)
        self.assertTrue(first and first[0], "the VM printed a line")
        time.sleep(0.3)
        os.kill(vm.process.pid, signal.SIGTERM)
        drain = threading.Thread(target=vm.process.stdout.read, daemon=True)
        drain.start()
        self.assertEqual(vm.wait(WAIT_SECONDS), -signal.SIGTERM)
        drain.join(WAIT_SECONDS)
        self.assertEqual(vm.stderr_text(), "")

    def test_a_stop_signal_with_standard_output_stuck_does_not_wait_for_the_flush_limit(self):
        vm = self.adopt(start_vm(self.bytecode(STUCK_STDOUT), read_stdout=False))
        self.assertEqual(vm.next_stderr_line(WAIT_SECONDS), "ready")
        time.sleep(0.3)
        start = time.monotonic()
        os.kill(vm.process.pid, signal.SIGTERM)
        self.assertEqual(vm.wait(WAIT_SECONDS), -signal.SIGTERM)
        self.assertLess(time.monotonic() - start, min(scaled(5), 25), "the run does not wait for the reader")

    def test_ctrl_c_through_the_cli_stops_a_child_that_ignores_the_signals_and_writes_the_file(self):
        path = self.make_temp_dir() / "out.txt"
        source = self.make_temp_dir() / "program.agc"
        source.write_text(child_program("trap '' INT TERM; "), encoding="utf-8")
        # The CLI, the VM and the child share the Child's session and process group, as a terminal's Ctrl-C reaches them.
        cli_child = self.adopt(Child(cli() + ["--allow-run", source, path, "sleep"],
                                     env=vm_environment({"AGENTICA_VM": vm_binary()}), capture_stderr=True))
        pid = int(cli_child.next_line(6 * WAIT_SECONDS))
        os.killpg(cli_child.process.pid, signal.SIGINT)
        cli_child.wait(WAIT_SECONDS)
        self.check_stopped(pid, path, "cli")
