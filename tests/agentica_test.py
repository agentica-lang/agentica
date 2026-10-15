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
import sys
import tempfile
import unittest
from collections import namedtuple
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
FIXTURES = TESTS / "fixtures"

# The interpreter that runs the tests also runs the Python peers and is the `python3` that VM programs spawn.
PYTHON = sys.executable

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


def _method_is_slow(cls, name):
    return bool(getattr(getattr(cls, name), "agentica_slow", False) or getattr(cls, "agentica_slow", False))


class TestCase(unittest.TestCase):
    """A TestCase that honors the tiers; derive from it instead of unittest's.

    A case of the other tier is skipped before its setUp, and a class with no
    case in the running tier is skipped before its setUpClass. A class that
    defines setUpClass must call super().setUpClass() first. setUpModule and
    module-level code run in both tiers: keep them cheap.
    """

    @classmethod
    def setUpClass(cls):
        names = [name for name in dir(cls) if name.startswith(unittest.TestLoader.testMethodPrefix)]
        if not any(_method_is_slow(cls, name) == SLOW for name in names):
            raise unittest.SkipTest("no cases in this tier")

    def _is_slow(self):
        return _method_is_slow(type(self), self._testMethodName)

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

    def compile_fixture(self, source):
        """Compile a .agc file into a fresh temp dir (removed after the test) and return the bytecode path."""
        source = Path(source)
        return compile_agc(source, self.make_temp_dir() / (source.stem + ".agcb"))


def vm_binary():
    """dist/agentica-vm, or AGENTICA_VM_BINARY like the Racket tests. `make test` builds it first."""
    override = os.environ.get("AGENTICA_VM_BINARY")
    path = (ROOT / override) if override else ROOT / "dist" / "agentica-vm"
    if not path.is_file():
        message = "the VM is not built (%s): run make vm" % path
        # CI fails when a tool is missing; a local run skips (AGENTS.md). AGENTICA_REQUIRE_VM is the flag of the Racket tests.
        if os.environ.get("CI") or os.environ.get("AGENTICA_REQUIRE_VM"):
            raise RuntimeError(message)
        raise unittest.SkipTest(message)
    return path


def cli():
    """The command that runs Agentica programs: the executable of AGENTICA_TEST_EXECUTABLE, else the Racket front end."""
    executable = os.environ.get("AGENTICA_TEST_EXECUTABLE")
    return [executable] if executable else ["racket", str(ROOT / "src" / "main.rkt")]


def run(argv, stdin=None, timeout=RUN_TIMEOUT, cwd=None, env=None):
    """Run a command and return Result(code, stdout, stderr), both streams as text.

    The command runs in its own session so that the whole process group can be
    killed (a VM may have children). The group is killed when the command
    outlives `timeout` seconds (AssertionError with what it had printed, so a
    hang fails one test) and on any interruption of the wait, Ctrl-C included:
    the new session no longer receives the terminal's SIGINT by itself.
    """
    process = subprocess.Popen(
        [str(part) for part in argv],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=cwd, env=env, start_new_session=True)
    data = stdin.encode() if isinstance(stdin, str) else stdin
    try:
        out, err = process.communicate(data, timeout=timeout)
    except subprocess.TimeoutExpired:
        out, err = _kill_and_collect(process)
        raise AssertionError("timed out after %ss: %s\nstdout: %s\nstderr: %s" % (
            timeout, argv, out.decode(errors="replace"), err.decode(errors="replace")))
    except BaseException:
        _kill_and_collect(process)
        raise
    return Result(process.returncode, out.decode(errors="replace"), err.decode(errors="replace"))


def _kill_and_collect(process):
    # Called before the process is reaped, so its pid (the group id) cannot belong to anyone else yet.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return process.communicate()


def compile_agc(source, output):
    """Compile a .agc file to bytecode with the CLI; raises AssertionError if that fails."""
    result = run(cli() + ["compile", source, "-o", output])
    if result.code != 0:
        raise AssertionError("compile failed for %s:\n%s" % (source, result.stderr))
    return Path(output)


def run_vm(bytecode, *flags, args=(), **options):
    """Run `dist/agentica-vm [flags] -- bytecode [args]`; options go to run()."""
    return run([vm_binary(), *flags, "--", bytecode, *args], **options)
