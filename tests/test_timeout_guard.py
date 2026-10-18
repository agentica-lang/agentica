"""The per-test time limit of tests/agentica_test.py (like pytest-timeout) and its AGENTICA_TEST_TIMEOUT_SCALE knob."""
import os
import signal

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

PYTEST_HANGING_MODULE = """\
import time

from tests.agentica_test import timeout


@timeout(1)
def test_a_native_pytest_case_that_hangs():
    time.sleep(60)
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

    @timeout(60)
    def test_native_pytest_tests_keep_the_per_test_timeout(self):
        if not hasattr(signal, "setitimer"):
            self.skipTest("per-test alarms are only available on POSIX")
        directory = self.make_suite({"test_timeout_probe.py": PYTEST_HANGING_MODULE})
        result = run(
            [PYTHON, "-m", "pytest", "-q", "-c", ROOT / "pyproject.toml",
             "-p", "tests.conftest", str(directory / "test_timeout_probe.py")],
            cwd=ROOT,
            env=dict(os.environ, PYTHONPATH=str(ROOT), AGENTICA_TEST_TIMEOUT_SCALE="2"),
            timeout=40,
        )
        self.assertEqual(result.code, 1, result.stdout + result.stderr)
        self.assertIn("test_a_native_pytest_case_that_hangs took longer than 2 s", result.stdout + result.stderr)
