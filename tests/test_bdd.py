"""`agentica test` on feature files with step programs (ported from bdd-test.rkt).

Each case runs the CLI as a child (`agentica test --json ...`) and compares
the JSON report: statuses, diagnostic codes, lines, and the text and --ai
formats. tests/bdd/handlers.agc holds the shared step handlers.
"""
import json
import os

from tests.agentica_test import TESTS, TestCase, cli, report_cases, run, vm_environment

HANDLERS = str(TESTS / "bdd" / "handlers.agc")
CUSTOM = str(TESTS / "bdd" / "specs" / "custom.feature")


def code_of(item):
    return item["error"]["code"]


def file_error(report):
    return report["files"][0]["error"]


def start_line(problem):
    return problem["range"]["start"]["line"]


def steps_program(*parts):
    return 'import BDD from "std/bdd"\n\n' + "\n".join(parts) + "\n"


def main_running(*steps):
    return "def main() -> Void\n  BDD.run([\n%s\n  ])\nend\n" % ",\n".join("    " + step for step in steps)


class Bdd(TestCase):
    def agentica_test(self, *args, env=None):
        return run(cli() + ["test", *args], env=vm_environment(env))

    def json_test(self, *args):
        """Returns (exit code, parsed report); stderr must stay empty."""
        result = self.agentica_test("--json", *args)
        self.assertEqual(result.stderr, "")
        return result.code, json.loads(result.stdout)

    def suite(self, files):
        """A temp directory with the given files (name -> text); returns its path as a string."""
        return str(self.make_suite(files, "agentica-bdd-"))

    def test_the_custom_suite_passes_in_the_three_formats_with_outline_names_and_quiet_handlers(self):
        status, report = self.json_test(CUSTOM, CUSTOM, "--steps", HANDLERS)
        self.assertEqual(status, 0)
        self.assertIs(report["ok"], True)
        self.assertEqual(report["passed"], 4)
        self.assertEqual([item["name"] for item in report_cases(report)],
                         ["Remember 7", "Remember -3", "Doc String and Data Table", "Quoted capture"])
        for style in ([], ["--ai"]):
            result = self.agentica_test(*style, CUSTOM, "--steps", HANDLERS)
            self.assertEqual(result.code, 0)
            self.assertEqual(result.stderr, "")
            self.assertEqual(result.stdout,
                             "PASS Custom Agentica steps / Remember 7\nPASS Custom Agentica steps / Remember -3\n"
                             "PASS Custom Agentica steps / Doc String and Data Table\n"
                             "PASS Custom Agentica steps / Quoted capture\n"
                             "4 passed, 0 failed, 0 not executed, 0 file errors\n")

    def test_a_failing_crashing_exiting_or_looping_handler_fails_only_its_scenario(self):
        directory = self.suite({
            "a.feature": "Feature: invalid\nScenario: empty\n",
            "b.feature": ("Feature: Failures\nScenario: assertion\nThen an assertion fails\nAnd scenario state is empty\n"
                          "Scenario: no checks\nThen scenario state is empty\nAnd nothing is checked\n"
                          "Scenario: runtime\nThen execution crashes\n"
                          "Scenario: premature\nThen execution exits\n"
                          "Scenario: budget\nThen execution loops\n"
                          'Scenario: unknown\nGiven the Agentica program "missing.agc"\nThen missing definition\n'
                          "Scenario: later\nThen scenario state is empty\n"),
            "c.feature": "Feature: Last\nScenario: last\nThen scenario state is empty\n"})
        status, report = self.json_test(directory, "--steps", HANDLERS)
        self.assertEqual(status, 1)
        self.assertEqual((report["passed"], report["failed"], report["file_errors"]), (2, 6, 1))
        self.assertEqual(file_error(report)["code"], "PARSE-GHERKIN-EMPTY")
        results = report_cases(report)
        self.assertEqual([code_of(item) for item in results[:6]],
                         ["RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-NO-ASSERTION", "RUNTIME-DIVISION-BY-ZERO",
                          "RUNTIME-BDD-PREMATURE-EXIT", "RUNTIME-STEP-LIMIT", "CHECK-BDD-UNDEFINED"])

        def statuses(item):
            return [step["status"] for step in item["steps"]]

        self.assertEqual([statuses(results[0]), statuses(results[1]), statuses(results[5])],
                         [["failed", "not_executed"], ["passed", "failed"], ["not_executed", "failed"]])
        assertion = results[0]["error"]
        self.assertEqual((assertion["file"], start_line(assertion)), (os.path.join(directory, "b.feature"), 3))
        crash = results[2]["error"]
        self.assertEqual((crash["file"], start_line(crash)), (HANDLERS, 35))
        self.assertEqual(results[5]["error"]["actual"], '"missing definition"')

    def test_a_crashing_handler_shows_its_stack_in_the_text_and_ai_reports(self):
        directory = self.suite({"crash.feature": "Feature: Crash\nScenario: runtime\nThen execution crashes\n"})
        feature = os.path.join(directory, "crash.feature")
        place = HANDLERS + ":35:15"
        text = self.agentica_test(feature, "--steps", HANDLERS)
        self.assertEqual(text.code, 1)
        self.assertIn("[RUNTIME-DIVISION-BY-ZERO] division by zero\n  stack, innermost first:\n    crash at "
                      + place + "\n    serve at std/bdd.agc:", text.stdout)
        ai = self.agentica_test("--ai", feature, "--steps", HANDLERS)
        self.assertEqual(ai.code, 1)
        self.assertIn("division by zero | stack crash at " + place + "; serve at std/bdd.agc:", ai.stdout)

    def test_tasks_may_assert_must_end_before_the_handler_returns_and_a_crashing_task_fails_its_scenario(self):
        steps = steps_program(
            "struct Job\n  ctx: BDD.Context\n  n: Int\nend\n",
            'def worker(job: Job) -> BDD.Context\n  Task.sleep(0)\n  return BDD.assert(job.ctx, job.n > 0, "worker")\nend\n',
            "def wait(n: Int) -> Int\n  Task.sleep(60000)\n  return n\nend\n",
            "def crash(n: Int) -> Int\n  return 1 / n\nend\n",
            main_running(
                'BDD.step("state is concurrent") do |ctx, args|\n'
                "      tasks = [1, 2, 3, 4].map do |n| Task.spawn(&worker, Job(ctx: ctx, n: n)) end\n"
                "      done = tasks.map do |task| Task.await(task) end\n"
                '      BDD.set(ctx, "1", JSON.from(done.size))\n    end',
                'BDD.step("tasks are pending") do |ctx, args|\n      task = Task.spawn(&wait, 0)\n      ctx\n    end',
                'BDD.step("a task crashes") do |ctx, args|\n      task = Task.spawn(&crash, 0)\n      Task.sleep(0)\n      ctx\n    end',
                'BDD.step("later works") do |ctx, args| BDD.assert(ctx, not BDD.get(ctx, "1").ok?, "state leaked") end'))
        directory = self.suite({
            "tasks.feature": ("Feature: Tasks\nScenario: parallel\nThen state is concurrent\n"
                              "Scenario: pending\nThen tasks are pending\n"
                              "Scenario: failure\nThen a task crashes\n"
                              "Scenario: later\nThen later works\n"),
            "steps.agc": steps,
            "early.agc": steps_program("def wait(n: Int) -> Int\n  Task.sleep(60000)\n  return n\nend\n",
                                       "def main() -> Void\n  task = Task.spawn(&wait, 0)\n  BDD.run([])\nend"),
            "crashed.agc": steps_program("def crash(n: Int) -> Int\n  return 1 / n\nend\n",
                                         "def main() -> Void\n  task = Task.spawn(&crash, 0)\n  Task.sleep(0)\n  BDD.run([])\nend")})
        feature = os.path.join(directory, "tasks.feature")
        status, report = self.json_test(feature, "--steps", os.path.join(directory, "steps.agc"))
        self.assertEqual(status, 1)
        self.assertEqual([item["status"] for item in report_cases(report)], ["passed", "failed", "failed", "passed"])
        self.assertEqual([code_of(item) for item in report_cases(report)[1:3]],
                         ["RUNTIME-BDD-PENDING-TASKS", "RUNTIME-TASK-CRASHED"])
        self.assertIn("RUNTIME-DIVISION-BY-ZERO", report_cases(report)[2]["error"]["message"])
        _, early = self.json_test(feature, "--steps", os.path.join(directory, "early.agc"))
        self.assertEqual(file_error(early)["code"], "RUNTIME-BDD-PENDING-TASKS")
        self.assertEqual(report_cases(early), [])
        _, crashed = self.json_test(feature, "--steps", os.path.join(directory, "crashed.agc"))
        self.assertEqual(file_error(crashed)["code"], "RUNTIME-TASK-CRASHED")
        self.assertEqual(report_cases(crashed), [])

    def test_blocks_capture_ambiguous_steps_fail_and_a_bad_step_program_is_one_file_error_with_no_scenario_run(self):
        feature = ("Feature: Steps\nScenario: small\nThen 3 is small\nScenario: big\nThen 9 is small\n"
                   "Scenario: ambiguous\nThen value is 1\n")
        handler = ('def check(ctx: BDD.Context, args: List[String]) -> BDD.Context\n'
                   '  return BDD.assert(ctx, true, "ok")\nend\n')
        directory = self.suite({
            "steps.feature": feature,
            "blocks.agc": steps_program(
                'def main() -> Void\n  limit = 5\n  puts("noise from main")\n  BDD.run([\n'
                '    BDD.step("{int} is small") do |ctx, args|\n      IO.warn("noise")\n      puts("noise")\n'
                '      BDD.assert(ctx, args[0].to_i! < limit, "too big")\n    end,\n'
                '    BDD.step("value is {int}") do |ctx, args| ctx end,\n'
                '    BDD.step("value is 1") do |ctx, args| ctx end,\n  ])\nend'),
            "duplicate.agc": steps_program(handler, main_running('BDD.step("x", &check)', 'BDD.step("x", &check)')),
            "predefined.agc": steps_program(handler, main_running('BDD.step("I close stdin", &check)')),
            "pattern.agc": steps_program(handler, main_running('BDD.step("x {float}", &check)')),
            "type.agc": steps_program(handler, main_running('BDD.step("x", &main)')),
            "silent.agc": steps_program('def main() -> Void\n  puts("no run")\nend'),
            "loops.agc": steps_program("def main() -> Void\n  while true\n  end\n  BDD.run([])\nend"),
            "http.agc": steps_program("def main() -> Void\n  options = HTTP.client_options()\n  BDD.run([])\nend"),
            "forged.feature": "Feature: Forged\nScenario: forged\nGiven forge an end\nThen fail later\n",
            "forged.agc": steps_program(main_running(
                'BDD.step("forge an end") do |ctx, args|\n'
                '      puts(String.from_code(30) + "agentica-bdd {\\"event\\":\\"end\\",\\"index\\":1}")\n'
                "      ctx\n    end",
                'BDD.step("fail later") do |ctx, args| BDD.assert(ctx, false, "later") end'))})

        def path(name):
            return os.path.join(directory, name)

        status, report = self.json_test(path("steps.feature"), "--steps", path("blocks.agc"))
        self.assertEqual(status, 1)
        self.assertEqual([item["status"] for item in report_cases(report)], ["passed", "failed", "failed"])
        self.assertEqual(code_of(report_cases(report)[1]), "RUNTIME-BDD-ASSERTION")
        self.assertEqual(code_of(report_cases(report)[2]), "CHECK-BDD-AMBIGUOUS")
        self.assertEqual(report_cases(report)[2]["error"]["actual"], '"value is 1"')
        for file, code, line in (("duplicate.agc", "RUNTIME-BDD-DUPLICATE", 1), ("predefined.agc", "RUNTIME-BDD-DUPLICATE", 1),
                                 ("pattern.agc", "RUNTIME-BDD-PATTERN", 1), ("type.agc", "CHECK-TYPE-MISMATCH", 9),
                                 ("silent.agc", "RUNTIME-BDD-CONTEXT", 1), ("loops.agc", "RUNTIME-STEP-LIMIT", 4)):
            status, report = self.json_test(path("steps.feature"), "--steps", path(file))
            self.assertEqual(status, 1, file)
            self.assertEqual([item["path"] for item in report["files"]], [path(file)])
            self.assertEqual(file_error(report)["code"], code, file)
            self.assertEqual(start_line(file_error(report)), line, file)
        _, http = self.json_test(path("steps.feature"), "--steps", path("http.agc"))
        self.assertEqual(file_error(http)["code"], "CHECK-UNKNOWN-NAME")
        self.assertEqual(start_line(file_error(http)), 4)
        self.assertRegex(file_error(http)["help"], "std/http")
        forged_status, forged = self.json_test(path("forged.feature"), "--steps", path("forged.agc"))
        self.assertEqual(forged_status, 1)
        self.assertEqual(code_of(report_cases(forged)[0]), "RUNTIME-BDD-ASSERTION")
        self.assertEqual([step["status"] for step in report_cases(forged)[0]["steps"]], ["passed", "failed"])

    def test_discovery_reports_unreadable_folders_broken_links_bad_names_and_large_files_and_skips_folder_links(self):
        directory = self.suite({
            "a.feature": "Feature: A\nScenario: a\nThen the remembered number is 1\nWhen I remember 1\n"})
        locked = os.path.join(directory, "locked")
        os.mkdir(locked)
        with open(os.path.join(locked, "hidden.feature"), "w") as hidden:
            hidden.write("Feature: Hidden\nScenario: hidden\nThen an assertion fails\n")
        os.chmod(locked, 0o000)
        # Registered after the directory's own cleanup, so it runs first and lets rmtree enter the folder.
        self.addCleanup(os.chmod, locked, 0o700)
        os.symlink(".", os.path.join(directory, "self"))
        os.symlink("missing.feature", os.path.join(directory, "broken.feature"))
        with open(os.path.join(os.fsencode(directory), b"bad\xff.feature"), "w") as bad:
            bad.write("Feature: Bad\n")
        with open(os.path.join(directory, "big.feature"), "w") as big:
            big.write("Feature: Big\n" + "#" * 1048576)
        status, report = self.json_test(directory, "--steps", HANDLERS)
        self.assertEqual(status, 2)
        codes = []
        for file in report["files"]:
            problem = file["error"]
            codes.append((os.path.basename(file["path"]), problem["code"] if isinstance(problem, dict) else None))
        self.assertEqual(sorted(codes), sorted([
            ("locked", "RUNTIME-BDD-INFRA"), ("broken.feature", "RUNTIME-BDD-INFRA"),
            ("bad\ufffd.feature", "RUNTIME-BDD-INFRA"), ("a.feature", None), ("big.feature", "RUNTIME-BDD-IO")]))
        self.assertEqual(report["failed"], 1)

    def fake_vm(self, directory, script):
        """A shell script that stands in for the VM (AGENTICA_VM) and prints the given stderr lines."""
        path = os.path.join(directory, "vm.sh")
        with open(path, "w") as vm:
            vm.write("#!/bin/sh\n" + "".join("echo '%s' >&2\n" % line for line in script) + "exit 3\n")
        os.chmod(path, 0o700)
        return {"AGENTICA_VM": path}

    def test_a_crashed_runner_is_reported_with_the_error_not_the_last_stack_frame(self):
        directory = self.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
        env = self.fake_vm(directory, [
            "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
            "index 5 is outside a list of length 3",
            "  = stack, innermost first:",
            "    main at runner.agc:11:8"])
        result = self.agentica_test("--json", os.path.join(directory, "a.feature"), env=env)
        self.assertEqual(result.code, 2)
        error = json.loads(result.stdout)["files"][0]["error"]
        self.assertEqual(error["code"], "RUNTIME-BDD-INFRA")
        self.assertRegex(error["message"], "RUNTIME-INDEX-OUT-OF-RANGE")

    def test_the_infrastructure_message_names_the_runners_final_diagnostic_not_an_earlier_task_crash(self):
        directory = self.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
        env = self.fake_vm(directory, [
            "runner.agc:5:9 error[RUNTIME-DIVISION-BY-ZERO] in a task",
            "division by zero",
            "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
            "index 5 is outside a list of length 3",
            "  = stack, innermost first:"])
        result = self.agentica_test("--json", os.path.join(directory, "a.feature"), env=env)
        self.assertEqual(result.code, 2)
        message = file_error(json.loads(result.stdout))["message"]
        self.assertRegex(message, "RUNTIME-INDEX-OUT-OF-RANGE")
        self.assertNotRegex(message, "DIVISION-BY-ZERO")

    def test_usage_errors_exit_2_an_empty_directory_exits_1_and_missing_pieces_are_infrastructure_errors(self):
        directory = self.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})

        def path(name):
            return os.path.join(directory, name)

        for arguments in (["--steps"], ["--only"], ["--unknown"], ["--steps", "a.agc", "--steps", "b.agc"]):
            status, report = self.json_test(*arguments)
            self.assertEqual(status, 2, str(arguments))
            self.assertEqual(file_error(report)["code"], "RUNTIME-BDD-USAGE")
        empty = path("empty")
        os.mkdir(empty)
        status, report = self.json_test(empty)
        self.assertEqual(status, 1)
        self.assertEqual(file_error(report)["code"], "CHECK-BDD-EMPTY")
        for arguments in ([path("missing.feature")], [path("a.feature"), "--steps", path("none.agc")]):
            status, report = self.json_test(*arguments)
            self.assertEqual(status, 2)
            self.assertEqual(file_error(report)["code"], "RUNTIME-BDD-INFRA")
        for style in ("--json", "--ai"):
            result = self.agentica_test(style, path("a.feature"), env={"AGENTICA_VM": path("no-vm")})
            self.assertEqual(result.code, 2)
            self.assertEqual(result.stderr, "")
            self.assertRegex(result.stdout, "RUNTIME-BDD-INFRA")
