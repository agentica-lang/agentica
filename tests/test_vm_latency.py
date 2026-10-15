"""Task wake latency next to busy tasks (ported from vm-latency-test.rkt).

Run alone by `make vm-latency` (and not by `make test`, see PY_ALONE in the
Makefile), so the VMs have the CPU to themselves. fixtures/latency/latency.agc
runs a sleeping task and a stdin reader next to CPU, sort and concat tasks.
"""
import os
import re
import threading
import time
import unittest

from tests.agentica_test import FIXTURES, Child, TestCase, vm_binary, vm_environment

LIMIT_MS = 250
WAIT_SECONDS = 60
LATENCY = FIXTURES / "latency" / "latency.agc"
CLOSE_READER = FIXTURES / "latency" / "close-reader.agc"


class VmLatency(TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if os.environ.get("AGENTICA_VM") or os.environ.get("AGENTICA_VM_BINARY"):
            raise unittest.SkipTest("AGENTICA_VM or AGENTICA_VM_BINARY names another binary")
        cls.vm = vm_binary()

    def start(self, bytecode, mode, no_turn_cost):
        env = vm_environment({"AGENTICA_VM_TEST_NO_TURN_COST": "1" if no_turn_cost else None})
        return self.adopt(Child([self.vm, "--", bytecode, mode], env=env, stdin=True))

    def sleep_worst(self, bytecode, no_turn_cost):
        child = self.start(bytecode, "sleep", no_turn_cost)
        child.close_stdin()
        try:
            line = child.next_line(WAIT_SECONDS)
            match = re.match(r"^worst ([0-9]+)$", line)
            self.assertIsNotNone(match, "unexpected output: %r" % line)
            return int(match.group(1))
        finally:
            child.stop()  # no VM may run during the next measurement

    def echo_worst(self, bytecode, no_turn_cost):
        child = self.start(bytecode, "echo", no_turn_cost)
        worst = 0
        try:
            for round_number in range(20):
                if worst > LIMIT_MS:
                    break
                self.assertEqual(child.next_line(WAIT_SECONDS), "ready", "the program did not say ready")
                sent = time.monotonic()
                child.process.stdin.write(("line %d\n" % round_number).encode())
                child.process.stdin.flush()
                reply = child.next_line(WAIT_SECONDS)
                delay = (time.monotonic() - sent) * 1000
                self.assertEqual(reply, "echo line %d" % round_number)
                worst = max(worst, delay)
            return worst
        finally:
            child.stop()  # no VM may run during the next measurement

    def concurrently(self, *calls):
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

    def test_a_sleeping_task_and_a_stdin_reader_wake_on_time_next_to_cpu_sort_and_concat_tasks(self):
        bytecode = self.compile_fixture(LATENCY)
        sleep = self.sleep_worst(bytecode, False)
        echo = self.echo_worst(bytecode, False)
        print("VM latency with turn costs: sleep wake %s ms, stdin echo %s ms (limit %s ms)" % (
            sleep, round(echo), LIMIT_MS))
        self.assertLess(sleep, LIMIT_MS, "sleep wake %s ms" % sleep)
        self.assertLess(echo, LIMIT_MS, "stdin echo %s ms" % echo)

    def test_a_task_reading_in_a_loop_lets_main_close_the_handle_and_the_run_ends(self):
        work = self.make_temp_dir("agentica-latency-")
        bytecode = self.compile_fixture(CLOSE_READER)
        child = self.adopt(Child([self.vm, "--", bytecode, work], env=vm_environment(), stdin=True))
        child.close_stdin()
        self.assertEqual(child.wait(WAIT_SECONDS), 0, "the VM did not end")
        self.assertEqual(child.stdout_text(), "ok()\ntrue\n")

    def test_without_turn_costs_the_same_check_fails(self):
        bytecode = self.compile_fixture(LATENCY)
        sleep, echo = self.concurrently(lambda: self.sleep_worst(bytecode, True),
                                        lambda: self.echo_worst(bytecode, True))
        print("VM latency without turn costs: sleep wake %s ms, stdin echo %s ms" % (sleep, round(echo)))
        self.assertGreater(sleep, LIMIT_MS, "sleep wake %s ms" % sleep)
        self.assertGreater(echo, LIMIT_MS, "stdin echo %s ms" % echo)
