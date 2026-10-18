"""The private BDD run-folder cleanup regression; Docker sandbox required."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

try:
    import fcntl
except ImportError:
    fcntl = None

from tests.agentica_test import cli, run, vm_environment, write_files
from tests.remove_sandbox_support import require_remove_sandbox


def make_suite(tmp_path, files, prefix):
    """A resolved folder under `tmp_path` holding the given files (name -> text)."""
    directory = Path(tempfile.mkdtemp(prefix=prefix, dir=tmp_path)).resolve()
    write_files(directory, files)
    return directory


def agentica_test(scratch, *args, env=None):
    """`agentica test` from the scratch folder; the caller passes TMPDIR in env."""
    return run(cli() + ["test", *args], env=vm_environment(env), cwd=scratch)


def test_later_run_removes_only_ended_private_folders(tmp_path):
    """Run the private handoff deletion regression only inside the sandbox."""
    scratch = make_suite(tmp_path, {"nothing.txt": ""}, "agentica-bdd-sweep-")
    require_remove_sandbox(scratch)
    temporary = scratch / "tmp"
    temporary.mkdir(0o700)
    ended = temporary / "agentica-bdd-0123456789abcdef"
    ended.mkdir()
    (ended / "lock").write_text("")
    (ended / "left.agcb").write_text("left behind")
    live = temporary / "agentica-bdd-1123456789abcdef"
    live.mkdir()
    outside = scratch / "outside"
    outside.mkdir()
    (outside / "lock").write_text("keep")
    os.symlink(outside, temporary / "agentica-bdd-fedcba9876543210")
    (temporary / "agentica-bdd-00ff").mkdir()
    (temporary / "agentica-bdd-new-0123").mkdir()
    # A run killed while it made its folder leaves a `new-` one: it goes only when it is old and has a free lock.
    stale = temporary / "agentica-bdd-new-aaaa"
    stale.mkdir()
    (stale / "lock").write_text("")
    os.utime(stale, (1, 1))
    fresh = temporary / "agentica-bdd-new-bbbb"
    fresh.mkdir()
    (fresh / "lock").write_text("")
    old_without_lock = temporary / "agentica-bdd-new-cccc"
    old_without_lock.mkdir()
    os.utime(old_without_lock, (1, 1))
    # A held lock is what tells a live run from an ended one.
    with open(live / "lock", "w") as held:
        assert fcntl is not None
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = agentica_test(scratch, scratch / "missing.feature", env={"TMPDIR": temporary})
    assert result.code == 2
    assert sorted(os.listdir(temporary)) == [
        "agentica-bdd-00ff", "agentica-bdd-1123456789abcdef", "agentica-bdd-fedcba9876543210",
        "agentica-bdd-new-0123", "agentica-bdd-new-bbbb", "agentica-bdd-new-cccc"]
    assert (outside / "lock").read_text() == "keep"
