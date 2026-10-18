"""Windows metadata values and file locks, run on the native Windows runner."""

from __future__ import annotations

import os
import stat
import unittest

from tests.agentica_test import TARGET_OS, TestCase, run_vm, start_vm, vm_environment

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
  file = Result.unwrap!(File.open(context.path, "read", 5000))
  puts(Result.unwrap!(File.try_lock(file, 5000)))
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


@unittest.skipUnless(TARGET_OS == "windows", "requires the native Windows VM")
class WindowsMetadataTests(TestCase):
    """Check the metadata values the Windows platform really reports."""

    def setUp(self) -> None:
        self.root = self.make_temp_dir("agentica-windows-metadata-").resolve()
        self.bytecode = self.compile_text(METADATA_PROGRAM, "windows-metadata")

    def metadata(self, path) -> list[str]:
        result = run_vm(self.bytecode, args=[str(path)], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
        return result.stdout.split()

    def test_a_regular_file_reports_no_owner_and_only_the_read_only_attribute(self) -> None:
        target = self.root / "plain.txt"
        target.write_text("plain", encoding="utf-8")
        kind, mode, user_id, group_id = self.metadata(target)
        self.assertEqual(kind, "file")
        self.assertEqual(mode, str(WRITABLE_MODE))
        # A 0 here is not an owner: the platform has no Unix owner ids, so the fields carry nothing to look up.
        self.assertEqual((user_id, group_id), ("0", "0"))

        os.chmod(target, stat.S_IREAD)
        kind, mode, user_id, group_id = self.metadata(target)
        self.assertEqual((kind, mode, user_id, group_id), ("file", str(READ_ONLY_MODE), "0", "0"))

        os.chmod(target, stat.S_IWRITE)
        self.assertEqual(self.metadata(target)[1], str(WRITABLE_MODE))

    def test_a_directory_reports_the_same_zero_owner(self) -> None:
        directory = self.root / "directory"
        directory.mkdir()
        kind, mode, user_id, group_id = self.metadata(directory)
        self.assertEqual((kind, mode, user_id, group_id), ("directory", str(WRITABLE_MODE), "0", "0"))

    # Wine answers access denied for the restricted creators: it does not implement the owner and DACL the adapter sets
    # and then checks on the object it opened, so this case is evidence from the native runner only.
    @unittest.skipIf(os.environ.get("AGENTICA_TEST_WINE") == "1", "Wine cannot make the restricted object")
    def test_the_restricted_creators_make_entries_that_report_the_same_zero_owner(self) -> None:
        private_file = self.root / "private.txt"
        private_directory = self.root / "private-directory"
        bytecode = self.compile_text(PRIVATE_PROGRAM, "windows-private")
        result = run_vm(bytecode, args=[str(private_file), str(private_directory)], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [f"file {WRITABLE_MODE} 0 0", f"directory {WRITABLE_MODE} 0 0"],
        )
        self.assertEqual(self.metadata(private_file)[2:], ["0", "0"])
        self.assertTrue(private_directory.is_dir())


@unittest.skipUnless(TARGET_OS == "windows", "requires the native Windows VM")
class WindowsLockTests(TestCase):
    """Check that a Windows lock contends across processes and dies with its holder."""

    def setUp(self) -> None:
        self.root = self.make_temp_dir("agentica-windows-lock-").resolve()
        self.target = self.root / "lock"
        self.target.write_text("", encoding="utf-8")
        self.bytecode = self.compile_text(CONTENTION_PROGRAM, "windows-contention")

    def probe(self) -> str:
        """Ask another process for the lock; "true" or "false", never a timeout."""
        result = run_vm(self.bytecode, args=[str(self.target), "probe"], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
        return result.stdout.strip()

    def holder(self):
        """A process holding the lock and waiting on stdin, adopted so the test always stops it."""
        child = self.adopt(start_vm(self.bytecode, str(self.target), "hold", stdin=True, cwd=self.root))
        self.assertEqual(child.next_line(), "true")
        self.assertEqual(child.next_line(), "ready")
        return child

    def test_a_lock_contends_across_processes_and_frees_when_the_holder_ends(self) -> None:
        self.assertEqual(self.probe(), "true")
        holder = self.holder()
        try:
            self.assertEqual(self.probe(), "false")
        finally:
            holder.close_stdin()
        self.assertEqual(holder.wait(), 0)
        self.assertIsNotNone(holder.process.poll())
        self.assertEqual(self.probe(), "true")

    def test_a_killed_holder_frees_the_lock(self) -> None:
        holder = self.holder()
        try:
            self.assertEqual(self.probe(), "false")
        finally:
            holder.stop()
        self.assertIsNotNone(holder.process.poll(), "the holder process must be gone before the lock is asked for")
        self.assertEqual(self.probe(), "true")

    def test_cancelled_owner_releases_its_lock_without_ending_the_process(self) -> None:
        bytecode = self.compile_text(CANCELLED_LOCK_PROGRAM, "windows-cancelled-lock")
        result = run_vm(
            bytecode, args=[str(self.target)], env=vm_environment(), cwd=self.root
        )
        self.assertEqual(result.code, 0, result.stderr)
        self.assertIn("RUNTIME-UNWRAP-ERROR", result.stderr)
        self.assertEqual(result.stdout, "true\nfalse\nfalse\ntrue\n")

    def test_a_lock_of_a_task_and_of_main_frees_when_its_owner_ends(self) -> None:
        bytecode = self.compile_text(TASK_LOCK_PROGRAM, "windows-task-lock")
        result = run_vm(bytecode, args=[str(self.target)], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
        # The first task takes it and ends, so a later handle takes it; that handle then blocks another task until it
        # is closed. Every line is sequenced by an await.
        self.assertEqual(result.stdout, "true\ntrue\ntrue\nfalse\ntrue\n")
        self.assertEqual(self.probe(), "true")


@unittest.skipUnless(TARGET_OS == "windows", "requires the Windows VM")
class WindowsLineTests(TestCase):
    """Check ordinary-file line decoding independently of pipe support."""

    def test_empty_crlf_lf_unterminated_and_invalid_utf8(self) -> None:
        root = self.make_temp_dir("agentica-windows-lines-")
        bytecode = self.compile_text(READ_LINES_PROGRAM, "windows-lines")
        cases = (
            (b"", 1, []),
            (b"one\r\ntwo\nlast", 4, ['ok("one")', 'ok("two")', 'ok("last")']),
            (b"\n\r\n", 3, ['ok("")', 'ok("")']),
            (b"\xff\n", 1, []),
            (b"\xe2\x82", 1, []),
        )
        for number, (data, count, successful) in enumerate(cases):
            with self.subTest(data=data):
                target = root / f"case-{number}"
                target.write_bytes(data)
                result = run_vm(
                    bytecode, args=[str(target), str(count)],
                    env=vm_environment(), cwd=root,
                )
                self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
                lines = result.stdout.splitlines()
                self.assertEqual(lines[:len(successful)], successful)
                self.assertTrue(lines[-2].startswith("error("), lines)
                self.assertEqual(lines[-1], "true")

    def test_overlong_line_returns_error_and_handle_can_be_closed(self) -> None:
        root = self.make_temp_dir("agentica-windows-line-limit-")
        target = root / "long-line"
        target.write_bytes(b"x" * (1048576 + 1))
        bytecode = self.compile_text(READ_LINES_PROGRAM, "windows-line-limit")
        result = run_vm(
            bytecode, args=[str(target), "1"], env=vm_environment(), cwd=root
        )
        self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
        lines = result.stdout.splitlines()
        self.assertTrue(lines[0].startswith("error("), lines)
        self.assertEqual(lines[1], "true")
