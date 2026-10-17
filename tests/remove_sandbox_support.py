"""Physical confinement checks for destructive filesystem test cases."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path


def require_remove_sandbox() -> None:
    """Fail closed unless Docker supplied a read-only root and disposable /tmp."""
    if os.name != "posix" or not Path("/proc/self/mountinfo").is_file():
        raise AssertionError("destructive filesystem case requires the Docker sandbox")

    mounts: dict[str, tuple[str, str]] = {}
    for line in Path("/proc/self/mountinfo").read_text(encoding="utf-8").splitlines():
        fields = line.split()
        separator = fields.index("-")
        mountpoint = fields[4].replace("\\040", " ")
        options = fields[5].split(",")
        filesystem = fields[separator + 1]
        mounts[mountpoint] = (filesystem, ",".join(options))

    root = mounts.get("/")
    source = mounts.get("/source")
    temporary = mounts.get("/tmp")
    if root is None or "ro" not in root[1].split(","):
        raise AssertionError("destructive filesystem case requires a read-only container root")
    if source is None or "ro" not in source[1].split(","):
        raise AssertionError("destructive filesystem case requires read-only test sources")
    if temporary is None or temporary[0] != "tmpfs":
        raise AssertionError("destructive filesystem case requires disposable /tmp tmpfs storage")

    for variable in ("HOME", "TEMP", "TMP", "TMPDIR", "WINEPREFIX"):
        value = os.environ.get(variable)
        if not value:
            continue
        path = Path(value).resolve()
        if path != Path("/tmp") and Path("/tmp") not in path.parents:
            raise AssertionError(f"{variable} must be inside disposable /tmp storage")
    scratch = Path(tempfile.gettempdir()).resolve()
    if Path("/tmp") not in scratch.parents:
        raise AssertionError("temporary test paths must be inside disposable /tmp storage")
