"""The JIT tier (`--jit`, docs/future/22-jit.md §22) changes no exit code, output, diagnostic, span or step count.

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
# compiled code calls in cut fails.
NATIVE_FAILURES = {
    "overflow": ("RUNTIME-INTEGER-OVERFLOW", "if i < 150\n      x = grow(x % 1000)\n    else\n      x = grow(x)\n    end"),
    "depth": ("RUNTIME-STACK-OVERFLOW", "x = x % 1000 + down(i * 80)"),
    "builtin": ("RUNTIME-INVALID-COUNT", "x = x % 1000 + cut(400 - i).length"),
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
    callee = {"depth": "down", "builtin": "cut"}.get(case, "grow")
    assert compiled(bytecode, tmp_path, "on") == (sorted([callee, "main"]) if X86_64 else [])
    for style in ((), ("--json",)):
        status, stdout, stderr = assert_same(bytecode, *style)
        assert status == 1 and stdout == "before\n" and code in stderr, (style, stderr)


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
    assert compiled(bytecode, tmp_path, "on") == (["walk"] if X86_64 else [])
    # Only the two errors leave walk's code: the interpreter runs the `try` that returns them. Under `always` parse is
    # compiled too, and each error leaves both functions' code.
    for mode, want in (("on", ["try count=2"]), ("always", ["try count=4"])):
        lines = jit_trace(bytecode, tmp_path, mode)
        exits = sorted(line.split("exit op=")[1] for line in lines
                       if any(f" jit exit op={op} " in line for op in ("global", "struct", "enum", "try")))
        assert exits == (want if X86_64 else []), (mode, exits)
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
    for style in ((), ("--json",), ("--ai",)):
        status, stdout, stderr = assert_same(bytecode, *style)
        assert status == 1 and stdout == "before\n" and "RUNTIME-DIVISION-BY-ZERO" in stderr, (style, stderr)


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


def test_a_bad_jit_mode_is_refused(tmp_path):
    bytecode = compile_text("def main() -> Void\n  puts(1)\nend\n", "plain", tmp_path)
    result = run_vm(bytecode, "--jit", "fast", env=vm_environment())
    assert result.code == 2 and "--jit needs off, on or always" in result.stderr
    result = run_vm(bytecode, env=vm_environment({"AGENTICA_JIT": "fast"}))
    assert result.code == 2 and "AGENTICA_JIT needs off, on or always" in result.stderr
    result = run_vm(bytecode, "--jit", "off", env=vm_environment({"AGENTICA_JIT": "always"}))
    assert (result.code, result.stdout) == (0, "1\n")
