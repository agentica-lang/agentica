"""The temporary roots of the pytest runs: one folder per checkout and module set, and a sweep of the stale ones."""

import hashlib
import os
import re
import shutil
import stat
import tempfile
import time
from pathlib import Path

import pytest

# A root nobody started a session in for this long is left over from a deleted checkout or a module set that is no
# longer run. A test module ends in minutes (the hang guards of mk/test.mk are far below a day, even scaled for a slow
# runner), so a day never reaches a live run.
STALE_AFTER_SECONDS = 24 * 60 * 60

# A root is named by six hex digits of the hash of its checkout and module set (assign_root). The sweep touches no
# other name, so a stray folder in the owner folder is never removed. A root being removed is first moved to a
# SWEEP_PREFIX name, which the sweep also finishes when the process that moved it died.
ROOT_NAME = re.compile(r"[0-9a-f]{6}")
SWEEP_PREFIX = ".sweep-"
TOUCH_TRIES = 50


def _make_writable_and_retry(function, path, excinfo):
    """rmtree's onexc: a read-only entry that cannot be removed is made writable and removed again.

    It does not recover an entry whose read-only parent folder blocks the removal; that stays for the next sweep."""
    if not isinstance(excinfo, PermissionError):
        return
    try:
        os.chmod(path, stat.S_IRWXU)
        function(path)
    except OSError:
        pass


def _remove_tree(path: Path) -> None:
    shutil.rmtree(path, onexc=_make_writable_and_retry)


def _age(path: Path, now: float) -> float | None:
    """Seconds since the last session started in PATH; None when it is gone or is not a plain folder."""
    try:
        info = path.lstat()
    except OSError:
        return None
    return now - info.st_mtime if stat.S_ISDIR(info.st_mode) else None


def sweep_stale_roots(owner: Path, keep: Path | None = None, now: float | None = None,
                      max_age: float = STALE_AFTER_SECONDS) -> None:
    """Remove the roots under OWNER whose last session started more than MAX_AGE seconds ago, except KEEP.

    Safe against sessions that start at the same time, in this and other processes: a session touches its root when
    it starts (assign_root), so a root in use is never old. The sweep looks at the age again right before it acts and
    moves a stale root aside with one rename before it removes it, so a session never finds a root half removed: the
    root is whole or briefly absent, and the session that lost its root creates it again (assign_root retries). If a
    session touched the root between the check and the rename, the sweep sees it on the moved folder and puts it back.
    The age is wall-clock time: a clock set forward makes roots look stale, and the sessions that lose their root
    simply create it again; a clock set back keeps roots longer. Failures are ignored: the sweep is housekeeping and
    must not fail a run.
    """
    now = time.time() if now is None else now
    try:
        names = os.listdir(owner)
    except OSError:
        return
    for name in names:
        path = owner / name
        if path == keep:
            continue
        leftover = name.startswith(SWEEP_PREFIX)
        if not leftover and not ROOT_NAME.fullmatch(name):
            continue
        age = _age(path, now)
        if age is None or age < max_age:
            continue
        if leftover:
            # Moved aside by a sweep that died, or by one running right now (removing it twice is fine). A fresh
            # one is a root a session touched after the move: that sweep puts it back, so it is not stale here.
            _remove_tree_quietly(path)
            continue
        aside = owner / f"{SWEEP_PREFIX}{os.getpid()}-{name}"
        try:
            os.rename(path, aside)
        except OSError:
            continue
        age = _age(aside, now)
        if age is not None and age < max_age:
            try:
                os.rename(aside, path)
                continue
            except OSError:
                pass
        _remove_tree_quietly(aside)


def _remove_tree_quietly(path: Path) -> None:
    try:
        _remove_tree(path)
    except OSError:
        pass


def _touch_root(root: Path) -> None:
    """Create ROOT if missing and set its modification time to now.

    A sweep may move the root away between the two steps (the folder exists for mkdir, then is gone for utime, or
    the other way round), so the pair is retried until the root is there and touched. Only a sweep moves a root, and
    it moves one at most once a root is stale, so a few tries are enough; many more mean something else removes it.
    """
    for _ in range(TOUCH_TRIES):
        try:
            os.mkdir(root, 0o700)
        except FileExistsError:
            pass
        try:
            os.utime(root)
            return
        except FileNotFoundError:
            continue
    raise RuntimeError(f"the temporary root {root} was removed {TOUCH_TRIES} times while it was being created")


def assign_root(config: pytest.Config) -> None:
    """Give each pytest run of a module its own temporary root, keep the last run in it and sweep the stale roots.

    make test runs one pytest per module in parallel. With a shared root, every run replaces the same
    pytest-of-<user>/pytest-current link, and the cleanup of another run can fail on it at the end of the session
    (FileNotFoundError in cleanup_dead_symlinks after all cases passed). A root per user, checkout and module set keeps
    the links apart; pyproject.toml keeps one numbered folder in it (tmp_path_retention_count), the last run, for
    debugging. Roots do not pile up: the sweep removes those of this user untouched for a day, which are the roots of
    deleted worktrees. The sweep runs before this session creates its own root, so it never competes for it. pytest
    reads the variable only at the first tmp_path, so setting it here is early enough, and child pytest runs inherit
    it on purpose (they return here at once and sweep nothing).
    """
    if config.option.basetemp is not None or "PYTEST_DEBUG_TEMPROOT" in os.environ:
        return
    # Short names: a Windows case builds a 100-character folder under tmp_path and needs it below MAX_PATH.
    owner = f"agc-{os.getuid()}" if hasattr(os, "getuid") else "agc"
    key = "\0".join([str(config.rootpath), *sorted(map(str, config.args))])
    root = Path(tempfile.gettempdir()) / owner / hashlib.sha256(key.encode()).hexdigest()[:6]
    root.parent.mkdir(mode=0o700, exist_ok=True)
    # On a shared temp folder another user could have made the owner folder: sweep only a folder of ours.
    if not hasattr(os, "getuid") or root.parent.stat().st_uid == os.getuid():
        sweep_stale_roots(root.parent, root)
    _touch_root(root)
    os.environ["PYTEST_DEBUG_TEMPROOT"] = str(root)
