"""`case` guards (`pattern if condition ->`), nested patterns and `case` as a value, through the product CLI.

Each case writes a program (one file, or several for the import-alias rules) and runs `--json check FILE`, or runs it.
A rejected program is asserted by its diagnostic code and the source text its range covers; a good one checks clean or
prints what the rule says. Message and help texts are not asserted (AGENTS.md).
"""
from collections import namedtuple

import pytest

from tests.agentica_test import cli, run
from tests.spec_support import assert_multi_file_case, assert_single_file_case, check_many, covered

# A range that starts with this text (a whole `case` or an arm: the range runs to its end).
Starts = namedtuple("Starts", "text")

ENUMS = ('enum Option\n  Some(Int)\n  None\nend\n\n'
         'enum Shape\n  Dot\n  Circle(Int)\n  Pair(Int, Int)\n  Boxed(Option)\nend\n\n')


def main_with(body, helpers=ENUMS):
    return helpers + "def main() -> Void\n" + body + "end\n\n"


def case_of(arms, scrutinee="Shape.Dot"):
    """A program whose main() is `case SCRUTINEE` over the arm lines (each indented by four spaces)."""
    lines = "".join("    " + arm + "\n" for arm in arms)
    return main_with("  shape = " + scrutinee + "\n  case shape\n" + lines + "  end\n")


def case_value_of(arms):
    """A program whose main() assigns `case shape` over the arm lines (each indented by four spaces)."""
    lines = "".join("    " + arm + "\n" for arm in arms)
    return main_with("  shape = Shape.Dot\n  x = case shape\n" + lines + "  end\n  puts(x)\n")


# (title, program, code, text the range covers): code None means the program checks clean.
SINGLE_FILE = [
    # Guards.
    ("a guard reads the names of its pattern",
     case_of(["Shape.Circle(r) if r > 3 -> puts(r)", "Shape.Circle(_) -> puts(0)",
              "Shape.Pair(a, b) if a < b -> puts(b)", "Shape.Pair(_, _) -> puts(0)", "Shape.Boxed(_) -> puts(1)",
              "Shape.Dot -> puts(2)"]), None, None),
    ("a guard must be a Bool",
     case_of(["Shape.Circle(r) if r -> puts(r)", "_ -> puts(0)"]), "CHECK-TYPE-MISMATCH", "r"),
    ("a guard of a wildcard arm must be a Bool",
     case_of(["_ if 1 -> puts(0)", "_ -> puts(1)"]), "CHECK-TYPE-MISMATCH", "1"),
    ("a guard does not see the names of another arm",
     case_of(["Shape.Circle(r) -> puts(r)", "Shape.Pair(a, _) if r > 1 -> puts(a)", "_ -> puts(0)"]),
     "CHECK-UNKNOWN-NAME", "r"),
    ("a guarded arm does not cover its variant",
     case_of(["Shape.Dot if 1 > 2 -> puts(0)", "Shape.Circle(_) -> puts(1)", "Shape.Pair(_, _) -> puts(2)",
              "Shape.Boxed(_) -> puts(3)"]), "CHECK-NON-EXHAUSTIVE-CASE", Starts("case shape")),
    ("a guarded arm and an unguarded arm of the same variant cover it",
     case_of(["Shape.Dot if 1 > 2 -> puts(0)", "Shape.Dot -> puts(5)", "Shape.Circle(_) -> puts(1)",
              "Shape.Pair(_, _) -> puts(2)", "Shape.Boxed(_) -> puts(3)"]), None, None),
    ("the same pattern may come again after a guarded arm, guarded or not",
     case_of(["Shape.Circle(r) if r > 9 -> puts(r)", "Shape.Circle(r) if r > 5 -> puts(r)",
              "Shape.Circle(r) -> puts(r)", "_ -> puts(0)"]), None, None),
    ("an unguarded arm covers its variant for the arms after it",
     case_of(["Shape.Circle(r) -> puts(r)", "Shape.Circle(r) if r > 5 -> puts(r)", "_ -> puts(0)"]),
     "CHECK-UNREACHABLE-CASE-ARM", Starts("Shape.Circle(r) if r > 5 -> puts(r)")),
    ("a guarded catch-all does not make the case exhaustive",
     case_of(["Shape.Dot -> puts(0)", "_ if 1 > 2 -> puts(1)"]), "CHECK-NON-EXHAUSTIVE-CASE", Starts("case shape")),
    ("a guarded catch-all may come before arms",
     case_of(["_ if 1 > 2 -> puts(1)", "Shape.Dot -> puts(0)", "_ -> puts(2)"]), None, None),
    ("an unguarded catch-all makes the arms after it unreachable, guarded or not",
     case_of(["_ -> puts(1)", "Shape.Dot if 1 > 2 -> puts(0)"]), "CHECK-UNREACHABLE-CASE-ARM",
     Starts("Shape.Dot if 1 > 2 -> puts(0)")),
    ("literals with guards need a final catch-all",
     main_with("  n = 3\n  case n\n    1 if n > 0 -> puts(1)\n    2 -> puts(2)\n  end\n"),
     "CHECK-NON-EXHAUSTIVE-CASE", Starts("case n")),
    ("a literal may come again after a guarded literal arm",
     main_with("  n = 3\n  case n\n    1 if n > 5 -> puts(0)\n    1 -> puts(1)\n    _ -> puts(2)\n  end\n"),
     None, None),
    ("a guard calls functions and builtins",
     'def small?(n: Int) -> Bool\n  return n < 10\nend\n\n'
     + main_with("  n = 3\n  case n\n    _ if small?(n) and n.to_s.length == 1 -> puts(1)\n    _ -> puts(2)\n  end\n",
                 ""), None, None),
    # Nested patterns.
    ("a literal, a name and _ in payload positions",
     case_of(["Shape.Pair(1, y) -> puts(y)", "Shape.Pair(-2, _) -> puts(0)", "Shape.Pair(x, 3) -> puts(x)",
              "Shape.Pair(_, _) -> puts(9)", "Shape.Circle(_) -> puts(1)", "Shape.Boxed(_) -> puts(1)",
              "Shape.Dot -> puts(2)"]), None, None),
    ("a nested variant and ok(...) and error(...)",
     case_of(["Shape.Boxed(Option.Some(n)) -> puts(n)", "Shape.Boxed(Option.None) -> puts(0)",
              "Shape.Boxed(_) -> puts(1)", "_ -> puts(2)"]), None, None),
    ("nested patterns to a depth of three",
     'enum Deep\n  Leaf(Int)\n  Node(Deep)\nend\n\n'
     + main_with("  d = Deep.Node(Deep.Node(Deep.Leaf(4)))\n  case d\n"
                 "    Deep.Node(Deep.Node(Deep.Leaf(n))) -> puts(n)\n    _ -> puts(0)\n  end\n", ""), None, None),
    ("a pattern in a Result payload",
     main_with("  r: Result[Option] = Result.Ok(Option.Some(1))\n  case r\n    ok(Option.Some(n)) -> puts(n)\n"
               "    ok(_) -> puts(0)\n    error(\"x\") -> puts(1)\n    error(_) -> puts(2)\n  end\n"), None, None),
    ("a literal of the wrong type in a payload position",
     case_of(["Shape.Circle(\"a\") -> puts(0)", "_ -> puts(1)"]), "CHECK-PATTERN-TYPE", '"a"'),
    ("a literal in the position of a non-primitive payload",
     case_of(["Shape.Boxed(1) -> puts(0)", "_ -> puts(1)"]), "CHECK-PATTERN-TYPE", "1"),
    ("a nested variant of another enum",
     case_of(["Shape.Boxed(Shape.Dot) -> puts(0)", "_ -> puts(1)"]), "CHECK-PATTERN-TYPE", "Shape.Dot"),
    ("a nested variant that the enum does not have",
     case_of(["Shape.Boxed(Option.Maybe(1)) -> puts(0)", "_ -> puts(1)"]), "CHECK-UNKNOWN-VARIANT",
     "Option.Maybe(1)"),
    ("a nested variant with the wrong number of positions",
     case_of(["Shape.Boxed(Option.Some(1, 2)) -> puts(0)", "_ -> puts(1)"]), "CHECK-ARITY", "Option.Some(1, 2)"),
    ("a name may appear once in an arm, also across nesting",
     case_of(["Shape.Pair(a, a) -> puts(a)", "_ -> puts(1)"]), "CHECK-SHADOWED-NAME", "Shape.Pair(a, a)"),
    ("a name in a nested pattern may not repeat a name that is visible",
     main_with("  n = 5\n  r: Result[Option] = Result.Ok(Option.Some(1))\n  case r\n"
               "    ok(Option.Some(n)) -> puts(n)\n    _ -> puts(0)\n  end\n"),
     "CHECK-SHADOWED-NAME", "Option.Some(n)"),
    ("a name may not repeat in two nested patterns of one arm",
     'enum Twin\n  Both(Option, Option)\nend\n\n'
     + main_with("  t = Twin.Both(Option.Some(1), Option.None)\n  case t\n"
                 "    Twin.Both(Option.Some(a), Option.Some(a)) -> puts(a)\n    _ -> puts(0)\n  end\n", ENUMS),
     "CHECK-SHADOWED-NAME", "Option.Some(a)"),
    ("a refutable arm does not cover its variant",
     case_of(["Shape.Circle(1) -> puts(1)", "Shape.Dot -> puts(0)", "Shape.Pair(_, _) -> puts(2)",
              "Shape.Boxed(_) -> puts(3)"]), "CHECK-NON-EXHAUSTIVE-CASE", Starts("case shape")),
    ("a refutable arm may be followed by the same variant",
     case_of(["Shape.Circle(1) -> puts(1)", "Shape.Circle(1) -> puts(8)", "Shape.Circle(n) -> puts(n)",
              "Shape.Dot -> puts(0)", "Shape.Pair(_, _) -> puts(2)", "Shape.Boxed(_) -> puts(3)"]), None, None),
    ("an arm with only names covers its variant, so the next arm of it is unreachable",
     case_of(["Shape.Circle(n) -> puts(n)", "Shape.Circle(1) -> puts(1)", "_ -> puts(0)"]),
     "CHECK-UNREACHABLE-CASE-ARM", Starts("Shape.Circle(1) -> puts(1)")),
    ("a top-level name is still not a pattern",
     case_of(["n -> puts(n)"]), "PARSE-UNEXPECTED-TOKEN", "n"),
    ("a pattern with empty parentheses",
     case_of(["Shape.Boxed(Option.Some()) -> puts(0)", "_ -> puts(1)"]), "PARSE-UNEXPECTED-TOKEN", ")"),
    ("a minus sign that no number follows in a payload position",
     case_of(["Shape.Circle(-x) -> puts(0)", "_ -> puts(1)"]), "PARSE-UNEXPECTED-TOKEN", "-"),
    ("a guard needs a condition",
     case_of(["Shape.Dot if -> puts(0)", "_ -> puts(1)"]), "PARSE-UNEXPECTED-TOKEN", "->"),
    ("an arm after a guarded arm of a case that is the body of an arm",
     main_with("  n = 3\n  case n\n    1 ->\n      case n\n        _ if n > 5 -> puts(0)\n"
               "        _ -> puts(1)\n      end\n    _ -> puts(2)\n  end\n"), None, None),
    # Several patterns in one arm.
    ("an arm of several patterns covers each variant it names",
     case_of(["Shape.Dot, Shape.Circle(_) -> puts(0)", "Shape.Pair(_, _), Shape.Boxed(_) if 1 > 2 -> puts(1)",
              "Shape.Pair(_, _), Shape.Boxed(_) -> puts(2)"]), None, None),
    ("an arm of several patterns binds no names",
     case_of(["Shape.Dot, Shape.Circle(r) -> puts(0)", "_ -> puts(1)"]), "CHECK-CASE-ARM-BINDING",
     "Shape.Dot, Shape.Circle(r)"),
    ("a pattern that an earlier arm covers is unreachable at its own span",
     case_of(["Shape.Dot -> puts(0)", "Shape.Circle(_), Shape.Dot -> puts(1)", "_ -> puts(2)"]),
     "CHECK-UNREACHABLE-CASE-ARM", "Shape.Dot"),
    ("a literal repeated in one arm is a duplicate at its own span",
     main_with("  n = 3\n  case n\n    1, 2, 1 -> puts(1)\n    _ -> puts(2)\n  end\n"),
     "CHECK-UNREACHABLE-CASE-ARM", "1"),
    ("a pattern after a catch-all of the same arm is unreachable",
     main_with("  n = 3\n  case n\n    _, 1 -> puts(1)\n  end\n"), "CHECK-UNREACHABLE-CASE-ARM", "1"),
    ("each pattern of an arm has the type of the value",
     main_with("  n = 3\n  case n\n    1, \"a\" -> puts(1)\n    _ -> puts(2)\n  end\n"), "CHECK-PATTERN-TYPE",
     '"a"'),
    ("the patterns of an arm stay on its line",
     main_with("  n = 3\n  case n\n    1,\n      2 -> puts(1)\n    _ -> puts(2)\n  end\n"),
     "PARSE-UNEXPECTED-TOKEN", Starts("\n")),
    # A case that gives a value: after `=`, `+=` or `return`, and as the last line of a block.
    ("a case gives the value of an assignment, an annotated assignment and a compound assignment",
     main_with("  n = 3\n  a = case n\n    3 ->\n      base = n * 2\n      base + 1\n    _ -> 0\n  end\n"
               "  b: Int = case n\n    _ -> a\n  end\n  b += case a\n    7 -> 1\n    _ -> 2\n  end\n  puts(b)\n"),
     None, None),
    ("a case gives the value of a return, over an enum, with a payload name in an arm",
     main_with("  puts(size(Shape.Dot))\n", ENUMS + 'def size(shape: Shape) -> Int\n  return case shape\n'
               '    Shape.Circle(r) -> r\n    Shape.Pair(a, b) -> a + b\n    _ -> 0\n  end\nend\n\n'), None, None),
    ("a case on the last line of a block gives the value of the block",
     main_with("  names = [Shape.Dot, Shape.Circle(1)].map do |shape|\n    case shape\n      Shape.Dot -> \"dot\"\n"
               "      _ -> \"other\"\n    end\n  end\n  puts(names)\n"), None, None),
    ("a case on the last line of a block with no value stays a statement, whatever its arms end with",
     main_with("  [1, 2].each do |n|\n    case n\n      1 -> puts(\"a\")\n      _ -> puts(2)\n    end\n  end\n"),
     None, None),
    ("the arms of a case that gives a value have one type, reported at the arm's last expression",
     main_with("  x = case 1\n    1 -> \"a\"\n    _ ->\n      puts(\"other\")\n      2\n  end\n  puts(x)\n"),
     "CHECK-TYPE-MISMATCH", "2"),
    ("the arms agree with the annotation of the assignment",
     main_with("  x: Int = case 1\n    1 -> \"a\"\n    _ -> 2\n  end\n  puts(x)\n"), "CHECK-TYPE-MISMATCH", '"a"'),
    ("the arms agree with the result of the function after return",
     'def f(n: Int) -> String\n  return case n\n    1 -> "a"\n    _ -> n\n  end\nend\n\n'
     + main_with("  puts(f(1))\n", ""), "CHECK-TYPE-MISMATCH", "n"),
    ("a case that ends a block of unknown result stays a statement when an arm is Void",
     main_with("  n = 1\n  t = Task.spawn do\n    case n\n      1 -> puts(\"a\")\n      _ -> compute()\n    end\n  end\n"
               "  Task.await(t)\n  u = Task.spawn do\n    case n\n      1 -> compute()\n      _ -> puts(\"a\")\n    end\n"
               "  end\n  Task.await(u)\n", "def compute() -> Int\n  return 5\nend\n\n"), None, None),
    ("arms of two non-Void types of a case that ends a block of unknown result mismatch, even beside a Void arm",
     main_with("  n = 1\n  t = Task.spawn do\n    case n\n      1 -> 1\n      2 -> \"s\"\n      _ -> puts(\"z\")\n"
               "    end\n  end\n  Task.await(t)\n"), "CHECK-TYPE-MISMATCH", '"s"'),
    ("a case that ends a block of unknown result gives its value when the arms agree",
     main_with("  n = 1\n  t = Task.spawn do\n    case n\n      1 -> compute()\n      _ -> 2\n    end\n  end\n"
               "  ints: List[Task[Int]] = [t]\n  puts(ints.size)\n", "def compute() -> Int\n  return 5\nend\n\n"),
     None, None),
    ("a block of unknown result with a case of Int arms is a Task[Int], not a Task[Void]",
     main_with("  n = 1\n  t = Task.spawn do\n    case n\n      1 -> compute()\n      _ -> 2\n    end\n  end\n"
               "  voids: List[Task[Void]] = [t]\n  puts(voids.size)\n", "def compute() -> Int\n  return 5\nend\n\n"),
     "CHECK-TYPE-MISMATCH", "t"),
    ("the arms of a case on the last line of a block have one type",
     main_with("  xs = [1, 2].map do |n|\n    case n\n      1 -> \"a\"\n      _ -> 2\n    end\n  end\n  puts(xs)\n"),
     "CHECK-TYPE-MISMATCH", "2"),
    ("a case that gives a value must be exhaustive",
     case_value_of(["Shape.Dot -> 1", "Shape.Circle(_) -> 2"]), "CHECK-NON-EXHAUSTIVE-CASE", Starts("case shape")),
    ("an arm of a case that gives a value ends with an expression",
     case_value_of(["Shape.Dot -> 1", "_ ->\n      y = 2"]), "CHECK-CASE-ARM-VALUE", Starts("y = 2")),
    ("an arm of a case that gives a value is not empty",
     case_value_of(["Shape.Dot -> 1", "_ ->"]), "CHECK-CASE-ARM-VALUE", Starts("_ ->")),
    ("a case is still not an expression as an argument",
     main_with("  puts(case 1\n    _ -> 2\n  end)\n"), "PARSE-UNEXPECTED-TOKEN", "case"),
    ("a case is still not an operand",
     main_with("  x = 1 + case 1\n    _ -> 2\n  end\n  puts(x)\n"), "PARSE-UNEXPECTED-TOKEN", "case"),
]

# (title, program, expected lines): the program runs and prints these.
RUNS = [
    ("a case gives a value after =, += and return, and as the last line of a block",
     ENUMS + 'def label(shape: Shape) -> String\n  return case shape\n    Shape.Circle(r) if r > 100 -> "big"\n'
     '    Shape.Circle(_) -> "circle"\n    Shape.Pair(a, b) ->\n      sum = a + b\n      "pair #{sum}"\n'
     '    _ -> "other"\n  end\nend\n\n'
     + main_with("  r: Result[Int] = Result.Err(\"boom\")\n  text = case r\n    ok(n) -> \"ok #{n}\"\n"
                 "    error(m) -> \"failed: #{m}\"\n  end\n  puts(text)\n  total = 1\n  total += case text\n"
                 "    \"x\" -> 10\n    _ -> 20\n  end\n  puts(total)\n"
                 "  shapes = [Shape.Circle(500), Shape.Circle(1), Shape.Pair(1, 2), Shape.Dot]\n"
                 "  puts(shapes.map do |shape| label(shape) end)\n"
                 "  puts(shapes.map do |shape|\n    case shape\n      Shape.Circle(radius) -> radius\n      _ -> 0\n    end\n  end)\n",
                 ""),
     ["failed: boom", "21", '["big", "circle", "pair 3", "other"]', "[500, 1, 0, 0]"]),
    ("only the arm that matches computes its value",
     'def noisy(n: Int) -> Int\n  puts("noisy #{n}")\n  return n\nend\n\n'
     + main_with("  x = case 2\n    1 -> noisy(1)\n    2 -> noisy(2)\n    _ -> noisy(3)\n  end\n  puts(x)\n", ""),
     ["noisy 2", "2"]),
    ("guards pick the first arm that matches and whose condition is true",
     main_with("  items = [Shape.Circle(0), Shape.Circle(7), Shape.Circle(200), Shape.Pair(3, 3), Shape.Pair(1, 2),\n"
               "           Shape.Dot]\n"
               "  for shape in items\n    case shape\n"
               "      Shape.Circle(0) -> puts(\"empty\")\n      Shape.Circle(r) if r > 100 -> puts(\"big #{r}\")\n"
               "      Shape.Circle(r) -> puts(\"circle #{r}\")\n"
               "      Shape.Pair(a, b) if a == b -> puts(\"same #{a}\")\n"
               "      Shape.Pair(a, _) -> puts(\"pair #{a}\")\n      Shape.Boxed(_) -> puts(\"boxed\")\n"
               "      Shape.Dot -> puts(\"dot\")\n    end\n  end\n"),
     ["empty", "circle 7", "big 200", "same 3", "pair 1", "dot"]),
    ("nested patterns test the tag and the literals of a payload, then bind",
     main_with("  items = [Shape.Pair(1, 5), Shape.Pair(2, 3), Shape.Boxed(Option.Some(4)),\n"
               "           Shape.Boxed(Option.Some(9)), Shape.Boxed(Option.None), Shape.Circle(2)]\n"
               "  for shape in items\n    case shape\n"
               "      Shape.Pair(1, y) -> puts(\"one then #{y}\")\n"
               "      Shape.Pair(x, 3) -> puts(\"#{x} then three\")\n"
               "      Shape.Boxed(Option.Some(9)) -> puts(\"boxed nine\")\n"
               "      Shape.Boxed(Option.Some(n)) -> puts(\"boxed #{n}\")\n"
               "      Shape.Boxed(Option.None) -> puts(\"boxed none\")\n"
               "      _ -> puts(\"other\")\n    end\n  end\n"),
     ["one then 5", "2 then three", "boxed 4", "boxed nine", "boxed none", "other"]),
    ("ok and error with nested literals and guards, and a literal Int case with a guard",
     main_with("  rs: List[Result[Int]] = [Result.Ok(0), Result.Ok(-3), Result.Ok(8), Result.Err(\"boom\"),\n"
               "                           Result.Err(\"x\")]\n"
               "  for r in rs\n    case r\n      ok(0) -> puts(\"zero\")\n      ok(n) if n < 0 -> puts(\"negative\")\n"
               "      ok(n) -> puts(\"positive #{n}\")\n      error(\"boom\") -> puts(\"boom\")\n"
               "      error(m) -> puts(\"error #{m}\")\n    end\n  end\n"
               "  for n in [0, -4, 4]\n    case n\n      0 -> puts(\"zero\")\n      _ if n < 0 -> puts(\"neg\")\n"
               "      _ -> puts(\"pos\")\n    end\n  end\n", ""),
     ["zero", "negative", "positive 8", "boom", "error x", "zero", "neg", "pos"]),
    ("a guard sees names of nested patterns and runs only when the pattern matched",
     main_with("  d = Shape.Boxed(Option.Some(6))\n  case d\n"
               "    Shape.Boxed(Option.Some(n)) if 12 / n == 2 -> puts(\"half #{n}\")\n"
               "    _ -> puts(\"other\")\n  end\n"
               "  e = Shape.Boxed(Option.None)\n  case e\n"
               "    Shape.Boxed(Option.Some(n)) if 12 / n == 2 -> puts(\"half\")\n    _ -> puts(\"none\")\n  end\n"),
     ["half 6", "none"]),
    ("the scrutinee is evaluated once, and a failed guard falls through to the next arm",
     'def next_value(n: Int) -> Int\n  puts("evaluated")\n  return n\nend\n\n'
     + main_with("  case next_value(5)\n    0 -> puts(\"zero\")\n    _ if 1 > 2 -> puts(\"never\")\n"
                 "    _ -> puts(\"other\")\n  end\n", ""),
     ["evaluated", "other"]),
    ("an arm of several patterns matches when any of them does, in a statement and as a value",
     main_with("  for option in [\"ex\", \"px\", \"exat\", \"keep\"]\n    case option\n"
               "      \"ex\", \"px\" -> puts(\"ttl\")\n      \"exat\", \"pxat\" if option.size > 3 -> puts(\"at\")\n"
               "      _ -> puts(\"other\")\n    end\n  end\n"
               "  shapes = [Shape.Dot, Shape.Circle(1), Shape.Boxed(Option.Some(2)), Shape.Boxed(Option.None),\n"
               "            Shape.Pair(1, 2)]\n"
               "  puts(shapes.map do |shape|\n    case shape\n      Shape.Dot, Shape.Circle(_) -> \"small\"\n"
               "      Shape.Boxed(Option.Some(2)), Shape.Pair(1, _) -> \"two or pair\"\n      _ -> \"other\"\n"
               "    end\n  end)\n"),
     ["ttl", "ttl", "at", "other", '["small", "small", "two or pair", "other", "two or pair"]']),
]

# Several files: (title, files, code, file of the diagnostic, text the range covers).
MODULES = [
    ("a nested variant through an import alias",
     {"models.agc": "export enum Option\n  Some(Int)\n  None\nend\n\nexport enum Shape\n  Boxed(Option)\nend\n\n",
      "root.agc": 'import Models from "models"\n\n'
                  + main_with("  s = Models.Shape.Boxed(Models.Option.Some(1))\n  case s\n"
                              "    Models.Shape.Boxed(Models.Option.Some(n)) if n > 0 -> puts(n)\n"
                              "    Models.Shape.Boxed(_) -> puts(0)\n  end\n", "")},
     None, None, None),
    ("a nested variant of an enum that the file does not import",
     {"models.agc": "export enum Option\n  Some(Int)\n  None\nend\n\nexport enum Shape\n  Boxed(Option)\nend\n\n",
      "root.agc": 'import Models from "models"\n\n'
                  + main_with("  s = Models.Shape.Boxed(Models.Option.Some(1))\n  case s\n"
                              "    Models.Shape.Boxed(Gone.Some(n)) -> puts(n)\n    Models.Shape.Boxed(_) -> puts(0)\n"
                              "  end\n", "")},
     "CHECK-PATTERN-TYPE", "root.agc", "Gone.Some(n)"),
]


def assert_span_covers(program, span, expected):
    seen = covered(program, span)
    if isinstance(expected, Starts):
        assert seen.startswith(expected.text), seen
    else:
        assert seen.rstrip("\n") == expected


@pytest.fixture(scope="module")
def batches(tmp_path_factory):
    """The SINGLE_FILE and the MODULES programs, each table checked by one `check` call."""
    return (check_many([case[1] for case in SINGLE_FILE], tmp_path_factory.mktemp("patterns"), "program.agc"),
            check_many([case[1] for case in MODULES], tmp_path_factory.mktemp("patterns-modules"), "root.agc"))


@pytest.mark.parametrize("case", SINGLE_FILE, ids=[case[0] for case in SINGLE_FILE])
def test_single_file_programs(case, batches):
    _, program, code, text = case
    assert_single_file_case(batches[0], program, code, text, assert_span_covers)


@pytest.mark.parametrize("case", MODULES, ids=[case[0] for case in MODULES])
def test_programs_of_several_files(case, batches):
    _, files, code, file, text = case
    assert_multi_file_case(batches[1], files, code, file, text, assert_span_covers)


@pytest.mark.parametrize(
    ("title", "program", "lines"), RUNS, ids=[case[0] for case in RUNS]
)
def test_programs_print_what_the_rules_say(title, program, lines, tmp_path):
    path = tmp_path / "run.agc"
    path.write_text(program, encoding="utf-8")
    result = run(cli() + [str(path)])
    assert (result.code, result.stdout.splitlines()) == (0, lines), result.stderr


def test_nesting_depth_is_bounded_like_expressions(agentica_check):
    def deep(levels, tail=""):
        pattern = "Deep.Node(" * levels + "Deep.Leaf" + ")" * levels
        return (
            "enum Deep\n  Leaf\n  Node(Deep)\nend\n\ndef main() -> Void\n  x = Deep.Leaf\n  case x\n"
            "    " + pattern + " -> puts(1)\n" + tail + "    _ -> puts(2)\n  end\nend\n\n"
        )

    # The parser and lookahead stay iterative at the same 1000-level limit.
    assert agentica_check(deep(900)) is None
    assert agentica_check(deep(1001))["code"] == "PARSE-TOO-DEEP"
    later = "    " + "Deep.Node(" * 3000 + "Deep.Leaf" + ")" * 3000 + " -> puts(3)\n"
    assert agentica_check(deep(1, later))["code"] == "PARSE-TOO-DEEP"
