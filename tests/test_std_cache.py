"""std/cache: tests/std/cache_test.agc, whose tests also run in the std suite, here on four schedulers.

The tasks of its last six tests race on one cache; the file checks the values they get and the byte count.
"""
import json

from tests.agentica_test import TESTS, cli, run, vm_environment


def test_the_cache_tests_pass_on_four_schedulers():
    command = cli() + ["test", "--json", str(TESTS / "std" / "cache_test.agc")]
    result = run(command, env=vm_environment({"AGENTICA_SCHEDULERS": 4}))
    assert result.stderr == ""
    report = json.loads(result.stdout)
    assert (result.code, report["passed"], report["failed"]) == (0, 18, 0), failures(report)


def failures(report):
    """The file errors and the failed tests of REPORT, each with its error, for the assertion message: a race that
    fails once in many runs is then named by the run that hit it."""
    lines = []
    for file in report["files"]:
        if file["error"]:
            lines.append("file %s: %s" % (file["path"], json.dumps(file["error"])))
            lines.extend(output_tail(file))
        for scenario in file["scenarios"]:
            if scenario["status"] != "passed":
                lines.append("%s %r: %s" % (scenario["status"], scenario["name"], json.dumps(scenario["error"])))
                lines.extend(output_tail(scenario))
    return "\n".join(lines)


def output_tail(item):
    """The last 2000 characters of what a file or test printed, which shows why it crashed or timed out."""
    output = item.get("output") or ""
    return ["  output: %r" % output[-2000:]] if output else []
