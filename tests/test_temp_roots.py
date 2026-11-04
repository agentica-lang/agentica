"""The temporary roots of the test runs stay bounded: one run kept per root, and stale roots swept."""

import os
import subprocess
import sys
from pathlib import Path

from tests.agentica_test import ROOT
from tests.temp_roots import STALE_AFTER_SECONDS, sweep_stale_roots

NOW = 1_000_000_000.0


def make_root(owner: Path, name: str, age: float) -> Path:
    root = owner / name
    (root / "pytest-0").mkdir(parents=True)
    (root / "pytest-0" / "file").write_text("x")
    os.utime(root, (NOW - age, NOW - age))
    return root


def test_sweep_removes_only_stale_roots(tmp_path):
    owner = tmp_path / "agc-0"
    owner.mkdir()
    current = make_root(owner, "aaaaaa", 3 * STALE_AFTER_SECONDS)
    stale = make_root(owner, "bbbbbb", 2 * STALE_AFTER_SECONDS)
    fresh = make_root(owner, "cccccc", STALE_AFTER_SECONDS // 2)
    target = tmp_path / "elsewhere"
    target.mkdir()
    if os.name != "nt":
        (owner / "link").symlink_to(target)

    sweep_stale_roots(owner, current, now=NOW)

    assert current.exists() and fresh.exists() and target.exists()
    assert not stale.exists()
    sweep_stale_roots(tmp_path / "missing", current, now=NOW)


def test_two_sessions_keep_one_run_in_a_root(tmp_path):
    """Two pytest sessions of the same module set leave one numbered folder, not three as pytest does by default."""
    project = tmp_path / "project"
    project.mkdir()
    (project / "conftest.py").write_text(
        "from tests.temp_roots import assign_root\n\n\ndef pytest_configure(config):\n    assign_root(config)\n"
    )
    (project / "test_inner.py").write_text("def test_it(tmp_path):\n    (tmp_path / 'f').write_text('x')\n")
    temp = tmp_path / "tmp"
    temp.mkdir()
    env = {k: v for k, v in os.environ.items() if k != "PYTEST_DEBUG_TEMPROOT"}
    env.update(TMPDIR=str(temp), TMP=str(temp), TEMP=str(temp), PYTHONPATH=str(ROOT))
    for _ in range(3):
        done = subprocess.run(
            [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-c", str(ROOT / "pyproject.toml"),
             "--rootdir", str(project), str(project)],
            env=env, capture_output=True, text=True, check=False, timeout=120,
        )
        assert done.returncode == 0, done.stdout + done.stderr
    roots = [root for owner in temp.glob("agc*") for root in owner.iterdir()]
    assert len(roots) == 1
    assert len(list(roots[0].glob("pytest-of-*/pytest-[0-9]*"))) == 1
