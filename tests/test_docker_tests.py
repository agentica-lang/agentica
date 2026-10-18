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

from tests.agentica_test import ROOT, TestCase, wait_until
from tests.remove_sandbox_support import require_remove_sandbox
from tools.run_remove_actions import SENTINEL_MARKER, _actions_scratch

RUNNER = ROOT / "tools" / "docker_tests.py"
ACTIONS_RUNNER = ROOT / "tools" / "run_remove_actions.py"
IMAGE = "preloaded-test-image"
DIGEST = "0123456789abcdef"


@unittest.skipUnless(os.name == "posix", "the Docker launcher uses POSIX process groups")
class DockerTestsLauncherTests(TestCase):
    """Check preflight, confinement arguments, and owned-container cleanup."""

    def setUp(self) -> None:
        self.scratch = self.make_temp_dir("agentica-docker-tests-mock-")
        self.docker = self.scratch / "docker"
        self.log = self.scratch / "docker.jsonl"
        self.started = self.scratch / "container-started"
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

    def _environment(self, *, include_docker: bool = True) -> dict[str, str]:
        env = os.environ.copy()
        env["PATH"] = (
            str(self.scratch) + os.pathsep + env.get("PATH", "")
            if include_docker
            else str(self.scratch / "empty-path")
        )
        env["TEST_IMAGE"] = IMAGE
        return env

    def _run(self, *arguments: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RUNNER), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=env or self._environment(),
            timeout=10,
        )

    def _calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def _create(self) -> list[str]:
        return next(call for call in self._calls() if call[0] == "create")

    def test_launcher_requires_container_boundaries_and_runs_probe_only(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._calls()
        create = self._create()
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
            self.assertIn(option, create)
        self.assertIn(f"type=bind,src={ROOT},dst=/source,readonly", create)
        for target in ("/source/build", "/source/dist"):
            name = f"agentica-test-build-{'build' if target.endswith('build') else 'dist'}-{DIGEST[:12]}"
            self.assertIn(f"type=volume,src={name},dst={target}", create)
        self.assertIn("/tmp:rw,nosuid,nodev,exec,size=1g,mode=1777", create)
        self.assertIn("/var/tmp:rw,nosuid,nodev,exec,size=512m,mode=1777", create)
        for setting in ("HOME=/tmp/home", "TEMP=/tmp/temp", "WINEPREFIX=/tmp/wine", "XDG_RUNTIME_DIR=/tmp/xdg"):
            self.assertIn(setting, create)
        self.assertTrue(any(setting.startswith("JOBS=") for setting in create))
        self.assertIn("mount_options", create[-1])
        self.assertNotIn("make -j", create[-1])
        self.assertNotIn("Path.remove", create[-1])
        self.assertNotIn("agc_remove_tree", create[-1])
        start = next(call for call in calls if call[:2] == ["start", "--attach"])
        remove = next(call for call in calls if call[:2] == ["rm", "--force"])
        self.assertEqual(start[2], remove[2])

    def test_destructive_modes_are_networkless_and_marked_for_the_installed_root(self) -> None:
        for mode in ("files", "bdd", "windows-wine-tests"):
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                result = self._run("--mode", mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                create = self._create()
                self.assertIn("--network=none", create)
                self.assertIn("AGENTICA_REMOVE_TEST_MODE=docker", create)
        self.log.unlink(missing_ok=True)
        self._run("--mode", "fast")
        self.assertNotIn("--network=none", self._create())
        self.assertNotIn("AGENTICA_REMOVE_TEST_MODE=docker", self._create())

    def test_each_group_runs_its_own_command(self) -> None:
        expected = {
            "fast": ("make -j\"$jobs\" test",),
            "slow": ("make -j\"$jobs\" test-slow",),
            "files": ("build/vm/release/tree-test", "tests.test_vm_os_remove"),
            "bdd": ("tests/bdd/specs/",),
            "windows-wine-tests": ("tests.test_windows_filesystem_safety",),
        }
        for mode, markers in expected.items():
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                result = self._run("--mode", mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                command = self._create()[-1]
                for marker in markers:
                    self.assertIn(marker, command)

    def test_isolated_modules_do_not_collect_imported_test_classes(self) -> None:
        from tests import test_bdd_cleanup, test_vm_os_remove

        for module in (test_bdd_cleanup, test_vm_os_remove):
            with self.subTest(module=module.__name__):
                suite = unittest.defaultTestLoader.loadTestsFromModule(module)
                self.assertGreater(suite.countTestCases(), 0)
                pending = list(suite)
                while pending:
                    test = pending.pop()
                    if isinstance(test, unittest.TestSuite):
                        pending.extend(test)
                    else:
                        self.assertEqual(type(test).__module__, module.__name__)

    def test_actions_entrypoint_refuses_local_execution(self) -> None:
        environment = os.environ.copy()
        environment.pop("GITHUB_ACTIONS", None)
        environment["RUNNER_TEMP"] = str(self.scratch)
        result = subprocess.run(
            [sys.executable, str(ACTIONS_RUNNER), "all"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=10,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("require an ephemeral GitHub-hosted Actions runner", result.stderr)

    def test_actions_harness_creates_a_scratch_and_sentinel_beside_it(self) -> None:
        environment = {
            "GITHUB_ACTIONS": "true",
            "AGENTICA_ACTIONS_RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_TEMP": str(self.scratch),
        }
        with patch.dict(os.environ, environment):
            scratch, sentinel, runner_temp, environment = _actions_scratch()
        self.addCleanup(sentinel.unlink, missing_ok=True)
        self.addCleanup(shutil.rmtree, scratch)
        self.assertEqual(scratch.parent, self.scratch)
        self.assertEqual(runner_temp, self.scratch)
        self.assertEqual(sentinel.parent, self.scratch)
        self.assertEqual(sentinel.read_bytes(), SENTINEL_MARKER)
        self.assertEqual(environment["AGENTICA_REMOVE_TEST_MODE"], "actions")
        self.assertEqual(environment["AGENTICA_REMOVE_TEST_SCRATCH"], str(scratch))
        self.assertEqual(environment["TMPDIR"], str(scratch))

    def test_actions_mode_accepts_only_runner_owned_scratch(self) -> None:
        runner_temp = self.scratch / "runner-temp"
        runner_temp.mkdir()
        scratch = runner_temp / "case"
        scratch.mkdir()
        system_temp = scratch / "python-temp"
        system_temp.mkdir()
        outside = self.scratch / "outside"
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
            with self.assertRaisesRegex(AssertionError, "per-run scratch root"):
                require_remove_sandbox(sibling)
            outside_root = environment | {"AGENTICA_REMOVE_TEST_SCRATCH": str(outside)}
            with patch.dict(os.environ, outside_root):
                with self.assertRaisesRegex(AssertionError, "below RUNNER_TEMP"):
                    require_remove_sandbox(scratch)

    def test_actions_mode_refuses_self_hosted_runners(self) -> None:
        runner_temp = self.scratch / "runner-temp"
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
            with self.assertRaisesRegex(AssertionError, "refuse non-hosted Actions runners"):
                require_remove_sandbox(scratch)

    def test_make_rejects_an_unknown_group_before_any_runner(self) -> None:
        result = subprocess.run(
            ["make", "--no-print-directory", "tests", "KIND=everything"],
            check=False,
            capture_output=True,
            text=True,
            cwd=ROOT,
            timeout=30,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("KIND must be fast, files, slow or all", result.stderr)

    def test_make_rejects_unsupported_test_selector_combinations(self) -> None:
        combinations = (
            ("KIND=files", "TESTS=tests/test_vm_os_remove.py", "TESTS= is supported only"),
            ("KIND=fast", "DOCKER=1", "WINE=1", "choose either DOCKER=1 or WINE=1"),
            ("KIND=fast", "DOCKER=1", "TESTS=tests/test_vm_bits.py", "TESTS= is supported only"),
        )
        for combination in combinations:
            *arguments, message = combination
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    ["make", "--no-print-directory", "tests", *arguments],
                    check=False,
                    capture_output=True,
                    text=True,
                    cwd=ROOT,
                    timeout=30,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_missing_docker_fails_without_host_fallback(self) -> None:
        result = self._run(env=self._environment(include_docker=False))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to run it on the host", result.stderr)
        self.assertEqual(self._calls(), [])

    def test_missing_image_fails_before_container_creation(self) -> None:
        env = self._environment()
        env["MOCK_IMAGE_MISSING"] = "1"
        result = self._run(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is missing: build it with make docker-test-image", result.stderr)
        self.assertFalse(any(call[0] == "create" for call in self._calls()))

    def test_failed_volume_preparation_stops_before_container_creation(self) -> None:
        env = self._environment()
        env["MOCK_PREPARE_FAIL"] = "1"
        result = self._run(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not prepare the disposable build volumes", result.stderr)
        self.assertFalse(any(call[0] == "create" for call in self._calls()))

    def test_rejected_mode_is_refused_before_docker(self) -> None:
        result = self._run("--mode", "tests")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.log.exists())

    def test_container_start_failure_still_removes_the_owned_container(self) -> None:
        env = self._environment()
        env["MOCK_START_STATUS"] = "9"
        result = self._run(env=env)
        self.assertEqual(result.returncode, 9)
        calls = self._calls()
        start = next(call for call in calls if call[:2] == ["start", "--attach"])
        remove = next(call for call in calls if call[:2] == ["rm", "--force"])
        self.assertEqual(start[2], remove[2])

    def test_partial_container_creation_failure_attempts_exact_name_cleanup(self) -> None:
        env = self._environment()
        env["MOCK_CREATE_FAIL"] = "1"
        result = self._run(env=env)
        self.assertNotEqual(result.returncode, 0)
        calls = self._calls()
        create = next(call for call in calls if call[0] == "create")
        remove = next(call for call in calls if call[:2] == ["rm", "--force"])
        name = create[create.index("--name") + 1]
        self.assertEqual(remove[2], name)

    def test_container_cleanup_failure_is_a_hard_error(self) -> None:
        env = self._environment()
        env["MOCK_RM_FAIL"] = "1"
        result = self._run(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Docker could not remove the container it created", result.stderr)

    @unittest.skipUnless(os.name == "posix", "Docker CLI cleanup uses POSIX process groups")
    def test_timeout_stops_client_and_removes_only_the_owned_container(self) -> None:
        env = self._environment()
        env["MOCK_START_HANG"] = "1"
        result = self._run("--mode", "slow", "--timeout", "1", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mode slow exceeded 1 seconds", result.stderr)
        calls = self._calls()
        start = next(call for call in calls if call[:2] == ["start", "--attach"])
        remove = next(call for call in calls if call[:2] == ["rm", "--force"])
        self.assertEqual(start[2], remove[2])
        self.assertEqual(len([call for call in calls if call[0] == "rm"]), 1)

    @unittest.skipUnless(os.name == "posix", "Docker CLI cleanup uses POSIX process groups")
    def test_interruption_removes_only_the_owned_container(self) -> None:
        env = self._environment()
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
            self.assertTrue(wait_until(self.started.exists, timeout=5))
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(process.returncode, 130, (stdout, stderr))
        self.assertIn("interrupted; owned container cleanup attempted", stderr)
        calls = self._calls()
        start = next(call for call in calls if call[:2] == ["start", "--attach"])
        remove = next(call for call in calls if call[:2] == ["rm", "--force"])
        self.assertEqual(start[2], remove[2])


if __name__ == "__main__":
    unittest.main()
