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

# `jit` lines appear when the JIT is on (the default, unless AGENTICA_JIT=off as in make test-jit-off), since `all`
# includes them.
TRACE_LINE = re.compile(
    rb'^agc-trace \+[0-9]+\.[0-9]{6} (sched|io|proc|tls|loader|gc|jit) [a-z_]+'
    rb'( [a-z_]+=([^ ="\\\x00-\x20\x7f]+|"([^"\\\x00-\x1f\x7f]|\\["\\bfnrt]|\\u[0-9a-f]{4})*"))*$')
GC_LINE = re.compile(
    rb"^agc-trace \+[0-9]+\.[0-9]{6} gc collect at=(turn|end) count=[0-9]+ heap=[0-9]+ free=[0-9]+ since=[0-9]+$")
CATEGORY = re.compile(rb"^agc-trace \S+ (\S+)")

# (fixture, stdin sidecar, categories that must show up in the trace)
CASES = [
    ("task-stdin", "task-stdin.stdin", ["loader", "sched", "io"]),
    ("process-streams", None, ["loader", "sched", "io", "proc"]),
    ("files-handles", None, ["loader", "sched", "io"]),
    ("task-file-shared", None, ["loader", "sched", "io"]),
    ("task-fail", None, ["loader", "sched"]),
    ("tls-echo", None, ["loader", "sched", "io", "tls"]),
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


def run_vm(vm, bytecode, settings=None, stdin_file=None, args=(), tmp=None):
    """The VM on `bytecode`; `settings` are extra environment variables; tmp is made fresh and empty."""
    if tmp is not None:
        fresh_directory(tmp)
    env = vm_environment(settings)
    arguments = [*vm, "--", bytecode, *args]
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


def check_case(vm, tmp_path, name, stdin, categories):
    work = tmp_path / ("agentica-trace-%s" % name)
    work.mkdir()
    bytecode = compile_fixture(VM_FIXTURES / (name + ".agc"), work)
    stdin_file = VM_FIXTURES / stdin if stdin else None
    tmp = work / (name + "-tmp")
    args = fixture_args(name, tmp)
    plain = run_vm(vm, bytecode, stdin_file=stdin_file, args=args, tmp=tmp)
    path = work / (name + ".trace")
    traced = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "all", "AGENTICA_VM_TRACE_FILE": path},
                    stdin_file, args, tmp)
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
    jit_path = tmp_path / "profile-jit.trace"
    traced_with_jit = run_vm([*vm, "--jit", "always"], bytecode,
                             {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": jit_path})
    assert traced_with_jit == plain
    jit_lines = trace_lines(jit_path)
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
        assert any(re.match(pattern, line) for line in jit_lines), "%r in %r" % (pattern, jit_lines)


def test_the_profile_names_a_byte_builtin_by_its_catalog_name(tmp_path, traced_vm):
    """Digest.sha256 runs under the key Digest.sha256.bytes; the report shows the catalog name. String.bytes is a
    name of its own and keeps it (on a variable: on a literal, .bytes is a constant and calls nothing)."""
    vm = traced_vm[0]
    source = tmp_path / "digest.agc"
    source.write_text('def main() -> Void\n  text = "abc"\n  puts(Digest.sha256(text.bytes).length)\nend\n')
    bytecode = compile_fixture(source, tmp_path)
    path = tmp_path / "digest.trace"
    plain = run_vm(vm, bytecode)
    assert run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": path}) == plain
    rows = (re.match(rb"^agc-trace \+[0-9.]+ profile builtin calls=1 us=[0-9]+ name=(\S+)$", line)
            for line in trace_lines(path))
    names = {row.group(1) for row in rows if row}
    assert {b"Digest.sha256", b"String.bytes"} <= names, names
    assert not any(name.endswith(b".bytes") and name != b"String.bytes" for name in names), names


def test_the_profile_counts_each_opcode_the_pairs_and_the_paths_of_builtin_calls(tmp_path, traced_vm):
    vm = traced_vm[0]
    source = tmp_path / "ops.agc"
    source.write_text('def main() -> Void\n  total = 0\n  word = "hello"\n  for k in 0...50\n'
                      "    total += word.length\n  end\n  puts(total)\nend\n")
    bytecode = compile_fixture(source, tmp_path)
    path = tmp_path / "ops.trace"
    plain = run_vm(vm, bytecode)
    traced = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": path})
    assert traced == plain
    lines = trace_lines(path)
    prefix = rb"^agc-trace \+[0-9.]+ profile "
    events = [re.match(prefix + rb"events instructions=([0-9]+) reloads=([1-9][0-9]*) builtin_leaf=([0-9]+)"
                       rb" builtin_tail=([0-9]+) builtin_native=([0-9]+)$", line) for line in lines]
    events = [match for match in events if match]
    assert len(events) == 1, lines
    instructions, _, leaf, tail, native = (int(group) for group in events[0].groups())
    # String.length is a leaf builtin, called once per pass; puts takes the generic tail.
    assert (leaf, tail, native) == (50, 1, 0)
    share = rb"([0-9]+\.[0-9]{2})"
    ops = [re.match(prefix + rb"op count=([1-9][0-9]*) share=" + share + rb" name=([a-z-]+)$", line) for line in lines]
    ops = [(int(m.group(1)), float(m.group(2)), m.group(3)) for m in ops if m]
    names = [name for _, _, name in ops]
    assert len(names) == len(set(names)) and b"step" in names
    assert sum(count for count, _, _ in ops) == instructions
    assert [count for count, _, _ in ops] == sorted((count for count, _, _ in ops), reverse=True)
    assert dict((name, count) for count, _, name in ops)[b"call-builtin"] == 51
    assert abs(sum(part for _, part, _ in ops) - 100) < 0.01 * len(ops)
    pairs = [re.match(prefix + rb"pair count=([1-9][0-9]*) share=" + share + rb" first=([a-z-]+) then=([a-z-]+)$",
                      line) for line in lines]
    pairs = [(int(m.group(1)), m.group(3), m.group(4)) for m in pairs if m]
    assert 0 < len(pairs) <= 20
    assert [count for count, _, _ in pairs] == sorted((count for count, _, _ in pairs), reverse=True)
    assert all(first in names and then in names for _, first, then in pairs)
    assert any(then == b"call-builtin" and count >= 50 for count, _, then in pairs), pairs


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


FUSED_TASKS = """def count(id: Int) -> Int
  i = 0
  total = 0
  while i < 600
    total = total + i * id
    i = i + 1
    if i % 50 == 0
      puts("task #{id} at #{i}")
    end
  end
  return total
end

def main() -> Void
  a = Task.spawn(&count, 1)
  b = Task.spawn(&count, 2)
  puts(count(3))
  puts(Task.await(a))
  puts(Task.await(b))
end
"""


def test_a_fused_step_stops_and_yields_where_the_plain_step_of_the_profile_does(tmp_path, traced_vm):
    """The loader fuses most STEPs with the instruction after them, and the profile runs every STEP plain. Three tasks
    share one scheduler, so their turns end on fused STEPs and the order of the lines shows where; each --max-steps
    stop must have the same output, diagnostic and span."""
    vm = traced_vm[0]
    source = tmp_path / "fused.agc"
    source.write_text(FUSED_TASKS)
    bytecode = compile_fixture(source, tmp_path)
    profile = {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": tmp_path / "fused.trace"}
    for limit in sorted({*range(1, 30), *range(1990, 2010), *range(30, 34000, 499)}):
        command = [*vm, "--schedulers", "1", "--json", "--max-steps", str(limit), "--", bytecode]
        plain = vm_run(command, vm_environment())
        assert vm_run(command, vm_environment(profile)) == plain, limit
        if plain[0] == 0:
            break
        assert plain[0] == 1 and json.loads(plain[2])["code"] == "RUNTIME-STEP-LIMIT", limit
    assert limit > 2010
    command = [*vm, "--schedulers", "1", "--", bytecode]
    plain = vm_run(command, vm_environment())
    assert plain[0] == 0 and plain[1].count(b"\n") == 3 * 12 + 3
    assert vm_run(command, vm_environment(profile)) == plain


# The statement at the top of the loop of the program below: `x * 3` and `x / 0` are a CONST and the operator after it.
FUSED_CONST_FAILURES = {
    "RUNTIME-INTEGER-OVERFLOW": "x = x * 3 + 1",
    "RUNTIME-DIVISION-BY-ZERO": "if i == 7\n      x = x / 0\n    end",
}


@pytest.mark.parametrize("code", sorted(FUSED_CONST_FAILURES))
def test_an_operator_after_a_fused_const_fails_where_the_plain_one_of_the_profile_does(tmp_path, traced_vm, code):
    """The loader fuses a CONST with the Int operator or compare after it (and a STEP before the CONST with both), and
    the profile runs them plain. The failure of the operator must have the same output, diagnostic and span."""
    vm = traced_vm[0]
    source = tmp_path / "fused_const.agc"
    source.write_text(f"""def main() -> Void
  x = 1
  i = 0
  while i < 100
    {FUSED_CONST_FAILURES[code]}
    i = i + 1
    if i % 5 == 0
      puts(x)
    end
  end
end
""")
    bytecode = compile_fixture(source, tmp_path)
    profile = {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": tmp_path / "fused_const.trace"}
    command = [*vm, "--json", "--", bytecode]
    plain = vm_run(command, vm_environment())
    assert plain[0] == 1 and json.loads(plain[2])["code"] == code and plain[1]
    assert vm_run(command, vm_environment(profile)) == plain


def test_the_profile_is_not_part_of_all(tmp_path, traced_vm):
    vm = traced_vm[0]
    bytecode = compile_fixture(VM_FIXTURES / "task-fail.agc", tmp_path)
    path = tmp_path / "all.trace"
    run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "all", "AGENTICA_VM_TRACE_FILE": path})
    assert not any(b" profile " in line for line in trace_lines(path))


PROFILED = """def work(n: Int) -> Int
  total = 0
  i = 0
  while i < n
    total += i
    i += 1
  end
  return total
end

def depth(n: Int) -> Int
  return Profile.measure("depth") do
    if n == 0
      return 0
    end
    depth(n - 1) + 1
  end
end

def in_task(n: Int) -> Int
  return Profile.measure("task") do work(n) end
end

def crash(xs: List[Int]) -> Result[Int]
  return Profile.measure("crash") do
    ok(xs[5])
  end
end

def main() -> Void
  before = Profile.steps()
  both = Profile.measure("outer") do
    a = Profile.measure("inner") do work(100) end
    b = Profile.measure("inner") do work(100) end
    a + b
  end
  puts("outer #{Profile.steps() - before} #{both}")
  puts(Profile.measure("wrap") do depth(20) end)
  puts(Task.await(Task.spawn(&in_task, 50)))
  puts(Task.await(Task.spawn(&crash, [1])).ok?)
  3.times do |k|
    puts(Profile.measure("after") do depth(k) end)
  end
end
"""

SECTION = re.compile(rb"^agc-trace \S+ profile section calls=([0-9]+) steps=([0-9]+) us=[0-9]+ gc_ms=[0-9]+ name=(\S+)$")
FOLDED_LINE = re.compile(rb"^[^;\x00-\x1f]+(;[^;\x00-\x1f]+)* [1-9][0-9]*$")


def profiled_bytecode(tmp_path):
    source = tmp_path / "sections.agc"
    source.write_text(PROFILED)
    return compile_fixture(source, tmp_path)


def test_profile_measure_adds_a_section_row_for_each_label(tmp_path, traced_vm):
    """Sections are inclusive: outer holds both inner calls, and a label inside itself counts its calls but its steps
    once, so the recursive depth section has no more steps than the wrap around it. A call that a runtime error ends
    counts as a call with no steps and leaves the next calls of the task right."""
    vm = traced_vm[0]
    bytecode = profiled_bytecode(tmp_path)
    path = tmp_path / "sections.trace"
    plain = run_vm(vm, bytecode)
    traced = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": path})
    assert traced == plain
    assert plain[0] == 0
    sections = {}
    for line in trace_lines(path):
        found = SECTION.match(line)
        if found:
            sections[found.group(3).decode()] = (int(found.group(1)), int(found.group(2)))
    assert set(sections) == {"outer", "inner", "wrap", "depth", "task", "crash", "after"}
    assert sections["outer"][0] == 1 and sections["inner"][0] == 2
    assert sections["inner"][1] < sections["outer"][1]
    measured = int(plain[1].split(b"\n")[0].split()[1])
    assert 0 < measured - sections["outer"][1] < 20, (measured, sections["outer"])
    assert sections["wrap"][0] == 1 and sections["depth"][0] == 21 + 1 + 2 + 3
    assert sections["depth"][1] < sections["wrap"][1] + sections["after"][1]
    assert sections["task"][0] == 1 and sections["task"][1] > 50
    assert sections["crash"] == (1, 0)
    assert sections["after"][0] == 3 and sections["after"][1] > 0


def test_profile_steps_gives_the_same_counts_with_the_profile_off_or_on(tmp_path, traced_vm):
    vm = traced_vm[0]
    source = tmp_path / "steps.agc"
    source.write_text("def main() -> Void\n  a = Profile.steps()\n  10.times do |k|\n    puts(Profile.steps() - a)\n"
                      "  end\n  puts(Profile.measure(\"m\") do Profile.steps() end)\nend\n")
    bytecode = compile_fixture(source, tmp_path)
    plain = run_vm(vm, bytecode)
    report = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": tmp_path / "r.trace"})
    folded = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": tmp_path / "f.trace",
                                   "AGENTICA_PROFILE_FORMAT": "folded", "AGENTICA_PROFILE_SAMPLE": "1"})
    assert plain[0] == 0 and plain[2] == b""
    assert report == plain and folded == plain


def test_the_folded_profile_is_the_same_on_every_run_and_names_each_frame(tmp_path, traced_vm):
    """One line per stack, outermost frame first: functions as name@FILE:LINE, blocks as block@FILE:LINE:COL, native
    loops by their builtin, Profile.measure labels as measure:LABEL. Sampled at every step, the weights add up to the
    steps of the report."""
    vm = traced_vm[0]
    bytecode = profiled_bytecode(tmp_path)
    folded = {"AGENTICA_VM_TRACE": "profile", "AGENTICA_PROFILE_FORMAT": "folded", "AGENTICA_PROFILE_SAMPLE": "1"}
    outputs = []
    for run in range(2):
        path = tmp_path / ("folded-%d.trace" % run)
        assert run_vm(vm, bytecode, {**folded, "AGENTICA_VM_TRACE_FILE": path}) == run_vm(vm, bytecode)
        outputs.append(path.read_bytes())
    assert outputs[0] == outputs[1]
    assert outputs[0].endswith(b"\n")
    lines = outputs[0][:-1].split(b"\n")
    for line in lines:
        assert FOLDED_LINE.match(line), line
    stacks = {line.rsplit(b" ", 1)[0] for line in lines}
    assert len(stacks) == len(lines)
    expected = [
        b"main@sections.agc:30;measure:outer;block@sections.agc:32:35;measure:inner;block@sections.agc:33:34;"
        b"work@sections.agc:1",
        b"main@sections.agc:30;measure:wrap;block@sections.agc:38:32;depth@sections.agc:11;measure:depth;"
        b"block@sections.agc:12:35;depth@sections.agc:11",
        b"in_task@sections.agc:20;measure:task;block@sections.agc:21:34;work@sections.agc:1",
        b"main@sections.agc:30;Int.times;block@sections.agc:41:11;measure:after",
    ]
    for stack in expected:
        assert stack in stacks, (stack, sorted(stacks))
    report = tmp_path / "report.trace"
    run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": report})
    total = re.match(rb"^agc-trace \S+ profile total wall_ms=[0-9]+ steps=([0-9]+) ", trace_lines(report)[0])
    assert sum(int(line.rsplit(b" ", 1)[1]) for line in lines) == int(total.group(1))
    sampled = tmp_path / "sampled.trace"
    run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_PROFILE_FORMAT": "folded",
                          "AGENTICA_PROFILE_SAMPLE": "100", "AGENTICA_VM_TRACE_FILE": sampled})
    weights = [int(line.rsplit(b" ", 1)[1]) for line in trace_lines(sampled)]
    assert weights and all(weight % 100 == 0 for weight in weights)
    assert int(total.group(1)) - 100 < sum(weights) <= int(total.group(1))


def test_the_folded_profile_puts_the_stacks_past_its_limit_on_one_truncated_line(tmp_path, traced_vm):
    """Past the stack limit (lowered by a test switch), the weight of each new stack goes to one last [truncated] line
    and one warning line follows; the weights still add up to the steps of the report."""
    vm = traced_vm[0]
    bytecode = profiled_bytecode(tmp_path)
    path = tmp_path / "truncated.trace"
    settings = {"AGENTICA_VM_TRACE": "profile", "AGENTICA_PROFILE_FORMAT": "folded", "AGENTICA_PROFILE_SAMPLE": "1",
                "AGENTICA_VM_TEST_PROFILE_STACKS": "3", "AGENTICA_VM_TRACE_FILE": path}
    assert run_vm(vm, bytecode, settings) == run_vm(vm, bytecode)
    lines = trace_lines(path)
    assert len(lines) == 5, lines
    assert all(FOLDED_LINE.match(line) for line in lines[:3]), lines
    assert re.match(rb"^\[truncated\] [1-9][0-9]*$", lines[3]), lines[3]
    assert lines[4] == b"agc-trace folded profile full: new stacks weigh on [truncated]; stacks kept 3"
    report = tmp_path / "report.trace"
    run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": report})
    total = re.match(rb"^agc-trace \S+ profile total wall_ms=[0-9]+ steps=([0-9]+) ", trace_lines(report)[0])
    assert sum(int(line.rsplit(b" ", 1)[1]) for line in lines[:4]) == int(total.group(1))


LABELS = """def main() -> Void
  puts(Profile.measure("a;b") do 1 end)
  puts(Profile.measure("a%3Bb") do 2 end)
  puts(Profile.measure("[overflow]") do 3 end)
  total = (0...4100).to_a.map do |i|
    Profile.measure("item #{i}") do i end
  end
  puts(total.size)
end
"""


def test_labels_past_the_section_limit_share_one_overflow_section_and_names_stay_apart(tmp_path, traced_vm):
    """4096 labels keep a section each; the 7 after them count in one [overflow] section, apart from a label of that
    text. In folded stacks ';' and '%' are written as %XX, so labels that differ there never share a line."""
    vm = traced_vm[0]
    source = tmp_path / "labels.agc"
    source.write_text(LABELS)
    bytecode = compile_fixture(source, tmp_path)
    plain = run_vm(vm, bytecode)
    assert plain[0] == 0, plain
    path = tmp_path / "labels.trace"
    assert run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": path}) == plain
    rows = [found.groups() for found in map(SECTION.match, trace_lines(path)) if found]
    overflow = [int(calls) for calls, _, name in rows if name == b"[overflow]"]
    assert overflow == [7, 1], rows[:5]
    assert rows[0][2] == b"[overflow]" and rows[0][0] == b"7"
    folded = tmp_path / "labels.folded"
    run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_PROFILE_FORMAT": "folded",
                          "AGENTICA_PROFILE_SAMPLE": "1", "AGENTICA_VM_TRACE_FILE": folded})
    lines = trace_lines(folded)
    assert all(FOLDED_LINE.match(line) for line in lines), lines
    stacks = [line.rsplit(b" ", 1)[0] for line in lines]
    assert len(set(stacks)) == len(stacks)
    frames = {frame for stack in stacks for frame in stack.split(b";")}
    assert {b"measure:a%3Bb", b"measure:a%253Bb", b"measure:[overflow]", b"measure[overflow]"} <= frames, frames


def test_a_bad_profile_format_or_sample_costs_one_warning_line(tmp_path, traced_vm):
    vm = traced_vm[0]
    bytecode = profiled_bytecode(tmp_path)
    for settings, warning, kept in [
        ({"AGENTICA_PROFILE_FORMAT": "flame"}, rb'^agc-trace unknown profile format "flame"$', rb" profile total "),
        ({"AGENTICA_PROFILE_FORMAT": "folded", "AGENTICA_PROFILE_SAMPLE": "0"},
         rb'^agc-trace AGENTICA_PROFILE_SAMPLE needs 1 to 1000000000 steps, not "0"$', rb";measure:outer;"),
    ]:
        path = tmp_path / "bad.trace"
        if path.exists():
            path.unlink()
        traced = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": path, **settings})
        assert traced == run_vm(vm, bytecode)
        lines = trace_lines(path)
        assert re.match(warning, lines[0]), lines[0]
        assert not any(line.startswith(b"agc-trace") for line in lines[1:] if kept != rb" profile total ")
        assert any(kept in line for line in lines[1:])


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


def test_a_sleep_traces_its_timer_arm_and_fire_under_sched(tmp_path, traced_vm):
    vm = traced_vm[0]
    source = tmp_path / "nap.agc"
    source.write_text("def main() -> Void\n  Task.sleep(1)\n  puts(\"done\")\nend\n", encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "nap.agcb")
    path = tmp_path / "nap.trace"
    status, out, err = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "sched", "AGENTICA_VM_TRACE_FILE": path})
    assert (status, out, err) == (0, b"done\n", b"")
    lines = trace_lines(path)
    arms = [line for line in lines if b" sched timer_arm " in line]
    fires = [line for line in lines if b" sched timer_fire " in line]
    assert len(arms) == 1 and len(fires) == 1, lines
    arm = re.search(rb" sched timer_arm task=([0-9]+) in_ms=([0-9]+)$", arms[0])
    fire = re.search(rb" sched timer_fire task=([0-9]+) late_ms=([0-9]+)$", fires[0])
    assert arm and fire, (arms, fires)
    assert arm.group(1) == fire.group(1)
    assert int(arm.group(2)) <= 1
    assert lines.index(arms[0]) < lines.index(fires[0])


PING_PONG = """\
struct Pair
  ping: Channel[Int]
  pong: Channel[Int]
end

def echo(p: Pair) -> Int
  n = 0
  while n < 200
    v = p.ping.recv(5000).unwrap!
    p.pong.send(v + 1, 5000).unwrap!
    n += 1
  end
  return n
end

def main() -> Void
  p = Pair(ping: Channel.new(1), pong: Channel.new(1))
  worker = Task.spawn(&echo, p)
  total = 0
  for i in 0...200
    p.ping.send(i, 5000).unwrap!
    total += p.pong.recv(5000).unwrap!
  end
  puts("#{total} #{Task.await(worker)}")
  IO.inspect(p.pong.recv(5))
end
"""


def test_a_channel_ping_pong_arms_no_timer_and_a_wait_nobody_ends_arms_one_and_fires(tmp_path, traced_vm):
    # On one scheduler each timed wait of the ping-pong is ended by the peer's next turn, before its clock starts
    # (agc_task_park_within, #629), so no timer is armed and the clock is never read for it. The last recv has no
    # sender: its clock starts when the scheduler goes idle, and its timer fires.
    vm = traced_vm[0]
    source = tmp_path / "ping.agc"
    source.write_text(PING_PONG, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "ping.agcb")
    path = tmp_path / "ping.trace"
    settings = {"AGENTICA_SCHEDULERS": "1", "AGENTICA_VM_TRACE": "sched", "AGENTICA_VM_TRACE_FILE": path}
    status, out, err = run_vm(vm, bytecode, settings)
    assert (status, out, err) == (0, b'20100 200\nerror("channel: timed out")\n', b"")
    lines = trace_lines(path)
    arms = [line for line in lines if b" sched timer_arm " in line]
    fires = [line for line in lines if b" sched timer_fire " in line]
    assert len(arms) == 1 and len(fires) == 1, arms
    arm = re.search(rb" sched timer_arm task=([0-9]+) in_ms=([0-9]+)$", arms[0])
    fire = re.search(rb" sched timer_fire task=([0-9]+) late_ms=([0-9]+)$", fires[0])
    assert arm and fire and arm.group(1) == fire.group(1), (arms, fires)
    assert int(arm.group(2)) <= 5


def test_task_cancel_traces_at_call_on_the_task_it_names_and_a_plain_line_on_a_descendant(tmp_path, traced_vm):
    vm = traced_vm[0]
    source = tmp_path / "stop.agc"
    source.write_text(
        "def leaf(n: Int) -> Void\n  Task.sleep(n)\nend\n\n"
        "def top(ready: Channel[Int]) -> Void\n  Task.spawn(&leaf, 600000)\n  ready.send(1, 5000).unwrap!\n  Task.sleep(600000)\nend\n\n"
        "def main() -> Void\n  ready: Channel[Int] = Channel.new(1)\n  t = Task.spawn(&top, ready)\n"
        "  ready.recv(5000).unwrap!\n  Task.cancel(t)\n  puts(\"done\")\nend\n",
        encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "stop.agcb")
    path = tmp_path / "stop.trace"
    status, out, err = run_vm(vm, bytecode, {"AGENTICA_VM_TRACE": "sched", "AGENTICA_VM_TRACE_FILE": path})
    assert (status, out, err) == (0, b"done\n", b"")
    cancels = [line for line in trace_lines(path) if b" sched cancel task=" in line]
    # `top` sends on `ready` after it spawns `leaf`, so the descendant exists when main cancels. With a sleep instead,
    # main could cancel `top` first: `leaf` was then cancelled at its spawn (` at=spawn`), or never spawned.
    shapes = [re.search(rb" cancel task=([0-9]+)( at=call)?$", line) for line in cancels]
    assert all(shapes), cancels
    assert [shape.groups() for shape in shapes] == [(b"3", None), (b"2", b" at=call")], cancels
