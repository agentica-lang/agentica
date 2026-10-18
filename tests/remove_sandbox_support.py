"""Check that destructive filesystem tests use Docker locally or Actions scratch in CI."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path


def _is_within(path: Path, parent: Path) -> bool:
    """Return whether a resolved path is strictly below its resolved parent."""
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return path != parent


def _require_docker_sandbox(scratch: Path) -> None:
    if os.name != "posix" or not Path("/proc/self/mountinfo").is_file():
        raise AssertionError("local destructive filesystem tests require Docker")

    mounts: dict[str, tuple[str, set[str]]] = {}
    for line in Path("/proc/self/mountinfo").read_text(encoding="utf-8").splitlines():
        fields = line.split()
        separator = fields.index("-")
        mountpoint = fields[4].replace("\\040", " ")
        mounts[mountpoint] = (fields[separator + 1], set(fields[5].split(",")))

    root = mounts.get("/")
    source = mounts.get("/source")
    temporary = mounts.get("/tmp")
    if root is None or "ro" not in root[1]:
        raise AssertionError("Docker destructive tests require a read-only root")
    if source is None or "ro" not in source[1]:
        raise AssertionError("Docker destructive tests require read-only source files")
    if temporary is None or temporary[0] != "tmpfs":
        raise AssertionError("Docker destructive tests require /tmp on tmpfs")
    if not _is_within(scratch, Path("/tmp")):
        raise AssertionError("Docker destructive-test scratch must be below /tmp")

    for variable in ("HOME", "TEMP", "TMP", "TMPDIR", "WINEPREFIX", "XDG_RUNTIME_DIR"):
        value = os.environ.get(variable)
        if value and not _is_within(Path(value).resolve(), Path("/tmp")):
            raise AssertionError(f"{variable} must be inside disposable /tmp storage")


def _require_actions_scratch(scratch: Path) -> None:
    if os.environ.get("GITHUB_ACTIONS", "").lower() != "true":
        raise AssertionError("native destructive tests require an ephemeral GitHub-hosted Actions runner")
    if os.environ.get("AGENTICA_ACTIONS_RUNNER_ENVIRONMENT", "") != "github-hosted":
        raise AssertionError("native destructive tests refuse non-hosted Actions runners")
    runner_temp_value = os.environ.get("RUNNER_TEMP")
    test_scratch_value = os.environ.get("AGENTICA_REMOVE_TEST_SCRATCH")
    if not runner_temp_value or not test_scratch_value:
        raise AssertionError("GitHub Actions destructive tests require RUNNER_TEMP and test scratch")
    runner_temp = Path(runner_temp_value).resolve(strict=True)
    test_scratch = Path(test_scratch_value).resolve(strict=True)
    path = scratch.resolve(strict=True)
    if not runner_temp.is_dir() or not _is_within(test_scratch, runner_temp):
        raise AssertionError("destructive-test root must be below RUNNER_TEMP")
    if not test_scratch.is_dir() or not (path == test_scratch or _is_within(path, test_scratch)):
        raise AssertionError("destructive-test scratch must be below its per-run scratch root")
    temporary = Path(tempfile.gettempdir()).resolve(strict=True)
    if not (temporary == test_scratch or _is_within(temporary, test_scratch)):
        raise AssertionError("Python temporary files must be below the per-run scratch root")
    for variable in ("HOME", "TEMP", "TMP", "TMPDIR", "USERPROFILE", "LOCALAPPDATA", "APPDATA"):
        value = os.environ.get(variable)
        if value:
            path = Path(value).resolve(strict=True)
            if not (path == test_scratch or _is_within(path, test_scratch)):
                raise AssertionError(f"{variable} must be inside per-run scratch")


def require_remove_sandbox(scratch: Path | None = None) -> None:
    """Require Docker locally or an ephemeral Actions scratch directory in CI."""
    mode = os.environ.get("AGENTICA_REMOVE_TEST_MODE")
    path = (scratch or Path(tempfile.gettempdir())).resolve()
    if mode == "docker":
        _require_docker_sandbox(path)
    elif mode == "actions":
        _require_actions_scratch(path)
    else:
        raise AssertionError(
            "destructive filesystem tests require the local Docker launcher or the Actions runner harness"
        )
