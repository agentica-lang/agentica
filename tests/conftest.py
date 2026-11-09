"""Shared fixtures for CLI-backed language tests."""

import faulthandler
import json
import os
import random
import signal
import sys
import threading
from collections.abc import Callable, Mapping
from pathlib import Path

import pytest

from tests.agentica_test import (
    BACKSTOP_GRACE,
    SLOW,
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
from tests.temp_roots import assign_root

try:
    from hypothesis import is_hypothesis_test, settings as hypothesis_settings
except ImportError:  # the Docker and Wine images run modules without properties on the system pytest
    hypothesis_settings = None

if hypothesis_settings is not None:
    # The fast tier replays the same few examples on every run (derandomize) and keeps no example database, so a run is
    # stable and quick. The slow tier draws many from the seed that pytest_configure picks and the header prints. A
    # failure prints the shrunk input and a @reproduce_failure line (print_blob). No deadline: a VM on a busy runner
    # can take a while for one example.
    hypothesis_settings.register_profile(
        "fast", max_examples=50, derandomize=True, database=None, deadline=None, print_blob=True)
    hypothesis_settings.register_profile("slow", max_examples=1000, database=None, deadline=None, print_blob=True)
    hypothesis_settings.load_profile("slow" if SLOW else "fast")


if os.name == "nt":
    # Python writes "\n" as "\r\n" in text mode on Windows, and the sources of these tests are meant byte for byte:
    # a "\r\n" the test wrote on purpose (the CRLF cases of the lexer) would become "\r\r\n". Linux and macOS write
    # what the test says, so Windows does too. Only Path.write_text changes (open(..., "w") keeps translating, as a
    # program of the user would see it), and only under pytest, so a module run by hand behaves as Python does.
    _write_text = Path.write_text

    def _write_text_exactly(self, data, encoding=None, errors=None, newline=None):
        return _write_text(self, data, encoding=encoding, errors=errors, newline="" if newline is None else newline)

    Path.write_text = _write_text_exactly


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config):
    """Give this run its temporary root (tests/temp_roots.py) and, in the slow tier, a Hypothesis seed.

    tryfirst: Hypothesis' own pytest_configure reads --hypothesis-seed after this sets it.
    """
    assign_root(config)
    if hypothesis_settings is not None and SLOW and config.getoption("hypothesis_seed", None) is None:
        config.option.hypothesis_seed = str(random.randrange(2**32))


def _seed_line(config):
    """The seed of the slow tier's properties and how to replay it, or None."""
    seed = config.getoption("hypothesis_seed", None) if hypothesis_settings is not None else None
    if seed is None:
        return None
    return "hypothesis seed %s (replay: PYTEST_ADDOPTS=--hypothesis-seed=%s make test-slow TESTS=...)" % (seed, seed)


def pytest_report_header(config):
    return _seed_line(config)


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    """The seed again after a failure: -q leaves the header out."""
    line = _seed_line(config)
    if line and exitstatus != 0:
        terminalreporter.write_line(line)


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
    """Keep plain pytest functions in the same fast/slow tier as TestCase methods. A property (a Hypothesis test) runs
    in both, with the profile of the tier."""
    for item in items:
        test_class = getattr(item, "cls", None)
        if test_class is not None and issubclass(test_class, TestCase):
            continue
        if hypothesis_settings is not None and is_hypothesis_test(getattr(item, "obj", None)):
            continue
        is_slow = item.get_closest_marker("slow") is not None
        if is_slow != SLOW:
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
