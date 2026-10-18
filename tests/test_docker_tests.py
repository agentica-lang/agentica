"""Test the Docker test-group launcher without filesystem backends."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import pytest

from tests.agentica_test import ROOT, wait_until
from tests.remove_sandbox_support import require_remove_sandbox
from tools.run_remove_actions import SENTINEL_MARKER, _actions_scratch

RUNNER = ROOT / "tools" / "docker_tests.py"
ACTIONS_RUNNER = ROOT / "tools" / "run_remove_actions.py"
IMAGE = "preloaded-test-image"
DIGEST = "0123456789abcdef"

pytestmark = pytest.mark.skipif(os.name != "posix", reason="the Docker launcher uses POSIX process groups")


class DockerLauncher:
    """A fake `docker` on PATH and the log of the calls the launcher made."""

    def __init__(self, scratch: Path) -> None:
        self.scratch = scratch
        self.docker = scratch / "docker"
        self.log = scratch / "docker.jsonl"
        self.started = scratch / "container-started"
        self._write_fake_docker()

    def _write_fake_docker(self) -> None:
        script = f'''#!{sys.executable}
import json
import os
import pathlib
import sys
import time

args = sys.argv[1:]
with open({str(self.log)!r}, "a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["image", "inspect"]:
    if os.environ.get("MOCK_IMAGE_MISSING"):
        raise SystemExit(1)
    print("sha256:{DIGEST}")
    raise SystemExit(0)
if args[0] == "volume" and args[1] == "create":
    raise SystemExit(1 if len(args) != 3 else 0)
if args[0] == "run":
    raise SystemExit(7 if os.environ.get("MOCK_PREPARE_FAIL") else 0)
if args[0] == "create":
    print("mock-container-id")
    raise SystemExit(5 if os.environ.get("MOCK_CREATE_FAIL") else 0)
if args[:2] == ["start", "--attach"]:
    pathlib.Path({str(self.started)!r}).touch()
    if os.environ.get("MOCK_START_HANG"):
        time.sleep(60)
    raise SystemExit(int(os.environ.get("MOCK_START_STATUS", "0")))
if args[:2] == ["rm", "--force"]:
    raise SystemExit(7 if os.environ.get("MOCK_RM_FAIL") else 0)
raise SystemExit(64)
'''
        self.docker.write_text(script, encoding="utf-8")
        self.docker.chmod(0o755)

    def environment(self, *, include_docker: bool = True) -> dict[str, str]:
        env = os.environ.copy()
        env["PATH"] = (
            str(self.scratch) + os.pathsep + env.get("PATH", "")
            if include_docker
            else str(self.scratch / "empty-path")
        )
        env["TEST_IMAGE"] = IMAGE
        return env

    def run(self, *arguments: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RUNNER), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=env or self.environment(),
            timeout=10,
        )

    def calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def create(self) -> list[str]:
        return next(call for call in self.calls() if call[0] == "create")


@pytest.fixture
def launcher(tmp_path: Path) -> DockerLauncher:
    """A scratch folder with the fake `docker` the launcher starts."""
    return DockerLauncher(tmp_path)


def assert_owned_container_removed(calls):
    start = next(call for call in calls if call[:2] == ["start", "--attach"])
    remove = next(call for call in calls if call[:2] == ["rm", "--force"])
    assert start[2] == remove[2]


def test_launcher_requires_container_boundaries_and_runs_probe_only(launcher):
    result = launcher.run()
    assert result.returncode == 0, result.stderr
    calls = launcher.calls()
    create = launcher.create()
    for option in (
        "--read-only",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--network=none",
        "--memory=4g",
        "--memory-swap=4g",
        "--pids-limit=512",
        "--tmpfs",
    ):
        assert option in create
    assert f"type=bind,src={ROOT},dst=/source,readonly" in create
    for target in ("/source/build", "/source/dist"):
        name = f"agentica-test-build-{'build' if target.endswith('build') else 'dist'}-{DIGEST[:12]}"
        assert f"type=volume,src={name},dst={target}" in create
    assert "/tmp:rw,nosuid,nodev,exec,size=1g,mode=1777" in create
    assert "/var/tmp:rw,nosuid,nodev,exec,size=512m,mode=1777" in create
    for setting in ("HOME=/tmp/home", "TEMP=/tmp/temp", "WINEPREFIX=/tmp/wine", "XDG_RUNTIME_DIR=/tmp/xdg"):
        assert setting in create
    assert any(setting.startswith("JOBS=") for setting in create)
    assert "mount_options" in create[-1]
    assert "make -j" not in create[-1]
    assert "Path.remove" not in create[-1]
    assert "agc_remove_tree" not in create[-1]
    assert_owned_container_removed(calls)


def test_destructive_modes_are_networkless_and_marked_for_the_installed_root(launcher):
    for mode in ("files", "bdd", "windows-wine-tests"):
        launcher.log.unlink(missing_ok=True)
        result = launcher.run("--mode", mode)
        assert result.returncode == 0, result.stderr
        create = launcher.create()
        tmp_size = "3g" if mode == "windows-wine-tests" else "1g"
        assert f"/tmp:rw,nosuid,nodev,exec,size={tmp_size},mode=1777" in create
        assert "--read-only" in create
        assert f"type=bind,src={ROOT},dst=/source,readonly" in create
        assert "--network=none" in create
        assert "AGENTICA_REMOVE_TEST_MODE=docker" in create
    launcher.log.unlink(missing_ok=True)
    launcher.run("--mode", "fast")
    assert "--network=none" not in launcher.create()
    assert "AGENTICA_REMOVE_TEST_MODE=docker" not in launcher.create()


def test_each_group_runs_its_own_command(launcher):
    expected = {
        "fast": ("make -j\"$jobs\" test",),
        "slow": ("make -j\"$jobs\" test-slow",),
        "files": ("build/vm/release/tree-test", "python3 -m pytest", "tests/test_vm_os_remove.py", "tests/test_bdd_cleanup.py"),
        "bdd": ("tests/bdd/specs/",),
        "windows-wine-tests": ("tests.test_windows_filesystem_safety",),
    }
    for mode, markers in expected.items():
        launcher.log.unlink(missing_ok=True)
        result = launcher.run("--mode", mode)
        assert result.returncode == 0, result.stderr
        command = launcher.create()[-1]
        for marker in markers:
            assert marker in command


def test_isolated_modules_do_not_collect_imported_test_classes():
    from tests import test_bdd_cleanup, test_vm_os_remove

    # Both isolated modules are pytest-native: unittest collects no cases from them,
    # and neither re-exports tests defined in another module (pytest would collect those too).
    for module in (test_bdd_cleanup, test_vm_os_remove):
        assert unittest.defaultTestLoader.loadTestsFromModule(module).countTestCases() == 0
        imported = [name for name, value in vars(module).items()
                    if name.startswith("test_") and callable(value)
                    and getattr(value, "__module__", None) != module.__name__]
        assert imported == [], module.__name__


def test_actions_entrypoint_refuses_local_execution(tmp_path):
    environment = os.environ.copy()
    environment.pop("GITHUB_ACTIONS", None)
    environment["RUNNER_TEMP"] = str(tmp_path)
    result = subprocess.run(
        [sys.executable, str(ACTIONS_RUNNER), "all"],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=10,
    )
    assert result.returncode == 1
    assert "require an ephemeral GitHub-hosted Actions runner" in result.stderr


def test_actions_harness_creates_a_scratch_and_sentinel_beside_it(tmp_path):
    environment = {
        "GITHUB_ACTIONS": "true",
        "AGENTICA_ACTIONS_RUNNER_ENVIRONMENT": "github-hosted",
        "RUNNER_TEMP": str(tmp_path),
    }
    with patch.dict(os.environ, environment):
        scratch, sentinel, runner_temp, environment = _actions_scratch()
    try:
        assert scratch.parent == tmp_path
        assert runner_temp == tmp_path
        assert sentinel.parent == tmp_path
        assert sentinel.read_bytes() == SENTINEL_MARKER
        assert environment["AGENTICA_REMOVE_TEST_MODE"] == "actions"
        assert environment["AGENTICA_REMOVE_TEST_SCRATCH"] == str(scratch)
        assert environment["TMPDIR"] == str(scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
        sentinel.unlink(missing_ok=True)


def test_actions_mode_accepts_only_runner_owned_scratch(tmp_path):
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir()
    scratch = runner_temp / "case"
    scratch.mkdir()
    system_temp = scratch / "python-temp"
    system_temp.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    sibling = runner_temp / "sibling"
    sibling.mkdir()
    environment = {
        "AGENTICA_REMOVE_TEST_MODE": "actions",
        "AGENTICA_REMOVE_TEST_SCRATCH": str(scratch),
        "GITHUB_ACTIONS": "true",
        "AGENTICA_ACTIONS_RUNNER_ENVIRONMENT": "github-hosted",
        "RUNNER_TEMP": str(runner_temp),
        "HOME": str(scratch / "home"),
        "TEMP": str(scratch),
        "TMP": str(scratch),
        "TMPDIR": str(scratch),
        "USERPROFILE": str(scratch / "home"),
        "LOCALAPPDATA": str(scratch / "local-app-data"),
        "APPDATA": str(scratch / "app-data"),
    }
    for directory in ("home", "local-app-data", "app-data"):
        (scratch / directory).mkdir()
    with patch.dict(os.environ, environment), patch(
        "tests.remove_sandbox_support.tempfile.gettempdir", return_value=str(system_temp)
    ):
        require_remove_sandbox(scratch)
        with pytest.raises(AssertionError, match="per-run scratch root"):
            require_remove_sandbox(sibling)
        outside_root = environment | {"AGENTICA_REMOVE_TEST_SCRATCH": str(outside)}
        with patch.dict(os.environ, outside_root):
            with pytest.raises(AssertionError, match="below RUNNER_TEMP"):
                require_remove_sandbox(scratch)


def test_actions_mode_refuses_self_hosted_runners(tmp_path):
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir()
    scratch = runner_temp / "case"
    scratch.mkdir()
    environment = {
        "AGENTICA_REMOVE_TEST_MODE": "actions",
        "AGENTICA_REMOVE_TEST_SCRATCH": str(scratch),
        "GITHUB_ACTIONS": "true",
        "AGENTICA_ACTIONS_RUNNER_ENVIRONMENT": "self-hosted",
        "RUNNER_TEMP": str(runner_temp),
    }
    with patch.dict(os.environ, environment), patch(
        "tests.remove_sandbox_support.tempfile.gettempdir", return_value=str(scratch)
    ):
        with pytest.raises(AssertionError, match="refuse non-hosted Actions runners"):
            require_remove_sandbox(scratch)


def test_make_rejects_an_unknown_group_before_any_runner():
    result = subprocess.run(
        ["make", "--no-print-directory", "tests", "KIND=everything"],
        check=False,
        capture_output=True,
        text=True,
        cwd=ROOT,
        timeout=30,
    )
    assert result.returncode == 2, result.stderr
    assert "KIND must be fast, files, slow or all" in result.stderr


@pytest.mark.parametrize("arguments, message", (
    (("KIND=files", "TESTS=tests/test_vm_os_remove.py"), "TESTS= is supported only"),
    (("KIND=fast", "DOCKER=1", "WINE=1"), "choose either DOCKER=1 or WINE=1"),
    (("KIND=fast", "DOCKER=1", "TESTS=tests/test_vm_bits.py"), "TESTS= is supported only"),
))
def test_make_rejects_unsupported_test_selector_combinations(arguments, message):
    result = subprocess.run(
        ["make", "--no-print-directory", "tests", *arguments],
        check=False,
        capture_output=True,
        text=True,
        cwd=ROOT,
        timeout=30,
    )
    assert result.returncode == 2, result.stderr
    assert message in result.stderr


def test_missing_docker_fails_without_host_fallback(launcher):
    result = launcher.run(env=launcher.environment(include_docker=False))
    assert result.returncode != 0
    assert "refusing to run it on the host" in result.stderr
    assert launcher.calls() == []


def test_missing_image_fails_before_container_creation(launcher):
    env = launcher.environment()
    env["MOCK_IMAGE_MISSING"] = "1"
    result = launcher.run(env=env)
    assert result.returncode != 0
    assert "is missing: build it with make docker-test-image" in result.stderr
    assert not any(call[0] == "create" for call in launcher.calls())


def test_failed_volume_preparation_stops_before_container_creation(launcher):
    env = launcher.environment()
    env["MOCK_PREPARE_FAIL"] = "1"
    result = launcher.run(env=env)
    assert result.returncode != 0
    assert "could not prepare the disposable build volumes" in result.stderr
    assert not any(call[0] == "create" for call in launcher.calls())


def test_rejected_mode_is_refused_before_docker(launcher):
    result = launcher.run("--mode", "tests")
    assert result.returncode == 2
    assert not launcher.log.exists()


def test_container_start_failure_still_removes_the_owned_container(launcher):
    env = launcher.environment()
    env["MOCK_START_STATUS"] = "9"
    result = launcher.run(env=env)
    assert result.returncode == 9
    assert_owned_container_removed(launcher.calls())


def test_partial_container_creation_failure_attempts_exact_name_cleanup(launcher):
    env = launcher.environment()
    env["MOCK_CREATE_FAIL"] = "1"
    result = launcher.run(env=env)
    assert result.returncode != 0
    calls = launcher.calls()
    create = next(call for call in calls if call[0] == "create")
    remove = next(call for call in calls if call[:2] == ["rm", "--force"])
    name = create[create.index("--name") + 1]
    assert remove[2] == name


def test_container_cleanup_failure_is_a_hard_error(launcher):
    env = launcher.environment()
    env["MOCK_RM_FAIL"] = "1"
    result = launcher.run(env=env)
    assert result.returncode != 0
    assert "Docker could not remove the container it created" in result.stderr


def test_timeout_stops_client_and_removes_only_the_owned_container(launcher):
    env = launcher.environment()
    env["MOCK_START_HANG"] = "1"
    result = launcher.run("--mode", "slow", "--timeout", "1", env=env)
    assert result.returncode != 0
    assert "mode slow exceeded 1 seconds" in result.stderr
    calls = launcher.calls()
    assert_owned_container_removed(calls)
    assert len([call for call in calls if call[0] == "rm"]) == 1


def test_interruption_removes_only_the_owned_container(launcher):
    env = launcher.environment()
    env["MOCK_START_HANG"] = "1"
    process = subprocess.Popen(
        [sys.executable, str(RUNNER)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        assert wait_until(launcher.started.exists, timeout=5)
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    assert process.returncode == 130, (stdout, stderr)
    assert "interrupted; owned container cleanup attempted" in stderr
    assert_owned_container_removed(launcher.calls())
