"""`agentica test` driving real programs under test.

Live JSON lines, tasks in handlers, seeds, wrong output, process cleanup and
the temporary-directory rules. The slow tier keeps the large sizes (1 MiB
outputs, floods), the output limits reached by endless prints (15 s deadlines)
and a killed driver with its process tree; the fast smoke case keeps the other
paths. Each case runs the CLI as a child.
"""
import json
import os
import time
from textwrap import dedent

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, TESTS, UNDER_WINE, WINDOWS, Child, agc_literal, cli, host_only, kill_process,
                                 process_alive, report_cases, run, scaled,
                                 vm_environment, wait_until, write_files)

try:
    import fcntl
except ImportError:  # Windows
    fcntl = None

# The deadline of a step is scaled for slow runners, but stays under the 30 s deadline of a whole scenario (the
# default of `agentica test`, which has no flag), or a slow step would end as a scenario timeout instead.
def ms(milliseconds):
    return str(min(scaled(milliseconds), 25000))


STREAM_SPEC = str(TESTS / "bdd" / "specs" / "json-lines.feature")

HOLDER_PROGRAM = f"""\
def main() -> Void
  p = Process.spawn("/bin/sh", ["-c", "echo $$ > pid.txt; echo started; exec sleep 60"], {ms(5000)}).unwrap!
  started = Process.read_line(p, {ms(5000)}).unwrap!
  puts("ready")
  IO.flush()
  line = IO.gets()
end
"""

# Windows has no /bin/sh: the program under test starts the Python peer that prints its pid and waits, and writes the
# pid to the file the shell writes on the other systems.
WINDOWS_HOLDER_PROGRAM = f"""def main() -> Void
  p = Process.spawn({agc_literal(PYTHON)}, [{agc_literal(FIXTURES / "process-peer.py")}, "hold"], {ms(5000)}).unwrap!
  pid = Process.read_line(p, {ms(5000)}).unwrap!
  File.write_text("pid.txt", pid, {ms(5000)}).unwrap!
  puts("ready")
  IO.flush()
  line = IO.gets()
end
"""
HOLDER = WINDOWS_HOLDER_PROGRAM if os.name == "nt" else HOLDER_PROGRAM
not_wine = pytest.mark.skipif(UNDER_WINE, reason="Wine runs the Windows binary, which starts neither /bin/sh nor a Linux Python")
# On Windows the killed driver and its tree end in a few seconds, so the case runs in the fast tier, which the Windows job
# runs; the slow tier runs on Linux only.
slow_off_windows = pytest.mark.slow if os.name != "nt" else (lambda function: function)

BUFFERED_PROGRAM = "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  line = IO.gets!()\nend\n"
OUTPUT_PROGRAM = 'def main() -> Void\n  puts("actual")\n  IO.warn("warning")\n  System.exit(3)\nend\n'
JSON_PROGRAM = 'def main() -> Void\n  puts("{\\"b\\": \\"3\\", \\"a\\": 1}")\nend\n'


def processes_mentioning(text):
    """The pids whose command line contains `text` (Linux /proc; the process list of Windows)."""
    if os.name == "nt":
        from tests.windows_support import processes_mentioning as windows_processes_mentioning
        return windows_processes_mentioning(text)
    needle = os.fsencode(str(text))
    found = []
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open("/proc/%s/cmdline" % entry, "rb") as cmdline:
                    if needle in cmdline.read():
                        found.append(int(entry))
            except OSError:
                pass
    return found


def doc(text):
    return '  """\n  ' + text + '\n  """\n'


# Scenarios shared by the smoke case (fast tier) and the full case (slow tier).
WRONG_STDOUT_SCENARIO = (
    'Scenario: wrong stdout\nGiven the Agentica program "output.agc"\n'
    "Then the program exits with code 3 within " + ms(5000) + " milliseconds\nAnd stdout is:\n" + doc("incorrect"))

LITERAL_INPUT_SCENARIO = (
    'Scenario: literal input and EOF\nGiven the Agentica program "buffered.agc"\nWhen I send input:\n' + doc("hello")
    + "When I close stdin\nAnd I close stdin\n"
    "Then the program exits with code 1 within " + ms(5000) + " milliseconds\n"
    "And stdout is:\n" + doc("hello\n"))

JSON_MISMATCH_SCENARIO = (
    'Scenario: JSON mismatch\nGiven the Agentica program "json.agc"\n'
    "Then I receive a JSON line within " + ms(5000) + " milliseconds:\n" + doc('{"a": 1, "b": 3}'))


def codes(report):
    return [item["error"]["code"] if isinstance(item["error"], dict) else None for item in report_cases(report)]


def details(item):
    problem = item["error"]
    return [problem["expected"], problem["actual"]]


@pytest.fixture
def cleanup(request):
    """Register a function to run when the test ends (kill what a failing test would leave running)."""
    return request.addfinalizer


def json_test(*args, before=()):
    result = run(cli() + [*before, "test", "--json", *args], env=vm_environment())
    assert result.stderr == ""
    return json.loads(result.stdout)


def suite(tmp_path, files):
    """A resolved folder holding the given files (name -> text)."""
    directory = (tmp_path / "suite").resolve()
    directory.mkdir(parents=True, exist_ok=True)
    write_files(directory, files)
    return directory


def kill_at_end(cleanup, pids):
    """Kill what a failing test would leave running; `pids` is called at the end, when the pids are known."""
    def kill():
        for pid in pids():
            try:
                kill_process(int(pid))
            except (ProcessLookupError, ValueError):
                pass
    cleanup(kill)


def test_live_json_replies_arrive_before_eof_and_recover_after_errors():
    report = json_test(STREAM_SPEC)
    assert report["ok"] is True, str(report)
    assert report["passed"] == 2


def test_a_task_receives_while_its_handler_sends_and_a_pending_read_fails_its_scenario(tmp_path):
    directory = suite(tmp_path, {
        "echo.agc": "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  IO.flush()\n  ending = IO.gets()\nend\n",
        "steps.agc": dedent(f"""\
            import BDD from "std/bdd"

            def receive(ctx: BDD.Context) -> BDD.Context
              return BDD.then_line(ctx, "hello", {ms(5000)})
            end

            def exchange(ctx: BDD.Context, args: List[String]) -> BDD.Context
              task = Task.spawn(&receive, ctx)
              Task.sleep(0)
              sent = BDD.when_line(ctx, "hello")
              return Task.await(task)
            end

            def wait(ctx: BDD.Context) -> BDD.Context
              return BDD.then_line(ctx, "never", 5000)
            end

            def pending(ctx: BDD.Context, args: List[String]) -> BDD.Context
              task = Task.spawn(&wait, ctx)
              Task.sleep(0)
              return ctx
            end

            def main() -> Void
              BDD.run([BDD.step("exchange concurrently", &exchange), BDD.step("leave a pending read", &pending)])
            end
            """),
        "tasks.feature": (
            'Feature: Concurrent streams\nBackground:\nGiven the Agentica program "echo.agc"\n'
            "Scenario: exchange\nThen exchange concurrently\nWhen I close stdin\n"
            "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n"
            "Scenario: pending\nThen leave a pending read\n"
            "Scenario: later\nThen exchange concurrently\nWhen I close stdin\n"
            "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n")})
    report = json_test(directory / "tasks.feature", "--steps", directory / "steps.agc")
    assert codes(report) == [None, "RUNTIME-BDD-PENDING-TASKS", None]


def test_a_seed_given_or_drawn_reaches_step_handlers_and_programs_under_test(tmp_path):
    draw = 'Random.int(1, 1000000).to_s + " " + Random.int(1, 1000000).to_s'
    directory = suite(tmp_path, {
        "draw.agc": f"""\
def main() -> Void
  puts({draw})
end
""",
        "steps.agc": dedent(f"""\
            import BDD from "std/bdd"

            def main() -> Void
              BDD.run([BDD.step("stdout repeats the seeded draw") do |ctx, args| BDD.then_stdout(ctx, {draw} + "\\n") end])
            end
            """),
        "seed.feature": ('Feature: Seeds\nScenario: seeded\nGiven the Agentica program "draw.agc"\n'
                         "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n"
                         "And stdout repeats the seeded draw\n")})
    arguments = [directory / "seed.feature", "--steps", directory / "steps.agc"]
    assert json_test(*arguments, before=["--seed", "9"])["ok"] is True
    drawn = json_test(*arguments)
    assert drawn["ok"] is True
    assert isinstance(drawn["seed"], int)
    assert drawn["seed"] >= 0


def test_programs_under_test_wrong_output_literal_input_and_a_json_line_mismatch(tmp_path):
    directory = suite(tmp_path, {
        "buffered.agc": BUFFERED_PROGRAM, "output.agc": OUTPUT_PROGRAM, "json.agc": JSON_PROGRAM,
        "smoke.feature": "Feature: Smoke\n" + WRONG_STDOUT_SCENARIO + LITERAL_INPUT_SCENARIO + JSON_MISMATCH_SCENARIO})
    report = json_test(directory / "smoke.feature")
    assert codes(report) == ["RUNTIME-BDD-ASSERTION", None, "RUNTIME-BDD-ASSERTION"]
    assert [details(report_cases(report)[0]), details(report_cases(report)[2])] == [
        ['"incorrect"', '"actual\\n"'], ['{"a":1,"b":3}', '{"a":1,"b":"3"}']]


@not_wine
def test_a_failed_scenario_leaves_no_process_of_its_program_behind(tmp_path, cleanup):
    directory = suite(tmp_path, {
        "holder.agc": HOLDER,
        "holder.feature": ('Feature: Cleanup\nScenario: held\nGiven the Agentica program "holder.agc"\n'
                           'Then I receive the line "ready" within ' + ms(5000) + ' milliseconds\n'
                           "And the program exits with code 0 within 200 milliseconds\n")})
    pid_file = directory / "pid.txt"
    kill_at_end(cleanup, lambda: [pid_file.read_text().strip()] if pid_file.exists() else [])
    report = json_test("--allow-run", directory / "holder.feature")
    assert codes(report) == ["RUNTIME-BDD-TIMEOUT"]
    pid = pid_file.read_text().strip()
    assert wait_until(lambda: not process_alive(pid), scaled(5)), pid


@host_only(WINDOWS, "needs the sticky bit and group permission bits of a shared temporary folder; Windows has neither")
def test_a_temporary_directory_others_can_write_to_without_the_sticky_bit_is_refused(tmp_path):
    directory = suite(tmp_path, {})
    temporary = directory / "shared"
    temporary.mkdir()

    def status_and_code():
        result = run(cli() + ["test", "--json", directory], env=vm_environment({"TMPDIR": temporary}))
        report = json.loads(result.stdout)
        return [result.code, report["files"][0]["error"]["code"]]

    os.chmod(temporary, 0o777)
    assert status_and_code() == [2, "RUNTIME-BDD-INFRA"]
    os.chmod(temporary, 0o1777)
    assert status_and_code() == [1, "CHECK-BDD-EMPTY"]
    os.chmod(temporary, 0o775)
    assert status_and_code() == [1, "CHECK-BDD-EMPTY"]
    os.chmod(temporary, 0o2775)
    assert status_and_code() == [2, "RUNTIME-BDD-INFRA"]


# Slow tier: large sizes, endless prints with 15 s deadlines, and a killed driver.

@pytest.mark.slow
def test_a_handler_that_prints_for_ever_fails_at_the_output_limit_long_before_the_scenario_deadline(tmp_path):
    directory = suite(tmp_path, {
        "steps.agc": ('import BDD from "std/bdd"\n\ndef main() -> Void\n'
                      '  BDD.run([BDD.step("the handler prints for ever") do |ctx, args|\n'
                      '    chunk = String.join(List.repeat("x", 100000), "")\n'
                      "    while true\n      puts(chunk)\n      Task.sleep(5)\n    end\n"
                      "    ctx\n  end])\nend\n"),
        "endless.feature": "Feature: Endless\nScenario: endless\nGiven the handler prints for ever\n"})
    started = time.monotonic()
    report = json_test(directory / "endless.feature", "--steps", directory / "steps.agc")
    assert time.monotonic() - started < min(scaled(15), 25)
    assert codes(report) == ["RUNTIME-BDD-OUTPUT-LIMIT"]


@pytest.mark.slow
def test_a_step_program_that_prints_for_ever_while_it_lists_its_steps_fails_at_the_output_limit(tmp_path):
    directory = suite(tmp_path, {
        "steps.agc": ('import BDD from "std/bdd"\n\ndef main() -> Void\n'
                      '  chunk = String.join(List.repeat("x", 100000), "")\n'
                      "  while true\n    puts(chunk)\n    Task.sleep(5)\n  end\n"
                      "  BDD.run([])\nend\n"),
        "listing.feature": "Feature: Listing\nScenario: never runs\nGiven something\n"})
    started = time.monotonic()
    report = json_test(directory / "listing.feature", "--steps", directory / "steps.agc")
    assert time.monotonic() - started < min(scaled(15), 25)
    assert [[file["kind"], file["error"]["code"] if isinstance(file["error"], dict) else None]
            for file in report["files"]] == [["steps", "RUNTIME-BDD-OUTPUT-LIMIT"]]


@pytest.mark.slow
def test_programs_under_test_output_without_a_flush_wrong_output_the_output_limits_literal_input_and_the_working_directory(tmp_path):
    directory = suite(tmp_path, {})
    # The expected text names the directory, so the files are written after it exists.
    write_files(directory, {
        "buffered.agc": BUFFERED_PROGRAM,
        "output.agc": OUTPUT_PROGRAM,
        "oversized.agc": 'def main() -> Void\n  puts(String.join(List.repeat("x", 1048576), ""))\nend\n',
        "flood.agc": 'def main() -> Void\n  IO.warn(String.join(List.repeat("x", 1048576), ""))\n  line = IO.gets()\nend\n',
        "where.agc": "def main() -> Void\n  puts(Path.cwd().unwrap!)\nend\n",
        "json.agc": JSON_PROGRAM,
        "quotes.agc": 'def main() -> Void\n  puts(String.join(List.repeat("\\"", 300000), ""))\nend\n',
        "steps.agc": ('import BDD from "std/bdd"\n\ndef main() -> Void\n'
                      '  BDD.run([BDD.step("the handler floods stdout") do |ctx, args|\n'
                      '    puts(String.join(List.repeat(String.join(List.repeat("x", 1000), ""), 1100), "\\n"))\n'
                      "    ctx\n  end,\n"
                      '  BDD.step("the handler fails with a huge message") do |ctx, args|\n'
                      '    BDD.assert(ctx, false, String.join(List.repeat("xxxxxxxxxx", 110000), ""))\n'
                      "  end])\nend\n"),
        "lifecycle.feature": (
            "Feature: Lifecycle\n"
            'Scenario: output without a flush\nGiven the Agentica program "buffered.agc"\n'
            'When I send the line "hello"\nThen I receive the line "hello" within ' + ms(1000) + ' milliseconds\n'
            + WRONG_STDOUT_SCENARIO
            + 'Scenario: wrong stderr\nGiven the Agentica program "output.agc"\n'
            "Then the program exits with code 3 within " + ms(5000) + " milliseconds\n"
            "And stderr is:\n" + doc("incorrect")
            + 'Scenario: wrong code\nGiven the Agentica program "output.agc"\n'
            "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n"
            'Scenario: output limit\nGiven the Agentica program "oversized.agc"\n'
            "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n"
            'Scenario: stderr flood\nGiven the Agentica program "flood.agc"\n'
            'Then I receive the line "never" within ' + ms(5000) + ' milliseconds\n'
            + LITERAL_INPUT_SCENARIO
            + 'Scenario: working directory\nGiven the Agentica program "where.agc"\n'
            'Then I receive the line "' + str(directory) + '/" within ' + ms(5000) + ' milliseconds\n'
            'Scenario: later\nGiven the Agentica program "output.agc"\n'
            "Then the program exits with code 3 within " + ms(5000) + " milliseconds\n"
            "And stdout is:\n" + doc("actual\n") + "And stderr is:\n" + doc("warning\n")
            + "Scenario: handler flood\nGiven the handler floods stdout\n"
            'Scenario: step line over 1 MiB\nGiven the Agentica program "output.agc"\nWhen I send input:\n'
            + doc('"' * 600000)
            + JSON_MISMATCH_SCENARIO
            + 'Scenario: long mismatch\nGiven the Agentica program "quotes.agc"\n'
            "Then the program exits with code 0 within " + ms(5000) + " milliseconds\nAnd stdout is:\n" + doc("x")
            + "Scenario: record over 1 MiB\nGiven the handler fails with a huge message\n")})
    report = json_test(directory / "lifecycle.feature", "--steps", directory / "steps.agc")
    assert codes(report) == [
        None, "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-ASSERTION",
        "RUNTIME-BDD-OUTPUT-LIMIT", "RUNTIME-BDD-OUTPUT-LIMIT", None, None, None,
        "RUNTIME-BDD-OUTPUT-LIMIT", "RUNTIME-BDD-IO", "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-ASSERTION",
        "RUNTIME-BDD-OUTPUT-LIMIT"]
    results = report_cases(report)
    assert [details(results[1]), details(results[3]), details(results[11])] == [
        ['"incorrect"', '"actual\\n"'], ["0", "3"], ['{"a":1,"b":3}', '{"a":1,"b":"3"}']]
    long_actual = details(results[12])[1]
    assert len(long_actual) == 65536 + len("... (534468 more characters)")
    assert long_actual.endswith("\\... (534468 more characters)")


@pytest.mark.slow
def test_a_json_line_of_a_few_hundred_kb_fits_the_step_budget(tmp_path):
    items = ["abcdefghij"] * 30000
    directory = suite(tmp_path, {
        "big.agc": 'def main() -> Void\n  puts(JSON.encode(JSON.from(List.repeat("abcdefghij", 30000))))\nend\n',
        "big.feature": ('Feature: Big\nScenario: big line\nGiven the Agentica program "big.agc"\n'
                        "Then I receive a JSON line within " + ms(5000) + " milliseconds:\n"
                        + doc(json.dumps(items, separators=(",", ":"))))})
    assert json_test(directory / "big.feature")["ok"] is True


@slow_off_windows
@not_wine
def test_killing_the_driver_stops_the_runner_the_scenario_vm_and_the_program_and_a_later_run_removes_its_folder(tmp_path, cleanup):
    directory = suite(tmp_path, {
        "holder.agc": HOLDER,
        "holder.feature": ('Feature: Killed\nScenario: held\nGiven the Agentica program "holder.agc"\n'
                           'Then I receive the line "ready" within ' + ms(5000) + ' milliseconds\n'
                           "And the program exits with code 0 within " + ms(20000) + " milliseconds\n")})
    temporary = directory / "tmp"
    temporary.mkdir(0o700)
    env = vm_environment({"TMPDIR": temporary})
    # The runner, the VM and the program are not children of the test: kill them if the cleanup under test fails.
    pid_file = directory / "pid.txt"
    kill_at_end(cleanup, lambda: processes_mentioning(temporary) + (
        [pid_file.read_text().strip()] if pid_file.exists() else []))
    driver = Child(cli() + ["test", "--allow-run", directory / "holder.feature"], env=env)
    cleanup(driver.stop)
    assert wait_until(
        lambda: pid_file.exists() and any(c.isdigit() for c in pid_file.read_text()), scaled(20))
    if os.name == "nt":
        # The process list names the runner and the scenario VM by their run folder; without them in the list, the wait
        # for an empty list after the kill would prove nothing.
        assert wait_until(lambda: processes_mentioning(temporary), scaled(20), 0.5)
    # Only the driver dies, not its process group: the runner, the VM and the program must follow it.
    driver.process.kill()
    driver.process.wait(scaled(20))
    pid = pid_file.read_text().strip()
    assert wait_until(lambda: not process_alive(pid), scaled(5)), pid
    assert wait_until(lambda: not processes_mentioning(temporary), scaled(20))
    assert len(os.listdir(temporary)) == 1
    if os.name == "nt":
        # Windows sweeps only folders a minute old, with locks of its own: the sweep is checked on folders made by hand in
        # test_a_run_removes_the_folder_of_an_ended_run_and_leaves_the_folder_of_a_live_one (tests/test_bdd.py).
        return
    # A later run removes the folder of the dead driver and keeps live, linked and malformed ones.
    live = temporary / "agentica-bdd-0123456789abcdef"
    live.mkdir()
    with open(live / "lock", "w") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        outside = directory / "outside"
        outside.mkdir()
        (outside / "lock").write_text("keep")
        os.symlink(outside, temporary / "agentica-bdd-fedcba9876543210")
        (temporary / "agentica-bdd-00ff").mkdir()
        run(cli() + ["test", directory / "missing.feature"], env=env)
    assert sorted(os.listdir(temporary)) == [
        "agentica-bdd-00ff", "agentica-bdd-0123456789abcdef", "agentica-bdd-fedcba9876543210"]
    assert (outside / "lock").read_text() == "keep"
