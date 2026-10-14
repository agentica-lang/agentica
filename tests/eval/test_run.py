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
            ("TMPDIR", {"TMPDIR": "/host/tmp"}),
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

    def test_missing_typed_start_falls_back_and_a_task_without_a_start_gets_none(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tasks = root / "tasks"
            for name in ("plain", "nostart"):
                (tasks / name).mkdir(parents=True)
                (tasks / name / "task.md").write_text("Sample task.\n", encoding="utf-8")
            (tasks / "plain" / "start.py").write_text("untyped\n", encoding="utf-8")
            with patch.object(run, "ROOT", root), patch.object(run, "TASKS", tasks):
                self.assertEqual(run.start_file("plain", "typed-python"), tasks / "plain" / "start.py")
                run.prepare(root / "work-plain", "plain", "typed-python")
                run.prepare(root / "work-nostart", "nostart", "typed-python")
            self.assertEqual((root / "work-plain" / "start.py").read_text(encoding="utf-8"), "untyped\n")
            self.assertFalse((root / "work-nostart" / "start.py").exists())
            self.assertNotIn("starting program", run.prompt(root / "work-nostart", "typed-python"))


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
        self.assertFalse(run.command_failed("pip install mypy", "x.py:1: error: not from mypy"))

    def test_only_running_the_checker_is_a_check_run(self) -> None:
        for command in ("mypy --strict solution.py", "python3 -m mypy solution.py", "cd /workspace && mypy solution.py",
                        "mypy solution.py | tail -3", "agentica check solution.agc", "./bin/agentica check x.agc"):
            with self.subTest(command=command):
                self.assertTrue(run.is_check_command(command))
        for command in ("pip install mypy", "cat solution.py", "grep mypy notes.txt", "python3 solution.py"):
            with self.subTest(command=command):
                self.assertFalse(run.is_check_command(command))
        metrics = run.pi_metrics("\n".join(bash_events("1", "pip install mypy", "Successfully installed mypy")))
        self.assertEqual((metrics["interpreter_runs"], metrics["check_runs"], metrics["net_commands"]), (0, 0, 1))

    def test_network_commands_ignore_loopback_curl_and_urllib(self) -> None:
        for command in ("curl https://example.com/x", "wget x", "git clone x", "pip install requests", "npm install x",
                        "apt-get install x", "python3 -c 'import urllib.request'", "curl localhost:1 && pip install x"):
            with self.subTest(command=command):
                self.assertTrue(run.is_net_command(command))
        for command in ("curl -s http://localhost:8080/stats", "curl 127.0.0.1:9", "cat adapter.py", "python3 solution.py",
                        "python3 -c 'import urllib.request as u; u.urlopen(\"http://127.0.0.1:80\")'"):
            with self.subTest(command=command):
                self.assertFalse(run.is_net_command(command))

    def test_claude_metrics_have_the_check_counters(self) -> None:
        metrics = run.claude_metrics(json.dumps({"usage": {"input_tokens": 3, "output_tokens": 4}, "num_turns": 2}))

        self.assertEqual((metrics["check_runs"], metrics["check_failures"], metrics["turns"]), (0, 0, 2))


class CheckerGradingTests(unittest.TestCase):
    def test_classifies_mypy_output(self) -> None:
        self.assertEqual(run.classify_check('solution.py:4: error: Argument 1 has incompatible type "str"  [arg-type]\n'
                                            "Found 1 error in 1 file (checked 1 source file)\n"), ("check", "arg-type"))
        self.assertEqual(run.classify_check("solution.py:2: error: invalid syntax  [syntax]\n"), ("syntax", "SyntaxError"))
        self.assertEqual(run.classify_check("mypy: can't read file 'solution.py': No such file or directory\n"),
                         ("check", "mypy"))
        self.assertEqual(run.classify_check("solution.py:1: error: something odd\n"), ("check", "mypy"))


class CaseCommandTests(unittest.TestCase):
    def test_plain_cases_send_the_case_on_stdin_to_the_solution(self) -> None:
        self.assertEqual(run.case_invocation("py", None, "3\r\n"), (["python3", "-I", "solution.py"], "3\r\n"))
        self.assertEqual(run.case_invocation("agc", None, "x"), (["/workspace/bin/agentica", "solution.agc"], "x"))

    def test_driver_cases_send_the_driver_on_stdin_and_the_case_and_solution_in_argv(self) -> None:
        self.assertEqual(run.case_invocation("py", "print(1)", "a\r\n"),
                         (["python3", "-I", "-", "a\r\n", "python3", "-I", "/workspace/solution.py"], "print(1)"))
        self.assertEqual(run.case_invocation("agc", "print(1)", "a"),
                         (["python3", "-I", "-", "a", "/workspace/bin/agentica", "/workspace/solution.agc"], "print(1)"))

    def test_crlf_case_files_reach_the_command_unchanged(self) -> None:
        seen: list[tuple[list[str], str]] = []

        def fake(args: Namespace, grade_root: Path, work: Path, command: list[str], stdin: str,
                 timeout: int) -> tuple[str | None, str, int | None]:
            seen.append((command, stdin))
            return "ok\n", "", 0

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hidden = root / "tasks" / "sample" / "hidden"
            hidden.mkdir(parents=True)
            (hidden / "01.in").write_bytes(b"a\r\nb\r\n")
            (hidden / "01.out").write_text("ok\n", encoding="utf-8")
            solution = root / "solution.py"
            solution.write_text("pass\n", encoding="utf-8")
            scratch = root / "scratch"
            scratch.mkdir()
            args = Namespace(sandbox="docker", image=run.DEFAULT_IMAGE, chroot_root=None)
            with patch.object(run, "TASKS", root / "tasks"), patch.object(run, "contained_run", fake):
                plain = run.grade(solution, "sample", "python", args, scratch, "plain")
                (hidden / "driver.py").write_text("pass\n", encoding="utf-8")
                driven = run.grade(solution, "sample", "python", args, scratch, "driven")

        self.assertEqual((plain["status"], driven["status"]), ("pass", "pass"))
        self.assertEqual(seen[0], (["python3", "-I", "solution.py"], "a\r\nb\r\n"))
        self.assertEqual(seen[1], (["python3", "-I", "-", "a\r\nb\r\n", "python3", "-I", "/workspace/solution.py"], "pass\n"))

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


class TypedSourceTests(unittest.TestCase):
    def test_silencing_comments_and_escapes_are_counted(self) -> None:
        source = ("from typing import Any, cast\n# mypy: ignore-errors\nx = foo()  # type: ignore[attr-defined]\n"
                  "y = bar()  #type:ignore\nz: Any = cast(int, x)\nAnything = 1\n")

        self.assertEqual(run.type_escapes(source), {"type_ignores": 3, "type_escapes": 3})
        self.assertEqual(run.type_escapes("import sys\nprint(sys.argv)\n"), {"type_ignores": 0, "type_escapes": 0})

    def test_a_checker_timeout_is_its_own_failure(self) -> None:
        result = run.type_check(lambda command, stdin, timeout: (None, "timeout", None), 3)

        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual((result["failure"], result["passed"], result["total"]), ("check-timeout", 0, 3))


class ImageDecisionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.build = patch.object(run, "build_image").start()
        for name, value in (("require_docker", None), ("image_exists", True), ("python_runs", None),
                            ("image_id", "sha256:abc")):
            patch.object(run, name, return_value=value).start()
        self.addCleanup(patch.stopall)

    def validate(self, image: str = run.DEFAULT_IMAGE, **probes: list) -> dict[str, str | None]:
        for name, results in probes.items():
            patch.object(run, name, side_effect=results).start()
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            result = run.validate_docker(image, typed="checker_probe" in probes, agentica="runtime_probe" in probes)
        self.printed = printed.getvalue()
        return result

    def test_the_default_image_is_rebuilt_only_when_the_checker_is_missing(self) -> None:
        found = (0, "mypy 2.3.1 (compiled: yes)\n", "")
        for code in run.MISSING_COMMAND:
            self.build.reset_mock()
            with self.subTest(code=code):
                result = self.validate(checker_probe=[(code, "", "not found"), found])
                self.assertEqual(self.build.call_count, 1)
                self.assertIn("rebuilding", self.printed)
                self.assertEqual(result, {"checker": "mypy 2.3.1 (compiled: yes)", "image_id": "sha256:abc"})
        for first in ((1, "", "crash"), (None, "", "timeout")):
            self.build.reset_mock()
            with self.subTest(first=first), self.assertRaises(SystemExit):
                self.validate(checker_probe=[first, found])
            self.assertEqual(self.build.call_count, 0)
        with self.assertRaises(SystemExit) as raised:
            self.validate("custom:1", checker_probe=[(127, "", "not found"), found])
        self.assertEqual(self.build.call_count, 0)
        self.assertIn("Rebuild", str(raised.exception))

    def test_an_image_that_cannot_run_the_agentica_runtime_is_rebuilt_or_refused(self) -> None:
        self.validate(runtime_probe=[(False, "libgc.so.1 missing"), (True, "")])
        self.assertEqual(self.build.call_count, 1)
        self.build.reset_mock()
        with self.assertRaises(SystemExit) as raised:
            self.validate(runtime_probe=[(False, "libgc.so.1 missing"), (False, "libgc.so.1 missing")])
        self.assertEqual(self.build.call_count, 1)
        self.assertIn("Rebuild", str(raised.exception))
        self.build.reset_mock()
        with self.assertRaises(SystemExit):
            self.validate("custom:1", runtime_probe=[(False, "libgc.so.1 missing")])
        self.assertEqual(self.build.call_count, 0)
        probe = patch.object(run, "runtime_probe", side_effect=AssertionError).start()
        with contextlib.redirect_stdout(io.StringIO()):
            run.validate_docker(run.DEFAULT_IMAGE, typed=False, agentica=False)
        probe.assert_not_called()


class MainTests(unittest.TestCase):
    def main(self, root: Path, argv: list[str], status: str) -> tuple[int, list[tuple[str, list[str], str]], list]:
        calls: list[tuple[str, list[str], str]] = []

        def fake_one_run(args: Namespace, results: Path, scratch: Path, task: str, arm: str, rep: int) -> None:
            calls.append((args.agent, list(args.pass_env), arm))
            row = {"task": task, "arm": arm, "status": status, "passed": 1, "total": 1, "failure": None, "code": None}
            with (results / "results.jsonl").open("a") as handle:
                handle.write(json.dumps(row) + "\n")

        validated: list = []

        def fake_validate(image: str, typed: bool = False, agentica: bool = False) -> dict[str, str | None]:
            validated.append((image, typed, agentica))
            return {"checker": "mypy 9.9", "image_id": "sha256:feed"}

        with (patch.object(run, "ROOT", root), patch.object(run, "EVAL", root / "eval"),
              patch.object(run, "build") as build, patch.object(run, "require_docker"),
              patch.object(run, "validate_docker", fake_validate), patch.object(run, "one_run", fake_one_run),
              patch.dict(os.environ, {"FOO": "bar"}), patch("sys.argv", ["run.py", *argv]),
              contextlib.redirect_stdout(io.StringIO())):
            code = run.main()
        build.assert_called_once()
        return code, calls, validated

    def result_info(self, root: Path) -> dict:
        (directory,) = (root / "eval" / "results").iterdir()
        return json.loads((directory / "run.json").read_text(encoding="utf-8"))

    def test_check_references_runs_the_reference_arms_without_credentials_and_exits_1_on_a_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("agentica", "agentica-vm"):
                (root / "dist" / "runtime" / "bin").mkdir(parents=True, exist_ok=True)
                (root / "dist" / "runtime" / "bin" / name).write_text("binary")
            argv = ["--check-references", "--agent", "pi", "--pass-env", "FOO", "--tasks", "t1", "--image", "custom:1"]

            code, calls, validated = self.main(root, argv, "fail")
            failing = self.result_info(root)
            shutil.rmtree(root / "eval")
            ok_code, _, _ = self.main(root, argv, "pass")
            shutil.rmtree(root / "eval")
            normal_code, normal_calls, normal_validated = self.main(
                root, ["--agent", "pi", "--pass-env", "FOO", "--tasks", "t1"], "pass")
            normal = self.result_info(root)

        self.assertEqual((code, ok_code, normal_code), (1, 0, 0))
        self.assertEqual(calls, [("reference", [], arm) for arm in run.REFERENCE_ARMS])
        self.assertEqual(validated, [("custom:1", True, True)])
        self.assertEqual((failing["agent"], failing["pass_env"], failing["agent_network"], failing["arms"]),
                         ("reference", [], False, run.REFERENCE_ARMS))
        self.assertEqual((failing["checker"], failing["image_id"], failing["image"]), ("mypy 9.9", "sha256:feed", "custom:1"))
        self.assertEqual([arm for _, _, arm in normal_calls], list(run.ARMS))
        self.assertEqual({(agent, tuple(env)) for agent, env, _ in normal_calls}, {("pi", ("FOO",))})
        self.assertEqual(normal_validated, [(run.DEFAULT_IMAGE, True, True)])
        self.assertEqual((normal["agent_network"], normal["pass_env"]), (True, ["FOO"]))


class SummaryTests(unittest.TestCase):
    def test_summary_has_a_check_runs_column(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            rows = [{"task": "t1", "arm": "typed-python", "status": "pass", "passed": 2, "total": 2, "seconds": 3.0,
                     "failing_runs": 1, "check_runs": 2, "type_escapes": 1, "failure": None, "code": None},
                    {"task": "t1", "arm": "typed-python", "status": "fail", "passed": 0, "total": 2, "seconds": 5.0,
                     "failing_runs": 3, "check_runs": 4, "type_escapes": 2, "failure": "check", "code": "arg-type"}]
            (results / "results.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                run.summarize(results)
            summary = (results / "summary.md").read_text(encoding="utf-8")

        self.assertIn("check runs | type escapes", summary)
        self.assertIn("| t1 | typed-python | 2 | 1/2 | 50% | 0 | 4.0 | 2.0 | 3.0 | 1.5 | check:arg-type |", summary)


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

    def sample_task(self, root: Path, driver: str | None = None, case: bytes = b"3\n", expected: str = "6\n") -> None:
        hidden = root / "tasks" / "sample" / "hidden"
        hidden.mkdir(parents=True)
        (hidden / "01.in").write_bytes(case)
        (hidden / "01.out").write_text(expected, encoding="utf-8")
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
        self.assertEqual((result["check_errors"], result["type_ignores"], result["type_escapes"]), (0, 0, 0))

    def test_typed_arm_fails_silencing_comments_even_when_the_checker_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.sample_task(root)
            results = {}
            for name, header in (("directive", "# mypy: ignore-errors\n"), ("ignore", "")):
                line = "n: int = 'three'" + ("  # type: ignore" if name == "ignore" else "")
                results[name] = self.grade(root, name, f"{header}{line}\nprint(6)\n")
            checker_alone = self.grade(root, "unsilenced", "n: int = 'three'\nprint(6)\n")

        for name in ("directive", "ignore"):
            with self.subTest(name=name):
                self.assertEqual((results[name]["status"], results[name]["passed"], results[name]["failure"],
                                  results[name]["code"]), ("fail", 0, "check", "ignore"))
                self.assertGreaterEqual(results[name]["type_ignores"], 1)
        self.assertEqual(checker_alone["code"], "assignment")
        self.assertEqual(checker_alone["type_ignores"], 0)

    def test_typed_arm_counts_any_and_cast_without_failing_them(self) -> None:
        source = ("import sys\nfrom typing import Any, cast\n\nraw: Any = sys.stdin.read()\n"
                  "text = cast(str, raw)\nprint(int(text) * 2)\n")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.sample_task(root)

            result = self.grade(root, "escapes", source)

        self.assertEqual((result["status"], result["type_ignores"], result["type_escapes"]), ("pass", 0, 3))

    def test_crlf_case_files_reach_the_solution_and_the_driver_unchanged(self) -> None:
        reads = "import sys\nprint(sys.stdin.buffer.read())\n"
        driver = "import sys\nprint(repr(sys.argv[1]))\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.sample_task(root, case=b"a\r\nb\r\n", expected="b'a\\r\\nb\\r\\n'\n")
            plain = self.grade(root, "plain", reads, arm="python")
            (root / "tasks" / "sample" / "hidden" / "driver.py").write_text(driver, encoding="utf-8")
            (root / "tasks" / "sample" / "hidden" / "01.out").write_text("'a\\r\\nb\\r\\n'\n", encoding="utf-8")
            driven = self.grade(root, "driven", "pass\n", arm="python")

        self.assertEqual((plain["status"], driven["status"]), ("pass", "pass"), (plain, driven))

    def test_driver_runs_the_solution_next_to_a_loopback_peer_without_network(self) -> None:
        driver = (
            "import socket, subprocess, sys\n"
            "peer = socket.socket()\n"
            "peer.bind(('127.0.0.1', 0))\n"
            "peer.listen(1)\n"
            "child = subprocess.Popen(sys.argv[2:] + [str(peer.getsockname()[1])], stdin=subprocess.PIPE, text=True)\n"
            "child.stdin.write(sys.argv[1])\n"
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
