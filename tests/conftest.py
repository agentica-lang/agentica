"""Shared fixtures for CLI-backed language tests."""

import faulthandler
import hashlib
import json
import os
import signal
import sys
import tempfile
import threading
from collections.abc import Callable, Mapping
from pathlib import Path

import pytest

from tests.agentica_test import (
    BACKSTOP_GRACE,
    SLOW_TEST_TIMEOUT,
    TEST_TIMEOUT,
    TIMEOUT_SCALE,
    TestCase,
    TestTimeout,
    cli,
    run,
    scaled,
    tool,
)


if os.name == "nt":
    # Python writes "\n" as "\r\n" in text mode on Windows, and the sources of these tests are meant byte for byte:
    # a "\r\n" the test wrote on purpose (the CRLF cases of the lexer) would become "\r\r\n". Linux and macOS write
    # what the test says, so Windows does too. Only Path.write_text changes (open(..., "w") keeps translating, as a
    # program of the user would see it), and only under pytest, so a module run by hand behaves as Python does.
    _write_text = Path.write_text

    def _write_text_exactly(self, data, encoding=None, errors=None, newline=None):
        return _write_text(self, data, encoding=encoding, errors=errors, newline="" if newline is None else newline)

    Path.write_text = _write_text_exactly


def pytest_configure(config):
    """Give each pytest run of a module its own temporary root.

    make test runs one pytest per module in parallel. With a shared root, every run replaces the same
    pytest-of-<user>/pytest-current link, and the cleanup of another run can fail on it at the end of the session
    (FileNotFoundError in cleanup_dead_symlinks after all cases passed). A root per user, checkout and module set keeps
    the links apart and still keeps pytest's last three numbered folders for debugging; `rm -rf` of the agc-pytest-*
    folders in the temp dir is safe. pytest reads the variable only at the first tmp_path, so setting it here is early
    enough, and child pytest runs inherit it on purpose.
    """
    if config.option.basetemp is not None or "PYTEST_DEBUG_TEMPROOT" in os.environ:
        return
    user = str(os.getuid()) if hasattr(os, "getuid") else "user"
    key = "\0".join([str(config.rootpath), *sorted(map(str, config.args))])
    root = Path(tempfile.gettempdir()) / f"agc-pytest-{user}" / hashlib.sha256(key.encode()).hexdigest()[:10]
    root.parent.mkdir(mode=0o700, exist_ok=True)
    root.mkdir(mode=0o700, exist_ok=True)
    os.environ["PYTEST_DEBUG_TEMPROOT"] = str(root)


@pytest.fixture
def adopt(request):
    """Stop a Child when the test ends (also after a failure or Ctrl-C); return it."""
    def register(child):
        request.addfinalizer(child.stop)
        return child

    return register


@pytest.fixture
def node():
    """The Node.js tool for peer servers."""
    return tool("node")


TIER_SKIP_REASON = "not selected in this test tier"
FAIL_ON_SKIP_ENV = "AGENTICA_FAIL_ON_SKIP"
_unexpected_skips: list[str] = []


def _record_skip(report) -> None:
    """Remember a skip that is not the fast/slow tier selection."""
    if not report.skipped:
        return
    longrepr = report.longrepr
    reason = str(longrepr[2]) if isinstance(longrepr, tuple) and len(longrepr) == 3 else str(longrepr)
    if TIER_SKIP_REASON not in reason:
        _unexpected_skips.append(f"{getattr(report, 'nodeid', '?')}: {reason}")


def pytest_runtest_logreport(report):
    _record_skip(report)


def pytest_collectreport(report):
    _record_skip(report)


def pytest_sessionfinish(session, exitstatus):
    """With AGENTICA_FAIL_ON_SKIP=1 (native Windows gate) a skipped case fails the run.

    A gate that skips its native cases proves nothing, so the harness sets the
    variable where every selected case must really run.
    """
    if os.environ.get(FAIL_ON_SKIP_ENV) != "1" or not _unexpected_skips:
        return
    for line in _unexpected_skips:
        print(f"{FAIL_ON_SKIP_ENV}: skipped {line}", file=sys.stderr)
    session.exitstatus = pytest.ExitCode.TESTS_FAILED


def pytest_collection_modifyitems(items):
    """Keep plain pytest functions in the same fast/slow tier as TestCase methods."""
    slow_run = os.environ.get("AGENTICA_TEST_SLOW", "") not in ("", "0")
    for item in items:
        test_class = getattr(item, "cls", None)
        if test_class is not None and issubclass(test_class, TestCase):
            continue
        is_slow = item.get_closest_marker("slow") is not None
        if is_slow != slow_run:
            item.add_marker(pytest.mark.skip(reason=TIER_SKIP_REASON))


@pytest.hookimpl(hookwrapper=True, tryfirst=True)
def pytest_runtest_protocol(item, nextitem):
    """Give native pytest tests the same scaled per-test deadline as TestCase."""
    test_class = getattr(item, "cls", None)
    if (
        (test_class is not None and issubclass(test_class, TestCase))
        or not hasattr(signal, "setitimer")
        or threading.current_thread() is not threading.main_thread()
    ):
        yield
        return

    seconds = getattr(item.obj, "agentica_timeout", None)
    if not seconds:
        is_slow = item.get_closest_marker("slow") is not None
        seconds = SLOW_TEST_TIMEOUT if is_slow else TEST_TIMEOUT
    limit = scaled(seconds)

    def expired(signum, frame):
        raise TestTimeout(
            "%s took longer than %s s (AGENTICA_TEST_TIMEOUT_SCALE=%s)"
            % (item.nodeid, limit, TIMEOUT_SCALE)
        )

    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, limit)
    faulthandler.dump_traceback_later(limit + BACKSTOP_GRACE, exit=True)
    try:
        yield
    finally:
        faulthandler.cancel_dump_traceback_later()
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


@pytest.fixture
def agentica_check(tmp_path: Path) -> Callable[..., dict[str, object] | None]:
    """Write one or more programs under ``tmp_path`` and check the root file."""
    def check(
        source: str | Mapping[str, str], name: str = "main.agc"
    ) -> dict[str, object] | None:
        files = {name: source} if isinstance(source, str) else source
        for filename, text in files.items():
            path = tmp_path / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        root = tmp_path / name
        result = run(cli() + ["--json", "check", str(root)])
        if result.code == 0:
            return None
        assert result.code == 1, result.stderr
        return json.loads(result.stderr)

    return check
