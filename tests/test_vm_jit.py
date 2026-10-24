"""The JIT tier (`--jit`, docs/future/22-jit.md §22) changes no exit code, output, diagnostic, span or step count.

Each program runs with `--jit off`, `on` and `always`, which compiles every function at its first entry (`on` only
those with a loop that seldom leaves compiled code, at their 100th entry). Compiled functions run the STEPs of their
loops in compiled code, so the `--max-steps` sweep stops inside them, the turns of several tasks end inside them (by
steps and by turn cost), their failures leave them, `on` switches to them in the middle of a loop, and four schedulers
compile and run them at once. Calls and returns use compiled frame-transition
exits; builtins and allocations without code run in the interpreter, and the
code goes on after them.
On an x86-64 host the jit trace must show the functions compiled; elsewhere nothing is compiled and the runs are the
interpreter's, which must still match.
"""
import platform

import pytest

from tests.agentica_test import compile_text, run_vm, vm_environment

X86_64 = platform.machine().lower() in ("x86_64", "amd64")
MODES = ("off", "on", "always")

# worker and main call and print, which leave compiled code for the interpreter. A spin call runs past a turn (2000
# steps), so the three tasks' turns end inside compiled loops, and the order of the lines shows where.
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

# Failures inside a compiled loop, after the program printed: the diagnostic, its span (the message of an index names
# the list's length and the index) and the stack must not depend on the tier.
FAILURES = {
    "overflow": ("RUNTIME-INTEGER-OVERFLOW", "x = x * 3 + 1"),
    "division": ("RUNTIME-DIVISION-BY-ZERO", "x = x / (7 - i)"),
    "float division": ("RUNTIME-DIVISION-BY-ZERO", "x = x + (1.0 / (7.0 - i.to_f)).to_i!"),
    "index": ("RUNTIME-INDEX-OUT-OF-RANGE", "x = x + items[i / 19]"),
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


# spin is called 96 times, below the threshold of `on` (100 entries), and its last call runs for many turns: the
# turns that start inside its loop are entries too, so `on` compiles it at one of them and enters the code at
# frame->pc, in the middle of the loop, through the entry table.
THRESHOLD = """def spin(n: Int) -> Int
  i = 0
  total = 0
  while i < n
    total = total + i % 7
    i = i + 1
  end
  return total
end

def main() -> Void
  sum = 0
  k = 0
  while k < 95
    sum = sum + spin(5)
    k += 1
  end
  puts(sum)
  puts(spin(40000))
  puts("steps #{Profile.steps()}")
end
"""

# Six tasks on four schedulers call spin 150 times each, from worker's loop, so `on` compiles both while several
# schedulers run them, and `always` compiles them on several schedulers at once.
SCHEDULERS = """def spin(id: Int, n: Int) -> Int
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

def worker(id: Int) -> Int
  total = 0
  round = 0
  while round < 150
    total = total + spin(id, 50 + round)
    round += 1
  end
  return total
end

def main() -> Void
  a = Task.spawn(&worker, 1)
  b = Task.spawn(&worker, 2)
  c = Task.spawn(&worker, 3)
  d = Task.spawn(&worker, 4)
  e = Task.spawn(&worker, 5)
  puts(worker(6))
  puts("#{Task.await(a)} #{Task.await(b)} #{Task.await(c)} #{Task.await(d)} #{Task.await(e)}")
end
"""

# Each compare of two 256 KiB Strings in the eligible `same` charges more turn cost than a turn has steps, so the
# turn ends right after it, in compiled code as in the interpreter. Task 1 compares once a round, task 2 five times,
# so the order of their lines shows where each turn ended.
COST = """def same(a: String, b: String, n: Int) -> Int
  i = 0
  hits = 0
  while i < n
    if a == b
      hits = hits + 1
    end
    i = i + 1
  end
  return hits
end

def doubled(times: Int) -> String
  s = "x"
  k = 0
  while k < times
    s = s + s
    k += 1
  end
  return s
end

def worker(id: Int) -> Int
  n = 4 * id - 3
  a = doubled(18)
  b = doubled(18)
  total = 0
  round = 0
  while round < 4
    total = total + same(a, b, n)
    puts("task #{id} round #{round} hits #{total}")
    round += 1
  end
  return total
end

def main() -> Void
  x = Task.spawn(&worker, 1)
  y = Task.spawn(&worker, 2)
  puts(Task.await(x) + Task.await(y))
end
"""


# scan reads fields, list items, enum variants and payloads, Results and Floats (a NaN among them) in compiled code;
# the only instructions of its loop without code are leaf builtins (List.size, Int.bit_xor), which run_compiled calls
# itself, so with `on` the code leaves for the interpreter only at the RETURN.
READS = """struct Point
  x: Int
  y: Float
end

enum Shape
  Dot
  Box(Int, Int)
end

def scan(points: List[Point], shapes: List[Shape], results: List[Result[Int]], rounds: Int) -> Float
  total = 0.0
  count = 0
  nan = Float.from_bits(9221120237041090560)
  round = 0
  while round < rounds
    i = 0
    while i < points.size
      p = points[i]
      if not (p.y < nan) and p.y <= 2.5
        total = total + p.y * 2.0 - -p.y / 4.0
      end
      case shapes[i % shapes.size]
        Shape.Dot -> count = count + 1
        Shape.Box(w, h) -> count = count + w * h
      end
      case results[i % results.size]
        ok(v) -> count = count + v
        error(_) -> count = count - 1
      end
      count = count + p.x + i.bit_xor(3)
      i = i + 1
    end
    round = round + 1
  end
  return total + count.to_f
end

def main() -> Void
  points = [Point(x: 1, y: 0.5), Point(x: 2, y: 3.25), Point(x: -3, y: 1.0 / 3.0)]
  shapes = [Shape.Dot, Shape.Box(2, 3)]
  results: List[Result[Int]] = [ok(4), error("no"), ok(-2)]
  puts(scan(points, shapes, results, 2000))
  puts("steps #{Profile.steps()}")
end
"""

# label's loop builds Strings in compiled code (TO_TEXT and CONCAT have code of their own), so `on` compiles it;
# `always` compiles it too.
DENSE = """def label(n: Int) -> Int
  total = 0
  i = 0
  while i < n
    total = total + "<#{i}>".size
    i = i + 1
  end
  return total
end

def main() -> Void
  puts(label(30000))
end
"""


# twice has no loop, so `on` keeps it in the interpreter however often it runs: each entry would run two instructions
# in compiled code and pay for the entry, the exit and the RETURN in the interpreter. `always` compiles it.
LOOP_FREE = """def twice(x: Int) -> Int
  return x + x
end

def spin(n: Int) -> Int
  i = 0
  total = 0
  while i < n
    total = total + i % 7
    i = i + 1
  end
  return total
end

def main() -> Void
  sum = 0
  k = 0
  while k < 300
    sum = twice(sum % 1000) + spin(k)
    k += 1
  end
  puts(sum)
end
"""


# build joins Strings in a loop (each join charges its bytes, so turns end by cost in compiled code as in the
# interpreter); main prints the text form of every tag through TO_TEXT. The joins stay in compiled code under `on`,
# so build compiles there; main has no loop and compiles only under `always`.
STRINGS = """struct Point
  x: Int
  y: Float
end

enum Shape
  Dot
  Box(Int, Int)
end

def build(n: Int) -> String
  s = ""
  i = 0
  while i < n
    s = s + "<#{i}>;"
    i = i + 1
  end
  return s
end

def main() -> Void
  puts(build(2000).size)
  puts(42.to_s)
  puts(1.5.to_s)
  puts(true.to_s)
  puts(nil.to_s)
  puts("hi".to_s)
  puts((1..3).to_s)
  puts((1...3).to_s)
  puts([1, 2, 3].to_s)
  puts(ok(7).to_s)
  r: Result[Int] = error("no")
  puts(r.to_s)
  puts(Point(x: 1, y: 0.5).to_s)
  puts(Shape.Dot.to_s)
  puts(Shape.Box(2, 3).to_s)
  puts({"a": 1, "b": 2}.to_s)
  case JSON.parse("{\\"a\\":[1,true]}")
    ok(j) -> puts(j.to_s)
    error(e) -> puts("parse failed")
  end
  puts("steps #{Profile.steps()}")
end
"""


def runs(bytecode, *flags, env=None, schedulers=1):
    """{mode: (exit code, stdout, stderr)} of one program in each mode."""
    out = {}
    for mode in MODES:
        result = run_vm(bytecode, "--jit", mode, "--schedulers", str(schedulers), *flags, env=vm_environment(env))
        out[mode] = (result.code, result.stdout, result.stderr)
    return out


def assert_same(bytecode, *flags, schedulers=1):
    results = runs(bytecode, *flags, schedulers=schedulers)
    assert results["on"] == results["off"], flags
    assert results["always"] == results["off"], flags
    return results["off"]


def assert_max_steps_sweep(bytecode, steps):
    """Limits below STEPS stop every tier with RUNTIME-STEP-LIMIT."""
    for limit in (steps // 3, steps // 2 + 7, steps - 1):
        code, _, stderr = assert_same(bytecode, "--json", "--max-steps", str(limit))
        assert code == 1 and '"RUNTIME-STEP-LIMIT"' in stderr, (limit, stderr)


def jit_trace(bytecode, tmp_path, mode):
    """The jit trace lines of a run with --jit MODE."""
    trace = tmp_path / "jit.trace"
    trace.unlink(missing_ok=True)
    run_vm(bytecode, "--jit", mode, "--schedulers", "1",
           env=vm_environment({"AGENTICA_VM_TRACE": "jit", "AGENTICA_VM_TRACE_FILE": trace}))
    return trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []


def compiled(bytecode, tmp_path, mode="always"):
    """The functions the jit trace says were compiled in a run with --jit MODE."""
    lines = jit_trace(bytecode, tmp_path, mode)
    return sorted(line.split("function=")[1].split()[0] for line in lines if " jit compile " in line)


def test_recursive_compiled_calls_match_the_interpreter_across_frame_growth(tmp_path):
    bytecode = compile_text("""def descend(n: Int) -> Int
  if n == 0
    return 42
  end
  return descend(n - 1) + 1
end

def main() -> Void
  values = [1, 2].map do |n| descend(180) + n end
  puts(values[0] + values[1])
end
""", "call-bridge", tmp_path)
    for style in ((), ("--json",), ("--max-steps", "10000")):
        code, stdout, _ = assert_same(bytecode, *style)
        assert code == 0 and stdout == "447\n", (style, stdout)
    lines = jit_trace(bytecode, tmp_path, "always")
    compiled_functions = sorted(line.split("function=")[1].split()[0] for line in lines if " jit compile " in line)
    assert compiled_functions == (["block@call-bridge.agc:9:23", "descend", "main"] if X86_64 else [])
    transitions = [line for line in lines if " jit exit op=call " in line or " jit exit op=return " in line]
    assert transitions == [], transitions


def test_the_max_steps_sweep_of_three_tasks_in_compiled_loops_matches_the_interpreter(tmp_path):
    bytecode = compile_text(TASKS, "tasks", tmp_path)
    assert compiled(bytecode, tmp_path) == (["main", "same_text", "spin", "worker"] if X86_64 else [])
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


@pytest.mark.parametrize("case", sorted(FAILURES))
def test_a_failure_in_compiled_code_has_the_interpreters_diagnostic_span_and_stack(tmp_path, case):
    code, statement = FAILURES[case]
    bytecode = compile_text(f"""def grow(start: Int) -> Int
  x = start
  items = [1, 2, 3, 4, 5]
  i = 0
  while i < 100
    {statement}
    i = i + 1
  end
  return x + items.size
end

def main() -> Void
  puts("before")
  puts(grow(1))
end
""", "failure", tmp_path)
    assert compiled(bytecode, tmp_path) == (["grow", "main"] if X86_64 else [])
    for style in ((), ("--json",), ("--ai",)):
        status, stdout, stderr = assert_same(bytecode, *style)
        assert status == 1 and stdout == "before\n" and code in stderr, (style, stderr)


def test_a_task_cancelled_in_a_compiled_loop_stops_as_in_the_interpreter(tmp_path):
    bytecode = compile_text(CANCEL, "cancel", tmp_path)
    assert compiled(bytecode, tmp_path) == (["main", "spin"] if X86_64 else [])
    status, stdout, stderr = assert_same(bytecode, "--json")
    assert status == 1 and stdout == "5000\ncancelled\n" and "RUNTIME-TASK-CANCELLED" in stderr, stderr


def test_on_compiles_a_function_at_a_turn_that_starts_in_its_loop(tmp_path):
    bytecode = compile_text(THRESHOLD, "threshold", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["spin"] if X86_64 else [])
    full = assert_same(bytecode)
    assert full[0] == 0 and full[1].count("\n") == 3, full
    steps = int(full[1].split("steps ")[1])
    for limit in (*range(steps - 3000, steps + 1, 211), steps - 1, steps):
        code, _, stderr = assert_same(bytecode, "--json", "--max-steps", str(limit))
        assert code == (0 if limit >= steps else 1), (limit, stderr)


def test_several_schedulers_compile_and_run_one_function_as_the_interpreter(tmp_path):
    bytecode = compile_text(SCHEDULERS, "schedulers", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["spin", "worker"] if X86_64 else [])
    for _ in range(3):
        code, stdout, stderr = assert_same(bytecode, schedulers=4)
        assert code == 0 and stdout.count("\n") == 2, stderr


def test_a_turn_that_ends_by_cost_in_compiled_code_ends_where_the_interpreters_does(tmp_path):
    bytecode = compile_text(COST, "cost", tmp_path)
    assert compiled(bytecode, tmp_path) == (["doubled", "main", "same", "worker"] if X86_64 else [])
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout.endswith("\n24\n"), (stdout, stderr)


def test_on_keeps_a_hot_function_without_a_loop_in_the_interpreter(tmp_path):
    bytecode = compile_text(LOOP_FREE, "loop_free", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["spin"] if X86_64 else [])
    assert compiled(bytecode, tmp_path, "always") == (["main", "spin", "twice"] if X86_64 else [])
    skips = [line for line in jit_trace(bytecode, tmp_path, "on") if " jit skip function=twice " in line]
    assert len(skips) == (1 if X86_64 else 0) and all(line.endswith(" loop=none") for line in skips), skips
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout.count("\n") == 1, stderr


def test_fields_lists_enums_results_and_floats_run_in_compiled_code(tmp_path):
    bytecode = compile_text(READS, "reads", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["scan"] if X86_64 else [])
    lines = jit_trace(bytecode, tmp_path, "on")
    exits = sorted(line.split("exit op=")[1] for line in lines if " jit exit op=" in line)
    leaves = [int(line.split("count=")[1]) for line in lines if " jit leaf count=" in line]
    assert exits == [], exits
    assert len(leaves) == (1 if X86_64 else 0) and all(n > 10000 for n in leaves), leaves
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout.startswith("33750.0\n"), (stdout, stderr)
    steps = int(stdout.split("steps ")[1])
    assert_max_steps_sweep(bytecode, steps)


def test_on_compiles_a_loop_that_builds_strings_in_compiled_code(tmp_path):
    bytecode = compile_text(DENSE, "dense", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["label"] if X86_64 else [])
    skips = [line for line in jit_trace(bytecode, tmp_path, "on") if " jit skip function=main " in line]
    assert len(skips) == (1 if X86_64 else 0) and all(line.endswith(" loop=none") for line in skips), skips
    assert compiled(bytecode, tmp_path, "always") == (["label", "main"] if X86_64 else [])
    code, stdout, stderr = assert_same(bytecode)
    assert (code, stdout) == (0, "198890\n"), (stdout, stderr)


def test_string_joins_and_forms_run_in_compiled_code(tmp_path):
    bytecode = compile_text(STRINGS, "strings", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["build"] if X86_64 else [])
    assert compiled(bytecode, tmp_path, "always") == (["build", "main"] if X86_64 else [])
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0, stderr
    assert stdout.split("\n")[:16] == ["12890", "42", "1.5", "true", "nil", "hi", "1..3", "1...3",
                                         "[1, 2, 3]", "ok(7)", 'error("no")', "Point(x: 1, y: 0.5)",
                                         "Shape.Dot", "Shape.Box(2, 3)", '{"a": 1, "b": 2}',
                                         '{"a":[1,true]}'], stdout
    steps = int(stdout.split("steps ")[1])
    assert_max_steps_sweep(bytecode, steps)
    code, _, stderr = assert_same(bytecode, "--json", "--max-steps", str(steps + 100))
    assert code == 0, stderr


def test_a_bad_jit_mode_is_refused(tmp_path):
    bytecode = compile_text("def main() -> Void\n  puts(1)\nend\n", "plain", tmp_path)
    result = run_vm(bytecode, "--jit", "fast", env=vm_environment())
    assert result.code == 2 and "--jit needs off, on or always" in result.stderr
    result = run_vm(bytecode, env=vm_environment({"AGENTICA_JIT": "fast"}))
    assert result.code == 2 and "AGENTICA_JIT needs off, on or always" in result.stderr
    result = run_vm(bytecode, "--jit", "off", env=vm_environment({"AGENTICA_JIT": "always"}))
    assert (result.code, result.stdout) == (0, "1\n")
