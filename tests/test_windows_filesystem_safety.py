"""Windows filesystem mutation regressions in disposable Docker or Actions scratch."""

from __future__ import annotations

import ctypes
import os
import subprocess
import threading
import time
import unittest

from tests.agentica_test import TestCase, run_vm, start_vm, vm_environment
from tests.remove_sandbox_support import require_remove_sandbox

REMOVE_PROGRAM = """\
def main() -> Void
  result = Path.remove(System.args()[0], 5000)
  puts(result.ok?)
end
"""

RENAME_PROGRAM = """\
def main() -> Void
  base = System.args()[0]
  puts(Path.rename(base + "/source", base + "/occupied", 5000).ok?)
  puts(Path.rename(base + "/source", base + "/moved", 5000).ok?)
  puts(Path.rename(base + "/directory", base + "/moved-directory", 5000).ok?)
  puts(Path.rename(base + "/missing", base + "/missing-target", 5000).ok?)
end
"""

RACE_PROGRAM = """\
def main() -> Void
  args = System.args()
  puts(Path.rename(args[0], args[1], 5000).ok?)
end
"""

REMOVE_RACE_PROGRAM = """\
def main() -> Void
  puts("ready")
  IO.flush()
  puts(Path.remove(System.args()[0], 30000).ok?)
end
"""


@unittest.skipUnless(
    os.environ.get("AGENTICA_TEST_TARGET_OS") == "windows" and os.environ.get("AGENTICA_TEST_WINE") != "1",
    "requires the native Windows VM and scratch",
)
class WindowsFilesystemMutationTests(TestCase):
    """Check Windows filesystem mutations in runner-owned scratch."""

    def setUp(self) -> None:
        self.root = self.make_temp_dir("agentica-windows-remove-").resolve()
        require_remove_sandbox(self.root)

    def test_remove_recurses_without_following_junctions_and_refuses_unsafe_paths(self) -> None:
        victim = self.root / "victim"
        nested = victim / "nested"
        outside = self.root / "outside"
        junction = victim / "junction"
        victim.mkdir()
        nested.mkdir()
        outside.mkdir()
        (nested / "file").write_text("remove me", encoding="utf-8")
        sentinel = outside / "keep"
        sentinel.write_text("outside sentinel", encoding="utf-8")
        link = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(junction), str(outside)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(link.returncode, 0, link.stdout + link.stderr)

        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-tree")
        result = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stdout, result.stderr), (0, "true\n", ""))
        self.assertFalse(victim.exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside sentinel")

        root_result = run_vm(bytecode, args=[str(self.root.anchor)], env=vm_environment(), cwd=self.root)
        parent_result = run_vm(bytecode, args=[str(self.root / "..")], env=vm_environment(), cwd=self.root)
        device_result = run_vm(bytecode, args=[str(self.root / "NUL")], env=vm_environment(), cwd=self.root)
        self.assertEqual((root_result.code, root_result.stdout), (0, "false\n"))
        self.assertEqual((parent_result.code, parent_result.stdout), (0, "false\n"))
        self.assertEqual((device_result.code, device_result.stdout), (0, "false\n"))
        self.assertTrue(self.root.is_dir())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside sentinel")

    def test_remove_fails_closed_when_an_existing_handle_allows_rename(self) -> None:
        victim = self.root / "busy-directory"
        victim.mkdir()
        (victim / "keep").write_text("keep until handle closes", encoding="utf-8")
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                         ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        kernel32.CreateFileW.restype = ctypes.c_void_p
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_int
        handle = kernel32.CreateFileW(str(victim), 0x00010000, 0x00000007, None, 3, 0x02000000, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value, ctypes.WinError(ctypes.get_last_error()))
        try:
            bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-busy-directory")
            blocked = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
            self.assertEqual((blocked.code, blocked.stdout), (0, "false\n"))
            self.assertTrue((victim / "keep").exists())
        finally:
            self.assertTrue(kernel32.CloseHandle(handle))

        removed = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
        self.assertEqual((removed.code, removed.stdout), (0, "true\n"))
        self.assertFalse(victim.exists())

    def test_remove_refuses_a_reparse_ancestor(self) -> None:
        outside = self.root / "outside"
        ancestor = self.root / "ancestor"
        target = outside / "target"
        outside.mkdir()
        target.write_text("outside sentinel", encoding="utf-8")
        link = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(ancestor), str(outside)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(link.returncode, 0, link.stdout + link.stderr)

        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-reparse-ancestor")
        result = run_vm(bytecode, args=[str(ancestor / "target")], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stdout), (0, "false\n"))
        self.assertEqual(target.read_text(encoding="utf-8"), "outside sentinel")

    def test_remove_deletes_files_and_treats_missing_paths_as_success(self) -> None:
        victim = self.root / "victim"
        victim.write_text("remove me", encoding="utf-8")
        unicode_victim = self.root / "café-雪.txt"
        unicode_victim.write_text("unicode", encoding="utf-8")
        long_victim = self.root / ("n" * 240)
        long_victim.write_text("long name", encoding="utf-8")
        missing = self.root / "missing"
        traversed_target = self.root / "traversed"
        traversed_target.write_text("remove through normalized parent", encoding="utf-8")
        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-file")

        removed = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
        unicode_removed = run_vm(bytecode, args=[str(unicode_victim)], env=vm_environment(), cwd=self.root)
        long_removed = run_vm(bytecode, args=[str(long_victim)], env=vm_environment(), cwd=self.root)
        absent = run_vm(bytecode, args=[str(missing)], env=vm_environment(), cwd=self.root)
        traversed = run_vm(bytecode, args=[str(self.root / "unused" / ".." / "traversed")], env=vm_environment(), cwd=self.root)

        self.assertEqual((removed.code, removed.stdout, removed.stderr), (0, "true\n", ""))
        self.assertEqual((unicode_removed.code, unicode_removed.stdout, unicode_removed.stderr), (0, "true\n", ""))
        self.assertEqual((long_removed.code, long_removed.stdout, long_removed.stderr), (0, "true\n", ""))
        self.assertEqual((absent.code, absent.stdout, absent.stderr), (0, "true\n", ""))
        self.assertEqual((traversed.code, traversed.stdout, traversed.stderr), (0, "true\n", ""))
        self.assertFalse(victim.exists())
        self.assertFalse(unicode_victim.exists())
        self.assertFalse(long_victim.exists())
        self.assertFalse(traversed_target.exists())

    def test_remove_pins_ancestors_during_concurrent_replacement(self) -> None:
        anchor = self.root / "anchor"
        moved = self.root / "anchor-moved"
        tree = anchor / "tree"
        outside = self.root / "outside"
        anchor.mkdir()
        tree.mkdir()
        outside.mkdir()
        outside_tree = outside / "tree"
        outside_tree.mkdir()
        sentinel = outside_tree / "keep"
        sentinel.write_text("outside sentinel", encoding="utf-8")
        for number in range(1200):
            (tree / f"item-{number}.dat").write_text("remove", encoding="utf-8")

        bytecode = self.compile_text(REMOVE_RACE_PROGRAM, "windows-remove-ancestor-race")
        child = self.adopt(start_vm(bytecode, str(tree), cwd=self.root))
        self.assertEqual(child.next_line(), "ready")
        stop = threading.Event()
        blocked = threading.Event()
        swapped = threading.Event()

        def replace_ancestor() -> None:
            while not stop.is_set() and child.process.poll() is None:
                try:
                    anchor.rename(moved)
                except OSError as error:
                    if getattr(error, "winerror", None) in (5, 32, 33):
                        blocked.set()
                        return
                    time.sleep(0.001)
                    continue
                swapped.set()
                subprocess.run(
                    ["cmd.exe", "/d", "/c", "mklink", "/J", str(anchor), str(outside)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                return

        racer = threading.Thread(target=replace_ancestor)
        racer.start()
        answer = child.next_line()
        stop.set()
        racer.join(5)
        self.assertFalse(racer.is_alive())
        self.assertTrue(blocked.is_set() or swapped.is_set(), "replacement attempt did not reach the filesystem")
        self.assertIn(answer, ("true", "false"))
        self.assertEqual(child.wait(), 0)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside sentinel")

    def test_rename_is_atomic_non_replacing_and_moves_directories(self) -> None:
        source = self.root / "source"
        occupied = self.root / "occupied"
        moved = self.root / "moved"
        directory = self.root / "directory"
        moved_directory = self.root / "moved-directory"
        source.write_text("source contents", encoding="utf-8")
        occupied.write_text("keep destination", encoding="utf-8")
        directory.mkdir()
        (directory / "inside").write_text("inside contents", encoding="utf-8")
        occupied_identity = occupied.stat().st_dev, occupied.stat().st_ino

        bytecode = self.compile_text(RENAME_PROGRAM, "windows-rename")
        result = run_vm(bytecode, args=[str(self.root)], env=vm_environment(), cwd=self.root)

        self.assertEqual((result.code, result.stdout, result.stderr), (0, "false\ntrue\ntrue\nfalse\n", ""))
        self.assertEqual(occupied.read_text(encoding="utf-8"), "keep destination")
        self.assertEqual((occupied.stat().st_dev, occupied.stat().st_ino), occupied_identity)
        self.assertFalse(source.exists())
        self.assertEqual(moved.read_text(encoding="utf-8"), "source contents")
        self.assertFalse(directory.exists())
        self.assertEqual((moved_directory / "inside").read_text(encoding="utf-8"), "inside contents")

    def test_rename_race_has_one_winner_and_preserves_losing_sources(self) -> None:
        bytecode = self.compile_text(RACE_PROGRAM, "windows-rename-race")
        target = self.root / "target"
        sources = []
        for number in range(6):
            source = self.root / f"source-{number}"
            source.write_text(str(number), encoding="utf-8")
            sources.append(source)

        racers = [self.adopt(start_vm(bytecode, str(source), str(target), cwd=self.root)) for source in sources]
        answers = [racer.next_line() for racer in racers]
        for racer in racers:
            self.assertEqual(racer.wait(), 0)

        self.assertEqual(sorted(answers), ["false"] * 5 + ["true"])
        winner = answers.index("true")
        self.assertEqual(target.read_text(encoding="utf-8"), str(winner))
        for number, source in enumerate(sources):
            self.assertEqual(source.exists(), number != winner)


@unittest.skipUnless(os.environ.get("AGENTICA_TEST_TARGET_OS") == "windows", "requires the Windows VM")
class WindowsPathRefusalTests(TestCase):
    """Check root and dot-component refusals without mutating the filesystem."""

    def test_roots_and_final_dot_components_are_refused(self) -> None:
        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-refusal")
        paths = ("C:\\", "C:", "C:\\parent\\..", "\\\\server\\share")
        for path in paths:
            with self.subTest(path=path):
                result = run_vm(bytecode, args=[path], env=vm_environment(), cwd=os.getcwd())
                self.assertEqual((result.code, result.stdout, result.stderr), (0, "false\n", ""))
