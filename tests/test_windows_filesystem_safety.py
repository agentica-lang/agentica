"""Windows filesystem mutation regressions in disposable Docker or Actions scratch."""

from __future__ import annotations

import os
import subprocess

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


class WindowsFilesystemMutationTests(TestCase):
    """Check Windows filesystem mutations in runner-owned scratch."""

    def setUp(self) -> None:
        if os.environ.get("AGENTICA_TEST_TARGET_OS") != "windows":
            self.fail("this regression requires the Windows VM")
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

    def test_remove_deletes_files_and_treats_missing_paths_as_success(self) -> None:
        victim = self.root / "victim"
        victim.write_text("remove me", encoding="utf-8")
        missing = self.root / "missing"
        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-file")

        removed = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
        absent = run_vm(bytecode, args=[str(missing)], env=vm_environment(), cwd=self.root)

        self.assertEqual((removed.code, removed.stdout, removed.stderr), (0, "true\n", ""))
        self.assertEqual((absent.code, absent.stdout, absent.stderr), (0, "true\n", ""))
        self.assertFalse(victim.exists())

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
