"""std/actor and std/supervisor: tests/std/actor_test.agc and supervisor_test.agc, whose tests also run in the std
suite, here on one and on four schedulers.

actor_test covers cast, call, a timed-out call, stop, a handler that ends the actor, a crash, a stop that times out, a
monitor notice, an init that monitors into its own inbox (Actor.inbox), a task the actor spawns that has no inbox, an
actor that calls itself, answers that race the timeout of their call (taken or refused, never lost), a second reply,
send and await (two actors handling at the same time, an await past its deadline, a second await, a stopped actor) and the
receive timeout (repeated, next to messages, changed per message, 0 or less, a passed deadline, stop and crash
with a wait pending, 1,000 actors with no extra task). supervisor_test covers a restart that registers the new address,
a child that ends without a crash, a restart that starts the receive timeout again, the stop order, the restart limit
(the supervisor crashes), failed starts (in the register block, in init, many next to another child's crash, many in a
row), the window of the limit, a crashing terminate and a child error that reads like a supervisor reason. The crashes
leave their diagnostics in the tests' output.
"""
import json

import pytest

from tests.agentica_test import TESTS, cli, run, vm_environment

# A test file and how many tests it has.
FILES = [("actor_test.agc", 25), ("supervisor_test.agc", 12)]


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


def halt_code(tmp_path, imports, line):
    program = tmp_path / "halt.agc"
    program.write_text(f"{imports}\n\ndef main() -> Void\n{line}\nend\n", encoding="utf-8")
    result = run(cli() + ["--json", str(program)], env=vm_environment())
    assert result.code == 1
    return json.loads(result.stderr.strip().splitlines()[-1])["code"]


def test_start_halts_on_options_out_of_range(tmp_path):
    line = "  _ = Supervisor.start([], Supervisor.Options(within_ms: 0))"
    assert halt_code(tmp_path, 'import Supervisor from "std/supervisor"', line) == "RUNTIME-UNWRAP-ERROR"


def test_inbox_outside_an_actor_halts(tmp_path):
    line = "  inbox: Channel[Int] = Actor.inbox\n  inbox.close"
    assert halt_code(tmp_path, 'import Actor from "std/actor"', line) == "RUNTIME-UNWRAP-ERROR"
