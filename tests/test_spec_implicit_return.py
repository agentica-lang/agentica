"""The last expression of a def is its value (#1287), through the product CLI: `--json check FILE`, asserting the
code and the source text that the range covers, never the message.

The rule: in a def whose result is not written `Void`, an expression statement at the end of the body is the value,
and so is one at the end of each branch of a last `if` that has an `else` and of each arm of a last `case`, at any
depth. An `if` without `else`, a loop, a binding or a `try` at the end gives no value, so the def fails as before. The
fixture tests/fixtures/vm/implicit-return.agc runs the rule, against a Python and a Node peer."""
import re

import pytest

from tests.agentica_test import FIXTURES, PYTHON, cli, run, tool, vm_environment
from tests.spec_support import check_diagnostic, covered

# Programs that check: the value at the end of the body, of every branch and of every arm, nested, generic, after a
# guard, a one-line def, `Nil`, a def whose result is an alias of Void (which drops the value of a call), and a `case`
# value.
ACCEPTED = {
    "body": "def f(t: String) -> Int\n  t.size\nend\n",
    "literal": "def f() -> Int\n  1\nend\n",
    "if_elsif_else": "def f(x: Int) -> Int\n  if x > 0\n    x\n  elsif x < 0\n    0 - x\n  else\n    0\n  end\nend\n",
    "case": 'def f(x: Int) -> String\n  case x\n    0 -> "zero"\n    _ -> "many"\n  end\nend\n',
    "nested": (
        "def f(x: Int) -> Int\n  if x > 0\n    case x\n      1 -> 10\n      _ ->\n        if x > 5\n          50\n"
        "        else\n          5\n        end\n    end\n  else\n    0\n  end\nend\n"
    ),
    "mixed": "def f(x: Int) -> Int\n  if x > 0\n    return x\n  else\n    0\n  end\nend\n",
    "after_guard": "def f(x: Int) -> Int\n  return 0 if x < 0\n  x * 2\nend\n",
    "generic": "def pick[T](a: T, b: T) -> T\n  a\nend\n",
    "one_line": "def f(x: Int) -> Int = x + 1\n",
    "nil": "def f() -> Nil\n  nil\nend\n",
    "result": "def g() -> Result[Int] = ok(1)\n\ndef f() -> Result[Int]\n  v = try g()\n  ok(v + 1)\nend\n",
    "void_alias_call": 'type Nothing = Void\n\ndef name() -> String = "n"\n\ndef f() -> Nothing\n  name()\nend\n',
    "case_value": "def f(x: Int) -> Int\n  y = case x\n    0 -> 1\n    _ -> 2\n  end\n  y\nend\n",
    "block_untouched": "def f(xs: List[Int]) -> List[Int]\n  xs.map do |x|\n    x * 2\n  end\nend\n",
}


@pytest.mark.parametrize("name", list(ACCEPTED))
def test_the_last_expression_gives_the_value(tmp_path, name):
    assert check_diagnostic(ACCEPTED[name], tmp_path) is None


# Programs that do not check: the code and the source text the range covers. "DEF" covers the whole def, as for a
# def with no value on some path; the others point at the statement or the expression.
WHOLE_DEF = "DEF"
REJECTED = {
    # No value on a path: the code and the span of a def that returns nothing there, as before #1287.
    "if_without_else": ("def f(x: Int) -> Int\n  if x > 0\n    x\n  end\nend\n", "CHECK-MISSING-RETURN", WHOLE_DEF),
    "arm_if_without_else": (
        "def f(x: Int) -> Int\n  case x\n    0 ->\n      if x == 0\n        1\n      end\n    _ -> 2\n  end\nend\n",
        "CHECK-MISSING-RETURN",
        WHOLE_DEF,
    ),
    "arm_guard": (
        "def f(x: Int) -> Int\n  case x\n    0 -> return 1 if true\n    _ -> 2\n  end\nend\n",
        "CHECK-MISSING-RETURN",
        WHOLE_DEF,
    ),
    "while_last": ("def f(x: Int) -> Int\n  while x > 0\n    x -= 1\n  end\nend\n", "CHECK-MISSING-RETURN", WHOLE_DEF),
    "binding_last": ("def f(x: Int) -> Int\n  y = x + 1\nend\n", "CHECK-MISSING-RETURN", WHOLE_DEF),
    "try_last": (
        "def g() -> Result[Int] = ok(1)\n\ndef f() -> Result[Int]\n  try g()\nend\n",
        "CHECK-MISSING-RETURN",
        WHOLE_DEF,
    ),
    # A last expression that gives no value (a Void call): the same code, at that expression.
    "void_call": ('def f() -> Int\n  puts("a")\nend\n', "CHECK-MISSING-RETURN", 'puts("a")'),
    "void_branch": (
        'def f(x: Int) -> Int\n  if x > 0\n    1\n  else\n    puts("a")\n  end\nend\n',
        "CHECK-MISSING-RETURN",
        'puts("a")',
    ),
    # A value of the wrong type, at the expression.
    "wrong_type": ('def name() -> String = "a"\n\ndef f() -> Int\n  name()\nend\n', "CHECK-TYPE-MISMATCH", "name()"),
    "wrong_branch": (
        'def f(x: Int) -> Int\n  if x > 0\n    1\n  else\n    "a"\n  end\nend\n',
        "CHECK-TYPE-MISMATCH",
        '"a"',
    ),
    "result_in_int": ('def f() -> Int\n  "1".to_i\nend\n', "CHECK-TYPE-MISMATCH", '"1".to_i'),
    # A case that misses a variant, and an expression after a return.
    "case_not_exhaustive": (
        "enum E\n  A\n  B\nend\n\ndef f(e: E) -> Int\n  case e\n    E.A -> 1\n  end\nend\n",
        "CHECK-NON-EXHAUSTIVE-CASE",
        "case e\n    E.A -> 1\n  end\n",
    ),
    "after_return": ("def f(x: Int) -> Int\n  return 1\n  x\nend\n", "CHECK-UNREACHABLE-CODE", "x"),
    # A Void def, `main` and a def whose result is an alias of Void drop their last value, so a value that could only
    # be used for itself is still an error there.
    "main_value": ('def main() -> Void\n  "a".size\nend\n', "CHECK-UNUSED-VALUE", '"a".size'),
    "void_alias_value": ('type Nothing = Void\n\ndef f() -> Nothing\n  "a".size\nend\n', "CHECK-UNUSED-VALUE", '"a".size'),
    "void_result": ('def f() -> Void\n  "1".to_i\nend\n', "CHECK-UNUSED-RESULT", '"1".to_i'),
}


@pytest.mark.parametrize("name", list(REJECTED))
def test_a_path_with_no_value_or_a_wrong_one_is_reported_where_it_is(tmp_path, name):
    program, code, covers = REJECTED[name]
    found = check_diagnostic(program, tmp_path)
    assert (found and found["code"]) == code, program
    text = covered(program, found["range"])
    if covers == WHOLE_DEF:
        assert text.startswith("def f(") and text.rstrip().endswith("end"), text
    else:
        assert text == covers, program


def test_the_fixture_prints_what_the_python_and_node_peers_print():
    fixture = FIXTURES / "vm" / "implicit-return.agc"
    result = run(cli() + [str(fixture)], env=vm_environment())
    assert result.code == 0, result.stderr
    python = run([PYTHON, str(FIXTURES / "implicit-return-peer.py")])
    node = run([tool("node"), str(FIXTURES / "implicit-return-peer.js")])
    assert (python.code, node.code) == (0, 0)
    assert result.stdout == python.stdout == node.stdout


ALIAS_VOID = """type Nothing = Void

def name() -> String = "n"

def f() -> Nothing
  name()
end

def main() -> Void
  f()
end
"""


def test_a_def_whose_result_is_an_alias_of_void_lowers_as_a_void_def(tmp_path):
    # Its last expression is a statement: the call is not a tail call that returns the String, so `f` stays in a
    # backtrace. The IR is the one of the def written `Void`, positions and the file name aside.
    def instructions(source):
        path = tmp_path / "program.agc"
        path.write_text(source, encoding="utf-8")
        result = run(cli() + ["--dump-ir", str(path)], env=vm_environment())
        assert result.code == 0, result.stderr
        lines = [line for line in result.stdout.splitlines() if not line.startswith("source ")]
        return [re.sub(r" @ [\d:-]+$", "", line) for line in lines]

    assert instructions(ALIAS_VOID) == instructions(ALIAS_VOID.replace("-> Nothing", "-> Void"))


# `fmt` cannot see an alias of Void imported from another file, so it writes a last `return count_down(n - 1)` there
# as the bare call. That call is still the tail call that `return` gives, so deep recursion does not overflow.
COUNT_DOWN = """import {Nothing} from "./types"

def count_down(n: Int) -> Nothing
  return if n == 0
  %s
end

def main() -> Void
  count_down(200000)
  puts("done")
end
"""


@pytest.mark.parametrize("last", ["return count_down(n - 1)", "count_down(n - 1)"])
def test_a_last_void_call_in_a_def_of_an_imported_void_alias_is_a_tail_call(tmp_path, last):
    (tmp_path / "types.agc").write_text("export type Nothing = Void\n", encoding="utf-8")
    path = tmp_path / "main.agc"
    path.write_text(COUNT_DOWN % last, encoding="utf-8")
    result = run(cli() + [str(path)], env=vm_environment())
    assert (result.code, result.stdout) == (0, "done\n"), result.stderr
