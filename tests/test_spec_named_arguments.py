"""Named arguments in calls (`check(gen, verbose: true)`), through the product CLI (#1163).

Each case runs `--json check` on a program and asserts the diagnostic code and the source text its range covers; a
good program checks clean. Message and help texts are not asserted (AGENTS.md). The order the arguments run in is a
VM golden (tests/fixtures/vm/named-arguments.agc).
"""
from tests.spec_support import Batch, assert_rule

F = 'def f(a: Int, b: Int = 2, c: Int = 3) -> Int = a + b + c\n\n'
EACH_LINE = ('def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void\n'
             '  f.call(path)\nend\n\n'
             'def show(line: String) -> Void\n  puts(line)\nend\n\n')
PAIR = 'def pair[T](first: T, rest: List[T] = []) -> List[T] = rest.push(first)\n\n'
RUNNER = 'struct Runner\n  run: Fn[Int, Int]\nend\n\n'
POINT = 'struct Point\n  x: Int\n  y: Int = 0\nend\n\n'


def main_with(body, helpers=F):
    return helpers + "def main() -> Void\n" + body + "end\n"


# (title, program, code, text the range covers): code None means the program checks clean.
CASES = [
    ("a name sets one default and keeps the ones before it", main_with("  puts(f(1, c: 9))\n"), None, None),
    ("positional arguments first, then named ones in any order",
     main_with("  puts(f(1, c: 9, b: 8))\n  puts(f(c: 1, a: 2))\n"), None, None),
    ("an unknown name", main_with("  puts(f(1, d: 2))\n"), "CHECK-UNKNOWN-ARGUMENT", "d: 2"),
    ("a name given twice", main_with("  puts(f(a: 1, b: 2, b: 3))\n"), "CHECK-REPEATED-ARGUMENT", "b: 3"),
    ("a name also given by position", main_with("  puts(f(1, a: 2))\n"), "CHECK-REPEATED-ARGUMENT", "a: 2"),
    ("a parameter without a default left out", main_with("  puts(f(b: 1))\n"),
     "CHECK-MISSING-ARGUMENT", "f(b: 1)"),
    ("more positional arguments than parameters", main_with("  puts(f(1, 2, 3, 4, b: 1))\n"),
     "CHECK-ARITY", "f(1, 2, 3, 4, b: 1)"),
    ("a named argument before a positional one", main_with("  puts(f(a: 1, 2))\n"), "PARSE-UNEXPECTED-TOKEN", "2"),
    ("a named argument checks its type", main_with('  puts(f(1, b: "x"))\n'), "CHECK-TYPE-MISMATCH", '"x"'),
    ("a type parameter comes from a named argument",
     main_with('  xs: List[String] = pair(rest: [], first: "a")\n  puts(xs)\n', PAIR), None, None),
    ("a type parameter clash through names", main_with('  puts(pair(rest: [1], first: "a"))\n', PAIR),
     "CHECK-TYPE-MISMATCH", None),
    ("a trailing block with a named argument",
     main_with('  each_line("a.txt", timeout_ms: 5) do |line|\n    puts(line)\n  end\n', EACH_LINE), None, None),
    ("a trailing block fills the Fn that a name fills too",
     main_with('  each_line("a.txt", f: &show) do |line|\n    puts(line)\n  end\n', EACH_LINE),
     "CHECK-REPEATED-ARGUMENT", "f: &show"),
    ("a method of a builtin type takes names", main_with('  puts(["a"].join(separator: "-"))\n'), None, None),
    ("an unknown name of a method", main_with('  puts(["a"].join(sep: "-"))\n'), "CHECK-UNKNOWN-ARGUMENT", 'sep: "-"'),
    ("a builtin with defaults takes names",
     main_with('  puts(Zlib.deflate("abc".bytes, max_bytes: 64).unwrap!.size)\n'
               '  puts(Zlib.crc32(seed: 1, data: "a".bytes))\n'),
     None, None),
    ("a builtin parameter without a default left out", main_with("  puts(Zlib.crc32(seed: 1))\n"),
     "CHECK-MISSING-ARGUMENT", "Zlib.crc32(seed: 1)"),
    ("a prelude method takes names", main_with("  puts([1, 2, 3].each_slice(size: 2))\n"), None, None),
    ("a function value takes no names", main_with("  g = &f\n  puts(g.call(a: 1))\n"),
     "PARSE-UNEXPECTED-TOKEN", "a: 1"),
    ("an Fn field takes no names", main_with("  r = Runner(run: ->(x: Int) { x })\n  puts(r.run(x: 1))\n", RUNNER),
     "CHECK-UNKNOWN-ARGUMENT", "x: 1"),
    ("struct construction and with are unchanged",
     main_with("  p = Point(x: 1)\n  puts(p.with(y: 2))\n  puts(Point(y: 1, x: 2))\n", POINT), None, None),
    ("a struct construction still names fields only", main_with("  puts(Point(1, y: 2))\n", POINT),
     "PARSE-UNEXPECTED-TOKEN", None),
    ("error(...) keeps its named arguments",
     main_with('  r: Result[Int] = error("x", kind: "db", code: 1)\n  puts(r)\n', ""), None, None),
]

BATCH = Batch()
checked = BATCH.fixture()


@BATCH.table("title, program, code, text", CASES, lambda title, program, *_: program)
def test_named_arguments(title, program, code, text, checked):
    assert_rule(checked(program), program, code, text)


MODULE_CASES = [
    ("a module function takes names", '  puts(Geo.scale(Geo.Point(x: 1), shift: 1))\n', None, None),
    ("an unknown name of a module function", '  puts(Geo.scale(Geo.Point(x: 1), shfit: 1))\n',
     "CHECK-UNKNOWN-ARGUMENT", "shfit: 1"),
]

GEO = (POINT.replace("struct", "export struct")
       + "export def scale(p: Point, by: Int = 2, shift: Int = 0) -> Point = Point(x: p.x * by + shift)\n")


def module_program(title, body, *_):
    return {"geo.agc": GEO, "main.agc": 'import Geo from "geo"\n\ndef main() -> Void\n' + body + "end\n"}


@BATCH.table("title, body, code, text", MODULE_CASES, module_program)
def test_named_arguments_of_a_module_function(title, body, code, text, checked):
    files = module_program(title, body)
    assert_rule(checked(files), files["main.agc"], code, text)
