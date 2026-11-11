"""std/actor and std/supervisor: tests/std/actor_test.agc and supervisor_test.agc, whose tests also run in the std
suite, here on one and on four schedulers.

actor_test covers cast, call, a timed-out call, stop, a handler that ends the actor, a crash, a stop that times out, a
monitor notice and an actor that calls itself. supervisor_test covers a restart that registers the new address, a
child that ends without a crash, the stop order, the restart limit (the supervisor crashes) and a failed start. The
crashes leave their diagnostics in the tests' output.
"""
import json

import pytest

from tests.agentica_test import TESTS, cli, run, vm_environment

# A test file and how many tests it has.
FILES = [("actor_test.agc", 9), ("supervisor_test.agc", 5)]


@pytest.mark.parametrize("schedulers", [1, 4])
@pytest.mark.parametrize("name,count", FILES)
def test_the_actor_and_supervisor_tests_pass(name, count, schedulers):
    command = cli() + ["test", "--json", str(TESTS / "std" / name)]
    result = run(command, env=vm_environment({"AGENTICA_SCHEDULERS": schedulers}))
    assert result.stderr == ""
    report = json.loads(result.stdout)
    failed = [(scenario["name"], scenario["error"]) for file in report["files"] for scenario in file["scenarios"]
              if scenario["status"] != "passed"]
    assert (result.code, report["passed"], failed) == (0, count, []), report["files"][0]["error"]
