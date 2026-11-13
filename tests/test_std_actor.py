"""std/actor and std/supervisor: tests/std/actor_test.agc and supervisor_test.agc, whose tests also run in the std
suite, here on one and on four schedulers.

actor_test covers cast, call, a timed-out call, stop, a handler that ends the actor, a crash, a stop that times out, a
monitor notice, an actor that calls itself, answers that race the timeout of their call (taken or refused, never lost)
and the receive timeout (repeated, next to messages, changed per message, 0 or less, stop and crash with a wait
pending, 1,000 actors with no extra task). supervisor_test covers a restart that registers the new address, a child
that ends without a crash, a restart that starts the receive timeout again, the stop order, the restart limit (the
supervisor crashes), failed starts (in the register block, in init, many next to another child's crash, many in a
row), the window of the limit, a crashing terminate and a child error that reads like a supervisor reason. The crashes
leave their diagnostics in the tests' output.
"""
import json

import pytest

from tests.agentica_test import TESTS, cli, run, vm_environment

# A test file and how many tests it has.
FILES = [("actor_test.agc", 17), ("supervisor_test.agc", 12)]


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


def test_start_halts_on_options_out_of_range(tmp_path):
    program = tmp_path / "bad.agc"
    program.write_text(
        'import Supervisor from "std/supervisor"\n\n'
        "def main() -> Void\n"
        "  _ = Supervisor.start([], Supervisor.Options(within_ms: 0))\n"
        "end\n", encoding="utf-8")
    result = run(cli() + ["--json", str(program)], env=vm_environment())
    assert result.code == 1
    diagnostic = json.loads(result.stderr.strip().splitlines()[-1])
    assert diagnostic["code"] == "RUNTIME-UNWRAP-ERROR"
