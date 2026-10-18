"""Windows metadata values and file locks, run on the native Windows runner."""

from __future__ import annotations

import ctypes
import os
import stat

import pytest

from tests.agentica_test import TARGET_OS, compile_agc, run_vm, start_vm, vm_environment
from tests.vm_os_support import compile_text, root, work
from tests.windows_support import kernel32_file_api

# The documented Windows values: mode carries the read-only attribute only, and both owner ids are 0.
WRITABLE_MODE = 0o666
READ_ONLY_MODE = 0o444

METADATA_PROGRAM = """\
def main() -> Void
  info = Result.unwrap!(File.stat(System.args()[0], 5000))
  puts("#{info.kind} #{info.mode} #{info.user_id} #{info.group_id}")
end
"""

# Both restricted creators, so the case that names them really makes the entries it reports. Their Windows guarantee is
# an owner-and-DACL check on the object they opened, which these two lines exercise.
PRIVATE_PROGRAM = """\
def main() -> Void
  args = System.args()
  file = Result.unwrap!(File.open(args[0], "create_private", 5000))
  Result.unwrap!(Dir.mkdir_private(args[1], 5000))
  for path in [args[0], args[1]]
    info = Result.unwrap!(File.stat(path, 5000))
    puts("#{info.kind} #{info.mode} #{info.user_id} #{info.group_id}")
  end
  Result.unwrap!(File.close(file, 5000))
end
"""

# The holder never closes its handle and never ends: only the process ending or being killed frees the lock that the
# probe then asks for. `ready` is the explicit signal that the lock is held, so nothing waits on the clock.
CONTENTION_PROGRAM = """\
def main() -> Void
  args = System.args()
  file = Result.unwrap!(File.open(args[0], "read", 5000))
  if args[1] == "probe"
    puts(Result.unwrap!(File.try_lock(file, 5000)))
    return
  end
  puts(Result.unwrap!(File.try_lock(file, 5000)))
  puts("ready")
  IO.flush()
  IO.gets()
end
"""

# The lock belongs to the task that opened the handle: awaiting that task is what ends it and closes the handle.
# Every step is sequenced by an await, so the order is fixed and nothing waits on the clock.
TASK_LOCK_PROGRAM = """\
def take(path: String) -> Bool
  file = Result.unwrap!(File.open(path, "read", 5000))
  return Result.unwrap!(File.try_lock(file, 5000))
end

def main() -> Void
  path = System.args()[0]
  held = Task.spawn(&take, path)
  puts(Task.await(held))
  puts(Task.await(held))
  file = Result.unwrap!(File.open(path, "read", 5000))
  puts(Result.unwrap!(File.try_lock(file, 5000)))
  puts(Task.await(Task.spawn(&take, path)))
  Result.unwrap!(File.close(file, 5000))
  puts(Task.await(Task.spawn(&take, path)))
end
"""


# Main permits the ancestor to crash only after the child has acquired the lock.
# Awaiting both tasks observes cancellation while the process remains alive.
CANCELLED_LOCK_PROGRAM = """\
struct LockContext
  path: String
  ready: Channel[Bool]
  crash: Channel[Bool]
  parked: Channel[Bool]
  handles: Channel[Task[Result[Void]]]
end

def locked_child(context: LockContext) -> Result[Void]
  if System.args().length > 1
    return File.each_line(context.path, 1024, 5000) do |line|
      Result.unwrap!(context.ready.send(line.length > 0, 5000))
      context.parked.recv(60000)
      return ok()
    end
  end
  file = Result.unwrap!(File.open(context.path, "read", 5000))
  Result.unwrap!(context.ready.send(Result.unwrap!(File.try_lock(file, 5000)), 5000))
  context.parked.recv(60000)
  return ok()
end

def ancestor(context: LockContext) -> Result[Void]
  child = Task.spawn(&locked_child, context)
  Result.unwrap!(context.handles.send(child, 5000))
  Result.unwrap!(context.crash.recv(5000))
  failure: Result[Void] = error("intentional ancestor failure")
  Result.unwrap!(failure)
  return ok()
end

def main() -> Void
  context = LockContext(
    path: System.args()[0],
    ready: Channel.new(1),
    crash: Channel.new(1),
    parked: Channel.new(1),
    handles: Channel.new(1),
  )
  parent = Task.spawn(&ancestor, context)
  child = Result.unwrap!(context.handles.recv(5000))
  puts(Result.unwrap!(context.ready.recv(5000)))
  Result.unwrap!(context.crash.send(true, 5000))
  puts(Task.await(parent).ok?)
  puts(Task.await(child).ok?)
  if System.args().length > 1
    puts("ready")
    IO.flush()
    IO.gets()
    return
  end
  file = Result.unwrap!(File.open(context.path, "read", 5000))
  puts(Result.unwrap!(File.try_lock(file, 5000)))
end
"""

EACH_LINE_PROGRAM = """\
def main() -> Void
  args = System.args()
  result = File.each_line(args[0], 1024, 5000) do |line|
    IO.inspect(line)
    if args[1] == "stop"
      return error("intentional early stop")
    end
    return ok()
  end
  puts(result.ok?)
  puts("ready")
  IO.flush()
  IO.gets()
end
"""

READ_LINES_PROGRAM = """\
def main() -> Void
  args = System.args()
  file = Result.unwrap!(File.open(args[0], "read", 5000))
  for i in 0...args[1].to_i!
    IO.inspect(File.read_line(file, 5000))
  end
  puts(File.close(file, 5000).ok?)
end
"""

REQUIRES_WINDOWS_VM = pytest.mark.skipif(TARGET_OS != "windows", reason="requires the native Windows VM")


def _metadata(bytecode, path, root) -> list[str]:
    """Run the metadata probe program for one path; return its stdout words."""
    result = run_vm(bytecode, args=[str(path)], env=vm_environment(), cwd=root)
    assert (result.code, result.stderr) == (0, ""), result.stderr
    return result.stdout.split()


@REQUIRES_WINDOWS_VM
def test_a_regular_file_reports_no_owner_and_only_the_read_only_attribute(root, work):
    """Check the metadata values the Windows platform really reports."""
    bytecode = compile_text(work, METADATA_PROGRAM, "windows-metadata")


    target = root / "plain.txt"
    target.write_text("plain", encoding="utf-8")
    kind, mode, user_id, group_id = _metadata(bytecode, target, root)
    assert kind == "file"
    assert mode == str(WRITABLE_MODE)
    # A 0 here is not an owner: the platform has no Unix owner ids, so the fields carry nothing to look up.
    assert (user_id, group_id) == ("0", "0")

    os.chmod(target, stat.S_IREAD)
    kind, mode, user_id, group_id = _metadata(bytecode, target, root)
    assert (kind, mode, user_id, group_id) == ("file", str(READ_ONLY_MODE), "0", "0")

    os.chmod(target, stat.S_IWRITE)
    assert _metadata(bytecode, target, root)[1] == str(WRITABLE_MODE)


@REQUIRES_WINDOWS_VM
def test_a_directory_reports_the_same_zero_owner(root, work):
    bytecode = compile_text(work, METADATA_PROGRAM, "windows-metadata")


    directory = root / "directory"
    directory.mkdir()
    kind, mode, user_id, group_id = _metadata(bytecode, directory, root)
    assert (kind, mode, user_id, group_id) == ("directory", str(WRITABLE_MODE), "0", "0")


# Wine answers access denied for the restricted creators: it does not implement the owner and DACL the adapter sets
# and then checks on the object it opened, so this case is evidence from the native runner only.
@REQUIRES_WINDOWS_VM
@pytest.mark.skipif(os.environ.get("AGENTICA_TEST_WINE") == "1", reason="Wine cannot make the restricted object")
def test_the_restricted_creators_make_entries_that_report_the_same_zero_owner(root, work):
    bytecode = compile_text(work, METADATA_PROGRAM, "windows-metadata")


    private_file = root / "private.txt"
    private_directory = root / "private-directory"
    bytecode = compile_text(work, PRIVATE_PROGRAM, "windows-private")
    result = run_vm(bytecode, args=[str(private_file), str(private_directory)], env=vm_environment(), cwd=root)
    assert (result.code, result.stderr) == (0, ""), result.stderr
    assert result.stdout.splitlines() == [
        f"file {WRITABLE_MODE} 0 0", f"directory {WRITABLE_MODE} 0 0",
    ]
    assert _metadata(bytecode, private_file, root)[2:] == ["0", "0"]
    assert private_directory.is_dir()


def _probe_lock(root, target, bytecode) -> str:
    """Ask another process for the lock; "true" or "false", never a timeout."""
    result = run_vm(bytecode, args=[str(target), "probe"], env=vm_environment(), cwd=root)
    assert (result.code, result.stderr) == (0, ""), result.stderr
    return result.stdout.strip()


def _hold_lock(root, target, bytecode, adopt):
    """A process holding the lock and waiting on stdin, adopted so the test always stops it."""
    child = adopt(start_vm(bytecode, str(target), "hold", stdin=True, cwd=root))
    assert child.next_line() == "true"
    assert child.next_line() == "ready"
    return child


def _lock_case(root, work):
    """A fresh lock target and the contention program for it."""
    target = root / "lock"
    target.write_text("", encoding="utf-8")
    return target, compile_text(work, CONTENTION_PROGRAM, "windows-contention")


@REQUIRES_WINDOWS_VM
def test_a_lock_contends_across_processes_and_frees_when_the_holder_ends(root, work, adopt):
    """Check that a Windows lock contends across processes and dies with its holder."""
    target, bytecode = _lock_case(root, work)
    assert _probe_lock(root, target, bytecode) == "true"
    holder = _hold_lock(root, target, bytecode, adopt)
    try:
        assert _probe_lock(root, target, bytecode) == "false"
    finally:
        holder.close_stdin()
    assert holder.wait() == 0
    assert holder.process.poll() is not None
    assert _probe_lock(root, target, bytecode) == "true"


@REQUIRES_WINDOWS_VM
def test_a_killed_holder_frees_the_lock(root, work, adopt):
    target, bytecode = _lock_case(root, work)
    holder = _hold_lock(root, target, bytecode, adopt)
    try:
        assert _probe_lock(root, target, bytecode) == "false"
    finally:
        holder.stop()
    assert holder.process.poll() is not None, "the holder process must be gone before the lock is asked for"
    assert _probe_lock(root, target, bytecode) == "true"


@REQUIRES_WINDOWS_VM
def test_cancelled_owner_releases_its_lock_without_ending_the_process(root, work):
    target, bytecode = _lock_case(root, work)
    cancelled = compile_text(work, CANCELLED_LOCK_PROGRAM, "windows-cancelled-lock")
    result = run_vm(
        cancelled, args=[str(target)], env=vm_environment(), cwd=root
    )
    assert result.code == 0, result.stderr
    assert "RUNTIME-UNWRAP-ERROR" in result.stderr
    assert result.stdout == "true\nfalse\nfalse\ntrue\n"


@REQUIRES_WINDOWS_VM
def test_a_lock_of_a_task_and_of_main_frees_when_its_owner_ends(root, work):
    target, bytecode = _lock_case(root, work)
    task = compile_text(work, TASK_LOCK_PROGRAM, "windows-task-lock")
    result = run_vm(task, args=[str(target)], env=vm_environment(), cwd=root)
    assert (result.code, result.stderr) == (0, ""), result.stderr
    # The first task takes it and ends, so a later handle takes it; that handle then blocks another task until it
    # is closed. Every line is sequenced by an await.
    assert result.stdout == "true\ntrue\ntrue\nfalse\ntrue\n"
    assert _probe_lock(root, target, bytecode) == "true"


@REQUIRES_WINDOWS_VM
def test_empty_crlf_lf_unterminated_and_invalid_utf8(tmp_path, work):
    """Check ordinary-file line decoding independently of pipe support."""
    box = tmp_path
    bytecode = compile_text(work, READ_LINES_PROGRAM, "windows-lines")
    cases = (
        (b"", 1, []),
        (b"one\r\ntwo\nlast", 4, ['ok("one")', 'ok("two")', 'ok("last")']),
        (b"\n\r\n", 3, ['ok("")', 'ok("")']),
        (b"\xff\n", 1, []),
        (b"\xe2\x82", 1, []),
    )
    for number, (data, count, successful) in enumerate(cases):
        target = box / f"case-{number}"
        target.write_bytes(data)
        result = run_vm(
            bytecode, args=[str(target), str(count)],
            env=vm_environment(), cwd=box,
        )
        assert (result.code, result.stderr) == (0, ""), result.stderr
        lines = result.stdout.splitlines()
        assert lines[:len(successful)] == successful
        assert lines[-2].startswith("error("), lines
        assert lines[-1] == "true"


@REQUIRES_WINDOWS_VM
@pytest.mark.skipif(os.name != "nt", reason="exclusive handle probe needs Win32")
def test_each_line_closes_its_file_on_eof_callback_error_and_decode_error(tmp_path, work, adopt):
    box = tmp_path
    bytecode = compile_text(work, EACH_LINE_PROGRAM, "windows-each-line")
    kernel32 = kernel32_file_api()
    cancelled = compile_text(work, CANCELLED_LOCK_PROGRAM, "windows-cancelled-lines")
    cases = (
        (b"first\nsecond\n", "cancel", ["true", "false", "false"]),
        (b"one\r\ntwo\nlast", "all", ['"one"', '"two"', '"last"', "true"]),
        (b"one\ntwo\n", "stop", ['"one"', "false"]),
        (b"\xff\n", "all", ["false"]),
        (b"", "all", ["true"]),
    )
    for number, (data, mode, expected) in enumerate(cases):
        target = box / f"case-{number}"
        target.write_bytes(data)
        program = cancelled if mode == "cancel" else bytecode
        child = adopt(start_vm(
            program, str(target), mode, stdin=True, cwd=box
        ))
        for line in expected:
            assert child.next_line() == line
        assert child.next_line() == "ready"
        assert child.process.poll() is None
        # Zero sharing fails while any reader still has the file open.
        handle = kernel32.CreateFileW(
            str(target), 0x80000000, 0, None, 3, 0, None
        )
        try:
            assert handle != ctypes.c_void_p(-1).value, \
                ctypes.WinError(ctypes.get_last_error())
        finally:
            if handle != ctypes.c_void_p(-1).value:
                assert kernel32.CloseHandle(handle)
            child.close_stdin()
        assert child.wait() == 0


@REQUIRES_WINDOWS_VM
def test_overlong_line_returns_error_and_handle_can_be_closed(tmp_path, work):
    box = tmp_path
    target = box / "long-line"
    target.write_bytes(b"x" * (1048576 + 1))
    bytecode = compile_text(work, READ_LINES_PROGRAM, "windows-line-limit")
    result = run_vm(
        bytecode, args=[str(target), "1"], env=vm_environment(), cwd=box
    )
    assert (result.code, result.stderr) == (0, ""), result.stderr
    lines = result.stdout.splitlines()
    assert lines[0].startswith("error("), lines
    assert lines[1] == "true"
