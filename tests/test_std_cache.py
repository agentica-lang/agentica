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
    assert (result.code, report["passed"], report["failed"]) == (0, 19, 0)
