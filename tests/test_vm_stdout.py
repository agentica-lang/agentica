"""Standard output and standard error of the VM against slow, stuck and vanishing readers.

fixtures/stdout-peer.py starts the VM with its stdout and stderr on a pipe, a
socket, a pty or a merged pipe, reads them slowly (or never), and prints a
JSON summary: the exit status and when the reader started, the VM exited, and
the first error byte arrived. Programs that need no peer run with their
streams on files. The cases run on Linux, macOS and Windows; the few that need
a Unix descriptor kind (a pty, /dev/stdout) are marked "host-only:"
with the reason. On Windows the socket cases use a Winsock socket that is not in overlapped mode.
"""
import contextlib
import json
import re
import subprocess
import time

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, TARGET_OS, UNDER_WINE, agc_literal, compile_text, run, scaled,
                                 vm_command, vm_environment)

PEER = FIXTURES / "stdout-peer.py"
PEER_LIMIT = scaled(90)
FILLER = "x" * 1024
# Rows that fit the 64 KiB buffer of a stream, so the program ends while the pipe (4 KiB to 16 KiB once shrunk) is
# full and the end of the run has to wait for a reader that does not come. More rows would keep the program printing.
STUCK_ROWS = 58
WINDOWS = TARGET_OS == "windows"
pty_stdout = pytest.mark.skipif(
    WINDOWS, reason="host-only: needs a Unix pseudo terminal; test_windows_console_stop.py has the ConPTY cases")
dev_stdout = pytest.mark.skipif(
    WINDOWS, reason="host-only: /dev/stdout and /dev/stderr are Unix paths that Windows does not have")
not_wine = pytest.mark.skipif(UNDER_WINE, reason="Wine does not show that two descriptors are one pipe")
not_wine_child = pytest.mark.skipif(
    UNDER_WINE, reason="Wine runs the Windows binary, which starts neither /bin/sh nor a Linux Python")
# The cases that read a socket only after the VM exited check how Windows closes the socket with the process; Wine's
# sockets are another implementation, so they are not run there.
not_wine_socket = pytest.mark.skipif(UNDER_WINE, reason="Wine: the close of a socket at exit is not Windows' own")
# Rows that a socket holds whole once its buffers are SOCKET_BUFFER (Linux caps the size it gives, at 208 KiB by
# default), so the run ends with every row sent and none read yet.
SOCKET_ROWS = 100
SOCKET_BUFFER = 1 << 20


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

ERROR_ROWS_PROGRAM = ROWS_PROGRAM.replace("puts(", "IO.warn(")

# Reads one line of stdin, which the peer sent before the start, and then prints the rows.
GETS_ROWS_PROGRAM = ROWS_PROGRAM.replace("def main() -> Void\n", "def main() -> Void\n  IO.warn(IO.gets!())\n")

# A task waits for a line of stdin that never comes while main prints and returns.
STDIN_WAIT_PROGRAM = """\
def listen(k: Int) -> Void
  text = IO.gets!()
  puts("got #{text}")
end

def main() -> Void
  Task.spawn(&listen, 0)
  Task.sleep(200)
  n = 0
  while n < 3
    puts("row #{n}")
    n += 1
  end
end

"""

# A task that prints until the run ends: main returns while the stream is still full.
FLOOD_PROGRAM = """\
def flood(filler: String) -> Void
  n = 0
  while true
    puts("row #{n} #{filler}")
    n += 1
  end
end

def main() -> Void
  filler = "x"
  for i in 0..9
    filler = filler + filler
  end
  Task.spawn(&flood, filler)
  Task.sleep(500)
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

# A child that is still running when the program ends.
LIVE_CHILD = '"ping", ["-n", "30", "127.0.0.1"]' if WINDOWS else '"/bin/sh", ["-c", "cat"]'

LIVE_CHILD_PROGRAM = """\
def main() -> Void
  child = Result.unwrap!(Process.spawn(%s, 5000))
  puts("child started")
  IO.inspect(Process.read_line(child, 100))
  puts("done")
end

""" % LIVE_CHILD


def row_total(count):
    return sum(1 + len("row %d %s" % (n, FILLER)) for n in range(count))




def run_case(tmp_path, name, program, peer=(), vm=(), env=None):
    """Run the program through stdout-peer.py; returns (summary, stdout bytes, stderr text)."""
    bytecode = compile_text(program, name, tmp_path)
    out_file = bytecode.with_suffix(".out")
    err_file = bytecode.with_suffix(".err")
    result = run([PYTHON, PEER, "--stdout-file", out_file, "--stderr-file", err_file, *peer,
                  "--", *vm_command(), *vm, "--", bytecode],
                 timeout=PEER_LIMIT, env=vm_environment(env))
    assert result.code == 0, "%s: the peer ends: %s" % (name, result.stderr)
    return json.loads(result.stdout), out_file.read_bytes(), err_file.read_text(errors="replace")


def run_to_file(tmp_path, name, program, stderr_file=None):
    """Run the VM with stdout on a file. stderr_file: None captures it, True sends it to a file, a string is a path,
    an open file is the stream itself (see read_only_stderr).

    Returns (exit code, seconds, stdout text, stderr text).
    """
    bytecode = compile_text(program, name, tmp_path)
    out_file = bytecode.with_suffix(".out")
    err_file = bytecode.with_suffix(".err") if stderr_file is True else stderr_file
    start = time.monotonic()
    result = run([*vm_command(), "--flush-timeout", "20000", "--", bytecode], timeout=PEER_LIMIT,
                 env=vm_environment(), stdout_to=out_file, stderr_to=err_file)
    elapsed = time.monotonic() - start
    if stderr_file is None:
        errors = result.stderr
    else:
        errors = bytecode.with_suffix(".err").read_text(errors="replace") if stderr_file is True else ""
    return result.code, elapsed, out_file.read_text(errors="replace"), errors


@contextlib.contextmanager
def read_only_stderr(tmp_path):
    """A stderr on which every write fails, on every system: a file that was opened for reading only."""
    path = tmp_path / "read-only-stderr"
    path.write_bytes(b"")
    with open(path, "rb") as handle:
        yield handle


def lines_of(data):
    """The lines of a byte string, which must end with a whole line (latin-1, one character per byte)."""
    text = data.decode("latin-1")
    assert text == "" or text.endswith("\n"), "the output ends with a whole line"
    return text.split("\n")[:-1] if text else []


def check_rows(lines, count):
    assert len(lines) == count
    for n, line in enumerate(lines):
        if line != "row %d %s" % (n, FILLER):
            pytest.fail("row %d is not whole or not in order" % n)


def check_alternating(lines):
    assert len(lines) == 300
    for k, line in enumerate(lines):
        if line != "%s%d %s" % ("o" if k % 2 == 0 else "e", k // 2, FILLER):
            pytest.fail("line %d is not in the order of the calls" % k)


def test_a_pipe_nobody_reads_does_not_stop_a_timer_task_and_the_run_ends_once_the_reader_drains(tmp_path):
    summary, out, err = run_case(tmp_path, "ticker", TICKER_PROGRAM % 400,
                                 peer=["--delay", "2.0", "--chunk", "16384", "--pause", "0.001"])
    assert summary["status"] == 0
    assert summary["ticks_before_read"] >= 5, "the ticker ran while stdout was stuck"
    check_rows(lines_of(out), 400)
    assert err.count("tick") == 40


def test_two_tasks_printing_long_lines_into_a_slow_pipe_never_interleave_and_each_keeps_its_order(tmp_path):
    summary, out, _ = run_case(tmp_path, "writers", TWO_WRITERS_PROGRAM,
                               peer=["--delay", "0.3", "--chunk", "16384", "--pause", "0.002"])
    assert summary["status"] == 0
    lines = lines_of(out)
    assert len(lines) == 80
    following = {"A": 0, "B": 0}
    for line in lines:
        m = re.fullmatch(r"([AB])([0-9]+) x{8192}", line)
        if not m:
            pytest.fail("a line is not whole")
        assert int(m.group(2)) == following[m.group(1)], "the order of one task"
        following[m.group(1)] += 1


def test_a_print_longer_than_the_buffer_holds_the_stream_until_it_is_all_copied(tmp_path):
    summary, out, _ = run_case(tmp_path, "long", LONG_PRINT_PROGRAM,
                               peer=["--delay", "0.3", "--chunk", "16384", "--pause", "0.002"])
    assert summary["status"] == 0
    lines = lines_of(out)
    assert len(lines) == 202
    big = "z" * 262144
    assert len([line for line in lines if line == big]) == 2
    assert [line for line in lines if line != big] == ["short-%d" % n for n in range(200)]


def test_the_end_of_the_run_drains_standard_output_within_the_flush_limit(tmp_path):
    summary, out, err = run_case(tmp_path, "drain", ROWS_PROGRAM % 100, peer=["--delay", "1.0"], vm=["--json"])
    assert summary["status"] == 0
    assert summary["exit"] >= summary["read_start"], "the run waited for the reader"
    check_rows(lines_of(out), 100)
    assert err == ""


def test_a_reader_that_never_reads_ends_the_run_after_the_flush_timeout_with_the_warning(tmp_path):
    summary, out, err = run_case(tmp_path, "stuck", ROWS_PROGRAM % STUCK_ROWS,
                                 peer=["--read-after-exit", "--pipe-size", "4096"],
                                 vm=["--json", "--flush-timeout", "500"])
    assert summary["status"] == 0
    assert 0.4 <= summary["exit"] <= 20, "the run waits for the flush limit"
    assert '"flush_timeout_ms":500' in err
    assert 0 < len(out) < row_total(STUCK_ROWS), "the data that fits the pipe arrives"


@not_wine
def test_a_stuck_stderr_that_is_the_stdout_pipe_drops_the_warning_and_keeps_the_exit_code(tmp_path):
    summary, out, _ = run_case(tmp_path, "merged", ROWS_PROGRAM % STUCK_ROWS,
                               peer=["--read-after-exit", "--merge", "--pipe-size", "4096"],
                               vm=["--json", "--flush-timeout", "500"])
    assert summary["status"] == 0
    assert 0.4 <= summary["exit"] <= 20, "the run waits for the flush limit"
    assert 0 < len(out) < row_total(STUCK_ROWS)
    assert b"flush_timeout_ms" not in out, "the warning is dropped, not mixed into the data"


def test_a_socket_as_stdout_that_nobody_reads_yet_does_not_stop_a_timer_task(tmp_path):
    summary, out, _ = run_case(tmp_path, "socket", TICKER_PROGRAM % 800, peer=["--socket", "--delay", "2.0"])
    assert summary["status"] == 0
    assert summary["ticks_before_read"] >= 5, "the ticker ran while stdout was stuck"
    check_rows(lines_of(out), 800)


@not_wine_socket
def test_a_socket_as_stdout_read_only_after_the_exit_gets_every_row(tmp_path):
    summary, out, err = run_case(tmp_path, "socket_exit", ROWS_PROGRAM % SOCKET_ROWS,
                                 peer=["--socket", "--read-after-exit", "--pipe-size", str(SOCKET_BUFFER)])
    assert summary["status"] == 0
    assert summary["read_start"] >= summary["exit"], "the reader started after the exit"
    check_rows(lines_of(out), SOCKET_ROWS)
    assert err == ""


# Rows past a quarter of the socket's buffer come in a later turn: a Unix socket polls writable only while a quarter of
# its buffer is used, so the rows must be sent without waiting for that (they fit in the buffer).
LATE_ROWS_PROGRAM = ROWS_PROGRAM.replace("    n += 1\n  end\n", "    n += 1\n  end\n  Task.sleep(50)\n  while n < %d\n"
                                         "    puts(\"row #{n} #{filler}\")\n    n += 1\n  end\n")


@not_wine_socket
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_socket_as_stdout_read_only_after_the_exit_gets_the_rows_of_a_later_turn(tmp_path, schedulers):
    summary, out, err = run_case(tmp_path, "socket_exit_late", LATE_ROWS_PROGRAM % (110, 120),
                                 peer=["--socket", "--read-after-exit", "--pipe-size", str(SOCKET_BUFFER)],
                                 vm=["--schedulers", schedulers])
    assert summary["status"] == 0
    check_rows(lines_of(out), 120)
    assert err == ""


# A line of 128 KiB and one byte, longer than the 64 KiB ring, after some rows: it goes out in pieces through the FIFO of
# prints, and each piece must reach the socket without waiting for the poller's writable.
BIG_LINE_PROGRAM = ROWS_PROGRAM.replace("    n += 1\n  end\n", "    n += 1\n  end\n  big = \"y\"\n  for i in 0..16\n"
                                        "    big = big + big\n  end\n  puts(big)\n")


@not_wine_socket
@pytest.mark.parametrize("rows", [0, 110])
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_socket_as_stdout_read_only_after_the_exit_gets_a_line_longer_than_the_buffer(tmp_path, rows, schedulers):
    summary, out, err = run_case(tmp_path, "socket_exit_big", BIG_LINE_PROGRAM % rows,
                                 peer=["--socket", "--read-after-exit", "--pipe-size", str(SOCKET_BUFFER),
                                       "--limit", str(scaled(30))],
                                 vm=["--schedulers", schedulers])
    assert summary["status"] == 0
    lines = lines_of(out)
    check_rows(lines[:-1], rows)
    assert lines[-1] == "y" * (1 << 17)
    assert err == ""


@not_wine_socket
def test_a_socket_as_stderr_read_only_after_the_exit_gets_every_row(tmp_path):
    summary, out, err = run_case(tmp_path, "socket_exit_err", ERROR_ROWS_PROGRAM % SOCKET_ROWS,
                                 peer=["--error-socket", "--read-after-exit", "--pipe-size", str(SOCKET_BUFFER)])
    assert summary["status"] == 0
    check_rows(lines_of(err.encode("latin-1")), SOCKET_ROWS)
    assert summary["first_error_at"] >= summary["exit"], "the reader started after the exit"
    assert out == b""


@not_wine_socket
def test_a_socket_as_stdout_that_is_full_at_the_end_does_not_hold_the_exit_past_the_flush_limit(tmp_path):
    summary, _, err = run_case(tmp_path, "socket_full", FLOOD_PROGRAM,
                               peer=["--socket", "--read-after-exit", "--pipe-size", "4096"],
                               vm=["--json", "--flush-timeout", "500"])
    assert summary["status"] == 0
    assert 0.9 <= summary["exit"] <= 20, "the run waits for the flush limit, not for the reader"
    assert '"flush_timeout_ms":500' in err


@not_wine_socket
def test_stdout_and_stderr_on_one_socket_read_only_after_the_exit_get_every_row(tmp_path):
    summary, out, _ = run_case(tmp_path, "socket_exit_merged", ERROR_ROWS_PROGRAM % SOCKET_ROWS,
                               peer=["--socket", "--merge", "--read-after-exit", "--pipe-size", str(SOCKET_BUFFER)])
    assert summary["status"] == 0
    check_rows(lines_of(out), SOCKET_ROWS)


@not_wine_socket
def test_a_socket_as_stdin_and_stdout_read_only_after_the_exit_gets_every_row(tmp_path):
    summary, out, _ = run_case(tmp_path, "socket_exit_inetd", ROWS_PROGRAM % SOCKET_ROWS,
                               peer=["--socket", "--stdin-socket", "--read-after-exit", "--pipe-size",
                                     str(SOCKET_BUFFER)])
    assert summary["status"] == 0
    check_rows(lines_of(out), SOCKET_ROWS)


@not_wine_socket
def test_a_socket_as_stdin_and_stdout_that_was_read_gets_every_row_after_the_exit(tmp_path):
    summary, out, err = run_case(tmp_path, "socket_exit_inetd_read", GETS_ROWS_PROGRAM % SOCKET_ROWS,
                                 peer=["--socket", "--stdin-socket", "--stdin-line", "hello", "--read-after-exit",
                                       "--pipe-size", str(SOCKET_BUFFER)])
    assert summary["status"] == 0
    assert err == "hello\n"
    check_rows(lines_of(out), SOCKET_ROWS)


@not_wine_socket
def test_a_read_of_a_socket_stdin_in_flight_at_the_end_does_not_hold_the_exit(tmp_path):
    summary, out, _ = run_case(tmp_path, "socket_stdin_wait", STDIN_WAIT_PROGRAM,
                               peer=["--socket", "--stdin-socket", "--read-after-exit", "--pipe-size",
                                     str(SOCKET_BUFFER)],
                               vm=["--flush-timeout", "500"])
    assert summary["status"] == 0
    assert summary["exit"] <= 20, "the exit does not wait for the read"
    # On Windows the socket is not overlapped, so the writes of stdout wait behind the blocked read of stdin on it and
    # the rows are lost after the flush limit (docs/vm/10-io-scheduler.md).
    if not WINDOWS:
        assert lines_of(out) == ["row 0", "row 1", "row 2"]


@not_wine
def test_stdout_and_stderr_on_one_pipe_keep_the_order_of_the_calls_under_a_slow_reader(tmp_path):
    summary, out, _ = run_case(tmp_path, "alternate", ALTERNATE_PROGRAM,
                               peer=["--delay", "0.5", "--merge", "--chunk", "16384", "--pause", "0.001"])
    assert summary["status"] == 0
    check_alternating(lines_of(out))


@pty_stdout
def test_stdout_and_stderr_on_one_terminal_keep_the_order_of_the_calls_under_a_slow_reader(tmp_path):
    summary, out, _ = run_case(tmp_path, "terminal", ALTERNATE_PROGRAM,
                               peer=["--delay", "0.5", "--pty", "--chunk", "1024", "--pause", "0.0005"])
    assert summary["status"] == 0
    check_alternating(lines_of(out.replace(b"\r", b"")))


def test_io_flush_returns_once_a_slow_reader_has_taken_the_data(tmp_path):
    summary, out, err = run_case(tmp_path, "flush", FLUSH_PROGRAM, peer=["--delay", "1.0"])
    assert summary["status"] == 0
    check_rows(lines_of(out), 100)
    assert err == "flushed\n"
    assert summary["first_error_at"] >= summary["read_start"], "flush waited for the reader"


def test_a_crash_notice_waits_for_a_stderr_that_is_full_and_then_arrives_whole(tmp_path):
    summary, _, err = run_case(tmp_path, "crash-notice", CRASH_WHILE_STUCK_PROGRAM, peer=["--error-delay", "1.0"],
                               vm=["--json"])
    assert summary["status"] == 1
    assert summary["first_error_at"] >= 0.9, "stderr was stuck while the task crashed"
    lines = err.split("\n")
    crash = [line for line in lines if line.startswith('{"code":"RUNTIME-DIVISION-BY-ZERO"')]
    assert len(crash) == 1
    assert json.loads(crash[0])["task"] is True
    assert len([line for line in lines if re.fullmatch(r"warn [0-9]+ w+", line)]) == 200


def test_a_stderr_that_cannot_be_written_makes_the_exit_code_1(tmp_path):
    with read_only_stderr(tmp_path) as stderr:
        status, _, out, _ = run_to_file(tmp_path, "full-stderr", WARN_LAST_PROGRAM, stderr_file=stderr)
    assert status == 1
    assert out == "done\n"


# A child writes to its stderr, which the VM forwards to its own; LATE is what the program does once the child is done.
CHILD_STDERR_PROGRAM = """\
def main() -> Void
  %s
  child = Result.unwrap!(Process.spawn(%s, ["-c", "import sys; sys.stderr.buffer.write(b'e' * 200000)"], 60000))
  Process.wait(child, 60000)
  %s
end

"""


@not_wine_child
def test_a_stderr_that_only_a_child_wrote_to_and_cannot_be_written_keeps_the_exit_code_0(tmp_path):
    program = CHILD_STDERR_PROGRAM % ("", agc_literal(PYTHON), 'puts("done")')
    with read_only_stderr(tmp_path) as stderr:
        status, _, out, _ = run_to_file(tmp_path, "child-full-stderr", program, stderr_file=stderr)
    assert status == 0
    assert out == "done\n"


@not_wine
@not_wine_child
@pytest.mark.parametrize("late, status", [("", 0), ('IO.warn("late")', 1)])
def test_a_stderr_lost_after_the_program_wrote_to_it_fails_the_run_only_if_a_later_write_is_lost(tmp_path, late,
                                                                                               status):
    # stderr is the stdout pipe; its reader takes the program's line and goes away, so only the child's bytes fail.
    early = 'IO.warn("early")\n  Task.sleep(300)'
    program = CHILD_STDERR_PROGRAM % (early, agc_literal(PYTHON), late)
    summary, out, _ = run_case(tmp_path, "child-gone", program, peer=["--merge", "--close-after", "6"])
    assert out.startswith(b"early\n")
    assert summary["status"] == status


def test_a_long_diagnostic_reaches_a_slow_stderr_pipe_whole(tmp_path):
    summary, _, err = run_case(tmp_path, "slow-diagnostic", BIG_UNWRAP_PROGRAM % 17, peer=["--error-delay", "1.0"],
                               vm=["--json"])
    assert summary["status"] == 1
    assert "RUNTIME-UNWRAP-ERROR" in err
    assert len(err) > 262144, "the whole text arrives"


def test_a_print_cut_by_the_end_of_the_run_does_not_hold_a_queued_notice_or_the_exit(tmp_path):
    summary, out, _ = run_case(tmp_path, "stuck-print", STUCK_PRINT_PROGRAM, peer=["--delay", "1.0", "--merge"],
                               vm=["--json", "--flush-timeout", "6000"])
    assert summary["status"] == 1
    assert summary["exit"] < 4, "the run does not wait for the flush limit"
    assert b"flush_timeout_ms" not in out
    assert b"RUNTIME-DIVISION-BY-ZERO" in out


def test_blocking_stdout_and_stderr_on_one_pipe_the_program_output_comes_before_the_diagnostic(tmp_path):
    summary, out, _ = run_case(tmp_path, "blocking-order", OUTPUT_THEN_CRASH_PROGRAM, peer=["--merge"],
                               vm=["--json"], env={"AGENTICA_VM_TEST_BLOCKING_OUTPUT": "1"})
    assert summary["status"] == 1
    assert re.search(rb"\Abefore\npartial[^\n]*RUNTIME-DIVISION-BY-ZERO", out)


@dev_stdout
def test_file_calls_on_dev_stdout_and_dev_stderr_still_work_when_they_are_pipes(tmp_path):
    summary, out, err = run_case(tmp_path, "dev-stdout", DEV_STDOUT_PROGRAM)
    assert summary["status"] == 0
    assert out == b"via file\nnormal\n"
    assert err == "via stderr\nafter\n"


def test_a_long_error_text_reaches_a_stderr_file_whole(tmp_path):
    status, _, out, err = run_to_file(tmp_path, "big-error", BIG_UNWRAP_PROGRAM % 16, stderr_file=True)
    assert status == 1
    assert out == ""
    assert "RUNTIME-UNWRAP-ERROR" in err
    assert len(err) > 131072, "the whole text is written"


def test_a_regular_file_written_by_the_pool_is_drained_while_a_child_is_stopped_at_the_end_of_the_run(tmp_path):
    status, elapsed, out, err = run_to_file(tmp_path, "live-child", LIVE_CHILD_PROGRAM)
    assert status == 0
    assert elapsed < min(scaled(10), 25), "the run does not wait for the flush limit"
    assert err == ""
    assert re.search(re.compile(r"\Achild started\n.*\ndone\n\Z", re.S), out)


def test_a_reader_that_goes_away_fails_the_print_not_the_vm(tmp_path):
    summary, _, err = run_case(tmp_path, "gone", ROWS_PROGRAM % 400, peer=["--close-after", "100000"], vm=["--json"])
    assert summary["status"] == 1
    assert '"code":"RUNTIME-INTERNAL"' in err


def test_a_crashed_parent_cancels_a_child_waiting_to_print_and_nothing_partial_is_written(tmp_path):
    summary, out, err = run_case(tmp_path, "crash", CRASHED_PARENT_PROGRAM, peer=["--delay", "1.0"], vm=["--json"])
    assert summary["status"] == 1
    assert '"code":"RUNTIME-DIVISION-BY-ZERO"' in err
    lines = lines_of(out)
    assert len(lines) > 50, "the child filled the buffers before it was cancelled"
    for n, line in enumerate(lines):
        if line != "C%d %s" % (n, FILLER):
            pytest.fail("line %d is partial or out of order" % n)


# A plain child writes FORWARD_BYTES to its stderr, which the VM forwards to its own stderr, while another task waits
# 200 ms at a time and keeps the slowest wait: a Task.sleep of 100 ms (a scheduler's timer) and a Process.wait on the
# child that times out after 100 ms (a deadline on the I/O thread).
FORWARD_BYTES = 2 * 1024 * 1024
FORWARD_PROGRAM = """\
def ticker(child: Process) -> Int
  slowest = 0
  n = 0
  while n < 8
    start = Time.monotonic_ms()
    Task.sleep(100)
    Process.wait(child, 100)
    took = Time.monotonic_ms() - start
    if took > slowest
      slowest = took
    end
    n += 1
  end
  return slowest
end

def main() -> Void
  child = Result.unwrap!(Process.spawn(%s, ["-c", "import sys; sys.stderr.buffer.write(b'e' * %d)"], 60000))
  slowest = Task.await(Task.spawn(&ticker, child))
  puts("slowest #{slowest}")
  IO.inspect(Process.wait(child, 60000))
end

""" % (agc_literal(PYTHON), FORWARD_BYTES)


@not_wine_child
@pytest.mark.parametrize("schedulers", [1, 4])
def test_a_child_stderr_forwarded_to_a_stderr_nobody_reads_yet_does_not_stop_a_timer_task(tmp_path, schedulers):
    # The reader of the VM's stderr starts only after the ticker is done; the child's 2 MiB then all arrive.
    delay = scaled(3.0)
    vm = ["--schedulers", str(schedulers)]
    summary, out, err = run_case(tmp_path, "forward", FORWARD_PROGRAM, peer=["--error-delay", str(delay)], vm=vm)
    assert summary["status"] == 0
    lines = lines_of(out)
    assert lines[1] == "ok(0)"
    slowest = int(lines[0].split()[1])
    assert slowest < 200 + scaled(1000), "a wait of 200 ms took %d ms while stderr was stuck" % slowest
    assert err == "e" * FORWARD_BYTES


# A plain child keeps writing to its stderr, which is the stdout pipe of the VM, read slowly. Meanwhile the program
# warns once and prints how long the warn took; the warn joins the stream between two of the child's chunks.
STREAMING_BYTES = 8_000_000
STREAMING_WARN = "w" * 1000
STREAMING_PROGRAM = """\
def main() -> Void
  child = Result.unwrap!(Process.spawn(%s, ["-c", "import sys; sys.stderr.buffer.write(b'e' * %d)"], 60000))
  Task.sleep(300)
  start = Time.monotonic_ms()
  IO.warn("%s")
  puts("took #{Time.monotonic_ms() - start}")
  IO.inspect(Process.wait(child, 60000))
end

""" % (agc_literal(PYTHON), STREAMING_BYTES, STREAMING_WARN)


@not_wine
@not_wine_child
@pytest.mark.parametrize("schedulers", [1, 4])
def test_a_child_that_keeps_writing_stderr_does_not_hold_back_a_warn_of_the_program(tmp_path, schedulers):
    # The reader takes 8 KiB every 2 ms, so the child's bytes need about 2 s; the warn waits only for its room.
    vm = ["--schedulers", str(schedulers)]
    summary, out, _ = run_case(tmp_path, "streaming", STREAMING_PROGRAM, peer=["--merge", "--chunk", "8192",
                                                                             "--pause", "0.002"], vm=vm)
    assert summary["status"] == 0
    warn = out.find(STREAMING_WARN.encode() + b"\n")
    took = re.search(rb"took (\d+)\n", out)
    assert warn >= 0 and took and b"ok(0)\n" in out
    assert out.count(b"e") == STREAMING_BYTES
    assert int(took.group(1)) < scaled(1000), "the warn took %s ms" % took.group(1).decode()
    assert warn < STREAMING_BYTES // 2, "the warn came after %d bytes of the child" % warn


# A task warns records of exactly 64 KiB (the newline included), each one needing the whole ring, until main closes
# `stop`; a child sleeps 300 ms, then writes FULL_RING_CHILD bytes to its stderr. Both reach one pipe.
FULL_RING_CHILD = 300_000
FULL_RING_PROGRAM = """\
def printer(stop: Channel[Int]) -> Int
  big = List.repeat("w", 65535).join("")
  n = 0
  while !stop.closed?
    IO.warn(big)
    n += 1
  end
  return n
end

def main() -> Void
  stop: Channel[Int] = Channel.new(1)
  child = Result.unwrap!(Process.spawn(%s, ["-c", "import sys,time; time.sleep(0.3); sys.stderr.buffer.write(b'e' * %d)"], 60000))
  printer = Task.spawn(&printer, stop)
  start = Time.monotonic_ms()
  waited = Process.wait(child, %d)
  took = Time.monotonic_ms() - start
  stop.close
  Task.await(printer, 60000)
  puts("child #{waited.ok?} took #{took}")
end

"""


@not_wine_child
@pytest.mark.parametrize("schedulers", [1, 4])
def test_a_child_moves_on_while_the_program_keeps_warning_records_that_fill_the_whole_ring(tmp_path, schedulers):
    # The reader counts what it gets instead of keeping it: the printer writes as fast as the pipe is read.
    limit = scaled(10000)
    program = FULL_RING_PROGRAM % (agc_literal(PYTHON), FULL_RING_CHILD, limit)
    bytecode = compile_text(program, "full-ring", tmp_path)
    process = subprocess.Popen([*vm_command(), "--schedulers", str(schedulers), "--", bytecode],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=vm_environment())
    children = 0
    tail = b""
    found = None
    try:
        while chunk := process.stdout.read1(1 << 16):
            children += chunk.count(b"e")
            # The last line of main may come before child bytes that were still queued: it is looked for anywhere.
            window = tail + chunk
            found = found or re.search(rb"child (\w+) took (\d+)\n", window)
            tail = window[-64:]
        code = process.wait(timeout=PEER_LIMIT)
    finally:
        process.kill()
        process.stdout.close()
    assert code == 0 and found
    assert found.group(1) == b"true", "the child was still blocked after %s ms" % found.group(2).decode()
    assert int(found.group(2)) < scaled(5000), "the child took %s ms" % found.group(2).decode()
    assert children - found.group(0).count(b"e") == FULL_RING_CHILD


@not_wine
@not_wine_child
def test_a_reader_that_leaves_once_only_child_bytes_are_pending_keeps_the_exit_code_0(tmp_path):
    # The warn is written while the child streams; the reader leaves later, at 3 MB, so only the child's bytes are lost.
    program = STREAMING_PROGRAM.replace('  puts("took #{Time.monotonic_ms() - start}")\n', "").replace(
        "IO.inspect(Process.wait(child, 60000))", "Process.wait(child, 60000)")
    summary, out, _ = run_case(tmp_path, "streaming-gone", program, peer=["--merge", "--chunk", "8192", "--pause",
                                                                          "0.002", "--close-after", "3000000"])
    assert STREAMING_WARN.encode() + b"\n" in out
    assert summary["status"] == 0
