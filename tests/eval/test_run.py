import contextlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import uuid
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

import run


class ChildEnvironmentTests(unittest.TestCase):
    def test_only_allowlisted_environment_is_passed(self) -> None:
        with patch.dict(os.environ, {"PROVIDER_TOKEN": "secret", "OTHER_SECRET": "hidden"}, clear=True):
            env = run.child_environment(["PROVIDER_TOKEN"], in_chroot=True, workspace=Path("/tmp/work"))

        self.assertEqual(env["PROVIDER_TOKEN"], "secret")
        self.assertNotIn("OTHER_SECRET", env)
        self.assertEqual(env["PATH"], run.ROOTFS_PATH)
        self.assertEqual(env["HOME"], "/home/agent")

    def test_rejects_invalid_reserved_and_unset_names(self) -> None:
        for name, variables in (
            ("BAD-NAME", {}),
            ("HOME", {"HOME": "/host/home"}),
            ("MISSING_TOKEN", {}),
        ):
            with self.subTest(name=name), patch.dict(os.environ, variables, clear=True):
                with self.assertRaises(SystemExit):
                    run.child_environment([name], in_chroot=True, workspace=Path("/tmp/work"))

    def test_redacts_allowlisted_values(self) -> None:
        with patch.dict(os.environ, {"PROVIDER_TOKEN": "secret-value"}, clear=True):
            output = run.redact_secrets("logged secret-value", ["PROVIDER_TOKEN"])

        self.assertEqual(output, "logged [REDACTED]")


class JailCommandTests(unittest.TestCase):
    def test_agent_has_chroot_and_network_access(self) -> None:
        command = run.jail_prefix(Path("/tmp/rootfs"), network=True)

        self.assertIn("--chroot=/tmp/rootfs", command)
        self.assertIn("--private-tmp", command)
        self.assertIn("--nonewprivs", command)
        self.assertIn("--caps.drop=all", command)
        self.assertIn("--seccomp", command)
        self.assertNotIn("--net=none", command)

    def test_grader_has_no_network(self) -> None:
        command = run.jail_prefix(Path("/tmp/rootfs"), network=False)

        self.assertIn("--net=none", command)


class CandidateBoundaryTests(unittest.TestCase):
    def test_copies_regular_candidate_and_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "solution.py"
            destination = root / "copy.py"
            source.write_text("print('ok')\n")
            self.assertTrue(run.copy_candidate(source, destination))
            self.assertEqual(destination.read_text(), "print('ok')\n")

            link = root / "linked.py"
            link.symlink_to(source)
            self.assertFalse(run.copy_candidate(link, root / "linked-copy.py"))

    def test_rootfs_clone_clears_agent_writable_and_home_directories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "template"
            (template / "workspace").mkdir(parents=True)
            (template / "workspace" / "leftover.txt").write_text("old workspace")
            outside_home = root / "outside-home"
            (outside_home / "agent").mkdir(parents=True)
            (outside_home / "agent" / "credentials").write_text("old credentials")
            (template / "home").symlink_to(outside_home, target_is_directory=True)
            clone = run.clone_rootfs(template, root / "clone")

            self.assertFalse((clone / "workspace").exists())
            self.assertFalse((clone / "home" / "agent").exists())
            self.assertEqual((outside_home / "agent" / "credentials").read_text(), "old credentials")


class PrepareTests(unittest.TestCase):
    def test_grammar_arm_writes_the_whole_specification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dist" / "runtime").mkdir(parents=True)
            (root / "examples").mkdir()
            shutil.copytree(run.ROOT / "docs" / "grammar", root / "docs" / "grammar")
            task = root / "tasks" / "sample"
            task.mkdir(parents=True)
            (task / "task.md").write_text("Sample task.\n", encoding="utf-8")
            work = root / "work"
            with patch.object(run, "ROOT", root), patch.object(run, "TASKS", root / "tasks"):
                run.prepare(work, "sample", "grammar")

            grammar = (work / "docs" / "grammar.md").read_text(encoding="utf-8")
            markers = ("# Agentica", "\n## 1. What we want", "\n## 4. Lexical", "\n## 7. Diagnostics",
                       "\n## 8. Examples", "\n### Programs that must be rejected")
            positions = [grammar.find(marker) for marker in markers]
            self.assertTrue(all(position >= 0 for position in positions), positions)
            self.assertEqual(positions, sorted(positions))
            self.assertNotIn("](../", grammar)
            self.assertNotIn("site/content", grammar)

    def test_grammar_arm_prompt_names_agentica_help(self) -> None:
        self.assertIn("agentica help NAME", run.prompt(Path("/tmp/work"), "grammar"))

    def test_typed_python_prompt_names_the_checker_and_forbids_silencing_it(self) -> None:
        text = run.prompt(Path("/tmp/work"), "typed-python")

        self.assertIn("mypy --strict solution.py", text)
        self.assertIn("# type: ignore", text)
        self.assertNotIn("mypy", run.prompt(Path("/tmp/work"), "python"))

    def test_typed_arm_gets_the_typed_start_and_no_agentica_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dist" / "runtime" / "bin").mkdir(parents=True)
            (root / "dist" / "runtime" / "bin" / "agentica").write_text("binary")
            task = root / "tasks" / "sample"
            task.mkdir(parents=True)
            (task / "task.md").write_text("Sample task.\n", encoding="utf-8")
            (task / "start.py").write_text("untyped\n", encoding="utf-8")
            (task / "start.typed.py").write_text("typed\n", encoding="utf-8")
            (task / "start.agc").write_text("agentica\n", encoding="utf-8")
            with patch.object(run, "ROOT", root), patch.object(run, "TASKS", root / "tasks"):
                for arm, start, runtime in (("typed-python", "typed\n", False), ("python", "untyped\n", False),
                                            ("binary", "agentica\n", True)):
                    work = root / f"work-{arm}"
                    run.prepare(work, "sample", arm)
                    ext = run.ARMS[arm]
                    with self.subTest(arm=arm):
                        self.assertEqual((work / f"start.{ext}").read_text(encoding="utf-8"), start)
                        self.assertEqual((work / "bin" / "agentica").exists(), runtime)
                        self.assertFalse((work / "start.typed.py").exists())


def bash_events(call: str, command: str, output: str) -> list[str]:
    return [
        json.dumps({"type": "tool_execution_start", "toolCallId": call, "toolName": "bash",
                    "args": {"command": command}}),
        json.dumps({"type": "tool_execution_end", "toolCallId": call, "toolName": "bash",
                    "result": {"content": [{"type": "text", "text": output}]}}),
    ]


class MetricsTests(unittest.TestCase):
    def test_checker_runs_count_as_check_runs_and_failures_as_repairs(self) -> None:
        mypy_error = "solution.py:3: error: Incompatible types in assignment  [assignment]\nFound 1 error in 1 file"
        events = (bash_events("1", "mypy --strict solution.py", mypy_error)
                  + bash_events("2", "mypy --strict solution.py", "Success: no issues found in 1 source file")
                  + bash_events("3", "python3 solution.py < in.txt", "Traceback (most recent call last):\nValueError")
                  + bash_events("4", "agentica check solution.agc", "solution.agc:1:1 error[CHECK-UNKNOWN-NAME]")
                  + bash_events("5", "python3 solution.py", "ok")
                  + bash_events("6", "cat task.md", "error: not a check"))

        metrics = run.pi_metrics("\n".join(events))

        self.assertEqual(metrics["interpreter_runs"], 5)
        self.assertEqual(metrics["check_runs"], 3)
        self.assertEqual(metrics["check_failures"], 2)
        self.assertEqual(metrics["failing_runs"], 3)

    def test_mypy_error_text_is_not_a_failure_for_other_commands(self) -> None:
        self.assertFalse(run.command_failed("python3 solution.py", "x.py:1: error: not from mypy"))
        self.assertTrue(run.command_failed("mypy --strict solution.py && python3 solution.py", "a.py:1: error: bad"))


class CheckerGradingTests(unittest.TestCase):
    def test_classifies_mypy_output(self) -> None:
        self.assertEqual(run.classify_check('solution.py:4: error: Argument 1 has incompatible type "str"  [arg-type]\n'
                                            "Found 1 error in 1 file (checked 1 source file)\n"), ("check", "arg-type"))
        self.assertEqual(run.classify_check("solution.py:2: error: invalid syntax  [syntax]\n"), ("syntax", "SyntaxError"))
        self.assertEqual(run.classify_check("mypy: can't read file 'solution.py': No such file or directory\n"),
                         ("check", "mypy"))
        self.assertEqual(run.classify_check("solution.py:1: error: something odd\n"), ("check", "mypy"))


class CaseCommandTests(unittest.TestCase):
    def test_plain_cases_run_the_solution_directly(self) -> None:
        self.assertEqual(run.case_command("py", None), ["python3", "-I", "solution.py"])
        self.assertEqual(run.case_command("agc", None), ["/workspace/bin/agentica", "solution.agc"])

    def test_driver_cases_pass_the_driver_source_and_an_absolute_solution_path(self) -> None:
        self.assertEqual(run.case_command("py", "print(1)"),
                         ["python3", "-I", "-c", "print(1)", "python3", "-I", "/workspace/solution.py"])
        self.assertEqual(run.case_command("agc", "print(1)"),
                         ["python3", "-I", "-c", "print(1)", "/workspace/bin/agentica", "/workspace/solution.agc"])

    def test_task_directory_supplies_driver_and_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            hidden = Path(directory) / "tasks" / "sample" / "hidden"
            hidden.mkdir(parents=True)
            with patch.object(run, "TASKS", Path(directory) / "tasks"):
                self.assertIsNone(run.hidden_driver("sample"))
                self.assertEqual(run.case_timeout("sample"), run.CASE_TIMEOUT)
                (hidden / "driver.py").write_text("print('driver')\n", encoding="utf-8")
                (hidden / "timeout").write_text("60\n", encoding="utf-8")
                self.assertEqual(run.hidden_driver("sample"), "print('driver')\n")
                self.assertEqual(run.case_timeout("sample"), 60)

    def test_every_task_has_a_reference_per_language_and_cases(self) -> None:
        for task in sorted(path for path in run.TASKS.iterdir() if path.is_dir()):
            with self.subTest(task=task.name):
                for name in ("task.md", "reference.agc", "reference.py"):
                    self.assertTrue((task / name).is_file(), name)
                cases = sorted((task / "hidden").glob("*.in"))
                self.assertTrue(cases)
                for case in cases:
                    self.assertTrue(case.with_suffix(".out").is_file(), case.name)


class SummaryTests(unittest.TestCase):
    def test_summary_has_a_check_runs_column(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            rows = [{"task": "t1", "arm": "typed-python", "status": "pass", "passed": 2, "total": 2, "seconds": 3.0,
                     "failing_runs": 1, "check_runs": 2, "failure": None, "code": None},
                    {"task": "t1", "arm": "typed-python", "status": "fail", "passed": 0, "total": 2, "seconds": 5.0,
                     "failing_runs": 3, "check_runs": 4, "failure": "check", "code": "arg-type"}]
            (results / "results.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                run.summarize(results)
            summary = (results / "summary.md").read_text(encoding="utf-8")

        self.assertIn("check runs", summary)
        self.assertIn("| t1 | typed-python | 2 | 1/2 | 50% | 0 | 4.0 | 2.0 | 3.0 | check:arg-type |", summary)


class DockerBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not shutil.which("docker"):
            raise unittest.SkipTest("Docker is unavailable")
        image = subprocess.run(["docker", "image", "inspect", run.DEFAULT_IMAGE], capture_output=True)
        if image.returncode:
            raise unittest.SkipTest("evaluation image has not been built")

    def test_agent_can_write_workspace_without_host_files_or_unlisted_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "workspace"
            work.mkdir()
            canary = root / "host-secret"
            canary.write_text("host only")
            script = (
                "import json,os; from pathlib import Path; "
                "Path('/workspace/probe.txt').write_text('ok'); "
                f"print(json.dumps([Path({str(canary)!r}).exists(), "
                "os.getenv('PROVIDER_TOKEN'), os.getenv('OTHER_SECRET'), os.geteuid()]))"
            )
            name = f"agentica-test-{uuid.uuid4().hex}"
            with patch.dict(os.environ, {"PROVIDER_TOKEN": "test-token", "OTHER_SECRET": "host-secret"}):
                env = run.child_environment(["PROVIDER_TOKEN"], in_chroot=True, workspace=work)
                command = run.docker_prefix(work, run.DEFAULT_IMAGE, name, network=True, pass_env=["PROVIDER_TOKEN"])
                try:
                    result = subprocess.run(command + ["python3", "-I", "-c", script], env=env,
                                            capture_output=True, text=True, timeout=30, check=True)
                finally:
                    run.remove_container(name)
            self.assertEqual(json.loads(result.stdout), [False, "test-token", None, os.getuid()])
            self.assertEqual((work / "probe.txt").read_text(), "ok")

    def test_grader_has_no_secret_network_or_workspace_writes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            candidate = work / "solution.py"
            candidate.write_text("original")
            script = """import json,os,socket
from pathlib import Path
writable = False
network = False
try:
    Path('/workspace/solution.py').write_text('changed')
    writable = True
except OSError:
    pass
try:
    socket.create_connection(('1.1.1.1', 443), timeout=0.5).close()
    network = True
except OSError:
    pass
print(json.dumps([os.getenv('PROVIDER_TOKEN'), writable, network]))
"""
            name = f"agentica-test-{uuid.uuid4().hex}"
            with patch.dict(os.environ, {"PROVIDER_TOKEN": "host-secret"}):
                command = run.docker_prefix(work, run.DEFAULT_IMAGE, name, network=False, pass_env=[])
                try:
                    result = subprocess.run(command + ["python3", "-I", "-c", script],
                                            env=run.grader_environment(), capture_output=True,
                                            text=True, timeout=30, check=True)
                finally:
                    run.remove_container(name)
            self.assertEqual(json.loads(result.stdout), [None, False, False])
            self.assertEqual(candidate.read_text(), "original")


class DockerGradingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not shutil.which("docker"):
            raise unittest.SkipTest("Docker is unavailable")
        image = subprocess.run(["docker", "image", "inspect", run.DEFAULT_IMAGE], capture_output=True)
        if image.returncode:
            raise unittest.SkipTest("evaluation image has not been built")
        if run.checker_version(run.DEFAULT_IMAGE) is None:
            raise unittest.SkipTest("evaluation image has no type checker")

    def grade(self, root: Path, name: str, source: str, arm: str = "typed-python") -> dict:
        solution = root / "solution.py"
        solution.write_text(source, encoding="utf-8")
        args = Namespace(sandbox="docker", image=run.DEFAULT_IMAGE, chroot_root=None)
        scratch = root / "scratch"
        scratch.mkdir(exist_ok=True)
        with patch.object(run, "TASKS", root / "tasks"):
            return run.grade(solution, "sample", arm, args, scratch, name)

    def sample_task(self, root: Path, driver: str | None = None) -> None:
        hidden = root / "tasks" / "sample" / "hidden"
        hidden.mkdir(parents=True)
        (hidden / "01.in").write_text("3\n", encoding="utf-8")
        (hidden / "01.out").write_text("6\n", encoding="utf-8")
        if driver is not None:
            (hidden / "driver.py").write_text(driver, encoding="utf-8")

    def test_typed_arm_fails_a_type_error_before_running_any_case(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.sample_task(root)
            source = "n: int = 'three'\nprint(6)\n"

            result = self.grade(root, "bad", source)
            untyped = self.grade(root, "bad-untyped", source, arm="python")

        self.assertEqual((result["status"], result["passed"], result["failure"], result["code"]),
                         ("fail", 0, "check", "assignment"))
        self.assertEqual(result["check_errors"], 1)
        self.assertEqual((untyped["status"], untyped["passed"]), ("pass", 1))

    def test_typed_arm_passes_a_checked_solution_and_counts_type_ignores(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.sample_task(root)
            source = "import sys\n\nn: int = int(sys.stdin.read())\nprint(n * 2)\n"

            result = self.grade(root, "good", source)

        self.assertEqual((result["status"], result["passed"], result["total"]), ("pass", 1, 1))
        self.assertEqual((result["check_errors"], result["type_ignores"]), (0, 0))

    def test_driver_runs_the_solution_next_to_a_loopback_peer_without_network(self) -> None:
        driver = (
            "import socket, subprocess, sys\n"
            "peer = socket.socket()\n"
            "peer.bind(('127.0.0.1', 0))\n"
            "peer.listen(1)\n"
            "child = subprocess.Popen(sys.argv[1:] + [str(peer.getsockname()[1])], stdin=subprocess.PIPE, text=True)\n"
            "child.stdin.write(sys.stdin.read())\n"
            "child.stdin.close()\n"
            "connection, _ = peer.accept()\n"
            "print('peer got', connection.recv(100).decode())\n"
            "child.wait()\n"
        )
        source = (
            "import socket, sys\n"
            "n = int(sys.stdin.read())\n"
            "socket.create_connection(('127.0.0.1', int(sys.argv[1]))).sendall(str(n * 2).encode())\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.sample_task(root, driver)
            (root / "tasks" / "sample" / "hidden" / "01.out").write_text("peer got 6\n", encoding="utf-8")

            result = self.grade(root, "peer", source, arm="python")

        self.assertEqual((result["status"], result["passed"]), ("pass", 1), result)


if __name__ == "__main__":
    unittest.main()
