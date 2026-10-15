"""Shared helpers of the Python unittest tests (standard library only).

A test module is tests/test_<area>.py. `make test` runs each module in its own
process (`python3 -m unittest tests.test_<area>` from the repository root, so
this module imports as `tests.agentica_test`). Keep this file small: add a
helper here only when a second test module needs it.
"""
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
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

# Time limit of one line or one exit of a Child.
WAIT_SECONDS = 30

def _terminate(signum, frame):
    raise KeyboardInterrupt


# Children live in their own sessions, so a SIGTERM or SIGHUP to the test process (timeout, a closing terminal) does not
# reach them. Turning those signals into KeyboardInterrupt runs the cleanups like Ctrl-C does, which stop the children.
if threading.current_thread() is threading.main_thread():
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGHUP, _terminate)

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
        try:
            return super().run(result)
        except KeyboardInterrupt:
            # unittest skips the cleanups on Ctrl-C; they stop the children and remove the temp dirs.
            self.doCleanups()
            raise

    def make_temp_dir(self, prefix="agentica-"):
        """A fresh directory, removed when the test ends (also after a failure)."""
        path = Path(tempfile.mkdtemp(prefix=prefix))
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path

    def adopt(self, child):
        """Stop a Child when the test ends (also after a failure or Ctrl-C); return it."""
        self.addCleanup(child.stop)
        return child

    def compile_text(self, text, name="program"):
        """Compile Agentica source text into a temp dir (one per test, removed after it); return the bytecode path."""
        if not hasattr(self, "_work"):
            self._work = self.make_temp_dir()
        source = self._work / (name + ".agc")
        source.write_text(text, encoding="utf-8")
        return compile_agc(source, self._work / (name + ".agcb"))

    def compile_fixture(self, source):
        """Compile a .agc file into a fresh temp dir (removed after the test) and return the bytecode path."""
        source = Path(source)
        return compile_agc(source, self.make_temp_dir() / (source.stem + ".agcb"))


def vm_binary():
    """dist/agentica-vm, or AGENTICA_VM_BINARY like the Racket tests. `make test` builds it first."""
    override = os.environ.get("AGENTICA_VM_BINARY")
    path = (ROOT / override) if override else ROOT / "dist" / "agentica-vm"
    if not path.is_file():
        _missing("the VM is not built (%s): run make vm" % path)
    return path


def _missing(message):
    """CI fails when a tool is missing; a local run skips (AGENTS.md). AGENTICA_REQUIRE_VM is the flag of the Racket tests."""
    if os.environ.get("CI") or os.environ.get("AGENTICA_REQUIRE_VM"):
        raise RuntimeError(message)
    raise unittest.SkipTest(message)


def optional_tool(name):
    """Like tool(), but None when it is missing locally (a part of a test is left out); still a failure in CI."""
    try:
        return tool(name)
    except unittest.SkipTest:
        return None


def tool(name):
    """The path of an executable that a test needs (node), or a skip (a failure in CI)."""
    path = shutil.which(name)
    if path is None:
        _missing("%s is required (not found on PATH)" % name)
    return path


def cli():
    """The command that runs Agentica programs: the executable of AGENTICA_TEST_EXECUTABLE, else the Racket front end."""
    executable = os.environ.get("AGENTICA_TEST_EXECUTABLE")
    return [executable] if executable else ["racket", str(ROOT / "src" / "main.rkt")]


def run(argv, stdin=None, timeout=RUN_TIMEOUT, cwd=None, env=None, stdout_to=None, stderr_to=None):
    """Run a command and return Result(code, stdout, stderr), both streams as text.

    The command runs in its own session so that the whole process group can be
    killed (a VM may have children). The group is killed when the command
    outlives `timeout` seconds (AssertionError with what it had printed, so a
    hang fails one test) and on any interruption of the wait, Ctrl-C included:
    the new session no longer receives the terminal's SIGINT by itself.
    """
    # A stream sent to a file (stdout_to, stderr_to: a path such as /dev/full, opened for writing) is not captured: "".
    files = [open(path, "wb") if path is not None else None for path in (stdout_to, stderr_to)]
    try:
        process = subprocess.Popen(
            [str(part) for part in argv],
            stdin=subprocess.PIPE, stdout=files[0] or subprocess.PIPE, stderr=files[1] or subprocess.PIPE,
            cwd=cwd, env=env, start_new_session=True)
        data = stdin.encode() if isinstance(stdin, str) else stdin
        try:
            out, err = process.communicate(data, timeout=timeout)
        except subprocess.TimeoutExpired:
            out, err = _kill_and_collect(process)
            raise AssertionError("timed out after %ss: %s\nstdout: %s\nstderr: %s" % (
                timeout, argv, (out or b"").decode(errors="replace"), (err or b"").decode(errors="replace")))
        except BaseException:
            _kill_and_collect(process)
            raise
    finally:
        for file in files:
            if file is not None:
                file.close()
    return Result(process.returncode, (out or b"").decode(errors="replace"), (err or b"").decode(errors="replace"))


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


# The tests do not read these from their own environment: a trace or a trust store set by the caller would change
# the output of the programs they compare.
_VM_UNSET = ("AGENTICA_VM_TRACE", "AGENTICA_VM_TRACE_FILE", "AGENTICA_FLUSH_TIMEOUT_MS", "SSL_CERT_FILE", "SSL_CERT_DIR")


def vm_environment(extra=None):
    """The environment of a VM run: UTF-8 locale, the caller's trace and trust settings removed.

    `extra` maps names to values; a value of None removes the name.
    """
    env = {k: v for k, v in os.environ.items() if k not in _VM_UNSET}
    env.update(LC_ALL="C.UTF-8", LANG="C.UTF-8")
    env.pop("LC_MESSAGES", None)
    for key, value in (extra or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = str(value)
    return env


class Child:
    """A process that runs beside the test: a peer or a VM that is read line by line.

    It has its own session, so stop() kills its process group (the child and what it spawned) while the child is still alive;
    a group left by a child that already exited is not reached.
    Hand it to TestCase.adopt(), so that a failed assertion, Ctrl-C or SIGTERM
    leaves nothing behind. stdout is read by a thread, so
    next_line() has a time limit and a child that exits is reported at once.
    """

    def __init__(self, argv, env=None, cwd=None, stdin=False, capture_stderr=False, read_stdout=True):
        """stdin=True gives a pipe (close_stdin() ends it), else /dev/null; stderr is the test's own unless captured.

        read_stdout=False leaves the stdout pipe unread, for tests of a full pipe: the test reads process.stdout itself.
        """
        self.argv = [str(part) for part in argv]
        self.process = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE if capture_stderr else None, env=env, cwd=cwd, start_new_session=True)
        self._lines = queue.Queue()
        self._error_lines = queue.Queue()
        self._stderr = []
        self._threads = [threading.Thread(target=self._read_stdout, daemon=True)] if read_stdout else []
        if capture_stderr:
            self._threads.append(threading.Thread(target=self._read_stderr, daemon=True))
        for thread in self._threads:
            thread.start()

    def _read_stdout(self):
        for raw in iter(self.process.stdout.readline, b""):
            self._lines.put(raw.decode(errors="replace"))
        self._lines.put(None)  # end of output: a child that died at start must not make next_line wait

    def _read_stderr(self):
        for raw in iter(self.process.stderr.readline, b""):
            line = raw.decode(errors="replace")
            self._stderr.append(line)
            self._error_lines.put(line)

    def next_stderr_line(self, timeout=WAIT_SECONDS):
        """The next line of captured stderr without its newline; AssertionError if none comes in time."""
        try:
            return self._error_lines.get(timeout=timeout).rstrip("\n")
        except queue.Empty:
            raise AssertionError("no stderr line within %s s from %s" % (timeout, self.argv))

    def next_line(self, timeout=WAIT_SECONDS):
        """The next line of stdout without its newline; AssertionError if none comes in time or the output ended."""
        try:
            line = self._lines.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError("no line within %s s from %s" % (timeout, self.argv))
        if line is None:
            self._lines.put(None)
            raise AssertionError("%s ended its output (exit %r)" % (self.argv, self.process.poll()))
        return line.rstrip("\n")

    def close_stdin(self):
        self.process.stdin.close()

    def wait(self, timeout=WAIT_SECONDS):
        """Wait for the exit and return the exit code; AssertionError if it does not exit in time."""
        try:
            code = self.process.wait(timeout)
        except subprocess.TimeoutExpired:
            raise AssertionError("%s did not finish within %s s" % (self.argv, timeout))
        for thread in self._threads:
            thread.join(5)
        return code

    def stderr_text(self):
        """What the child wrote to stderr (capture_stderr=True; call after wait())."""
        return "".join(self._stderr)

    def stop(self):
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.process.wait()
        for thread in self._threads:
            thread.join(5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None:
                stream.close()


def start_vm(bytecode, *args, flags=(), env=None, **options):
    """Start `dist/agentica-vm [flags] -- bytecode [args]` as a Child (stderr captured), with vm_environment()."""
    return Child([vm_binary(), *flags, "--", bytecode, *args], env=vm_environment(env), capture_stderr=True, **options)


def output_lines(text):
    """The lines of a peer's or program's output; only \\n separates them (splitlines also splits on other control characters)."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def check_lines(case, text, expected, message):
    """One output line per expectation: a string is equal, ("prefix", text) is a prefix."""
    lines = output_lines(text)
    case.assertEqual(len(lines), len(expected), message + "\n" + text)
    for line, want in zip(lines, expected):
        if isinstance(want, str):
            case.assertEqual(line, want, message)
        else:
            case.assertTrue(line.startswith(want[1]), "%s: %r should start with %r" % (message, line, want[1]))


def process_alive(pid):
    """True while the process exists and is not a zombie (Linux /proc)."""
    try:
        with open("/proc/%d/stat" % int(pid)) as stat:
            text = stat.read()
    except OSError:
        return False
    return text.rsplit(") ", 1)[-1][:1] != "Z"


def wait_until(predicate, timeout=WAIT_SECONDS, interval=0.05):
    """Poll `predicate` until it is true (returns True) or `timeout` seconds pass (returns False)."""
    deadline = time.monotonic() + timeout
    while True:
        if predicate():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)


def processes_mentioning(text):
    """The pids whose command line contains `text` (Linux /proc)."""
    needle = os.fsencode(str(text))
    found = []
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open("/proc/%s/cmdline" % entry, "rb") as cmdline:
                    if needle in cmdline.read():
                        found.append(int(entry))
            except OSError:
                pass
    return found
