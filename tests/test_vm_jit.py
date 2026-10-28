"""The JIT tier (`--jit`, docs/vm/05-values-execution-builtins.md §6.4) changes no exit code, output, diagnostic,
span or step count.

Each program runs with `--jit off`, `on` and `always`, which compiles every function at its first entry (`on` only
those with a loop that seldom leaves compiled code, at their 100th entry, and small functions without a loop after
several calls from compiled code). Compiled functions run the STEPs of their
loops in compiled code, so the `--max-steps` sweep stops inside them, the turns of several tasks end inside them (by
steps and by turn cost), their failures leave them, `on` switches to them in the middle of a loop, and four schedulers
compile and run them at once. A call of a compiled function is a native call
in compiled code, and so is a call of a builtin marked direct; a block call
(`map`, `filter`, ...) starts between two runs of compiled code, and its block
runs compiled; other builtins and allocations without code run in the
interpreter, and the code goes on after them.
On an x86-64 host the jit trace must show the functions compiled; elsewhere nothing is compiled and the runs are the
interpreter's, which must still match.
"""
import os
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
    "builtin": ("RUNTIME-INVALID-COUNT", "x = x + items.take(3 - i).size"),
    "key": ("RUNTIME-KEY-NOT-FOUND", "x = x + {0: 1, 2: 3}[i / 19]"),
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
# its loop also calls leaf builtins: List.size, which compiled code calls itself, and Int.bit_xor, which run_compiled
# calls at native depth 0, so with `on` the code leaves for the interpreter only at the RETURN.
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

def thrice(x: Int) -> Int
  return x * 3
end

def noisy(n: Int) -> Int
  k = 0
  while k < n
    puts(thrice(k))
    k += 1
  end
  return k
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
  puts(noisy(150))
end
"""

# fib and down have no loop and are called natively from main's compiled loop and from their own compiled code. down
# goes past the 64 frames a task starts with, so some calls grow the frames through the CALL exit, and its last calls
# go deeper than AGC_JIT_NATIVE_DEPTH (256). The --max-steps sweep stops inside natively called frames.
NATIVE = """def fib(n: Int) -> Int
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end

def down(n: Int) -> Int
  if n == 0
    return 0
  end
  return down(n - 1) + 1
end

def main() -> Void
  total = 0
  i = 0
  while i < 220
    total = total + fib(12) + down(50 + i)
    i += 1
  end
  puts(total)
  puts("steps #{Profile.steps()}")
end
"""

# Failures inside natively called functions, after main's loop is hot: the diagnostic, its span and the stack (each
# caller's pc is the one after its CALL) must not depend on the tier. down passes the call depth limit; a builtin that
# compiled code calls in cut fails, and so does the leaf unwrap! in pick, also when relay's native tail call reached
# pick.
NATIVE_FAILURES = {
    "overflow": ("RUNTIME-INTEGER-OVERFLOW", "if i < 150\n      x = grow(x % 1000)\n    else\n      x = grow(x)\n    end"),
    "depth": ("RUNTIME-STACK-OVERFLOW", "x = x % 1000 + down(i * 80)"),
    "builtin": ("RUNTIME-INVALID-COUNT", "x = x % 1000 + cut(400 - i).length"),
    "leaf": ("RUNTIME-UNWRAP-ERROR", "x = x % 1000 + pick(i)"),
    "tail-leaf": ("RUNTIME-UNWRAP-ERROR", "x = x % 1000 + relay(i)"),
}

# Two tasks whose compiled loops call String, List, Map and Set builtins that compiled code calls itself: they
# allocate and charge turn cost (split, join, upcase, take), so turns end inside those calls as in the interpreter,
# and the order of the lines shows where.
DIRECT = """def tally(words: List[String], rounds: Int) -> Int
  counts: Map[String, Int] = {}
  seen = Set.new(words)
  kept = words.take(0)
  total = 0
  i = 0
  while i < rounds
    word = words[i % words.size]
    counts = counts.put(word, counts.get(word, 0) + 1)
    parts = word.split("-")
    total += parts.join("+").length + word.slice(0, 1).length
    if seen.include?(word.upcase)
      total += 1
    end
    kept = kept.concat(parts).take(40)
    i += 1
  end
  return total + counts.get("b-c-d", 0) + kept.size + counts.size
end

def worker(id: Int) -> Int
  words = "a-b,b-c-d,E,f-g-h-i,j-k".split(",")
  total = 0
  round = 0
  while round < 3
    total += tally(words, 3000 * id)
    puts("task #{id} round #{round} total #{total}")
    round += 1
  end
  puts("task #{id} steps #{Profile.steps()}")
  return total
end

def main() -> Void
  x = Task.spawn(&worker, 1)
  y = Task.spawn(&worker, 2)
  puts(Task.await(x) + Task.await(y))
end
"""


# Two tasks whose compiled loop reads a Map by key (MAP_GET) and builds list literals (LIST), which have code of their
# own, so `on` compiles lookup. The 256 KiB key charges more turn cost than a turn has steps each time it is hashed,
# so turns end right after a read in compiled code, as in the interpreter, and the order of the lines shows where.
LOOKUP = """def doubled(times: Int) -> String
  s = "k"
  k = 0
  while k < times
    s = s + s
    k += 1
  end
  return s
end

def lookup(table: Map[String, Int], keys: List[String], rounds: Int) -> Int
  total = 0
  i = 0
  while i < rounds
    pair = [keys[i % keys.size], keys[(i + 1) % keys.size]]
    empty: List[Int] = []
    total = total + table[pair[0]] - table[pair[1]] + pair.size + empty.size
    i += 1
  end
  return total
end

def worker(id: Int) -> Int
  big = doubled(18)
  keys = ["a", "b", "c"]
  if id == 2
    keys = ["a", big, "b"]
  end
  table = {"a": 1, "b": 20, "c": 300, big: 4000}
  total = 0
  round = 0
  while round < 3
    total += lookup(table, keys, 400 * id)
    puts("task #{id} round #{round} total #{total}")
    round += 1
  end
  puts("task #{id} steps #{Profile.steps()}")
  return total
end

def main() -> Void
  x = Task.spawn(&worker, 1)
  y = Task.spawn(&worker, 2)
  puts(Task.await(x) + Task.await(y))
end
"""

# Two tasks whose compiled loop makes closures that capture values (shift, bias) and passes them to filter, map,
# reduce and any?, which compiled code starts itself; the blocks run in compiled code. Each call of a block charges
# turn cost, so turns end inside the block calls (and resume in the block's code), as in the interpreter, and the order
# of the lines shows where.
BLOCKS = """def sweep(items: List[Int], rounds: Int, bias: Int) -> Int
  total = 0
  i = 0
  while i < rounds
    shift = i % 7
    kept = items.filter do |x| (x + shift) % 3 == 0 end
    total = (total + kept.map do |x| x * bias + shift end.reduce(0) do |acc, x| (acc + x) % 1000003 end) % 1000003
    if items.any? do |x| x == shift + 900 end
      total += 1
    end
    i += 1
  end
  return total
end

def worker(id: Int) -> Int
  items: List[Int] = []
  n = 0
  while n < 500 * id
    items = items.push(n * 7 % 1009)
    n += 1
  end
  total = 0
  round = 0
  while round < 3
    total += sweep(items, 10 * id, id)
    puts("task #{id} round #{round} total #{total}")
    round += 1
  end
  puts("task #{id} steps #{Profile.steps()}")
  return total
end

def main() -> Void
  x = Task.spawn(&worker, 1)
  y = Task.spawn(&worker, 2)
  puts(Task.await(x) + Task.await(y))
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


def assert_same_failure(bytecode, code, *stack):
    """Every tier prints "before", then fails with CODE, its span and stack the same in plain, --json and --ai
    output; the functions of STACK, innermost first, come in that order."""
    for style in ((), ("--json",), ("--ai",)):
        status, stdout, stderr = assert_same(bytecode, *style)
        assert status == 1 and stdout == "before\n" and code in stderr, (style, stderr)
        at = [stderr.index(name) for name in stack]
        assert at == sorted(at), (style, stderr)


def assert_step_limits_stop_alike(bytecode, steps):
    """The lowest limits, nine spread over the run and STEPS - 1 stop every tier with RUNTIME-STEP-LIMIT."""
    for limit in (*range(1, 12), *range(steps // 9, steps, steps // 9), steps - 1):
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


def tail_call_exits(bytecode, tmp_path, mode):
    """(TAIL_CALL exits, those whose callee had code) in a run with --jit MODE: a tail call of a function with code is
    native, so the second count stays 0 unless the register file has to grow."""
    for line in jit_trace(bytecode, tmp_path, mode):
        if " jit transition op=tail-call " in line:
            fields = dict(field.split("=") for field in line.split(" jit transition op=tail-call ")[1].split())
            return int(fields["count"]), int(fields["compiled"])
    return 0, 0


def assert_compiled_without_exits(bytecode, tmp_path, want, forbidden):
    """With `on` and `always`, the functions of WANT[mode] are compiled (none off x86-64), and no exit to the turn loop
    is at an opcode that FORBIDDEN(op) holds for."""
    for mode in ("on", "always"):
        lines = jit_trace(bytecode, tmp_path, mode)
        names = sorted(line.split("function=")[1].split()[0] for line in lines if " jit compile " in line)
        assert names == (want[mode] if X86_64 else []), (mode, names)
        exits = [line for line in lines if " jit exit op=" in line and forbidden(line.split("op=")[1].split()[0])]
        assert exits == [], (mode, exits)


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


def test_on_compiles_a_function_without_a_loop_only_for_compiled_callers(tmp_path):
    bytecode = compile_text(LOOP_FREE, "loop_free", tmp_path)
    # twice is called from main's compiled loop; thrice only from noisy, whose loop prints, so both stay interpreted.
    assert compiled(bytecode, tmp_path, "on") == (["main", "spin", "twice"] if X86_64 else [])
    assert compiled(bytecode, tmp_path, "always") == (["main", "noisy", "spin", "thrice", "twice"] if X86_64 else [])
    skips = [line for line in jit_trace(bytecode, tmp_path, "on") if " jit skip function=" in line]
    assert skips == [] if not X86_64 else [line.split("skip ")[1] for line in skips] == ["function=noisy loop=exits"]
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout.count("\n") == 152, stderr


def test_on_compiles_a_function_without_a_loop_only_after_several_calls_from_compiled_code(tmp_path):
    # main's loop compiles; hot is then called from it 300 times, rare 6 times (fewer than the 16 calls that make a
    # function without a loop hot), so only hot gets code. always compiles all three.
    bytecode = compile_text("""def hot(x: Int) -> Int
  return x + 1
end

def rare(x: Int) -> Int
  return x * 2
end

def main() -> Void
  total = 0
  i = 0
  while i < 400
    total = total + hot(i)
    if i % 50 == 0
      total = total + rare(i)
    end
    i += 1
  end
  puts(total)
end
""", "callee_threshold", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["hot", "main"] if X86_64 else [])
    assert compiled(bytecode, tmp_path, "always") == (["hot", "main", "rare"] if X86_64 else [])
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout == "83000\n", (stdout, stderr)


@pytest.mark.parametrize("passes", [3, 40])
def test_on_compiles_a_long_loop_body_only_after_enough_passes(tmp_path, passes):
    # Each pass of main's loop returns into it from 60 calls: 180 entries in 3 passes are not enough, since only an
    # entry at or before the previous one is a pass; 40 passes are (it compiles at the 32nd).
    calls = "".join(f"    acc = (acc + f{k}(i)) % 1000003\n" for k in range(60))
    functions = "".join(f"def f{k}(x: Int) -> Int\n  return x + {k}\nend\n\n" for k in range(60))
    bytecode = compile_text(functions + f"""def main() -> Void
  acc = 0
  i = 0
  while i < {passes}
{calls}    i += 1
  end
  puts(acc)
end
""", "passes", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["main"] if X86_64 and passes == 40 else [])
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout == f"{sum(i * 60 + 1770 for i in range(passes))}\n", (stdout, stderr)


def test_on_settles_a_call_chain_whose_last_callee_leaves(tmp_path):
    # f0 calls f1 ... f13, which prints: no function of the chain may get code, whatever the order of the functions in
    # the file, so main's loop leaves at each call and nothing is compiled.
    chain = "".join(f"def f{k}(x: Int) -> Int\n  return f{k + 1}(x + 1) + 1\nend\n\n" for k in range(13))
    chain += "def f13(x: Int) -> Int\n  if x == 0 - 5\n    puts(x)\n  end\n  return x\nend\n\n"
    chain += "def main() -> Void\n  t = 0\n  i = 0\n  while i < 3000\n    t = t + f0(i)\n    i += 1\n  end\n  puts(t)\nend\n"
    bytecode = compile_text(chain, "chain", tmp_path)
    lines = jit_trace(bytecode, tmp_path, "on")
    assert [line for line in lines if " jit compile " in line or " jit transition " in line] == []
    skips = sorted(line.split("skip ")[1] for line in lines if " jit skip " in line)
    assert skips == (sorted([f"function=f{k} loop=none" for k in range(14)] + ["function=main loop=exits"])
                     if X86_64 else []), skips
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout == "4576500\n", (stdout, stderr)


@pytest.mark.parametrize("calls", [0, 3000])
def test_on_runs_the_jit_turn_loop_only_in_sampled_turns_until_code_is_published(tmp_path, calls):
    # main's first loop leaves at its two maps, so only pad may get code. Uncalled, it leaves the run in the plain turn
    # loop but for the turns drawn at random, one in 16 (AGC_JIT_SAMPLE) on average of the steps / 2000 turns (bounded
    # here at twice that). Called 3000 times, the turns that start in it run the jit copy, which compiles it, and from
    # then on every turn does: at least the whole turns of the second loop's steps.
    bytecode = compile_text(f"""def pad(n: Int, width: Int) -> String
  text = n.to_s
  while text.length < width
    text = "0#{{text}}"
  end
  return text
end

def main() -> Void
  total = 0
  i = 0
  while i < 20000
    total = total + {{"k": i}}.size * {{"j": i}}.size
    i += 1
  end
  first = Profile.steps()
  k = 0
  while k < {calls}
    total = total + pad(k, 6).length
    k += 1
  end
  puts(total)
  puts(first)
  puts(Profile.steps())
end
""", "plain_until_live", tmp_path)
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout.split("\n")[0] == f"{20000 + 6 * calls}", (stdout, stderr)
    first, total = int(stdout.split("\n")[1]), int(stdout.split("\n")[2])
    all_turns = total // 2000 + 1
    lines = jit_trace(bytecode, tmp_path, "on")
    turns = [int(line.split("count=")[1]) for line in lines if " jit turn count=" in line]
    assert compiled(bytecode, tmp_path, "on") == (["pad"] if X86_64 and calls else [])
    if X86_64 and not calls:
        assert len(turns) == 1 and 0 < turns[0] <= all_turns // 8 + 1, (turns, all_turns)
    elif X86_64:
        assert len(turns) == 1 and turns[0] >= (total - first) // 2000, (turns, first, total)
    else:
        assert turns == []


MID_TURN_WORK = """def work(n: Int) -> Int
  s = 0
  i = 0
  while i < n
    s = s + i % 7
    i += 1
  end
  return s
end

"""
MID_TURN = {
    # main's loop parks at each pass, and a map keeps it out, so every turn starts in main and work returns before it
    # ends.
    "park": (MID_TURN_WORK + """def main() -> Void
  total = 0
  k = 0
  while k < 3000
    Task.sleep(0)
    total = total + {"k": k}.size * work(120)
    k += 1
  end
  puts(total)
end
""", f"{3000 * sum(i % 7 for i in range(120))}\n"),
    # Each task runs job, a function without a loop, and ends within its turn, so no turn starts in work.
    "spawn": (MID_TURN_WORK + """def job(n: Int) -> Int
  return work(n) + work(n) + work(n)
end

def main() -> Void
  tasks: List[Task[Int]] = []
  k = 0
  while k < 1500
    tasks = tasks.push(Task.spawn(&job, 45))
    k += 1
  end
  total = 0
  for t in tasks
    total = total + Task.await(t)
  end
  puts(total)
end
""", f"{1500 * 3 * sum(i % 7 for i in range(45))}\n"),
    # main and echo take turns (a ping-pong): every second turn is echo's, and work runs only inside main's. The random
    # sample of the JIT still lands on main's turns; a sample of every 16th turn landed only on echo's.
    "ping_pong": ("""struct Pipes
  ping: Channel[Int]
  pong: Channel[Int]
end

""" + MID_TURN_WORK + """def echo(p: Pipes) -> Int
  seen: Map[Int, Int] = {}
  while true
    case p.ping.recv(5000)
      ok(n) ->
        seen = seen.put(n % 2, n)
        try_send(p.pong, n)
      error(_) ->
        return seen.size
    end
  end
  return 0
end

def try_send(c: Channel[Int], n: Int) -> Void
  case c.send(n, 5000)
    ok(_) -> nil
    error(_) -> nil
  end
end

def main() -> Void
  ping: Channel[Int] = Channel.new(1)
  pong: Channel[Int] = Channel.new(1)
  t = Task.spawn(&echo, Pipes(ping: ping, pong: pong))
  total = 0
  k = 0
  while k < 3000
    try_send(ping, k)
    case pong.recv(5000)
      ok(n) -> total = total + {"k": n}.size * work(120)
      error(_) -> nil
    end
    k += 1
  end
  ping.close
  puts(total)
  puts(Task.await(t))
end
""", f"{3000 * sum(i % 7 for i in range(120))}\n2\n"),
}


@pytest.mark.parametrize("case", sorted(MID_TURN))
def test_on_compiles_a_hot_function_that_runs_only_inside_turns(tmp_path, case):
    # No turn starts with work on the stack; the turns that the JIT samples count its entries, so it still compiles.
    # One scheduler draws the same samples in each run, and each case runs at least twice the passes it needs.
    source, expected = MID_TURN[case]
    bytecode = compile_text(source, f"mid_turn_{case}", tmp_path)
    assert ("work" in compiled(bytecode, tmp_path, "on")) == X86_64
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout == expected, (stdout, stderr)


def test_compiled_code_calls_compiled_functions_natively(tmp_path):
    bytecode = compile_text(NATIVE, "native", tmp_path)
    for mode in ("on", "always"):
        assert compiled(bytecode, tmp_path, mode) == (["down", "fib", "main"] if X86_64 else [])
    full = assert_same(bytecode)
    assert full[0] == 0 and full[1].startswith("66770\n"), full
    steps = int(full[1].split("steps ")[1])
    assert_max_steps_sweep(bytecode, steps)
    # Of the 137,390 calls of fib and down and their returns, about a sixth leave compiled code: the calls that grow
    # the frames or pass the native depth, and the returns of the frames whose native calls an exit unwound (each turn
    # that ends inside them, as the turn loop holds no native call). Shallow calls stay native; a deep recursion
    # returns through one exit per frame after each such unwind.
    lines = jit_trace(bytecode, tmp_path, "always")
    transitions = sum(int(line.split("count=")[1]) for line in lines if " jit transition count=" in line)
    assert transitions < (30000 if X86_64 else 1), transitions


@pytest.mark.parametrize("case", sorted(NATIVE_FAILURES))
def test_a_failure_in_a_natively_called_function_matches_the_interpreter(tmp_path, case):
    code, statement = NATIVE_FAILURES[case]
    bytecode = compile_text(f"""def grow(x: Int) -> Int
  return x * 3 + 1
end

def cut(n: Int) -> String
  return "a,b,c".split(",").take(n).join("-")
end

def down(n: Int) -> Int
  if n == 0
    return 0
  end
  return down(n - 1) + 1
end

def pick(n: Int) -> Int
  r = ok(n)
  if n > 400
    r = error("stop")
  end
  return r.unwrap! + 1
end

def relay(n: Int) -> Int
  return pick(n + 1)
end

def main() -> Void
  puts("before")
  x = 1
  i = 0
  while i < 1000
    {statement}
    i += 1
  end
  puts(x)
end
""", "native_failure", tmp_path)
    callees = {"depth": ["down"], "builtin": ["cut"], "leaf": ["pick"], "tail-leaf": ["pick", "relay"]}
    callees = callees.get(case, ["grow"])
    assert compiled(bytecode, tmp_path, "on") == (sorted([*callees, "main"]) if X86_64 else [])
    for style in ((), ("--json",)):
        status, stdout, stderr = assert_same(bytecode, *style)
        assert status == 1 and stdout == "before\n" and code in stderr, (style, stderr)


# measure has no loop and calls only leaf builtins (ok, ok?, unwrap!, List.size, List.append, String.length), ping
# and pong tail-call each other with leaf builtins (Int.bit_and, Int.bit_xor, Int.shift_right), and map's block calls
# measure. Compiled code calls a leaf builtin itself below a native call, so `on` gives all of them code, the native
# calls below a leaf stay on the C stack, and their RETURNs take no exit. The turns of the two tasks end inside these
# calls.
LEAVES = """def measure(xs: List[Int], word: String) -> Int
  r = ok(xs.size + word.length)
  if r.ok?
    return r.unwrap! + xs.append(word.length).size
  end
  return 0
end

def ping(n: Int, acc: Int) -> Int
  if n == 0
    return acc
  end
  return pong(n - 1, acc + n.bit_and(3))
end

def pong(n: Int, acc: Int) -> Int
  if n == 0
    return acc
  end
  return ping(n - 1, acc + n.bit_xor(5).shift_right(1))
end

def work(id: Int) -> Int
  xs = [1, 2, 3]
  words = ["a", "bb", "ccc", "dddd"]
  total = 0
  i = 0
  while i < 4000
    total += measure(xs, words[i % 4])
    total += ping(i % 24 + id, 0)
    total += words.map do |w| measure(xs, w) + w.length end.sum
    if i % 1000 == 0
      puts("#{id} #{i} #{total}")
    end
    i += 1
  end
  return total
end

def main() -> Void
  t = Task.spawn(&work, 2)
  puts(work(1))
  puts(Task.await(t))
  puts("steps #{Profile.steps()}")
end
"""


def test_leaf_builtins_run_in_compiled_code_without_leaving(tmp_path):
    bytecode = compile_text(LEAVES, "leaves", tmp_path)
    code, stdout, _ = assert_same(bytecode)
    assert code == 0 and stdout.startswith("1 0 57\n2 0 60\n") and "\n368072\n385056\n" in stdout, stdout
    on = compiled(bytecode, tmp_path, "on")
    want = ["measure", "ping", "pong", "work"]
    assert all(name in on for name in want) if X86_64 else on == [], on
    for mode in ("on", "always"):
        lines = jit_trace(bytecode, tmp_path, mode)
        counts = {line.split(" jit ")[1].split()[0]: int(line.split("count=")[1]) for line in lines
                  if " jit block count=" in line or " jit transition count=" in line or " jit leaf count=" in line}
        blocks, transitions = counts.get("block", 0), counts.get("transition", 0)
        # About one transition per block call (its last RETURN, 8,000 calls, a few interpreted before the block has
        # code), not one per leaf below a native call. Of the half a million leaf calls, only those at native depth 0
        # of the builtins that can fail take an exit (a frame that goes on after its native calls were unwound, as
        # when a turn ended in them).
        assert counts.get("leaf", 0) < 50000, (mode, counts)
        assert (blocks >= 7000 and transitions < blocks * 3 // 2) if X86_64 else blocks == transitions == 0, \
            (mode, counts)
    steps = int(stdout.split("steps ")[1])
    assert_max_steps_sweep(bytecode, steps)


def test_fields_lists_enums_results_and_floats_run_in_compiled_code(tmp_path):
    bytecode = compile_text(READS, "reads", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["scan"] if X86_64 else [])
    lines = jit_trace(bytecode, tmp_path, "on")
    exits = sorted(line.split("exit op=")[1] for line in lines if " jit exit op=" in line)
    leaves = [int(line.split("count=")[1]) for line in lines if " jit leaf count=" in line]
    assert exits == [], exits
    assert len(leaves) == (1 if X86_64 else 0) and all(n > 2000 for n in leaves), leaves
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout.startswith("33750.0\n"), (stdout, stderr)
    steps = int(stdout.split("steps ")[1])
    assert_max_steps_sweep(bytecode, steps)


# walk's loop reads module constants (GLOBAL), builds structs and enums and unwraps Results with `try`, all in
# compiled code, so `on` compiles it (before, these instructions left it every few instructions). Twice a `try` meets
# an error: in the second call of walk, which main reads with `ok?`, and in the last call, at round 2500, which check
# unwraps, so the run fails with check and main on the stack.
VALUES = """WEIGHTS = [3, 1, 4, 1, 5]
ORIGIN = Point(x: 2, y: -1)

struct Point
  x: Int
  y: Int
end

enum Step
  Stay
  Move(Int, Int)
end

def parse(text: String, bias: Int) -> Result[Int]
  n = try text.to_i
  return ok(n + bias)
end

def walk(words: List[String], rounds: Int, fail_at: Int) -> Result[Int]
  total = 0
  i = 0
  while i < rounds
    p = Point(x: i % 7, y: WEIGHTS[i % WEIGHTS.size])
    step = Step.Stay
    if i % 3 == 0
      step = Step.Move(p.x, p.y + ORIGIN.y)
    end
    case step
      Step.Stay -> total += 1
      Step.Move(dx, dy) -> total += dx * dy
    end
    text = words[i % words.size]
    if i == fail_at
      text = "x#{i}"
    end
    total += try parse(text, ORIGIN.x)
    i += 1
  end
  return ok(total)
end

def check(rounds: Int, fail_at: Int) -> Int
  return walk(["1", "22", "333"], rounds, fail_at).unwrap!
end

def main() -> Void
  puts(check(3000, -1))
  puts(walk(["4", "5"], 2000, 1500).ok?)
  puts("steps #{Profile.steps()}")
  puts(check(3000, 2500))
end
"""


def test_globals_structs_enums_and_try_run_in_compiled_code(tmp_path):
    bytecode = compile_text(VALUES, "values", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["parse", "walk"] if X86_64 else [])
    # Only the two errors leave the code: the interpreter runs the `try` that returns them. parse is compiled too (its
    # `ok` is a leaf builtin that compiled code calls), and each error leaves both functions' code.
    for mode in ("on", "always"):
        lines = jit_trace(bytecode, tmp_path, mode)
        exits = sorted(line.split("exit op=")[1] for line in lines
                       if any(f" jit exit op={op} " in line for op in ("global", "struct", "enum", "try")))
        assert exits == (["try count=4"] if X86_64 else []), (mode, exits)
    for style in ((), ("--json",), ("--ai",)):
        status, stdout, stderr = assert_same(bytecode, *style)
        assert status == 1 and stdout.startswith("369396\nfalse\n"), (style, stdout)
        # The diagnostic, its span and the stack are the interpreter's (assert_same); the stack holds check, then main.
        assert "RUNTIME-UNWRAP-ERROR" in stderr and stderr.index("check") < stderr.index("main"), (style, stderr)
    assert_max_steps_sweep(bytecode, int(stdout.split("steps ")[1].split()[0]))


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


# Two tasks whose loop stays in compiled code under `on` and `always`: (program, the functions `on` compiles, the first
# naming the program, the opcodes of the exits they must not take, fewer than this many of them). DIRECT: only main and
# worker call builtins that leave (Task, puts), so the 243,000 builtin calls in the 27,000 passes of tally's loop stay
# in compiled code, where one leaves only when it ends a turn. LOOKUP: no map read or list literal of lookup's loop
# leaves. BLOCKS: no closure or block call of sweep's loop leaves (its 360 block calls start between two runs of
# compiled code, and their blocks, compiled at the first call, run there too); under `always` the calls of puts and
# Task in main and worker do.
SWEEP_BLOCKS = ["block@sweep.agc:6:25", "block@sweep.agc:7:31", "block@sweep.agc:7:69", "block@sweep.agc:8:19"]
STAYS = {
    "builtins": (DIRECT, ["tally"], ("call-builtin",), 20),
    "map reads and lists": (LOOKUP, ["lookup"], ("map-get", "list"), 1),
    "blocks": (BLOCKS, ["sweep", *SWEEP_BLOCKS], ("closure", "call-builtin"), 20),
}


@pytest.mark.parametrize("case", sorted(STAYS))
def test_compiled_loops_run_builtins_map_reads_lists_and_blocks_without_leaving(tmp_path, case):
    source, functions, ops, most = STAYS[case]
    bytecode = compile_text(source, functions[0], tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (sorted(functions) if X86_64 else [])
    full = assert_same(bytecode)
    assert full[0] == 0 and full[1].count("\n") == 9, full
    for mode in ("on", "always"):
        lines = jit_trace(bytecode, tmp_path, mode)
        exits = sum(int(line.split("count=")[1]) for line in lines for op in ops if f" jit exit op={op} " in line)
        assert exits < (most if X86_64 else 1), (mode, exits)
    # Limits below the two tasks' steps stop the run inside the loop, in either task.
    steps = sum(int(line.split("steps ")[1]) for line in full[1].splitlines() if " steps " in line)
    for limit in range(steps // 20, steps * 19 // 20, steps // 15):
        code, _, stderr = assert_same(bytecode, "--json", "--max-steps", str(limit))
        assert code == 1 and '"RUNTIME-STEP-LIMIT"' in stderr, (limit, stderr)


def test_a_failure_inside_a_compiled_block_matches_the_interpreter(tmp_path):
    # The block fails at the 300th pass of main's compiled loop, inside the native frame of map: the diagnostic, its
    # span (in the block) and the stack (main, map, the block) must not depend on the tier.
    bytecode = compile_text("""def main() -> Void
  puts("before")
  total = 0
  i = 0
  while i < 1000
    total += [i, i + 1, i + 2].map do |v| v * 3 / (300 - i) end.size
    i += 1
  end
  puts(total)
end
""", "block_failure", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["block@block_failure.agc:6:36", "main"] if X86_64 else [])
    assert_same_failure(bytecode, "RUNTIME-DIVISION-BY-ZERO")


def test_a_task_cancelled_inside_a_long_block_call_stops_as_in_the_interpreter(tmp_path):
    # The spawned task's compiled loop runs a filter over a long list: the turns end inside the block calls, and the
    # cancel lands there, between two of its turns.
    bytecode = compile_text("""def scan(rounds: Int) -> Int
  items: List[Int] = []
  n = 0
  while n < 20000
    items = items.push(n)
    n += 1
  end
  total = 0
  r = 0
  while r < rounds
    total += items.filter do |x| (x + r) % 5 == 0 end.size
    r += 1
  end
  return total
end

def main() -> Void
  t = Task.spawn(&scan, 1000000)
  puts(scan(3))
  Task.cancel(t)
  puts("cancelled")
  puts(Task.await(t))
end
""", "block_cancel", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["block@block_cancel.agc:11:27", "scan"] if X86_64 else [])
    status, stdout, stderr = assert_same(bytecode, "--json")
    assert status == 1 and stdout == "12000\ncancelled\n" and "RUNTIME-TASK-CANCELLED" in stderr, stderr


# Two tasks whose compiled loop (work) makes block calls of every kind over 300 items: map, filter, reduce, any? and
# all? (both stop early), each, sort_by, a named function as the block, times, upto, downto and each of a Range, with
# captured values. A compiled block that returns while its call has items left starts over in place, so only the last
# item of each call (or the one that stops it) leaves compiled code. The turns of the two tasks end inside these
# calls, and the order of the lines shows where.
BLOCK_KINDS = """def triple(x: Int) -> Int
  return x * 3
end

def work(id: Int) -> Int
  rounds = 30
  items = (0...300).to_a
  total = 0
  r = 0
  while r < rounds
    bias = r + id
    total += items.map do |x| x + bias end.sum % 1000
    total += items.filter do |x| (x + bias) % 3 == 0 end.size
    total += items.reduce(0) do |acc, x| (acc + x * bias) % 100003 end
    if items.any? do |x| x == bias % 300 end
      total += 1
    end
    if items.all? do |x| x < 250 end
      total += 1
    end
    total += items.map(&triple).sum % 1000
    total += items.sort_by do |x| (x * 7 + bias) % 300 end.first
    items.each do |x| x + bias end
    300.times do |i| i + bias end
    3.upto(200) do |i| i - bias end
    200.downto(3) do |i| i * bias end
    (0...300).each do |i| i + bias end
    if r % 10 == 0
      puts("#{id} #{r} #{total}")
    end
    r += 1
  end
  return total
end

def main() -> Void
  t = Task.spawn(&work, 2)
  puts(work(1))
  puts(Task.await(t))
  puts("steps #{Profile.steps()}")
end
"""


def test_block_calls_of_every_kind_start_their_block_again_in_compiled_code(tmp_path):
    bytecode = compile_text(BLOCK_KINDS, "block_kinds", tmp_path)
    code, stdout, _ = assert_same(bytecode)
    assert code == 0 and stdout.count("\n") == 9, stdout
    for mode in ("on", "always"):
        lines = jit_trace(bytecode, tmp_path, mode)
        counts = {line.split(" jit ")[1].split()[0]: int(line.split("count=")[1]) for line in lines
                  if " jit block count=" in line or " jit transition count=" in line}
        blocks, transitions = counts.get("block", 0), counts.get("transition", 0)
        # One RETURN exit for each block call (and a few calls of work and main), not one for each item.
        assert (blocks > 300 and transitions < 2 * blocks) if X86_64 else blocks == transitions == 0, (mode, counts)
    steps = int(stdout.split("steps ")[1])
    assert_max_steps_sweep(bytecode, steps)


# map's block is &f, which tail-calls g (a loop long enough to end turns, compiled under `on`), which tail-calls f
# again: the block's frame reaches f's RETURN by a native tail call, so f's code runs in a frame that run_compiled
# entered for g's. That RETURN must take the RETURN exit, not start the block again in place.
TAIL_BLOCK = """def g(x: Int) -> Int
  i = 0
  s = 0
  while i < 700
    s = (s + i * x) % 1000003
    i += 1
  end
  return f(x - 1 + s * 0)
end

def f(x: Int) -> Int
  if x > 0
    return g(x)
  end
  a = x
  i = 0
  while i < 3
    a = (a * 3 + i) % 1000003
    a = (a * 5 + i) % 1000003
    a = (a * 7 + i) % 1000003
    a = (a * 11 + i) % 1000003
    a = (a * 13 + i) % 1000003
    a = (a * 17 + i) % 1000003
    a = (a * 19 + i) % 1000003
    a = (a * 23 + i) % 1000003
    i += 1
  end
  return a + 1
end

def main() -> Void
  total = 0
  r = 0
  while r < 300
    xs = [1, 0, 0, 0].map(&f)
    total = (total + xs[3] + xs[0]) % 1000003
    r += 1
  end
  puts(total)
  puts([2, 0, 1].map(&f))
  puts("steps #{Profile.steps()}")
end
"""


@pytest.mark.parametrize("schedulers", (1, 4))
def test_a_block_that_returns_after_a_native_tail_call_matches_the_interpreter(tmp_path, schedulers):
    bytecode = compile_text(TAIL_BLOCK, "tail_block", tmp_path)
    code, stdout, _ = assert_same(bytecode, schedulers=schedulers)
    assert code == 0 and stdout.count("\n") == 3, stdout


# Two tasks whose compiled loop (drive) calls step, which tail-calls count_down (self tail calls that copy a struct of
# five fields with `with`, each copy charging turn cost), noisy (a loop that prints, which `on` never compiles: a tail
# call into a function without code) or calls is_even (mutual tail calls). With `on`, count_down's self tail call is
# its loop, and step, is_even and is_odd have no loop and get code only from compiled code; a tail call of a function
# with code stays in compiled code. Task 1's last round and main's is_even make a million tail calls each, far past the
# depth limit of 10,000 frames if a tail call kept its frame. The order of the lines shows where the turns end.
TAIL = """struct State
  n: Int
  total: Int
  odd: Int
  even: Int
  last: Int
end

def count_down(s: State) -> Int
  if s.n == 0
    return s.total + s.odd - s.even + s.last
  end
  if s.n % 2 == 0
    return count_down(s.with(n: s.n - 1, total: (s.total + s.n % 7) % 1000003, even: s.even + 1))
  end
  return count_down(s.with(n: s.n - 1, total: (s.total + s.n % 7) % 1000003, odd: s.odd + 1, last: s.n))
end

def is_even(n: Int) -> Bool
  if n == 0
    return true
  end
  return is_odd(n - 1)
end

def is_odd(n: Int) -> Bool
  if n == 0
    return false
  end
  return is_even(n - 1)
end

def noisy(id: Int, r: Int) -> Int
  i = 0
  while i < 2
    puts("task #{id} noisy #{r} #{i}")
    i += 1
  end
  return r
end

def step(id: Int, r: Int) -> Int
  if r % 50 == 7
    return noisy(id, r)
  end
  if r == 299 and id == 1
    return count_down(State(n: 1000001, total: r, odd: 0, even: 0, last: 0))
  end
  if r % 2 == 0
    return count_down(State(n: r * 10 + id, total: r, odd: 0, even: 0, last: 0))
  end
  if is_even(r * 31 + id)
    return 1
  end
  return 2
end

def drive(id: Int) -> Int
  total = 0
  r = 0
  while r < 300
    total = (total + step(id, r)) % 1000003
    if r % 100 == 99
      puts("task #{id} round #{r} total #{total}")
    end
    r += 1
  end
  return total
end

def main() -> Void
  x = Task.spawn(&drive, 1)
  y = Task.spawn(&drive, 2)
  puts(Task.await(x) + Task.await(y))
  puts(is_even(1000001))
  puts("steps #{Profile.steps()}")
end
"""


def test_tail_calls_and_struct_updates_run_in_compiled_code_without_growing_the_stack(tmp_path):
    bytecode = compile_text(TAIL, "tail", tmp_path)
    assert_compiled_without_exits(bytecode, tmp_path, {
        "on": ["count_down", "drive", "is_even", "is_odd", "step"],
        "always": ["count_down", "drive", "is_even", "is_odd", "main", "noisy", "step"],
    }, lambda op: op in ("tail-call", "struct-with"))
    # The tail calls that leave are those of noisy, which `on` never compiles, and the first of each callee, before
    # its compile; of the 2.6 million, none whose callee has code.
    for mode in ("on", "always"):
        exits, with_code = tail_call_exits(bytecode, tmp_path, mode)
        assert exits < 20 and with_code == 0, (mode, exits, with_code)
    for style in ((), ("--json",)):
        code, stdout, stderr = assert_same(bytecode, *style)
        assert code == 0 and stdout.count("\n") == 2 * 3 + 2 * 6 * 2 + 3, (style, stdout, stderr)
        assert "\nfalse\nsteps " in stdout, stdout
    assert_step_limits_stop_alike(bytecode, int(stdout.split("steps ")[1]))


def test_a_failure_after_many_compiled_tail_calls_matches_the_interpreter(tmp_path):
    # fall divides by zero in compiled code at the end of a million tail calls: the diagnostic, its span and the stack
    # (fall after a tail call, drive, main) are the interpreter's.
    bytecode = compile_text("""def fall(n: Int, acc: Int) -> Int
  if n == 0
    return 1000 / acc
  end
  return fall(n - 1, acc - 1)
end

def drive(rounds: Int) -> Int
  total = 0
  r = 0
  while r < rounds
    total += fall(r % 50, r % 50 + 1)
    r += 1
  end
  return total + fall(1000000, 1000000)
end

def main() -> Void
  puts("before")
  puts(drive(300))
end
""", "tail_failure", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["drive", "fall"] if X86_64 else [])
    for mode in ("on", "always"):
        assert tail_call_exits(bytecode, tmp_path, mode) == (0, 0), mode
    assert_same_failure(bytecode, "RUNTIME-DIVISION-BY-ZERO", "fall", "drive", "main")


def test_a_task_cancelled_in_a_long_compiled_tail_call_loop_stops_as_in_the_interpreter(tmp_path):
    # The spawned task's loop reaches a chain of a billion tail calls in compiled code; main's own loop runs meanwhile,
    # and its cancel lands between two turns of the chain.
    bytecode = compile_text("""def chain(n: Int, acc: Int) -> Int
  if n == 0
    return acc
  end
  return chain(n - 1, (acc + n) % 1000003)
end

def churn(rounds: Int) -> Int
  total = 0
  r = 0
  while r < rounds
    n = 10
    if r >= 150
      n = 1000000000
    end
    total = (total + chain(n, r)) % 1000003
    r += 1
  end
  return total
end

def warm(rounds: Int) -> Int
  total = 0
  r = 0
  while r < rounds
    total = (total + chain(10, r)) % 1000003
    r += 1
  end
  return total
end

def main() -> Void
  t = Task.spawn(&churn, 1000000)
  puts(warm(400))
  Task.cancel(t)
  puts("cancelled")
  puts(Task.await(t))
end
""", "tail_cancel", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["chain", "churn", "warm"] if X86_64 else [])
    for mode in ("on", "always"):
        assert tail_call_exits(bytecode, tmp_path, mode) == (0, 0), mode
    status, stdout, stderr = assert_same(bytecode, "--json")
    assert status == 1 and stdout.endswith("\ncancelled\n") and "RUNTIME-TASK-CANCELLED" in stderr, stderr


def test_a_self_tail_call_is_a_loop_that_on_compiles(tmp_path):
    # main has no loop and chain's only loop is its self tail call, which `on` counts as a loop: chain compiles at its
    # entries and its million tail calls run as a jump in its code. is_even and is_odd tail-call each other a million
    # times; with `always` that stays in their code too. No tail call of a function with code leaves.
    bytecode = compile_text("""def chain(n: Int, acc: Int) -> Int
  if n == 0
    return acc
  end
  return chain(n - 1, (acc + n) % 1000003)
end

def is_even(n: Int) -> Bool
  if n == 0
    return true
  end
  return is_odd(n - 1)
end

def is_odd(n: Int) -> Bool
  if n == 0
    return false
  end
  return is_even(n - 1)
end

def main() -> Void
  puts(chain(1000000, 0))
  puts(is_even(1000001))
  puts("steps #{Profile.steps()}")
end
""", "self_tail", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (["chain"] if X86_64 else [])
    assert compiled(bytecode, tmp_path, "always") == (["chain", "is_even", "is_odd", "main"] if X86_64 else [])
    assert tail_call_exits(bytecode, tmp_path, "on")[1] == 0
    assert tail_call_exits(bytecode, tmp_path, "always") == ((1, 0) if X86_64 else (0, 0))
    code, stdout, stderr = assert_same(bytecode)
    assert code == 0 and stdout.startswith(f"{sum(range(1000001)) % 1000003}\nfalse\nsteps "), (stdout, stderr)
    assert_max_steps_sweep(bytecode, int(stdout.split("steps ")[1]))


def test_on_stops_compiling_once_the_compile_budget_is_spent(tmp_path):
    """A budget that fits only the first hot function: the others stay interpreted, the output is the interpreter's.

    The budget comes from a run without one (that compile's instructions plus the 32 units each compile takes), so it
    follows the lowering. AGENTICA_VM_TEST_JIT_BUDGET is the test-only way to make the budget small.
    """
    bytecode = compile_text("""def spin(n: Int, k: Int) -> Int
  i = 0
  total = 0
  while i < n
    total = total + i * k
    i = i + 1
  end
  return total
end

def twirl(n: Int) -> Int
  i = 0
  total = 0
  while i < n
    total = total + i % 5
    i = i + 1
  end
  return total
end

def main() -> Void
  sum = 0
  r = 0
  while r < 300
    sum = sum + spin(20, r) + twirl(20)
    r += 1
  end
  puts(sum)
  puts("steps #{Profile.steps()}")
end
""", "budget", tmp_path)
    lines = jit_trace(bytecode, tmp_path, "on")
    compiles = [line for line in lines if " jit compile " in line]
    assert len(compiles) >= (2 if X86_64 else 0) and not any(" jit budget " in line for line in lines), lines
    first = compiles[0].split("function=")[1].split()[0] if X86_64 else None
    budget = int(compiles[0].split("instructions=")[1].split()[0]) + 32 if X86_64 else 1
    trace = tmp_path / "budget.trace"
    env = {"AGENTICA_VM_TEST_JIT_BUDGET": budget, "AGENTICA_VM_TRACE": "jit", "AGENTICA_VM_TRACE_FILE": trace}
    result = run_vm(bytecode, "--jit", "on", "--schedulers", "1", env=vm_environment(env))
    off = run_vm(bytecode, "--jit", "off", "--schedulers", "1", env=vm_environment())
    assert (result.code, result.stdout, result.stderr) == (off.code, off.stdout, off.stderr)
    assert off.code == 0 and off.stdout.count("\n") == 2, off.stderr
    lines = trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []
    compiled_functions = [line.split("function=")[1].split()[0] for line in lines if " jit compile " in line]
    assert compiled_functions == ([first] if X86_64 else []), lines
    spent = [line.split(" jit ")[1] for line in lines if " jit budget " in line]
    if X86_64:
        assert len(spent) == 1 and spent[0].startswith("budget spent=work ") and f" work={budget} " in spent[0], spent
    else:
        assert spent == [], spent


# Two tasks whose compiled loop (sweep) calls function values: the worker's block, which captures `shift`, `&triple`
# from a struct field, and every 1000 rounds `&deep`, which calls itself through a function value 300 deep (past the
# native depth of compiled code, so the frames grow on the way down), and `&noisy`, a loop that prints, which `on`
# never compiles: a call into a function without code. With `on`, the block, triple and deep have no loop and get
# code only from compiled code. The order of the lines shows where the turns end.
CALL_VALUE = """struct Rule
  name: String
  apply: Fn[Int, Int]
end

def triple(x: Int) -> Int
  return x * 3
end

def deep(n: Int) -> Int
  if n == 0
    return 0
  end
  hop = &deep
  return hop.call(n - 1) + 1
end

def noisy(x: Int) -> Int
  i = 0
  while i < 1
    puts("noisy #{x}")
    i += 1
  end
  return x
end

def sweep(id: Int, rounds: Int, f: Fn[Int, Int]) -> Int
  rule = Rule(name: "triple", apply: &triple)
  say = &noisy
  down = &deep
  total = 0
  r = 0
  while r < rounds
    total = (total + f.call(r) + rule.apply.call(r)) % 1000003
    if r % 1000 == 999
      total = (total + down.call(300 + id) + say.call(id * 100000 + r)) % 1000003
    end
    r += 1
  end
  return total
end

def worker(id: Int) -> Int
  shift = id * 7
  total = sweep(id, 6000) do |x| (x + shift) % 1000 end
  puts("worker #{id} total #{total}")
  return total
end

def main() -> Void
  x = Task.spawn(&worker, 1)
  y = Task.spawn(&worker, 2)
  puts(Task.await(x) + Task.await(y))
  puts("steps #{Profile.steps()}")
end
"""


def test_calls_of_function_values_run_in_compiled_code(tmp_path):
    bytecode = compile_text(CALL_VALUE, "call_value", tmp_path)
    # Only the prints and the tasks' builtins leave compiled code for the turn loop.
    assert_compiled_without_exits(bytecode, tmp_path, {
        "on": ["block@call_value.agc:45:27", "deep", "sweep", "triple"],
        "always": ["block@call_value.agc:45:27", "deep", "main", "noisy", "sweep", "triple", "worker"],
    }, lambda op: op != "call-builtin")
    for style in ((), ("--json",)):
        code, stdout, stderr = assert_same(bytecode, *style)
        assert code == 0 and stdout.count("\n") == 2 * 6 + 2 + 2, (style, stdout, stderr)
    assert_step_limits_stop_alike(bytecode, int(stdout.split("steps ")[1]))


# A function value called from a compiled loop fails at the 700th pass: a block divides by zero, or `&deep` passes the
# depth limit of 10,000 frames through calls of function values. The diagnostic, its span and the stack are the
# interpreter's.
CALL_VALUE_FAILURES = {
    "block": ("""def sweep(rounds: Int, f: Fn[Int, Int]) -> Int
  total = 0
  r = 0
  while r < rounds
    total += f.call(r)
    r += 1
  end
  return total
end

def main() -> Void
  puts("before")
  puts(sweep(1000) do |x| 1000 / (x - 700) end)
end
""", "RUNTIME-DIVISION-BY-ZERO", ["block@call_value_block.agc:13:20", "sweep"], ("sweep", "main")),
    "depth": ("""def deep(n: Int) -> Int
  if n == 0
    return 0
  end
  hop = &deep
  return hop.call(n - 1) + 1
end

def sweep(rounds: Int) -> Int
  down = &deep
  total = 0
  r = 0
  while r < rounds
    n = 3
    if r == 700
      n = 20000
    end
    total += down.call(n)
    r += 1
  end
  return total
end

def main() -> Void
  puts("before")
  puts(sweep(1000))
end
""", "RUNTIME-STACK-OVERFLOW", ["deep", "sweep"], ("deep", "sweep", "main")),
}


@pytest.mark.parametrize("case", sorted(CALL_VALUE_FAILURES))
def test_a_failure_in_a_called_function_value_matches_the_interpreter(tmp_path, case):
    source, code, functions, stack = CALL_VALUE_FAILURES[case]
    bytecode = compile_text(source, f"call_value_{case}", tmp_path)
    assert compiled(bytecode, tmp_path, "on") == (functions if X86_64 else [])
    assert_same_failure(bytecode, code, *stack)


def test_a_task_cancelled_in_a_long_loop_of_function_value_calls_stops_as_in_the_interpreter(tmp_path):
    # The spawned task's compiled loop calls a block a billion times; main's own loop runs meanwhile, and its cancel
    # lands between two turns of the spawned one, inside the block or the loop.
    bytecode = compile_text("""def spin(rounds: Int, f: Fn[Int, Int]) -> Int
  total = 0
  r = 0
  while r < rounds
    total = (total + f.call(r)) % 1000003
    r += 1
  end
  return total
end

def churn(rounds: Int) -> Int
  return spin(rounds) do |x| x % 7 end
end

def main() -> Void
  t = Task.spawn(&churn, 1000000000)
  puts(spin(300000) do |x| x % 5 end)
  Task.cancel(t)
  puts("cancelled")
  puts(Task.await(t))
end
""", "call_value_cancel", tmp_path)
    want = ["block@call_value_cancel.agc:12:23", "block@call_value_cancel.agc:17:21", "spin"]
    assert compiled(bytecode, tmp_path, "on") == (want if X86_64 else [])
    status, stdout, stderr = assert_same(bytecode, "--json")
    assert status == 1 and stdout.endswith("\ncancelled\n") and "RUNTIME-TASK-CANCELLED" in stderr, stderr


def test_a_bad_jit_mode_is_refused(tmp_path):
    bytecode = compile_text("def main() -> Void\n  puts(1)\nend\n", "plain", tmp_path)
    result = run_vm(bytecode, "--jit", "fast", env=vm_environment())
    assert result.code == 2 and "--jit needs off, on or always" in result.stderr
    result = run_vm(bytecode, env=vm_environment({"AGENTICA_JIT": "fast"}))
    assert result.code == 2 and "AGENTICA_JIT needs off, on or always" in result.stderr
    result = run_vm(bytecode, "--jit", "off", env=vm_environment({"AGENTICA_JIT": "always"}))
    assert (result.code, result.stdout) == (0, "1\n")


def test_the_jit_mode_of_the_environment_reaches_the_vm(tmp_path):
    """The canary of make test-jit-on: no --jit flag, so only AGENTICA_JIT decides whether this hot loop is compiled.

    If the variable stopped reaching the VMs, the soak would run the interpreter and pass without proving anything.
    """
    bytecode = compile_text(THRESHOLD, "threshold-env", tmp_path)
    trace = tmp_path / "env.trace"
    run_vm(bytecode, env=vm_environment({"AGENTICA_VM_TRACE": "jit", "AGENTICA_VM_TRACE_FILE": trace}))
    lines = trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []
    functions = sorted(line.split("function=")[1].split()[0] for line in lines if " jit compile " in line)
    jit_on = os.environ.get("AGENTICA_JIT", "off") in ("on", "always")
    assert ("spin" in functions) == (X86_64 and jit_on), (os.environ.get("AGENTICA_JIT"), functions)
