"""The per-test time limit of tests/agentica_test.py (like pytest-timeout) and its AGENTICA_TEST_TIMEOUT_SCALE knob."""
import os

from tests.agentica_test import PYTHON, ROOT, TestCase, run, timeout

HANGING_MODULE = """\
import time

from tests.agentica_test import TestCase, timeout


class Hangs(TestCase):
    @timeout(1)
    def test_a_test_that_hangs(self):
        time.sleep(60)

    def test_the_next_test_still_runs(self):
        pass
"""


class TimeoutGuardTest(TestCase):
    # The guard stays armed around the hanging test itself, so a stuck guard fails this test by its own limit.
    @timeout(60)
    def test_a_hanging_test_fails_by_name_with_the_scaled_limit_and_the_next_test_runs(self):
        directory = self.make_suite({"hanging_module.py": HANGING_MODULE})
        environment = dict(os.environ, PYTHONPATH=os.pathsep.join([str(ROOT), str(directory)]),
                           AGENTICA_TEST_TIMEOUT_SCALE="2", AGENTICA_TEST_SLOW="")
        result = run([PYTHON, "-m", "unittest", "hanging_module"], cwd=ROOT, env=environment, timeout=40)
        self.assertEqual(result.code, 1, result.stderr)
        self.assertIn("hanging_module.Hangs.test_a_test_that_hangs took longer than 2 s", result.stderr)
        self.assertIn("Ran 2 tests", result.stderr)
        self.assertIn("FAILED (failures=1)", result.stderr)
