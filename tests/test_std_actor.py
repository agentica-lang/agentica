"""std/actor: tests/std/actor_test.agc, whose tests also run in the std suite, here on one and on four schedulers.

The file covers cast, call, a timed-out call, stop, a handler that ends the actor, a crash, a stop that times out, a
monitor notice and an actor that calls itself. The crash test leaves the crash diagnostic in that test's output.
"""
import json

import pytest

from tests.agentica_test import TESTS, cli, run, vm_environment


@pytest.mark.parametrize("schedulers", [1, 4])
def test_the_actor_tests_pass(schedulers):
    command = cli() + ["test", "--json", str(TESTS / "std" / "actor_test.agc")]
    result = run(command, env=vm_environment({"AGENTICA_SCHEDULERS": schedulers}))
    assert result.stderr == ""
    report = json.loads(result.stdout)
    failed = [(scenario["name"], scenario["error"]) for file in report["files"] for scenario in file["scenarios"]
              if scenario["status"] != "passed"]
    assert (result.code, report["passed"], failed) == (0, 9, []), report["files"][0]["error"]
