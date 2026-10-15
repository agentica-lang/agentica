"""Process.spawn and friends through the CLI, against a Node child (ported from process-test.rkt).

fixtures/process-peer.js is the child (modes echo, exit, hold, stubborn, ...).
Each case writes an Agentica program, runs it with `--allow-run --json` and
compares its output, or its diagnostic code taken from the last line of stderr.
"""
import json
import unittest

from tests.agentica_test import FIXTURES, TestCase, cli, cli_runs_tests, run, tool, vm_environment

PEER = FIXTURES / "process-peer.js"


class ProcessCli(TestCase):
    def setUp(self):
        self.node = tool("node")

    def spawn(self, mode, extra=""):
        return '  p = Result.unwrap!(Process.spawn("%s", ["%s", "%s"%s], 5000))\n' % (self.node, PEER, mode, extra)

    def captured(self, mode, body, prefix=""):
        return ('%sdef main() -> Void\n  p = Result.unwrap!(Process.spawn_captured("%s", ["%s", "%s"], ".", 5000))\n%s\nend\n\n'
                % (prefix, self.node, PEER, mode, body))

    def probe(self, pid):
        return 'Process.wait(Result.unwrap!(Process.spawn("%s", ["%s", "probe", %s], 5000)), 5000)' % (self.node, PEER, pid)

    def program(self, mode, body, prefix="", extra=""):
        return prefix + "def main() -> Void\n" + self.spawn(mode, extra) + body + "\nend\n\n"

    def cli(self, *args):
        return run(cli() + list(args), env=vm_environment())

    def write(self, name, text):
        path = self.make_temp_dir("agentica-process-") / name
        path.write_text(text, encoding="utf-8")
        return path

    def run_program(self, text, allowed=True, limit=None):
        """Returns (result, stdout, stderr): result is None for a clean run, the diagnostic code for a failure
        that printed one (stderr then loses that last line), else the exit status."""
        args = (["--allow-run"] if allowed else []) + ["--json"] + (["--max-steps", str(limit)] if limit else [])
        result = self.cli(*args, self.write("program.agc", text))
        lines = result.stderr.strip("\n").split("\n") if result.stderr.strip("\n") else []
        problem = None
        if lines:
            try:
                problem = json.loads(lines[-1])
            except ValueError:
                pass
        if result.code == 0:
            return None, result.stdout, result.stderr
        if isinstance(problem, dict):
            return problem["code"], result.stdout, "\n".join(lines[:-1])
        return result.code, result.stdout, result.stderr

    def output(self, text, expected=""):
        result, out, err = self.run_program(text)
        self.assertIsNone(result, err)
        self.assertEqual(err, expected)
        return out

    def alive(self, pid):
        return run([self.node, PEER, "probe", pid.strip()]).code == 0

    def test_cli_capability_guards_execution_while_check_and_help_work_without_it(self):
        body = ("  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(System.args())\n"
                "  Result.unwrap!(Process.wait(p, 5000))")
        file = self.write("program.agc", self.program("args", body))
        self.assertEqual(tuple(self.cli("check", file)), (0, "check ok\n", ""))
        denied = self.cli("--json", file, "--allow-run")
        self.assertEqual(denied.code, 1)
        self.assertEqual(json.loads(denied.stderr)["code"], "RUNTIME-UNWRAP-ERROR")
        self.assertEqual(tuple(self.cli("--allow-run", file, "--allow-run")), (0, '[]\n["--allow-run"]\n', ""))
        help_result = self.cli("help", "Process.send", "--json")
        self.assertEqual(help_result.code, 0)
        self.assertEqual(json.loads(help_result.stdout)["result"], "Result[Void]")

    def test_unavailable_and_malformed_commands_return_errors_without_a_child(self):
        self.assertEqual(self.output(
            'def main() -> Void\n  IO.inspect(Result.ok?(Process.spawn("agentica-nonexistent-command-5l", [], 1000)))\n'
            '  IO.inspect(Result.ok?(Process.spawn("", [], 1000)))\n  nul = Result.unwrap!(String.from_bytes([0]))\n'
            '  IO.inspect(Result.ok?(Process.spawn("node", [nul], 1000)))\nend\n\n'),
            "false\nfalse\nfalse\n")

    @unittest.skipUnless(cli_runs_tests(), "the single binary cannot start the test runner yet (step 8d)")
    def test_bdd_handlers_can_always_spawn_and_programs_under_test_need_allow_run(self):
        directory = self.make_temp_dir("agentica-process-bdd-")
        feature = directory / "process.feature"
        steps = directory / "steps.agc"
        feature.write_text(
            'Feature: Process capability\nScenario: child\nGiven the Agentica program "child.agc"\n'
            'Then I receive a JSON line within 30000 milliseconds:\n  """\n  ["child"]\n  """\n'
            'And the program exits with code 0 within 30000 milliseconds\nScenario: handler\nThen the handler can spawn\n')
        (directory / "child.agc").write_text(self.program(
            "args", "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  Result.unwrap!(Process.wait(p, 5000))",
            "", ', "child"'))
        steps.write_text(
            'import BDD from "std/bdd"\n\ndef handler(ctx: BDD.Context, args: List[String]) -> BDD.Context\n'
            + self.spawn("args", ', "handler"')
            + '  checked = BDD.assert(ctx, Result.unwrap!(Process.read_line(p, 5000)) == "[\\"handler\\"]", "argv")\n'
            + "  Result.unwrap!(Process.wait(p, 5000))\n  return checked\nend\n\n"
            + 'def main() -> Void\n  BDD.run([BDD.step("the handler can spawn", &handler)])\nend\n')
        args = ["test", feature, "--steps", steps, "--json"]
        denied = self.cli(*args)
        self.assertEqual(denied.code, 1)
        report = json.loads(denied.stdout)
        self.assertEqual(report["passed"], 1)
        self.assertEqual([item["status"] for item in report["files"][0]["scenarios"]], ["failed", "passed"])
        allowed = self.cli(*args, "--allow-run")
        self.assertEqual(allowed.code, 0)
        self.assertEqual(json.loads(allowed.stdout)["passed"], 2)

    def test_permission_literal_argv_and_inherited_task_capability(self):
        text = self.program("args", "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Process.wait(p, 5000))",
                            "", ', "a b;$x", "--allow-run"')
        denied, out, _ = self.run_program(text, allowed=False)
        self.assertEqual(denied, "RUNTIME-UNWRAP-ERROR")
        self.assertEqual(out, "")
        self.assertEqual(self.output(text), '["a b;$x","--allow-run"]\nok(0)\n')

    def test_flushed_text_and_bytes_reply_before_stdin_eof_stderr_stays_separate(self):
        body = ('  Result.unwrap!(Process.send(p, "ñ\\n", 5000))\n'
                "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n"
                "  Result.unwrap!(Process.send_bytes(p, [0, 255, 10], 5000))\n"
                "  IO.inspect(Process.read_bytes(p, 0, 5000))\n"
                "  IO.inspect(Process.read_bytes(p, 3, 5000))\n"
                "  IO.inspect(Process.close_stdin(p, 5000))\n"
                "  IO.inspect(Process.close_stdin(p, 5000))\n"
                '  IO.inspect(Result.ok?(Process.send(p, "x", 5000)))\n'
                "  IO.inspect(Process.read_bytes(p, 3, 5000))\n"
                "  IO.inspect(Process.wait(p, 5000))\n"
                "  Process.close(p)\n  Process.close(p)\n"
                "  IO.inspect(Result.ok?(Process.wait(p, 5000)))")
        self.assertEqual(self.output(self.program("echo", body), "peer stderr\n"),
                         "ñ\nok([])\nok([0, 255, 10])\nok()\nok()\nfalse\nok([])\nok(0)\nfalse\n")

    def test_eof_nonzero_and_repeated_exit_waits_preserve_unread_output(self):
        body = ("  IO.inspect(Process.wait(p, 5000))\n  IO.inspect(Process.wait(p, 5000))\n"
                "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))\n"
                "  IO.inspect(Result.ok?(Process.read_line(p, 5000)))")
        self.assertEqual(self.output(self.program("exit", body)), "ok(7)\nok(7)\ndone\nlast\nfalse\n")

    def test_invalid_input_preserves_bytes_strict_decoding_consumes_a_complete_bad_line(self):
        body = ("  IO.inspect(Result.ok?(Process.read_bytes(p, -1, 1000)))\n"
                "  IO.inspect(Result.ok?(Process.read_bytes(p, 1048577, 1000)))\n"
                "  IO.inspect(Result.ok?(Process.read_line(p, 0)))\n  IO.inspect(Result.ok?(Process.read_line(p, 5000)))\n"
                "  puts(Result.unwrap!(Process.read_line(p, 5000)))")
        self.assertEqual(self.output(self.program("invalid", body)), "false\nfalse\nfalse\nfalse\nvalid\n")
        body = ("  IO.inspect(Result.ok?(Process.send_bytes(p, [256], 1000)))\n"
                "  IO.inspect(Result.ok?(Process.send_bytes(p, List.append(List.repeat(65, 1048576), 65), 1000)))\n"
                '  Result.unwrap!(Process.send(p, "valid\\n", 5000))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))')
        self.assertEqual(self.output(self.program("echo", body), "peer stderr\n"), "false\nfalse\nvalid\n")

    def test_streaming_exceeds_1_mib_with_concurrent_reads_and_independently_drained_stderr(self):
        drain = ("def drain(p: Process) -> Int\n  first = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n"
                 "  second = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n"
                 "  return List.size(first) + List.size(second)\nend\n\n")
        self.assertEqual(self.output(self.program(
            "flood", "  reader = Task.spawn(&drain, p)\n  IO.inspect(Process.wait(p, 5000))\n  IO.inspect(Task.await(reader))",
            drain)), "ok(0)\n2097152\n")
        result, out, err = self.run_program(self.program("stderr", "  IO.inspect(Process.wait(p, 5000))"))
        self.assertIsNone(result)
        self.assertEqual(out, "ok(0)\n")
        self.assertEqual(len(err), 2097152)

    def test_wait_retries_preserve_children_active_stream_deadlines_abort_them(self):
        body = ("  pid = Result.unwrap!(Process.read_line(p, 5000))\n  reader = Task.spawn(&read, p)\n  Task.sleep(100)\n"
                "  IO.inspect(Result.ok?(Process.read_line(p, 20)))\n"
                '  Result.unwrap!(Process.send(p, "exit\\n", 5000))\n'
                "  IO.inspect(Result.ok?(Task.await(reader)))\n  IO.inspect(Process.wait(p, 5000))")
        read = "def read(p: Process) -> Result[String]\n  return Process.read_line(p, 5000)\nend\n\n"
        self.assertEqual(self.output(self.program("release", body, read)), "false\nfalse\nok(3)\n")
        body = ("  pid = Result.unwrap!(Process.read_line(p, 5000))\n  IO.inspect(Result.ok?(Process.wait(p, 20)))\n"
                '  Result.unwrap!(Process.send(p, "exit\\n", 5000))\n  IO.inspect(Process.wait(p, 5000))')
        self.assertEqual(self.output(self.program("release", body)), "false\nok(3)\n")
        for operation in ("Process.read_line(p, 20)", "Process.send_bytes(p, List.repeat(65, 1048576), 20)"):
            body = ("  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Result.ok?(%s))\n"
                    "  IO.inspect(Result.ok?(Process.wait(p, 20)))" % operation)
            result, out, _ = self.run_program(self.program("hold", body))
            self.assertIsNone(result)
            lines = out.split("\n")
            lines = lines[:-1] if lines[-1] == "" else lines
            self.assertEqual(lines[1:], ["false", "false"])
            self.assertFalse(self.alive(lines[0]))
        self.assertEqual(self.output(self.program(
            "oversized", "  IO.inspect(Result.ok?(Process.read_line(p, 5000)))\n  IO.inspect(Result.ok?(Process.wait(p, 1000)))")),
            "false\nfalse\n")

    def test_every_way_a_run_ends_kills_and_reaps_its_children(self):
        for ending in ("", "  System.exit(4)", "  x = 1 / 0", "  while true\n  end",
                       "  task = Task.spawn(&crash, 0)\n  n = Task.await(task)"):
            with self.subTest(ending=ending):
                result, out, _ = self.run_program(
                    self.program("hold", "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n" + ending,
                                 "def crash(n: Int) -> Int\n  return 1 / 0\nend\n\n"),
                    limit=100 if "while" in ending else None)
                self.assertRegex(out, r"\A[0-9]+\n\Z")
                if "crash" in ending:
                    self.assertEqual(result, "RUNTIME-TASK-CRASHED")
                self.assertFalse(self.alive(out))
        result, out, _ = self.run_program(self.captured("stubborn", "  puts(Result.unwrap!(Process.read_line(p, 5000)))"))
        self.assertIsNone(result)
        self.assertRegex(out, r"\A[0-9]+\n\Z")
        self.assertFalse(self.alive(out))

    def test_closing_a_plain_child_returns_only_after_it_is_gone_even_when_it_ignores_sigterm(self):
        body = ("  pid = Result.unwrap!(Process.read_line(p, 5000))\n  Process.close(p)\n  IO.inspect(%s)" % self.probe("pid"))
        self.assertEqual(self.output(self.program("stubborn", body)), "ok(1)\n")
