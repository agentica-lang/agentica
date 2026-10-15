"""Shared helpers of the Python unittest tests (standard library only).

A test module is tests/test_<area>.py. `make test` runs each module in its own
process (`python3 -m unittest tests.test_<area>` from the repository root, so
this module imports as `tests.agentica_test`). Keep this file small: add a
helper here only when a second test module needs it.
"""
import os
import shutil
import signal
import subprocess
import tempfile
import unittest
from collections import namedtuple
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
FIXTURES = TESTS / "fixtures"

# Same limit as run-timeout in tests/vm-diff-common.rkt.
RUN_TIMEOUT = 60

# `make test-slow` sets this. The two tiers are exclusive, like the rackunit
# `test` and `slow` submodules: with the flag only @slow cases run, without it
# the @slow cases are skipped.
SLOW = os.environ.get("AGENTICA_TEST_SLOW", "") not in ("", "0")

Result = namedtuple("Result", "code stdout stderr")


def slow(item):
    """Mark a test method or a TestCase class as slow-tier."""
    item.agentica_slow = True
    return item


class TestCase(unittest.TestCase):
    """A TestCase that honors the tiers; derive from it instead of unittest's."""

    def _is_slow(self):
        method = getattr(self, self._testMethodName)
        return getattr(method, "agentica_slow", False) or getattr(type(self), "agentica_slow", False)

    def run(self, result=None):
        # Skipping before setUp keeps the other tier's fixtures from being built.
        if result is not None and self._is_slow() != SLOW:
            result.startTest(self)
            result.addSkip(self, "slow tier only" if self._is_slow() else "fast tier only")
            result.stopTest(self)
            return result
        return super().run(result)

    def make_temp_dir(self, prefix="agentica-"):
        """A fresh directory, removed when the test ends (also after a failure)."""
        path = Path(tempfile.mkdtemp(prefix=prefix))
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path


def vm_binary():
    """dist/agentica-vm, or AGENTICA_VM_BINARY like the Racket tests. `make test` builds it first."""
    override = os.environ.get("AGENTICA_VM_BINARY")
    path = (ROOT / override) if override else ROOT / "dist" / "agentica-vm"
    if not path.is_file():
        raise RuntimeError("the VM is not built (%s): run make vm" % path)
    return path


def cli():
    """The command that runs Agentica programs: the executable of AGENTICA_TEST_EXECUTABLE, else the Racket front end."""
    executable = os.environ.get("AGENTICA_TEST_EXECUTABLE")
    return [executable] if executable else ["racket", str(ROOT / "src" / "main.rkt")]


def run(argv, input=None, timeout=RUN_TIMEOUT, cwd=None, env=None):
    """Run a command and return Result(code, stdout, stderr), both streams as text.

    A command that outlives `timeout` seconds is killed with its whole process
    group (a VM may have children) and the call raises AssertionError with
    what it had printed, so a hang fails one test instead of the whole run.
    """
    process = subprocess.Popen(
        [str(part) for part in argv],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=cwd, env=env, start_new_session=True)
    data = input.encode() if isinstance(input, str) else input
    try:
        out, err = process.communicate(data, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        out, err = process.communicate()
        raise AssertionError("timed out after %ss: %s\nstdout: %s\nstderr: %s" % (
            timeout, argv, out.decode(errors="replace"), err.decode(errors="replace")))
    return Result(process.returncode, out.decode(errors="replace"), err.decode(errors="replace"))


def compile_agc(source, output):
    """Compile a .agc file to bytecode with the CLI; raises AssertionError if that fails."""
    result = run(cli() + ["compile", source, "-o", output])
    if result.code != 0:
        raise AssertionError("compile failed for %s:\n%s" % (source, result.stderr))
    return Path(output)


def run_vm(bytecode, *flags, **options):
    """Run `dist/agentica-vm [flags] -- bytecode`."""
    return run([vm_binary(), *flags, "--", bytecode], **options)
