"""The temporary roots of the pytest runs: one folder per checkout and module set, and a sweep of the stale ones."""

import hashlib
import os
import shutil
import tempfile
import time
from pathlib import Path

# A root nobody started a session in for this long is left over from a deleted checkout or a module set that is no
# longer run. A module is limited to 30 minutes (MODULE_BASE_LIMIT of mk/test.mk), so a day never touches a live run.
STALE_AFTER_SECONDS = 24 * 60 * 60


def sweep_stale_roots(owner: Path, keep: Path, now: float | None = None, max_age: float = STALE_AFTER_SECONDS) -> None:
    """Remove the roots under OWNER whose last session started more than MAX_AGE seconds ago, except KEEP.

    A session touches its root when it starts (assign_root), so the modification time of a root is the start of its
    latest session and a root in use by a running module is never old. Failures are ignored: the sweep is housekeeping
    and must not fail a run, and a root another process is removing is already on its way out.
    """
    now = time.time() if now is None else now
    try:
        entries = list(os.scandir(owner))
    except OSError:
        return
    for entry in entries:
        path = Path(entry.path)
        try:
            if path == keep or entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                continue
            if now - entry.stat(follow_symlinks=False).st_mtime < max_age:
                continue
        except OSError:
            continue
        shutil.rmtree(path, ignore_errors=True)


def assign_root(config) -> None:
    """Give each pytest run of a module its own temporary root, keep the last run in it and sweep the stale roots.

    make test runs one pytest per module in parallel. With a shared root, every run replaces the same
    pytest-of-<user>/pytest-current link, and the cleanup of another run can fail on it at the end of the session
    (FileNotFoundError in cleanup_dead_symlinks after all cases passed). A root per user, checkout and module set keeps
    the links apart; pyproject.toml keeps one numbered folder in it (tmp_path_retention_count), the last run, for
    debugging. Roots do not pile up: the sweep removes those of this user untouched for a day, which are the roots of
    deleted worktrees. pytest reads the variable only at the first tmp_path, so setting it here is early enough, and
    child pytest runs inherit it on purpose (they return here at once and sweep nothing).
    """
    if config.option.basetemp is not None or "PYTEST_DEBUG_TEMPROOT" in os.environ:
        return
    # Short names: a Windows case builds a 100-character folder under tmp_path and needs it below MAX_PATH.
    owner = f"agc-{os.getuid()}" if hasattr(os, "getuid") else "agc"
    key = "\0".join([str(config.rootpath), *sorted(map(str, config.args))])
    root = Path(tempfile.gettempdir()) / owner / hashlib.sha256(key.encode()).hexdigest()[:6]
    root.parent.mkdir(mode=0o700, exist_ok=True)
    root.mkdir(mode=0o700, exist_ok=True)
    os.utime(root)
    sweep_stale_roots(root.parent, root)
    os.environ["PYTEST_DEBUG_TEMPROOT"] = str(root)
