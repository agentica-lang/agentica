"""`agentica test` driving real programs under test (ported from bdd-integration.rkt).

Live JSON lines, tasks in handlers, seeds, wrong output, process cleanup and
the temporary-directory rules. The slow tier keeps the large sizes (1 MiB
outputs, floods), the output limits reached by endless prints (15 s deadlines)
and a killed driver with its process tree; the fast smoke case keeps the other
paths. Each case runs the CLI as a child.
"""
import fcntl
import json
import os
import signal
import time

from tests.agentica_test import (TESTS, Child, TestCase, cli, process_alive, report_cases, run, scaled, slow,
                                 vm_environment, wait_until, write_files)

# The deadline of a step is scaled for slow runners, but stays under the 30 s deadline of a whole scenario (the
# default of `agentica test`, which has no flag), or a slow step would end as a scenario timeout instead.
def ms(milliseconds):
    return str(min(scaled(milliseconds), 25000))


STREAM_SPEC = str(TESTS / "bdd" / "specs" / "json-lines.feature")

HOLDER_PROGRAM = (
    "def main() -> Void\n"
    '  p = Process.spawn("/bin/sh", ["-c", "echo $$ > pid.txt; echo started; exec sleep 60"], ' + ms(5000)
    + ").unwrap!\n  started = Process.read_line(p, " + ms(5000) + ").unwrap!\n"
    '  puts("ready")\n  IO.flush()\n  line = IO.gets()\nend\n')

BUFFERED_PROGRAM = "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  line = IO.gets!()\nend\n"
OUTPUT_PROGRAM = 'def main() -> Void\n  puts("actual")\n  IO.warn("warning")\n  System.exit(3)\nend\n'
JSON_PROGRAM = 'def main() -> Void\n  puts("{\\"b\\": \\"3\\", \\"a\\": 1}")\nend\n'


def processes_mentioning(text):
    """The pids whose command line contains `text` (Linux /proc)."""
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


class BddIntegration(TestCase):
    def json_test(self, *args, before=()):
        result = run(cli() + [*before, "test", "--json", *args], env=vm_environment())
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def suite(self, files):
        return self.make_suite(files, "agentica-bdd-integration-")

    def kill_at_end(self, pids):
        """Kill what a failing test would leave running; `pids` is called at the end, when the pids are known."""
        def kill():
            for pid in pids():
                try:
                    os.kill(int(pid), signal.SIGKILL)
                except (ProcessLookupError, ValueError):
                    pass
        self.addCleanup(kill)

    def test_live_json_replies_arrive_before_eof_and_recover_after_errors(self):
        report = self.json_test(STREAM_SPEC)
        self.assertIs(report["ok"], True, str(report))
        self.assertEqual(report["passed"], 2)

    def test_a_task_receives_while_its_handler_sends_and_a_pending_read_fails_its_scenario(self):
        directory = self.suite({
            "echo.agc": "def main() -> Void\n  line = IO.gets!()\n  puts(line)\n  IO.flush()\n  ending = IO.gets()\nend\n",
            "steps.agc": (
                'import BDD from "std/bdd"\n\n'
                "def receive(ctx: BDD.Context) -> BDD.Context\n"
                '  return BDD.then_line(ctx, "hello", ' + ms(5000) + ')\nend\n\n'
                "def exchange(ctx: BDD.Context, args: List[String]) -> BDD.Context\n  task = Task.spawn(&receive, ctx)\n"
                '  Task.sleep(0)\n  sent = BDD.when_line(ctx, "hello")\n  return Task.await(task)\nend\n\n'
                'def wait(ctx: BDD.Context) -> BDD.Context\n  return BDD.then_line(ctx, "never", 5000)\nend\n\n'
                "def pending(ctx: BDD.Context, args: List[String]) -> BDD.Context\n"
                "  task = Task.spawn(&wait, ctx)\n  Task.sleep(0)\n  return ctx\nend\n\n"
                'def main() -> Void\n  BDD.run([BDD.step("exchange concurrently", &exchange), '
                'BDD.step("leave a pending read", &pending)])\nend\n'),
            "tasks.feature": (
                'Feature: Concurrent streams\nBackground:\nGiven the Agentica program "echo.agc"\n'
                "Scenario: exchange\nThen exchange concurrently\nWhen I close stdin\n"
                "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n"
                "Scenario: pending\nThen leave a pending read\n"
                "Scenario: later\nThen exchange concurrently\nWhen I close stdin\n"
                "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n")})
        report = self.json_test(directory / "tasks.feature", "--steps", directory / "steps.agc")
        self.assertEqual(codes(report), [None, "RUNTIME-BDD-PENDING-TASKS", None])

    def test_a_seed_given_or_drawn_reaches_step_handlers_and_programs_under_test(self):
        draw = 'Random.int(1, 1000000).to_s + " " + Random.int(1, 1000000).to_s'
        directory = self.suite({
            "draw.agc": "def main() -> Void\n  puts(%s)\nend\n" % draw,
            "steps.agc": ('import BDD from "std/bdd"\n\ndef main() -> Void\n'
                          '  BDD.run([BDD.step("stdout repeats the seeded draw") do |ctx, args| '
                          'BDD.then_stdout(ctx, %s + "\\n") end])\nend\n' % draw),
            "seed.feature": ('Feature: Seeds\nScenario: seeded\nGiven the Agentica program "draw.agc"\n'
                             "Then the program exits with code 0 within " + ms(5000) + " milliseconds\n"
                             "And stdout repeats the seeded draw\n")})
        arguments = [directory / "seed.feature", "--steps", directory / "steps.agc"]
        self.assertIs(self.json_test(*arguments, before=["--seed", "9"])["ok"], True)
        drawn = self.json_test(*arguments)
        self.assertIs(drawn["ok"], True)
        self.assertIsInstance(drawn["seed"], int)
        self.assertGreaterEqual(drawn["seed"], 0)

    def test_programs_under_test_wrong_output_literal_input_and_a_json_line_mismatch(self):
        directory = self.suite({
            "buffered.agc": BUFFERED_PROGRAM, "output.agc": OUTPUT_PROGRAM, "json.agc": JSON_PROGRAM,
            "smoke.feature": "Feature: Smoke\n" + WRONG_STDOUT_SCENARIO + LITERAL_INPUT_SCENARIO + JSON_MISMATCH_SCENARIO})
        report = self.json_test(directory / "smoke.feature")
        self.assertEqual(codes(report), ["RUNTIME-BDD-ASSERTION", None, "RUNTIME-BDD-ASSERTION"])
        self.assertEqual([details(report_cases(report)[0]), details(report_cases(report)[2])],
                         [['"incorrect"', '"actual\\n"'], ['{"a":1,"b":3}', '{"a":1,"b":"3"}']])

    def test_a_failed_scenario_leaves_no_process_of_its_program_behind(self):
        directory = self.suite({
            "holder.agc": HOLDER_PROGRAM,
            "holder.feature": ('Feature: Cleanup\nScenario: held\nGiven the Agentica program "holder.agc"\n'
                               'Then I receive the line "ready" within ' + ms(5000) + ' milliseconds\n'
                               "And the program exits with code 0 within 200 milliseconds\n")})
        pid_file = directory / "pid.txt"
        self.kill_at_end(lambda: [pid_file.read_text().strip()] if pid_file.exists() else [])
        report = self.json_test("--allow-run", directory / "holder.feature")
        self.assertEqual(codes(report), ["RUNTIME-BDD-TIMEOUT"])
        pid = pid_file.read_text().strip()
        self.assertTrue(wait_until(lambda: not process_alive(pid), scaled(5)), pid)

    def test_a_temporary_directory_others_can_write_to_without_the_sticky_bit_is_refused(self):
        directory = self.suite({})
        temporary = directory / "shared"
        temporary.mkdir()

        def status_and_code():
            result = run(cli() + ["test", "--json", directory], env=vm_environment({"TMPDIR": temporary}))
            report = json.loads(result.stdout)
            return [result.code, report["files"][0]["error"]["code"]]

        os.chmod(temporary, 0o777)
        self.assertEqual(status_and_code(), [2, "RUNTIME-BDD-INFRA"])
        os.chmod(temporary, 0o1777)
        self.assertEqual(status_and_code(), [1, "CHECK-BDD-EMPTY"])
        os.chmod(temporary, 0o775)
        self.assertEqual(status_and_code(), [1, "CHECK-BDD-EMPTY"])
        os.chmod(temporary, 0o2775)
        self.assertEqual(status_and_code(), [2, "RUNTIME-BDD-INFRA"])

    # Slow tier: large sizes, endless prints with 15 s deadlines, and a killed driver.

    @slow
    def test_a_handler_that_prints_for_ever_fails_at_the_output_limit_long_before_the_scenario_deadline(self):
        directory = self.suite({
            "steps.agc": ('import BDD from "std/bdd"\n\ndef main() -> Void\n'
                          '  BDD.run([BDD.step("the handler prints for ever") do |ctx, args|\n'
                          '    chunk = String.join(List.repeat("x", 100000), "")\n'
                          "    while true\n      puts(chunk)\n      Task.sleep(5)\n    end\n"
                          "    ctx\n  end])\nend\n"),
            "endless.feature": "Feature: Endless\nScenario: endless\nGiven the handler prints for ever\n"})
        started = time.monotonic()
        report = self.json_test(directory / "endless.feature", "--steps", directory / "steps.agc")
        self.assertLess(time.monotonic() - started, min(scaled(15), 25))
        self.assertEqual(codes(report), ["RUNTIME-BDD-OUTPUT-LIMIT"])

    @slow
    def test_a_step_program_that_prints_for_ever_while_it_lists_its_steps_fails_at_the_output_limit(self):
        directory = self.suite({
            "steps.agc": ('import BDD from "std/bdd"\n\ndef main() -> Void\n'
                          '  chunk = String.join(List.repeat("x", 100000), "")\n'
                          "  while true\n    puts(chunk)\n    Task.sleep(5)\n  end\n"
                          "  BDD.run([])\nend\n"),
            "listing.feature": "Feature: Listing\nScenario: never runs\nGiven something\n"})
        started = time.monotonic()
        report = self.json_test(directory / "listing.feature", "--steps", directory / "steps.agc")
        self.assertLess(time.monotonic() - started, min(scaled(15), 25))
        self.assertEqual([[file["kind"], file["error"]["code"] if isinstance(file["error"], dict) else None]
                          for file in report["files"]], [["steps", "RUNTIME-BDD-OUTPUT-LIMIT"]])

    @slow
    def test_programs_under_test_output_without_a_flush_wrong_output_the_output_limits_literal_input_and_the_working_directory(self):
        directory = self.suite({})
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
        report = self.json_test(directory / "lifecycle.feature", "--steps", directory / "steps.agc")
        self.assertEqual(codes(report), [
            None, "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-ASSERTION",
            "RUNTIME-BDD-OUTPUT-LIMIT", "RUNTIME-BDD-OUTPUT-LIMIT", None, None, None,
            "RUNTIME-BDD-OUTPUT-LIMIT", "RUNTIME-BDD-IO", "RUNTIME-BDD-ASSERTION", "RUNTIME-BDD-ASSERTION",
            "RUNTIME-BDD-OUTPUT-LIMIT"])
        results = report_cases(report)
        self.assertEqual([details(results[1]), details(results[3]), details(results[11])],
                         [['"incorrect"', '"actual\\n"'], ["0", "3"], ['{"a":1,"b":3}', '{"a":1,"b":"3"}']])
        long_actual = details(results[12])[1]
        self.assertEqual(len(long_actual), 65536 + len("... (534468 more characters)"))
        self.assertTrue(long_actual.endswith("\\... (534468 more characters)"))

    @slow
    def test_a_json_line_of_a_few_hundred_kb_fits_the_step_budget(self):
        items = ["abcdefghij"] * 30000
        directory = self.suite({
            "big.agc": 'def main() -> Void\n  puts(JSON.encode(JSON.from(List.repeat("abcdefghij", 30000))))\nend\n',
            "big.feature": ('Feature: Big\nScenario: big line\nGiven the Agentica program "big.agc"\n'
                            "Then I receive a JSON line within " + ms(5000) + " milliseconds:\n"
                            + doc(json.dumps(items, separators=(",", ":"))))})
        self.assertIs(self.json_test(directory / "big.feature")["ok"], True)

    @slow
    def test_killing_the_driver_stops_the_runner_the_scenario_vm_and_the_program_and_a_later_run_removes_its_folder(self):
        directory = self.suite({
            "holder.agc": HOLDER_PROGRAM,
            "holder.feature": ('Feature: Killed\nScenario: held\nGiven the Agentica program "holder.agc"\n'
                               'Then I receive the line "ready" within ' + ms(5000) + ' milliseconds\n'
                               "And the program exits with code 0 within " + ms(20000) + " milliseconds\n")})
        temporary = directory / "tmp"
        temporary.mkdir(0o700)
        env = vm_environment({"TMPDIR": temporary})
        # The runner, the VM and the program are not children of the test: kill them if the cleanup under test fails.
        self.kill_at_end(lambda: processes_mentioning(temporary))
        driver = self.adopt(Child(cli() + ["test", "--allow-run", directory / "holder.feature"], env=env))
        pid_file = directory / "pid.txt"
        self.assertTrue(wait_until(
            lambda: pid_file.exists() and any(c.isdigit() for c in pid_file.read_text()), scaled(20)))
        # Only the driver dies, not its process group: the runner, the VM and the program must follow it.
        driver.process.kill()
        driver.process.wait()
        pid = pid_file.read_text().strip()
        self.assertTrue(wait_until(lambda: not process_alive(pid), scaled(5)), pid)
        self.assertTrue(wait_until(lambda: not processes_mentioning(temporary), scaled(20)))
        self.assertEqual(len(os.listdir(temporary)), 1)
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
        self.assertEqual(sorted(os.listdir(temporary)),
                         ["agentica-bdd-00ff", "agentica-bdd-0123456789abcdef", "agentica-bdd-fedcba9876543210"])
        self.assertEqual((outside / "lock").read_text(), "keep")
