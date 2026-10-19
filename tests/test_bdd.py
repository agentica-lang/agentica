"""`agentica test` on feature files with step programs.

Each case runs the CLI as a child (`agentica test --json ...`) and compares
the JSON report: statuses, diagnostic codes, lines, and the text and --ai
formats. tests/bdd/handlers.agc holds the shared step handlers. The cases that
need a runner that fails run the front end as an ordinary program with a script
as the binary it starts again (front_end_command; the cases that need a shell script are in
tests/test_bdd_posix.py).
"""
import ast
import json
import os
import re
import tempfile
from pathlib import Path

import pytest

from tests.agentica_test import (ROOT, TESTS, binary, cli, front_end_command, report_cases, require, run,
                                 vm_environment, write_files)

HANDLERS = str(TESTS / "bdd" / "handlers.agc")
# The first binary of the bootstrap (the Makefile links it with stage0 and builds the release mode only).
BOOTSTRAP = ROOT / "build" / "vm" / "release" / "bootstrap" / ("agentica.exe" if os.name == "nt" else "agentica")
ADDS_TEST = 'def main() -> Void\n  Test.run([Test.test("adds") do\n    Test.eq(1 + 1, 2)\n  end])\nend\n'
CUSTOM = str(TESTS / "bdd" / "specs" / "custom.feature")


def code_of(item):
    return item["error"]["code"]


def file_error(report):
    return report["files"][0]["error"]


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
    """The Makefile compiles compiler/embedded/*.agc into the binary; the driver has the same two texts for a front
    end that reads the std/ sources from a folder."""
    driver = (ROOT / "compiler" / "bdd_driver.agc").read_text()
    for name, constant in (("runner", "RUNNER_ROOT"), ("steps", "DEFAULT_STEPS")):
        literal = re.search(r'^%s = "(.*)"$' % constant, driver, re.M).group(1)
        assert ast.literal_eval('"%s"' % literal) == (ROOT / "compiler" / "embedded" / (name + ".agc")).read_text(), name


def test_the_first_binary_of_the_bootstrap_still_tests_with_the_driver_of_stage0(bdd):
    """That binary has the driver of stage0: it compiles the runner and the steps from the std/ sources of this
    checkout, writes the configuration it always wrote, and knows no embedded program. The current runner must
    read that configuration."""
    require(BOOTSTRAP.is_file(), "the first binary is not built (%s): run make" % BOOTSTRAP)
    directory = bdd.suite({"c_test.agc": ADDS_TEST})
    result = run([BOOTSTRAP, "test", "--json", directory], env=vm_environment())
    assert (result.code, result.stderr) == (0, "")
    assert json.loads(result.stdout)["passed"] == 1
    result = run([BOOTSTRAP, "run", "--embedded", "runner", "--", "config.jsonl"], env=vm_environment())
    assert (result.code, result.stdout) == (2, "")
    assert result.stderr != ""


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
    assert (assertion["file"], start_line(assertion)) == (os.path.join(directory, "b.feature"), 3)
    crash = results[2]["error"]
    assert (crash["file"], start_line(crash)) == (HANDLERS, 35)
    assert results[5]["error"]["actual"] == '"missing definition"'


def test_a_crashing_handler_shows_its_stack_in_the_text_and_ai_reports(bdd):
    directory = bdd.suite({"crash.feature": "Feature: Crash\nScenario: runtime\nThen execution crashes\n"})
    feature = os.path.join(directory, "crash.feature")
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
        main_running(
            'BDD.step("state is concurrent") do |ctx, args|\n'
            "      tasks = [1, 2, 3, 4].map do |n| Task.spawn(&worker, Job(ctx: ctx, n: n)) end\n"
            "      done = tasks.map do |task| Task.await(task) end\n"
            '      BDD.set(ctx, "1", JSON.from(done.size))\n    end',
            'BDD.step("tasks are pending") do |ctx, args|\n      task = Task.spawn(&wait, 0)\n      ctx\n    end',
            'BDD.step("a task crashes") do |ctx, args|\n      task = Task.spawn(&crash, 0)\n      Task.sleep(0)\n      ctx\n    end',
            'BDD.step("later works") do |ctx, args| BDD.assert(ctx, not BDD.get(ctx, "1").ok?, "state leaked") end'))
    directory = bdd.suite({
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
    status, report = bdd.json_test(feature, "--steps", os.path.join(directory, "steps.agc"))
    assert status == 1
    assert [item["status"] for item in report_cases(report)] == ["passed", "failed", "failed", "passed"]
    assert [code_of(item) for item in report_cases(report)[1:3]] == [
        "RUNTIME-BDD-PENDING-TASKS", "RUNTIME-TASK-CRASHED"]
    assert "RUNTIME-DIVISION-BY-ZERO" in report_cases(report)[2]["error"]["message"]
    _, early = bdd.json_test(feature, "--steps", os.path.join(directory, "early.agc"))
    assert file_error(early)["code"] == "RUNTIME-BDD-PENDING-TASKS"
    assert report_cases(early) == []
    _, crashed = bdd.json_test(feature, "--steps", os.path.join(directory, "crashed.agc"))
    assert file_error(crashed)["code"] == "RUNTIME-TASK-CRASHED"
    assert report_cases(crashed) == []


def test_a_step_program_with_invalid_utf8_is_one_file_error_at_the_bad_byte(bdd):
    directory = bdd.suite({"steps.feature": "Feature: Steps\nScenario: small\nThen 3 is small\n"})
    steps = os.path.join(directory, "bad.agc")
    with open(steps, "wb") as out:
        out.write(b"# caf\xc3\xa9\ndef main() -> Void\n  puts(\"\xff\")\nend\n")
    status, report = bdd.json_test(os.path.join(directory, "steps.feature"), "--steps", steps)
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
        return os.path.join(directory, name)

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
        return os.path.join(directory, name)

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
        assert (problem["code"], problem["file"]) == ("CHECK-BDD-EMPTY", str(scratch / "specs") + "/")
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
