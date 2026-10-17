"""Test the Docker removal-sandbox launcher without filesystem backends."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import unittest
from pathlib import Path

from tests.agentica_test import TestCase, wait_until

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tools" / "windows_remove_sandbox.py"


@unittest.skipUnless(os.name == "posix", "the Docker launcher uses POSIX process groups")
class WindowsRemoveSandboxLauncherTests(TestCase):
    """Check preflight, confinement arguments, and owned-container cleanup."""

    def setUp(self) -> None:
        self.scratch = self.make_temp_dir("agentica-sandbox-mock-")
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
    raise SystemExit(1 if os.environ.get("MOCK_IMAGE_MISSING") else 0)
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
        env["WINDOWS_IMAGE"] = "preloaded-test-image"
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

    def test_launcher_requires_container_boundaries_and_runs_probe_only(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._calls()
        create = next(call for call in calls if call[0] == "create")
        for option in (
            "--read-only",
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges",
            "--network=none",
            "--memory=2g",
            "--memory-swap=2g",
            "--pids-limit=128",
            "--tmpfs",
        ):
            self.assertIn(option, create)
        self.assertIn(
            f"type=bind,src={ROOT},dst=/source,readonly",
            create,
        )
        self.assertIn("/tmp:rw,nosuid,nodev,exec,size=512m,mode=1777", create)
        for setting in ("HOME=/tmp/home", "TEMP=/tmp/temp", "WINEPREFIX=/tmp/wine"):
            self.assertIn(setting, create)
        self.assertIn("sandbox boundary probe passed", create[-1])
        self.assertNotIn("Path.remove", create[-1])
        self.assertNotIn("agc_remove_tree", create[-1])
        start = next(call for call in calls if call[:2] == ["start", "--attach"])
        remove = next(call for call in calls if call[:2] == ["rm", "--force"])
        self.assertEqual(start[2], remove[2])

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

    def test_missing_docker_fails_without_host_fallback(self) -> None:
        result = self._run(env=self._environment(include_docker=False))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to run the probe on the host", result.stderr)
        self.assertEqual(self._calls(), [])

    def test_missing_image_fails_before_container_creation(self) -> None:
        env = self._environment()
        env["MOCK_IMAGE_MISSING"] = "1"
        result = self._run(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required preloaded Docker image is unavailable", result.stderr)
        self.assertFalse(any(call[0] == "create" for call in self._calls()))

    def test_tests_mode_is_rejected_before_docker(self) -> None:
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
        self.assertIn("Docker could not remove the owned probe container", result.stderr)

    @unittest.skipUnless(os.name == "posix", "Docker CLI cleanup uses POSIX process groups")
    def test_timeout_stops_client_and_removes_only_the_owned_container(self) -> None:
        env = self._environment()
        env["MOCK_START_HANG"] = "1"
        result = self._run("--timeout", "1", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeded 1 seconds", result.stderr)
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
