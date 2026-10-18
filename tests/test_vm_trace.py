"""VM tracing.

Tracing to a file (AGENTICA_VM_TRACE, AGENTICA_VM_TRACE_FILE) must change no
exit code, stdout or stderr. Every trace line matches the documented format,
an unknown category or an unwritable file costs one warning line, and a VM
started with stderr or stdout closed still behaves as before. The VM runs
directly (not through `run`), because a fixture's stdin is a regular file, not
a pipe, as it was for the original test.
"""
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

import pytest

from tests.agentica_test import FIXTURES, compile_agc, scaled, vm_command, vm_environment

pytestmark = pytest.mark.skipif(not sys.platform.startswith("linux"), reason="VM trace tests: Linux only")

VM_FIXTURES = FIXTURES / "vm"
WAIT_SECONDS = scaled(60)

TRACE_LINE = re.compile(
    rb'^agc-trace \+[0-9]+\.[0-9]{6} (sched|io|proc|tls|loader|gc) [a-z_]+'
    rb'( [a-z_]+=([^ ="\\\x00-\x20\x7f]+|"([^"\\\x00-\x1f\x7f]|\\["\\bfnrt]|\\u[0-9a-f]{4})*"))*$')
GC_LINE = re.compile(
    rb"^agc-trace \+[0-9]+\.[0-9]{6} gc collect at=(turn|end) count=[0-9]+ heap=[0-9]+ free=[0-9]+ since=[0-9]+$")
CATEGORY = re.compile(rb"^agc-trace \S+ (\S+)")

# (fixture, stdin sidecar, --allow-run, categories that must show up in the trace)
CASES = [
    ("task-stdin", "task-stdin.stdin", False, ["loader", "sched", "io"]),
    ("process-streams", None, True, ["loader", "sched", "io", "proc"]),
    ("files-handles", None, False, ["loader", "sched", "io"]),
    ("task-file-shared", None, False, ["loader", "sched", "io"]),
    ("task-fail", None, False, ["loader", "sched"]),
    ("tls-echo", None, False, ["loader", "sched", "io", "tls"]),
]


@pytest.fixture(scope="module")
def traced_vm():
    vm = vm_command()
    version = subprocess.run([*vm, "--version"], stdout=subprocess.PIPE, timeout=WAIT_SECONDS).stdout
    if b"trace off" in version:
        pytest.skip("the VM was built with TRACE=0")
    return vm, version


def vm_run(arguments, env, stdin_file=None):
    """Run a command to its end in its own session; returns (exit code, stdout bytes, stderr bytes)."""
    stdin = open(stdin_file, "rb") if stdin_file else subprocess.PIPE
    try:
        process = subprocess.Popen([str(part) for part in arguments], stdin=stdin, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, start_new_session=True)
        try:
            out, err = process.communicate(timeout=WAIT_SECONDS)
        except BaseException as problem:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            if isinstance(problem, subprocess.TimeoutExpired):
                raise AssertionError("the VM finished within %s s: %s" % (WAIT_SECONDS, arguments)) from None
            raise
    finally:
        if stdin_file:
            stdin.close()
    return process.returncode, out, err


def trace_lines(path):
    """The lines of a trace file (the last byte, the final newline, is dropped as the original test did)."""
    if not path.exists():
        return []
    data = path.read_bytes()
    return data[:max(0, len(data) - 1)].split(b"\n")


def run_vm(vm, bytecode, settings=None, stdin_file=None, allow_run=False, args=(), tmp=None):
    """The VM on `bytecode`; `settings` are extra environment variables; tmp is made fresh and empty."""
    if tmp is not None:
        fresh_directory(tmp)
    env = vm_environment(settings)
    arguments = [*vm, *(["--allow-run"] if allow_run else []), "--", bytecode, *args]
    return vm_run(arguments, env, stdin_file)


def fresh_directory(path):
    path.mkdir(parents=True, exist_ok=True)
    for entry in path.iterdir():
        if entry.is_dir() and not entry.is_symlink():
            fresh_directory(entry)
            entry.rmdir()
        else:
            entry.unlink()


def compile_fixture(source, directory):
    source = Path(source)
    return compile_agc(source, directory / (source.stem + ".agcb"))


def fixture_args(name, tmp):
    sidecar = VM_FIXTURES / (name + ".args")
    if not sidecar.exists():
        return []
    # No escapes: a regex reads the strings, so a sidecar with a backslash escape (system-args.args) needs a real reader.
    # The sidecar is a list of double-quoted strings: "@tmp" is the case's temp dir, "@fixtures/x" is
    # tests/fixtures/x.
    arguments = []
    for argument in re.findall(r'"([^"]*)"', sidecar.read_text()):
        if argument == "@tmp":
            arguments.append(str(tmp))
        elif argument.startswith("@fixtures/"):
            arguments.append(str((FIXTURES / argument[len("@fixtures/"):]).resolve()))
        else:
            arguments.append(argument)
    return arguments


def run_closed(vm, redirect, bytecode, stdin_file):
    """The VM under `sh` with a descriptor closed ("2>&-" or ">&-") and the file as stdin."""
    script = 'exec "$0" run -- "$1" %s <"$2"' % redirect
    return vm_run(["sh", "-c", script, vm[0], bytecode, stdin_file], vm_environment())


def check_case(vm, tmp_path, name, stdin, allow_run, categories):
    work = tmp_path / ("agentica-trace-%s" % name)
    work.mkdir()
    bytecode = compile_fixture(VM_FIXTURES / (name + ".agc"), work)
    stdin_file = VM_FIXTURES / stdin if stdin else None
    tmp = work / (name + "-tmp")
    args = fixture_args(name, tmp)
    plain = run_vm(vm, bytecode, stdin_file=stdin_file, allow_run=allow_run, args=args, tmp=tmp)
    path = work / (name + ".trace")
    traced = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "all", "AGENTICA_VM_TRACE_FILE": path},
                    stdin_file, allow_run, args, tmp)
    assert traced == plain
    assert path.stat().st_mode & 0o077 == 0
    lines = trace_lines(path)
    assert lines
    for line in lines:
        assert TRACE_LINE.search(line), "trace line %r" % line
    seen = {CATEGORY.match(line).group(1).decode("latin-1") for line in lines}
    for category in categories:
        assert category in seen, "category %s in %s" % (category, sorted(seen))


def test_task_stdin_tracing_to_a_file_changes_no_exit_code_stdout_or_stderr(tmp_path, traced_vm):
    check_case(traced_vm[0], tmp_path, *CASES[0])


def test_process_streams_tracing_to_a_file_changes_no_exit_code_stdout_or_stderr(tmp_path, traced_vm):
    check_case(traced_vm[0], tmp_path, *CASES[1])


def test_files_handles_tracing_to_a_file_changes_no_exit_code_stdout_or_stderr(tmp_path, traced_vm):
    check_case(traced_vm[0], tmp_path, *CASES[2])


def test_task_file_shared_tracing_to_a_file_changes_no_exit_code_stdout_or_stderr(tmp_path, traced_vm):
    check_case(traced_vm[0], tmp_path, *CASES[3])


def test_task_fail_tracing_to_a_file_changes_no_exit_code_stdout_or_stderr(tmp_path, traced_vm):
    check_case(traced_vm[0], tmp_path, *CASES[4])


def test_tls_echo_tracing_to_a_file_changes_no_exit_code_stdout_or_stderr(tmp_path, traced_vm):
    check_case(traced_vm[0], tmp_path, *CASES[5])


def test_an_unknown_category_writes_one_warning_and_changes_nothing_else(tmp_path, traced_vm):
    vm = traced_vm[0]
    bytecode = compile_fixture(VM_FIXTURES / "task-fail.agc", tmp_path)
    plain = run_vm(vm, bytecode)
    status, out, err = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "nope"})
    assert status == plain[0]
    assert out == plain[1]
    assert err == b'agc-trace unknown category "nope"\n' + plain[2]


def test_a_trace_file_that_cannot_be_opened_writes_one_line_and_traces_nothing(tmp_path, traced_vm):
    vm = traced_vm[0]
    bytecode = compile_fixture(VM_FIXTURES / "task-fail.agc", tmp_path)
    plain = run_vm(vm, bytecode)
    missing = tmp_path / "missing" / "trace"
    status, out, err = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "all", "AGENTICA_VM_TRACE_FILE": missing})
    assert status == plain[0]
    assert out == plain[1]
    line_end = len(err) - len(plain[2])
    assert line_end >= 0
    assert err[max(0, line_end):] == plain[2]
    assert re.search(rb'^agc-trace cannot open "?[^\n]*/missing/trace"?\n$', err[:max(0, line_end)])


def test_an_allocation_heavy_run_writes_gc_collect_lines(tmp_path, traced_vm):
    vm, version = traced_vm
    if b"sanitizer build" in version:
        pytest.skip("gc trace test: sanitizer build, no libgc")
    bytecode = compile_fixture(VM_FIXTURES / "map-large.agc", tmp_path)
    path = tmp_path / "map-large.trace"
    plain = run_vm(vm, bytecode)
    traced = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "gc", "AGENTICA_VM_TRACE_FILE": path})
    lines = trace_lines(path)
    assert traced == plain
    assert lines
    for line in lines:
        assert GC_LINE.search(line), "gc line %r" % line


def test_the_profile_counts_calls_and_steps_of_each_function_and_the_time_of_each_builtin(tmp_path, traced_vm):
    vm = traced_vm[0]
    source = tmp_path / "profile.agc"
    source.write_text("def square(n: Int) -> Int\n  return n * n\nend\n\ndef main() -> Void\n  total = 0\n"
                      "  for k in 0...50\n    total += square(k)\n  end\n  puts(total)\nend\n")
    bytecode = compile_fixture(source, tmp_path)
    path = tmp_path / "profile.trace"
    plain = run_vm(vm, bytecode)
    traced = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": path})
    assert traced == plain
    lines = trace_lines(path)
    number = rb"[0-9]+"
    patterns = [
        rb"^agc-trace \+[0-9.]+ profile total wall_ms=" + number + rb" steps=([1-9][0-9]*) calls=" + number +
        rb" builtin_calls=1 builtin_ms=" + number + rb" gc_ms=" + number + rb" collections=" + number + rb"$",
        rb"^agc-trace \+[0-9.]+ profile fn calls=50 steps=" + number + rb" name=square at=profile\.agc:1$",
        rb"^agc-trace \+[0-9.]+ profile fn calls=1 steps=" + number + rb" name=main at=profile\.agc:5$",
        rb"^agc-trace \+[0-9.]+ profile file calls=51 steps=" + number + rb" name=profile\.agc$",
        rb"^agc-trace \+[0-9.]+ profile builtin calls=1 us=" + number + rb" name=\S*puts$",
    ]
    for pattern in patterns:
        assert any(re.match(pattern, line) for line in lines), "%r in %r" % (pattern, lines)


def test_the_profile_stops_a_looping_program_at_the_same_step_and_counts_a_native_loop(tmp_path, traced_vm):
    """Counting takes every STEP through the slow path of the budget; the run must still end where it ended."""
    vm = traced_vm[0]
    source = tmp_path / "loop.agc"
    source.write_text("def twice(n: Int) -> Int\n  return n * 2\nend\n\ndef main() -> Void\n"
                      "  3.times do |n|\n    puts(n)\n  end\n  i = 0\n  while true\n    i = twice(i) + 1\n"
                      "    if i > 1000\n      i = 0\n    end\n  end\nend\n")
    bytecode = compile_fixture(source, tmp_path)
    path = tmp_path / "loop.trace"
    command = [*vm, "--json", "--max-steps", "5000", "--", bytecode]
    plain = vm_run(command, vm_environment())
    traced = vm_run(command, vm_environment({"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": path}))
    assert plain[0] == 1
    assert traced[:2] == plain[:2]
    ended = json.loads(plain[2])
    assert ended["code"] == "RUNTIME-STEP-LIMIT"
    assert json.loads(traced[2])["code"] == ended["code"]
    assert json.loads(traced[2])["range"] == ended["range"]
    lines = trace_lines(path)
    assert any(re.match(rb"^agc-trace \S+ profile fn calls=0 steps=3 name=<native>$", line)
               for line in lines), lines


def test_the_profile_is_not_part_of_all(tmp_path, traced_vm):
    vm = traced_vm[0]
    bytecode = compile_fixture(VM_FIXTURES / "task-fail.agc", tmp_path)
    path = tmp_path / "all.trace"
    run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "all", "AGENTICA_VM_TRACE_FILE": path})
    assert not any(b" profile " in line for line in trace_lines(path))


def test_a_connection_task_names_its_servers_group_as_its_parent(tmp_path, traced_vm):
    vm = traced_vm[0]
    path = tmp_path / "http-server-close.trace"
    bytecode = compile_fixture(VM_FIXTURES / "http-server-close.agc", tmp_path)
    status = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "sched", "AGENTICA_VM_TRACE_FILE": path})[0]
    assert status == 0
    spawn = re.compile(rb" sched spawn task=[0-9]+ parent=group:[1-9][0-9]* fn=")
    assert any(spawn.search(line) for line in trace_lines(path))


def test_a_vm_started_with_stderr_closed_runs_normally(tmp_path, traced_vm):
    vm = traced_vm[0]
    stdin_file = VM_FIXTURES / "task-stdin.stdin"
    bytecode = compile_fixture(VM_FIXTURES / "task-stdin.agc", tmp_path)
    plain = run_vm(vm, bytecode, stdin_file=stdin_file)
    status, out, _ = run_closed(vm, "2>&-", bytecode, stdin_file)
    assert status == plain[0]
    assert out == plain[1]


def test_a_vm_started_with_stdout_closed_fails_to_write_as_before(tmp_path, traced_vm):
    vm = traced_vm[0]
    stdin_file = VM_FIXTURES / "task-stdin.stdin"
    bytecode = compile_fixture(VM_FIXTURES / "task-stdin.agc", tmp_path)
    status, _, err = run_closed(vm, ">&-", bytecode, stdin_file)
    assert status == 1
    assert b"RUNTIME-INTERNAL" in err
