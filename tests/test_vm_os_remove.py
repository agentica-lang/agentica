"""Removal and rename regressions; these cases require the Docker sandbox."""

import os
import stat
import unittest

from tests import test_vm_os as os_tests
from tests.agentica_test import run_vm, start_vm, vm_environment
from tests.remove_sandbox_support import require_remove_sandbox
from tests.windows_support import assert_rename_race

TREE_DEPTH = 130
REMOVE_PROGRAM = """\
def main() -> Void
  base = System.args()[0]
  IO.inspect(Path.remove(base + "/tree", 5000))
  IO.inspect(Path.remove(base + "/root-link", 5000))
  IO.inspect(Path.remove(base + "/root-link", 5000))
  IO.inspect(Path.remove(base + "/other-link/", 5000).ok?)
  IO.inspect(Path.remove(base + "/missing", 5000))
  IO.inspect(Path.remove(base + "/plain.txt/x", 5000).ok?)
  IO.inspect(Path.remove(base + "/guarded/sub/..", 5000))
  IO.inspect(Path.remove(base + "/guarded/sub/../", 5000))
  IO.inspect(Path.remove(".", 5000))
  IO.inspect(Path.remove("..", 5000))
  IO.inspect(Path.remove("../.", 5000))
  IO.inspect(Path.remove(base + "/deep", 5000))
  IO.inspect(Path.remove(base + "/file-link", 5000))
  IO.inspect(Path.remove(base + "/plain.txt", 5000))
  IO.inspect(Path.remove(base + "/real-dir", 5000))
end
"""


class OsRemoveBuiltins(os_tests.OsBuiltinsBase):
    """Exercise mutating Path APIs only inside Docker locally or Actions scratch in CI."""

    def setUp(self) -> None:
        super().setUp()
        require_remove_sandbox(self.root)

    def prepare_trees(self) -> None:
        outside = self.root / "outside"
        (outside / "keep-dir").mkdir(parents=True)
        (outside / "keep.txt").write_text("keep")
        tree = self.root / "tree"
        (tree / "sub" / "deeper").mkdir(parents=True)
        (tree / "sub" / "deeper" / "f.txt").write_text("f")
        (tree / "top.txt").write_text("top")
        os.symlink(outside, tree / "to-dir")
        os.symlink("../../outside/keep.txt", tree / "sub" / "to-file")
        os.symlink("/does/not/exist", tree / "dangling")
        os.mkfifo(tree / "pipe")
        os.symlink(outside, self.root / "root-link")
        os.symlink(outside, self.root / "other-link")
        os.symlink(outside / "keep.txt", self.root / "file-link")
        (self.root / "plain.txt").write_text("plain")
        (self.root / "real-dir" / "sub").mkdir(parents=True)
        (self.root / "real-dir" / "sub" / "b.txt").write_text("b")
        (self.root / "guarded" / "sub").mkdir(parents=True)
        (self.root / "guarded" / "sub" / "keep.txt").write_text("keep")
        deep = self.root / "deep"
        deep.mkdir()
        path = str(deep)
        for _ in range(TREE_DEPTH):
            path += "/d"
            os.mkdir(path)

    def test_private_bytecode_handoff_is_consumed_only_inside_sandbox(self) -> None:
        os_tests.OsBuiltins._system_pid_is_the_vm_process_and_the_parent_a_child_sees(self)

    def test_remove_deletes_links_as_links_never_follows_them_and_refuses_unsafe_roots(self) -> None:
        self.prepare_trees()
        lines = self.run_program(
            REMOVE_PROGRAM,
            "remove",
            self.root,
            cwd=self.root / "guarded" / "sub",
        )
        refused = 'error("filesystem: refusing to remove /, . or ..")'
        self.assertEqual(
            lines,
            [
                "ok()",
                "ok()",
                "ok()",
                "false",
                "ok()",
                "false",
                refused,
                refused,
                refused,
                refused,
                refused,
                'error("filesystem: directory tree is deeper than 128 levels")',
                "ok()",
                "ok()",
                "ok()",
            ],
        )
        self.assertEqual((self.root / "guarded" / "sub" / "keep.txt").read_text(), "keep")
        self.assertFalse((self.root / "tree").exists())
        self.assertEqual((self.root / "outside" / "keep.txt").read_text(), "keep")
        self.assertTrue((self.root / "outside" / "keep-dir").is_dir())
        self.assertFalse((self.root / "root-link").is_symlink())
        self.assertTrue((self.root / "other-link").is_symlink())
        self.assertFalse((self.root / "file-link").is_symlink())
        self.assertFalse((self.root / "plain.txt").exists())
        self.assertFalse((self.root / "real-dir").exists())
        self.assertTrue((self.root / "deep").is_dir())

    @unittest.skipIf(os.geteuid() == 0, "root ignores the permission bits")
    def test_remove_names_the_entry_that_failed_and_leaves_the_rest(self) -> None:
        tree = self.root / "tree"
        (tree / "a" / "locked").mkdir(parents=True)
        (tree / "a" / "locked" / "f.txt").write_text("f")
        (tree / "z.txt").write_text("z")
        os.chmod(tree / "a" / "locked", 0o500)
        self.addCleanup(os.chmod, tree / "a" / "locked", 0o700)
        text = """\
def main() -> Void
  IO.inspect(Path.remove(System.args()[0] + "/tree", 5000))
end
"""
        lines = self.run_program(text, "named", self.root)
        self.assertEqual(
            lines,
            [
                'error("filesystem: cannot remove path\\n  path: %s/tree/a/locked/f.txt\\n  system error: '
                'Permission denied; errno=13")' % self.root
            ],
        )
        self.assertTrue((tree / "a" / "locked" / "f.txt").exists())

    def test_remove_error_path_preserves_file_and_names_the_os_reason(self) -> None:
        path = self.root / "plain.txt"
        path.write_text("plain")
        text = """\
def main() -> Void
  IO.inspect(Path.remove(System.args()[0] + "/plain.txt/x", 5000))
end
"""
        lines = self.run_program(text, "remove-error", self.root)
        self.assertEqual(
            lines,
            [
                'error("filesystem: cannot remove path\\n  path: %s/plain.txt/x\\n  system error: '
                'Not a directory; errno=20")' % self.root
            ],
        )
        self.assertEqual(path.read_text(), "plain")

    def test_rename_keeps_lock_owner_across_the_final_name(self) -> None:
        bytecode = self.program(os_tests.CONTENTION_PROGRAM, "contention")

        def probe(name: str) -> str:
            result = run_vm(
                bytecode,
                args=[str(self.root / name / "lock"), "probe"],
                env=vm_environment(),
                cwd=self.root,
            )
            self.assertEqual((result.code, result.stderr), (0, ""))
            return result.stdout.strip()

        holder = self.adopt(
            start_vm(
                self.program(os_tests.PROTOCOL_PROGRAM, "protocol"),
                str(self.root),
                stdin=True,
                cwd=self.root,
            )
        )
        self.assertEqual(holder.next_line(), "true")
        self.assertEqual(holder.next_line(), "renamed")
        self.assertFalse((self.root / "new-dir").exists())
        self.assertEqual(stat.S_IMODE((self.root / "final-dir").stat().st_mode), 0o700)
        self.assertEqual(probe("final-dir"), "false")
        holder.close_stdin()
        self.assertEqual(holder.wait(), 0)
        self.assertEqual(probe("final-dir"), "true")

    def test_rename_never_replaces_and_moves_a_link_as_a_link(self) -> None:
        os_tests.OsBuiltins._rename_never_replaces_and_moves_a_link_as_a_link(self)

    def test_rename_race_has_one_winner_and_preserves_all_losing_sources(self) -> None:
        bytecode = self.program(os_tests.RACE_PROGRAM, "race")
        assert_rename_race(self, bytecode, self.root, lambda number: f"source{number}")
