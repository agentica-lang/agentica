#!/usr/bin/env python3
"""Run destructive filesystem regressions on an ephemeral GitHub Actions runner."""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import uuid
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
if str(REPOSITORY) not in sys.path:
    # The script runs from the repository root but Python puts this file's directory on the path, not the checkout.
    sys.path.insert(0, str(REPOSITORY))

from tests.agentica_test import run  # noqa: E402  (needs the repository root on sys.path)

COMMAND_TIMEOUT = 300
SENTINEL_MARKER = b"agentica remove harness sentinel\n"


def _inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return path != parent


def _run(command: list[str], *, cwd: Path, env: dict[str, str]) -> int:
    print("+", " ".join(command), flush=True)
    result = run(command, timeout=COMMAND_TIMEOUT, cwd=cwd, env=env)
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    return result.code


def _actions_scratch() -> tuple[Path, Path, Path, dict[str, str]]:
    if os.environ.get("GITHUB_ACTIONS", "").lower() != "true":
        raise RuntimeError("native destructive tests require an ephemeral GitHub-hosted Actions runner")
    if os.environ.get("AGENTICA_ACTIONS_RUNNER_ENVIRONMENT", "") != "github-hosted":
        raise RuntimeError("native destructive tests refuse non-hosted Actions runners")
    runner_temp_value = os.environ.get("RUNNER_TEMP")
    if not runner_temp_value:
        raise RuntimeError("native destructive tests require RUNNER_TEMP")
    runner_temp = Path(runner_temp_value).resolve(strict=True)
    if not runner_temp.is_dir():
        raise RuntimeError("RUNNER_TEMP is not a directory")

    sentinel = runner_temp / f"agentica-remove-sentinel-{uuid.uuid4().hex}"
    sentinel.write_bytes(SENTINEL_MARKER)
    try:
        scratch = Path(tempfile.mkdtemp(prefix="agentica-remove-", dir=runner_temp)).resolve()
    except OSError:
        sentinel.unlink(missing_ok=True)
        raise
    if not _inside(scratch, runner_temp):
        sentinel.unlink(missing_ok=True)
        raise RuntimeError("refusing scratch directory outside RUNNER_TEMP")

    environment = os.environ.copy()
    environment.update(
        AGENTICA_REMOVE_TEST_MODE="actions",
        AGENTICA_REMOVE_TEST_SCRATCH=str(scratch),
        PYTHONDONTWRITEBYTECODE="1",
        TEMP=str(scratch),
        TMP=str(scratch),
        TMPDIR=str(scratch),
        HOME=str(scratch / "home"),
        USERPROFILE=str(scratch / "home"),
        LOCALAPPDATA=str(scratch / "local-app-data"),
        APPDATA=str(scratch / "app-data"),
    )
    for directory in ("home", "local-app-data", "app-data"):
        (scratch / directory).mkdir()
    return scratch, sentinel, runner_temp, environment


def _run_bdd(repository: Path, product: Path, environment: dict[str, str]) -> int:
    return _run(
        [str(product), "test", "tests/bdd/specs/", "--steps", "tests/bdd/handlers.agc"],
        cwd=repository,
        env=environment,
    )


def _run_filesystem_tests(repository: Path, vm_build: Path, environment: dict[str, str]) -> int:
    suffix = ".exe" if os.name == "nt" else ""
    binaries = [vm_build / f"files_private-test{suffix}"]
    modules = ["tests.test_windows_filesystem_safety"] if os.name == "nt" else [
        "tests.test_vm_os_remove",
        "tests.test_bdd_cleanup",
    ]
    if sys.platform.startswith("linux"):
        binaries.insert(0, vm_build / f"tree-test{suffix}")

    for binary in binaries:
        if not binary.is_file():
            print(f"required prebuilt isolated test binary is missing: {binary}", file=sys.stderr)
            return 1
        status = _run([str(binary)], cwd=repository, env=environment)
        if status:
            return status

    module_paths = [module.replace(".", "/") + ".py" for module in modules]
    return _run(
        [sys.executable, "-m", "pytest", *module_paths],
        cwd=repository,
        env=environment,
    )


def main(argv: list[str] | None = None) -> int:
    """Run destructive regressions only on an ephemeral Actions runner."""
    arguments = sys.argv[1:] if argv is None else argv
    mode = arguments[0] if arguments else "all"
    if mode not in ("all", "bdd"):
        print("usage: run_remove_actions.py [all|bdd]", file=sys.stderr)
        return 2
    try:
        scratch, sentinel, runner_temp, environment = _actions_scratch()
    except (OSError, RuntimeError) as exc:
        print(f"test-remove-actions: {exc}", file=sys.stderr)
        return 1

    repository = REPOSITORY
    vm_build = repository / "build" / "vm" / "release"
    product = repository / "dist" / ("agentica.exe" if os.name == "nt" else "agentica")
    environment["AGENTICA_TEST_EXECUTABLE"] = str(product)
    environment["AGENTICA_VM_BINARY"] = str(product)
    environment["AGENTICA_TEST_TARGET_OS"] = "windows" if os.name == "nt" else sys.platform

    status = 0
    try:
        if mode == "bdd":
            status = _run_bdd(repository, product, environment)
        else:
            status = _run_filesystem_tests(repository, vm_build, environment)
    except AssertionError as exc:
        print(f"test-remove-actions: isolated test timed out: {exc}", file=sys.stderr)
        status = 1
    finally:
        if not _inside(scratch, runner_temp) or scratch.is_symlink():
            print("test-remove-actions: refusing to clean a scratch path outside RUNNER_TEMP", file=sys.stderr)
            status = 1
        else:
            try:
                shutil.rmtree(scratch)
            except OSError as exc:
                print(f"test-remove-actions: could not clean Actions scratch: {exc}", file=sys.stderr)
                status = 1
        if sentinel.parent != runner_temp:
            print("test-remove-actions: refusing to inspect a sentinel outside RUNNER_TEMP", file=sys.stderr)
            status = 1
        else:
            try:
                if sentinel.is_symlink() or not sentinel.is_file():
                    print("test-remove-actions: runner-temp sentinel is missing or replaced", file=sys.stderr)
                    status = 1
                elif sentinel.read_bytes() != SENTINEL_MARKER:
                    print("test-remove-actions: runner-temp sentinel was modified", file=sys.stderr)
                    status = 1
            except OSError as exc:
                print(f"test-remove-actions: could not verify runner-temp sentinel: {exc}", file=sys.stderr)
                status = 1
            finally:
                try:
                    sentinel.unlink(missing_ok=True)
                except OSError as exc:
                    print(f"test-remove-actions: could not remove runner-temp sentinel: {exc}", file=sys.stderr)
                    status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
