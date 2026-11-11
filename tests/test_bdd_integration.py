"""`agentica test` driving real programs under test.

Live JSON lines, tasks in handlers, seeds, wrong output, process cleanup and
the temporary-directory rules. The slow tier keeps the large sizes (1 MiB
outputs, floods) and the output limits reached by endless prints (15 s
deadlines); the fast smoke case keeps the other paths. A killed driver with its
process tree is slow on POSIX systems and fast on Windows, which runs no slow
tier. Each case runs the CLI as a child.
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
  p = Process.spawn("/bin/sh", ["-c", "echo $$ > pid.txt; echo started; exec sleep 60"], Process.Options(timeout_ms: {ms(5000)})).unwrap!
  _started = Process.read_line(p, {ms(5000)}).unwrap!
  puts("ready")
  IO.flush()
  _line = IO.gets()
end
"""

# Windows has no /bin/sh: the program under test starts the Python peer that prints its pid and waits, and writes the
# pid to the file the shell writes on the other systems, and its own pid to a second file. A file appears whole (it is
# renamed into place), so the test never reads half a pid.
WINDOWS_HOLDER_PROGRAM = f"""def publish(name: String, text: String) -> Void
  File.write_text(name + ".tmp", text, {ms(5000)}).unwrap!
  Path.rename(name + ".tmp", name, {ms(5000)}).unwrap!
end

def main() -> Void
  p = Process.spawn({agc_literal(PYTHON)}, [{agc_literal(FIXTURES / "process-peer.py")}, "hold"], Process.Options(timeout_ms: {ms(5000)})).unwrap!
  pid = Process.read_line(p, {ms(5000)}).unwrap!
  publish("program-pid.txt", System.pid().to_s)
  publish("pid.txt", pid)
  puts("ready")
  IO.flush()
  _line = IO.gets()
end
"""
HOLDER = WINDOWS_HOLDER_PROGRAM if os.name == "nt" else HOLDER_PROGRAM
not_wine = pytest.mark.skipif(UNDER_WINE, reason="Wine runs the Windows binary, which starts neither /bin/sh nor a Linux Python")
# On Windows the killed driver and its tree end in a few seconds, so the case runs in the fast tier, which the Windows
# job runs; the slow tier runs on Linux only.
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


def describe_missing_run(temporary, driver, pid_file):
    """Why the process list may not name the run folder, for an assertion message (Windows): the driver's state, the
    pid file, the folder in both spellings and what it holds, and the processes that name the folder or agentica. A
    part that cannot be read says so, so the message never hides the failure."""
    def part(read):
        try:
            return read()
        except Exception as problem:  # any failure to read a part is shown, never raised
            return "unavailable: %r" % problem

    def listing():
        from tests.windows_support import processes_naming
        names = [str(temporary), os.path.realpath(temporary), "agentica"]
        return processes_naming(names, 15)

    return "\n".join([
        "no process names the run folder",
        "driver exit status (None while it runs): %s" % part(driver.process.poll),
        "pid file: %s" % part(lambda: repr(pid_file.read_text())),
        "folder: %s, real path %s" % (temporary, part(lambda: os.path.realpath(temporary))),
        "folder holds: %s" % part(lambda: sorted(os.listdir(temporary))),
        "processes that name the folder or agentica:\n%s" % part(listing),
    ])


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


def json_test(*args, before=(), timeout=None):
    limit = {"timeout": timeout} if timeout else {}
    result = run(cli() + [*before, "test", "--json", *args], env=vm_environment(), **limit)
    assert result.stderr == ""
    return result.json()


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
        "echo.agc": "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  IO.flush()\n  _ = IO.gets()\nend\n",
        "steps.agc": dedent(f"""\
            import BDD from "std/bdd"

            def receive(ctx: BDD.Context) -> BDD.Context
              return BDD.then_line(ctx, "hello", {ms(5000)})
            end

            def exchange(ctx: BDD.Context, args: List[String]) -> BDD.Context
              task = Task.spawn(&receive, ctx)
              Task.sleep(0)
              _sent = BDD.when_line(ctx, "hello")
              return Task.await(task)
            end

            def wait(ctx: BDD.Context) -> BDD.Context
              return BDD.then_line(ctx, "never", 5000)
            end

            def pending(ctx: BDD.Context, args: List[String]) -> BDD.Context
              _task = Task.spawn(&wait, ctx)
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


def test_a_step_reads_the_next_line_as_a_result_that_fails_at_the_end_of_the_output_or_a_timeout(tmp_path):
    directory = suite(tmp_path, {
        "two.agc": 'def main() -> Void\n  puts("one")\n  puts("two")\nend\n',
        "wait.agc": 'def main() -> Void\n  puts("one")\n  IO.flush()\n  _ = IO.gets()\nend\n',
        "steps.agc": dedent(f"""\
            import BDD from "std/bdd"

            def main() -> Void
              BDD.run([
                BDD.step("the line is {{string}}") do |ctx, args|
                  line = BDD.read_line(ctx, {ms(5000)})
                  BDD.assert(ctx, line.ok? and line.unwrap! == args[0], "wrong line")
                end,
                BDD.step("no line comes within {{int}} milliseconds") do |ctx, args|
                  line = BDD.read_line(ctx, args[0].to_i!)
                  BDD.assert(ctx, not line.ok?, "a line came")
                end,
              ])
            end
            """),
        "lines.feature": (
            "Feature: Lines\nScenario: end\nGiven the Agentica program \"two.agc\"\n"
            'Then the line is "one"\nAnd the line is "two"\nAnd no line comes within ' + ms(5000) + " milliseconds\n"
            'Scenario: timeout\nGiven the Agentica program "wait.agc"\nThen the line is "one"\n'
            "And no line comes within 100 milliseconds\n"
            # A timeout stops the program: the next read is an I/O failure, and a read with no program is a context error.
            'Scenario: read after a timeout\nGiven the Agentica program "wait.agc"\nThen the line is "one"\n'
            "And no line comes within 100 milliseconds\nAnd the line is \"never\"\n"
            'Scenario: read before a program\nThen the line is "one"\n')})
    report = json_test(directory / "lines.feature", "--steps", directory / "steps.agc")
    assert [item["status"] for item in report_cases(report)] == ["passed", "passed", "failed", "failed"]
    assert codes(report)[2:] == ["RUNTIME-BDD-IO", "RUNTIME-BDD-CONTEXT"]


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
              BDD.run([BDD.step("stdout repeats the seeded draw") do |ctx, _| BDD.then_stdout(ctx, {draw} + "\\n") end])
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


def test_a_scenario_gives_its_program_environment_variables_and_arguments_that_reach_no_other_scenario(tmp_path):
    directory = suite(tmp_path, {
        "show.agc": ('def main() -> Void\n'
                     '  puts("#{System.env("BDD_GREETING").unwrap_or("unset")}|#{System.args().join(",")}")\n'
                     '  puts(System.env("HOME").unwrap_or("no home").length > 0)\nend\n'),
        "env.feature": (
            "Feature: Environment\n"
            "Scenario: set\n"
            'Given the environment variable "BDD_GREETING" is "hello there"\n'
            'And the environment variable "BDD_GREETING" is "hi there"\n'
            'And the program argument "a b"\nAnd the program argument "--flag"\n'
            'And the Agentica program "show.agc"\n'
            'Then I receive the line "hi there|a b,--flag" within ' + ms(5000) + " milliseconds\n"
            'And I receive the line "true" within ' + ms(5000) + " milliseconds\n"
            "Scenario: nothing is left over\n"
            'Given the Agentica program "show.agc"\n'
            'Then I receive the line "unset|" within ' + ms(5000) + " milliseconds\n"
            "Scenario: too late\n"
            'Given the Agentica program "show.agc"\nAnd the program argument "x"\n'
            "Scenario: an empty name\n"
            'Given the environment variable "" is "x"\n'
            # Windows ignores ASCII case in names: the second spelling replaces the first there, as one name does here.
            "Scenario: a name again in other case\n"
            'Given the environment variable "Bdd_Greeting" is "first"\n'
            'And the environment variable "BDD_GREETING" is "second"\n'
            'And the Agentica program "show.agc"\n'
            'Then I receive the line "second|" within ' + ms(5000) + " milliseconds\n"
            # Refused when set, not when the program starts.
            "Scenario: a name the VM owns\n"
            'Given the environment variable "UV_USE_IO_URING" is "0"\nAnd the Agentica program "show.agc"\n'
            "Scenario: a NUL byte\n"
            'Given the environment variable "BDD_GREETING" ends with a NUL byte\nAnd the Agentica program "show.agc"\n'),
        "steps.agc": dedent("""\
            import BDD from "std/bdd"

            def main() -> Void
              BDD.run([
                BDD.step("the environment variable {string} ends with a NUL byte") do |ctx, args|
                  BDD.given_env(ctx, args[0], "x" + String.from_bytes(Bytes.from_list([0]).unwrap!).unwrap!)
                end,
              ])
            end
            """)})
    report = json_test(directory / "env.feature")
    cases = report_cases(report)
    assert [item["status"] for item in cases] == ["passed", "passed", "failed", "failed", "passed", "failed", "failed"]
    assert codes(report) == [None, None, "RUNTIME-BDD-CONTEXT", "RUNTIME-BDD-CONTEXT", None, "RUNTIME-BDD-CONTEXT",
                             "RUNTIME-BDD-CONTEXT"]
    assert [[step["status"] for step in item["steps"]] for item in cases[5:]] == [["failed", "not_executed"]] * 2


def test_stdout_and_stderr_includes_check_a_substring_after_the_program_exits(tmp_path):
    directory = suite(tmp_path, {
        "log.agc": ('def main() -> Void\n  puts("alpha beta")\n  IO.warn("warn: one")\n  IO.warn("warn: two")\n'
                    '  System.exit(3)\nend\n'),
        "wait.agc": "def main() -> Void\n  line = IO.gets()\nend\n",
        "log.feature": (
            "Feature: Includes\n"
            'Scenario: both streams\nGiven the Agentica program "log.agc"\n'
            "Then the program exits with code 3 within " + ms(5000) + " milliseconds\n"
            "And stdout includes:\n" + doc("beta")
            + "And stderr includes:\n" + doc("warn: two")
            + 'Scenario: a substring that is missing\nGiven the Agentica program "log.agc"\n'
            "Then the program exits with code 3 within " + ms(5000) + " milliseconds\n"
            "And stderr includes:\n" + doc("warn: three")
            + 'Scenario: stdout missing\nGiven the Agentica program "log.agc"\n'
            "Then the program exits with code 3 within " + ms(5000) + " milliseconds\n"
            "And stdout includes:\n" + doc("gamma")
            + 'Scenario: the program still runs\nGiven the Agentica program "wait.agc"\n'
            "Then stderr includes:\n" + doc("x")
            + 'Scenario: an empty text\nGiven the Agentica program "log.agc"\n'
            "Then the program exits with code 3 within " + ms(5000) + " milliseconds\n"
            'And stdout includes:\n  """\n  """\n')})
    report = json_test(directory / "log.feature")
    assert [item["status"] for item in report_cases(report)] == ["passed", "failed", "failed", "failed", "failed"]
    assert codes(report) == [None, "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-CONTEXT",
                             "RUNTIME-BDD-CONTEXT"]
    results = report_cases(report)
    assert details(results[1]) == ['text including "warn: three"', '"warn: one\\nwarn: two\\n"']
    assert details(results[2]) == ['text including "gamma"', '"alpha beta\\n"']


def test_a_step_runs_a_peer_with_spawn_captured_and_keep_beside_the_program_and_it_ends_with_the_scenario(tmp_path):
    """The pattern the BDD page gives for a scenario that needs a second program: the step starts the peer, learns
    what the program needs from it, and keeps its handle in a service; the peer stops when the scenario ends."""
    directory = (tmp_path / "suite").resolve()
    peer_pid = directory / "peer-pid.txt"
    files = {
        "app.agc": 'def main() -> Void\n  puts(System.env("PEER_PID").unwrap_or("none"))\nend\n',
        "steps.agc": dedent(f"""\
            import BDD from "std/bdd"

            def start_peer(ctx: BDD.Context, args: List[String]) -> BDD.Context
              peer = Process.spawn_captured({agc_literal(PYTHON)}, [{agc_literal(FIXTURES / "process-peer.py")}, "hold"], Process.Options(timeout_ms: {ms(5000)})).unwrap!
              pid = Process.read_line(peer, {ms(5000)}).unwrap!
              File.write_text({agc_literal(peer_pid)}, pid, {ms(5000)}).unwrap!
              kept = BDD.keep(ctx, "peer") do |_request|
                ok(JSON.from(not Process.wait(peer, 1).ok?))
              end
              return BDD.given_env(BDD.set(kept, "pid", JSON.from(pid)), "PEER_PID", pid)
            end

            def main() -> Void
              BDD.run([
                BDD.step("a peer program", &start_peer),
                BDD.step("the program printed the pid of the peer") do |ctx, _|
                  pid = JSON.string(BDD.get(ctx, "pid").unwrap!).unwrap!
                  BDD.then_line(ctx, pid, {ms(5000)})
                end,
                BDD.step("the scenario fails") do |ctx, _| BDD.assert(ctx, false, "on purpose") end,
                BDD.step("the peer still runs") do |ctx, _|
                  running = JSON.bool(BDD.call(ctx, "peer", JSON.null()).unwrap!).unwrap!
                  BDD.assert(ctx, running, "the peer ended")
                end,
              ])
            end
            """),
        "peer.feature": (
            "Feature: Peer\nScenario: the program and its peer\nGiven a peer program\n"
            'And the Agentica program "app.agc"\nThen the program printed the pid of the peer\n'
            "And the peer still runs\n"),
        "failing.feature": "Feature: Failing\nScenario: a failed scenario\nGiven a peer program\nThen the scenario fails\n"}
    suite(tmp_path, files)
    pids = []
    try:
        report = json_test(directory / "peer.feature", "--steps", directory / "steps.agc")
        assert [item["status"] for item in report_cases(report)] == ["passed"], str(report)
        pids.append(peer_pid.read_text())
        assert wait_until(lambda: not process_alive(pids[0])), "the peer outlived its scenario"
        failed = json_test(directory / "failing.feature", "--steps", directory / "steps.agc")
        assert [item["status"] for item in report_cases(failed)] == ["failed"], str(failed)
        pids.append(peer_pid.read_text())
        assert pids[1] != pids[0]
        assert wait_until(lambda: not process_alive(pids[1])), "the peer outlived its failed scenario"
    finally:
        for pid in pids:
            kill_process(pid)


AFTER_STEPS = dedent("""\
    import BDD from "std/bdd"

    def cleanup(closing: BDD.Context, log: String, name: String) -> Result[Void]
      File.append_text(log, name + "\\n", 5000).unwrap!
      if name == "bad"
        return error("cleanup failed")
      elsif name == "crash"
        _invalid = 1 / 0
      elsif name == "check"
        BDD.assert(closing, false, "hook check")
      elsif name == "skip"
        BDD.skip(closing, "from a hook")
      elsif name == "sleep"
        Task.sleep(60000)
      end
      return ok()
    end

    def hook(ctx: BDD.Context, args: List[String]) -> BDD.Context
      log = args[1]
      name = args[0]
      return BDD.after(ctx) do |closing| cleanup(closing, log, name) end
    end

    # The hook checks the context of its registration, not the one it is given: the check still fails only the hook.
    def stale(ctx: BDD.Context, args: List[String]) -> BDD.Context
      log = args[0]
      return BDD.after(ctx) do |_| stale_check(ctx, log) end
    end

    def stale_check(ctx: BDD.Context, log: String) -> Result[Void]
      File.append_text(log, "stale\\n", 5000).unwrap!
      BDD.assert(ctx, false, "stale check")
      return ok()
    end

    def older(ctx: BDD.Context, args: List[String]) -> BDD.Context
      _registered = hook(ctx, args)
      return BDD.assert(ctx, false, "failed on the older context")
    end

    def folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
      path = args[0]
      Dir.mkdir(path, 5000).unwrap!
      return BDD.after(ctx) do |_| Path.remove(path, 5000) end
    end

    def main() -> Void
      BDD.run([
        BDD.step("the hook {string} logs to {string}", &hook),
        BDD.step("the hook {string} logs to {string} and the step fails on the older context", &older),
        BDD.step("a hook that checks its older context logs to {string}", &stale),
        BDD.step("the folder {string} exists until the scenario ends", &folder),
        BDD.step("the scenario fails") do |ctx, _| BDD.assert(ctx, false, "the step failed") end,
        BDD.step("the scenario passes") do |ctx, _| BDD.assert(ctx, true, "never") end,
        BDD.step("the scenario is skipped") do |ctx, _| BDD.skip(ctx, "not here") end,
      ])
    end
    """)


def test_after_hooks_run_last_first_also_after_a_failure_or_a_skip_and_a_failing_hook_stops_no_other(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    gone = (tmp_path / "gone").as_posix()

    def log(name):
        return (logs / name).as_posix()

    def scenario(title, *lines):
        return "Scenario: " + title + "\n" + "".join(line + "\n" for line in lines)

    directory = suite(tmp_path, {
        "steps.agc": AFTER_STEPS,
        "after.feature": "Feature: After\n" + scenario(
            "passes", f'Given the hook "one" logs to "{log("passes")}"', f'And the hook "two" logs to "{log("passes")}"',
            "Then the scenario passes"
        ) + scenario(
            "fails", f'Given the folder "{gone}" exists until the scenario ends',
            f'And the hook "one" logs to "{log("fails")}"', "When the scenario fails"
        ) + scenario(
            "skipped", f'Given the hook "one" logs to "{log("skipped")}"', "When the scenario is skipped"
        ) + scenario(
            "a hook breaks a passing scenario", f'Given the hook "one" logs to "{log("breaks")}"',
            f'And the hook "bad" logs to "{log("breaks")}"', f'And the hook "crash" logs to "{log("breaks")}"',
            f'And the hook "check" logs to "{log("breaks")}"', "Then the scenario passes"
        ) + scenario(
            "a hook is added to a failure", f'Given the hook "bad" logs to "{log("both")}"', "When the scenario fails"
        ) + scenario(
            "a hook fails a skipped scenario", f'Given the hook "bad" logs to "{log("skip-bad")}"',
            "When the scenario is skipped"
        ) + scenario(
            "a hook cannot skip", f'Given the hook "skip" logs to "{log("skip-hook")}"', "Then the scenario passes"
        ) + scenario(
            "a hook of the same step on an older context is lost",
            f'Given the hook "one" logs to "{log("older")}" and the step fails on the older context'
        ) + scenario(
            "a hook that checks an older context fails alone", f'Given the hook "one" logs to "{log("stale")}"',
            f'And a hook that checks its older context logs to "{log("stale")}"', "Then the scenario passes")})
    report = json_test(directory / "after.feature")
    cases = report_cases(report)
    assert [item["status"] for item in cases] == ["passed", "failed", "skipped", "failed", "failed", "failed", "failed",
                                                   "failed", "failed"]
    assert codes(report) == [None, "RUNTIME-BDD-ASSERTION", None, "RUNTIME-BDD-AFTER", "RUNTIME-BDD-ASSERTION",
                             "RUNTIME-BDD-AFTER", "RUNTIME-BDD-AFTER", "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-AFTER"]
    assert (logs / "passes").read_text().split() == ["two", "one"]
    assert (logs / "fails").read_text().split() == ["one"]
    assert not (tmp_path / "gone").exists()
    assert "the step failed" in cases[1]["error"]["message"]
    assert (logs / "skipped").read_text().split() == ["one"]
    assert (logs / "breaks").read_text().split() == ["check", "crash", "bad", "one"]
    broken = cases[3]["error"]["message"]
    assert "cleanup failed" in broken and "hook check" in broken and "division by zero" in broken
    both = cases[4]["error"]["message"]
    assert both.startswith("the step failed") and "cleanup failed" in both
    assert (logs / "skip-bad").read_text().split() == ["bad"]
    assert "cleanup failed" in cases[5]["error"]["message"]
    assert (logs / "skip-hook").read_text().split() == ["skip"]
    assert "cannot skip" in cases[6]["error"]["message"]
    assert not (logs / "older").exists()
    # Each hook ran once: the stale check did not run the earlier hook again from inside its own.
    assert (logs / "stale").read_text().split() == ["stale", "one"]


@pytest.mark.slow
def test_a_hook_that_never_ends_is_reported_at_the_scenario_limit_for_a_passing_failing_or_skipped_scenario(tmp_path):
    log = (tmp_path / "log").as_posix()
    directory = suite(tmp_path, {
        "steps.agc": AFTER_STEPS,
        "hang.feature": ("Feature: Hang\n"
                         f'Scenario: passes\nGiven the hook "sleep" logs to "{log}"\nThen the scenario passes\n'
                         f'Scenario: fails\nGiven the hook "sleep" logs to "{log}"\nWhen the scenario fails\n'
                         f'Scenario: skipped\nGiven the hook "sleep" logs to "{log}"\nWhen the scenario is skipped\n')})
    # Three scenarios wait for the 30 s limit one after the other.
    report = json_test(directory / "hang.feature", timeout=scaled(160))
    cases = report_cases(report)
    assert codes(report) == ["RUNTIME-BDD-TIMEOUT", "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-TIMEOUT"]
    for item in cases:
        assert "after hook did not finish" in item["error"]["message"]


def test_a_program_under_test_runs_without_a_step_limit(tmp_path):
    # Each loop pass is several steps, so 400,000 passes are well over the 1,000,000 steps the program once had.
    directory = suite(tmp_path, {
        "busy.agc": ("def main() -> Void\n  total = 0\n  for i in 0...400000\n    total = total + i\n  end\n"
                     "  puts(total.to_s)\nend\n"),
        "busy.feature": ('Feature: Busy\nScenario: more than 1,000,000 steps\nGiven the Agentica program "busy.agc"\n'
                         "Then the program exits with code 0 within " + ms(20000) + " milliseconds\n"
                         "And stdout is:\n" + doc("79999800000\n"))})
    assert json_test(directory / "busy.feature")["ok"] is True


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
    report = json_test(directory / "holder.feature")
    assert codes(report) == ["RUNTIME-BDD-TIMEOUT"]
    pid = pid_file.read_text().strip()
    assert wait_until(lambda: not process_alive(pid), scaled(5)), pid


@host_only(WINDOWS, "a shared temporary folder is told apart by the sticky bit and group permission bits, and Windows has neither; the Windows runner assumes a private per-user %TEMP% (no shared-folder check there, by design)")
def test_a_temporary_directory_others_can_write_to_without_the_sticky_bit_is_refused(tmp_path):
    directory = suite(tmp_path, {})
    temporary = directory / "shared"
    temporary.mkdir()

    def status_and_code():
        result = run(cli() + ["test", "--json", directory], env=vm_environment({"TMPDIR": temporary}))
        report = result.json()
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
                      '  BDD.run([BDD.step("the handler prints for ever") do |ctx, _|\n'
                      '    chunk = List.repeat("x", 100000).join("")\n'
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
                      '  chunk = List.repeat("x", 100000).join("")\n'
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
        "oversized.agc": 'def main() -> Void\n  puts(List.repeat("x", 1048576).join(""))\nend\n',
        "flood.agc": 'def main() -> Void\n  IO.warn(List.repeat("x", 1048576).join(""))\n  _ = IO.gets()\nend\n',
        "where.agc": "def main() -> Void\n  puts(Path.cwd().unwrap!)\nend\n",
        "json.agc": JSON_PROGRAM,
        "quotes.agc": 'def main() -> Void\n  puts(List.repeat("\\"", 300000).join(""))\nend\n',
        "steps.agc": ('import BDD from "std/bdd"\n\ndef main() -> Void\n'
                      '  BDD.run([BDD.step("the handler floods stdout") do |ctx, _|\n'
                      '    puts(List.repeat(List.repeat("x", 1000).join(""), 1100).join("\\n"))\n'
                      "    ctx\n  end,\n"
                      '  BDD.step("the handler fails with a huge message") do |ctx, _|\n'
                      '    BDD.assert(ctx, false, List.repeat("xxxxxxxxxx", 110000).join(""))\n'
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
            'Then I receive the line "' + str(directory) + '" within ' + ms(5000) + ' milliseconds\n'
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
    program_pid_file = directory / "program-pid.txt"  # Windows only: the holder writes its own pid
    kill_at_end(cleanup, lambda: processes_mentioning(temporary) + [
        file.read_text().strip() for file in (pid_file, program_pid_file) if file.exists()])
    driver = Child(cli() + ["test", directory / "holder.feature"], env=env)
    cleanup(driver.stop)
    assert wait_until(
        lambda: pid_file.exists() and any(c.isdigit() for c in pid_file.read_text()), scaled(20))
    if os.name == "nt":
        # The process list names the runner and the scenario VM by their run folder; without them in the list, the wait
        # for an empty list after the kill would prove nothing.
        assert wait_until(lambda: processes_mentioning(temporary), scaled(20), 0.5), (
            describe_missing_run(temporary, driver, pid_file))
    # Only the driver dies, not its process group: the runner, the VM and the program must follow it.
    driver.process.kill()
    driver.process.wait(scaled(20))
    pid = pid_file.read_text().strip()
    assert wait_until(lambda: not process_alive(pid), scaled(5)), pid
    assert wait_until(lambda: not processes_mentioning(temporary), scaled(20))
    assert len(os.listdir(temporary)) == 1
    if os.name == "nt":
        # The VM that runs the program under test is gone too, not only the child it started.
        program_pid = program_pid_file.read_text().strip()
        assert wait_until(lambda: not process_alive(program_pid), scaled(5)), program_pid
        # Windows sweeps only folders a minute old, with locks of its own: the sweep is checked on folders made by hand
        # in test_a_run_removes_the_folder_of_an_ended_run_and_leaves_the_folder_of_a_live_one (tests/test_bdd.py).
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
