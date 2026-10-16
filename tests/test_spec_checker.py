"""Checker rules through the product CLI: where diagnostics point, pipes and the nesting limit.

These are the cases of the old checker test about the spans of diagnostics, the pipe rules and the nesting
limit. The other cases are in tests/test_spec_checker_rest.py.

Each program is written to a file and checked with `--json check FILE`. A test asserts the diagnostic code and its
range (the 1-based line and column of the start and of the end, which is exclusive). Message and help texts are not
asserted (AGENTS.md). The programs are also in the frozen corpus (tests/fixtures/frontend/frozen/corpus/), which the
Agentica checker is compared with.
"""
import json

from tests.agentica_test import TestCase, cli, run


def main_with(body):
    return "def main() -> Void\n%s\nend\n\n" % body


def links(count):
    return " + x" * count


def nested_chains(levels, length):
    """`levels` chains of `length` links, each inside the right operand of the first link of the next."""
    text = "x"
    for _ in range(levels):
        text = "x + (" + text + ")" + links(length)
    return text


def position(point):
    return point["line"], point["column"]


def covered(text, span):
    """The source text from the start of a JSON range to its end (exclusive)."""
    lines = text.split("\n")

    def offset(point):
        return sum(len(line) + 1 for line in lines[:point["line"] - 1]) + point["column"] - 1

    return text[offset(span["start"]):offset(span["end"])]


PIPE_HELPERS = ("def add(a: Int, b: Int) -> Int\n  return a + b\nend\n\n"
                "def parse(text: String) -> Result[Int]\n  return text.to_i\nend\n\n"
                "def load(path: String) -> Result[Int]\n"
                "  text = path |> try File.read_text(1000)\n"
                "  return text |> parse()\n"
                "end\n\n")

METHOD_PIPE_HELPERS = ("def f(n: Int) -> Int\n  return n\nend\n\n"
                       "def g(n: Int) -> Result[Int]\n  return ok(n)\nend\n\n")


class SpecCheckerTest(TestCase):
    def setUp(self):
        self.work = self.make_temp_dir()

    def problem(self, text):
        """The JSON diagnostic that `check` gives the program, or None when the program checks clean."""
        path = self.work / "program.agc"
        path.write_text(text, encoding="utf-8")
        result = run(cli() + ["--json", "check", str(path)])
        if result.code == 0:
            return None
        self.assertEqual(result.code, 1, result.stderr)
        return json.loads(result.stderr)

    def assert_clean(self, text):
        self.assertIsNone(self.problem(text), text)

    def assert_code(self, text, code):
        found = self.problem(text)
        self.assertIsNotNone(found, "%s expected for:\n%s" % (code, text))
        self.assertEqual(found["code"], code, text)
        return found

    def expect(self, text, code, start, covers=None):
        """The program fails with `code` at `start` (line, column); `covers` is the span's source text, if given."""
        found = self.assert_code(text, code)
        self.assertEqual(position(found["range"]["start"]), start, text)
        if covers is not None:
            self.assertEqual(covered(text, found["range"]), covers, text)
        return found

    def test_diagnostics_point_at_the_offending_source(self):
        cases = [
            (main_with("  x: Int = \"s\""), "CHECK-TYPE-MISMATCH", (2, 12), "\"s\""),
            (main_with("  x = missing"), "CHECK-UNKNOWN-NAME", (2, 7), "missing"),
            (main_with("  x = 1 + \"a\""), "CHECK-TYPE-MISMATCH", (2, 9), "+"),
        ]
        for text, code, start, covers in cases:
            with self.subTest(text=text):
                self.expect(text, code, start, covers)

    def test_a_field_named_with_cannot_hold_a_function(self):
        self.expect("struct Hooks\n  with: Fn[Int, Int]\nend\n\ndef main() -> Void\nend\n\n",
                    "CHECK-REDEFINED-NAME", (2, 3), "with: Fn[Int, Int]\n")
        self.assert_clean("struct Hooks\n  with: Int\n  run: Fn[Int, Int]\nend\n\ndef main() -> Void\nend\n\n")

    def test_stream_is_a_generic_type(self):
        self.assert_clean(
            "def accept(stream: Stream[Int]) -> Int\n  return 1\nend\n\n"
            "def main() -> Void\nend\n\n"
        )
        text = ("def accept(stream: Stream[Void]) -> Int\n  return 1\nend\n\n"
                "def main() -> Void\nend\n\n")
        self.expect(text, "CHECK-VOID-TYPE", (1, 27), "Void")

    def test_stream_type_propagates_through_generic_enums(self):
        self.assert_clean(
            "enum Box[T]\n  Wrapped(Stream[T])\nend\n\n"
            "def accept_stream(stream: Stream[Int]) -> Int\n  return 1\nend\n\n"
            "def use(box: Box[Int]) -> Int\n"
            "  case box\n    Box.Wrapped(stream) -> return accept_stream(stream)\n  end\n"
            "end\n\n"
            "def main() -> Void\nend\n\n"
        )

    def test_pipe_calls_user_functions_and_builtins(self):
        for body in ("  n: Int = 1 |> add(2) |> add(3)\n  puts(n)",
                     "  r: Result[Int] = \" 4 \".trim |> parse()\n  puts(r.unwrap!)"):
            with self.subTest(body=body):
                self.assert_clean(PIPE_HELPERS + main_with(body))
        self.expect(PIPE_HELPERS + main_with("  n = \"a\" |> add(1)"), "CHECK-TYPE-MISMATCH", (15, 7), "\"a\"")
        for body, code in (("  n = 1 |> add()\n  puts(n)", "CHECK-ARITY"),
                           ("  n = 1 |> missing()", "CHECK-UNKNOWN-NAME")):
            with self.subTest(body=body):
                self.assert_code(PIPE_HELPERS + main_with(body), code)

    def test_pipe_into_a_builtin_with_a_method_form_is_pipe_method(self):
        self.expect(main_with("  s = \" a \"\n  t = s |> String.trim()\n  puts(t)"),
                    "CHECK-PIPE-METHOD", (3, 12), "String.trim()")
        tried = (METHOD_PIPE_HELPERS + "def h() -> Result[String]\n  z = 1 |> try g() |> String.from_int()\n"
                 "  return ok(z)\nend\n\n")
        cases = [
            main_with("  s = \"a,b\"\n  xs = s.trim |> String.split(\",\")\n  puts(xs.size)"),
            main_with("  n = \"a\" + \"b\" |> String.length()"),
            METHOD_PIPE_HELPERS + main_with("  z = 1 |> f() |> String.from_int()"),
            tried + main_with("  puts(1)"),
            METHOD_PIPE_HELPERS + main_with("  xs = [1, 2]\n  ys = xs |> List.map() do |v: Int| v |> f() end"),
            main_with("  xs = [1, 2]\n  ys = (xs |> List.map()) do |v: Int| v end"),
        ]
        for text in cases:
            with self.subTest(text=text):
                self.assert_code(text, "CHECK-PIPE-METHOD")

    def test_expressions_and_statements_nest_at_most_1000_levels(self):
        for count in (997, 998):
            with self.subTest(links=count):
                self.assert_clean(main_with("  x = 1\n  y = x" + links(count) + "\n  puts(y)"))
        deep = main_with("  x = 1\n  y = " + nested_chains(3, 500) + "\n  puts(y)")
        found = self.expect(deep, "CHECK-TOO-DEEP", (3, 12))
        self.assertTrue(covered(deep, found["range"]).startswith("x "), deep)
        nested_ifs = ("".join("  if x == 1\n" for _ in range(300)) + "  y = " + nested_chains(2, 500) + "\n"
                      + "".join("  end\n" for _ in range(300)))
        self.expect(main_with("  x = 1\n" + nested_ifs), "CHECK-TOO-DEEP", (303, 12))
