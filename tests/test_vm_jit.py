"""The JIT tier (`--jit`, docs/future/22-jit.md §22) changes no exit code, output, diagnostic, span or step count.

Each program runs with `--jit off`, `on` and `always`, which compiles every eligible function at its first entry. Its
eligible functions (Int loops, compares and jumps only) run the STEPs of their loops in compiled code, so the
`--max-steps` sweep stops inside them, the turns of several tasks end inside them, and their failures leave them.
On an x86-64 host the jit trace must show the functions compiled; elsewhere nothing is compiled and the runs are the
interpreter's, which must still match.
"""
import platform

import pytest

from tests.agentica_test import compile_text, run_vm, vm_environment

X86_64 = platform.machine().lower() in ("x86_64", "amd64")
MODES = ("off", "on", "always")

# spin and same_text are eligible; worker and main call and print, so they stay interpreted. A spin call runs past a
# turn (2000 steps), so the three tasks' turns end inside compiled loops, and the order of the lines shows where.
LONG = "x" * 300
TASKS = """def spin(id: Int, n: Int) -> Int
  i = 0
  total = 0
  while i < n
    total = total + i * id - 3
    if total % 7 == 0 or total > 1000000
      total = total / 3
    end
    i = i + 1
  end
  return total
end

def same_text(a: String, b: String) -> Bool
  return a == b
end

def worker(id: Int) -> Int
  long = "LONG" + "!"
  total = 0
  round = 0
  while round < 6
    total = total + spin(id, 260 + 37 * round)
    if same_text(long, "LONG!") and !same_text(long, "y")
      total = total + 1
    end
    puts("task #{id} round #{round} total #{total}")
    round += 1
  end
  return total
end

def main() -> Void
  a = Task.spawn(&worker, 1)
  b = Task.spawn(&worker, 2)
  puts(worker(3))
  puts(Task.await(a))
  puts(Task.await(b))
  puts("steps #{Profile.steps()}")
end
""".replace("LONG", LONG)

# Failures inside an eligible function, after it printed: the diagnostic, its span and the stack must not depend on
# the tier.
FAILURES = {
    "RUNTIME-INTEGER-OVERFLOW": "x = x * 3 + 1",
    "RUNTIME-DIVISION-BY-ZERO": "x = x / (7 - i)",
}

# A task in a long compiled loop is cancelled between two of its turns.
CANCEL = """def spin(n: Int) -> Int
  i = 0
  while i < n
    i = i + 1
  end
  return i
end

def main() -> Void
  t = Task.spawn(&spin, 1000000000)
  puts(spin(5000))
  Task.cancel(t)
  puts("cancelled")
  puts(Task.await(t))
end
"""


def runs(bytecode, *flags, env=None):
    """{mode: (exit code, stdout, stderr)} of one program in each mode."""
    out = {}
    for mode in MODES:
        result = run_vm(bytecode, "--jit", mode, "--schedulers", "1", *flags, env=vm_environment(env))
        out[mode] = (result.code, result.stdout, result.stderr)
    return out


def assert_same(bytecode, *flags):
    results = runs(bytecode, *flags)
    assert results["on"] == results["off"], flags
    assert results["always"] == results["off"], flags
    return results["off"]


def compiled(bytecode, tmp_path):
    """The functions the jit trace says were compiled in a run with --jit always."""
    trace = tmp_path / "jit.trace"
    trace.unlink(missing_ok=True)
    run_vm(bytecode, "--jit", "always", "--schedulers", "1",
           env=vm_environment({"AGENTICA_VM_TRACE": "jit", "AGENTICA_VM_TRACE_FILE": trace}))
    lines = trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []
    return sorted(line.split("function=")[1].split()[0] for line in lines if " jit compile " in line)


def test_the_max_steps_sweep_of_three_tasks_in_compiled_loops_matches_the_interpreter(tmp_path):
    bytecode = compile_text(TASKS, "tasks", tmp_path)
    assert compiled(bytecode, tmp_path) == (["same_text", "spin"] if X86_64 else [])
    full = assert_same(bytecode)
    assert full[0] == 0 and full[1].count("\n") == 3 * 6 + 4, full
    limits = sorted({*range(1, 25), *range(1990, 2010), *range(25, 200000, 1201)})
    checked = 0
    for limit in limits:
        code, _, stderr = assert_same(bytecode, "--json", "--max-steps", str(limit))
        checked += 1
        if code == 0:
            break
        assert code == 1 and '"RUNTIME-STEP-LIMIT"' in stderr, (limit, stderr)
    assert checked >= 100 and code == 0, (checked, limit)


@pytest.mark.parametrize("code", sorted(FAILURES))
def test_a_failure_in_compiled_code_has_the_interpreters_diagnostic_span_and_stack(tmp_path, code):
    bytecode = compile_text(f"""def grow(start: Int) -> Int
  x = start
  i = 0
  while i < 100
    {FAILURES[code]}
    i = i + 1
  end
  return x
end

def main() -> Void
  puts("before")
  puts(grow(1))
end
""", "failure", tmp_path)
    assert compiled(bytecode, tmp_path) == (["grow"] if X86_64 else [])
    for style in ((), ("--json",), ("--ai",)):
        status, stdout, stderr = assert_same(bytecode, *style)
        assert status == 1 and stdout == "before\n" and code in stderr, (style, stderr)


def test_a_task_cancelled_in_a_compiled_loop_stops_as_in_the_interpreter(tmp_path):
    bytecode = compile_text(CANCEL, "cancel", tmp_path)
    assert compiled(bytecode, tmp_path) == (["spin"] if X86_64 else [])
    status, stdout, stderr = assert_same(bytecode, "--json")
    assert status == 1 and stdout == "5000\ncancelled\n" and "RUNTIME-TASK-CANCELLED" in stderr, stderr


def test_a_bad_jit_mode_is_refused(tmp_path):
    bytecode = compile_text("def main() -> Void\n  puts(1)\nend\n", "plain", tmp_path)
    result = run_vm(bytecode, "--jit", "fast", env=vm_environment())
    assert result.code == 2 and "--jit needs off, on or always" in result.stderr
    result = run_vm(bytecode, env=vm_environment({"AGENTICA_JIT": "fast"}))
    assert result.code == 2 and "AGENTICA_JIT needs off, on or always" in result.stderr
    result = run_vm(bytecode, "--jit", "off", env=vm_environment({"AGENTICA_JIT": "always"}))
    assert (result.code, result.stdout) == (0, "1\n")
