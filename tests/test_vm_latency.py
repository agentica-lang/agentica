"""Task wake latency next to busy tasks.

Run alone by `make vm-latency` (and not by `make test`, see PY_ALONE in the
Makefile), so the VMs have the CPU to themselves. fixtures/latency/latency.agc
runs a sleeping task and a stdin reader next to CPU, sort and concat tasks, on
one scheduler: the turn costs keep the wake latency low where every task shares
one thread, and with more schedulers a woken task finds an idle one anyway.
"""
import os
import re
import threading
import time

import pytest

from tests.agentica_test import FIXTURES, Child, compile_agc, scaled, vm_command, vm_environment

LIMIT_MS = 250
WAIT_SECONDS = scaled(60)
LATENCY = FIXTURES / "latency" / "latency.agc"
CLOSE_READER = FIXTURES / "latency" / "close-reader.agc"


@pytest.fixture(scope="module")
def vm_cmd():
    if os.environ.get("AGENTICA_VM_BINARY"):
        pytest.skip("AGENTICA_VM_BINARY names another binary")
    return vm_command()




def compile_fixture(source, tmp_path):
    return compile_agc(source, tmp_path / (source.stem + ".agcb"))


def start(adopt, vm, bytecode, mode, no_turn_cost):
    env = vm_environment({"AGENTICA_VM_TEST_NO_TURN_COST": "1" if no_turn_cost else None, "AGENTICA_SCHEDULERS": "1"})
    return adopt(Child([*vm, "--", bytecode, mode], env=env, stdin=True))


def sleep_worst(adopt, vm, bytecode, no_turn_cost):
    child = start(adopt, vm, bytecode, "sleep", no_turn_cost)
    child.close_stdin()
    try:
        line = child.next_line(WAIT_SECONDS)
        match = re.match(r"^worst ([0-9]+)$", line)
        assert match is not None, "unexpected output: %r" % line
        return int(match.group(1))
    finally:
        child.stop()  # no VM may run during the next measurement


def echo_worst(adopt, vm, bytecode, no_turn_cost):
    child = start(adopt, vm, bytecode, "echo", no_turn_cost)
    worst = 0
    try:
        for round_number in range(20):
            if worst > LIMIT_MS:
                break
            assert child.next_line(WAIT_SECONDS) == "ready", "the program did not say ready"
            sent = time.monotonic()
            child.process.stdin.write(("line %d\n" % round_number).encode())
            child.process.stdin.flush()
            reply = child.next_line(WAIT_SECONDS)
            delay = (time.monotonic() - sent) * 1000
            assert reply == "echo line %d" % round_number
            worst = max(worst, delay)
        return worst
    finally:
        child.stop()  # no VM may run during the next measurement


def concurrently(*calls):
    """Run the calls in threads at once; return their results in order, or raise the first exception."""
    outcomes = [None] * len(calls)

    def work(index, call):
        try:
            outcomes[index] = ("returned", call())
        except BaseException as problem:
            outcomes[index] = ("raised", problem)

    threads = [threading.Thread(target=work, args=(index, call), daemon=True) for index, call in enumerate(calls)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    for kind, value in outcomes:
        if kind == "raised":
            raise value
    return [value for _, value in outcomes]


def test_a_sleeping_task_and_a_stdin_reader_wake_on_time_next_to_cpu_sort_and_concat_tasks(tmp_path, adopt, vm_cmd):
    bytecode = compile_fixture(LATENCY, tmp_path)
    sleep = sleep_worst(adopt, vm_cmd, bytecode, False)
    echo = echo_worst(adopt, vm_cmd, bytecode, False)
    print("VM latency with turn costs: sleep wake %s ms, stdin echo %s ms (limit %s ms)" % (
        sleep, round(echo), LIMIT_MS))
    assert sleep < LIMIT_MS, "sleep wake %s ms" % sleep
    assert echo < LIMIT_MS, "stdin echo %s ms" % echo


def test_a_task_reading_in_a_loop_lets_main_close_the_handle_and_the_run_ends(tmp_path, adopt, vm_cmd):
    work = tmp_path / "agentica-latency-work"
    work.mkdir()
    bytecode = compile_fixture(CLOSE_READER, tmp_path)
    child = adopt(Child([*vm_cmd, "--", bytecode, work], env=vm_environment(), stdin=True))
    child.close_stdin()
    assert child.wait(WAIT_SECONDS) == 0, "the VM did not end"
    assert child.stdout_text() == "ok()\ntrue\n"


def test_without_turn_costs_the_same_check_fails(tmp_path, adopt, vm_cmd):
    bytecode = compile_fixture(LATENCY, tmp_path)
    sleep, echo = concurrently(lambda: sleep_worst(adopt, vm_cmd, bytecode, True),
                               lambda: echo_worst(adopt, vm_cmd, bytecode, True))
    print("VM latency without turn costs: sleep wake %s ms, stdin echo %s ms" % (sleep, round(echo)))
    assert sleep > LIMIT_MS, "sleep wake %s ms" % sleep
    assert echo > LIMIT_MS, "stdin echo %s ms" % echo
