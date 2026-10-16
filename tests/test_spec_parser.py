"""The parser rules of the language, through the product CLI.

Each case writes a program to a temp file and runs the CLI on it. A rejected program is asserted by its diagnostic
code and, where a position is part of the rule, by the start (and end) of its range. A valid program is asserted by
a clean `check`, or by the output of a run where the output shows the rule (a precedence, a desugaring, an
evaluation order). Help and message texts are not asserted (AGENTS.md).
"""
import json
from collections import namedtuple

from tests.agentica_test import TestCase, cli, output_lines, run, vm_environment

# span: (line, column) of the start, (line, column, line, column) with the end too, (line,) for the line only,
# or None when the rule is not about a position.
Reject = namedtuple("Reject", "text code span files", defaults=(None, None))
# parses_only: the program parses, but its check fails for another reason (a program with no main).
Accept = namedtuple("Accept", "text files parses_only", defaults=(None, False))
Output = namedtuple("Output", "text lines files", defaults=(None,))

PARSE_CODES = ("LEX-", "PARSE-")

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
    ("  break if x > 3", 2),
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
]


class SpecParser(TestCase):
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
            with self.subTest(program=case.text):
                if result.code != 1:
                    self.fail("expected %s, the program was not rejected: %s" % (case.code, result.stdout))
                diagnostic = json.loads(result.stderr)
                self.assertEqual(diagnostic["code"], case.code, diagnostic.get("message"))
                if case.span is not None:
                    self.assertEqual(span_of(diagnostic)[:len(case.span)], case.span, diagnostic.get("message"))

    def check_accepted(self, cases):
        results = self.run_all([(case.text, case.files) for case in cases], "--json", "check")
        for case, result in zip(cases, results):
            with self.subTest(program=case.text):
                if case.parses_only:
                    code = json.loads(result.stderr)["code"] if result.code else ""
                    self.assertFalse(code.startswith(PARSE_CODES), result.stderr)
                else:
                    self.assertEqual((result.code, result.stdout), (0, '{"ok":true}\n'), result.stderr)

    def check_output(self, cases):
        results = self.run_all([(case.text, case.files) for case in cases])
        for case, result in zip(cases, results):
            with self.subTest(program=case.text):
                self.assertEqual(result.code, 0, result.stderr)
                self.assertEqual(output_lines(result.stdout), case.lines)

    def test_ranges_bind_loosest_and_do_not_chain(self):
        self.check_output([
            Output(main_of("  n = 2\n  for i in 0...n + 1 do\n    puts(i)\n  end\n"), ["0", "1", "2"]),
        ])
        self.check_accepted([
            Accept(main_of("  for i in 0...3 do\n    puts(i)\n  end\n")),
            Accept(main_of("  r = (1..5).to_a\n")),
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
            Accept(main_of("  xs = [1]\n  ys = xs.map do |x: Int| x end\n"
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
                           "  while !IO.eof? do\n    line = IO.gets!\n  end\n"
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
            Accept(main_of("  while true\n    next\n    break\n  end\n  next = 1\n")),
        ])

    def test_result_spellings_bare_gets_and_nullary_variants_through_an_alias(self):
        self.check_accepted([
            Accept(
                "import M from \"./m\"\n\n"
                + main_of("  a = Result.Ok(1)\n  b: Result[Int] = Result.Err(\"x\")\n  c = gets!\n"
                          "  d = M.Shape.Dot\n  case a\n    ok(v) -> puts(v)\n    error(_) -> puts(\"e\")\n  end\n"),
                {"m.agc": SHAPE}),
        ])

    def test_habits_from_other_languages_get_a_parse_hint(self):
        self.check_rejected([
            Reject(main_of(body + "\n"), "PARSE-UNEXPECTED-TOKEN", (line,)) for body, line in HABITS
        ])

    def test_braces_after_a_block_head_point_to_end(self):
        self.check_rejected([
            Reject(text, "PARSE-UNEXPECTED-TOKEN", position) for text, position in BRACES
        ])

    def test_map_literals_still_parse_where_a_block_head_does_not(self):
        self.check_accepted([
            Accept(main_of("  xs = [1]\n  m: Map[String, Int] = {}\n  n = {\"a\": 1}\n"
                           "  ys = xs.map do |x| {\"k\": x} end\n")),
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
        program = imports + main_of("  puts(from())\n  puts(Old.one())\n")
        self.check_output([Output(program, ["1", "1"], files)])
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
            Accept("import A from \"a\"\ndef f() -> Void\nend\n# note\ndef main() -> Void\nend", {"a.agc": ALPHA}),
        ])
        self.check_rejected([
            Reject("struct A\n  n: Int\nend\ndef main() -> Void\nend\n\n", "PARSE-MISSING-BLANK-LINE", (4,)),
            Reject("def f() -> Void\nend\nexport def main() -> Void\nend\n\n", "PARSE-MISSING-BLANK-LINE"),
            Reject("enum E\n  A\nend\nimport A from \"a\"\n", "PARSE-MISSING-BLANK-LINE"),
            Reject("def f() -> Void\nend\nend\n", "PARSE-TOP-LEVEL-STATEMENT"),
            Reject("def f() -> Void\nend\nputs(1)\n", "PARSE-TOP-LEVEL-STATEMENT"),
            Reject(main_of("  x = / 2\n"), "PARSE-UNEXPECTED-TOKEN"),
            Reject(main_of("  x = /abc/\n"), "PARSE-UNEXPECTED-TOKEN"),
        ])

    def test_elif_and_else_if_point_to_elsif(self):
        texts = [
            "def main() -> Void\n  if true\n    x = 1\n  elif false\n    x = 2\n  end\nend\n",
            "def main() -> Void\n  if true\n    x = 1\n  elseif false\n    x = 2\n  end\nend\n",
            "def main() -> Void\n  if true\n    x = 1\n  else if false\n    x = 2\n  end\n  end\nend\n",
        ]
        self.check_rejected([Reject(text, "PARSE-UNEXPECTED-TOKEN", (4,)) for text in texts])

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
            Accept("def f(x: List[List[Int]]) -> List[List[Int]]\n  y: List[String] = []\n  return x\nend\n\n"
                   + main_of("")),
        ])

    def test_empty_input_parses_to_an_empty_program(self):
        # check needs a main(), so the empty program fails the check, but it parses.
        self.check_accepted([Accept("", parses_only=True)])

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
                                 "  t = try good(4) |> plus(2)\n  return Result.Ok(s)\nend\n\n"
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
            # Without a main() the check fails, but the module doc parses.
            Accept("## Only a module doc.\n\n", parses_only=True),
            Accept("## Module.\n\nimport A from \"a\"\n", {"a.agc": ALPHA}, parses_only=True),
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
            Accept("import A from \"a\"\n## d\ndef b() -> Void\nend\n\n" + main_of(""), {"a.agc": ALPHA}),
        ])

    def test_nesting_and_chains_beyond_1000_levels_are_parse_too_deep(self):
        def body(text):
            return "def main() -> Void\n  " + text + "\nend\n\n"

        self.check_accepted([
            Accept(body("x = " + "(" * 900 + "1" + ")" * 900)),
            Accept(body("x = 1" + " + 1" * 900)),
        ])
        self.check_rejected([
            Reject(body("x = " + "(" * 1000 + "1" + ")" * 1000), "PARSE-TOO-DEEP"),
            Reject(body("x = " + "- " * 1000 + "1"), "PARSE-TOO-DEEP"),
            Reject(body("x = a" + ".b" * 1000), "PARSE-TOO-DEEP"),
            Reject(body("if x\n" * 1000), "PARSE-TOO-DEEP"),
            Reject(body("x = 1" + " + 1" * 1000), "PARSE-TOO-DEEP", (2, 4001)),
        ])
