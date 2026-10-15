"""Standard output and standard error of the VM against slow, stuck and vanishing readers
(ported from vm-stdout-test.rkt).

fixtures/stdout-peer.py starts the VM with its stdout and stderr on a pipe, a
socket, a pty or a merged pipe, reads them slowly (or never), and prints a
JSON summary: the exit status and when the reader started, the VM exited, and
the first error byte arrived. Programs that need no peer run with their
streams on files.
"""
import json
import re
import time

from tests.agentica_test import FIXTURES, PYTHON, TestCase, run, scaled, vm_command, vm_environment

PEER = FIXTURES / "stdout-peer.py"
PEER_LIMIT = scaled(90)
FILLER = "x" * 1024


ROWS_PROGRAM = """\
def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < %d
    puts("row #{n} #{filler}")
    n += 1
  end
end

"""

TICKER_PROGRAM = """\
def ticker(count: Int) -> Int
  n = 0
  while n < count
    Task.sleep(50)
    IO.warn("tick")
    n += 1
  end
  return n
end

def main() -> Void
  t = Task.spawn(&ticker, 40)
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < %d
    puts("row #{n} #{filler}")
    n += 1
  end
  Task.await(t)
end

"""

TWO_WRITERS_PROGRAM = """\
def writer(tag: String) -> Int
  filler = "x"
  for i in 0..12
    filler = filler + filler
  end
  n = 0
  while n < 40
    puts("#{tag}#{n} #{filler}")
    n += 1
  end
  return n
end

def main() -> Void
  a = Task.spawn(&writer, "A")
  b = Task.spawn(&writer, "B")
  Task.await(a)
  Task.await(b)
end

"""

LONG_PRINT_PROGRAM = """\
def shorts(count: Int) -> Int
  n = 0
  while n < count
    puts("short-#{n}")
    n += 1
  end
  return n
end

def main() -> Void
  s = Task.spawn(&shorts, 200)
  big = "z"
  for i in 0..17
    big = big + big
  end
  puts(big)
  puts(big)
  Task.await(s)
end

"""

CRASHED_PARENT_PROGRAM = """\
def child(filler: String) -> Void
  i = 0
  while true
    puts("C#{i} #{filler}")
    i += 1
  end
end

def parent(filler: String) -> Void
  Task.spawn(&child, filler)
  Task.sleep(300)
  x = 1 / 0
  puts(x)
end

def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  Task.await(Task.spawn(&parent, filler))
end

"""

BIG_UNWRAP_PROGRAM = """\
def parse(text: String) -> Result[Int]
  return error(text)
end

def main() -> Void
  big = "e"
  for i in 0..%d
    big = big + big
  end
  value = Result.unwrap!(parse(big))
  puts(value)
end

"""

STUCK_PRINT_PROGRAM = """\
def printer(big: String) -> Void
  puts(big)
  puts(big)
end

def crasher(k: Int) -> Void
  x = 1 / 0
  puts(x)
end

def main() -> Void
  big = "z"
  for i in 0..18
    big = big + big
  end
  Task.spawn(&printer, big)
  Task.sleep(100)
  Task.spawn(&crasher, 1)
  Task.sleep(100)
end

"""

OUTPUT_THEN_CRASH_PROGRAM = """\
def main() -> Void
  puts("before")
  print("partial")
  x = 1 / 0
  puts(x)
end

"""

DEV_STDOUT_PROGRAM = """\
def main() -> Void
  out = File.open("/dev/stdout", "write", 1000).unwrap!
  File.write(out, "via file\\n", 1000).unwrap!
  File.close(out, 1000).unwrap!
  err = File.open("/dev/stderr", "append", 1000).unwrap!
  File.write(err, "via stderr\\n", 1000).unwrap!
  File.close(err, 1000).unwrap!
  puts("normal")
  IO.warn("after")
end

"""

CRASH_WHILE_STUCK_PROGRAM = """\
def crasher(delay: Int) -> Void
  Task.sleep(delay)
  x = 1 / 0
  puts(x)
end

def main() -> Void
  Task.spawn(&crasher, 200)
  filler = "w"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < 200
    IO.warn("warn #{n} #{filler}")
    n += 1
  end
end

"""

ALTERNATE_PROGRAM = """\
def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < 150
    puts("o#{n} #{filler}")
    IO.warn("e#{n} #{filler}")
    n += 1
  end
end

"""

WARN_LAST_PROGRAM = """\
def main() -> Void
  puts("done")
  IO.warn("last words")
end

"""

FLUSH_PROGRAM = """\
def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  n = 0
  while n < 100
    puts("row #{n} #{filler}")
    n += 1
  end
  IO.flush()
  IO.warn("flushed")
end

"""

LIVE_CHILD_PROGRAM = """\
def main() -> Void
  child = Result.unwrap!(Process.spawn("/bin/sh", ["-c", "cat"], 5000))
  puts("child started")
  IO.inspect(Process.read_line(child, 100))
  puts("done")
end

"""


def row_total(count):
    return sum(1 + len("row %d %s" % (n, FILLER)) for n in range(count))


class VmStdout(TestCase):
    def run_case(self, name, program, peer=(), vm=(), env=None):
        """Run the program through stdout-peer.py; returns (summary, stdout bytes, stderr text)."""
        bytecode = self.compile_text(program, name)
        out_file = bytecode.with_suffix(".out")
        err_file = bytecode.with_suffix(".err")
        result = run([PYTHON, PEER, "--stdout-file", out_file, "--stderr-file", err_file, *peer,
                      "--", *vm_command(), *vm, "--", bytecode],
                     timeout=PEER_LIMIT, env=vm_environment(env))
        self.assertEqual(result.code, 0, "%s: the peer ends: %s" % (name, result.stderr))
        return json.loads(result.stdout), out_file.read_bytes(), err_file.read_text(errors="replace")

    def run_to_file(self, name, program, stderr_file=None):
        """Run the VM with stdout on a file. stderr_file: None captures it, True sends it to a file, a string is a path.

        Returns (exit code, seconds, stdout text, stderr text).
        """
        bytecode = self.compile_text(program, name)
        out_file = bytecode.with_suffix(".out")
        err_file = bytecode.with_suffix(".err") if stderr_file is True else stderr_file
        start = time.monotonic()
        result = run([*vm_command(), "--allow-run", "--flush-timeout", "20000", "--", bytecode], timeout=PEER_LIMIT,
                     env=vm_environment(), stdout_to=out_file, stderr_to=err_file)
        elapsed = time.monotonic() - start
        if stderr_file is None:
            errors = result.stderr
        else:
            errors = bytecode.with_suffix(".err").read_text(errors="replace") if stderr_file is True else ""
        return result.code, elapsed, out_file.read_text(errors="replace"), errors

    def lines_of(self, data):
        """The lines of a byte string, which must end with a whole line (latin-1, one character per byte)."""
        text = data.decode("latin-1")
        self.assertTrue(text == "" or text.endswith("\n"), "the output ends with a whole line")
        return text.split("\n")[:-1] if text else []

    def check_rows(self, lines, count):
        self.assertEqual(len(lines), count)
        for n, line in enumerate(lines):
            if line != "row %d %s" % (n, FILLER):
                self.fail("row %d is not whole or not in order" % n)

    def check_alternating(self, lines):
        self.assertEqual(len(lines), 300)
        for k, line in enumerate(lines):
            if line != "%s%d %s" % ("o" if k % 2 == 0 else "e", k // 2, FILLER):
                self.fail("line %d is not in the order of the calls" % k)

    def test_a_pipe_nobody_reads_does_not_stop_a_timer_task_and_the_run_ends_once_the_reader_drains(self):
        summary, out, err = self.run_case("ticker", TICKER_PROGRAM % 400,
                                          peer=["--delay", "1.0", "--chunk", "16384", "--pause", "0.001"])
        self.assertEqual(summary["status"], 0)
        self.assertGreaterEqual(summary["ticks_before_read"], 5, "the ticker ran while stdout was stuck")
        self.check_rows(self.lines_of(out), 400)
        self.assertEqual(err.count("tick"), 40)

    def test_two_tasks_printing_long_lines_into_a_slow_pipe_never_interleave_and_each_keeps_its_order(self):
        summary, out, _ = self.run_case("writers", TWO_WRITERS_PROGRAM,
                                        peer=["--delay", "0.3", "--chunk", "16384", "--pause", "0.002"])
        self.assertEqual(summary["status"], 0)
        lines = self.lines_of(out)
        self.assertEqual(len(lines), 80)
        following = {"A": 0, "B": 0}
        for line in lines:
            m = re.fullmatch(r"([AB])([0-9]+) x{8192}", line)
            if not m:
                self.fail("a line is not whole")
            self.assertEqual(int(m.group(2)), following[m.group(1)], "the order of one task")
            following[m.group(1)] += 1

    def test_a_print_longer_than_the_buffer_holds_the_stream_until_it_is_all_copied(self):
        summary, out, _ = self.run_case("long", LONG_PRINT_PROGRAM,
                                        peer=["--delay", "0.3", "--chunk", "16384", "--pause", "0.002"])
        self.assertEqual(summary["status"], 0)
        lines = self.lines_of(out)
        self.assertEqual(len(lines), 202)
        big = "z" * 262144
        self.assertEqual(len([line for line in lines if line == big]), 2)
        self.assertEqual([line for line in lines if line != big], ["short-%d" % n for n in range(200)])

    def test_the_end_of_the_run_drains_standard_output_within_the_flush_limit(self):
        summary, out, err = self.run_case("drain", ROWS_PROGRAM % 100, peer=["--delay", "1.0"], vm=["--json"])
        self.assertEqual(summary["status"], 0)
        self.assertGreaterEqual(summary["exit"], summary["read_start"], "the run waited for the reader")
        self.check_rows(self.lines_of(out), 100)
        self.assertEqual(err, "")

    def test_a_reader_that_never_reads_ends_the_run_after_the_flush_timeout_with_the_warning(self):
        summary, out, err = self.run_case("stuck", ROWS_PROGRAM % 100, peer=["--read-after-exit"],
                                          vm=["--json", "--flush-timeout", "500"])
        self.assertEqual(summary["status"], 0)
        self.assertTrue(0.4 <= summary["exit"] <= 20, "the run waits for the flush limit")
        self.assertIn('"flush_timeout_ms":500', err)
        self.assertTrue(0 < len(out) < row_total(100), "the data that fits the pipe arrives")

    def test_a_stuck_stderr_that_is_the_stdout_pipe_drops_the_warning_and_keeps_the_exit_code(self):
        summary, out, _ = self.run_case("merged", ROWS_PROGRAM % 100, peer=["--read-after-exit", "--merge"],
                                        vm=["--json", "--flush-timeout", "500"])
        self.assertEqual(summary["status"], 0)
        self.assertTrue(0.4 <= summary["exit"] <= 20, "the run waits for the flush limit")
        self.assertTrue(0 < len(out) < row_total(100))
        self.assertNotIn(b"flush_timeout_ms", out, "the warning is dropped, not mixed into the data")

    def test_a_socket_as_stdout_is_written_on_the_loop(self):
        summary, out, _ = self.run_case("socket", TICKER_PROGRAM % 800, peer=["--socket", "--delay", "1.0"])
        self.assertEqual(summary["status"], 0)
        self.assertGreaterEqual(summary["ticks_before_read"], 5, "the ticker ran while stdout was stuck")
        self.check_rows(self.lines_of(out), 800)

    def test_stdout_and_stderr_on_one_pipe_keep_the_order_of_the_calls_under_a_slow_reader(self):
        summary, out, _ = self.run_case("alternate", ALTERNATE_PROGRAM,
                                        peer=["--delay", "0.5", "--merge", "--chunk", "16384", "--pause", "0.001"])
        self.assertEqual(summary["status"], 0)
        self.check_alternating(self.lines_of(out))

    def test_stdout_and_stderr_on_one_terminal_keep_the_order_of_the_calls_under_a_slow_reader(self):
        summary, out, _ = self.run_case("terminal", ALTERNATE_PROGRAM,
                                        peer=["--delay", "0.5", "--pty", "--chunk", "1024", "--pause", "0.0005"])
        self.assertEqual(summary["status"], 0)
        self.check_alternating(self.lines_of(out.replace(b"\r", b"")))

    def test_io_flush_returns_once_a_slow_reader_has_taken_the_data(self):
        summary, out, err = self.run_case("flush", FLUSH_PROGRAM, peer=["--delay", "1.0"])
        self.assertEqual(summary["status"], 0)
        self.check_rows(self.lines_of(out), 100)
        self.assertEqual(err, "flushed\n")
        self.assertGreaterEqual(summary["first_error_at"], summary["read_start"], "flush waited for the reader")

    def test_a_crash_notice_waits_for_a_stderr_that_is_full_and_then_arrives_whole(self):
        summary, _, err = self.run_case("crash-notice", CRASH_WHILE_STUCK_PROGRAM, peer=["--error-delay", "1.0"],
                                        vm=["--json"])
        self.assertEqual(summary["status"], 1)
        self.assertGreaterEqual(summary["first_error_at"], 0.9, "stderr was stuck while the task crashed")
        lines = err.split("\n")
        crash = [line for line in lines if line.startswith('{"code":"RUNTIME-DIVISION-BY-ZERO"')]
        self.assertEqual(len(crash), 1)
        self.assertIs(json.loads(crash[0])["task"], True)
        self.assertEqual(len([line for line in lines if re.fullmatch(r"warn [0-9]+ w+", line)]), 200)

    def test_a_stderr_that_cannot_be_written_makes_the_exit_code_1(self):
        status, _, out, _ = self.run_to_file("full-stderr", WARN_LAST_PROGRAM, stderr_file="/dev/full")
        self.assertEqual(status, 1)
        self.assertEqual(out, "done\n")

    def test_a_long_diagnostic_reaches_a_slow_stderr_pipe_whole(self):
        summary, _, err = self.run_case("slow-diagnostic", BIG_UNWRAP_PROGRAM % 17, peer=["--error-delay", "1.0"],
                                        vm=["--json"])
        self.assertEqual(summary["status"], 1)
        self.assertIn("RUNTIME-UNWRAP-ERROR", err)
        self.assertGreater(len(err), 262144, "the whole text arrives")

    def test_a_print_cut_by_the_end_of_the_run_does_not_hold_a_queued_notice_or_the_exit(self):
        summary, out, _ = self.run_case("stuck-print", STUCK_PRINT_PROGRAM, peer=["--delay", "1.0", "--merge"],
                                        vm=["--json", "--flush-timeout", "6000"])
        self.assertEqual(summary["status"], 1)
        self.assertLess(summary["exit"], 4, "the run does not wait for the flush limit")
        self.assertNotIn(b"flush_timeout_ms", out)
        self.assertIn(b"RUNTIME-DIVISION-BY-ZERO", out)

    def test_blocking_stdout_and_stderr_on_one_pipe_the_program_output_comes_before_the_diagnostic(self):
        summary, out, _ = self.run_case("blocking-order", OUTPUT_THEN_CRASH_PROGRAM, peer=["--merge"],
                                        vm=["--json"], env={"AGENTICA_VM_TEST_BLOCKING_OUTPUT": "1"})
        self.assertEqual(summary["status"], 1)
        self.assertRegex(out, rb"\Abefore\npartial[^\n]*RUNTIME-DIVISION-BY-ZERO")

    def test_file_calls_on_dev_stdout_and_dev_stderr_still_work_when_they_are_pipes(self):
        summary, out, err = self.run_case("dev-stdout", DEV_STDOUT_PROGRAM)
        self.assertEqual(summary["status"], 0)
        self.assertEqual(out, b"via file\nnormal\n")
        self.assertEqual(err, "via stderr\nafter\n")

    def test_a_long_error_text_reaches_a_stderr_file_whole(self):
        status, _, out, err = self.run_to_file("big-error", BIG_UNWRAP_PROGRAM % 16, stderr_file=True)
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertIn("RUNTIME-UNWRAP-ERROR", err)
        self.assertGreater(len(err), 131072, "the whole text is written")

    def test_a_regular_file_written_by_the_pool_is_drained_while_a_child_is_stopped_at_the_end_of_the_run(self):
        status, elapsed, out, err = self.run_to_file("live-child", LIVE_CHILD_PROGRAM)
        self.assertEqual(status, 0)
        self.assertLess(elapsed, min(scaled(10), 25), "the run does not wait for the flush limit")
        self.assertEqual(err, "")
        self.assertRegex(out, re.compile(r"\Achild started\n.*\ndone\n\Z", re.S))

    def test_a_reader_that_goes_away_fails_the_print_not_the_vm(self):
        summary, _, err = self.run_case("gone", ROWS_PROGRAM % 400, peer=["--close-after", "100000"], vm=["--json"])
        self.assertEqual(summary["status"], 1)
        self.assertIn('"code":"RUNTIME-INTERNAL"', err)

    def test_a_crashed_parent_cancels_a_child_waiting_to_print_and_nothing_partial_is_written(self):
        summary, out, err = self.run_case("crash", CRASHED_PARENT_PROGRAM, peer=["--delay", "1.0"], vm=["--json"])
        self.assertEqual(summary["status"], 1)
        self.assertIn('"code":"RUNTIME-DIVISION-BY-ZERO"', err)
        lines = self.lines_of(out)
        self.assertGreater(len(lines), 50, "the child filled the buffers before it was cancelled")
        for n, line in enumerate(lines):
            if line != "C%d %s" % (n, FILLER):
                self.fail("line %d is partial or out of order" % n)
