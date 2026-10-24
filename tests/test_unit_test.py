"""`agentica test` on *_test.agc files.

Each case runs the CLI as a child on the fixtures of tests/fixtures/unit/ and compares the JSON report, or the text
and --ai formats. The report of a hung test needs the test deadline, which the CLI does not set (30 s), so that case is
slow.
"""
import json
import time
from pathlib import Path

from tests.agentica_test import FIXTURES, TESTS, TestCase, cli, report_cases, run, scaled, slow, vm_environment

UNIT = FIXTURES / "unit"
STD_TESTS = str(TESTS / "std")
HANDLERS = str(TESTS / "bdd" / "handlers.agc")
MEBIBYTE_REPORT_LIMIT = 65536


def fixture(name):
    return str(UNIT / name)


def field(item, key):
    problem = item["error"]
    return problem.get(key) if isinstance(problem, dict) else None


def start_line(problem):
    return problem["range"]["start"]["line"]


def file_codes(report):
    """[(kind, code of the file's error or None)] in file order."""
    return [(file["kind"], file["error"]["code"] if isinstance(file["error"], dict) else None)
            for file in report["files"]]


def statuses(report):
    return [item["status"] for item in report_cases(report)]


def processes_mentioning(directory):
    """The pids of the processes whose command line holds the folder name."""
    needle = str(directory).encode()
    found = []
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            try:
                if needle in (entry / "cmdline").read_bytes():
                    found.append(entry.name)
            except OSError:
                continue
    return found


class UnitTest(TestCase):
    def agentica_test(self, *arguments, cwd=None, env=None, flags=()):
        """`agentica [flags] test ARGUMENTS`; returns Result(code, stdout, stderr)."""
        return run(cli() + [*flags, "test", *arguments], cwd=cwd, env=vm_environment(env))

    def json_test(self, *arguments, cwd=None, env=None):
        """Returns (exit code, parsed report); stderr must stay empty."""
        result = self.agentica_test("--json", *arguments, cwd=cwd, env=env)
        self.assertEqual(result.stderr, "")
        return result.code, json.loads(result.stdout)

    def test_a_test_file_reports_each_outcome_with_captured_output_only_for_failed_tests(self):
        status, report = self.json_test(fixture("outcomes_test.agc"))
        self.assertEqual(status, 1)
        results = report_cases(report)
        self.assertEqual(statuses(report), ["passed", "failed", "failed", "failed", "passed", "failed", "failed", "passed"])
        self.assertEqual([field(item, "code") for item in results], [
            None, "RUNTIME-TEST-ASSERTION", "RUNTIME-TEST-ERROR", "RUNTIME-DIVISION-BY-ZERO", None,
            "RUNTIME-TEST-PENDING-TASKS", "RUNTIME-TASK-CRASHED", None])
        compared = results[1]
        self.assertEqual([field(compared, "expected"), field(compared, "actual")], ['"c"', '"a\\"b"'])
        self.assertEqual(start_line(compared["error"]), 19)
        self.assertEqual(start_line(results[3]["error"]), 2)
        self.assertEqual([frame["function"] for frame in results[3]["error"]["stack"]], ["divide", "block"])
        self.assertNotIn("stack", compared["error"])
        self.assertEqual(compared["output"], 'first line\n\x1eagentica-bdd {"event":"pass"}')
        self.assertEqual([results[index]["output"] for index in (0, 2, 3)], ["", "", ""])
        self.assertEqual(report["files"][0]["kind"], "tests")
        self.assertEqual((report["passed"], report["failed"], report["not_executed"]), (3, 5, 0))
        plain = self.agentica_test(fixture("outcomes_test.agc")).stdout
        self.assertIn(':19:7 [RUNTIME-TEST-ASSERTION] values are not equal; expected "c"; actual "a\\"b"\n  first line\n',
                      plain)
        self.assertNotIn("quiet when passing", plain)
        self.assertIn("[RUNTIME-DIVISION-BY-ZERO] division by zero\n  stack, innermost first:\n    divide at ", plain)
        ai = self.agentica_test("--ai", fixture("outcomes_test.agc")).stdout
        self.assertIn('actual "a\\"b" | output "first line\\n\\u001Eagentica-bdd ', ai)
        self.assertRegex(ai, r"\[RUNTIME-DIVISION-BY-ZERO\] division by zero \| stack divide at [^;]*:2:13; block at ")

    def test_a_stack_cut_after_15_frames_says_how_many_frames_are_not_shown_in_the_text_and_ai_reports(self):
        plain = self.agentica_test(fixture("deep_test.agc")).stdout
        ai = self.agentica_test("--ai", fixture("deep_test.agc")).stdout

        def section(text, name):
            return [part for part in text.split("FAIL ") if "/ " + name in part][0]

        for omitted, name in [("1 frame", "one frame cut"), ("2 frames", "two frames cut")]:
            self.assertRegex(
                section(plain, name),
                r"stack, innermost first:\n(?:    (?:ping|pong) at [^\n]*\n){15}    \.\.\. %s not shown \.\.\.\n" % omitted)
            self.assertRegex(section(ai, name), r"(?:(?:ping|pong) at [^;]*; ){15}\.\.\. %s not shown \.\.\.; " % omitted)

    def test_an_exit_ends_the_files_run_and_bad_names_are_a_file_error(self):
        status, report = self.json_test(fixture("stops_test.agc"), fixture("names_test.agc"))
        self.assertEqual(status, 1)
        names = report["files"][0]
        self.assertEqual((names["error"]["code"], start_line(names["error"])), ("RUNTIME-TEST-NAME", 6))
        stops = report_cases(report)
        self.assertEqual([item["status"] for item in stops], ["passed", "failed", "not_executed"])
        self.assertEqual(field(stops[1], "code"), "RUNTIME-BDD-PREMATURE-EXIT")
        self.assertEqual(stops[1]["output"], "going away")
        self.assertEqual(report["not_executed"], 1)

    @slow
    def test_a_timeout_ends_the_files_run_and_leaves_no_process_behind(self):
        # The deadline of a test is 30 s and has no flag, so this waits for it.
        temporary = self.make_temp_dir("agentica-hangs-").resolve()
        status, report = self.json_test(fixture("hangs_test.agc"), env={"TMPDIR": temporary})
        self.assertEqual(status, 1)
        hung = report_cases(report)
        self.assertEqual([item["status"] for item in hung], ["failed", "not_executed"])
        self.assertEqual(field(hung[0], "code"), "RUNTIME-TEST-TIMEOUT")
        self.assertEqual(hung[0]["output"], "before the hang")
        self.assertEqual(processes_mentioning(temporary), [])

    def test_only_keeps_matching_tests_and_a_test_draws_the_same_values_alone_or_with_others(self):
        seed = fixture("seed_test.agc")

        def draws(number, *arguments):
            result = run(cli() + ["--seed", number, "test", "--json", *arguments], env=vm_environment())
            return [(item["name"], field(item, "actual")) for item in report_cases(json.loads(result.stdout))]

        everything = draws("7", seed)
        alone = draws("7", "--only", "second", seed)
        self.assertEqual(alone, [everything[1]])
        self.assertNotEqual(draws("8", "--only", "second", seed), alone)
        _status, drawn = self.json_test(seed)
        self.assertIsInstance(drawn["seed"], int)
        self.assertGreaterEqual(drawn["seed"], 0)
        text = run(cli() + ["--seed", "7", "test", seed], env=vm_environment()).stdout
        self.assertTrue(text.endswith("0 passed, 2 failed, 0 not executed, 0 file errors, seed 7\n"), text)
        status, none = self.json_test("--only", "nothing", seed)
        self.assertEqual((status, report_cases(none), file_codes(none)), (1, [], [("tests", None), ("", "CHECK-BDD-EMPTY")]))
        for arguments in [["--only", ""], ["--only", "a", "--only", "b"]]:
            usage_status, report = self.json_test(*arguments, seed)
            self.assertEqual((usage_status, file_codes(report)), (2, [("", "RUNTIME-BDD-USAGE")]))
        usage = run(cli() + ["--seed", "5", "test", "--json", "--only", ""], env=vm_environment())
        self.assertEqual(json.loads(usage.stdout)["seed"], 5)

    def test_a_file_that_fails_before_its_tests_run_is_a_file_error_that_shows_what_it_printed(self):
        status, report = self.json_test(fixture("lists"))
        self.assertEqual(status, 1)
        self.assertEqual(file_codes(report), [
            ("tests", "RUNTIME-BDD-PREMATURE-EXIT"), ("tests", "RUNTIME-DIVISION-BY-ZERO"), ("tests", "RUNTIME-TEST-NAME"),
            ("tests", "RUNTIME-TEST-RUN")])
        self.assertEqual([file["output"] for file in report["files"]], ["bad config", "loading", "", "no tests here"])
        plain = self.agentica_test(fixture("lists/config_test.agc")).stdout
        self.assertIn("exited with code 3\n  bad config\n", plain)

    def test_a_test_owns_its_stdin_and_stdout_so_records_it_prints_are_plain_output(self):
        status, free = self.json_test(fixture("free_io_test.agc"))
        self.assertEqual(status, 1)
        results = report_cases(free)
        self.assertEqual([item["status"] for item in results], ["passed", "failed", "passed"])
        self.assertEqual(field(results[1], "code"), "RUNTIME-TEST-ASSERTION")
        self.assertEqual(results[1]["output"], '{"event":"pass"}\nno newline')
        self.assertEqual(file_codes(free), [("tests", None)])
        self.assertEqual(free["passed"], 2)

    def test_output_limits_are_1_mib_per_test_with_a_64_ki_tail(self):
        _status, noisy = self.json_test(fixture("noisy_test.agc"))
        items = report_cases(noisy)
        self.assertEqual([item["status"] for item in items], ["failed", "not_executed"])
        self.assertEqual(field(items[0], "code"), "RUNTIME-BDD-OUTPUT-LIMIT")
        output = items[0]["output"]
        self.assertTrue(1 <= len(output) <= MEBIBYTE_REPORT_LIMIT)
        self.assertRegex(output, r"^y+")
        _status, chatty = self.json_test(fixture("chatty_test.agc"))
        self.assertEqual([(item["status"], field(item, "code")) for item in report_cases(chatty)],
                         [("failed", "RUNTIME-BDD-OUTPUT-LIMIT"), ("not_executed", None)])
        self.assertEqual(file_codes(chatty), [("tests", None)])

    def test_test_files_and_features_share_one_report_and_test_is_a_default_path(self):
        status, report = self.json_test(fixture("mixed"), "--steps", HANDLERS)
        self.assertEqual(status, 1)
        self.assertEqual(file_codes(report), [("tests", "CHECK-TYPE-MISMATCH"), ("tests", None), ("feature", None)])
        self.assertEqual(report["passed"], 2)
        _status, only = self.json_test(fixture("mixed"), "--steps", HANDLERS, "--only", "state starts")
        self.assertEqual([item["name"] for item in report_cases(only)], ["state starts empty"])
        broken_status, broken = self.json_test(fixture("mixed"), "--steps", fixture("steps/broken_steps.agc"))
        self.assertEqual(broken_status, 1)
        self.assertEqual(file_codes(broken), [("steps", "CHECK-TYPE-MISMATCH"), ("tests", "CHECK-TYPE-MISMATCH"), ("tests", None)])
        self.assertEqual(broken["passed"], 1)
        alone_status, alone = self.json_test(fixture("mixed/fine_test.agc"), "--steps", fixture("steps/broken_steps.agc"))
        self.assertEqual((alone_status, file_codes(alone)), (1, [("steps", "CHECK-TYPE-MISMATCH"), ("tests", None)]))
        unlisted_status, _unlisted = self.json_test(fixture("mixed/fine_test.agc"), "--steps", fixture("steps/crash_steps.agc"))
        self.assertEqual(unlisted_status, 0)
        directory = self.make_temp_dir("agentica-unit-").resolve()
        (directory / "test").mkdir()
        (directory / "test" / "fine_test.agc").write_bytes((UNIT / "mixed" / "fine_test.agc").read_bytes())
        self.assertEqual(self.agentica_test(cwd=directory).code, 0)
        (directory / "test" / "fine_test.agc").unlink()
        (directory / "test").rmdir()
        _status, empty = self.json_test(cwd=directory)
        self.assertEqual(file_codes(empty), [("", "CHECK-BDD-EMPTY")])

    def test_deny_flags_reach_the_test_files_and_the_programs_under_test_but_not_the_runner(self):
        # The runner still reads the folders and starts the children; the user's code runs with --deny-env, given
        # once in front of `test` and once after it.
        directory = self.make_temp_dir("agentica-unit-").resolve()
        (directory / "test").mkdir()
        (directory / "test" / "env_test.agc").write_text(
            'def main() -> Void\n  Test.run([\n    Test.test("reads HOME") do\n      Test.eq(try System.env("HOME"), "")\n'
            '    end,\n  ])\nend\n', encoding="utf-8")
        (directory / "specs").mkdir()
        (directory / "specs" / "env.agc").write_text('def main() -> Void\n  puts(System.env("HOME").ok?)\nend\n',
                                                     encoding="utf-8")
        (directory / "specs" / "env.feature").write_text(
            'Feature: env\n  Scenario: the program under test\n    Given the Agentica program "env.agc"\n'
            '    Then the program exits with code 0 within 5000 milliseconds\n    And stdout is:\n'
            '      """\n      false\n\n      """\n', encoding="utf-8")
        result = self.agentica_test("--json", "--deny-env", "test", "specs", cwd=directory, flags=["--deny-env"])
        self.assertEqual((result.code, result.stderr), (1, ""))
        report = json.loads(result.stdout)
        failed = [item for item in report_cases(report) if item["status"] == "failed"]
        self.assertEqual([item["name"] for item in failed], ["reads HOME"])
        self.assertEqual(failed[0]["error"]["code"], "RUNTIME-TEST-ERROR")
        self.assertTrue(failed[0]["error"]["message"].startswith("denied: --deny-env"))
        self.assertEqual(report["passed"], 1)

    def test_the_std_unit_tests_pass(self):
        status, report = self.json_test(STD_TESTS)
        self.assertEqual(status, 0)
        self.assertEqual((report["passed"], report["failed"]), (23, 0))

    @slow
    def test_a_stderr_flood_a_print_without_end_and_a_flooding_step_listing_hit_the_output_limits(self):
        status, flood = self.json_test(fixture("flood_test.agc"))
        self.assertEqual(status, 1)
        self.assertEqual(flood["failed"], 0)
        self.assertEqual(file_codes(flood), [("tests", "RUNTIME-BDD-OUTPUT-LIMIT")])
        self.assertTrue(flood["files"][0]["output"].startswith("xxx"))
        started = time.monotonic()
        _status, endless = self.json_test(fixture("endless_test.agc"))
        self.assertLess(time.monotonic() - started, min(scaled(15), 25))
        self.assertEqual([(item["status"], field(item, "code")) for item in report_cases(endless)],
                         [("failed", "RUNTIME-BDD-OUTPUT-LIMIT"), ("not_executed", None)])
        started = time.monotonic()
        _status, listing = self.json_test(fixture("listing_flood_test.agc"))
        self.assertLess(time.monotonic() - started, min(scaled(15), 25))
        self.assertEqual(file_codes(listing), [("tests", "RUNTIME-BDD-OUTPUT-LIMIT")])
