"""Default parameter values (`NAME: type = expression`), through the product CLI.

Each case writes a program (one file, or several for the import-alias rules) and runs `--json check FILE`. A rejected
program is asserted by its diagnostic code and the source text its range covers; a good one checks clean. Message and
help texts are not asserted (AGENTS.md).
"""
import json

from tests.agentica_test import TestCase
from tests.spec_support import (
    assert_module_cases,
    assert_single_file_cases,
    json_diagnostic_files,
)

JOIN = 'def join(xs: List[String], sep: String = ", ") -> String\n  return xs.join(sep)\nend\n\n'

# A path, a timeout with a default and a last Fn parameter, which a block (or the last argument) fills.
EACH_LINE = ('def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void\n'
             '  f.call(path)\nend\n\n'
             'def show(line: String) -> Void\n  puts(line)\nend\n\n')


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
    ("main takes no parameters, defaults included",
     'def main(a: Int = 1) -> Void\n  puts(a)\nend\n\n', "CHECK-MAIN", None),
    ("a block parameter takes no default",
     main_with("  [1].each do |x = 1|\n    puts(x)\n  end\n"), "PARSE-UNEXPECTED-TOKEN", "="),
    ("a default needs an expression after the sign",
     'def f(a: Int =) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), "PARSE-UNEXPECTED-TOKEN", ")"),
    ("a parameter needs its type even with a default",
     'def f(a = 1) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), "PARSE-UNEXPECTED-TOKEN", "="),
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
]


class SpecCheckerDefaultsTest(TestCase):
    def setUp(self):
        super().setUp()
        self.work = self.make_temp_dir()

    def diagnostic(self, files, root="program.agc"):
        return json_diagnostic_files(self, self.work, files, root)

    def test_single_file_programs(self):
        assert_single_file_cases(self, SINGLE_FILE, self.diagnostic)

    def test_programs_of_several_files(self):
        assert_module_cases(self, MODULES, self.diagnostic)
