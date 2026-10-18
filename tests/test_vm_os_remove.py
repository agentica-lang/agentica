"""Removal and rename regressions; these cases require the Docker sandbox."""

import os
import stat

import pytest

from tests.agentica_test import run_vm, start_vm, vm_environment
from tests.vm_os_support import (CONTENTION_PROGRAM, PROTOCOL_PROGRAM, RACE_PROGRAM, _RaceCase, compile_text,
                                 rename_never_replaces_and_moves_a_link_as_a_link, run_program,
                                 sandbox_root as root, system_pid_is_the_vm_process_and_the_parent_a_child_sees,
                                 work)
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


def prepare_trees(root):
    """Build the link-rich trees the removal cases delete (links only, targets stay outside)."""
    outside = root / "outside"
    (outside / "keep-dir").mkdir(parents=True)
    (outside / "keep.txt").write_text("keep")
    tree = root / "tree"
    (tree / "sub" / "deeper").mkdir(parents=True)
    (tree / "sub" / "deeper" / "f.txt").write_text("f")
    (tree / "top.txt").write_text("top")
    os.symlink(outside, tree / "to-dir")
    os.symlink("../../outside/keep.txt", tree / "sub" / "to-file")
    os.symlink("/does/not/exist", tree / "dangling")
    os.mkfifo(tree / "pipe")
    os.symlink(outside, root / "root-link")
    os.symlink(outside, root / "other-link")
    os.symlink(outside / "keep.txt", root / "file-link")
    (root / "plain.txt").write_text("plain")
    (root / "real-dir" / "sub").mkdir(parents=True)
    (root / "real-dir" / "sub" / "b.txt").write_text("b")
    (root / "guarded" / "sub").mkdir(parents=True)
    (root / "guarded" / "sub" / "keep.txt").write_text("keep")
    deep = root / "deep"
    deep.mkdir()
    path = str(deep)
    for _ in range(TREE_DEPTH):
        path += "/d"
        os.mkdir(path)


def test_private_bytecode_handoff_is_consumed_only_inside_sandbox(root, work, adopt):
    system_pid_is_the_vm_process_and_the_parent_a_child_sees(root, work, adopt)


def test_remove_deletes_links_as_links_never_follows_them_and_refuses_unsafe_roots(root, work):
    prepare_trees(root)
    lines = run_program(
        root,
        work,
        REMOVE_PROGRAM,
        "remove",
        root,
        cwd=root / "guarded" / "sub",
    )
    refused = 'error("filesystem: refusing to remove /, . or ..")'
    assert lines == [
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
    ]
    assert (root / "guarded" / "sub" / "keep.txt").read_text() == "keep"
    assert not (root / "tree").exists()
    assert (root / "outside" / "keep.txt").read_text() == "keep"
    assert (root / "outside" / "keep-dir").is_dir()
    assert not (root / "root-link").is_symlink()
    assert (root / "other-link").is_symlink()
    assert not (root / "file-link").is_symlink()
    assert not (root / "plain.txt").exists()
    assert not (root / "real-dir").exists()
    assert (root / "deep").is_dir()


@pytest.mark.skipif(os.geteuid() == 0, reason="root ignores the permission bits")
def test_remove_names_the_entry_that_failed_and_leaves_the_rest(root, work):
    tree = root / "tree"
    (tree / "a" / "locked").mkdir(parents=True)
    (tree / "a" / "locked" / "f.txt").write_text("f")
    (tree / "z.txt").write_text("z")
    os.chmod(tree / "a" / "locked", 0o500)
    try:
        text = """\
def main() -> Void
  IO.inspect(Path.remove(System.args()[0] + "/tree", 5000))
end
"""
        lines = run_program(root, work, text, "named", root)
        assert lines == [
            'error("filesystem: cannot remove path\\n  path: %s/tree/a/locked/f.txt\\n  system error: '
            'Permission denied; errno=13")' % root
        ]
        assert (tree / "a" / "locked" / "f.txt").exists()
    finally:
        os.chmod(tree / "a" / "locked", 0o700)


def test_remove_error_path_preserves_file_and_names_the_os_reason(root, work):
    path = root / "plain.txt"
    path.write_text("plain")
    text = """\
def main() -> Void
  IO.inspect(Path.remove(System.args()[0] + "/plain.txt/x", 5000))
end
"""
    lines = run_program(root, work, text, "remove-error", root)
    assert lines == [
        'error("filesystem: cannot remove path\\n  path: %s/plain.txt/x\\n  system error: '
        'Not a directory; errno=20")' % root
    ]
    assert path.read_text() == "plain"


def test_rename_keeps_lock_owner_across_the_final_name(root, work, adopt):
    bytecode = compile_text(work, CONTENTION_PROGRAM, "contention")

    def probe(name: str) -> str:
        result = run_vm(
            bytecode,
            args=[str(root / name / "lock"), "probe"],
            env=vm_environment(),
            cwd=root,
        )
        assert (result.code, result.stderr) == (0, "")
        return result.stdout.strip()

    holder = adopt(
        start_vm(
            compile_text(work, PROTOCOL_PROGRAM, "protocol"),
            str(root),
            stdin=True,
            cwd=root,
        )
    )
    assert holder.next_line() == "true"
    assert holder.next_line() == "renamed"
    assert not (root / "new-dir").exists()
    assert stat.S_IMODE((root / "final-dir").stat().st_mode) == 0o700
    assert probe("final-dir") == "false"
    holder.close_stdin()
    assert holder.wait() == 0
    assert probe("final-dir") == "true"


def test_rename_never_replaces_and_moves_a_link_as_a_link(root, work):
    rename_never_replaces_and_moves_a_link_as_a_link(root, work)


def test_rename_race_has_one_winner_and_preserves_all_losing_sources(root, work, adopt):
    bytecode = compile_text(work, RACE_PROGRAM, "race")
    assert_rename_race(_RaceCase(adopt), bytecode, root, lambda number: f"source{number}")
