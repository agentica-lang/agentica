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

    def test_a_directory_and_a_private_file_report_the_same_zero_owner(self) -> None:
        directory = self.root / "directory"
        directory.mkdir()
        kind, mode, user_id, group_id = self.metadata(directory)
        self.assertEqual((kind, mode, user_id, group_id), ("directory", str(WRITABLE_MODE), "0", "0"))

        private = self.root / "private.txt"
        private.write_text("private", encoding="utf-8")
        self.assertEqual(self.metadata(private)[2:], ["0", "0"])


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

    def test_a_lock_of_a_task_and_of_main_frees_when_its_owner_ends(self) -> None:
        bytecode = self.compile_text(TASK_LOCK_PROGRAM, "windows-task-lock")
        result = run_vm(bytecode, args=[str(self.target)], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
        # The first task takes it and ends, so a later handle takes it; that handle then blocks another task until it
        # is closed. Every line is sequenced by an await.
        self.assertEqual(result.stdout, "true\ntrue\ntrue\nfalse\ntrue\n")
        self.assertEqual(self.probe(), "true")
