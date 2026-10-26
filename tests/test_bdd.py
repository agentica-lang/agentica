"""`agentica test` on feature files with step programs.

Each case runs the CLI as a child (`agentica test --json ...`) and compares
the JSON report: statuses, diagnostic codes, lines, and the text and --ai
formats. tests/bdd/handlers.agc holds the shared step handlers. The cases that
need a runner that fails run the front end as an ordinary program with a
stand-in for the binary it starts again (front_end_command and fake_binary: a
shell script, or on Windows a copy of node.exe).
"""
import ast
import contextlib
import json
import os
import re
import shutil
import tempfile
import time
from pathlib import Path

import pytest

from tests.agentica_test import (ROOT, TESTS, UNDER_WINE, binary, cli, front_end_command, report_cases, run,
                                 tool, vm_environment, write_files)

# Paths are written with "/" on every system, as the driver reports them (it joins and resolves with "/").
HANDLERS = (TESTS / "bdd" / "handlers.agc").as_posix()
ADDS_TEST = 'def main() -> Void\n  Test.run([Test.test("adds") do\n    Test.eq(1 + 1, 2)\n  end])\nend\n'
CUSTOM = (TESTS / "bdd" / "specs" / "custom.feature").as_posix()


def joined(directory, name):
    """The path of `name` in `directory`, written with "/" like the paths in a report."""
    return (Path(directory) / name).as_posix()


def code_of(item):
    return item["error"]["code"]


def file_error(report):
    return report["files"][0]["error"]


def assert_unwritable_temporary_is_an_infrastructure_error(bdd, scratch, temporary, system_text):
    """`agentica test` with TMPDIR at a folder that cannot be written ends with the infrastructure error that names it
    and the text of the system for the refusal (`system_text`), and leaves the folder empty."""
    result = bdd.agentica_test("--json", scratch / "missing.feature", env={"TMPDIR": temporary}, cwd=scratch)
    assert (result.code, result.stderr) == (2, "")
    problem = file_error(json.loads(result.stdout))
    assert problem["code"] == "RUNTIME-BDD-INFRA"
    assert ("cannot make a private directory in %s" % temporary) in problem["message"]
    assert system_text in problem["message"]
    assert os.listdir(temporary) == []


def start_line(problem):
    return problem["range"]["start"]["line"]


def without_chance(value):
    """A report without what differs between two runs of the same suite: the seed and the durations."""
    if isinstance(value, dict):
        return {key: without_chance(item) for key, item in value.items() if key not in ("seed", "duration_ms")}
    if isinstance(value, list):
        return [without_chance(item) for item in value]
    return value


def steps_program(*parts):
    return 'import BDD from "std/bdd"\n\n' + "\n".join(parts) + "\n"


# Waits until every task but main has ended (returned or crashed), so a crash is seen whatever the number of
# schedulers; a yield (Task.sleep(0)) lets the crashing task run first only on one scheduler.
SETTLE = "def settle() -> Void\n  while Task.pending_count() > 0\n    Task.sleep(1)\n  end\nend\n"


def main_running(*steps):
    return "def main() -> Void\n  BDD.run([\n%s\n  ])\nend\n" % ",\n".join("    " + step for step in steps)


class BddCli:
    """`agentica test` for the cases here: a private TMPDIR per run and a suite folder under the test's `tmp_path`."""

    def __init__(self, tmp_path):
        self.tmp_path = tmp_path

    def agentica_test(self, *args, env=None, cwd=None, binary_path=None):
        """`agentica test`; with binary_path, the front end runs as an ordinary program that starts that path (a
        script) in place of the binary."""
        test_env = dict(env or {})
        if "TMPDIR" not in test_env:
            # A normal case never sweeps another case's private handoff folder.
            test_env["TMPDIR"] = tempfile.mkdtemp(prefix="agentica-bdd-run-tmp-", dir=self.tmp_path)
        if binary_path is not None:
            return run(front_end_command(binary_path, "test", *args), env=vm_environment(test_env), cwd=cwd)
        return run(cli() + ["test", *args], env=vm_environment(test_env), cwd=cwd)

    def json_test(self, *args, **options):
        """Returns (exit code, parsed report); stderr must stay empty."""
        result = self.agentica_test("--json", *args, **options)
        assert result.stderr == ""
        return result.code, json.loads(result.stdout)

    def make_suite(self, files, prefix="agentica-bdd-"):
        """A resolved temp dir holding the given files (name -> text); removed when the test ends."""
        directory = Path(tempfile.mkdtemp(prefix=prefix, dir=self.tmp_path)).resolve()
        write_files(directory, files)
        return directory

    def suite(self, files):
        """A temp directory with the given files (name -> text); returns its path as a Path."""
        return self.make_suite(files)


@pytest.fixture
def bdd(tmp_path):
    """The `agentica test` helper of this module, with a per-test scratch folder."""
    return BddCli(tmp_path)


def test_the_custom_suite_passes_in_the_three_formats_with_outline_names_and_quiet_handlers(bdd):
    status, report = bdd.json_test(CUSTOM, CUSTOM, "--steps", HANDLERS)
    assert status == 0
    assert report["ok"] is True
    assert report["passed"] == 4
    assert [item["name"] for item in report_cases(report)] == [
        "Remember 7", "Remember -3", "Doc String and Data Table", "Quoted capture"]
    for style in ([], ["--ai"]):
        result = bdd.agentica_test(*style, CUSTOM, "--steps", HANDLERS)
        assert result.code == 0
        assert result.stderr == ""
        assert result.stdout == (
            "PASS Custom Agentica steps / Remember 7\nPASS Custom Agentica steps / Remember -3\n"
            "PASS Custom Agentica steps / Doc String and Data Table\nPASS Custom Agentica steps / Quoted capture\n"
            "4 passed, 0 failed, 0 not executed, 0 file errors\n")


def test_the_runner_and_the_steps_the_binary_carries_give_the_report_of_ones_compiled_from_the_sources(bdd):
    """The binary starts its own compiled runner and default step program (`run --embedded`); a front end that
    reads the std/ sources from a folder compiles them. Both must report the same."""
    steps = ('Given the Agentica program "hello.agc"\nWhen I close stdin\n'
             'Then I receive the line "%s" within 5000 milliseconds\n')
    directory = bdd.suite({
        "hello.agc": 'def main() -> Void\n  puts("hi")\nend\n',
        "a.feature": "Feature: A\nScenario: right\n" + steps % "hi" + "Scenario: wrong\n" + steps % "bye",
        "c_test.agc": ADDS_TEST,
        "d.feature": "Feature: D\nScenario: d\nThen an undefined step\n"})
    carried = bdd.json_test(directory)
    compiled = bdd.json_test(directory, binary_path=binary())
    assert carried[0] == compiled[0]
    assert without_chance(carried[1]) == without_chance(compiled[1])
    assert (carried[1]["passed"], carried[1]["failed"]) == (2, 2)


def test_the_programs_the_binary_carries_are_the_texts_the_driver_compiles_without_them():
    """mk/bootstrap.mk compiles compiler/embedded/*.agc into the binary; the driver has the same two texts for a front
    end that reads the std/ sources from a folder."""
    driver = (ROOT / "compiler" / "bdd" / "bdd_driver.agc").read_text()
    for name, constant in (("runner", "RUNNER_ROOT"), ("steps", "DEFAULT_STEPS")):
        literal = re.search(r'^%s = "(.*)"$' % constant, driver, re.M).group(1)
        assert ast.literal_eval('"%s"' % literal) == (ROOT / "compiler" / "embedded" / (name + ".agc")).read_text(), name


def test_a_failing_crashing_exiting_or_looping_handler_fails_only_its_scenario(bdd):
    directory = bdd.suite({
        "a.feature": "Feature: invalid\nScenario: empty\n",
        "b.feature": ("Feature: Failures\nScenario: assertion\nThen an assertion fails\nAnd scenario state is empty\n"
                      "Scenario: no checks\nThen scenario state is empty\nAnd nothing is checked\n"
                      "Scenario: runtime\nThen execution crashes\n"
                      "Scenario: premature\nThen execution exits\n"
                      "Scenario: budget\nThen execution loops\n"
                      'Scenario: unknown\nGiven the Agentica program "missing.agc"\nThen missing definition\n'
                      "Scenario: later\nThen scenario state is empty\n"),
        "c.feature": "Feature: Last\nScenario: last\nThen scenario state is empty\n"})
    status, report = bdd.json_test(directory, "--steps", HANDLERS)
    assert status == 1
    assert (report["passed"], report["failed"], report["file_errors"]) == (2, 6, 1)
    assert file_error(report)["code"] == "PARSE-GHERKIN-EMPTY"
    results = report_cases(report)
    assert [code_of(item) for item in results[:6]] == [
        "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-NO-ASSERTION", "RUNTIME-DIVISION-BY-ZERO",
        "RUNTIME-BDD-PREMATURE-EXIT", "RUNTIME-STEP-LIMIT", "CHECK-BDD-UNDEFINED"]

    def statuses(item):
        return [step["status"] for step in item["steps"]]

    assert [statuses(results[0]), statuses(results[1]), statuses(results[5])] == [
        ["failed", "not_executed"], ["passed", "failed"], ["not_executed", "failed"]]
    assertion = results[0]["error"]
    assert (assertion["file"], start_line(assertion)) == (joined(directory, "b.feature"), 3)
    crash = results[2]["error"]
    assert (crash["file"], start_line(crash)) == (HANDLERS, 35)
    assert results[5]["error"]["actual"] == '"missing definition"'


def test_a_failed_check_points_at_its_step_keyword_and_outline_rows_have_their_own_names(bdd):
    steps = steps_program(
        'def main() -> Void\n  BDD.run([\n    BDD.step("a check passes") do |ctx, args| BDD.assert(ctx, true, "ok") end,\n'
        '    BDD.step("{int} is small") do |ctx, args|\n      BDD.assert(ctx, args[0].to_i! < 5, "too big")\n'
        '    end,\n  ])\nend')
    directory = bdd.suite({
        "steps.agc": steps,
        "plain.feature": "Feature: Plain\n\n  Scenario: plain\n    When a check passes\n    Then 9 is small\n",
        "background.feature": ("Feature: Background\n\n  Background:\n    Given a check passes\n"
                              "    Then 9 is small\n\n  Scenario: later\n    When a check passes\n"),
        "bad.feature": "Feature: Bad\n\n    Rule: nope\n",
        "outline.feature": ("Feature: Outline\n\n  Scenario Outline: row\n    Then <n> is small\n\n  Examples:\n"
                            "    | kind   | n |\n    | sqlite | 2 |\n    | sqlite | 9 |\n    | pg     | 9 |\n\n"
                            "  Scenario Outline: edge <n>\n    Then <n> is small\n\n  Examples:\n"
                            "    | n | note   |\n    | 1 |        |\n    | 7 | a\\nb   |\n    | 7 | a\\nb   |\n")})
    # Tab and CRLF indentation, and a form feed before the keyword, which `strip` removes like blanks.
    with open(joined(directory, "crlf.feature"), "wb") as out:
        out.write(b"Feature: Crlf\r\n\r\n\tScenario: tabs\r\n\t\tThen 9 is small\r\n"
                  b"\tScenario: form feed\r\n\x0c  Then 9 is small\r\n")
    steps_file = joined(directory, "steps.agc")

    def failures(name):
        """(scenario name, line, column) of each failed scenario of the feature; step and error agree."""
        feature = joined(directory, name + ".feature")
        status, report = bdd.json_test(feature, "--steps", steps_file)
        assert status == 1
        found = []
        for item in report_cases(report):
            if item["status"] == "failed":
                start = item["error"]["range"]["start"]
                assert item["error"]["file"] == feature
                assert [step["location"] for step in item["steps"] if step["status"] == "failed"] == [
                    {"file": feature, "line": start["line"], "column": start["column"]}]
                found.append((item["name"], start["line"], start["column"]))
        return report, found

    assert failures("plain")[1] == [("plain", 5, 5)]
    assert failures("background")[1] == [("later", 5, 5)]
    assert failures("crlf")[1] == [("tabs", 4, 3), ("form feed", 6, 4)]
    report, found = failures("outline")
    assert found == [("row (sqlite, 9)", 4, 5), ("row (pg, 9)", 4, 5), ("edge 7 (a\\nb)", 13, 5),
                     ("edge 7 (a\\nb)", 13, 5)]
    assert [item["name"] for item in report_cases(report)][:5] == [
        "row (sqlite, 2)", "row (sqlite, 9)", "row (pg, 9)", 'edge 1 ("")', "edge 7 (a\\nb)"]
    # Identical rows keep one name; their example places tell them apart.
    assert [item["example"]["line"] for item in report_cases(report)[-2:]] == [18, 19]

    feature = joined(directory, "outline.feature")
    _, one = bdd.json_test(feature, "--steps", steps_file, "--only", "(sqlite, 9)")
    assert [item["name"] for item in report_cases(one)] == ["row (sqlite, 9)"]
    text = bdd.agentica_test(feature, "--steps", steps_file).stdout
    assert "FAIL Outline / edge 7 (a\\nb)\n%s:13:5 [RUNTIME-BDD-ASSERTION] too big\n" % feature in text
    ai = bdd.agentica_test("--ai", feature, "--steps", steps_file).stdout
    assert "FAIL Outline / edge 7 (a\\nb) | %s:13:5 [RUNTIME-BDD-ASSERTION] too big\n" % feature in ai

    # Only a step's place starts at its keyword: a parse error keeps column 1.
    _, bad = bdd.json_test(joined(directory, "bad.feature"), "--steps", steps_file)
    assert (file_error(bad)["code"], file_error(bad)["range"]["start"]) == (
        "PARSE-GHERKIN-UNSUPPORTED", {"line": 3, "column": 1})


def test_a_crashing_handler_shows_its_stack_in_the_text_and_ai_reports(bdd):
    directory = bdd.suite({"crash.feature": "Feature: Crash\nScenario: runtime\nThen execution crashes\n"})
    feature = joined(directory, "crash.feature")
    place = HANDLERS + ":35:15"
    text = bdd.agentica_test(feature, "--steps", HANDLERS)
    assert text.code == 1
    assert ("[RUNTIME-DIVISION-BY-ZERO] division by zero\n  stack, innermost first:\n    crash at "
            + place + "\n    serve at std/bdd.agc:") in text.stdout
    ai = bdd.agentica_test("--ai", feature, "--steps", HANDLERS)
    assert ai.code == 1
    assert ("division by zero | stack crash at " + place + "; serve at std/bdd.agc:") in ai.stdout


def test_tasks_may_assert_must_end_before_the_handler_returns_and_a_crashing_task_fails_its_scenario(bdd):
    steps = steps_program(
        "struct Job\n  ctx: BDD.Context\n  n: Int\nend\n",
        'def worker(job: Job) -> BDD.Context\n  Task.sleep(0)\n  return BDD.assert(job.ctx, job.n > 0, "worker")\nend\n',
        "def wait(n: Int) -> Int\n  Task.sleep(60000)\n  return n\nend\n",
        "def crash(n: Int) -> Int\n  return 1 / n\nend\n",
        SETTLE,
        main_running(
            'BDD.step("state is concurrent") do |ctx, args|\n'
            "      tasks = [1, 2, 3, 4].map do |n| Task.spawn(&worker, Job(ctx: ctx, n: n)) end\n"
            "      done = tasks.map do |task| Task.await(task) end\n"
            '      BDD.set(ctx, "1", JSON.from(done.size))\n    end',
            'BDD.step("tasks are pending") do |ctx, args|\n      task = Task.spawn(&wait, 0)\n      ctx\n    end',
            'BDD.step("a task crashes") do |ctx, args|\n      task = Task.spawn(&crash, 0)\n      settle()\n      ctx\n    end',
            'BDD.step("later works") do |ctx, args| BDD.assert(ctx, not BDD.get(ctx, "1").ok?, "state leaked") end'))
    directory = bdd.suite({
        "tasks.feature": ("Feature: Tasks\nScenario: parallel\nThen state is concurrent\n"
                          "Scenario: pending\nThen tasks are pending\n"
                          "Scenario: failure\nThen a task crashes\n"
                          "Scenario: later\nThen later works\n"),
        "steps.agc": steps,
        "early.agc": steps_program("def wait(n: Int) -> Int\n  Task.sleep(60000)\n  return n\nend\n",
                                   "def main() -> Void\n  task = Task.spawn(&wait, 0)\n  BDD.run([])\nend"),
        "crashed.agc": steps_program("def crash(n: Int) -> Int\n  return 1 / n\nend\n", SETTLE,
                                     "def main() -> Void\n  task = Task.spawn(&crash, 0)\n  settle()\n  BDD.run([])\nend")})
    feature = joined(directory, "tasks.feature")
    status, report = bdd.json_test(feature, "--steps", joined(directory, "steps.agc"))
    assert status == 1
    assert [item["status"] for item in report_cases(report)] == ["passed", "failed", "failed", "passed"]
    assert [code_of(item) for item in report_cases(report)[1:3]] == [
        "RUNTIME-BDD-PENDING-TASKS", "RUNTIME-TASK-CRASHED"]
    assert "RUNTIME-DIVISION-BY-ZERO" in report_cases(report)[2]["error"]["message"]
    _, early = bdd.json_test(feature, "--steps", joined(directory, "early.agc"))
    assert file_error(early)["code"] == "RUNTIME-BDD-PENDING-TASKS"
    assert report_cases(early) == []
    _, crashed = bdd.json_test(feature, "--steps", joined(directory, "crashed.agc"))
    assert file_error(crashed)["code"] == "RUNTIME-TASK-CRASHED"
    assert report_cases(crashed) == []


def test_a_step_program_with_invalid_utf8_is_one_file_error_at_the_bad_byte(bdd):
    directory = bdd.suite({"steps.feature": "Feature: Steps\nScenario: small\nThen 3 is small\n"})
    steps = joined(directory, "bad.agc")
    with open(steps, "wb") as out:
        out.write(b"# caf\xc3\xa9\ndef main() -> Void\n  puts(\"\xff\")\nend\n")
    status, report = bdd.json_test(joined(directory, "steps.feature"), "--steps", steps)
    assert status == 1
    problem = file_error(report)
    assert problem["code"] == "LEX-INVALID-UTF8"
    assert problem["range"]["start"] == {"line": 3, "column": 9}


def test_blocks_capture_ambiguous_steps_fail_and_a_bad_step_program_is_one_file_error_with_no_scenario_run(bdd):
    feature = ("Feature: Steps\nScenario: small\nThen 3 is small\nScenario: big\nThen 9 is small\n"
               "Scenario: ambiguous\nThen value is 1\n")
    handler = ('def check(ctx: BDD.Context, args: List[String]) -> BDD.Context\n'
               '  return BDD.assert(ctx, true, "ok")\nend\n')
    directory = bdd.suite({
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
        return joined(directory, name)

    status, report = bdd.json_test(path("steps.feature"), "--steps", path("blocks.agc"))
    assert status == 1
    assert [item["status"] for item in report_cases(report)] == ["passed", "failed", "failed"]
    assert code_of(report_cases(report)[1]) == "RUNTIME-BDD-ASSERTION"
    assert code_of(report_cases(report)[2]) == "CHECK-BDD-AMBIGUOUS"
    assert report_cases(report)[2]["error"]["actual"] == '"value is 1"'
    for file, code, line in (("duplicate.agc", "RUNTIME-BDD-DUPLICATE", 1), ("predefined.agc", "RUNTIME-BDD-DUPLICATE", 1),
                             ("pattern.agc", "RUNTIME-BDD-PATTERN", 1), ("type.agc", "CHECK-TYPE-MISMATCH", 9),
                             ("silent.agc", "RUNTIME-BDD-CONTEXT", 1), ("loops.agc", "RUNTIME-STEP-LIMIT", 4)):
        status, report = bdd.json_test(path("steps.feature"), "--steps", path(file))
        assert status == 1, file
        assert [item["path"] for item in report["files"]] == [path(file)]
        assert file_error(report)["code"] == code, file
        assert start_line(file_error(report)) == line, file
    _, http = bdd.json_test(path("steps.feature"), "--steps", path("http.agc"))
    assert file_error(http)["code"] == "CHECK-UNKNOWN-NAME"
    assert start_line(file_error(http)) == 4
    assert re.search("std/http", file_error(http)["help"])
    forged_status, forged = bdd.json_test(path("forged.feature"), "--steps", path("forged.agc"))
    assert forged_status == 1
    assert code_of(report_cases(forged)[0]) == "RUNTIME-BDD-ASSERTION"
    assert [step["status"] for step in report_cases(forged)[0]["steps"]] == ["passed", "failed"]


def test_usage_errors_exit_2_an_empty_directory_exits_1_and_missing_pieces_are_infrastructure_errors(bdd):
    directory = bdd.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})

    def path(name):
        return joined(directory, name)

    for arguments in (["--steps"], ["--only"], ["--unknown"], ["--steps", "a.agc", "--steps", "b.agc"]):
        status, report = bdd.json_test(*arguments)
        assert status == 2, str(arguments)
        assert file_error(report)["code"] == "RUNTIME-BDD-USAGE"
    empty = path("empty")
    os.mkdir(empty)
    status, report = bdd.json_test(empty)
    assert status == 1
    assert file_error(report)["code"] == "CHECK-BDD-EMPTY"
    for arguments in ([path("missing.feature")], [path("a.feature"), "--steps", path("none.agc")]):
        status, report = bdd.json_test(*arguments)
        assert status == 2
        assert file_error(report)["code"] == "RUNTIME-BDD-INFRA"
    # Without the binary nothing can run: the driver answers with its own message in the format of the report.
    fake = path("no-binary")
    for style in ("--json", "--ai"):
        result = bdd.agentica_test(style, path("a.feature"), binary_path=fake)
        assert result.code == 2, style
        assert re.search("cannot find agentica at .*no-binary", result.stdout), style
        assert result.stderr == ""


def test_without_paths_specs_and_test_are_searched_and_the_empty_message_says_which_were_missing(bdd):
    scratch = bdd.make_suite({"nothing.txt": ""}, "agentica-bdd-default-")
    messages = []
    for folder in (None, "specs"):
        if folder:
            os.mkdir(scratch / folder)
        result = bdd.agentica_test("--json", cwd=scratch)
        assert result.code == 1
        problem = file_error(json.loads(result.stdout))
        assert (problem["code"], problem["file"]) == ("CHECK-BDD-EMPTY", (scratch / "specs").as_posix() + "/")
        messages.append(problem["message"])
    assert messages == ["no .feature or *_test.agc files found: neither specs/ nor test/ exists",
                        "no .feature or *_test.agc files found"]


def test_a_report_of_several_mib_arrives_whole(bdd):
    # The runner is a captured child, and a captured stream keeps 1 MiB: the report travels in a file instead.
    names = ["case %d %s" % (number, "x" * 40000) for number in range(40)]
    tests = ",\n".join('    Test.test("%s") do\n      Test.eq(1, 1)\n    end' % name for name in names)
    directory = bdd.suite({"big_test.agc": "def main() -> Void\n  Test.run([\n%s,\n  ])\nend\n" % tests})
    result = bdd.agentica_test("--json", directory)
    assert (result.code, result.stderr) == (0, "")
    assert len(result.stdout) > 1048576 + 400000
    report = json.loads(result.stdout)
    assert [item["name"] for item in report_cases(report)] == names


def test_the_temporary_directory_is_tmpdir_when_it_is_a_folder_else_a_system_one(bdd):
    scratch = bdd.make_suite({"file": ""}, "agentica-bdd-tmpdir-")
    os.mkdir(scratch / "empty")
    for given in (scratch / "file", scratch / "missing", ""):
        result = bdd.agentica_test("--json", scratch / "empty", env={"TMPDIR": given}, cwd=scratch)
        assert (result.code, json.loads(result.stdout)["files"][0]["error"]["code"]) == (1, "CHECK-BDD-EMPTY"), str(given)
    assert sorted(os.listdir(scratch)) == ["empty", "file"]


@contextlib.contextmanager
def held_lock(path):
    """The file at `path` with an exclusive lock that this process holds while the block runs."""
    with open(path, "r+b") as handle:
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def test_a_run_removes_the_folder_of_an_ended_run_and_leaves_the_folder_of_a_live_one(bdd):
    """The sweep of the run directories in the private TMPDIR of the case: a folder with a free `lock` goes (it is old,
    which Windows asks for), a folder whose `lock` another process holds stays."""
    scratch = bdd.make_suite({"c_test.agc": ADDS_TEST}, "agentica-bdd-sweep-")
    temporary = scratch / "tmp"
    temporary.mkdir()
    ended, live = temporary / "agentica-bdd-0123456789abcdef", temporary / "agentica-bdd-fedcba9876543210"
    for folder in (ended, live):
        folder.mkdir()
        (folder / "lock").write_text("x")
        old = time.time() - 3600
        os.utime(folder, (old, old))
    # On Windows a folder younger than a minute is left alone even when its lock is free (WINDOWS_MIN_AGE_SECONDS).
    young = temporary / "agentica-bdd-00112233445566778899aabbccddeeff"
    young.mkdir()
    (young / "lock").write_text("x")
    # A link to a folder that holds a free lock, and a hexadecimal name with no lock in it, are not run folders: they
    # stay, and nothing behind the link is touched.
    outside = scratch / "outside"
    outside.mkdir()
    (outside / "lock").write_text("keep")
    linked = temporary / "agentica-bdd-aaaaaaaaaaaaaaaa"
    # Windows needs the right to make symbolic links (Developer Mode or an administrator), as test_filesystem.py does.
    os.symlink(outside, linked, target_is_directory=True)
    malformed = temporary / "agentica-bdd-00ff"
    malformed.mkdir()
    os.utime(malformed, (old, old))
    with held_lock(live / "lock"):
        status, report = bdd.json_test(scratch / "c_test.agc", env={"TMPDIR": temporary})
    assert (status, report["passed"]) == (0, 1)
    assert sorted(os.listdir(temporary)) == sorted(
        [live.name, linked.name, malformed.name] + ([young.name] if os.name == "nt" else []))
    assert (outside / "lock").read_text() == "keep"


not_wine = pytest.mark.skipif(UNDER_WINE, reason="Wine runs the Windows binary, which starts neither a shell script nor node")


def fake_binary(directory, script):
    """The stand-in for the binary that `agentica test` starts again, and the environment it needs: when it is asked to
    run the runner it prints the given stderr lines and ends with status 3.

    A #!/bin/sh script that runs the real binary for anything else, on POSIX systems. The VM starts only .exe and .com
    files on Windows, so there it is a copy of node.exe (which needs nothing beside it; a hard link when the system
    allows it) with a script that NODE_OPTIONS preloads. The driver starts it only for the runner, so it does not
    start the real binary for anything else."""
    if os.name != "nt":
        path = os.path.join(directory, "agentica.sh")
        with open(path, "w") as binary_script:
            binary_script.write("#!/bin/sh\ncase \"$*\" in\n*runner.agcb*)\n"
                                + "".join("  echo '%s' >&2\n" % line for line in script)
                                + "  exit 3 ;;\nesac\nexec '%s' \"$@\"\n" % binary())
        os.chmod(path, 0o700)
        return path, {}
    fake = Path(directory) / "agentica-fake.exe"
    node = tool("node")
    try:
        os.link(node, fake)
    except OSError:
        shutil.copy(node, fake)
    preload = Path(directory) / "fake-runner.js"
    preload.write_text("const fs = require('fs');\nfs.writeSync(2, %s.join('\\n') + '\\n');\nprocess.exit(3);\n"
                       % json.dumps(script), encoding="utf-8")
    return str(fake), {"NODE_OPTIONS": '--require "%s"' % preload.as_posix()}


@not_wine
def test_a_crashed_runner_is_reported_with_the_error_not_the_last_stack_frame(bdd):
    directory = bdd.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
    fake, env = fake_binary(directory, [
        "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
        "index 5 is outside a list of length 3",
        "  = stack, innermost first:",
        "    main at runner.agc:11:8"])
    result = bdd.agentica_test("--json", os.path.join(directory, "a.feature"), binary_path=fake, env=env)
    assert result.code == 2
    error = json.loads(result.stdout)["files"][0]["error"]
    assert error["code"] == "RUNTIME-BDD-INFRA"
    assert re.search("RUNTIME-INDEX-OUT-OF-RANGE", error["message"])


@not_wine
def test_the_infrastructure_message_names_the_runners_final_diagnostic_not_an_earlier_task_crash(bdd):
    directory = bdd.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
    fake, env = fake_binary(directory, [
        "runner.agc:5:9 error[RUNTIME-DIVISION-BY-ZERO] in a task",
        "division by zero",
        "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
        "index 5 is outside a list of length 3",
        "  = stack, innermost first:"])
    result = bdd.agentica_test("--json", os.path.join(directory, "a.feature"), binary_path=fake, env=env)
    assert result.code == 2
    message = file_error(json.loads(result.stdout))["message"]
    assert re.search("RUNTIME-INDEX-OUT-OF-RANGE", message)
    assert not re.search("DIVISION-BY-ZERO", message)

