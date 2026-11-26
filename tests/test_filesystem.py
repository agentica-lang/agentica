"""File, Dir, Path and System.env programs on the VM.

Most cases run a checked Agentica program through the CLI, like the original
test did in process, against temp directories. The FIFO cases run the VM
binary directly with a one-thread pool and a 10 s bound; fixtures/fifo-peer.py
and fixtures/stop-peer.py play the other side of a FIFO or of a pipe, and
fixtures/os-peer.py gives Python's answers for Path.real and System.env.

Windows has no FIFO file, and the VM does not stream a pipe as a file there (it refuses one, and no path it accepts names
a pipe), so the FIFO cases are host-only on Windows. The flush limit is the exception: it runs there on a standard
output that nobody reads. test_windows_handle_counts.py checks the refusal of a named pipe and its released handle.
"""
import errno
import json
import os
import re
import shutil
import sys
import threading
import time

import pytest

from tests.agentica_test import (FIFO_FILE_REASON, FIXTURES, PYTHON, ROOT, UNDER_WINE, WINDOWS, Child, cli, compile_agc,
                                 host_only, output_lines, run, scaled, vm_command, vm_environment)
from tests.test_vm_stdout import ROWS_PROGRAM, STUCK_ROWS
from tests.vm_os_support import symlink
from tests.windows_support import long_paths_enabled

EXAMPLES = ROOT / "examples"
STOP_PEER = FIXTURES / "stop-peer.py"
FIFO_PEER = FIXTURES / "fifo-peer.py"
OS_PEER = FIXTURES / "os-peer.py"
VM_WAIT_SECONDS = scaled(10)
FD_ROOT = "/dev/fd" if sys.platform == "darwin" else "/proc/self/fd"

# Path.real or System.env of every argument after the mode, one line each.
OS_PROGRAM = r"""def line(r: Result[String]) -> String
  if r.ok?
    return "ok:" + Result.unwrap!(r)
  end
  return "error"
end

def main() -> Void
  args = System.args()
  for item in args.drop(1)
    if args[0] == "real"
      puts(line(Path.real(item)))
    else
      puts(line(System.env(item)))
    end
  end
end
"""


# Windows has named pipes where POSIX has FIFOs, but the VM does not open one as a file (probe() in vm/files.c refuses
# every file that is not regular, and path_string refuses the paths that name a pipe directly); it has no
# /dev/urandom and no /dev/stdin; its descriptors are not listed in a folder (test_windows_handle_counts.py lists its
# pipes and counts its handles instead).
no_fifo = host_only(WINDOWS, "a FIFO opened as a file that waits on the loop; " + FIFO_FILE_REASON)
no_urandom = host_only(WINDOWS, "/dev/urandom does not exist on Windows")
no_stdin_path = host_only(WINDOWS, "Windows has no path that names an inherited descriptor or the standard input (/proc/self/fd/N, /dev/stdin)")


def literal(text):
    """An Agentica string literal for a path or text (JSON escapes, which the lexer reads back for these inputs)."""
    return json.dumps(str(text), ensure_ascii=False)


def brief(lines):
    return [len(line) if len(line) > 200 else line for line in lines]


@pytest.fixture
def new_dir(tmp_path):
    """A fresh directory below tmp_path for each call (pytest removes the tree after the test)."""
    count = 0

    def make(prefix="agentica-filesystem-"):
        nonlocal count
        path = (tmp_path / ("%s%d" % (prefix, count))).resolve()
        count += 1
        path.mkdir()
        return path

    return make


@pytest.fixture
def run_program(new_dir):
    """Run an Agentica program through the CLI; asserts exit 0 and returns its stdout."""
    def run_text(text, args=(), cwd=None, env=None):
        directory = new_dir()
        source = directory / "program.agc"
        source.write_text(text.replace("@FD_ROOT@", FD_ROOT), encoding="utf-8")
        result = run(cli() + [source, *args], cwd=cwd, env=env or vm_environment())
        assert result.code == 0, result.stderr
        return result.stdout

    return run_text




@pytest.fixture
def run_vm_bounded(request):
    """Compile `text`, run the VM on it, and return (exit code, stdout, stderr).

    The VM must end within 10 s. `peer` runs it under fixtures/stop-peer.py in that mode;
    `keep_stdin` leaves stdin open until the VM has ended. stdout stays a pipe, which a reader thread drains,
    so the cases with one pool thread still cover a pipe on the loop.
    """
    def run_bounded(root, text, *arguments, peer=None, stdin_text=None, one_pool_thread=False, keep_stdin=False,
                    schedulers=None):
        source = root / "program.agc"
        source.write_text(text.replace("@FD_ROOT@", FD_ROOT), encoding="utf-8")
        bytecode = compile_agc(source, root / "program.agcb")
        command = [*vm_command(), "--", bytecode, *arguments]
        if peer:
            command = [PYTHON, STOP_PEER, peer, *command]
        extra = {"UV_THREADPOOL_SIZE": "1"} if one_pool_thread else {}
        if schedulers:
            extra["AGENTICA_SCHEDULERS"] = schedulers
        env = vm_environment(extra)
        child = Child(command, env=env, stdin=True, capture_stderr=True)
        request.addfinalizer(child.stop)
        if stdin_text:
            child.process.stdin.write(stdin_text.encode())
            child.process.stdin.flush()
        if not keep_stdin:
            child.close_stdin()
        try:
            code = child.wait(VM_WAIT_SECONDS)
        except AssertionError:
            child.stop()
            pytest.fail("the VM ends within %s s\nstderr: %s" % (VM_WAIT_SECONDS, child.stderr_text()))
        return code, child.stdout_text(), child.stderr_text()

    return run_bounded


@pytest.fixture
def os_lines(run_program):
    """The lines Agentica prints for Path.real (mode "real") or System.env (mode "env") of each item."""
    def lines(mode, items, cwd=None, env=None):
        stdout = run_program(OS_PROGRAM, [mode, *items], cwd=cwd, env=env)
        return output_lines(stdout)

    return lines


@pytest.fixture
def os_peer_lines():
    def lines(mode, items, cwd=None, env=None):
        result = run([PYTHON, "-I", OS_PEER, mode, *items], cwd=cwd, env=env or vm_environment())
        assert result.code == 0, result.stderr
        return output_lines(result.stdout)

    return lines


@pytest.fixture
def stuck_fifo(new_dir):
    """A temp dir with a FIFO that is full and has a reader that never reads; yields (root, fifo).

    A watchdog closes the reader after 20 s, so a flush that nothing bounds cannot hang the run for ever.
    The cleanups run like the original's: stop the timer, then close the reader, then remove the directory.
    """
    root = new_dir()
    fifo = root / "fifo"
    os.mkfifo(fifo)
    reader = [os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)]
    lock = threading.Lock()

    def close_reader():
        with lock:
            if reader:
                os.close(reader.pop())

    watchdog = threading.Timer(20, close_reader)
    watchdog.daemon = True
    watchdog.start()
    writer = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    try:
        while True:
            os.write(writer, b"a" * 4096)
    except OSError as problem:
        if problem.errno not in (errno.EAGAIN, errno.EPIPE):
            raise
    finally:
        os.close(writer)
    yield root, fifo
    watchdog.cancel()
    close_reader()


# The program of the flush limit on POSIX: the flush at the end of the run waits for a FIFO whose reader does not read.
STUCK_FIFO_PROGRAM = r"""def main() -> Void
  f = File.open(System.args()[0], "write", 1000).unwrap!
  File.write(f, "x", 1000).unwrap!
  IO.print("main done\n")
end
"""


@pytest.fixture
def stuck_flush(request, new_dir, adopt):
    """(start, done): start(*options, variable=None) runs a program with the options and the AGENTICA_FLUSH_TIMEOUT_MS
    `variable`, whose end must flush into a stream that a reader holds up, and returns (exit code, stdout, stderr).

    POSIX: the FIFO of stuck_fifo, which the program writes as a file; stdout is a text, `done`. Windows: the VM does not
    stream a pipe as a file, so the stream is the standard output of tests/test_vm_stdout.py's rows program (58 rows
    of 1 KiB fit the 64 KiB buffer of the stream, so the program ends while the 4 KiB pipe is full and the end of the
    run waits for a reader that does not come): a pipe that nobody reads; stdout is None, and so is `done`.
    """
    if not WINDOWS:
        root, fifo = request.getfixturevalue("stuck_fifo")
        source = root / "stuck.agc"
        source.write_text(STUCK_FIFO_PROGRAM, encoding="utf-8")

        def start_on_fifo(*options, variable=None):
            # Each run ends in well under a second when the limit works; 6 s fails a broken limit before the watchdog.
            result = run(cli() + [*options, source, fifo], timeout=scaled(6),
                         env=vm_environment({"AGENTICA_FLUSH_TIMEOUT_MS": variable}))
            return result.code, result.stdout, result.stderr

        return start_on_fifo, "main done\n"
    if UNDER_WINE:
        pytest.skip("Wine gives the pipe 64 KiB, so the rows fit it and nothing is stuck")
    source = new_dir() / "stuck.agc"
    source.write_text(ROWS_PROGRAM % STUCK_ROWS, encoding="utf-8")

    def start_on_stdout(*options, variable=None):
        env = vm_environment({"AGENTICA_FLUSH_TIMEOUT_MS": variable})
        child = adopt(Child(cli() + [*options, source], env=env, capture_stderr=True, read_stdout=False))
        code = child.wait(scaled(6))
        return code, None, child.stderr_text()

    return start_on_stdout, None


@no_urandom
def test_urandom_reads_bytes_directly_and_through_a_symlink(new_dir, run_program):
    alias = new_dir() / "entropy"
    os.symlink("/dev/urandom", alias)
    output = run_program("""def main() -> Void
  for path in System.args()
    file = File.open(path, "read", 1000).unwrap!
    bytes = File.read_bytes(file, 16, 1000).unwrap!
    IO.inspect(bytes.size)
    IO.inspect(File.close(file, 1000))
  end
end
""", args=["/dev/urandom", str(alias)])
    assert output == "16\nok()\n16\nok()\n"


def test_the_filesystem_calls_leave_out_the_timeout_and_file_open_the_mode(new_dir, run_program):
    root = new_dir()
    output = run_program("""def main() -> Void
  root = System.args()[0]
  path = root + "/a.txt"
  IO.inspect(File.write_text(path, "hi"))
  IO.inspect(File.append_text(path, "!"))
  IO.inspect(File.read_text(path))
  IO.inspect(File.stat(path).unwrap!.size_bytes)
  file = File.open(path).unwrap!
  IO.inspect(File.read_line(file))
  IO.inspect(File.write(file, "x").ok?)
  IO.inspect(File.close(file))
  _ = File.each_line(path) do |line|
    IO.inspect(line)
    ok()
  end
  IO.inspect(File.foreach(path).write_lines(root + "/c.txt"))
  IO.inspect(File.read_text(root + "/c.txt"))
  IO.inspect(Dir.list(root))
  IO.inspect(Path.rename(path, root + "/b.txt"))
  IO.inspect(Path.remove(root + "/b.txt"))
end
""", args=[str(root)])
    assert output == 'ok()\nok()\nok("hi!")\n3\nok("hi!")\nfalse\nok()\n"hi!"\nok()\nok("hi!\\n")\nok(["a.txt", "c.txt"])\nok()\nok()\n'


def test_the_run_waits_for_the_close_of_a_crashed_tasks_file_so_its_buffered_write_reaches_the_disk(new_dir, run_program):
    path = new_dir() / "crash.txt"
    output = run_program(r"""def writer(path: String) -> Result[Int]
  f = try File.open(path, "write", 1000)
  try File.write(f, "hello world\n", 1000)
  n = 0
  return ok(1 / n)
end

def main() -> Void
  t = Task.spawn(&writer, System.args()[0])
  puts(Task.await(t).ok?)
end
""", [path])
    assert output == "false\n"
    assert path.read_text() == "hello world\n"


def test_the_run_waits_for_a_timed_out_close_so_its_buffered_write_reaches_the_disk(new_dir, run_program):
    # One pool thread, held by the digest of a large sparse file: the close queues behind it, so its 1 ms deadline
    # passes before its work runs, and main ends at once. Nothing is printed, so no output flush holds the exit.
    root = new_dir()
    path = root / "kept.bin"
    big = root / "big.bin"
    with open(big, "wb") as handle:
        handle.truncate(256 << 20)
    run_program(r"""def digest(path: String) -> Bool
  return File.sha256(path, 60000).ok?
end

def main() -> Void
  out = File.open(System.args()[0], "create_private", 1000).unwrap!
  _ = File.write_bytes(out, "0123456789".bytes, 1000)
  Task.spawn(&digest, System.args()[1])
  Task.sleep(100)
  _ = File.close(out, 1)
end
""", [path, big], env=vm_environment({"UV_THREADPOOL_SIZE": "1"}))
    assert path.read_bytes() == b"0123456789"


def test_flush_timeout_and_agentica_flush_timeout_ms_need_a_non_negative_integer():
    hello = EXAMPLES / "hello.agc"

    def code_of(*arguments, variable=None):
        env = vm_environment({"AGENTICA_FLUSH_TIMEOUT_MS": variable})
        return run(cli() + [*arguments, hello], env=env)

    assert code_of("--flush-timeout", "-1").code == 2
    assert code_of("--flush-timeout", "soon").code == 2
    assert code_of("--flush-timeout", "86400001").code == 2
    assert code_of("--flush-timeout", "0").code == 0
    for bad in ("soon", "-1", "", "86400001"):
        result = code_of(variable=bad)
        assert result.code == 2, bad
        assert "AGENTICA_FLUSH_TIMEOUT_MS" in result.stderr
    assert code_of(variable="0").code == 0


def test_the_flush_limit_comes_from_the_flag_then_the_variable_and_ends_a_stuck_flush(stuck_flush):
    start, done = stuck_flush
    began = time.monotonic()
    by_flag = start("--json", "--flush-timeout", "200")
    by_variable = start("--json", variable="300")
    flag_wins = start("--json", "--flush-timeout", "250", variable="60000")
    elapsed = time.monotonic() - began
    assert elapsed < scaled(20)
    if WINDOWS:
        assert elapsed >= 0.8 * (0.2 + 0.3 + 0.25), "each run waits for its limit"
    for (code, stdout, errors), expected in zip((by_flag, by_variable, flag_wins), (200, 300, 250)):
        assert (code, stdout) == (0, done), errors
        assert json.loads(errors)["flush_timeout_ms"] == expected


@no_fifo
def test_an_await_does_not_wait_for_a_flush_that_a_fifo_reader_holds_up(stuck_fifo):
    root, fifo = stuck_fifo
    source = root / "awaited.agc"
    source.write_text(r"""def write_one(path: String) -> Result[Void]
  f = File.open(path, "write", 1000).unwrap!
  return File.write(f, "x", 1000)
end

def main() -> Void
  IO.inspect(Task.await(Task.spawn(&write_one, System.args()[0])))
  IO.print("awaited\n")
end
""", encoding="utf-8")
    began = time.monotonic()
    result = run(cli() + ["--flush-timeout", "200", source, fifo], timeout=scaled(10), env=vm_environment())
    assert time.monotonic() - began < scaled(10)
    assert (result.code, result.stdout) == (0, "ok()\nawaited\n"), result.stderr


@no_fifo
def test_fifo_calls_wait_on_the_loop_timed_out_reads_and_parked_tasks_hold_no_pool_thread_at_exit(new_dir, run_vm_bounded):
    root = new_dir()
    fifo = root / "fifo"
    out = root / "out.txt"
    os.mkfifo(fifo)
    code, output, errors = run_vm_bounded(root, r"""def stuck(path: String) -> Result[String]
  return File.read_text(path, 60000)
end

def main() -> Void
  fifo = System.args()[0]
  reader = File.open(fifo, "read", 1000).unwrap!
  _writer = File.open(fifo, "append", 1000).unwrap!
  out = File.open(System.args()[1], "write", 1000).unwrap!
  File.write(out, "flushed", 1000).unwrap!
  IO.inspect(File.read_line(reader, 100))
  IO.inspect(File.read_text(fifo, 100))
  for _ in [1, 2, 3, 4]
    Task.spawn(&stuck, fifo)
  end
  Task.sleep(50)
  IO.print("main done\n")
end
""", fifo, out, one_pool_thread=True)
    assert (code, output) == (0, 'error("filesystem: operation timed out", kind: "io.timeout")\n'
                                  'error("filesystem: operation timed out", kind: "io.timeout", details: {"path": %s})\n'
                                  'main done\n' % json.dumps(str(fifo))), errors
    assert out.read_text() == "flushed"


@no_fifo
def test_fifos_stream_on_the_loop_read_line_waits_for_a_writer_task_read_text_reads_to_eof(new_dir, run_vm_bounded):
    root = new_dir()
    first, second = root / "first", root / "second"
    os.mkfifo(first)
    os.mkfifo(second)
    code, output, errors = run_vm_bounded(root, r"""struct Pair
  first: File.Handle
  second: File.Handle
end

def feed(p: Pair) -> Result[Void]
  Task.sleep(100)
  try File.write(p.first, "hello\n", 5000)
  try File.close(p.first, 5000)
  big = "line\n"
  for _ in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    big = big + big
  end
  try File.write(p.second, big, 5000)
  return File.close(p.second, 5000)
end

def main() -> Void
  a = System.args()[0]
  b = System.args()[1]
  r = File.open(a, "read", 1000).unwrap!
  w = File.open(a, "append", 1000).unwrap!
  _holder = File.open(b, "read", 1000).unwrap!
  w2 = File.open(b, "append", 1000).unwrap!
  t = Task.spawn(&feed, Pair(first: w, second: w2))
  IO.inspect(File.read_line(r, 5000))
  IO.inspect(File.read_line(r, 5000))
  text = File.read_text(b, 5000).unwrap!
  IO.inspect(Task.await(t))
  IO.inspect(String.length(text))
end
""", first, second, one_pool_thread=True)
    assert (code, output) == (0, 'ok("hello")\nerror("filesystem: end of file", kind: "io.eof")\nok()\n81920\n'), errors


@no_fifo
@pytest.mark.parametrize("mode", ("slow", "close"))
def test_a_fifo_write_waits_on_the_loop_for_a_slow_reader_and_a_reader_that_leaves_gives_epipe(new_dir, adopt,
                                                                                              run_vm_bounded, mode):
    root = new_dir()
    fifo = root / "fifo"
    peer = adopt(Child([PYTHON, FIFO_PEER, fifo, mode, "65536"]))
    assert peer.next_line(VM_WAIT_SECONDS) == "ready", mode
    code, output, errors = run_vm_bounded(root, r"""def main() -> Void
  big = "0123456789"
  for _ in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    big = big + big
  end
  IO.inspect(File.write_text(System.args()[0], big, 10000))
end
""", fifo, one_pool_thread=True)
    try:
        got = peer.next_line(VM_WAIT_SECONDS)
    except AssertionError:
        got = None
    assert code == 0, mode + "\n" + errors
    if mode == "slow":
        assert output == "ok()\n", errors
        assert got == "327680"
    else:
        assert re.search(r'^error\("filesystem: cannot write the file.*Broken pipe', output, re.S)


@no_fifo
def test_a_crash_cancels_a_task_parked_on_a_fifo_read_and_frees_its_descriptor(new_dir, run_vm_bounded):
    root = new_dir()
    fifo = root / "fifo"
    path = root / "plain.txt"
    os.mkfifo(fifo)
    code, output, errors = run_vm_bounded(root, r"""def reader(path: String) -> Result[String]
  text = File.read_text(path, 60000)
  puts("the read returned")
  return text
end

def parent(path: String) -> Int
  Task.spawn(&reader, path)
  Task.sleep(300)
  zero = String.length("")
  return 1 / zero
end

def count() -> Int
  return Dir.list("@FD_ROOT@", 1000).unwrap!.length
end

def main() -> Void
  fifo = System.args()[0]
  _keep = File.open(fifo, "read", 1000).unwrap!
  _holder = File.open(fifo, "append", 1000).unwrap!
  before = count()
  Task.spawn(&parent, fifo)
  Task.sleep(150)
  IO.inspect(count() - before)
  Task.sleep(450)
  IO.inspect(count() - before)
  IO.inspect(File.write_text(System.args()[1], "x", 1000))
end
""", fifo, path, one_pool_thread=True)
    assert code == 1, errors
    assert output == "1\n0\nok()\n", "the read parks with one descriptor, and the cancel closes it"


def test_stdin_waits_on_the_loop_so_file_calls_run_while_a_task_waits_for_input(new_dir, run_vm_bounded):
    root = new_dir()
    path = root / "plain.txt"
    code, output, errors = run_vm_bounded(root, r"""def reader(n: Int) -> Int
  IO.inspect(IO.gets())
  return n
end

def main() -> Void
  Task.spawn(&reader, 1)
  Task.sleep(50)
  IO.inspect(File.write_text(System.args()[0], "x", 1000))
  IO.inspect(File.read_text(System.args()[0], 1000))
end
""", path, one_pool_thread=True, keep_stdin=True)
    assert (code, output) == (0, 'ok()\nok("x")\n'), errors


def next_line_or_stderr(child):
    """The child's next stdout line; a failure carries what it wrote to stderr so far."""
    try:
        return child.next_line(VM_WAIT_SECONDS)
    except AssertionError as error:
        raise AssertionError("%s\nstderr: %s" % (error, child.stderr_text())) from None


# A reader task is cancelled while its read of stdin waits, with one pool thread: a file call still runs, the read
# stays in flight and its line goes to the next reader, and the EOF then reaches both of two waiting readers once.
# The reader warns "reading" in the turn that starts its read: a task cancelled before it runs never runs, so the
# warning shows the reader ran before the cancel (only a turn that ends between the warning and the read is not ruled
# out).
CANCELLED_READER = """\
def reader(n: Int) -> Int
  IO.warn("reading")
  IO.inspect(IO.gets())
  return n
end

def main() -> Void
  r = Task.spawn(&reader, 1)
  Task.sleep(50)
  Task.cancel(r)
  IO.inspect(File.write_text(System.args()[0], "x", 1000))
  IO.flush()
  IO.inspect(IO.gets())
  IO.flush()
  a = Task.spawn(&reader, 2)
  b = Task.spawn(&reader, 3)
  IO.inspect(Task.await(a) + Task.await(b))
end
"""


@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_cancelled_stdin_reader_leaves_its_read_to_the_next_reader_and_eof_reaches_every_waiter(
    tmp_path, adopt, schedulers
) -> None:
    source = tmp_path / "stdin.agc"
    source.write_text(CANCELLED_READER, encoding="utf-8")
    env = vm_environment({"UV_THREADPOOL_SIZE": "1", "AGENTICA_SCHEDULERS": schedulers})
    bytecode = compile_agc(source, tmp_path / "stdin.agcb")
    child = adopt(Child([*vm_command(), "--", bytecode, tmp_path / "out.txt"], cwd=tmp_path, env=env, stdin=True,
                        capture_stderr=True))
    assert child.next_stderr_line(VM_WAIT_SECONDS) == "reading"
    assert next_line_or_stderr(child) == "ok()"
    child.process.stdin.write(b"late\n")
    child.process.stdin.flush()
    assert next_line_or_stderr(child) == 'ok("late")'
    child.close_stdin()
    assert child.wait(VM_WAIT_SECONDS) == 0, child.stderr_text()
    lines = child.stdout_text().splitlines()
    assert lines == ['error("IO.gets reached the end of input", kind: "io.eof")'] * 2 + ["5"], lines


@host_only(WINDOWS, "the VM's pipes are reopened through the folder of its descriptors; Windows has none "
                    "(test_file_calls_cannot_name_the_vms_own_pipes_so_a_later_spawn_does_not_deadlock in "
                    "test_windows_handle_counts.py lists its pipes)")
def test_file_calls_cannot_reopen_the_vms_own_pipes_so_a_later_spawn_does_not_deadlock(new_dir, run_vm_bounded):
    root = new_dir()
    code, output, errors = run_vm_bounded(root, r"""def main() -> Void
  for name in Dir.list("@FD_ROOT@", 1000).unwrap!
    if name != "0" and name != "1" and name != "2"
      path = "@FD_ROOT@/" + name
      read = File.read_text(path, 100).ok?
      append = File.open(path, "append", 100).ok?
      out = Process.spawn("true", [], Process.Options(timeout_ms: 1000, out: path))
      err = Process.spawn("true", [], Process.Options(timeout_ms: 1000, err: path))
      IO.inspect([read, append, out.ok?, err.ok?])
      info = File.stat(path, 100)
      if info.ok? and info.unwrap!.kind == "fifo"
        IO.inspect(["pipe", out.message, err.message])
      end
    end
  end
  p = Process.spawn("true", [], Process.Options(timeout_ms: 1000)).unwrap!
  IO.inspect(Process.wait(p, 1000))
end
""", peer="clean", schedulers="1")
    # One scheduler: with more, the stdin poller is set up before the program starts and holds a reopened copy of the
    # inherited stdin pipe under another number, which stays reachable by design (a pipe the VM got at start).
    lines = output_lines(output)
    assert code == 0, errors
    assert lines[-1] == "ok(0)"
    # Process.spawn's out and err files take the same guards, so a child never gets one of the VM's pipes. On Linux each
    # pipe opens again by its /proc/self/fd path and the guard refuses it, as such, not merely as a failed open. On
    # macOS /dev/fd/N duplicates the descriptor instead and refuses an access mode the descriptor lacks with EACCES, so
    # a read end fails to open for writing before the guard runs; the write ends still reach the guard.
    pipes = [json.loads(line)[1:] for line in lines[:-1] if line.startswith('["pipe", ')]
    messages = [message for pair in pipes for message in pair]
    refusals = [m for m in messages if re.fullmatch(r"process: (out|err) does not refer to a regular file", m)]
    unopened = [m for m in messages if re.match(r"process: cannot open the (out|err) file\n.*errno=13$", m, re.S)]
    assert refusals and len(refusals) + (len(unopened) if sys.platform == "darwin" else 0) == len(messages), pipes
    assert list(dict.fromkeys(line for line in lines[:-1] if not line.startswith('["pipe", '))) == [
        "[false, false, false, false]"]


@no_stdin_path
def test_pipes_the_vm_got_at_start_stay_readable_an_inherited_descriptor_and_a_piped_stdin(new_dir, run_vm_bounded):
    root = new_dir()
    program = r"""def main() -> Void
  f = File.open(System.args()[0], "read", 1000).unwrap!
  IO.inspect(File.read_line(f, 1000))
end
"""
    code, output, errors = run_vm_bounded(root, program, peer="inherit")
    assert (code, output) == (0, 'ok("inherited")\n'), errors
    code, output, errors = run_vm_bounded(root, program, "/dev/stdin", stdin_text="piped\n")
    assert (code, output) == (0, 'ok("piped")\n'), errors


def test_file_summary_example_reads_a_command_line_path(run_program):
    input_path = EXAMPLES / "hello.agc"
    output = run_program((EXAMPLES / "file-summary.agc").read_text(encoding="utf-8"), [input_path])
    assert output == "%d\n" % len(input_path.read_text(encoding="utf-8"))


def test_file_streams_whole_text_helpers_directories_metadata_and_paths_work_together(new_dir, run_program):
    root = new_dir()
    directory = root / "nested" / "data"
    path = directory / "notes.txt"
    unnormalized = "%s/nested/../nested/data" % root
    output = run_program(r"""def main() -> Void
  made: Result[Void] = Dir.mkdir(%s, 1000)
  made_again: Result[Void] = Dir.mkdir(%s, 1000)
  opened: Result[File.Handle] = File.open(%s, "write", 1000)
  handle: File.Handle = Result.unwrap!(opened)
  wrote: Result[Void] = File.write(handle, "alpha\n", 1000)
  wrote_bytes: Result[Void] = File.write_bytes(handle, "beta".bytes, 1000)
  closed: Result[Void] = File.close(handle, 1000)
  closed_again: Result[Void] = File.close(handle, 1000)
  appended: Result[Void] = File.append_text(%s, "\nend", 1000)
  text: Result[String] = File.read_text(%s, 1000)
  info: Result[File.Info] = File.stat(%s, 1000)
  entries: Result[List[String]] = Dir.list(%s, 1000)
  joined: Result[String] = Path.join([%s, "notes.txt"])
  resolved: Result[String] = Path.resolve(%s)
  IO.inspect(Result.ok?(made) and Result.ok?(made_again) and Result.ok?(wrote) and Result.ok?(wrote_bytes) and Result.ok?(closed) and Result.ok?(closed_again) and Result.ok?(appended))
  IO.inspect(text)
  IO.inspect(info)
  IO.inspect(entries)
  IO.inspect(joined)
  IO.inspect(resolved)
end

""" % tuple(literal(item) for item in (directory, directory, path, path, path, path, unnormalized, directory,
                                         unnormalized)))
    assert "true\n" in output
    assert 'ok("alpha\\nbeta\\nend")' in output
    assert 'File.Info(kind: "file", size_bytes: 14' in output
    assert 'ok(["notes.txt"])' in output
    # The VM prints joined and resolved paths with "/" on every system.
    assert "ok(%s)" % literal(path.as_posix()) in output
    assert "ok(%s)" % literal(directory.as_posix()) in output


def test_invalid_modes_closed_handles_invalid_utf8_and_whole_file_bounds_return_errors(new_dir, run_program):
    root = new_dir()
    path = root / "bad.txt"
    large = root / "large.txt"
    large.write_bytes(b"x" * 1048577)
    output = run_program(r"""def main() -> Void
  invalid_mode: Result[File.Handle] = File.open(%s, "readwrite", 1000)
  opened: Result[File.Handle] = File.open(%s, "write", 1000)
  handle: File.Handle = Result.unwrap!(opened)
  _wrote: Result[Void] = File.write_bytes(handle, Bytes.from_list([255]).unwrap!, 1000)
  _closed: Result[Void] = File.close(handle, 1000)
  closed_read: Result[Bytes] = File.read_bytes(handle, 1, 1000)
  invalid_utf8: Result[String] = File.read_text(%s, 1000)
  oversized: Result[String] = File.read_text(%s, 1000)
  IO.inspect(invalid_mode)
  IO.inspect(closed_read)
  IO.inspect(invalid_utf8)
  IO.inspect(oversized)
end

""" % (literal(path), literal(path), literal(path), literal(large)))
    assert "error(" in output
    assert "file handle is closed" in output
    assert "UTF-8" in output
    assert "1048576" in output


def test_bounded_stream_reads_and_line_decoding_preserve_eof_semantics(new_dir, run_program):
    path = new_dir() / "lines.txt"
    path.write_bytes(b"one\r\ntwo\nlast")
    output = run_program(r"""def main() -> Void
  opened: Result[File.Handle] = File.open(%s, "read", 1000)
  handle: File.Handle = Result.unwrap!(opened)
  first: Result[String] = File.read_line(handle, 1000)
  second: Result[String] = File.read_line(handle, 1000)
  rest: Result[Bytes] = File.read_bytes(handle, 100, 1000)
  eof: Result[Bytes] = File.read_bytes(handle, 100, 1000)
  _closed: Result[Void] = File.close(handle, 1000)
  IO.inspect(first)
  IO.inspect(second)
  IO.inspect(rest)
  IO.inspect(eof)
end

""" % literal(path))
    assert 'ok("one")' in output
    assert 'ok("two")' in output
    assert "ok(<Bytes 4 6c617374>)" in output
    assert "ok(<Bytes 0>)" in output


def test_file_operations_follow_symlinks_to_regular_files(new_dir, run_program):
    root = new_dir()
    target = root / "target.txt"
    alias = root / "alias.txt"
    target.write_text("linked")
    os.symlink(target, alias)
    output = run_program(r"""def main() -> Void
  contents: Result[String] = File.read_text(%s, 1000)
  info: Result[File.Info] = File.stat(%s, 1000)
  IO.inspect(contents)
  IO.inspect(info)
end

""" % (literal(alias), literal(alias)))
    assert 'ok("linked")' in output
    assert 'File.Info(kind: "file", size_bytes: 6' in output


def test_empty_files_read_as_empty_text_and_relative_symlinks_resolve_from_the_link_directory(new_dir, run_program):
    root = new_dir()
    nested = root / "nested"
    empty = root / "empty.txt"
    target = nested / "target.txt"
    alias = nested / "alias.txt"
    nested.mkdir()
    empty.write_text("")
    target.write_text("linked")
    os.symlink("target.txt", alias)
    output = run_program(r"""def main() -> Void
  empty: Result[String] = File.read_text(%s, 1000)
  linked: Result[String] = File.read_text(%s, 1000)
  IO.inspect(empty)
  IO.inspect(linked)
end

""" % (literal(empty), literal(alias)))
    assert 'ok("")' in output
    assert 'ok("linked")' in output


# The kind of link comes from the disk, so the order of `links` matters: a target must exist before a link to it.
def symlink(target, path):
    """A link to `target`; Windows needs to know whether it points at a folder, and keeps the target as typed."""
    folder = os.path.isdir(os.path.join(os.path.dirname(path), target))
    if WINDOWS:
        target = target.replace("/", "\\")
    os.symlink(target, path, target_is_directory=folder)


def test_path_real_gives_what_pythons_os_path_realpath_gives_through_link_chains_loops_and_long_paths(new_dir, os_lines,
                                                                                                     os_peer_lines):
    root = new_dir()
    directory = str(root)
    (root / "real" / "dir").mkdir(parents=True)
    (root / "real" / "dir" / "file.txt").write_text("data")
    links = [("../real/dir/file.txt", "real", "rel"), ("../..", "real", "dir", "up"), ("real/dir", "link2"),
             ("link2", "link1"), ("loop2", "loop1"), ("loop1", "loop2"), ("nowhere", "dangling"), (".", "self"),
             ("/", "slash"), ("link1/file.txt", "file-link")]
    for target, *parts in links:
        symlink(target, root.joinpath(*parts))
    symlink(str(root / "real" / "dir"), root / "abs")

    def repeat(part: str) -> str:
        count = 1500
        if sys.platform == "darwin":
            count = max(1, (os.pathconf(root, "PC_PATH_MAX") - len(directory) - 32) // len(part))
        return part * count

    items = [".", "./", "..", "../", "real", "real/", "real/dir/file.txt", "real/dir/../dir/./file.txt",
             "real/rel", "real/dir/up", "real/dir/up/real", "link1", "link1/", "link1/file.txt", "link1/..",
             "link2/../rel", "abs", "abs/file.txt", "abs/../rel", "file-link", "loop1", "loop1/x", "dangling",
             "dangling/x", "self", "self/self/self/real", "slash", "slash/", "slash/.", "missing",
             "real/missing", "real/dir/file.txt/x",
             directory + "/link1/file.txt", directory + "/link1/../rel",
             "real" + repeat("/dir/.."), "real/dir" + repeat("/../dir")]
    seen = os_lines("real", items, cwd=root)
    peer = os_peer_lines("real", items, cwd=root)
    # Python answers with backslashes on Windows; the VM writes the slashes that a program types.
    assert seen == ([line.replace("\\", "/") for line in peer] if WINDOWS else peer)
    table = dict(zip(items, seen))
    real_root = table["."][3:]

    def ok_at(suffix):
        return "ok:" + real_root + suffix

    assert table["link1"] == ok_at("/real/dir")
    assert table["link1/file.txt"] == ok_at("/real/dir/file.txt")
    assert table["real/dir/up"] == ok_at("")
    if WINDOWS:
        # The system removes `..` from the typed text before it follows any link, so `link1/..` is the folder that
        # holds the link, not the parent of its target, and the root link answers the drive.
        assert table["link1/.."] == ok_at("")
        assert table["abs/../rel"] == "error"
        assert table["link2/../rel"] == "error"
        assert seen[items.index(directory + "/link1/../rel")] == "error"
        assert table["slash"] == "ok:" + real_root[:3]
    else:
        assert table["link1/.."] == ok_at("/real")
        assert table["abs/../rel"] == ok_at("/real/dir/file.txt")
        assert table["slash"] == "ok:/"
    assert table["loop1"] == "error"
    assert table["dangling"] == "error"
    assert table["real/dir/file.txt/x"] == "error"
    assert seen[len(items) - 2] == ok_at("/real")
    assert seen[-1] == ok_at("/real/dir")
    if sys.platform == "darwin":
        overlong = ["real" + "/dir/.." * 1500, "real/dir" + "/../dir" * 1500]
        assert os_lines("real", overlong, cwd=root) == ["error", "error"]


def test_path_real_resolves_a_deep_folder_longer_than_a_small_buffer_where_the_system_allows_one(new_dir, os_lines,
                                                                                                os_peer_lines):
    root = new_dir()
    if WINDOWS:
        # Python makes the folder with the \\?\ prefix. The VM, given the plain path, reaches it only when Windows
        # lifts the MAX_PATH limit (long_paths_enabled).
        prefix = "\\\\?\\"
        first = str(root / ("d" * 100))
        here = prefix + str(root)
        try:
            for _ in range(4):
                here = here + "\\" + "d" * 100
                os.mkdir(here)
            seen = os_lines("real", [here[4:], first])
            assert seen[0].startswith("ok:") == long_paths_enabled() and seen[1].startswith("ok:"), seen
        finally:
            shutil.rmtree(prefix + first, ignore_errors=True)
        return
    deep = root.joinpath(*["d" * 100] * 30)
    if sys.platform == "darwin":
        # PATH_MAX is 1024 there, so the folder cannot exist and the answer is the error of a missing path.
        with pytest.raises(OSError) as refused:
            os.makedirs(deep)
        assert refused.value.errno == errno.ENAMETOOLONG
        assert os_lines("real", [str(deep)]) == ["error"]
        return
    os.makedirs(deep)
    assert len(str(deep)) > 3000
    seen = os_lines("real", [str(deep), str(deep) + "/..", "d" * 100], cwd=deep.parent)
    assert seen[:2] == os_peer_lines("real", [str(deep), str(deep) + "/.."])
    assert seen[0].endswith("/" + "/".join(["d" * 100] * 30)) and seen[2] == seen[0]


def test_path_real_of_a_file_with_a_trailing_slash_is_an_error_except_on_macos_and_a_child_name_is_always_one(
        new_dir, os_lines):
    file = new_dir() / "file.txt"
    file.write_text("data")
    plain, slash, child = os_lines("real", [str(file), str(file) + "/", str(file) + "/x"])
    assert plain.startswith("ok:") and child == "error"
    if sys.platform == "darwin":
        # realpath of macOS accepts the slash after a file and answers the file.
        assert slash.rstrip("/") == plain
    else:
        assert slash == "error"


@host_only(WINDOWS, "the Windows environment is UTF-16, so it cannot hold bytes that are not UTF-8")
def test_system_env_gives_what_pythons_os_environ_gives_decoding_bytes_that_are_not_utf_8_with_u_fffd(os_lines,
                                                                                                      os_peer_lines):
    env = vm_environment()
    # Not vm_environment(extra): it turns values into str, so bytes would become "b'..'" and lose the non-UTF-8 cases.
    env.update({
        "AGC_PEER_SET": b"plain", "AGC_PEER_EMPTY": b"", "AGC_PEER_EQ": b"x=y=", "AGC_PEER_SPACE": b"  padded  ",
        "AGC_PEER_UNI": "h\u00e9llo \u2713 \u65e5\u672c".encode("utf-8"),
        "AGC_PEER_BAD": b"a\xffb", "AGC_PEER_BAD2": b"\xc3(", "AGC_PEER_BAD3": b"x\xe2\x82",
        "AGC_PEER_BAD4": b"\xe2\x82A", "AGC_PEER_LONG": b"v" * 100000})
    items = ["AGC_PEER_SET", "AGC_PEER_EMPTY", "AGC_PEER_EQ", "AGC_PEER_SPACE", "AGC_PEER_UNI", "AGC_PEER_BAD",
             "AGC_PEER_BAD2", "AGC_PEER_BAD3", "AGC_PEER_BAD4", "AGC_PEER_LONG", "AGC_PEER_UNSET", "agc_peer_set",
             "AGC_PEER", "AGC_PEER_SET_", "", "=", "AGC_PEER_SET=plain"]
    seen = os_lines("env", items, env=env)
    assert brief(seen) == brief(os_peer_lines("env", items, env=env))
    assert seen[:3] == ["ok:plain", "ok:", "ok:x=y="]
    assert seen[5] == "ok:a\ufffdb"
    # One U+FFFD for the cut sequence E2 82, as bytes.scrub gives.
    assert seen[8] == "ok:\ufffdA"
    assert seen[10:] == ["error"] * 7


def test_system_env_does_not_show_the_variables_the_vm_keeps_for_itself(os_lines):
    def seen(name, env):
        return os_lines("env", [name], env=env)[0]

    assert seen("UV_USE_IO_URING", vm_environment({"UV_USE_IO_URING": None})) == "error"
    assert seen("UV_USE_IO_URING", vm_environment({"UV_USE_IO_URING": "1"})) == "ok:1"
    assert seen("AGENTICA_CHANNEL", vm_environment({"AGENTICA_CHANNEL": "3"})) == "error"


def test_the_end_of_a_run_flushes_and_closes_an_unclosed_file_handle(new_dir, run_program):
    path = new_dir() / "cleanup.txt"
    run_program(r"""def main() -> Void
  opened: Result[File.Handle] = File.open(%s, "write", 1000)
  handle: File.Handle = Result.unwrap!(opened)
  _wrote: Result[Void] = File.write(handle, "cleanup", 1000)
end

""" % literal(path))
    assert path.read_text() == "cleanup"


REPLACE_PROGRAM = """def fill(letter: String) -> Bytes
  text = letter
  n = 0
  while n < 16
    text = text + text
    n += 1
  end

  return text.bytes
end

def main() -> Void
  args = System.args()
  IO.inspect(File.replace(args[0], "new".bytes))
  IO.inspect(File.replace(args[1], "still read-only".bytes))
  IO.inspect(File.replace(args[2], "x".bytes).ok?)
  IO.inspect(File.replace(args[3], "x".bytes).ok?)
  payloads = [fill("a"), fill("b"), fill("c"), fill("d")]
  i = 0
  while i < 200
    File.replace(args[4], payloads[i % 4]).unwrap!
    i += 1
  end
end
"""


@host_only(WINDOWS, "POSIX permission bits and symbolic links; Windows keeps only the read-only bit")
def test_file_replace_keeps_the_mode_writes_through_a_link_and_a_reader_never_sees_a_part_or_no_file(new_dir,
                                                                                                    run_program):
    root = new_dir()
    target, alias, locked, watched = root / "target.txt", root / "alias.txt", root / "locked.txt", root / "watched.txt"
    target.write_text("old")
    target.chmod(0o751)
    os.symlink("target.txt", alias)
    locked.write_text("read-only")
    locked.chmod(0o444)
    watched.write_bytes(b"z" * 65536)
    stop, seen = threading.Event(), []

    def read_while_replaced():
        # Every open must find the file whole: one letter, 64 KiB. A missing file or a short read is a broken swap.
        while not stop.is_set():
            try:
                data = watched.read_bytes()
            except FileNotFoundError:
                seen.append("missing")
                continue
            if len(data) != 65536 or len(set(data)) != 1:
                seen.append("part of %d bytes" % len(data))

    reader = threading.Thread(target=read_while_replaced)
    reader.start()
    try:
        output = run_program(REPLACE_PROGRAM, args=[alias, locked, root / "missing.txt", root, watched])
    finally:
        stop.set()
        reader.join()
    assert output == "ok()\nok()\nfalse\nfalse\n"
    assert seen == []
    assert os.readlink(alias) == "target.txt" and target.read_text() == "new"
    assert (target.stat().st_mode & 0o777, locked.stat().st_mode & 0o777) == (0o751, 0o444)
    assert locked.read_text() == "still read-only"
    assert sorted(path.name for path in root.iterdir()) == ["alias.txt", "locked.txt", "target.txt", "watched.txt"]
    if os.geteuid() == 0:
        return
    # A folder without write permission: an error that names the new file, the old file as it was, nothing left.
    sealed = new_dir()
    kept = sealed / "kept.txt"
    kept.write_text("kept")
    sealed.chmod(0o555)
    try:
        output = run_program("""def main() -> Void
  puts(File.replace(System.args()[0], "lost".bytes).message.include?(".agc-"))
end
""", args=[kept])
        assert output == "true\n"
        assert kept.read_text() == "kept" and [path.name for path in sealed.iterdir()] == ["kept.txt"]
    finally:
        sealed.chmod(0o755)


PATH_REPLACE_PROGRAM = r"""def show(r: Result[Void]) -> Void
  case r
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]}")
  end
end

def main() -> Void
  root = System.args()[0]
  show(Path.replace(root + "/new.txt", root + "/old.txt"))
  show(Path.replace(root + "/fresh.txt", root + "/missing.txt"))
  show(Path.replace(root + "/into-link.txt", root + "/link.txt"))
  show(Path.replace(root + "/blocked.txt", root + "/folder"))
  show(Path.replace(root + "/folder", root + "/other.txt"))
  show(Path.replace(root + "/absent.txt", root + "/old.txt"))
  show(Path.replace(root + "/from-link.txt", root + "/other.txt"))
end
"""


def test_path_replace_swaps_a_file_or_link_in_one_step_and_refuses_a_directory(new_dir, run_program):
    root = new_dir()
    for name, text in (("new.txt", "new"), ("old.txt", "old"), ("fresh.txt", "fresh"), ("into-link.txt", "linked"),
                       ("target.txt", "target"), ("blocked.txt", "blocked"), ("other.txt", "other")):
        (root / name).write_text(text)
    (root / "folder").mkdir()
    (root / "folder" / "keep.txt").write_text("keep")
    os.symlink(root / "target.txt", root / "link.txt")
    os.symlink(root / "blocked.txt", root / "from-link.txt")
    output = run_program(PATH_REPLACE_PROGRAM, [str(root)])
    assert output.splitlines() == [
        "ok",
        "ok",
        "ok",
        "io.is_directory filesystem: cannot rename path",
        "io.is_directory filesystem: cannot rename path",
        "io.not_found filesystem: cannot rename path",
        "io.failed filesystem: cannot rename path",
    ], output
    assert (root / "old.txt").read_text() == "new"
    assert (root / "missing.txt").read_text() == "fresh"
    assert not (root / "link.txt").is_symlink() and (root / "link.txt").read_text() == "linked"
    assert (root / "target.txt").read_text() == "target"
    assert (root / "blocked.txt").read_text() == "blocked"
    assert [path.name for path in (root / "folder").iterdir()] == ["keep.txt"]
    assert (root / "other.txt").read_text() == "other"
    assert sorted(path.name for path in root.iterdir()) == [
        "blocked.txt", "folder", "from-link.txt", "link.txt", "missing.txt", "old.txt", "other.txt", "target.txt"]


CHMOD_PROGRAM = r"""def show(r: Result[Void]) -> Void
  case r
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]}")
  end
end

def mode(path: String) -> Int = File.stat(path).unwrap!.mode

def main() -> Void
  path = System.args()[0]
  show(File.chmod(path, 0o444))
  puts(mode(path))
  show(File.chmod(path, 0o755))
  puts(mode(path))
  show(File.chmod(path, mode(path)))
  puts(mode(path))
  show(File.chmod(System.args()[1], 0o444))
  puts(mode(path))
  show(File.chmod(path, 0o755))
  show(File.chmod(path, 4096))
  show(File.chmod(path, -1))
  show(File.chmod(path + ".missing", 0o644, 1000))
  show(File.chmod(path, 0o644, 0))
end
"""


def test_file_chmod_sets_the_mode_that_file_stat_reads_back_and_refuses_a_bad_mode_or_path(new_dir, run_program):
    root = new_dir()
    path, link = root / "mode.txt", root / "link.txt"
    path.write_text("text")
    symlink("mode.txt", link)
    output = run_program(CHMOD_PROGRAM, [str(path), str(link)])
    # Windows keeps the owner write bit only, as the read-only attribute: 0o444 and 0o666. A link is followed there too.
    writable = "438" if WINDOWS else "493"
    assert output.splitlines() == [
        "ok", "292", "ok", writable, "ok", writable, "ok", "292", "ok",
        "argument filesystem: mode must be between 0 and 4095",
        "argument filesystem: mode must be between 0 and 4095",
        "io.not_found filesystem: cannot change the mode",
        "argument filesystem: timeout must be positive milliseconds",
    ], output
    assert path.stat().st_mode & 0o777 == (0o666 if WINDOWS else 0o755)
    assert link.is_symlink() and path.read_text() == "text"


@host_only(WINDOWS, "POSIX permission bits, setuid, folders and permission errors; Windows keeps only the read-only bit")
def test_file_chmod_follows_a_link_changes_a_directory_and_sets_every_bit_of_a_mode(new_dir, run_program):
    root = new_dir()
    target, link, folder = root / "target.txt", root / "link.txt", root / "folder"
    target.write_text("text")
    target.chmod(0o600)
    os.symlink("target.txt", link)
    folder.mkdir()
    output = run_program("""def main() -> Void
  root = System.args()[0]
  puts(File.chmod(root + "/link.txt", 0o751).ok?)
  puts(File.stat(root + "/target.txt").unwrap!.mode)
  puts(File.chmod(root + "/folder", 0o750).ok?)
  puts(File.chmod(root + "/target.txt", 0o4755).ok?)
  puts(File.stat(root + "/target.txt").unwrap!.mode)
end
""", [str(root)])
    assert output == "true\n%d\ntrue\ntrue\n%d\n" % (0o751, 0o4755)
    assert link.is_symlink() and os.readlink(link) == "target.txt"
    assert target.stat().st_mode & 0o7777 == 0o4755
    assert folder.stat().st_mode & 0o777 == 0o750
    if os.geteuid() == 0:
        return
    # A folder nobody may search: the call fails with a permission error and the file keeps its mode.
    sealed = new_dir()
    kept = sealed / "kept.txt"
    kept.write_text("kept")
    kept.chmod(0o640)
    sealed.chmod(0)
    try:
        output = run_program(r"""def main() -> Void
  case File.chmod(System.args()[0], 0o777)
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]}")
  end
end
""", [str(kept)])
    finally:
        sealed.chmod(0o755)
    assert output == "io.permission filesystem: cannot change the mode\n"
    assert kept.stat().st_mode & 0o777 == 0o640


SYMLINK_PROGRAM = r"""def show(r: Result[Void]) -> Void
  case r
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]} #{e.details.get("path").unwrap_or("-")} #{e.details.get("to").unwrap_or("-")}")
  end
end

def text(r: Result[String]) -> String
  case r
    ok(s) -> return s
    error(e) -> return "#{e.kind} #{e.message.split("\n")[0]}"
  end
end

def kind(path: String) -> String = File.lstat(path).unwrap!.kind

def main() -> Void
  root = System.args()[0]
  show(File.symlink("target.txt", "link.txt"))
  puts(text(File.read_text("link.txt")) + " " + text(File.readlink("link.txt")) + " " + kind("link.txt"))
  show(File.symlink("missing.txt", "dangling.txt"))
  puts(text(File.readlink("dangling.txt")) + " " + kind("dangling.txt") + " " + text(File.read_text("dangling.txt")))
  show(File.symlink("other.txt", "link.txt"))
  show(File.symlink("other.txt", "target.txt"))
  show(File.symlink("other.txt", "folder"))
  puts(text(File.readlink("link.txt")))
  show(File.symlink("folder", "folder-link"))
  puts(text(File.read_text("folder-link/inner.txt")))
  show(File.symlink("../folder", "sub/folder-up"))
  puts(text(File.read_text("sub/folder-up/inner.txt")))
  show(File.symlink("../target.txt", "folder/up.txt"))
  puts(text(File.read_text("folder/up.txt")))
  show(File.symlink(text(File.readlink("folder/up.txt")), "folder/again.txt"))
  puts(text(File.readlink("folder/again.txt")))
  show(File.symlink(root + "/target.txt", "absolute.txt"))
  puts(text(File.readlink("absolute.txt")))
  long = System.args()[1]
  show(File.symlink(long, "long.txt"))
  show(File.symlink(text(File.readlink("long.txt")), "long-again.txt"))
  puts(text(File.readlink("long.txt")) == long && text(File.readlink("long-again.txt")) == long)
  case File.symlink(long, "long.txt")
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{String.length(e.message.split("\n")[2])}")
  end
  nul = String.from_code(0)
  show(File.symlink("a" + nul, "nul-target"))
  show(File.symlink("target.txt", "nul" + nul))
  puts(text(File.readlink("nul" + nul)))
  show(File.symlink("target.txt", "nowhere/link.txt"))
  show(File.symlink("", "empty-target"))
  show(File.symlink("target.txt", ""))
  show(File.symlink("target.txt", "late.txt", 0))
  puts(text(File.readlink("target.txt")))
  puts(text(File.readlink("nothing.txt")))
  puts(text(File.readlink("link.txt", -1)))
  puts(text(File.readlink("peer.txt")))
end
"""


def test_file_symlink_makes_a_link_readlink_reads_it_even_dangling_and_an_existing_path_is_never_replaced(new_dir,
                                                                                                           run_program):
    root = new_dir()
    (root / "target.txt").write_text("hello")
    (root / "folder").mkdir()
    (root / "folder" / "inner.txt").write_text("inside")
    (root / "sub").mkdir()
    symlink("target.txt", root / "peer.txt")
    output = run_program(SYMLINK_PROGRAM, [str(root), "d/" * 500], cwd=root).splitlines()
    absolute = (str(root) + "/target.txt").replace("\\", "/")
    exists = "io.exists filesystem: cannot make symbolic link"
    assert output == [
        "ok", "hello target.txt link",
        "ok", "missing.txt link io.not_found filesystem: path does not refer to a regular file",
        f"{exists} link.txt other.txt",
        f"{exists} target.txt other.txt",
        f"{exists} folder other.txt",
        "target.txt",
        "ok", "inside",
        "ok", "inside",
        "ok", "hello",
        "ok", "../target.txt",
        "ok", absolute,
        "ok", "ok", "true",
        f"io.exists {len('  target: ') + 256}",
        'argument filesystem: invalid path "a\\u0000" - -',
        'argument filesystem: invalid path "nul\\u0000" - -',
        'argument filesystem: invalid path "nul\\u0000"',
        "io.not_found filesystem: cannot make symbolic link nowhere/link.txt target.txt",
        "argument filesystem: invalid path \"\" - -",
        "argument filesystem: invalid path \"\" - -",
        "argument filesystem: timeout must be positive milliseconds - -",
        "io.failed filesystem: cannot read symbolic link",
        "io.not_found filesystem: cannot read symbolic link",
        "argument filesystem: timeout must be positive milliseconds",
        "target.txt",
    ], output
    assert os.readlink(root / "link.txt") == "target.txt" and (root / "target.txt").read_text() == "hello"
    assert os.readlink(root / "dangling.txt") == "missing.txt" and not (root / "dangling.txt").exists()
    assert (root / "folder-link").is_symlink() and (root / "folder-link").is_dir()
    assert os.readlink(root / "folder" / "up.txt").replace("\\", "/") == "../target.txt"
    assert (root / "folder" / "again.txt").read_text() == "hello"
    assert not (root / "nowhere").exists() and not (root / "late.txt").is_symlink()
    assert sorted(path.name for path in root.iterdir()) == [
        "absolute.txt", "dangling.txt", "folder", "folder-link", "link.txt", "long-again.txt", "long.txt", "peer.txt",
        "sub", "target.txt"]
    assert os.readlink(root / "sub" / "folder-up").replace("\\", "/") == "../folder"
    assert (root / "sub" / "folder-up").is_dir() and os.readlink(root / "long.txt").replace("\\", "/") == "d/" * 500
    if WINDOWS:
        output = run_program(r'''def main() -> Void
  for target in ["\\\\?\\C:\\x", "\\\\.\\x"]
    case File.symlink(target, "device.txt")
      ok(_) -> puts("ok")
      error(e) -> puts("#{e.kind} #{e.message}")
    end
  end
end
''', cwd=root).splitlines()
        assert output == [r'argument filesystem: invalid path "\\\\?\\C:\\x"',
                          r'argument filesystem: invalid path "\\\\.\\x"'], output
        assert not (root / "device.txt").is_symlink()


@host_only(WINDOWS, "a link text of bytes that are not UTF-8, which Windows cannot hold (it keeps the text as UTF-16)")
def test_file_readlink_refuses_a_link_text_that_is_not_utf_8_and_the_text_stays_as_it_was(new_dir, run_program):
    root = new_dir()
    os.symlink(b"\xff", os.fsencode(root / "bad.txt"))
    output = run_program(r'''def main() -> Void
  case File.readlink("bad.txt")
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.message}")
  end
end
''', cwd=root)
    assert output == "text.encoding invalid UTF-8 at byte 0\n"
    assert os.readlink(os.fsencode(root / "bad.txt")) == b"\xff"


COPY_PROGRAM = r"""def show(r: Result[Void]) -> Void
  case r
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]} #{e.details.get("path").unwrap_or("-")} #{e.details.get("to").unwrap_or("-")}")
  end
end

def mode(path: String) -> Int = File.stat(path).unwrap!.mode

def main() -> Void
  show(File.copy("tool.sh", "tool-copy.sh"))
  puts(mode("tool-copy.sh") == mode("tool.sh"))
  show(File.copy("secret.txt", "secret-copy.txt"))
  puts(mode("secret-copy.txt") == mode("secret.txt"))
  show(File.copy("empty.txt", "empty-copy.txt"))
  show(File.copy("big.bin", "big-copy.bin"))
  show(File.copy("link.txt", "from-link.txt"))
  show(File.copy("tool.sh", "old.txt"))
  puts(mode("old.txt") == mode("tool.sh"))
  show(File.copy("tool.sh", "target-link.txt"))
  show(File.copy("tool.sh", "tool.sh"))
  show(File.copy("tool.sh", "folder"))
  show(File.copy("tool.sh", "folder-link"))
  show(File.copy("tool.sh", "dangling-to.txt"))
  show(File.copy("folder", "folder-copy"))
  show(File.copy("missing.txt", "missing-copy.txt"))
  show(File.copy("tool.sh", "nowhere/copy.sh"))
  show(File.copy("tool.sh", "", 1000))
  show(File.copy("tool.sh", "late.sh", 0))
  show(File.copy("tool.sh", "locked.txt"))
end
"""


def test_file_copy_keeps_the_mode_replaces_a_file_through_a_link_whole_and_leaves_the_destination_on_a_failure(
        new_dir, run_program):
    root = new_dir()
    big = os.urandom(200_000)
    (root / "tool.sh").write_text("echo hi\n")
    (root / "tool.sh").chmod(0o755)
    (root / "secret.txt").write_text("secret")
    (root / "secret.txt").chmod(0o600)
    (root / "empty.txt").write_bytes(b"")
    (root / "big.bin").write_bytes(big)
    (root / "old.txt").write_text("old")
    (root / "old.txt").chmod(0o640)
    (root / "folder").mkdir()
    (root / "kept.txt").write_text("kept")
    (root / "locked.txt").write_text("locked")
    (root / "locked.txt").chmod(0o444)
    symlink("tool.sh", root / "link.txt")
    symlink("kept.txt", root / "target-link.txt")
    symlink("folder", root / "folder-link")
    symlink("nowhere.txt", root / "dangling-to.txt")
    output = run_program(COPY_PROGRAM, cwd=root).splitlines()
    # A read-only destination: POSIX renames over it (the folder decides), Windows refuses and keeps it.
    locked = "io.permission filesystem: cannot copy file tool.sh locked.txt" if WINDOWS else "ok"
    assert output == [
        "ok", "true",
        "ok", "true",
        "ok",
        "ok",
        "ok",
        "ok", "true",
        "ok",
        "ok",
        "io.is_directory filesystem: cannot copy file tool.sh folder",
        "io.is_directory filesystem: cannot copy file tool.sh folder-link",
        "io.not_found filesystem: cannot copy file tool.sh dangling-to.txt",
        "io.is_directory filesystem: path does not refer to a regular file folder folder-copy",
        "io.not_found filesystem: path does not refer to a regular file missing.txt missing-copy.txt",
        "io.not_found filesystem: cannot copy file tool.sh nowhere/copy.sh",
        "argument filesystem: invalid path \"\" - -",
        "argument filesystem: timeout must be positive milliseconds - -",
        locked,
    ], output
    assert (root / "tool-copy.sh").read_text() == "echo hi\n" and (root / "empty-copy.txt").read_bytes() == b""
    assert (root / "big-copy.bin").read_bytes() == big and (root / "from-link.txt").read_text() == "echo hi\n"
    assert (root / "old.txt").read_text() == "echo hi\n"
    # A link at the destination stays a link, and the file it names is the one replaced.
    assert (root / "target-link.txt").is_symlink() and (root / "kept.txt").read_text() == "echo hi\n"
    assert not (root / "nowhere.txt").exists() and (root / "tool.sh").read_text() == "echo hi\n"
    assert not (root / "from-link.txt").is_symlink() and (root / "link.txt").is_symlink()
    assert (root / "folder").is_dir() and not list((root / "folder").iterdir())
    if not WINDOWS:
        assert (root / "tool-copy.sh").stat().st_mode & 0o7777 == 0o755
        assert (root / "secret-copy.txt").stat().st_mode & 0o7777 == 0o600
        assert (root / "old.txt").stat().st_mode & 0o7777 == 0o755
        assert (root / "kept.txt").stat().st_mode & 0o7777 == 0o755
    else:
        assert (root / "locked.txt").read_text() == "locked"
    assert sorted(path.name for path in root.iterdir() if ".agc-" in path.name) == []


@host_only(WINDOWS, "POSIX permission bits (setuid, setgid, sticky) and the umask, which Windows does not have")
def test_file_copy_gives_the_permission_bits_without_setuid_setgid_or_sticky_whatever_the_umask(new_dir, run_program):
    root = new_dir()
    (root / "tool.sh").write_text("echo hi\n")
    for bits in (0o7755, 0o6755, 0o4755):
        try:
            (root / "tool.sh").chmod(bits)
            break
        except OSError:
            continue
    assert (root / "tool.sh").stat().st_mode & 0o4000
    before = os.umask(0o077)
    try:
        output = run_program("""def main() -> Void
  puts(File.copy("tool.sh", "tool-copy.sh").ok?)
end
""", cwd=root)
    finally:
        os.umask(before)
    assert output == "true\n"
    assert (root / "tool-copy.sh").stat().st_mode & 0o7777 == 0o755


@host_only(WINDOWS, "POSIX folder and file permissions; Windows does not enforce them on a folder or an owner")
def test_file_copy_fails_with_a_permission_error_when_the_source_or_the_folder_refuses_and_leaves_nothing(new_dir,
                                                                                                         run_program):
    if os.geteuid() == 0:
        pytest.skip("host-only: a mode of 000 stops nothing for root")
    root = new_dir()
    (root / "source.txt").write_text("source")
    (root / "sealed.txt").write_text("sealed")
    (root / "sealed.txt").chmod(0)
    (root / "closed").mkdir()
    (root / "closed" / "kept.txt").write_text("kept")
    (root / "closed").chmod(0o555)
    try:
        output = run_program(r"""def main() -> Void
  for pair in [["sealed.txt", "a.txt"], ["source.txt", "closed/b.txt"], ["source.txt", "closed/kept.txt"]]
    case File.copy(pair[0], pair[1])
      ok(_) -> puts("ok")
      error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]}")
    end
  end
end
""", cwd=root).splitlines()
    finally:
        (root / "closed").chmod(0o755)
        (root / "sealed.txt").chmod(0o600)
    assert output == ["io.permission filesystem: cannot open file for reading",
                      "io.permission filesystem: cannot copy file", "io.permission filesystem: cannot copy file"]
    assert not (root / "a.txt").exists() and (root / "closed" / "kept.txt").read_text() == "kept"
    assert sorted(path.name for path in (root / "closed").iterdir()) == ["kept.txt"]


@no_fifo
def test_file_copy_refuses_a_fifo_or_a_device_at_either_end_without_waiting_and_leaves_no_file(new_dir,
                                                                                            run_vm_bounded):
    root = new_dir()
    os.mkfifo(root / "source.fifo")
    os.mkfifo(root / "target.fifo")
    (root / "source.txt").write_text("source")
    code, output, errors = run_vm_bounded(root, r"""def main() -> Void
  root = System.args()[0]
  for pair in [[root + "/source.fifo", root + "/a.txt"], ["/dev/null", root + "/b.txt"],
               [root + "/source.txt", root + "/target.fifo"], [root + "/source.txt", "/dev/null"]]
    case File.copy(pair[0], pair[1], 5000)
      ok(_) -> puts("ok")
      error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]}")
    end
  end
end
""", root)
    assert (code, output.splitlines()) == (0, [
        "io.failed filesystem: path does not refer to a regular file",
        "io.failed filesystem: path does not refer to a regular file",
        "io.exists filesystem: cannot copy file",
        "io.exists filesystem: cannot copy file",
    ]), errors
    assert sorted(path.name for path in root.iterdir()) == [
        "program.agc", "program.agcb", "source.fifo", "source.txt", "target.fifo"]
    assert (root / "target.fifo").is_fifo()


@host_only(WINDOWS, "a limit on the size of a written file (ulimit -f), which Windows does not have")
def test_file_copy_that_fails_after_the_new_file_exists_removes_it_and_keeps_the_destination(new_dir):
    root = new_dir()
    (root / "big.bin").write_bytes(os.urandom(1 << 20))
    (root / "to.txt").write_text("old")
    source = root / "program.agc"
    source.write_text(r"""def main() -> Void
  case File.copy("big.bin", "to.txt")
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.message.split("\n")[0]}")
  end
end
""", encoding="utf-8")
    bytecode = compile_agc(source, root / "program.agcb")
    # SIGXFSZ ignored, so the write past the limit fails with EFBIG instead of killing the VM.
    result = run(["sh", "-c", 'trap "" XFSZ; ulimit -f 100; exec "$@"', "sh", *vm_command(), "--", bytecode],
                 cwd=root, env=vm_environment())
    assert (result.code, result.stdout) == (0, "io.too_large filesystem: cannot copy file\n"), result.stderr
    assert (root / "to.txt").read_text() == "old"
    assert sorted(path.name for path in root.iterdir() if ".agc-" in path.name) == []


def test_file_copy_stops_at_a_timeout_and_at_the_end_of_the_run_and_removes_the_new_file(new_dir, run_program):
    root = new_dir()
    with open(root / "big.bin", "wb") as large:
        large.truncate(1 << 30)
    (root / "to.txt").write_text("old")
    output = run_program("""def main() -> Void
  case File.copy("big.bin", "to.txt", 20)
    ok(_) -> puts("ok")
    error(e) -> puts(e.kind)
  end
end
""", cwd=root)
    assert output == "io.timeout\n"
    assert (root / "to.txt").read_text() == "old"
    assert sorted(path.name for path in root.iterdir() if ".agc-" in path.name) == []
    # The program ends while the copy is on its way: the exit waits for the short abort, not for the whole file.
    started = time.monotonic()
    run_program("""def copier(_: Int) -> Result[Void]
  return File.copy("big.bin", "to.txt", 60000)
end

def main() -> Void
  Task.spawn(&copier, 0)
  Task.sleep(50)
end
""", cwd=root)
    assert time.monotonic() - started < scaled(10)
    assert (root / "to.txt").read_text() == "old"
    assert sorted(path.name for path in root.iterdir() if ".agc-" in path.name) == []
