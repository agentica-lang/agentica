"""The parser rules of the language, through the product CLI.

Each case writes a program to a temp file and runs the CLI on it. A rejected program is asserted by its diagnostic
code and, where a position is part of the rule, by the start (and end) of its range. A valid program is asserted by
a clean `check`, or by the output of a run where the output shows the rule (a precedence, a desugaring, an
evaluation order). Help and message texts are not asserted (AGENTS.md).
"""
import json
from collections import namedtuple

import pytest

from tests.agentica_test import cli, output_lines, run, vm_environment

# span: (line, column) of the start, (line, column, line, column) with the end too, (line,) for the line only,
# or None when the rule is not about a position.
Reject = namedtuple("Reject", "text code span files", defaults=(None, None))
Accept = namedtuple("Accept", "text files", defaults=(None,))
Output = namedtuple("Output", "text lines files", defaults=(None,))


ALPHA = "export def one() -> Int\n  return 1\nend\n"


def main_of(body):
    """A program whose main() has the statements `body` (each line indented, ending with a newline)."""
    return "def main() -> Void\n" + body + "end\n\n"


def in_function(statement):
    """A program with one function f() whose body is `statement`."""
    return "def f() -> Void\n  " + statement + "\nend\n\n"


def span_of(diagnostic):
    where = diagnostic["range"]
    return (where["start"]["line"], where["start"]["column"], where["end"]["line"], where["end"]["column"])


# A result of the `try` rules: good and add return Result, plus returns a plain Int.
TRY_PRELUDE = (
    "def good(n: Int) -> Result[Int]\n  return Result.Ok(n)\nend\n\n"
    "def plus(a: Int, b: Int) -> Int\n  return a + b\nend\n\n"
    "def add(a: Int, b: Int) -> Result[Int]\n  return Result.Ok(a + b)\nend\n\n"
)

SHAPE = "export enum Shape\n  Dot\n  Circle(Int)\nend\n"

# The habits of other languages, each with the line of its first problem (the case arms start one line lower).
HABITS = [
    ("  case x\n    when 1\n      puts(\"a\")\n  end", 3),
    ("  let x = 5", 2),
    ("  var x = 5", 2),
    ("  match x", 2),
    ("  if x then\n    puts(\"a\")\n  end", 2),
    ("  f = fn(x: Int) -> Int", 2),
    ("  f = lambda do |x|\n    x\n  end", 2),
    ("  f = do |x|\n    x\n  end", 2),
    ("  ys = run do |x| x end", 2),
    ("  if x > 0 do\n    puts(\"a\")\n  end", 2),
    ("  loop do\n    puts(\"a\")\n  end", 2),
    ("  // note", 2),
    ("  x = 4 // 2", 2),
    ("  /* note */", 2),
    ("  xs = [1]\n  xs << 2", 3),
    ("  x = 4 if x > 3", 2),
    ("  puts(\"a\") if x", 2),
    ("  n = String.length \"abc\"", 2),
    ("  case r\n    ok() -> puts(\"a\")\n  end", 3),
    ("  case r\n    Await.Done() -> puts(\"a\")\n  end", 3),
    ("  case r\n    Await.TimedOut() -> puts(\"a\")\n  end", 3),
    ("  while x {\n    puts(\"a\")\n  }", 2),
    ("  if x {\n    puts(\"a\")\n  }", 2),
    ("  for x in xs {\n    puts(\"a\")\n  }", 2),
]

BRACES = [
    ("def main() -> Void {\n  puts(1)\n}\n", (1, 20)),
    ("def main() {\n  puts(1)\n}\n", (1, 12)),
    ("def main() -> Void\n  if x\n    puts(1)\n  else {\n    puts(2)\n  }\nend\n", (4, 8)),
    ("def main() -> Void\n  case x {\n    1 -> puts(1)\n  }\nend\n", (2, 10)),
    ("def main() -> Void\n  xs.each do |x| {\n    puts(x)\n  }\nend\n", (4, 3)),
]

# Each detached doc block is PARSE-DETACHED-DOC at its first line (and column).
DETACHED_DOCS = [
    ("def a() -> Void\nend\n\n## d\n\ndef b() -> Void\nend\n", (4, 1)),
    ("def a() -> Void\nend\n\n## d\n# note\ndef b() -> Void\nend\n", (4, 1)),
    ("## d\n# note\n\ndef a() -> Void\nend\n", (1, 1)),
    ("## d\n## e\n# note\n\ndef a() -> Void\nend\n", (1, 1)),
    ("import A from \"a\"\n## d\nimport B from \"b\"\n", (2, 1)),
    ("## d\nimport A from \"a\"\n", (1, 1)),
    ("import A from \"a\"\n\n## d\n\ndef a() -> Void\nend\n", (3, 1)),
    ("def main() -> Void\n  ## d\n  ## e\n  x = 1\nend\n", (2, 3)),
    ("def main() -> Void\n  x = 1\n  ## d\nend\n", (3, 3)),
    ("def main() -> Void\n  f(1,\n## d\n2)\nend\n", (3, 1)),
    ("def main() -> Void\n  f(1\n## d\n)\nend\n", (3, 1)),
    ("def a() -> Void\nend\n\n## d\n", (4, 1)),
    ("def a() -> Void\nend\n\n## d", (4, 1)),
    ("## d\n", (1, 1)),
    ("## d", (1, 1)),
    ("## a\n\n## b\n\ndef a() -> Void\nend\n", (3, 1)),
    ("## d\nputs(1)\n", (1, 1)),
    ("struct S\n  a: Int\n  ## d\nend\n", (3, 3)),
    ("struct S\n  ## d\n\n  a: Int\nend\n", (2, 3)),
    ("struct S\n  ## d\n  # note\n  a: Int\nend\n", (2, 3)),
    ("enum E\n  A\n  ## d\nend\n", (3, 3)),
    ("enum E\n  ## d\n\n  A\nend\n", (2, 3)),
]

# The right side of `|>` must be a call with parentheses; the span is the right side.
PIPE_TARGETS = [
    ("a |> f", (12, 13)),
    ("a |> r.field", (12, 19)),
    ("a |> xs[0]", (12, 17)),
    ("a |> f(1).g", (12, 18)),
    ("a |> f() + 1", (12, 19)),
    ("a |> 1", (12, 13)),
    ("a |> try f", (12, 17)),
    ("a |> gets", (12, 16)),
    ("a |> s.trim()", (12, 20)),
    ("3 |> (U.double)", (12, 22)),
    ("1 |> (IO.gets)", (12, 21)),
    ("3 |> U.each2 do |y: Int| y end", (12, 37)),
    ("3 |> U.each2", (12, 19)),
    ("a |> Color.Red.name()", (12, 28)),
    ("a |> try Color.Red.name()", (12, 32)),
]


class TestSpecParser:
    @pytest.fixture(autouse=True)
    def set_up(self, tmp_path):
        self._tmp_path = tmp_path
        self._temp_dir_count = 0

    def make_suite(self, files):
        self._temp_dir_count += 1
        directory = self._tmp_path / f"case-{self._temp_dir_count}"
        directory.mkdir()
        for name, text in files.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return directory

    def run_all(self, programs, *command):
        """Run the CLI with `command` on each program (text, files) and return the results in order.

        Each program is main.agc in a temp directory, with its files beside it.
        """
        results = []
        for text, files in programs:
            directory = self.make_suite({"main.agc": text, **(files or {})})
            results.append(run(cli() + [*command, str(directory / "main.agc")], env=vm_environment()))
        return results

    def check_rejected(self, cases):
        results = self.run_all([(case.text, case.files) for case in cases], "--json", "check")
        for case, result in zip(cases, results):
            if result.code != 1:
                pytest.fail("expected %s, the program was not rejected: %s" % (case.code, result.stdout))
            diagnostic = json.loads(result.stderr)
            assert (diagnostic["code"]) == (case.code), diagnostic.get("message")
            if case.span is not None:
                assert (span_of(diagnostic)[:len(case.span)]) == (case.span), diagnostic.get("message")

    def check_accepted(self, cases):
        results = self.run_all([(case.text, case.files) for case in cases], "--json", "check")
        for case, result in zip(cases, results):
            assert ((result.code, result.stdout)) == ((0, '{"ok":true}\n')), result.stderr

    def check_output(self, cases):
        results = self.run_all([(case.text, case.files) for case in cases])
        for case, result in zip(cases, results):
            assert (result.code) == (0), result.stderr
            assert (output_lines(result.stdout)) == (case.lines)

    def test_a_discard_has_no_type_annotation(self):
        self.check_accepted([Accept(main_of("  _ = 1\n"))])
        self.check_rejected([Reject(main_of("  _: Int = 1\n"), "PARSE-UNEXPECTED-TOKEN", (2, 4))])

    def test_ranges_bind_loosest_and_do_not_chain(self):
        self.check_output([
            Output(main_of("  n = 2\n  for i in 0...n + 1 do\n    puts(i)\n  end\n"), ["0", "1", "2"]),
        ])
        self.check_accepted([
            Accept(main_of("  for i in 0...3 do\n    puts(i)\n  end\n")),
            Accept(main_of("  _r = (1..5).to_a\n")),
        ])
        self.check_rejected([
            Reject(main_of("  x = 1..2..3\n"), "PARSE-UNEXPECTED-TOKEN", (2, 11, 2, 13)),
            Reject(in_function("x = 1..2 == 3..4"), "PARSE-UNEXPECTED-TOKEN"),
            Reject(main_of("  x = 1..\n  2\n"), "PARSE-UNEXPECTED-TOKEN", (2, 10)),
        ])

    def test_function_references_and_chained_calls(self):
        self.check_output([
            Output(
                "def double(n: Int) -> Int\n  return n * 2\nend\n\n"
                + main_of("  handlers: Map[String, Fn[Int, Int]] = {\"double\": &double}\n"
                          "  puts(handlers[\"double\"].call(21))\n"),
                ["42"]),
        ])
        self.check_rejected([
            Reject(main_of("  x = &nope?\n"), "CHECK-UNKNOWN-NAME", (2, 7, 2, 13)),
            Reject(main_of("  f = &\n"), "PARSE-UNEXPECTED-TOKEN"),
        ])

    def test_try_has_unary_precedence_and_a_source_span(self):
        program = TRY_PRELUDE + (
            "def f() -> Result[Int]\n"
            "  x = try good(1) + 2\n"
            "  y = try (good(1))\n"
            "  z = try good(1) |> plus(1)\n"
            "  return Result.Ok(x * 10 + y + z)\n"
            "end\n\n"
            "def main() -> Void\n"
            "  case f()\n    ok(v) -> puts(v)\n    error(_) -> puts(\"e\")\n  end\n"
            "end\n")
        self.check_output([Output(program, ["33"])])
        bad = TRY_PRELUDE + main_of("  x = try good(1) + 2\n")
        self.check_rejected([
            Reject(bad, "CHECK-TRY-CONTEXT", (bad.split("\n").index("  x = try good(1) + 2") + 1, 7)),
            Reject(main_of("  ready? = true\n"), "PARSE-UNEXPECTED-TOKEN", (2, 3)),
        ])

    def test_ruby_operators_share_nodes_and_compound_assignment_desugars(self):
        self.check_output([
            Output(main_of("  a = true\n  b = false\n  c = true\n  puts(!a && b || c)\n"
                           "  total = 1\n  total -= 2 * 3\n  puts(total)\n"),
                   ["true", "-5"]),
        ])
        self.check_rejected([
            Reject(main_of("  xs[0] += 1\n"), "PARSE-INVALID-ASSIGNMENT-TARGET"),
            Reject(main_of("  f() *= 2\n"), "PARSE-INVALID-ASSIGNMENT-TARGET"),
            Reject(main_of("  1 %= 2\n"), "PARSE-INVALID-ASSIGNMENT-TARGET"),
        ])

    def test_interpolation_keeps_text_and_expression_parts_in_order(self):
        self.check_output([Output(main_of("  n = 1\n  m = 5\n  puts(\"a#{n + 1}#{m}\")\n"), ["a25"])])
        self.check_rejected([
            Reject(main_of("  x = \"#{1 2}\"\n"), "PARSE-UNEXPECTED-TOKEN"),
            Reject(main_of("  x = \"#{}\"\n"), "PARSE-UNEXPECTED-TOKEN"),
            Reject(main_of("  x = \"a #{} b\"\n"), "PARSE-UNEXPECTED-TOKEN", (2, 12)),
        ])

    def test_blocks_attach_to_calls_as_the_last_argument(self):
        self.check_output([
            Output(main_of("  puts(List.reduce([1, 2, 3], 0) do |a, b| a + b end)\n"), ["6"]),
        ])
        self.check_accepted([
            Accept(main_of("  xs = [1]\n  _ys = xs.map do |x: Int| x end\n"
                           "  case (xs.map do |x| x end) do\n    _ ->\n      puts(\"b\")\n  end\n")),
        ])
        self.check_rejected([
            Reject(main_of("  xs.each do || puts(\"a\") end\n"), "PARSE-UNEXPECTED-TOKEN"),
            Reject(main_of("  x = 1 do\n  end\n"), "PARSE-UNEXPECTED-TOKEN"),
            Reject(main_of("  xs.each do |x|\n    if x\n      puts(x) end\n  end\n"), "PARSE-UNEXPECTED-TOKEN"),
            Reject(main_of("  xs.each do |x|\n    puts(x)\n"), "PARSE-UNCLOSED-BLOCK"),
        ])

    def test_ruby_headers_one_line_case_arms_and_module_calls_without_parentheses(self):
        self.check_output([
            Output(main_of("  xs = [1, 2]\n  n = 1\n"
                           "  while !IO.eof? do\n    _line = IO.gets!\n  end\n"
                           "  for x in xs.reverse do\n    puts(x)\n  end\n"
                           "  case n\n    1 -> puts(\"one\")\n    _ ->\n      puts(\"other\")\n      puts(\"more\")\n"
                           "  end\n"),
                   ["2", "1", "one"]),
        ])

    def test_break_and_next_are_statements_on_their_own_line(self):
        self.check_output([
            Output(main_of("  i = 0\n  while true\n    i = i + 1\n    if i < 3\n      next\n    end\n"
                           "    break\n  end\n  puts(i)\n"),
                   ["3"]),
        ])
        self.check_accepted([
            Accept(main_of("  while true\n    if false\n      next\n    end\n    break\n  end\n  next = 1\n  puts(next)\n")),
        ])

    def test_result_spellings_bare_gets_and_nullary_variants_through_an_alias(self):
        self.check_accepted([
            Accept(
                "import M from \"./m\"\n\n"
                + main_of("  a = Result.Ok(1)\n  _b: Result[Int] = Result.Err(\"x\")\n  _c = gets!\n"
                          "  _d = M.Shape.Dot\n  case a\n    ok(v) -> puts(v)\n    error(_) -> puts(\"e\")\n  end\n"),
                {"m.agc": SHAPE}),
        ])

    def test_habits_from_other_languages_get_a_parse_hint(self):
        self.check_rejected([
            Reject(main_of(body + "\n"), "PARSE-UNEXPECTED-TOKEN", (line,)) for body, line in HABITS
        ])

    def test_a_heredoc_is_a_string_but_not_a_pattern_or_an_import_path(self):
        heredoc = "<<~A\n      a\n      b\n  A\n"
        self.check_output([
            Output(main_of("  case " + heredoc + "    _ -> puts(\"other\")\n  end\n"), ["other"]),
        ])
        self.check_rejected([
            Reject(main_of("  case \"a\"\n    " + heredoc + "    _ -> puts(2)\n  end\n"),
                   "PARSE-UNEXPECTED-TOKEN", (3, 5, 3, 9)),
            Reject("import Util from <<~A\n  a\n  b\nA\n\n" + main_of(""), "PARSE-UNEXPECTED-TOKEN", (1, 18, 1, 22)),
            Reject("import {run} from <<~A\n  a\n  b\nA\n\n" + main_of(""), "PARSE-UNEXPECTED-TOKEN", (1, 19, 1, 23)),
        ])

    def test_braces_after_a_block_head_point_to_end(self):
        self.check_rejected([
            Reject(text, "PARSE-UNEXPECTED-TOKEN", position) for text, position in BRACES
        ])

    def test_map_literals_still_parse_where_a_block_head_does_not(self):
        self.check_accepted([
            Accept(main_of("  xs = [1]\n  _m: Map[String, Int] = {}\n  _n = {\"a\": 1}\n"
                           "  _ys = xs.map do |x| {\"k\": x} end\n")),
        ])

    def test_import_forms_an_alias_or_a_list_of_names_with_optional_renames(self):
        files = {
            "old.agc": ALPHA,
            "new.agc": ALPHA,
            "lexer.agc": ("export struct Token\n  n: Int\nend\n\n"
                          "export def as() -> Int\n  return 1\nend\n\n"
                          "export def from() -> Int\n  return 2\nend\n"),
        }
        imports = ("import Old from \"old\"\nimport New from \"new\"\n"
                   "import {\n  as as from,\n  Token,\n} from \"lexer\"\n\n")
        program = imports + main_of("  puts(from())\n  puts(Old.one())\n  puts(New.one())\n")
        self.check_output([Output(program, ["1", "1", "1"], files)])
        self.check_rejected([
            Reject("import {} from \"a\"\n", "PARSE-UNEXPECTED-TOKEN", (1, 9)),
            Reject("import {A as} from \"a\"\n", "PARSE-UNEXPECTED-TOKEN", (1, 13)),
            Reject("import Mod, {A} from \"a\"\n", "PARSE-UNEXPECTED-TOKEN", (1, 11)),
            Reject("import {A} of \"a\"\n", "PARSE-UNEXPECTED-TOKEN", (1, 12)),
            # The path-first form of earlier versions: an error at the string.
            Reject("import \"a\" as A\n", "PARSE-UNEXPECTED-TOKEN", (1, 8)),
        ])

    def test_declarations_need_a_blank_line_after_their_end(self):
        self.check_accepted([
            Accept("import A from \"a\"\ndef f() -> Int\n  return A.one()\nend\n# note\ndef main() -> Void\nend",
                   {"a.agc": ALPHA}),
        ])
        self.check_rejected([
            Reject("struct A\n  n: Int\nend\ndef main() -> Void\nend\n\n", "PARSE-MISSING-BLANK-LINE", (4,)),
            Reject("def f() -> Void\nend\nexport def main() -> Void\nend\n\n", "PARSE-MISSING-BLANK-LINE"),
            Reject("enum E\n  A\nend\nimport A from \"a\"\n", "PARSE-MISSING-BLANK-LINE"),
            Reject("def f() -> Void\nend\nend\n", "PARSE-TOP-LEVEL-STATEMENT"),
            Reject("def f() -> Void\nend\nputs(1)\n", "PARSE-TOP-LEVEL-STATEMENT"),
        ])

    def test_elif_and_else_if_point_to_elsif(self):
        texts = [
            "def main() -> Void\n  if true\n    x = 1\n  elif false\n    x = 2\n  end\nend\n",
            "def main() -> Void\n  if true\n    x = 1\n  elseif false\n    x = 2\n  end\nend\n",
            "def main() -> Void\n  if true\n    x = 1\n  else if false\n    x = 2\n  end\n  end\nend\n",
        ]
        self.check_rejected([Reject(text, "PARSE-UNEXPECTED-TOKEN", (4,)) for text in texts])

    def test_return_break_and_next_take_a_guard_that_runs_as_the_if_written_out(self):
        # The condition is an `if` condition: `and`, `or`, `not` and a call with a block need no parentheses. A
        # statement after a guard runs when the guard does not, and a guard ends at the `end` of a one-line block.
        program = (
            "def first(xs: List[Int]) -> Int\n"
            "  return -1 if xs.any? do |x| x < 0 end\n"
            "  return xs[0] if xs.size > 0 and not xs.include?(7) # the first one\n"
            "  return 0\nend\n\n"
            "def say(text: String) -> Void\n  return if text == \"\" or text == \"-\"\n  puts(text)\nend\n\n"
            + main_of("  puts(first([3, 4]))\n  puts(first([3, -4]))\n  puts(first([7]))\n"
                      "  say(\"\")\n  say(\"shown\")\n"
                      "  for n in [1, 2, 3, 4, 5]\n    next if n == 2\n    break if n == 4\n    puts(n)\n  end\n"
                      "  ys = [1, 2, 3].map do |n|\n    return 0 if n == 2\n    n * 10\n  end\n\n  puts(ys)\n"
                      "  [8, 9].each do |n| return if n == 8 end\n"
                      "  case 1\n    1 -> return if first([1]) == 1\n    _ -> puts(\"other\")\n  end\n\n"
                      "  puts(\"after\")\n"))
        self.check_output([Output(program, ["3", "-1", "0", "shown", "1", "3", "[10, 0, 30]"])])

    def test_a_guard_checks_as_the_if_written_out(self):
        # A guard as the last statement misses a return as the `if` does; `break if` outside a loop is the error of
        # `break` there; the condition must be Bool.
        self.check_rejected([
            Reject("def f(x: Int) -> Int\n  return 1 if x > 0\nend\n\n" + main_of("  puts(f(1))\n"),
                   "CHECK-MISSING-RETURN", (1, 1)),
            Reject(main_of("  break if true\n"), "CHECK-LOOP-CONTROL", (2, 3, 2, 8)),
            Reject(main_of("  for n in [1]\n    [1].each do |x| break if x == 1 end\n  end\n"),
                   "CHECK-LOOP-CONTROL", (3, 21, 3, 26)),
            # An `if` on the next line is an `if` statement, as before: dead after the return.
            Reject("def f() -> Int\n  return 1\n  if true\n    return 2\n  end\nend\n", "CHECK-UNREACHABLE-CODE", (3, 3)),
            Reject("def f(x: Int) -> Int\n  return 1 if x\n  return 0\nend\n\n" + main_of("  puts(f(1))\n"),
                   "CHECK-TYPE-MISMATCH", (2, 15, 2, 16)),
        ])

    def test_only_return_break_and_next_take_a_guard_with_one_condition_on_their_line(self):
        unexpected = "PARSE-UNEXPECTED-TOKEN"
        self.check_rejected([
            # A modifier on any other statement, at its `if`.
            Reject(main_of("  x = 1 if true\n"), unexpected, (2, 9, 2, 11)),
            Reject(main_of("  puts(1) if true\n"), unexpected, (2, 11, 2, 13)),
            Reject(main_of("  x = 1\n  x += 1 if true\n"), unexpected, (3, 10, 3, 12)),
            # No elsif, else or second if after the condition.
            Reject(main_of("  return if true else false\n"), unexpected, (2, 18, 2, 22)),
            Reject(main_of("  return if true elsif false\n"), unexpected, (2, 18, 2, 23)),
            Reject(main_of("  return if true if false\n"), unexpected, (2, 18, 2, 20)),
            # The condition starts on the line of the `if`; there is no `unless` and no `while` modifier.
            Reject("def f(x: Int) -> Int\n  return 1 if\n    x > 0\n  return 0\nend\n", unexpected, (2, 14)),
            Reject("def f(x: Int) -> Int\n  return 1 unless x > 0\n  return 0\nend\n", unexpected, (2, 12, 2, 18)),
            Reject("def f(x: Int) -> Int\n  return 1 while x > 0\n  return 0\nend\n", unexpected, (2, 12, 2, 17)),
            Reject(main_of("  for n in [1]\n    next unless n > 0\n  end\n"), unexpected, (3, 10, 3, 16)),
            Reject(main_of("  puts(1) unless true\n"), unexpected, (2, 11, 2, 17)),
            # The `if` is on the line of the `return`: not after a `case` value or a block that spans lines.
            Reject("def f(x: Int) -> Int\n  return case x\n    1 -> 2\n    _ -> 3\n  end if x > 0\n  return 0\nend\n",
                   unexpected, (5, 7, 5, 9)),
            Reject("def f(xs: List[Int]) -> List[Int]\n  return xs.map do |x|\n    x\n  end if xs.size > 0\n"
                   "  return xs\nend\n", unexpected, (4, 7, 4, 9)),
        ])

    def test_a_one_line_def_has_a_value_and_a_return_type(self):
        unexpected = "PARSE-UNEXPECTED-TOKEN"
        self.check_rejected([
            # A Void function, `main` included, has no value to return: at the `=`.
            Reject("def f() -> Void = puts(1)\n", unexpected, (1, 17, 1, 18)),
            Reject("def main() -> Void = puts(1)\n", unexpected, (1, 20, 1, 21)),
            Reject("def main() -> Int = 1\n", "CHECK-MAIN"),
            # The value starts on the line of `=`, and a line does not go on after an operator, as anywhere.
            Reject("def f() -> Int =\n  1\n", unexpected, (1, 17)),
            Reject("def f(a: Int) -> Int = a +\n  1\n", unexpected, (1, 27)),
            # The return type is required.
            Reject("def f(x: Int) = x\n", unexpected, (1, 15, 1, 16)),
            # One expression: a `case` or an `if` is a statement, and a guard is not a value.
            Reject("def f(x: Int) -> Int = case x\n  _ -> 1\nend\n", unexpected, (1, 24, 1, 28)),
            Reject("def f(x: Int) -> Int = if x > 0\n", unexpected, (1, 24, 1, 26)),
            Reject("def f(x: Int) -> Int = x if x > 0\n", unexpected, (1, 26, 1, 28)),
        ])
        # The Void case has a help: write the def with a body.
        void = self.run_all([("def f() -> Void = puts(1)\n", None)], "--json", "check")[0]
        assert json.loads(void.stderr).get("help")

    def test_one_line_defs_may_follow_each_other_without_a_blank_line(self):
        # Like constants: a one-line def right after a one-line def, also with a `##` doc or `export` before the
        # second, and with the blank line (a `#` comment line counts as one, as before). The `=` of a default and the
        # brackets of a generic do not end the lookahead. Any other pair of declarations still needs the blank line,
        # reported at the second one.
        self.check_accepted([
            Accept("export def f() -> Int = 1\n## Two.\nexport def g() -> Int = 2\ndef h() -> Int = 3\n# a note\n"
                   "def i() -> Int = 4\n\ndef j() -> Int = 5\n\n" + main_of("  puts(f() + g() + h() + i() + j())\n")),
            Accept("def f() -> Int = 1\ndef g[T](x: T, n: Int = 1) -> Int = n\n\n" + main_of("  puts(f() + g(\"a\"))\n")),
        ])
        missing = "PARSE-MISSING-BLANK-LINE"
        self.check_rejected([
            Reject("def f() -> Int = 1\ndef g() -> Int\n  return 2\nend\n", missing, (2, 1, 2, 4)),
            Reject("def f() -> Int\n  return 1\nend\ndef g() -> Int = 2\n", missing, (4, 1, 4, 4)),
            Reject("def f() -> Int = 1\ndef g(x: Int = 1) -> Int\n  return x\nend\n", missing, (2, 1, 2, 4)),
            Reject("def f() -> Int = 1\n## Two.\ndef g() -> Int\n  return 2\nend\n", missing, (2, 1)),
            Reject("def f() -> Int = 1\nstruct S\n  n: Int\nend\n", missing, (2, 1, 2, 7)),
            # Next to a constant, on either side.
            Reject("LIMIT = 3\ndef f() -> Int = 1\n", missing, (2, 1, 2, 4)),
            Reject("def f() -> Int = 1\nLIMIT = 3\n", missing, (2, 1, 2, 6)),
        ])

    def test_in_an_extern_block_the_string_after_equals_is_the_c_name(self):
        # The same shape means two things: in an extern block `= "abs"` names the C function (a Void one too);
        # elsewhere it is a one-line def that returns the string.
        extern = ('extern "libc.so.6"\n  def c_abs(n: C.Int32) -> C.Int32 = "abs"\n'
                  '  def c_free(p: C.Pointer) -> Void = "free"\nend\n\n')
        self.check_accepted([Accept(extern + main_of("  puts(c_abs(-3))\n"))])
        self.check_rejected([Reject('extern "libc.so.6"\n  def c_abs(n: C.Int32) -> C.Int32 = n\nend\n',
                                    "PARSE-UNEXPECTED-TOKEN", (2, 38))])
        program = 'def c_abs(n: Int) -> String = "abs"\n\n' + main_of("  puts(c_abs(-3))\n")
        self.check_output([Output(program, ["abs"])])

    def test_if_elsif_else_parses(self):
        program = (
            "def classify(age: Int) -> String\n"
            "  if age >= 18\n    return \"adult\"\n"
            "  elsif age >= 13\n    return \"teen\"\n"
            "  else\n    return \"child\"\n"
            "  end\n"
            "end\n\n"
            + main_of("  puts(classify(20))\n  puts(classify(15))\n  puts(classify(5))\n"))
        self.check_output([Output(program, ["adult", "teen", "child"])])

    def test_arithmetic_precedence_and_associativity(self):
        self.check_output([
            Output(main_of("  a = 1\n  b = 2\n  c = 3\n  puts(a + b * c)\n  puts(a - b - c)\n"
                           "  x = true\n  y = false\n  z = false\n"
                           "  puts(not x and y)\n  puts(x or y and z)\n"),
                   ["7", "-4", "false", "true"]),
        ])

    def test_postfix_access(self):
        program = (
            "struct User\n  name: String\nend\n\n"
            "def find_user(id: Int) -> User\n  return User(name: \"Ana\")\nend\n\n"
            + main_of("  users: List[User] = [User(name: \"Bo\")]\n  user = find_user(1)\n"
                      "  puts(user.name)\n  puts(find_user(1).name)\n  puts(users[0].name)\n"))
        self.check_output([Output(program, ["Ana", "Ana", "Bo"])])

    def test_calls_constructors_and_trailing_commas(self):
        program = (
            "struct Todo\n  title: String\n  done: Bool\nend\n\n"
            "def two(a: Int, b: Int) -> Int\n  return a + b\nend\n\n"
            "def seven() -> Int\n  return 7\nend\n\n"
            + main_of("  puts(seven())\n  puts(two(1, 2,))\n  t = Todo(done: false, title: \"x\")\n"
                      "  puts(t.title)\n  xs = [1, 2,]\n  puts(xs[1])\n"))
        self.check_output([Output(program, ["7", "3", "x", "2"])])

    def test_a_default_value_follows_the_type_of_a_parameter(self):
        program = (
            "def add(a: Int, b: Int = 10, c: Int = -1,) -> Int\n  return a + b + c\nend\n\n"
            + main_of("  puts(add(1))\n  puts(add(1, 2))\n  puts(add(1, 2, 3))\n"))
        self.check_output([Output(program, ["10", "2", "6"])])
        self.check_rejected([
            Reject("def f(a: Int =) -> Void\nend\n\n", "PARSE-UNEXPECTED-TOKEN", (1, 15, 1, 16)),
            Reject("def f(a: Int = 1 2) -> Void\nend\n\n", "PARSE-UNEXPECTED-TOKEN", (1, 18, 1, 19)),
            Reject("def f(a = 1) -> Void\nend\n\n", "PARSE-UNEXPECTED-TOKEN", (1, 9, 1, 10)),
            Reject(main_of("  [1].each do |x = 1|\n    puts(x)\n  end\n"), "PARSE-UNEXPECTED-TOKEN", (2, 18, 2, 19))])

    def test_a_struct_update_is_with_after_a_dot_with_named_arguments_only(self):
        person = "struct Person\n  name: String\n  age: Int\nend\n\nstruct Box\n  with: Int\nend\n\n"
        self.check_output([
            Output(person + main_of(
                "  ana = Person(name: \"Ana\", age: 30)\n"
                "  b = ana.with(age: 31, name: \"Bea\",)\n  puts(b.name)\n  puts(b.age)\n"
                "  puts(ana.with(age: 1).with(name: \"Cy\").name)\n"
                "  box = Box(with: 3)\n  puts(box.with)\n"),
                ["Bea", "31", "Cy", "3"]),
            Output("import W from \"w\"\n\n" + main_of("  puts(W.with(1))\n"), ["1"],
                   {"w.agc": "export def with(n: Int) -> Int\n  return n\nend\n"}),
        ])
        update = "  ana.with(age: 31, name: \"Bea\",)"
        unused = person + main_of("  ana = Person(name: \"Ana\", age: 30)\n" + update + "\n")
        line = unused.split("\n").index(update) + 1
        self.check_rejected([
            Reject(in_function("x = " + text), "PARSE-UNEXPECTED-TOKEN")
            for text in ["ana.with()", "ana.with(31)", "ana.with(age)", "ana.with(age: 1, 2)", "ana.with(age?: 1)"]
        ] + [
            Reject(in_function("x = a |> b.with(c: 1)"), "PARSE-PIPE-TARGET"),
            Reject(person + main_of("  ana = Person(name: \"Ana\", age: 30)\n  x = ana.within(1)\n"),
                   "CHECK-UNKNOWN-METHOD"),
            # The update is the statement's expression: the call's span is the update's span.
            Reject(unused, "CHECK-UNUSED-VALUE", (line, 3, line, 34)),
        ])

    def test_type_applications_parse(self):
        self.check_accepted([
            Accept("def f(x: List[List[Int]]) -> List[List[Int]]\n  _y: List[String] = []\n  return x\nend\n\n"
                   + main_of("")),
        ])

    def test_empty_input_parses_to_an_empty_program(self):
        self.check_accepted([Accept("")])

    def test_while_reassignment_and_bare_return_parse(self):
        program = (
            "def countdown(n: Int) -> Void\n  count = 0\n  while count < n\n    count = count + 1\n  end\n"
            "  puts(count)\n  return\nend\n\n"
            + main_of("  countdown(3)\n"))
        self.check_output([Output(program, ["3"])])

    def test_a_comparison_chain_is_a_located_diagnostic(self):
        self.check_rejected([
            Reject("def f() -> Int\n  return a < b < c\nend\n\n", "PARSE-CHAINED-COMPARISON", (2, 16)),
        ])

    def test_invalid_syntax_is_rejected(self):
        self.check_rejected([
            Reject("def f() -> Bool\n  return a == b == c\nend\n\n", "PARSE-CHAINED-COMPARISON"),
            Reject("puts(\"hello\")\n", "PARSE-TOP-LEVEL-STATEMENT"),
            Reject("age: Int = \"25\"\n", "PARSE-TOP-LEVEL-STATEMENT"),
            Reject("def f() -> Int\n  return 1\n", "PARSE-UNCLOSED-BLOCK"),
            Reject(in_function("x[0] = 1"), "PARSE-INVALID-ASSIGNMENT-TARGET"),
            Reject(in_function("x.y = 1"), "PARSE-INVALID-ASSIGNMENT-TARGET"),
            Reject(in_function("x = 1 y = 2"), "PARSE-UNEXPECTED-TOKEN"),
        ])

    def test_map_literals_and_builtin_module_calls(self):
        self.check_output([
            Output(main_of("  m = {\n    \"a\": 1,\n    \"b\": 2,\n  }\n  m2 = Map.put(m, \"a\", 3)\n"
                           "  puts(m.get(\"b\", 0))\n  puts(m2.get(\"a\", 0))\n"),
                   ["2", "3"]),
        ])

    def test_comparison_mixed_with_equality_is_allowed(self):
        self.check_output([
            Output(main_of("  a = 1\n  b = 2\n  c = 3\n  d = 4\n  puts(a < b == c < d)\n"), ["true"]),
        ])

    def test_generic_enum_declarations_constructors_and_case_patterns_parse(self):
        program = (
            "enum Option[T]\n  Some(T)\n  None\nend\n\n"
            + main_of("  value = Option.Some(3)\n  case value do\n    Option.Some(item) ->\n      puts(item)\n"
                      "    Option.None ->\n      puts(0)\n  end\n"))
        self.check_output([Output(program, ["3"])])

    def test_underscore_discards_direct_enum_payloads_and_imported_patterns_keep_qualification(self):
        domain = "export enum Option\n  Some(Int, Int)\n  None\nend\n"
        program = ("import Domain from \"./domain\"\n\n"
                   + main_of("  value = Domain.Option.Some(1, 2)\n  case value do\n"
                             "    Domain.Option.Some(_, other) ->\n      puts(other)\n"
                             "    _ ->\n      puts(0)\n  end\n"))
        self.check_output([Output(program, ["2"], {"domain.agc": domain})])

    def test_pipe_builds_a_call_with_the_left_value_as_argument_0(self):
        program = (
            "import Util from \"./util\"\n\n"
            "def mix(a: Int, b: Int, c: Int) -> Int\n  return a * 100 + b * 10 + c\nend\n\n"
            + main_of("  x = 5\n  puts(x |> mix(1, 2))\n  puts(x |> Util.twice())\n"))
        self.check_output([Output(program, ["512", "10"], {"util.agc": "export def twice(n: Int) -> Int\n"
                                                                       "  return n * 2\nend\n"})])

    def test_pipe_binds_lower_than_plus_and_minus_and_higher_than_comparisons(self):
        program = (
            "def double(n: Int) -> Int\n  return n * 2\nend\n\n"
            "def sub(a: Int, b: Int) -> Int\n  return a - b\nend\n\n"
            + main_of("  a = 1\n  puts(a + 1 |> double())\n  x = 5\n  puts(x |> double() == 10)\n"
                      "  puts(x |> double() |> sub(1))\n  puts(1 |> double() < 3 |> double())\n"))
        self.check_output([Output(program, ["4", "true", "9", "true"])])
        self.check_rejected([
            Reject(in_function("x = a |> f() |> g() == b == c"), "PARSE-CHAINED-COMPARISON"),
        ])

    def test_try_and_unary_operators_bind_tighter_than_pipe(self):
        program = (
            "def sub(a: Int, b: Int) -> Int\n  return a - b\nend\n\n"
            + TRY_PRELUDE
            + main_of("  x = 3\n  puts(-x |> sub(1))\n"
                      "  case add(1, 2)\n    ok(v) -> puts(v)\n    error(_) -> puts(\"e\")\n  end\n"))
        self.check_output([Output(program, ["-4", "3"])])
        self.check_accepted([
            Accept(TRY_PRELUDE + "def g() -> Result[Int]\n  s = 1 |> try add(2) |> try add(3)\n"
                                 "  _t = try good(4) |> plus(2)\n  return Result.Ok(s)\nend\n\n"
                                 + main_of("")),
        ])

    def test_pipe_takes_a_trailing_block_and_a_multi_line_chain_in_parentheses(self):
        program = (
            "def each_pair(xs: List[Int], body: Fn[Int, Int, Void]) -> Void\n"
            "  for x in xs do\n    body.call(x, x)\n  end\nend\n\n"
            "def f(n: Int) -> Int\n  return n + 1\nend\n\n"
            "def g(n: Int) -> Int\n  return n * 3\nend\n\n"
            + main_of("  xs = [1, 2]\n  xs |> each_pair() do |a, b| puts(a + b) end\n"
                      "  x = 1\n  y = (x\n    |> f()\n    |> g())\n  puts(y)\n"))
        self.check_output([Output(program, ["2", "4", "6"])])
        self.check_rejected([
            Reject(in_function("x = a\n    |> f()"), "PARSE-UNEXPECTED-TOKEN"),
        ])

    def test_the_right_side_of_pipe_must_be_a_call_with_parentheses(self):
        self.check_rejected([
            Reject(in_function("x = " + text), "PARSE-PIPE-TARGET", (2, start, 2, end))
            for text, (start, end) in PIPE_TARGETS
        ])

    def test_a_doc_block_attaches_to_the_declaration_on_the_next_line(self):
        program = (
            "## A point.\nstruct Point\nend\n\n"
            "## A shape.\nexport struct Shape\nend\n\n"
            "## A choice.\nexport enum Choice\n  A\nend\n\n"
            "## Plain.\nenum Plain\n  B\nend\n\n"
            "## Shows.\nexport def show() -> Void\nend\n\n"
            "## Adds.\n##\n## Two numbers.\ndef add() -> Void\nend\n\n"
            "def main() -> Void\nend\n")
        self.check_accepted([Accept(program)])

    def test_fields_and_variants_take_docs(self):
        self.check_accepted([
            Accept("struct Point\n  ## Across.\n  x: Int\n  y: Int\n  ## Up.\n  z: Int\nend\n\n"
                   "enum Option[T]\n  Some(T)\n  ## Nothing here.\n  None\nend\n\n" + main_of("")),
        ])

    def test_a_file_without_doc_comments_and_the_module_doc(self):
        self.check_accepted([
            Accept("# note\ndef main() -> Void\nend\n"),
            Accept("\n\n# license\n\n# more\n## Module.\n##\n## Details.\n\n## Adds.\ndef add() -> Void\nend\n\n"
                   + main_of("")),
            Accept("## Not a module doc.\ndef main() -> Void\nend\n"),
            Accept("## Only a module doc.\n\n"),
            Accept("## Module.\n\nimport {one} from \"a\"\n", {"a.agc": ALPHA}),
        ])

    def test_every_detached_doc_block_is_parse_detached_doc_at_its_first_line(self):
        self.check_rejected([
            Reject(text, "PARSE-DETACHED-DOC", position) for text, position in DETACHED_DOCS
        ] + [
            Reject("def a() -> Void\nend\n\n## one\n## two\n\ndef b() -> Void\nend\n", "PARSE-DETACHED-DOC",
                   (4, 1, 5, 7)),
        ])

    def test_a_doc_line_does_not_count_as_the_blank_line_between_declarations(self):
        self.check_rejected([
            Reject("def a() -> Void\nend\n## d\ndef b() -> Void\nend\n", "PARSE-MISSING-BLANK-LINE", (3, 1)),
            Reject("def a() -> Void\nend\n## d\n## e\ndef b() -> Void\nend\n", "PARSE-MISSING-BLANK-LINE", (3, 1)),
            Reject("struct S\n  a: Int\nend\n## d\nstruct T\nend\n", "PARSE-MISSING-BLANK-LINE", (4, 1)),
            Reject("def a() -> Void\nend\n## d\n\ndef b() -> Void\nend\n", "PARSE-MISSING-BLANK-LINE", (3, 1)),
            Reject("## d\ndef a() -> Void\nend\n## e\ndef b() -> Void\nend\n", "PARSE-MISSING-BLANK-LINE", (4, 1)),
        ])
        self.check_accepted([
            Accept("def a() -> Void\nend\n\n## d\ndef b() -> Void\nend\n\n" + main_of("")),
            Accept("def a() -> Void\nend\n# note\n## d\ndef b() -> Void\nend\n\n" + main_of("")),
            Accept("import {one} from \"a\"\n## d\ndef b() -> Void\nend\n\n" + main_of(""), {"a.agc": ALPHA}),
        ])

    def test_nesting_and_chains_beyond_1000_levels_are_parse_too_deep(self):
        def body(text):
            return "def main() -> Void\n  " + text + "\nend\n\n"

        self.check_accepted([
            Accept(body("_ = " + "(" * 900 + "1" + ")" * 900)),
            Accept(body("_ = 1" + " + 1" * 900)),
        ])
        self.check_rejected([
            Reject(body("x = " + "(" * 1000 + "1" + ")" * 1000), "PARSE-TOO-DEEP"),
            Reject(body("x = " + "- " * 1000 + "1"), "PARSE-TOO-DEEP"),
            Reject(body("x = a" + ".b" * 1000), "PARSE-TOO-DEEP"),
            Reject(body("if x\n" * 1000), "PARSE-TOO-DEEP"),
            Reject(body("x = 1" + " + 1" * 1000), "PARSE-TOO-DEEP", (2, 4001)),
        ])
