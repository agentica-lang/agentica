"""File.each_line on the VM.

A 10 MB file streams in order with about size/buffer reads (and, on Linux, bounded memory);
FIFOs fed by fixtures/lines-peer.py check partial reads, stalls, early closes
and a crash that frees the descriptor of a parked task. Ordinary files check
line decoding, the end-of-file and overlong errors and descriptor cleanup. The
descriptor count reads /proc/self/fd (Linux) or /dev/fd (macOS). Windows has
named pipes and handle counts for the same checks: the descriptor-count case is
host-only there, and test_windows_handle_counts.py counts the handles of the VM
instead. The FIFO cases are host-only there: Windows has no FIFO file, and the VM refuses a named pipe as a file.
"""
import re
import sys

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, WAIT_SECONDS, WINDOWS, Child, compile_agc, host_only, run,
                                 run_vm, vm_command, vm_environment)

PEER = FIXTURES / "lines-peer.py"
LINUX = sys.platform.startswith("linux")
# The folder that lists the open descriptors of the process: the programs below name /proc/self/fd, and a macOS run
# swaps it for /dev/fd when the program is written.
FD_ROOT = "/dev/fd" if sys.platform == "darwin" else "/proc/self/fd"
needs_fifo = host_only(
    WINDOWS, "a FIFO read as a file that waits on the loop; Windows has no FIFO file and the VM refuses a named pipe "
             "as a file (test_a_named_pipe_is_refused_as_a_file_at_once_and_the_vm_holds_no_handle_of_it "
             "in test_windows_handle_counts.py checks the refusal)")
needs_fd_folder = host_only(
    WINDOWS, "the open descriptors are counted in a folder that Windows does not have "
             "(test_each_line_frees_its_handle_on_every_return_path in test_windows_handle_counts.py counts handles)")
BUFFER_BYTES = 4096
LINE_COUNT = 1400000

STREAM_PROGRAM = """\
def main() -> Void
  r = File.each_line(System.args()[0], 4096, 10000) do |line|
    puts(line)
    ok()
  end
  puts(r)
end
"""

# The peak resident memory comes from /proc, so only Linux appends this report to the stream program.
HWM_REPORT = """\
def hwm() -> Void
  status = Result.unwrap!(File.read_text("/proc/self/status", 10000))
  for entry in status.split("\\n")
    if entry.starts_with?("VmHWM")
      puts(entry)
    end
  end
end
"""


def stream_program():
    """The stream program, which on Linux also prints the peak memory (HWM_REPORT) after the last line."""
    if not LINUX:
        return STREAM_PROGRAM
    return HWM_REPORT + "\n" + STREAM_PROGRAM.replace("  puts(r)\n", "  puts(r)\n  hwm()\n")


BASELINE_PROGRAM = """\
def main() -> Void
  status = Result.unwrap!(File.read_text("/proc/self/status", 10000))
  for entry in status.split("\\n")
    if entry.starts_with?("VmHWM")
      puts(entry)
    end
  end
end
"""

FIFO_PROGRAM = """\
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def main() -> Void
  before = open_files()
  r = File.each_line(System.args()[0], 1024, Result.unwrap!(String.to_int(System.args()[1]))) do |line|
    IO.inspect(line)
    ok()
  end
  IO.inspect(r)
  IO.inspect(wait_for(before, 0))
end
"""

CRASH_PROGRAM = """\
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def reader(path: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    puts("never #{line}")
    ok()
  end
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def parent(go: Channel[Int]) -> Int
  Task.spawn(&reader, System.args()[0])
  Result.unwrap!(go.recv(5000))
  zero = String.length("")
  return 1 / zero
end

def main() -> Void
  before = open_files()
  go: Channel[Int] = Channel.new(1)
  Task.spawn(&parent, go)
  IO.inspect(wait_for(before, 1))
  Result.unwrap!(go.send(1, 1000))
  IO.inspect(wait_for(before, 0))
end
"""

CLOSE_PROGRAM = """\
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def main() -> Void
  path = System.args()[0]
  before = open_files()
  r = File.each_line(path, 1024, 5000) do |line|
    IO.inspect(line)
    return error("stop at #{line}")
  end
  IO.inspect(r)
  IO.inspect(wait_for(before, 0))
  File.write_text(path + ".go", "go", 5000).unwrap!
  h = Result.unwrap!(File.open(path, "read", 5000))
  IO.inspect(File.read_line(h, 5000))
  IO.inspect(File.close(h, 5000))
  IO.inspect(wait_for(before, 0))
end
"""


READ_ORDINARY_PROGRAM = """\
def main() -> Void
  args = System.args()
  file = Result.unwrap!(File.open(args[0], "read", 5000))
  for i in 0...args[1].to_i!
    IO.inspect(File.read_line(file, 5000))
  end
  puts(File.close(file, 5000).ok?)
end
"""

EACH_ORDINARY_PROGRAM = """\
def main() -> Void
  r = File.each_line(System.args()[0], 1024, 5000) do |line|
    IO.inspect(line)
    if line == "stop"
      return error("stopped")
    end
    ok()
  end
  IO.inspect(r)
end
"""

COUNT_FDS_PROGRAM = """\
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def main() -> Void
  before = open_files()
  r = File.each_line(System.args()[0], 1024, 5000) do |line|
    IO.inspect(line)
    if line == "stop"
      return error("stopped")
    end
    ok()
  end
  IO.inspect(r)
  IO.inspect(open_files() - before == 0)
end
"""


def _ordinary_file_output(tmp_path, data, program, name, *args):
    target = tmp_path / "case.txt"
    target.write_bytes(data)
    source = tmp_path / f"{name}.agc"
    source.write_text(program.replace("/proc/self/fd", FD_ROOT), encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / f"{name}.agcb")
    result = run_vm(
        bytecode, args=[str(target), *args], env=vm_environment(), cwd=tmp_path
    )
    assert result.code == 0, result.stderr
    return result.stdout.splitlines()


@pytest.mark.parametrize("data,count,successful", (
    (b"", 1, []),
    (b"one\ntwo\nlast\n", 4, ['ok("one")', 'ok("two")', 'ok("last")']),
    (b"one\r\ntwo\nlast", 4, ['ok("one")', 'ok("two")', 'ok("last")']),
    (b"\n", 2, ['ok("")']),
    (b"\xff\n", 1, []),
    (b"\xe2\x82", 1, []),
    (b"a" * 1048577 + b"\n", 1, []),
), ids=("empty", "lf", "crlf-unterminated", "blank-line", "invalid-utf8", "truncated-utf8",
          "overlong-line"))
def test_read_line_on_ordinary_files_decodes_strips_and_reports_end_of_file(tmp_path, data, count, successful):
    lines = _ordinary_file_output(
        tmp_path, data, READ_ORDINARY_PROGRAM, "read", str(count)
    )
    assert lines[:len(successful)] == successful
    assert lines[-2].startswith("error("), lines
    assert lines[-1] == "true"


@pytest.mark.parametrize("data,delivered,ends_ok", (
    (b"a\nb\n", ['"a"', '"b"'], True),
    (b"a\r\nb", ['"a"', '"b"'], True),
    (b"", [], True),
    (b"a\nstop\nc\n", ['"a"', '"stop"'], False),
    (b"\xff\n", [], False),
    (b"a" * 2000 + b"\nshort\n", [], False),
), ids=("lf", "crlf-unterminated", "empty", "block-error-stops", "invalid-utf8", "overlong-line"))
def test_each_line_on_ordinary_files_passes_lines_and_stops_on_errors(tmp_path, data, delivered, ends_ok):
    lines = _ordinary_file_output(tmp_path, data, EACH_ORDINARY_PROGRAM, "each")
    assert lines[:len(delivered)] == delivered
    tail = lines[len(delivered):]
    if ends_ok:
        assert tail == ["ok()"]
    else:
        assert len(tail) == 1 and tail[0].startswith("error("), lines


@needs_fd_folder
@pytest.mark.parametrize("data,delivered", (
    (b"a\nb\n", ['"a"', '"b"']),
    (b"a\nstop\nc\n", ['"a"', '"stop"']),
), ids=("clean", "block-error"))
def test_each_line_frees_its_descriptor_on_every_return_path(tmp_path, data, delivered):
    lines = _ordinary_file_output(tmp_path, data, COUNT_FDS_PROGRAM, "count")
    assert lines[:len(delivered)] == delivered
    assert lines[-1] == "true"


def hwm_kib(text):
    return int(re.search(r"VmHWM:\s+([0-9]+) kB", text).group(1))


def run_program(tmp_path, name, text, *args, env=None, flags=()):
    source = tmp_path / (name + ".agc")
    source.write_text(text.replace("/proc/self/fd", FD_ROOT), encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / (name + ".agcb"))
    return run_vm(bytecode, *flags, args=args, env=vm_environment(env), timeout=WAIT_SECONDS)


def write_lines(tmp_path):
    data = tmp_path / "lines.txt"
    data.write_text("".join("l%d\n" % k for k in range(LINE_COUNT)))
    return data


def collected():
    """False for a VM built without libgc (its memory use is not bounded by a collector)."""
    return "no libgc" not in run([*vm_command(), "--version"]).stdout


def start_fifo_peer(tmp_path, mode, request):
    fifo = tmp_path / (mode + ".fifo")
    peer = Child([PYTHON, PEER, fifo, mode])
    request.addfinalizer(peer.stop)
    assert peer.next_line() == "ready", mode
    return peer, fifo


def test_a_10_mb_file_of_short_lines_streams_in_order_with_size_over_buffer_reads_and_bounded_memory(tmp_path):
    data = write_lines(tmp_path)
    size = data.stat().st_size
    assert size > 10000000
    trace = tmp_path / "trace.txt"
    result = run_program(tmp_path, "stream", stream_program(), data,
                         env={"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": trace})
    assert result.code == 0, result.stderr
    expected = data.read_text()
    assert result.stdout.startswith(expected), "every line, in order, once"
    rest = result.stdout[len(expected):]
    assert re.fullmatch(r"ok\(\)\n(VmHWM:\s+[0-9]+ kB\n)?", rest)
    if LINUX and collected():
        baseline = run_program(tmp_path, "baseline", BASELINE_PROGRAM)
        assert baseline.code == 0, baseline.stderr
        growth = hwm_kib(rest) - hwm_kib(baseline.stdout)
        assert growth < size // 4096, "peak memory grew by %d kB while streaming %d bytes" % (growth, size)
    jobs = len(re.findall(r" io start job=[0-9]+ kind=file ", trace.read_text()))
    assert jobs >= size // (BUFFER_BYTES + 1), "%d jobs" % jobs
    assert jobs <= 8 + size // (BUFFER_BYTES - 16), "%d jobs" % jobs


def test_max_steps_ends_a_long_file_with_runtime_step_limit(tmp_path):
    data = write_lines(tmp_path)
    result = run_program(tmp_path, "stream", stream_program(), data, flags=["--max-steps", "50000"])
    assert result.code == 1
    assert "RUNTIME-STEP-LIMIT" in result.stderr


@needs_fifo
def test_a_fifo_fed_in_pieces_lines_and_a_crlf_split_across_reads_a_last_line_without_a_newline(tmp_path, request):
    peer, fifo = start_fifo_peer(tmp_path, "pieces", request)
    result = run_program(tmp_path, "fifo", FIFO_PROGRAM, fifo, "5000")
    assert result.code == 0, result.stderr
    assert result.stdout == '"alpha"\n"beta"\n"gamma"\n""\n"delta"\nok()\ntrue\n'
    assert peer.next_line() == "closed"


@needs_fifo
def test_a_fifo_that_stalls_times_out_one_read_with_a_line_half_read_and_the_descriptor_is_closed(tmp_path, request):
    _, fifo = start_fifo_peer(tmp_path, "stall", request)
    result = run_program(tmp_path, "fifo", FIFO_PROGRAM, fifo, "1200")
    assert result.code == 0, result.stderr
    assert result.stdout == '"first"\nerror("filesystem: operation timed out")\ntrue\n'


@needs_fifo
def test_closing_a_read_fifo_that_still_holds_buffered_lines_is_ok_after_an_early_stop_and_after_read_line(
    tmp_path, request
):
    _, fifo = start_fifo_peer(tmp_path, "burst", request)
    result = run_program(tmp_path, "close", CLOSE_PROGRAM, fifo)
    assert result.code == 0, result.stderr
    assert result.stdout == '"one"\nerror("stop at one")\ntrue\nok("four")\nok()\ntrue\n'


@needs_fifo
def test_a_crash_cancels_a_task_parked_in_file_each_line_on_a_fifo_and_frees_its_descriptor(tmp_path, request):
    _, fifo = start_fifo_peer(tmp_path, "idle", request)
    result = run_program(tmp_path, "crash", CRASH_PROGRAM, fifo, env={"UV_THREADPOOL_SIZE": "1"})
    assert result.code == 1
    assert result.stdout == "true\ntrue\n"
