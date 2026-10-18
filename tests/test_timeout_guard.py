"""The per-test time limit of tests/agentica_test.py (like pytest-timeout) and its AGENTICA_TEST_TIMEOUT_SCALE knob."""
import os
import signal

import pytest

from tests.agentica_test import PYTHON, ROOT, run, timeout, write_files

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


# The guard stays armed around the hanging test itself, so a stuck guard fails this test by its own limit.
@timeout(60)
def test_a_hanging_test_fails_by_name_with_the_scaled_limit_and_the_next_test_runs(tmp_path):
    write_files(tmp_path, {"hanging_module.py": HANGING_MODULE})
    directory = tmp_path
    environment = dict(os.environ, PYTHONPATH=os.pathsep.join([str(ROOT), str(directory)]),
                       AGENTICA_TEST_TIMEOUT_SCALE="2", AGENTICA_TEST_SLOW="")
    result = run([PYTHON, "-m", "unittest", "hanging_module"], cwd=ROOT, env=environment, timeout=40)
    assert result.code == 1, result.stderr
    assert "hanging_module.Hangs.test_a_test_that_hangs took longer than 2 s" in result.stderr
    assert "Ran 2 tests" in result.stderr
    assert "FAILED (failures=1)" in result.stderr


@timeout(60)
def test_native_pytest_tests_keep_the_per_test_timeout(tmp_path):
    if not hasattr(signal, "setitimer"):
        pytest.skip("per-test alarms are only available on POSIX")
    write_files(tmp_path, {"test_timeout_probe.py": PYTEST_HANGING_MODULE})
    directory = tmp_path
    result = run(
        [PYTHON, "-m", "pytest", "-q", "-c", ROOT / "pyproject.toml",
         "-p", "tests.conftest", str(directory / "test_timeout_probe.py")],
        cwd=ROOT,
        env=dict(os.environ, PYTHONPATH=str(ROOT), AGENTICA_TEST_TIMEOUT_SCALE="2"),
        timeout=40,
    )
    assert result.code == 1, result.stdout + result.stderr
    assert "test_a_native_pytest_case_that_hangs took longer than 2 s" in result.stdout + result.stderr
