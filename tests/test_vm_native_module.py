"""Native modules (the `extern module "NAME"` blocks of docs/grammar/05-syntax.md, #1149) through the product CLI.

The module is tests/fixtures/native/module_demo.c, built with the system C compiler into a shared library that links
nothing of the VM (-Wl,-z,defs proves it on Linux). Each case runs a program whose block declares functions of the
module's table; outputs are written out here, and failures assert the code and the line, never the message
(AGENTS.md). A module opens its library through the loader of the extern blocks, so it runs where they do.
"""
import re
import struct

import pytest

from tests.agentica_test import TARGET_OS
from tests.test_vm_native import NATIVE_CALLS, agentica, diagnostic, literal, program, shared_library

TYPES = """struct Point
  x: Int
  y: Int
end

enum Shape
  Dot
  Circle(Int)
  Rect(Point, Point)
end

extern "LIBRARY"
  callback Twice(n: C.Int32) -> C.Int32
  def demo_keep(f: Twice) -> Void
  def demo_call_kept(n: C.Int32) -> C.Int32
end

"""

MODULE = """extern module "LIBRARY"
  def add(a: Int, b: Int) -> Int
  def upcase(text: String) -> String
  def reverse(data: Bytes) -> Bytes
  def sum(items: List[Int]) -> Int
  def range(n: Int) -> List[Int]
  def row(n: Int) -> Map[String, Int]
  def pairs(map: Map[String, Int]) -> List[String]
  def lookup(map: Map[String, Int], key: String) -> Optional[Int]
  def parse(text: String) -> Result[Int]
  def unwrap(result: Result[Int]) -> Int
  def truthy?(flag: Bool, x: Float) -> Float
  def nothing() -> Void
  def flip(point: Point) -> Point
  def area(shape: Shape) -> Int
  def grow(shape: Shape, n: Int) -> Shape
  def points(n: Int) -> List[Point]
  def sum32(samples: List[Float32]) -> Float
  def sum32_after_first(samples: List[Float32]) -> Float
  def runs32(samples: List[Float32]) -> Int
  def iota32(n: Int) -> List[Float32]
  def scale32(samples: List[Float32], by: Float) -> List[Float32]
  compute def dirty_scale32(samples: List[Float32], by: Float) -> List[Float32]
  compute def dirty_iota32(n: Int) -> List[Float32]
  def call_kept(n: Int) -> Int
  def bad_text() -> String
  def bad_type(n: Int) -> Point
end

def twice(n: Int) -> Int
  puts("twice #{n}")
  return n * 2
end

"""


@pytest.fixture(scope="module")
def demo(tmp_path_factory):
    """The path of the demo module, built once for the module."""
    return shared_library(tmp_path_factory, "module_demo", *(["-Wl,-z,defs"] if TARGET_OS == "linux" else []))


ADD = 'extern module "LIBRARY"\n  def add(a: Int, b: Int) -> Int\nend\n\n'


def run_main(tmp_path, demo, body, types=TYPES, module=MODULE, *flags):
    text = (types + module).replace("LIBRARY", literal(demo)) + "def main() -> Void\n" + body + "end\n"
    return agentica("--json", *flags, program(tmp_path, text))


def line_of(text, needle):
    return next(k for k, line in enumerate(text.split("\n"), 1) if needle in line)


@NATIVE_CALLS
def test_each_kind_of_value_crosses_a_module_call(tmp_path, demo):
    body = """  puts(add(40, 2))
  puts(upcase("caf\u00e9 ok"))
  puts(reverse("abc".bytes) == "cba".bytes)
  puts(sum([1, 2, 3, -10]))
  puts(range(4))
  puts(row(7)["square"])
  puts(pairs({"b": 2, "a": 1}))
  puts(lookup({"a": 1}, "a"))
  puts(lookup({"a": 1}, "z"))
  puts(parse("123"))
  puts(parse("12x"))
  puts(unwrap(ok(5)))
  puts(truthy?(true, 1.25))
  nothing()
  puts(flip(Point(x: 1, y: 2)))
  puts(area(Shape.Rect(Point(x: 1, y: 1), Point(x: 3, y: 4))) + area(Shape.Circle(5)) + area(Shape.Dot))
  puts(grow(Shape.Dot, 3))
  puts(grow(Shape.Circle(2), 3))
  puts(grow(Shape.Circle(2), 0))
  puts(points(3))
"""
    result = run_main(tmp_path, demo, body)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == "\n".join([
        "42", "CAF\u00e9 OK", "true", "-4", "[0, 1, 2, 3]", "49", '["b=2", "a=1"]',
        "some(1)", "none", "ok(123)", 'error("not a number")', "5", "2.5", "Point(x: 2, y: 1)", str(6 + 25 + 0),
        "Shape.Circle(3)", "Shape.Rect(Point(x: 0, y: 0), Point(x: 3, y: 3))", "Shape.Dot",
        "[Point(x: 0, y: 0), Point(x: 1, y: 2), Point(x: 2, y: 4)]", ""])


def binary32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def bits32(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


# A List[Float32] is read in place as C floats and made from a C array, in a short and in a compute call; a Python
# struct peer computes the binary32 values the module must see and make.
@NATIVE_CALLS
def test_a_list_of_float32_crosses_as_c_floats(tmp_path, demo):
    count = 150
    items = [binary32(0.37 * k - 11.1) for k in range(count)]
    literal_items = ", ".join(repr(x) for x in items)
    body = """  samples: List[Float32] = [%s]
  puts(sum32(samples))
  puts(sum32_after_first(samples))
  puts(sum32(samples.drop(45)))
  puts(runs32(samples) <= 6)
  puts(scale32(samples, 3.0).map do |x: Float32| x.to_bits.to_i end)
  puts(dirty_scale32(samples, 3.0).map do |x: Float32| x.to_bits.to_i end)
  puts(iota32(70).map do |x: Float32| x.to_bits.to_i end)
  puts(dirty_iota32(0))
  puts(scale32([], 2.0))
""" % literal_items
    result = run_main(tmp_path, demo, body)
    assert (result.code, result.stderr) == (0, "")
    total = 0.0
    for x in items:
        total += x
    after = 0.0
    for x in items[1:]:
        after += x
    tail = 0.0
    for x in items[45:]:
        tail += x
    scaled = [bits32(x * 3.0) for x in items]
    halves = [bits32(0.5 * k) for k in range(70)]
    lines = result.stdout.split("\n")
    assert [float(line) for line in lines[:3]] == [total, after, tail]
    assert lines[3:] == ["true", str(scaled), str(scaled), str(halves), "[]", "[]", ""]


# The structs and enums of an imported file cross too: the module knows them by their bare names.
@NATIVE_CALLS
def test_the_types_of_an_imported_file_cross(tmp_path, demo):
    shapes = ("struct Point\n  x: Int\n  y: Int\nend\n\n"
               "enum Shape\n  Dot\n  Circle(Int)\n  Rect(Point, Point)\nend\n")
    program(tmp_path, shapes, "shapes.agc")
    text = ('import {Point, Shape} from "shapes"\n\nextern module "%s"\n  def flip(point: Point) -> Point\n'
            '  def grow(shape: Shape, n: Int) -> Shape\nend\n\ndef main() -> Void\n  puts(flip(Point(x: 1, y: 2)))\n'
            '  puts(grow(Shape.Circle(2), 3))\nend\n') % literal(demo)
    result = agentica("--json", program(tmp_path, text))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == "Point(x: 2, y: 1)\nShape.Rect(Point(x: 0, y: 0), Point(x: 3, y: 3))\n"


# A record of a std module crosses by its bare name too, though it prints with the import alias (URI.Pair).
@NATIVE_CALLS
def test_a_record_of_a_std_module_crosses(tmp_path, demo):
    text = ('import URI from "std/uri"\n\nextern module "%s"\n  def swap_pair(pair: URI.Pair) -> URI.Pair\nend\n\n'
            'def main() -> Void\n  puts(swap_pair(URI.Pair(name: "a", value: "b")))\nend\n') % literal(demo)
    result = agentica("--json", program(tmp_path, text))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == 'URI.Pair(name: "b", value: "a")\n'


# A short call never calls back into Agentica: the callback that the module starts runs nothing and gives 0, while
# the same callback started from an extern call runs.
@NATIVE_CALLS
def test_a_callback_started_inside_a_short_call_runs_nothing_and_gives_zero(tmp_path, demo):
    body = "  demo_keep(Native.callback(Twice, &twice))\n  puts(call_kept(5))\n  puts(demo_call_kept(6))\n"
    result = run_main(tmp_path, demo, body)
    assert (result.code, result.stdout, result.stderr) == (0, "0\ntwice 6\n12\n", "")


# What the module refuses (an_raise, an_badarg, a bad constructor) stops the run at the def line of the function.
@NATIVE_CALLS
@pytest.mark.parametrize("call, name", [
    ('unwrap(error("no"))', "def unwrap("),
    ("bad_text()", "def bad_text("),
    ("bad_type(1)", "def bad_type("),
])
def test_a_failure_of_the_module_stops_the_run_at_the_def_line(tmp_path, demo, call, name):
    result = run_main(tmp_path, demo, "  puts(%s)\n" % call)
    assert diagnostic(result, 1) == ("RUNTIME-NATIVE-ERROR", (line_of(TYPES + MODULE, name), 3))
    assert result.stdout == ""


# The VM binds a function at its first call: the module must have it with the same signature, mode and types.
@NATIVE_CALLS
@pytest.mark.parametrize("types, declared, call, code", [
    ("", "def add(a: Int, b: Float) -> Int", "add(1, 2.0)", "RUNTIME-NATIVE-SIGNATURE"),
    ("", "def missing(a: Int) -> Int", "missing(1)", "RUNTIME-NATIVE-SIGNATURE"),
    ("", "compute def add(a: Int, b: Int) -> Int", "add(1, 2)", "RUNTIME-NATIVE-SIGNATURE"),
    ("", "def crunch(a: Int, b: Int) -> Int", "crunch(1, 2)", "RUNTIME-NATIVE-SIGNATURE"),
    ("struct Point\n  y: Int\n  x: Int\nend\n\n", "def flip(point: Point) -> Point", "flip(Point(x: 1, y: 2))",
     "RUNTIME-NATIVE-SIGNATURE"),
    ("type Size = Int\n\n", "def add(a: Size, b: Int) -> Size", "add(1, 2)", None),
])
def test_a_declaration_that_the_module_does_not_have_is_refused_at_the_first_call(tmp_path, demo, types, declared,
                                                                                  call, code):
    module = 'extern module "LIBRARY"\n  %s\nend\n\n' % declared
    result = run_main(tmp_path, demo, '  puts("start")\n  puts(%s)\n' % call, types, module)
    if code is None:
        assert (result.code, result.stdout) == (0, "start\n3\n")
    else:
        assert diagnostic(result, 1) == (code, (line_of(types + module, declared), 3))
        assert result.stdout == "start\n"


@NATIVE_CALLS
def test_a_module_that_does_not_open_fails_its_first_call(tmp_path):
    result = run_main(tmp_path, tmp_path / "missing.so", "  puts(add(1, 2))\n", "", ADD)
    assert diagnostic(result, 1) == ("RUNTIME-NATIVE-LOAD", (2, 3))


@NATIVE_CALLS
@pytest.mark.parametrize("flag", ["--deny-native", "--sandbox"])
def test_deny_native_refuses_a_module_block_before_it_runs(tmp_path, demo, flag):
    result = run_main(tmp_path, demo, '  puts("start")\n  puts(add(1, 2))\n', "", ADD, flag)
    assert (result.code, result.stdout) == (2, "")
    assert diagnostic(result, 2)[0] == "RUNTIME-NATIVE-DENIED"


DIRTY = """extern module "LIBRARY"
  resource Counter
  compute def crunch(a: Int, b: Int) -> Int
  compute def dirty_upcase(text: String) -> String
  compute def dirty_row(n: Int) -> Map[String, Int]
  compute def dirty_grow(shape: Shape, n: Int) -> Shape
  compute def dirty_points(n: Int) -> List[Point]
  compute def dirty_parse(text: String) -> Result[Int]
  compute def dirty_unwrap(result: Result[Int]) -> Int
  compute def wait_gate(counter: Counter) -> Int
  compute def counters(n: Int) -> List[Counter]
  def counter(id: Int) -> Counter
  def bump(counter: Counter) -> Int
  def gate_entered?() -> Bool
  def gate(on: Bool) -> Void
  def freed() -> Int
  def trace_frees() -> Void
end

def wait_for(counter: Counter) -> Int
  return wait_gate(counter)
end

def wait_for_new(id: Int) -> Int
  return wait_gate(counter(id))
end

def until_entered() -> Void
  while !gate_entered?()
    Task.sleep(1)
  end
end

"""


# A compute def of a module runs on the compute pool: its values are built once it returns. A resource of the module
# block is made, held for each call and freed once, at Native.close.
@NATIVE_CALLS
def test_dirty_calls_and_resources_of_a_module(tmp_path, demo):
    body = """  puts(crunch(40, 2))
  puts(dirty_upcase("abc"))
  puts(dirty_row(7)["square"])
  puts(dirty_grow(Shape.Circle(2), 3))
  puts(dirty_points(2))
  puts(dirty_parse("12x"))
  one = counter(1)
  puts(bump(one))
  puts(bump(one))
  Native.close(one)
  puts(Native.closed?(one))
  puts(counters(2).map do |item: Counter| bump(item) end)
  puts(freed())
"""
    result = run_main(tmp_path, demo, body, TYPES, DIRTY)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == "\n".join([
        "42", "ABC", "49", "Shape.Rect(Point(x: 0, y: 0), Point(x: 3, y: 3))", "[Point(x: 0, y: 0), Point(x: 1, y: 2)]",
        'error("not a number")', "1", "2", "true", "[1, 1]", "1", ""])


# The Error that a module function returns (an_error) has the location of the user's call, as an Error of a builtin
# does, for a short and a compute def alike: not the place of the extern declaration.
@NATIVE_CALLS
def test_an_error_of_a_module_function_points_at_the_call(tmp_path, demo):
    module = ('extern module "LIBRARY"\n  def parse(text: String) -> Result[Int]\n'
              '  compute def dirty_parse(text: String) -> Result[Int]\nend\n\n')
    body = """  for result in [parse("12x"), dirty_parse("12x")]
    case result
      ok(n) -> puts(n)
      error(e) -> puts(e.location)
    end
  end
"""
    result = run_main(tmp_path, demo, body, "", module)
    assert (result.code, result.stderr) == (0, "")
    line = module.count("\n") + 2
    assert result.stdout == "program.agc:%d:18\nprogram.agc:%d:32\n" % (line, line)


@NATIVE_CALLS
@pytest.mark.parametrize("body, name, code", [
    ('  puts(dirty_unwrap(error("no")))\n', "compute def dirty_unwrap(", "RUNTIME-NATIVE-ERROR"),
    ("  one = counter(1)\n  Native.close(one)\n  puts(bump(one))\n", "  def bump(", "RUNTIME-NATIVE-CLOSED"),
    ("  one = counter(1)\n  Native.close(one)\n  puts(wait_gate(one))\n", "compute def wait_gate(",
     "RUNTIME-NATIVE-CLOSED"),
])
def test_a_failed_dirty_call_or_a_closed_resource_stops_the_run_at_the_def_line(tmp_path, demo, body, name, code):
    result = run_main(tmp_path, demo, body, TYPES, DIRTY)
    assert diagnostic(result, 1) == (code, (line_of(TYPES + DIRTY, name), 3))


# A dirty call holds its counter: a close by another task, or the end of the cancelled task that owns it, leaves the
# free to the end of the call, which C still runs to its end (it reads the counter after the close). Each counter is
# freed once, and the end of the run frees the live ones, newest first.
@NATIVE_CALLS
def test_a_resource_held_by_a_dirty_call_is_freed_once_after_it(tmp_path, demo):
    body = """  trace_frees()
  shared = counter(9)
  waiting = Task.spawn(&wait_for, shared)
  until_entered()
  Native.close(shared)
  puts("closed #{Native.closed?(shared)} freed #{freed()}")
  gate(true)
  puts(Task.await(waiting))
  puts("freed #{freed()}")
  gate(false)
  cancelled = Task.spawn(&wait_for_new, 7)
  until_entered()
  Task.cancel(cancelled)
  puts("freed #{freed()}")
  gate(true)
  while freed() < 2
    Task.sleep(1)
  end
  kept = [counter(1), counter(2), counter(3)]
  puts(kept.size)
"""
    result = run_main(tmp_path, demo, body, TYPES, DIRTY)
    assert (result.code, result.stdout) == (0, "closed true freed 0\n9\nfreed 1\nfreed 1\n3\n")
    assert result.stderr == "freed 9\nfreed 7\nfreed 3\nfreed 2\nfreed 1\n"


# Native.arena closes the counters made in its block, a compute call's list of them included, newest first, and keeps
# the one its value holds.
@NATIVE_CALLS
def test_an_arena_closes_the_resources_of_a_module(tmp_path, demo):
    body = """  trace_frees()
  kept = Native.arena do
    _a = counter(10)
    _pair = counters(2)
    _b = counter(20)
    counter(30)
  end
  puts("freed #{freed()}")
  puts(bump(kept))
  Native.close(kept)
"""
    result = run_main(tmp_path, demo, body, TYPES, DIRTY)
    assert (result.code, result.stdout) == (0, "freed 4\n1\n")
    assert result.stderr == "freed 20\nfreed 2\nfreed 1\nfreed 10\nfreed 30\n"


FRESH = """extern module "LIBRARY"
  resource Blob
  def blob() -> Blob
  def mix(blob: Blob) -> Blob
  def mix_fresh(blob: Blob) -> Blob
  compute def dirty_mix_fresh(blob: Blob) -> Blob
  def first(blob: Blob) -> Int
  def blobs() -> Int
end

def chain(path: String) -> Blob
  if path == "short"
    return mix_fresh(mix_fresh(blob()))
  elsif path == "dirty"
    return dirty_mix_fresh(dirty_mix_fresh(blob()))
  end
  return mix(mix(blob()))
end

def arenas(path: String) -> Void
  before = blobs()
  last = 0
  for _ in 0...8
    kept = Native.arena do chain(path) end
    last = first(kept)
    Native.close(kept)
  end
  puts("#{path} #{last} #{blobs() - before}")
end

"""


# #1932: an arena that returns the Blob of a function marked AN_FRESH keeps that Blob alone, so a loop of such arenas
# frees every 4 MiB intermediate. Each path that makes a resource is checked on its own chain: a short call makes it
# at once (api_resource_new), a compute call when it returns (build_node). Without the flag the Blob keeps the ones it
# was made from, all the way up, and each arena leaves two of them open until the task ends. Each line counts the
# Blobs left open by its own loop.
@NATIVE_CALLS
def test_an_arena_keeps_only_the_result_of_a_fresh_function(tmp_path, demo):
    body = """  arenas("short")
  arenas("dirty")
  arenas("plain")
"""
    result = run_main(tmp_path, demo, body, "", FRESH)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == "short 2 0\ndirty 2 0\nplain 2 16\n"


# The profile (AGENTICA_VM_TRACE=profile) has a line per function of a module that ran: its calls, the time in C and
# the mode.
@NATIVE_CALLS
def test_the_profile_counts_the_calls_of_each_module_function(tmp_path, demo):
    if "trace off" in agentica("--version").stdout:
        pytest.skip("the VM was built with TRACE=0")
    trace = tmp_path / "profile.trace"
    text = (TYPES + DIRTY).replace("LIBRARY", literal(demo))
    text += "def main() -> Void\n  puts(crunch(1, 2) + crunch(3, 4))\n  puts(bump(counter(1)))\nend\n"
    result = agentica("--schedulers", "1", program(tmp_path, text),
                      env={"AGENTICA_VM_TRACE": "profile", "AGENTICA_VM_TRACE_FILE": str(trace)})
    assert (result.code, result.stdout) == (0, "10\n1\n")
    lines = [line for line in trace.read_text().splitlines() if "native calls=" in line]
    found = sorted(re.sub(r".*native calls=(\d+) us=\d+ (mode=\w+ name=\S+).*", r"\1 \2", line) for line in lines)
    assert found == ["1 mode=short name=bump", "1 mode=short name=counter", "2 mode=dirty name=crunch"]


ERRORS = """extern module "LIBRARY"
  def fail_kind(kind: String, message: String, details: Map[String, String]) -> Result[Int]
  def describe(result: Result[Int]) -> String
  def rethrow(result: Result[Int]) -> Result[Int]
  def bad_error(which: Int) -> String
  compute def dirty_fail_kind(kind: String, message: String, details: Map[String, String]) -> Result[Int]
  compute def dirty_describe(result: Result[Int]) -> String
  compute def dirty_rethrow(result: Result[Int]) -> Result[Int]
  compute def dirty_bad_error(which: Int) -> String
end

"""


# API 1.4: an_error_kind makes an Error with a kind and details, an_get_error reads them back, in short and compute
# defs alike; what one reads, the other makes again, equal to the first.
@NATIVE_CALLS
def test_a_module_makes_and_reads_errors_with_a_kind_and_details(tmp_path, demo):
    body = """  made = fail_kind("db.constraint", "unique failed", {"table": "users", "café": "é"})
  case made
    ok(n) -> puts(n)
    error(e) -> puts("#{e.kind} #{e.message} #{e.details} #{e.is_a?("db")}")
  end
  dirty = dirty_fail_kind("net.timeout", "slow", {})
  puts(dirty)
  given: Result[Int] = error("no route", kind: "net.refused", details: {"host": "db"})
  puts(describe(given))
  puts(dirty_describe(given))
  puts(describe(error("plain")))
  puts(describe(ok(1)))
  puts(rethrow(given) == given)
  puts(dirty_rethrow(made) == made)
  puts(bad_error(6))
  puts(bad_error(7))
  puts(dirty_bad_error(7))
"""
    result = run_main(tmp_path, demo, body, "", ERRORS)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == "\n".join([
        'db.constraint unique failed {"table": "users", "café": "é"} true',
        'error("slow", kind: "net.timeout")',
        "net.refused: no route {host=db}", "net.refused: no route {host=db}", "error: plain {}", "ok",
        "true", "true", "false", "true", "false", ""])


# A kind that is not a dotted name, a NULL where text is needed, or text that is not UTF-8 fails the call.
@NATIVE_CALLS
@pytest.mark.parametrize("call", [
    'fail_kind("Db", "m", {})', 'fail_kind("db..x", "m", {})', 'fail_kind("db.", "m", {})', 'fail_kind("", "m", {})',
    'fail_kind("1db", "m", {})', 'dirty_fail_kind("db._x", "m", {})',
    "bad_error(0)", "bad_error(1)", "bad_error(2)", "bad_error(3)", "bad_error(4)", "bad_error(5)",
    "dirty_bad_error(0)", "dirty_bad_error(3)", "dirty_bad_error(5)",
])
def test_bad_arguments_of_an_error_kind_fail_the_call(tmp_path, demo, call):
    result = run_main(tmp_path, demo, "  puts(%s)\n" % call, "", ERRORS)
    name = call.split("(")[0] + "("
    assert diagnostic(result, 1) == ("RUNTIME-NATIVE-ERROR", (line_of(ERRORS, " def " + name), 3))
    assert result.stdout == ""


# A module built for API 1.3 still loads: its an_error makes kind "error", and an_get_result reads the message of an
# Error with a kind as a String.
@NATIVE_CALLS
def test_a_module_of_api_1_3_still_loads_and_reads_errors(tmp_path_factory, tmp_path):
    old = shared_library(tmp_path_factory, "module_v13", *(["-Wl,-z,defs"] if TARGET_OS == "linux" else []))
    module = ('extern module "LIBRARY"\n  def fail() -> Result[Int]\n  def message(result: Result[Int]) -> String\n'
              'end\n\n')
    body = """  case fail()
    ok(n) -> puts(n)
    error(e) -> puts("#{e.kind} #{e.message}")
  end
  puts(message(error("boom", kind: "db.constraint")))
"""
    result = run_main(tmp_path, old, body, "", module)
    assert (result.code, result.stdout, result.stderr) == (0, "error old\nboom\n", "")
