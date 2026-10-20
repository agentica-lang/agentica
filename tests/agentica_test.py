"""Shared helpers for pytest modules and remaining unittest.TestCase modules.

A test module is tests/test_<area>.py. Make runs each selected module in its own
pytest process; legacy TestCase modules still import this file as
`tests.agentica_test`. Keep it small: add a helper only when another module
needs it.
"""
import faulthandler
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

# The platform the program under test was built for: the host, or "windows" when a Linux or macOS host runs a Windows
# build through Wine (`make windows-docker-check` sets AGENTICA_TEST_TARGET_OS). A few behaviours belong to the build,
# not to the machine that starts it, so a test reads this instead of os.name.
TARGET_OS = os.environ.get("AGENTICA_TEST_TARGET_OS") or ("windows" if os.name == "nt" else sys.platform)

# A Windows build run under Wine (`make windows-docker-check` sets AGENTICA_TEST_WINE). Wine gives a child two inherited
# descriptors of one pipe as two unrelated objects, which no Windows call can match, so a test that needs the VM to see
# that stdout and stderr are one pipe (`2>&1`) waits for the native Windows job.
UNDER_WINE = os.environ.get("AGENTICA_TEST_WINE") == "1"

# `make test-multicore` runs whole modules (TCP, TLS, HTTP) on several schedulers: AGENTICA_VM_TEST_MODULE_SCHEDULERS=N
# makes every VM started with vm_environment() run on N schedulers under the test switch. A case whose program still
# uses a builtin that several schedulers refuse (Process, Duplex) calls one_scheduler() first.
TEST_SCHEDULERS = os.environ.get("AGENTICA_VM_TEST_MODULE_SCHEDULERS", "").strip()


def one_scheduler():
    """Skip the case on a several-scheduler run of its module (TEST_SCHEDULERS): its program needs one scheduler."""
    if TEST_SCHEDULERS:
        raise unittest.SkipTest("needs one scheduler (AGENTICA_VM_TEST_MODULE_SCHEDULERS)")



def _timeout_scale():
    raw = os.environ.get("AGENTICA_TEST_TIMEOUT_SCALE", "").strip()
    if not raw:
        return 1
    try:
        scale = float(raw)
    except ValueError:
        scale = 0
    if not scale > 0 or scale == float("inf"):
        raise SystemExit("AGENTICA_TEST_TIMEOUT_SCALE must be a positive number, got %r" % raw)
    return scale


# Slow runners (a capped CPU frequency, a busy shared host) need longer deadlines. CI sets this to stretch every
# deadline that a correct run must beat; read it once, here, and wrap such a literal in scaled(). A deadline that a
# test expects to expire, and a limit that measures the product, stay unscaled.
TIMEOUT_SCALE = _timeout_scale()


def scaled(value):
    """`value` (seconds or milliseconds) times AGENTICA_TEST_TIMEOUT_SCALE; an int stays an int."""
    result = value * TIMEOUT_SCALE
    return max(1, round(result)) if isinstance(value, int) else result


# The limit of one test (setUp, the body and the cleanups), like pytest-timeout: fast tests, then @slow ones. A test
# that legitimately takes longer says so with @timeout(seconds). The limits are scaled like every other deadline.
TEST_TIMEOUT = 120
SLOW_TEST_TIMEOUT = 900
# Extra time before the backstop kills the whole module process: the signal handler cannot run while the test sits
# in C code, so faulthandler dumps the stacks of every thread and exits from its own thread.
BACKSTOP_GRACE = 30


def timeout(seconds):
    """Give a test method or a TestCase class its own limit in seconds (scaled), replacing the tier's default."""
    def mark(item):
        item.agentica_timeout = seconds
        return item
    return mark


class TestTimeout(AssertionError):
    """A test that outlived its limit: unittest reports that test as failed and goes on with the next."""

    __test__ = False


# The time limit of a run, as in the VM golden harness (tests/vm_diff_support.py).
RUN_TIMEOUT = scaled(60)

# `make test-slow` sets this. The two tiers are exclusive: with the flag only @slow cases run, without it
# the @slow cases are skipped.
SLOW = os.environ.get("AGENTICA_TEST_SLOW", "") not in ("", "0")

# Time limit of one line or one exit of a Child.
WAIT_SECONDS = scaled(30)

def _terminate(signum, frame):
    raise KeyboardInterrupt


# Children live in their own sessions, so a SIGTERM or SIGHUP to the test process (timeout, a closing terminal) does not
# reach them. Turning those signals into KeyboardInterrupt runs the cleanups like Ctrl-C does, which stop the children.
if threading.current_thread() is threading.main_thread():
    signal.signal(signal.SIGTERM, _terminate)
    if hasattr(signal, "SIGHUP"):
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

    def _time_limit(self):
        """Seconds that this test may take: its @timeout, else its class's, else the tier's default; all scaled."""
        method = getattr(type(self), self._testMethodName)
        seconds = getattr(method, "agentica_timeout", None) or getattr(type(self), "agentica_timeout", None)
        return scaled(seconds or (SLOW_TEST_TIMEOUT if self._is_slow() else TEST_TIMEOUT))

    def _arm_timeout(self):
        """Start the per-test limit; return the function that stops it. SIGALRM and its timer exist only in the main
        thread of a POSIX process: elsewhere the test runs unguarded and the module limit of make is the net."""
        if threading.current_thread() is not threading.main_thread() or not hasattr(signal, "setitimer"):
            return lambda: None
        limit = self._time_limit()

        def expired(signum, frame):
            raise TestTimeout("%s took longer than %s s (AGENTICA_TEST_TIMEOUT_SCALE=%s)" % (
                self.id(), limit, TIMEOUT_SCALE))

        previous = signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, limit)
        faulthandler.dump_traceback_later(limit + BACKSTOP_GRACE, exit=True)

        def disarm():
            faulthandler.cancel_dump_traceback_later()
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
        return disarm

    def run(self, result=None):
        # Skipping before setUp keeps the other tier's fixtures from being built.
        if result is not None and self._is_slow() != SLOW:
            result.startTest(self)
            result.addSkip(self, "slow tier only" if self._is_slow() else "fast tier only")
            result.stopTest(self)
            return result
        disarm = self._arm_timeout()
        try:
            return super().run(result)
        except KeyboardInterrupt:
            # unittest skips the cleanups on Ctrl-C; they stop the children and remove the temp dirs.
            self.doCleanups()
            raise
        finally:
            disarm()

    def make_temp_dir(self, prefix="agentica-"):
        """A fresh directory, removed when the test ends (also after a failure)."""
        path = Path(tempfile.mkdtemp(prefix=prefix)).resolve()
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path

    def make_suite(self, files, prefix="agentica-"):
        """A resolved temp dir holding the given files (name -> text); removed when the test ends."""
        directory = self.make_temp_dir(prefix).resolve()
        write_files(directory, files)
        return directory

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


def agentica_version():
    """The Agentica version: the one line of the VERSION file."""
    return (ROOT / "VERSION").read_text(encoding="utf-8").strip()


def binary():
    """The product, or the executable wrapper named by AGENTICA_TEST_EXECUTABLE."""
    override = os.environ.get("AGENTICA_TEST_EXECUTABLE")
    if override:
        path = Path(override)
        if not path.is_absolute():
            path = ROOT / path
    else:
        path = ROOT / "dist" / ("agentica.exe" if os.name == "nt" else "agentica")
    if not path.is_file():
        _missing("the binary is not built (%s): run make" % path)
    return path


def vm_binary():
    """The binary whose `run` command runs the programs: dist/agentica, or AGENTICA_VM_BINARY for another build of it
    (the GC stress build, the vendored link, a sanitizer build). `make test` builds dist/agentica first."""
    override = os.environ.get("AGENTICA_VM_BINARY")
    if not override:
        return binary()
    path = ROOT / override
    if not path.is_file():
        _missing("the binary is not built (%s): run make" % path)
    return path


def vm_command():
    """The words that run a compiled program: `agentica run`, followed by the flags, `--`, the file and its arguments."""
    return [vm_binary(), "run"]


def _missing(message):
    """CI fails when a tool is missing; a local run skips (AGENTS.md). AGENTICA_REQUIRE_VM fails the same way."""
    if os.environ.get("CI") or os.environ.get("AGENTICA_REQUIRE_VM"):
        raise RuntimeError(message)
    raise unittest.SkipTest(message)


def require(condition, message):
    """Like tool() for a need that is not an executable (a Python module or version): a skip locally, a failure in CI."""
    if not condition:
        _missing(message)


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
    """The command that runs Agentica programs: the executable of AGENTICA_TEST_EXECUTABLE, else dist/agentica."""
    executable = os.environ.get("AGENTICA_TEST_EXECUTABLE")
    return [executable] if executable else [str(binary())]


# The front end of the binary, as the bootstrap leaves it. `make` builds it.
STAGE2 = ROOT / "build" / "stage" / "stage2.agcb"


def front_end_command(self_path, *words):
    """The command that runs the front end of the binary as an ordinary program, with `self_path` as the binary it
    starts again for `agentica test`: a test can put a script there and see what the driver does with the answers.

    Without --front-end the program has no hand-off and no embedded std/ sources: it reads them from stdlib/, and it
    needs --allow-run because `test` starts processes (the binary does not: its front end has it)."""
    require(STAGE2.is_file(), "the front end is not built (%s): run make" % STAGE2)
    return [*vm_command(), "--allow-run", "--", STAGE2, "--version", agentica_version(), "--stdlib", ROOT / "stdlib",
            "--self", self_path, "--", *words]


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


def _kill_process_tree(process: subprocess.Popen[bytes]) -> None:
    # Called before the process is reaped, so its pid (the group id) cannot belong to anyone else yet.
    try:
        if os.name == "nt":
            taskkill = Path(os.environ["SystemRoot"]) / "System32" / "taskkill.exe"
            killed = subprocess.run(
                [str(taskkill), "/PID", str(process.pid), "/T", "/F"],
                capture_output=True, timeout=30, check=False,
            )
            if killed.returncode and process.poll() is None:
                raise AssertionError(killed.stderr.decode(errors="replace"))
        else:
            os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS answers EPERM, not ESRCH, for a group whose only process exited a moment ago and is not reaped yet.
        if process.poll() is None:
            raise


def _kill_and_collect(process):
    _kill_process_tree(process)
    return process.communicate()


def compile_agc(source, output):
    """Compile a .agc file to bytecode with the CLI; raises AssertionError if that fails."""
    result = run(cli() + ["compile", source, "-o", output])
    if result.code != 0:
        raise AssertionError("compile failed for %s:\n%s" % (source, result.stderr))
    return Path(output)


def compile_text(text, name, tmp_path):
    """Write text as name.agc under tmp_path and compile it; return the bytecode path."""
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, tmp_path / (name + ".agcb"))


def run_vm(bytecode, *flags, args=(), **options):
    """Run `dist/agentica run [flags] -- bytecode [args]`; options go to run()."""
    return run([*vm_command(), *flags, "--", bytecode, *args], **options)


# The tests do not read these from their own environment: a trace or a trust store set by the caller would change
# the output of the programs they compare.
_VM_UNSET = ("AGENTICA_VM_TRACE", "AGENTICA_VM_TRACE_FILE", "AGENTICA_FLUSH_TIMEOUT_MS", "AGENTICA_SCHEDULERS",
             "SSL_CERT_FILE", "SSL_CERT_DIR")


def vm_environment(extra=None):
    """The environment of a VM run: UTF-8 locale, the caller's trace and trust settings removed.

    `extra` maps names to values; a value of None removes the name.
    """
    env = {k: v for k, v in os.environ.items() if k not in _VM_UNSET}
    env.update(LC_ALL="C.UTF-8", LANG="C.UTF-8")
    if TEST_SCHEDULERS:
        env.update(AGENTICA_SCHEDULERS=TEST_SCHEDULERS, AGENTICA_VM_TEST_MULTICORE="1")
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

    def __init__(self, argv, env=None, cwd=None, stdin=False, capture_stderr=False, read_stdout=True, creationflags=0):
        """stdin=True gives a pipe (close_stdin() ends it), else /dev/null; stderr is the test's own unless captured.

        read_stdout=False leaves the stdout pipe unread, for tests of a full pipe: the test reads process.stdout itself.
        creationflags are the Windows process creation flags (CREATE_NEW_PROCESS_GROUP, to send it Ctrl+Break).
        """
        self.argv = [str(part) for part in argv]
        self.process = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE if capture_stderr else None, env=env, cwd=cwd, start_new_session=True,
            creationflags=creationflags)
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

    def stdout_text(self):
        """The stdout lines that next_line() has not returned, as text (call after wait(), when the reader has ended)."""
        lines = []
        while True:
            try:
                line = self._lines.get_nowait()
            except queue.Empty:
                break
            if line is None:
                break
            lines.append(line)
        return "".join(lines)

    def stderr_text(self):
        """What the child wrote to stderr (capture_stderr=True; call after wait())."""
        return "".join(self._stderr)

    def stop(self):
        if self.process.poll() is None:
            _kill_process_tree(self.process)
        self.process.wait()
        for thread in self._threads:
            thread.join(5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None:
                stream.close()


def start_vm(bytecode, *args, flags=(), env=None, **options):
    """Start `dist/agentica run [flags] -- bytecode [args]` as a Child (stderr captured), with vm_environment()."""
    return Child([*vm_command(), *flags, "--", bytecode, *args], env=vm_environment(env), capture_stderr=True, **options)


def output_lines(text):
    """The lines of a peer's or program's output; only \\n separates them (splitlines also splits on other control characters)."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def write_files(directory, files):
    """Write each name -> text of `files` into `directory`, for a text that must name the directory first."""
    for name, text in files.items():
        (Path(directory) / name).write_text(text, encoding="utf-8")


def report_cases(report):
    """The scenarios of an `agentica test --json` report, in file order."""
    return [scenario for file in report["files"] for scenario in file["scenarios"]]


def check_lines(text, expected, message):
    """One output line per expectation: a string is equal, ("prefix", text) is a prefix."""
    lines = output_lines(text)
    assert len(lines) == len(expected), message + "\n" + text
    for line, want in zip(lines, expected):
        if isinstance(want, str):
            assert line == want, message
        else:
            assert line.startswith(want[1]), "%s: %r should start with %r" % (message, line, want[1])


def _windows_process_alive(number):
    import ctypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    # SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION. A process that ended but whose handle someone still holds can be
    # opened, so the wait on its handle (signaled at the end), not the open, tells whether it is alive.
    handle = kernel32.OpenProcess(0x00100000 | 0x1000, False, number)
    if not handle:
        # ERROR_ACCESS_DENIED (5): it exists and belongs to someone else, like the POSIX PermissionError branch.
        return ctypes.get_last_error() == 5
    try:
        return kernel32.WaitForSingleObject(handle, 0) == 0x102  # WAIT_TIMEOUT
    finally:
        kernel32.CloseHandle(handle)


def _zombie(number):
    """True for a process that ended but is not reaped yet. Linux reads /proc; other systems ask ps."""
    try:
        with open("/proc/%d/stat" % number) as stat:
            return stat.read().rsplit(") ", 1)[-1][:1] == "Z"
    except OSError:
        pass
    if os.path.isdir("/proc/self"):
        return False  # /proc exists and has no entry: the process is gone
    shown = subprocess.run(["ps", "-o", "stat=", "-p", str(number)], capture_output=True, text=True, check=False)
    return shown.stdout.strip()[:1] == "Z"


def process_alive(pid):
    """True while the process exists and is not a zombie (Windows: until it ends)."""
    try:
        number = int(pid)
    except ValueError:
        raise AssertionError("not a process id: %r" % (pid,)) from None
    if os.name == "nt":
        return _windows_process_alive(number)
    try:
        os.kill(number, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass  # it exists and belongs to someone else
    return not _zombie(number)


def agc_literal(text):
    """`text` as an Agentica string literal: backslash, quote and `#` (which would start an interpolation) escaped.

    Only the lexer's escape set is handled (those three, newline, CR and tab): use it for paths and printable
    arguments, not for arbitrary bytes or other control characters.
    """
    escapes = {"\\": "\\\\", '"': '\\"', "#": "\\#", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return '"' + "".join(escapes.get(c, c) for c in str(text)) + '"'


def kill_process(pid):
    """Last resort at the end of a test, so a failure leaves no process behind."""
    if not process_alive(pid):
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True, check=False)
        return
    try:
        os.kill(int(pid), signal.SIGKILL)
    except ProcessLookupError:
        pass  # it ended between the check and the signal


def wait_until(predicate, timeout=WAIT_SECONDS, interval=0.05):
    """Poll `predicate` until it is true (returns True) or `timeout` seconds pass (returns False)."""
    deadline = time.monotonic() + timeout
    while True:
        if predicate():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(interval)
