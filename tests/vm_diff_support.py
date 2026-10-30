"""The VM golden harness.

Every program of tests/fixtures/vm/ is compiled with the product CLI (`compile FILE -o OUT`) and run on the VM, and the
outcome is compared with its `<name>.expected` golden: exit code, stdout, program stderr and diagnostic code, in the
three diagnostic formats, plus a `--max-steps` sweep. The test modules tests/test_vm_diff_<N>.py each run one shard.

    python3 -m tests.vm_diff_support          rewrite the goldens (make goldens)
    python3 -m tests.vm_diff_support check    check only the fixtures named in AGENTICA_FIXTURES (make vm-golden-check)

Environment: AGENTICA_FIXTURES names fixtures (space or comma separated, without .agc; it is an error when CI is
set), AGENTICA_SWEEP is `full`, `sampled` or `ends` (only the limits 1, T - 1, T and the last one) and
AGENTICA_SWEEP_SEED fixes the sampled draw.
"""
import itertools
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import pytest
from dataclasses import dataclass, field
from pathlib import Path, PureWindowsPath

from tests.agentica_test import (FIXTURES, ROOT, RUN_TIMEOUT, UNDER_WINE, WINDOWS, TestCase, _kill_and_collect,
                                 channel_peer, compile_agc, scaled, vm_binary, vm_command, vm_environment)

FIXTURE_DIR = FIXTURES / "vm"
RUNAWAY_DIR = FIXTURE_DIR / "step-limited"

SHARD_COUNT = 8
EXTRAS_SHARD = 8
# Fixtures pinned to a shard because they are costly; the others rotate over shards 1 to 7.
HEAVY_FIXTURES = {
    "files-large.agc": 1, "process-limits.agc": 1, "tcp-exit.agc": 2, "json-decode-deep.agc": 3, "map-large.agc": 3,
    "http-server-slow.agc": 4, "http-server-stream.agc": 4, "task-concurrent.agc": 5, "tcp-limits.agc": 5, "tcp-tasks.agc": 5,
    "process-timeouts.agc": 6, "callback-overflow.agc": 7, "tcp-errors.agc": 7}
LIGHT_SHARD_ROTATION = (1, 2, 3, 4, 5, 6, 7)

FULL_SWEEP_LIMIT = 200
SWEEP_HEAD = 100
SAMPLE_POINTS = 8
RUNAWAY_LIMIT = 500
VM_TURN_STEPS = 2000
DENY_RUN_PREFIX = "spawn-denied"
TMP_TOKEN = "@tmp"
FIXTURE_TOKEN = "@fixtures/"
# The folder of the open descriptors of the process, which a fixture lists to count them: /proc/self/fd, or /dev/fd on macOS.
FD_TOKEN = "@fds"

SWEEP_MODE = os.environ.get("AGENTICA_SWEEP", "")
if SWEEP_MODE not in ("", "full", "sampled", "ends"):
    raise RuntimeError("AGENTICA_SWEEP must be full, sampled or ends, not %r" % SWEEP_MODE)
SAMPLED_SWEEP = SWEEP_MODE == "sampled"
# Fixtures whose every run is costly (1000 file rounds; three fixed sleeps): they get the `ends` sweep in every mode but
# full (the weekly sweep and the release), as the stop of a Task.map and of an HTTP client under --max-steps is swept by
# task-map-steps and http-client; only the full sweep stops a Task.map item that holds a buffered file.
ENDS_ONLY_FIXTURES = {"task-map-flushed.agc", "http-client-queue.agc", "http-server-stream.agc"}

# What a run that outlived its time limit reports in place of an exit code.
TIMEOUT = "timeout"

STACK_LINE_PATTERNS = [
    re.compile(r"^    \S+ at .+:[0-9]+:[0-9]+(?: \([0-9]+ times\))?(?: \(after a tail call\))?$"),
    re.compile(r"^    \.\.\. [0-9]+ frames? not shown \.\.\.$"),
    re.compile(r"^    task spawned at .+:[0-9]+:[0-9]+$")]
TEXT_CODE = re.compile(r"error\[([A-Z]+-[A-Z0-9-]+)\]$|^\[([A-Z]+-[A-Z0-9-]+)\]$", re.M)
PLAIN_HEADER = re.compile(r"^.*:[0-9]+:[0-9]+ error\[([A-Z]+-[A-Z0-9-]+)\] in a task$")
AI_HEADER = re.compile(r"^\[([A-Z]+-[A-Z0-9-]+)\] in a task$")
CRASH_SUMMARY = re.compile(r"^([0-9]+) task crash(?:es were| was) not observed; first: (.*)$")
CARET_LINE = re.compile(r"^ +\| [ \t]*\^+$")


def _fixture_filter():
    names = [name for name in re.split(r"[\s,]+", os.environ.get("AGENTICA_FIXTURES", "")) if name]
    if names and os.environ.get("CI"):
        raise RuntimeError("AGENTICA_FIXTURES must not be set when CI is set: CI runs every fixture")
    return names or None


FIXTURE_FILTER = _fixture_filter()


def fixture_selected(name):
    """True when AGENTICA_FIXTURES is unset or names this fixture (a name without .agc)."""
    return FIXTURE_FILTER is None or name in FIXTURE_FILTER


def fixture_programs():
    return sorted(FIXTURE_DIR.glob("*.agc"))


def runaway_programs():
    return sorted(RUNAWAY_DIR.glob("*.agc"))


def check_fixture_filter():
    """Exit 2 when AGENTICA_FIXTURES names a program that is not in tests/fixtures/vm."""
    if FIXTURE_FILTER is None:
        return
    known = {program.stem for program in fixture_programs() + runaway_programs()}
    unknown = [name for name in FIXTURE_FILTER if name not in known]
    if unknown:
        sys.stderr.write("vm-diff: no fixture named %s in tests/fixtures/vm (names go without .agc)\n"
                         % ", ".join(unknown))
        sys.exit(2)


def selected(programs):
    return [program for program in programs if fixture_selected(program.stem)]


def shard_assignment(programs):
    """[(program, shard)]: heavy fixtures where HEAVY_FIXTURES pins them, the others cycle through shards 1 to 7."""
    assignment = []
    light_index = -1
    for program in programs:
        if program.name in HEAVY_FIXTURES:
            shard = HEAVY_FIXTURES[program.name]
        else:
            light_index += 1
            shard = LIGHT_SHARD_ROTATION[light_index % len(LIGHT_SHARD_ROTATION)]
        assignment.append((program, shard))
    return assignment


# Sidecars -------------------------------------------------------------------------------------------------------------

_STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
_PAIR = re.compile(r'\(\s*"((?:[^"\\]|\\.)*)"\s+\.\s+"((?:[^"\\]|\\.)*)"\s*\)')


def _unquote(text):
    return json.loads('"%s"' % text, strict=False)


def fixture_arg(argument):
    """An .args word: "@fixtures/x" is the absolute path of tests/fixtures/x, "@fds" the folder of the open descriptors,
    anything else stays."""
    if argument == FD_TOKEN:
        return "/dev/fd" if sys.platform == "darwin" else "/proc/self/fd"
    if argument.startswith(FIXTURE_TOKEN):
        return str(FIXTURES / argument[len(FIXTURE_TOKEN):])
    return argument


@dataclass(frozen=True)
class Fixture:
    """What a VM run of a program needs besides the bytecode: stdin, arguments, environment, channel, --deny-run."""

    input: bytes = b""
    args: tuple = ()
    env: dict = field(default_factory=dict)
    channel: Path = None
    deny_run: bool = False

    @property
    def uses_tmp(self):
        return TMP_TOKEN in self.args

    @classmethod
    def of(cls, program):
        """The fixture of a program, from its .stdin, .args (a list of double-quoted strings), .env (a list of
        ("NAME" . "value") pairs) and .channel sidecars; a name that starts with `spawn-denied` runs with --deny-run."""
        def sidecar(extension):
            path = program.with_suffix(extension)
            return path if path.is_file() else None

        stdin, args, env, channel = (sidecar(extension) for extension in (".stdin", ".args", ".env", ".channel"))
        return cls(
            input=stdin.read_bytes() if stdin else b"",
            args=tuple(fixture_arg(_unquote(word)) for word in _STRING.findall(args.read_text(encoding="utf-8")))
            if args else (),
            env={_unquote(key): _unquote(value) for key, value in _PAIR.findall(env.read_text(encoding="utf-8"))}
            if env else {},
            channel=channel,
            deny_run=program.name.startswith(DENY_RUN_PREFIX))


def relocate(text, folder, token):
    """`text` with the path of `folder` written as `token` (the golden writes @fixtures and @tmp)."""
    if os.sep == "/":
        return text.replace(str(folder) + "/", token + "/") if token != TMP_TOKEN else text.replace(str(folder), token)
    return relocate_windows(text, PureWindowsPath(folder), token)


def relocate_windows(text, folder, token, escapes=True):
    """The same for a Windows folder. The VM prints a path the way it was typed (backslashes, doubled in JSON and in an
    inspected string) and the stored names of a program with slashes, so one path shows the folder in several
    spellings and a tail that mixes both separators. Each spelling of the folder becomes the token, and the rest of
    that path is written with slashes. In printed text (escapes=True) a backslash before n, r, u, a quote or another
    backslash is an escape, not a separator, so it ends the path (no fixture names a folder with one of those
    letters); the text of an argument list has no escapes (escapes=False)."""
    native = str(folder)
    forms = sorted({native, native.replace("\\", "\\\\"), folder.as_posix()}, key=len, reverse=True)
    name = r"[^\s\"':,<>|\\/]"
    guard = r"(?![nru\"\\])" if escapes else ""
    tail = r"((?:/" + name + r"*|\\{1,2}" + guard + name + r"+)*)"
    pattern = re.compile("(?:" + "|".join(re.escape(form) for form in forms) + ")" + tail)
    return pattern.sub(lambda found: token + found.group(1).replace("\\\\", "/").replace("\\", "/"), text)


def unfixture(result):
    status, stdout, stderr = result
    return status, relocate(stdout, FIXTURES, "@fixtures"), relocate(stderr, FIXTURES, "@fixtures")


def untmp(directory, result):
    return result[0], relocate(result[1], directory, TMP_TOKEN), relocate(result[2], directory, TMP_TOKEN)


# Running the VM -------------------------------------------------------------------------------------------------------

def decode(data):
    """Bytes as text the way a port reads it: each byte that is not part of a valid sequence is one U+FFFD (Python
    would turn a cut sequence into a single one)."""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        pass
    text = []
    index = 0
    while index < len(data):
        for size in range(1, min(4, len(data) - index) + 1):
            try:
                text.append(data[index:index + size].decode("utf-8"))
                index += size
                break
            except UnicodeDecodeError:
                continue
        else:
            text.append("\ufffd")
            index += 1
    return "".join(text)


def exit_status(code):
    """The status a shell reports: 128 + the signal for a process killed by one."""
    return code if code >= 0 else 128 - code


def execute(argv, stdin=b"", stdin_path=None, timeout=RUN_TIMEOUT, cwd=None, env=None):
    """Run a command to its end in its own session: (status, stdout, stderr) as text, or (TIMEOUT, "", "") when it
    outlives `timeout` seconds (its whole process group is killed). stdin is bytes for a pipe, or `stdin_path` names a
    file to redirect, which is what the batch of a golden run did and what a pipe is not."""
    source = open(stdin_path, "rb") if stdin_path else None
    try:
        process = subprocess.Popen(
            [part if isinstance(part, bytes) else str(part) for part in argv], stdin=source or subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, cwd=cwd, env=env, start_new_session=True)
        try:
            out, err = process.communicate(None if source else stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_and_collect(process)
            return TIMEOUT, "", ""
        except BaseException:
            _kill_and_collect(process)
            raise
    finally:
        if source:
            source.close()
    return exit_status(process.returncode), decode(out), decode(err)


# The goldens are taken and checked at one scheduler: their step counts, the --max-steps sweep and the order of output
# between tasks are fixed only there. The variable (not the flag) reaches the VMs that a fixture starts too; a flag
# given in `options` still wins (tests/test_vm_multicore.py runs the goldens at four).
ONE_SCHEDULER = {"AGENTICA_SCHEDULERS": "1"}


def run_vm_process(fixture, options, bytecode, args, timeout=RUN_TIMEOUT, cwd=None, env=None, stdin_path=None):
    """One VM run as (status, stdout, stderr); the status is TIMEOUT when it outlives `timeout` seconds.

    A fixture with a channel runs through tests/fixtures/channel-run.py, which hands the VM a socket as descriptor 3, or
    on Windows through channel-run.js, which hands it two pipes at descriptors 3 and 4.
    """
    prefix = [*channel_peer("channel-run"), fixture.channel] if fixture.channel else []
    argv = prefix + [*vm_command(), *options, "--", bytecode, *args]
    environment = vm_environment({**ONE_SCHEDULER, **fixture.env, **(env or {})})
    return execute(argv, fixture.input, stdin_path, timeout, cwd, environment)


def style_options(style):
    return {"ai": ["--ai"], "json": ["--json"]}.get(style, [])


def limit_options(limit):
    return ["--max-steps", str(limit)] if limit else []


def deny_options(fixture):
    return ["--deny-run"] if fixture.deny_run else []


def source_root_options():
    """The fixtures run as the CLI runs a program in tests/fixtures/vm: the stored names go under that folder."""
    return ["--source-root", str(FIXTURE_DIR)]


def tmp_args(fixture, directory):
    return [str(directory) if word == TMP_TOKEN else word for word in fixture.args]


_TMP_COUNT = itertools.count(1)


def fresh_tmp(work):
    """A new empty folder under `work`, for an `@tmp` argument."""
    directory = Path(work) / ("vm-%06d" % next(_TMP_COUNT))
    directory.mkdir()
    return directory


def run_vm(fixture, bytecode, limit, style="json", root=(), extra=(), timeout=RUN_TIMEOUT, cwd=None, env=None):
    """The VM on `bytecode` with the fixture's arguments and stdin, in one diagnostic style."""
    options = deny_options(fixture) + limit_options(limit) + style_options(style) + list(root)
    return run_vm_process(fixture, options, bytecode, [*fixture.args, *extra], timeout, cwd, env)


def run_fixture_vm(fixture, bytecode, limit, work):
    """A fixture run as the golden is taken: --json, the fixtures as source root, @tmp as a fresh folder."""
    if fixture.uses_tmp:
        directory = fresh_tmp(work)
        try:
            options = deny_options(fixture) + limit_options(limit) + style_options("json") + source_root_options()
            result = untmp(directory, run_vm_process(fixture, options, bytecode, tmp_args(fixture, directory),
                                                     cwd=work))
        finally:
            shutil.rmtree(directory, ignore_errors=True)
    else:
        result = run_vm(fixture, bytecode, limit, root=source_root_options(), cwd=work)
    return unfixture(result)


def vm_batch(fixture, bytecode, option_lists, work):
    """Run the VM once for each list of options, with the fixture's stdin as a file; after the first run that hangs
    (124 or 137) the others are skipped and reported as 124."""
    results = []
    hung = False
    stdin_path = Path(work) / "stdin"
    stdin_path.write_bytes(fixture.input)
    for options in option_lists:
        if hung:
            results.append((124, "", ""))
            continue
        directory = fresh_tmp(work) if fixture.uses_tmp else None
        try:
            args = tmp_args(fixture, directory) if directory else fixture.args
            result = run_vm_process(fixture, deny_options(fixture) + source_root_options() + options, bytecode, args,
                                    cwd=work, stdin_path=stdin_path)
            if directory:
                result = untmp(directory, result)
        finally:
            if directory:
                shutil.rmtree(directory, ignore_errors=True)
        if result[0] == TIMEOUT:
            result = (124, "", "")
        hung = result[0] in (124, 137)
        results.append(unfixture(result))
    return results


# Reading the output ---------------------------------------------------------------------------------------------------

def last_line_start(text):
    return text.rfind("\n") + 1


def outcome(result):
    """(status, stdout, stderr, code): the diagnostic code comes from the last stderr line when that is a JSON
    diagnostic of an exit 1, and that line is cut from the stderr."""
    status, stdout, stderr = result
    body = stderr[:-1] if stderr.endswith("\n") else stderr
    start = last_line_start(body)
    parsed = None
    if status == 1:
        try:
            parsed = json.loads(body[start:])
        except ValueError:
            parsed = None
    code = None
    if isinstance(parsed, dict) and not parsed.get("task") and isinstance(parsed.get("code"), str):
        code = parsed["code"]
    return status, stdout, stderr[:start] if code else stderr, code


def text_code(stderr):
    found = TEXT_CODE.findall(stderr)
    if not found:
        return None
    return found[-1][0] or found[-1][1]


def diagnostic_code(result):
    return outcome(result)[3]


def step_limited(result):
    return diagnostic_code(result) == "RUNTIME-STEP-LIMIT"


def _parse_line(line):
    try:
        return json.loads(line)
    except ValueError:
        return None


def json_crash_free(text):
    """Task crash records and the unobserved summary taken out of JSON stderr: (kept text, codes, summaries)."""
    kept, codes, summaries = [], [], []
    for line in text.split("\n"):
        parsed = _parse_line(line)
        if isinstance(parsed, dict) and parsed.get("task") is True:
            codes.append(parsed["code"])
        elif isinstance(parsed, dict) and "unobserved_crashes" in parsed:
            summaries.append((parsed["unobserved_crashes"], parsed["first"]))
        else:
            kept.append(line)
    return "\n".join(kept), codes, summaries


def skip_stack(lines, header):
    if lines and lines[0] == header:
        rest = lines[1:]
        while rest and any(pattern.match(rest[0]) for pattern in STACK_LINE_PATTERNS):
            rest = rest[1:]
        return rest
    return lines


def _after_caret(lines):
    for index, line in enumerate(lines):
        if CARET_LINE.match(line):
            return skip_stack(lines[index + 1:], "  = stack, innermost first:")
    return []


def text_crash_free(text):
    """The same for the plain and --ai formats, whose crash blocks span several lines with a stack."""
    kept, codes, summaries = [], [], []
    lines = text.split("\n")
    while lines:
        ai = AI_HEADER.match(lines[0]) if len(lines) >= 4 else None
        plain = PLAIN_HEADER.match(lines[0])
        summary = CRASH_SUMMARY.match(lines[0])
        if ai:
            codes.append(ai.group(1))
            lines = skip_stack(lines[4:], "  stack:")
        elif plain:
            codes.append(plain.group(1))
            lines = _after_caret(lines[1:])
        elif summary:
            summaries.append((int(summary.group(1)), summary.group(2)))
            lines = lines[1:]
        else:
            kept.append(lines[0])
            lines = lines[1:]
    return "\n".join(kept), codes, summaries


def check_text_format(on_vm, full, message):
    """A plain or --ai run against the golden of the --json run: same exit and stdout, the same crashes, the same
    program stderr, and the same diagnostic code."""
    assert tuple(on_vm[:2]) == tuple(full[:2]), "%s\n  got:      %r\n  expected: %r" % (message, on_vm[:2], full[:2])
    stderr, text_crashes, text_summaries = text_crash_free(on_vm[2])
    expected, json_crashes, json_summaries = json_crash_free(full[2])
    assert text_crashes == json_crashes, message
    assert text_summaries == json_summaries, message
    assert stderr.startswith(expected), "%s: %r does not start with %r" % (message, stderr, expected)
    diagnostic = stderr[min(len(stderr), len(expected)):]
    if full[3]:
        assert text_code(diagnostic) == full[3], message
    else:
        assert diagnostic == "", message


def check_step_allowance(limited, expected_steps, name):
    """A fixture stays within the step allowance of its golden: one run under the allowance must finish. With the
    limit monotonic (check_sweep), that is the same as the smallest limit that finishes being at most the allowance.
    A lower count passes, as the per-system goldens (files-real-windows) are only refreshed on their system."""
    assert not limited(step_allowance(expected_steps)), \
        "%s takes more steps than its golden %s allows (over-charging)" % (name, expected_steps)


def check_limited(on_vm, full, name, limit, note=""):
    """One sweep limit: the golden outcome, or a step-limit stop whose output is a prefix of the golden's."""
    seen = outcome(on_vm)
    message = "%s --max-steps %s%s (exit 124/137 or timeout: the run timed out): %r" % (name, limit, note, seen)
    if seen != full:
        assert seen[0] == 1, message
        assert seen[3] == "RUNTIME-STEP-LIMIT", message
        assert full[1].startswith(seen[1]), message
        assert full[2].startswith(seen[2]), message
    return seen == full


def check_sweep(results, limits, full, name, note=""):
    """Every limit must stop on the step limit or give the golden outcome, and once one finishes so must larger."""
    finished = False
    for on_vm, limit in zip(results, limits):
        done = check_limited(on_vm, full, name, limit, note)
        if finished:
            assert done, "%s --max-steps %s%s stops after a smaller limit finished" % (name, limit, note)
        finished = done
    assert finished, "%s finishes under --max-steps %s%s" % (name, limits[-1], note)


# A fixture named -posix or -windows holds what that family of systems answers (Linux and macOS, or Windows), and the
# shared fixtures hold the rest, so the other family skips it as host-only: the system gives another answer on purpose
# (the text of an errno, a drive letter, a case-insensitive environment). The variant fixtures sit next to each other
# and exist in pairs, or have a Windows counterpart in tests/test_windows_*.py.
VARIANT_FAMILY = re.compile(r"-(posix|windows)\.agc$")

# Fixtures that have a gap on one system: the behavior exists there, so the case is an open gap (a known-issue skip),
# not a host-only one. The reason says what differs.
KNOWN_ISSUE_FIXTURES = {}


def skip_reason(name):
    """Why this system does not run the golden of the fixture, or None: a "host-only:" or "known-issue:" text (under Wine,
    a plain one for the channel fixtures)."""
    family = VARIANT_FAMILY.search(name)
    if family and (family.group(1) == "windows") != WINDOWS:
        return "host-only: %s holds the answers of %s" % (name, "Windows" if family.group(1) == "windows"
                                                        else "Linux and macOS")
    system = "windows" if WINDOWS else sys.platform
    gap = KNOWN_ISSUE_FIXTURES.get(name, {}).get(system)
    if gap:
        return "known-issue: #%d %s: %s" % (gap[0], name, gap[1])
    if UNDER_WINE and Path(FIXTURE_DIR / name).with_suffix(".channel").is_file():
        return "%s: Wine runs the Windows binary, which a Linux peer cannot give the two pipes of its channel" % name
    return None


def check_fixture(program, work):
    """The golden test of one fixture: every format, the step count and the --max-steps sweep."""
    name = program.name
    reason = skip_reason(name)
    if reason:
        pytest.skip(reason)
    fixture = Fixture.of(program)
    bytecode = compile_agc(program, work / (program.stem + ".agcb"))
    full = read_expected(program)
    expected_steps = read_expected_steps(program)
    check_step_allowance(lambda limit: step_limited(run_fixture_vm(fixture, bytecode, limit, work)), expected_steps, name)
    limits = fixture_limits(name, expected_steps)
    text_styles = ["plain", "ai"]
    results = vm_batch(
        fixture, bytecode,
        [style_options("json")] + [style_options(style) for style in text_styles]
        + [limit_options(limit) + style_options("json") for limit in limits], work)
    seen = outcome(results[0])
    assert seen == full, "%s\n  got:      %r\n  expected: %r" % (name, seen, full)
    for style, on_vm in zip(text_styles, results[1:]):
        check_text_format(on_vm, full, "%s %s" % (name, style))
    check_sweep(results[1 + len(text_styles):], limits, full, name, sweep_note())


def check_runaway(program, work):
    """A runaway loop stops at --max-steps 1 to 5, 50 and 500 with a prefix of its expected output."""
    name = program.name
    bytecode = compile_agc(program, work / (program.stem + ".agcb"))
    expected = read_expected(program)
    fixture = Fixture()
    for limit in [1, 2, 3, 4, 5, 50, RUNAWAY_LIMIT]:
        message = "%s --max-steps %s" % (name, limit)
        on_vm = run_vm(fixture, bytecode, limit, cwd=work)
        assert on_vm[0] == 1, message
        assert step_limited(on_vm), message
        assert "done" not in on_vm[1], message
        assert expected[1].startswith(on_vm[1]), message
        assert expected[2].startswith(outcome(on_vm)[2]), message
        if limit == RUNAWAY_LIMIT:
            assert outcome(on_vm) == expected, message


def _make_shard_test(program):
    def test_fixture(tmp_path):
        check_fixture(program, tmp_path)

    test_fixture.__name__ = "test_" + program.stem.replace("-", "_")
    test_fixture.__doc__ = ("%s gives its expected exit code, stdout, stderr and diagnostic code "
                             "under every --max-steps" % program.name)
    return test_fixture


def install_shard_tests(shard, namespace):
    """Define the pytest tests of golden shard N in namespace (the caller shard module's globals).

    The caller keeps SHARD = N so the shard-table test still names its shard."""
    @pytest.fixture(scope="module", autouse=True)
    def _warmup():
        vm_binary()

    namespace["_warmup"] = _warmup
    for program in [program for program, assigned in shard_assignment(fixture_programs()) if assigned == shard]:
        test = _make_shard_test(program)
        assert test.__name__ not in namespace, test.__name__
        namespace[test.__name__] = test


# Goldens --------------------------------------------------------------------------------------------------------------

def expected_file(program):
    return program.with_suffix(".expected")


def read_golden(program):
    path = expected_file(program)
    if not path.is_file():
        raise RuntimeError("%s is missing; run make goldens" % path)
    return json.loads(path.read_text(encoding="utf-8"))


def read_expected(program):
    """(exit, stdout, stderr, code) of a program's golden."""
    data = read_golden(program)
    code = data["code"]
    return data["exit"], "\n".join(data["stdout"]), "\n".join(data["stderr"]), code if isinstance(code, str) else None


def read_expected_steps(program):
    steps = read_golden(program).get("steps")
    if not isinstance(steps, int) or isinstance(steps, bool) or steps < 1:
        raise RuntimeError("%s has no step count; run make goldens" % expected_file(program))
    return steps


def _json_string(text):
    # The JSON text of a program escapes DEL too; the goldens keep non-ASCII characters as they are.
    return json.dumps(text, ensure_ascii=False).replace("\x7f", "\\u007f")


def _json_lines(name, text):
    items = [] if text == "" else text.split("\n")
    if not items:
        return "  %s: []" % _json_string(name)
    return "  %s: [\n%s\n  ]" % (_json_string(name), ",\n".join("    " + _json_string(item) for item in items))


def expected_text(result, steps=None):
    """The text of a golden file."""
    status, stdout, stderr, code = result
    return ("{\n  \"exit\": %d,\n  \"code\": %s,\n%s%s,\n%s\n}\n" % (
        status, _json_string(code) if code else "null", "  \"steps\": %d,\n" % steps if steps else "",
        _json_lines("stdout", stdout), _json_lines("stderr", stderr)))


# Steps and sweeps -----------------------------------------------------------------------------------------------------

def last_limit(steps):
    return max(2 * steps + 100, steps + 2 * VM_TURN_STEPS)


def step_allowance(steps):
    return steps + max(10, steps // 10)


def total_steps(limited):
    """The smallest --max-steps under which the program finishes; `limited(n)` says whether a limit of n stops it.
    Only `make goldens` searches: the tests check the recorded count (check_step_allowance)."""
    low = high = 1
    while limited(high):
        low, high = high, high * 2
    while low < high:
        middle = (low + high) // 2
        if limited(middle):
            low = middle + 1
        else:
            high = middle
    return high


def fixture_limits(name, steps):
    """The --max-steps limits of a fixture, around the step count T of its golden (the check of the allowance proves
    that the VM's own count is not above it)."""
    if SWEEP_MODE == "ends" or (name in ENDS_ONLY_FIXTURES and SWEEP_MODE != "full"):
        return end_limits(steps)
    return sampled_limits(steps, name) if SAMPLED_SWEEP else sweep_limits(steps)


def end_limits(steps):
    """1, T - 1, T and the last limit: the first and the last stop, and the finish."""
    return sorted({limit for limit in (1, steps - 1, steps) if limit >= 1}) + [last_limit(steps)]


def sweep_limits(steps):
    if steps <= FULL_SWEEP_LIMIT:
        limits = list(range(1, steps + 1))
    else:
        limits = list(dict.fromkeys(
            list(range(1, SWEEP_HEAD + 1)) + list(range(SWEEP_HEAD, steps, steps // 50)) + [steps - 1, steps]))
    return limits + [last_limit(steps)]


def _head_sha():
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True,
                              timeout=scaled(10)).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None


def _sweep_seed():
    given = os.environ.get("AGENTICA_SWEEP_SEED")
    if given:
        if not given.isascii() or not given.isdigit():
            raise RuntimeError("AGENTICA_SWEEP_SEED must be a natural number, not %r" % given)
        return int(given)
    if SAMPLED_SWEEP:
        sha = os.environ.get("GITHUB_SHA") or _head_sha()
        if sha and re.match(r"[0-9a-f]{8}", sha):
            return int(sha[:8], 16)
    return 0


SWEEP_SEED = _sweep_seed()


def sweep_note():
    if SAMPLED_SWEEP:
        return " [sampled sweep: AGENTICA_SWEEP=sampled AGENTICA_SWEEP_SEED=%d]" % SWEEP_SEED
    return ""


def name_seed(name):
    value = 0
    for byte in name.encode("utf-8"):
        value = (value * 31 + byte) % 2147483647
    return value


def sampled_limits(steps, name):
    """1, 2, T - 1, T, the last limit and one limit drawn from each eighth of 3 to T - 2."""
    low = 3
    high = steps - 2
    span = high - low + 1
    if span <= SAMPLE_POINTS:
        middle = list(range(low, high + 1))
    else:
        draw = random.Random((SWEEP_SEED + name_seed(name)) % 2147483646 + 1)
        middle = []
        for bucket in range(SAMPLE_POINTS):
            start = low + bucket * span // SAMPLE_POINTS
            end = low + (bucket + 1) * span // SAMPLE_POINTS
            middle.append(start + draw.randrange(end - start))
    chosen = sorted({limit for limit in [1, 2, *middle, steps - 1, steps] if 1 <= limit <= steps})
    return chosen + [last_limit(steps)]


class VmCase(TestCase):
    """A TestCase with the checks of the golden harness."""

    def work_dir(self):
        """A scratch folder for this test (one per test, removed after it); VM runs use it as working directory."""
        if not hasattr(self, "_scratch"):
            self._scratch = self.make_temp_dir("agentica-vm-").resolve()
        return self._scratch

    def bytecode_of(self, program, name=None):
        """Compile a program with the CLI into the scratch folder; returns the .agcb path."""
        return compile_agc(program, self.work_dir() / ((name or program.stem) + ".agcb"))

    def check_limited(self, on_vm, full, name, limit, note=""):
        return check_limited(on_vm, full, name, limit, note)

    def check_sweep(self, results, limits, full, name, note=""):
        return check_sweep(results, limits, full, name, note)

    def check_step_allowance(self, limited, expected_steps, name):
        return check_step_allowance(limited, expected_steps, name)

    def check_fixture(self, program):
        return check_fixture(program, self.work_dir())

    def check_runaway(self, program):
        return check_runaway(program, self.work_dir())


def shard_case(shard):
    """The TestCase of one shard: a test method for each of its fixtures. Shard 8 runs only the extras."""
    methods = {}
    for program, assigned in shard_assignment(fixture_programs()):
        if assigned == shard:
            methods["test_" + program.stem.replace("-", "_")] = _fixture_method(program)

    def set_up_class(cls):
        super(cls, cls).setUpClass()
        if SAMPLED_SWEEP:
            sys.stderr.write("vm-diff shard %d: sampled --max-steps sweep, AGENTICA_SWEEP_SEED=%d\n"
                             % (shard, SWEEP_SEED))
        vm_binary()

    return type("Shard%d" % shard, (VmCase,), {**methods, "setUpClass": classmethod(set_up_class)})


def _fixture_method(program):
    def method(self):
        self.check_fixture(program)

    method.__doc__ = "%s gives its expected exit code, stdout, stderr and diagnostic code under every --max-steps" \
        % program.name
    return method


# The goldens ----------------------------------------------------------------------------------------------------------

def _save(program, result, steps=None):
    seen = outcome(result)
    if not isinstance(seen[0], int) or 128 < seen[0] < 160:
        raise RuntimeError("%s did not finish (timeout or signal): %r" % (program, result))
    if seen[3] == "RUNTIME-INTERNAL":
        raise RuntimeError("%s failed with RUNTIME-INTERNAL: %r" % (program, result))
    expected_file(program).write_text(expected_text(seen, steps), encoding="utf-8", newline="\n")


def write_goldens():
    """Rewrite the .expected files of the selected fixtures (all of them without AGENTICA_FIXTURES)."""
    check_fixture_filter()
    vm_binary()
    for directory in (FIXTURE_DIR, RUNAWAY_DIR):
        for path in sorted(directory.glob("*.expected")):
            if not path.with_suffix(".agc").exists():
                sys.stderr.write("%s has no .agc next to it; delete it\n" % path)
    with tempfile.TemporaryDirectory(prefix="agentica-goldens-") as scratch:
        work = Path(scratch).resolve()
        for program in selected(fixture_programs()):
            fixture = Fixture.of(program)
            bytecode = compile_agc(program, work / (program.stem + ".agcb"))
            total = total_steps(lambda limit: step_limited(run_fixture_vm(fixture, bytecode, limit, work)))
            _save(program, run_fixture_vm(fixture, bytecode, None, work), total)
        for program in selected(runaway_programs()):
            bytecode = compile_agc(program, work / (program.stem + ".agcb"))
            _save(program, run_vm(Fixture(), bytecode, RUNAWAY_LIMIT, cwd=work))


def check_selected():
    """The CI golden check of the fixtures named in AGENTICA_FIXTURES, and of their stack-trace sidecars."""
    check_fixture_filter()
    if FIXTURE_FILTER is None:
        sys.stderr.write("vm-diff: check needs AGENTICA_FIXTURES (make vm-golden-check FIXTURES=\"name ...\")\n")
        sys.exit(2)
    vm_binary()
    methods = {}
    for program in selected(fixture_programs()):
        methods["test_" + program.stem.replace("-", "_")] = _fixture_method(program)
    for program in selected(runaway_programs()):
        methods["test_" + program.stem.replace("-", "_")] = _runaway_method(program)
    suite = unittest.TestSuite(unittest.TestLoader().loadTestsFromTestCase(type("Selected", (VmCase,), methods)))
    from tests.test_vm_stack import StackTraces
    suite.addTests(unittest.TestLoader().loadTestsFromTestCase(StackTraces))
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    ran = result.testsRun - len(result.skipped)
    if ran == 0:
        sys.stderr.write("vm-diff: no checks ran (a skipped fixture?)\n")
        sys.exit(1)
    sys.exit(0 if result.wasSuccessful() else 1)


def _runaway_method(program):
    def method(self):
        self.check_runaway(program)

    method.__doc__ = "%s stops at --max-steps with a prefix of its expected output" % program.name
    return method


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if not arguments:
        write_goldens()
    elif arguments == ["check"]:
        check_selected()
    else:
        sys.stderr.write("usage: python3 -m tests.vm_diff_support [check]\n")
        sys.exit(2)
