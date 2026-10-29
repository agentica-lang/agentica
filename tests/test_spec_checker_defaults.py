"""Default values of parameters and of struct fields (`NAME: type = expression`), through the product CLI.

A builtin row can give defaults too; `Zlib.crc32(data, seed = 0)` is the one that does, so its cases are here.

Each case writes a program (one file, or several for the import-alias rules) and runs `--json check FILE`. A rejected
program is asserted by its diagnostic code and the source text its range covers; a good one checks clean. Message and
help texts are not asserted (AGENTS.md).
"""
import pytest

from tests.spec_support import assert_exact_span, assert_multi_file_case, assert_single_file_case

JOIN = 'def join(xs: List[String], sep: String = ", ") -> String\n  return xs.join(sep)\nend\n\n'

# A path, a timeout with a default and a last Fn parameter, which a block (or the last argument) fills.
EACH_LINE = ('def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void\n'
             '  f.call(path)\nend\n\n'
             'def show(line: String) -> Void\n  puts(line)\nend\n\n')


POINT = 'struct Point\n  x: Int = 0\n  y: Int\nend\n\n'


def main_with(body, helpers=""):
    return helpers + "def main() -> Void\n" + body + "end\n\n"


# (title, program, code, text the range covers): code None means the program checks clean.
SINGLE_FILE = [
    ("every constant form is a default",
     'enum Mode\n  Fast\n  Safe\nend\n\n'
     'def f(a: Int = 1, b: Int = -2, c: Float = 2.5, d: Float = -0.5, e: String = "x", g: Bool = true,'
     ' h: Bool = false, i: List[Int] = [], j: Map[String, Int] = {}, k: Mode = Mode.Safe,'
     ' l: Int = -9223372036854775808) -> Int\n'
     '  return a\nend\n\n' + main_with("  puts(f())\n"), None, None),
    ("a call may leave out 0, 1 or 2 arguments",
     'def f(a: Int, b: Int = 1, c: Int = 2) -> Int\n  return a + b + c\nend\n\n'
     + main_with("  puts(f(1))\n  puts(f(1, 2))\n  puts(f(1, 2, 3))\n"), None, None),
    ("defaults only at the end: a parameter without a default after one",
     'def f(a: Int = 1, b: Int) -> Int\n  return a + b\nend\n\n' + main_with("  puts(f(1, 2))\n"),
     "CHECK-DEFAULT-ORDER", "b: Int"),
    ("defaults only at the end: the first of several parameters without a default is the problem",
     'def f(a: Int = 1, b: Int, c: Int) -> Int\n  return a + b + c\nend\n\n' + main_with("  puts(f(1, 2, 3))\n"),
     "CHECK-DEFAULT-ORDER", "b: Int"),
    ("defaults only at the end: a last Fn parameter may stay without one",
     EACH_LINE + main_with("  each_line(\"a.txt\", 5, &show)\n"), None, None),
    ("defaults only at the end: an Fn parameter that is not the last one cannot",
     'def f(a: Int = 1, g: Fn[Int, Int], b: Int = 2) -> Int\n  return a\nend\n\n' + main_with("  puts(f(1))\n"),
     "CHECK-DEFAULT-ORDER", "g: Fn[Int, Int]"),
    ("defaults only at the end: a last parameter that is not an Fn cannot",
     'def f(a: Int = 1, b: Int) -> Int\n  return a\nend\n\n' + main_with("  puts(f(1, 2))\n"),
     "CHECK-DEFAULT-ORDER", "b: Int"),
    ("a default is a constant: a call",
     'def seed() -> Int\n  return 4\nend\n\ndef f(a: Int = seed()) -> Int\n  return a\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-DEFAULT-VALUE", "seed()"),
    ("a default is a constant: a name",
     'ONE = 1\n\ndef f(a: Int = ONE) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "ONE"),
    ("a default is a constant: an operation",
     'def f(a: Int = 1 + 2) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "1 + 2"),
    ("a default is a constant: a function reference",
     'def show(line: String) -> Void\nend\n\ndef f(g: Fn[String, Void] = &show) -> Void\nend\n\n'
     + main_with("  f()\n"), "CHECK-DEFAULT-VALUE", "&show"),
    ("a default is a constant: an interpolated string",
     'def f(a: String = "a#{1}b") -> String\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", '"a#{1}b"'),
    ("a default is a constant: a list with elements",
     'def f(a: List[Int] = [1]) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "[1]"),
    ("a default is a constant: a map with entries",
     'def f(a: Map[String, Int] = {"k": 1}) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", '{"k": 1}'),
    ("a default is a constant: a struct",
     'struct Point\n  x: Int\nend\n\ndef f(p: Point = Point(x: 1)) -> Int\n  return 1\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-DEFAULT-VALUE", "Point(x: 1)"),
    ("a default is a constant: a variant with a payload",
     'enum Shape\n  Dot\n  Circle(Int)\nend\n\ndef f(s: Shape = Shape.Circle(1)) -> Int\n  return 1\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-DEFAULT-VALUE", "Shape.Circle(1)"),
    ("a default is a constant: another parameter",
     'def f(a: Int, b: Int = a) -> Int\n  return b\nend\n\n' + main_with("  puts(f(1))\n"),
     "CHECK-DEFAULT-VALUE", "a"),
    ("the type of a default is checked against the parameter",
     'def f(a: Int = "x") -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", '"x"'),
    ("[] and {} take the type of the parameter",
     'def f(a: List[String] = [], b: Map[String, Int] = {}) -> Int\n  return a.size + b.size\nend\n\n'
     + main_with("  puts(f())\n"), None, None),
    ("[] does not fit a map parameter",
     'def f(a: Map[String, Int] = []) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", "[]"),
    ("a variant of another enum does not fit the parameter",
     'enum Mode\n  Fast\nend\n\nenum Other\n  Slow\nend\n\n'
     'def f(a: Mode = Other.Slow) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", "Other.Slow"),
    ("an unknown variant is not a default",
     'enum Mode\n  Fast\nend\n\ndef f(a: Mode = Mode.Gone) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-UNKNOWN-VARIANT", "Mode.Gone"),
    ("a builtin enum variant is a default",
     'def f(level: LogLevel = LogLevel.Info) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), None, None),
    ("a call takes between the required and the total number of arguments: too few",
     JOIN + main_with("  puts(join())\n"), "CHECK-ARITY", "join()"),
    ("a call takes between the required and the total number of arguments: too many",
     JOIN + main_with('  puts(join([], ", ", 1))\n'), "CHECK-ARITY", 'join([], ", ", 1)'),
    ("a function without defaults keeps its exact arity",
     'def two(a: Int, b: Int) -> Int\n  return a + b\nend\n\n' + main_with("  puts(two(1))\n"),
     "CHECK-ARITY", "two(1)"),
    ("arguments fill from the left: a mismatch is reported at the argument",
     JOIN + main_with("  puts(join([], 1))\n"), "CHECK-TYPE-MISMATCH", "1"),
    ("the block fills the last Fn parameter",
     EACH_LINE + main_with('  each_line("a.txt") do |line|\n    puts(line)\n  end\n'), None, None),
    ("the block fills the last Fn parameter after a given default",
     EACH_LINE + main_with('  each_line("a.txt", 50) do |line|\n    puts(line)\n  end\n'), None, None),
    ("the last argument fills the last Fn parameter",
     EACH_LINE + main_with('  each_line("a.txt", 50, &show)\n  each_line("a.txt", &show)\n'), None, None),
    ("the last argument goes to the Fn parameter, so a number there is a type error, not an arity error",
     EACH_LINE + main_with('  each_line("a.txt", 50)\n'), "CHECK-TYPE-MISMATCH", "50"),
    ("a call with only the path and no Fn is an arity error",
     EACH_LINE + main_with("  each_line()\n"), "CHECK-ARITY", "each_line()"),
    ("a piped value is the first argument and the defaults follow",
     JOIN + main_with('  puts(["a"] |> join())\n'), None, None),
    ("a function value takes every argument: the call with all of them",
     JOIN + main_with('  f = &join\n  puts(f.call(["a"], ", "))\n'), None, None),
    ("a function value takes every argument: the call with fewer is an arity error",
     JOIN + main_with('  f = &join\n  puts(f.call(["a"]))\n'), "CHECK-ARITY", 'f.call(["a"])'),
    ("a function value has the type with every parameter",
     JOIN + main_with('  f: Fn[List[String], String, String] = &join\n  puts(f.call(["a"], "-"))\n'), None, None),
    ("a builtin call may leave out the trailing parameter with a default, or give it",
     main_with("  puts(Zlib.crc32([1, 2]).unwrap!)\n  puts(Zlib.crc32([1, 2], 7).unwrap!)\n"), None, None),
    ("a piped call of a builtin leaves out the default",
     main_with("  puts(([1, 2] |> Zlib.crc32()).unwrap!)\n"), None, None),
    ("a builtin call with fewer arguments than it requires is an arity error",
     main_with("  puts(Zlib.crc32())\n"), "CHECK-ARITY", "Zlib.crc32()"),
    ("a builtin call with more arguments than it has parameters is an arity error",
     main_with("  puts(Zlib.crc32([1], 0, 1))\n"), "CHECK-ARITY", "Zlib.crc32([1], 0, 1)"),
    ("a builtin default does not change the type of a given argument",
     main_with('  puts(Zlib.crc32([1], "x"))\n'), "CHECK-TYPE-MISMATCH", '"x"'),
    ("a filesystem builtin may leave out the timeout, and File.open the mode and the timeout",
     main_with('  puts(File.read_text("a.txt"))\n  puts(File.stat("a.txt", 50))\n  puts(Path.rename("a", "b"))\n'
               '  a = File.open("a.txt")\n  b = File.open("a.txt", "write")\n'
               '  c = File.open("a.txt", "append", 50)\n'), None, None),
    ("a filesystem builtin timeout is still an Int",
     main_with('  puts(Dir.list("d", "soon"))\n'), "CHECK-TYPE-MISMATCH", '"soon"'),
    ("a file handle call and each_line, foreach and write_lines may leave out the timeout",
     main_with('  f = File.open("a.txt").unwrap!\n  puts(File.read_line(f))\n  puts(File.write(f, "x"))\n'
               '  puts(File.close(f, 50))\n  puts(File.read_bytes(f, 4))\n  puts(File.flush(f))\n'
               '  puts(File.write_bytes(f, [1]))\n  puts(File.try_lock(f))\n'
               '  File.each_line("a.txt", 4096) do |l|\n    ok()\n  end\n'
               '  File.each_line("a.txt") do |line|\n    puts(line)\n    ok()\n  end\n'
               '  puts(File.foreach("a.txt").first(1))\n  puts(File.foreach("a.txt", 4096).first(1))\n'
               '  puts(File.foreach("a.txt").write_lines("b.txt"))\n'), None, None),
    ("File.open still needs its path",
     main_with("  puts(File.open())\n"), "CHECK-ARITY", "File.open()"),
    ("a builtin has no function value, defaults or not",
     main_with("  f = &Zlib.crc32\n"), "CHECK-UNKNOWN-NAME", "&Zlib.crc32"),
    ("main takes no parameters, defaults included",
     'def main(a: Int = 1) -> Void\n  puts(a)\nend\n\n', "CHECK-MAIN", None),
    ("a block parameter takes no default",
     main_with("  [1].each do |x = 1|\n    puts(x)\n  end\n"), "PARSE-UNEXPECTED-TOKEN", "="),
    ("a default needs an expression after the sign",
     'def f(a: Int =) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), "PARSE-UNEXPECTED-TOKEN", ")"),
    ("a parameter needs its type even with a default",
     'def f(a = 1) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), "PARSE-UNEXPECTED-TOKEN", "="),
    ("a constructor may leave out a field with a default, or give it",
     'enum Mode\n  Fast\n  Safe\nend\n\n'
     'struct Options\n  name: String\n  a: Int = 1\n  b: Int = -2\n  c: Float = 2.5\n  d: String = "x"\n'
     '  e: Bool = true\n  f: List[Int] = []\n  g: Map[String, Int] = {}\n  h: Mode = Mode.Safe\nend\n\n'
     + main_with('  puts(Options(name: "n").inspect)\n  puts(Options(h: Mode.Fast, name: "n", a: 2).inspect)\n'),
     None, None),
    ("a struct with only defaults is built with no fields",
     'struct Box\n  w: Int = 1\n  h: Int = 2\nend\n\n' + main_with("  puts(Box().inspect)\n"), None, None),
    ("a field without a default must still be given",
     POINT + main_with("  puts(Point(x: 1).inspect)\n"), "CHECK-MISSING-FIELD", "Point(x: 1)"),
    ("a field without a default must still be given, even when every other field has one",
     POINT + main_with("  puts(Point().inspect)\n"), "CHECK-MISSING-FIELD", "Point()"),
    ("a field that has a default cannot be given twice",
     POINT + main_with("  puts(Point(x: 1, y: 2, x: 3).inspect)\n"), "CHECK-DUPLICATE-FIELD", "x: 3"),
    ("an extra field is still unknown",
     POINT + main_with("  puts(Point(y: 2, z: 3).inspect)\n"), "CHECK-UNKNOWN-FIELD", "z: 3"),
    ("a field default is a constant: a call",
     'struct S\n  a: Int = seed()\nend\n\ndef seed() -> Int\n  return 4\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "seed()"),
    ("a field default is a constant: an operation",
     'struct S\n  a: Int = 1 + 2\nend\n\n' + main_with("  puts(S().inspect)\n"), "CHECK-DEFAULT-VALUE", "1 + 2"),
    ("a field default is a constant: a name",
     'ONE = 1\n\nstruct S\n  a: Int = ONE\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "ONE"),
    ("a field default is a constant: a list with elements",
     'struct S\n  a: List[Int] = [1]\nend\n\n' + main_with("  puts(S().inspect)\n"), "CHECK-DEFAULT-VALUE", "[1]"),
    ("a field default is a constant: a struct",
     POINT + 'struct S\n  p: Point = Point(y: 1)\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "Point(y: 1)"),
    ("a field default is a constant: another field",
     'struct S\n  a: Int = 1\n  b: Int = a\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "a"),
    ("the type of a field default is checked against the field",
     'struct S\n  a: Int = "x"\nend\n\n' + main_with("  puts(S().inspect)\n"), "CHECK-TYPE-MISMATCH", '"x"'),
    ("[] does not fit a map field",
     'struct S\n  a: Map[String, Int] = []\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-TYPE-MISMATCH", "[]"),
    ("an unknown variant is not a field default",
     'enum Mode\n  Fast\nend\n\nstruct S\n  a: Mode = Mode.Gone\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-UNKNOWN-VARIANT", "Mode.Gone"),
    ("a field default needs an expression after the sign",
     'struct S\n  a: Int =\nend\n\n' + main_with("  puts(S().inspect)\n"), "PARSE-UNEXPECTED-TOKEN", "\n"),
    ("a field default of a struct that is never built is still checked",
     'struct S\n  a: Int = 1 + 1\nend\n\n' + main_with("  puts(1)\n"), "CHECK-DEFAULT-VALUE", "1 + 1"),
    ("with changes a field and leaves the others, defaults included",
     POINT + main_with("  puts(Point(y: 1).with(x: 5).inspect)\n"), None, None),
]

# Several files: (title, files, code, file of the diagnostic, text the range covers).
MODULES = [
    ("a call through an import alias leaves out the defaults",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import Util from "util"\n\n'
                  + main_with('  puts(Util.join(["a"]))\n  puts(Util.join(["a"], "-"))\n')},
     None, None, None),
    ("an alias call without parentheses fills every default",
     {"util.agc": 'export def connect(host: String = "localhost", port: Int = 8080) -> String\n'
                  '  return "#{host}:#{port}"\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  x = Util.connect\n  puts(x)\n")},
     None, None, None),
    ("an alias call without parentheses and a required parameter is an arity error",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import Util from "util"\n\n' + main_with("  x = Util.join\n  puts(x)\n")},
     "CHECK-ARITY", "root.agc", "Util.join"),
    ("an alias call with too many arguments is an arity error",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import Util from "util"\n\n' + main_with('  puts(Util.join([], ",", 1))\n')},
     "CHECK-ARITY", "root.agc", 'Util.join([], ",", 1)'),
    ("a default that names a variant through an import alias is resolved in the declaring module",
     {"models.agc": "export enum Level\n  Info\n  Warn\nend\n\n",
      "util.agc": 'import Models from "models"\n\n'
                  'export def pick(level: Models.Level = Models.Level.Warn) -> Models.Level\n  return level\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  x = Util.pick()\n  puts(x)\n")},
     None, None, None),
    ("a default that names a private enum of its module can be left out by another module",
     {"util.agc": 'enum Mode\n  Fast\n  Safe\nend\n\n'
                  'export def pick(mode: Mode = Mode.Safe) -> String\n  return "#{mode}"\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  puts(Util.pick())\n")},
     None, None, None),
    ("a bad default in an imported file is reported in that file",
     {"util.agc": 'export def pick(n: Int = 1 + 1) -> Int\n  return n\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  puts(Util.pick())\n")},
     "CHECK-DEFAULT-VALUE", "util.agc", "1 + 1"),
    ("a named import of a function with defaults leaves them out",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import {join} from "util"\n\n' + main_with('  puts(join(["a"]))\n')},
     None, None, None),
    ("a struct with defaults, exported, is built by another file that leaves them out",
     {"models.agc": 'export enum Level\n  Info\n  Warn\nend\n\n'
                    'export struct Options\n  name: String\n  level: Level = Level.Warn\n  retries: Int = 3\nend\n\n',
      "root.agc": 'import Models from "models"\n\n'
                  + main_with('  puts(Models.Options(name: "a").inspect)\n'
                              '  puts(Models.Options(name: "a", retries: 1).inspect)\n')},
     None, None, None),
    ("a field default that names a private enum of its module can be left out by another module",
     {"models.agc": 'enum Mode\n  Fast\n  Safe\nend\n\nexport struct S\n  mode: Mode = Mode.Safe\nend\n\n',
      "root.agc": 'import Models from "models"\n\n' + main_with("  puts(Models.S().inspect)\n")},
     None, None, None),
    ("a field of an imported struct without a default must still be given",
     {"models.agc": 'export struct S\n  a: Int\n  b: Int = 1\nend\n\n',
      "root.agc": 'import Models from "models"\n\n' + main_with("  puts(Models.S(b: 2).inspect)\n")},
     "CHECK-MISSING-FIELD", "root.agc", "Models.S(b: 2)"),
    ("a bad field default in an imported file is reported in that file",
     {"models.agc": 'export struct S\n  a: Int = 1 + 1\nend\n\n',
      "root.agc": 'import Models from "models"\n\n' + main_with("  puts(Models.S().inspect)\n")},
     "CHECK-DEFAULT-VALUE", "models.agc", "1 + 1"),
]


@pytest.mark.parametrize(
    ("title", "program", "code", "text"),
    SINGLE_FILE,
    ids=[case[0] for case in SINGLE_FILE],
)
def test_single_file_programs(title, program, code, text, agentica_check):
    assert_single_file_case(agentica_check, program, code, text, assert_exact_span)


@pytest.mark.parametrize(
    ("title", "files", "code", "file", "text"),
    MODULES,
    ids=[case[0] for case in MODULES],
)
def test_programs_of_several_files(title, files, code, file, text, agentica_check):
    assert_multi_file_case(agentica_check, files, code, file, text, assert_exact_span)
