"""The temporary roots of the test runs stay bounded: one run kept per root, and stale roots swept."""

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

from tests import temp_roots
from tests.agentica_test import ROOT
from tests.temp_roots import STALE_AFTER_SECONDS, SWEEP_PREFIX, sweep_stale_roots

NOW = 1_000_000_000.0
OLD = 3 * STALE_AFTER_SECONDS


def make_root(owner: Path, name: str, age: float, files: int = 1) -> Path:
    root = owner / name
    (root / "pytest-0").mkdir(parents=True)
    for number in range(files):
        (root / "pytest-0" / f"file{number}").write_text("x")
    os.utime(root, (NOW - age, NOW - age))
    return root


def test_sweep_removes_only_stale_roots(tmp_path):
    owner = tmp_path / "agc-0"
    owner.mkdir()
    current = make_root(owner, "aaaaaa", OLD)
    stale = make_root(owner, "bbbbbb", 2 * STALE_AFTER_SECONDS)
    fresh = make_root(owner, "cccccc", STALE_AFTER_SECONDS // 2)
    stranger = make_root(owner, "notaroot", OLD)
    leftover = make_root(owner, SWEEP_PREFIX + "1-bbbbbb", OLD)
    target = make_root(tmp_path, "elsewhere", OLD)
    if os.name != "nt":
        (owner / "dddddd").symlink_to(target)

    sweep_stale_roots(owner, current, now=NOW)

    assert current.exists() and fresh.exists() and stranger.exists() and target.exists()
    assert not stale.exists() and not leftover.exists()
    if os.name != "nt":
        assert (owner / "dddddd").is_symlink()
    sweep_stale_roots(tmp_path / "missing", current, now=NOW)


def test_sweep_puts_back_a_root_a_session_touched_before_the_move(tmp_path, monkeypatch):
    """A session that touches its stale root between the sweep's check and its rename does not lose the root."""
    owner = tmp_path / "agc-0"
    owner.mkdir()
    root = make_root(owner, "bbbbbb", OLD)
    rename = os.rename

    def touch_then_rename(source, target):
        os.utime(source)
        rename(source, target)

    monkeypatch.setattr(temp_roots.os, "rename", touch_then_rename)
    sweep_stale_roots(owner, None, now=time.time() + 1)

    assert (root / "pytest-0" / "file0").read_text() == "x"
    assert [entry.name for entry in owner.iterdir()] == ["bbbbbb"]


def test_sweep_survives_a_root_recreated_before_the_put_back(tmp_path, monkeypatch):
    """When the session already made a new root, the put back fails: the new root stays and nothing raises."""
    owner = tmp_path / "agc-0"
    owner.mkdir()
    root = make_root(owner, "bbbbbb", OLD)
    rename = os.rename
    calls = []

    def touch_then_rename(source, target):
        calls.append(source)
        if len(calls) == 1:
            os.utime(source)
        else:
            (root / "pytest-0").mkdir(parents=True)
            (root / "new").write_text("new")
        rename(source, target)

    monkeypatch.setattr(temp_roots.os, "rename", touch_then_rename)
    sweep_stale_roots(owner, None, now=time.time() + 1)

    assert len(calls) == 2
    assert (root / "new").read_text() == "new"
    assert [entry.name for entry in owner.iterdir()] == ["bbbbbb"]


@pytest.mark.parametrize("step", ["mkdir", "utime"])
def test_touch_root_retries_when_a_sweep_removes_the_root(tmp_path, monkeypatch, step):
    """The folder is removed between mkdir and utime (a sweep moved it), or after mkdir saw it exist: both retry."""
    root = tmp_path / "bbbbbb"
    root.mkdir()
    real = getattr(os, step)
    calls = []

    def sabotage(*args, **kwargs):
        calls.append(args)
        if len(calls) == 1:
            shutil.rmtree(root)
            if step == "mkdir":
                raise FileExistsError(str(root))
        return real(*args, **kwargs)

    monkeypatch.setattr(temp_roots.os, step, sabotage)
    temp_roots._touch_root(root)

    assert root.is_dir()
    assert time.time() - root.stat().st_mtime < 60


def test_touch_root_gives_up_with_a_clear_error(tmp_path, monkeypatch):
    root = tmp_path / "bbbbbb"

    def always_gone(path):
        raise FileNotFoundError(path)

    monkeypatch.setattr(temp_roots.os, "utime", always_gone)
    with pytest.raises(RuntimeError, match="removed"):
        temp_roots._touch_root(root)


# Run by test_sessions_that_start_together_keep_their_roots: say it is ready, wait for the shared start time the parent
# sets once every racer is ready, then take a root as a session does.
RACER = """
import os, sys, time
from types import SimpleNamespace
from pathlib import Path
from tests.temp_roots import assign_root

gate, name = Path(sys.argv[1]), sys.argv[2]
config = SimpleNamespace(option=SimpleNamespace(basetemp=None), rootpath=Path(name), args=[name])
(gate / ("ready-" + name)).write_text("")
while not (gate / "go").exists():
    time.sleep(0.001)
start = float((gate / "go").read_text())
while time.time() < start:
    pass
assign_root(config)
root = Path(os.environ["PYTEST_DEBUG_TEMPROOT"])
# Another racer's sweep may hold this root aside for a few microseconds before it puts it back (a fresh root is
# never removed); the final asserts check that no root was lost, so wait out that window here.
for _ in range(1000):
    try:
        (root / "pytest-of-x").mkdir(exist_ok=True)
        break
    except (FileNotFoundError, FileExistsError):
        time.sleep(0.001)
else:
    raise SystemExit("root never came back: " + str(root))
"""


def clean_env(temp: Path) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k != "PYTEST_DEBUG_TEMPROOT"}
    env.update(TMPDIR=str(temp), TMP=str(temp), TEMP=str(temp), PYTHONPATH=str(ROOT))
    return env


def test_sessions_that_start_together_keep_their_roots(tmp_path):
    """The first sessions after a long gap all find every root stale; none may lose its own to another's sweep."""
    temp = tmp_path / "tmp"
    temp.mkdir()
    env = clean_env(temp)
    names = [f"module{number}" for number in range(8)]

    def start_all():
        gate = tmp_path / "gate"
        gate.mkdir()
        children = [subprocess.Popen([sys.executable, "-c", RACER, str(gate), name], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for name in names]
        deadline = time.time() + 60
        while len(list(gate.glob("ready-*"))) < len(names) and time.time() < deadline:
            time.sleep(0.01)
        assert len(list(gate.glob("ready-*"))) == len(names), "a racer did not start"
        # Written aside and renamed, so a racer never reads a half-written start time.
        (gate / "go.tmp").write_text(str(time.time() + 0.1))
        os.replace(gate / "go.tmp", gate / "go")
        for child in children:
            output = child.communicate(timeout=120)[0]
            assert child.returncode == 0, output
        shutil.rmtree(gate)

    start_all()
    owners = list(temp.glob("agc*"))
    assert len(owners) == 1
    roots = list(owners[0].iterdir())
    assert len(roots) == len(names)
    for _ in range(3):
        for root in roots:
            for number in range(300):
                (root / "pytest-of-x" / f"f{number}").write_text("x")
            os.utime(root, (NOW, NOW))
        start_all()
    assert sorted(owners[0].iterdir()) == sorted(roots)
    assert all(time.time() - root.stat().st_mtime < 60 for root in roots)


def test_sessions_keep_one_run_in_a_root_and_touch_it(tmp_path):
    """Pytest sessions of the same module set leave one numbered folder, not three as pytest does by default."""
    project = tmp_path / "project"
    project.mkdir()
    (project / "conftest.py").write_text(
        "from tests.temp_roots import assign_root\n\n\ndef pytest_configure(config):\n    assign_root(config)\n"
    )
    (project / "test_inner.py").write_text("def test_it(tmp_path):\n    (tmp_path / 'f').write_text('x')\n")
    temp = tmp_path / "tmp"
    temp.mkdir()
    env = clean_env(temp)

    def session():
        done = subprocess.run(
            [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-c", str(ROOT / "pyproject.toml"),
             "--rootdir", str(project), str(project)],
            env=env, capture_output=True, text=True, check=False, timeout=120,
        )
        assert done.returncode == 0, done.stdout + done.stderr

    for _ in range(3):
        session()
    roots = [root for owner in temp.glob("agc*") for root in owner.iterdir()]
    assert len(roots) == 1
    assert len(list(roots[0].glob("pytest-of-*/pytest-[0-9]*"))) == 1

    os.utime(roots[0], (NOW, NOW))
    session()
    assert time.time() - roots[0].stat().st_mtime < 60
