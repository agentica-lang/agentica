"""The Agentica parser (compiler/parse.agc) against the frozen output of the Racket parser.

tests/frontend-parser-test.rkt compares the two live. This module compares the Agentica parser with what the Racket
parser printed once for the same inputs (`make frontend-freeze`, tests/frontend-parser-freeze.rkt): the corpus
(examples/, stdlib/ and tests/fixtures/vm/ as they were at the freeze), 300 generated inputs, the nesting limit, large
files, the numbering of node ids and a file with invalid UTF-8. Inputs that are a formula are rebuilt here; the
manifests hold their hashes.
"""
import time

from tests.agentica_test import FIXTURES, slow
from tests.frontend_support import FROZEN, StageTestCase, load_corpus, load_json, write_files

NESTING_LIMIT = 1000
PARSER_FIXTURES = FIXTURES / "frontend" / "parser"


def function_body(body):
    return "def main() -> Void\n" + body + "end\n\n"


def key_of(name):
    return name.replace(" ", "-")


def nesting_shapes(count):
    """(name, program) for each shape nested `count` deep."""
    return [
        ("parentheses", function_body("  x = " + "(" * count + "1" + ")" * count + "\n")),
        ("prefix operators", function_body("  x = " + "- " * count + "1\n")),
        ("calls", function_body("  x = " + "f(" * count + "1" + ")" * count + "\n")),
        ("lists", function_body("  x = " + "[" * count + "1" + "]" * count + "\n")),
        ("if statements", function_body("if x\n" * count + "puts(1)\n" + "end\n" * count)),
        ("blocks", function_body("xs.each do |x|\n" * count + "puts(1)\n" + "end\n" * count)),
        ("types", "def f(a: " + "List[" * count + "Int" + "]" * count + ") -> Void\nend\n\n"),
        ("binary chain", function_body("  x = 1" + " + 1" * count + "\n")),
        ("mixed chain", function_body("  x = 1 * 1 or 1" + " + 1" * count + " < 1 and (1" + " * 1" * count + ")\n")),
        ("field chain", function_body("  x = a" + ".b" * count + "\n")),
        ("pipe chain", function_body("  x = a" + " |> f()" * count + "\n")),
        ("interpolations", function_body("  x = " + '"#{' * count + "1" + '}"' * count + "\n")),
    ]


def deepest_legal(shape):
    """The levels of a shape that still parse, as far as the tested sizes (300, 900, 1001, 3000) can tell.

    A shape costs one counted level per level written (the exact edge is a few levels under the limit, which the
    boundary cases cover), except a do block: its statement, expression, `.each` link and body each count, so only 249
    fit.
    """
    return 249 if shape == "blocks" else NESTING_LIMIT


def limit_shapes():
    """(name, legal count, builder): chains, prefix operators and nested chains at the limit and one past it."""
    return [
        ("mixed", 998, lambda n: function_body("  y = x * x" + " + x" * n + "\n")),
        ("prefix", 998, lambda n: function_body("  y = " + "- " * n + "x\n")),
        ("field", 998, lambda n: function_body("  y = x" + ".b" * n + "\n")),
        ("method", 997, lambda n: function_body("  y = x" + ".f(1)" * n + "\n")),
        ("nested", 988, lambda n: function_body("  y = x + (x + (x + (x + (x + (x" + " + x" * n + ")))))\n")),
    ]


def large_files():
    return {
        "statements": function_body("  x = f(1, 2) + 3\n" * 10000),
        "items": function_body("  x = [" + "1, " * 20000 + "1]\n"),
        "branches": function_body("  if x\n  end\n" + "  if x\n    y = 1\n  elsif x\n    y = 2\n  end\n" * 3000),
        "flat": "".join("def f%d(a: Int) -> Int\n  return a + %d\nend\n\n" % (n, n) for n in range(400)),
    }


def is_too_deep(text):
    return text.startswith("ERROR PARSE-TOO-DEEP")


class ParserFrozenTest(StageTestCase):
    ENTRY = "parse.agc"

    def parse_cases(self, cases, *before, flags=()):
        """Parse {key: program text} written as files; gives {key: output}."""
        directory = self.make_temp_dir()
        write_files(directory, {key + ".agc": text for key, text in cases.items()})
        outputs = self.run_sections(sorted(key + ".agc" for key in cases), *before, flags=flags, cwd=directory)
        return {key: outputs[key + ".agc"] for key in cases}

    def check_cases(self, cases, manifest):
        outputs = self.parse_cases(cases)
        self.assert_manifest(outputs, manifest, cases)
        return outputs

    def test_chains_prefix_operators_and_nested_chains_are_legal_at_the_limit_and_refused_one_past_it(self):
        # The trees of the legal cases print about 1 MB each, so the golden holds their hashes.
        cases = {}
        legal = {}
        for name, limit, build in limit_shapes():
            for count in (limit, limit + 1):
                cases["limit-%s-%d" % (name, count)] = build(count)
                legal["limit-%s-%d" % (name, count)] = count == limit
        outputs = self.check_cases(cases, "parser/limits.sha256")
        for key, is_legal in legal.items():
            self.assertEqual(outputs[key].startswith("program "), is_legal, key)

    def test_a_file_with_invalid_utf8_is_lex_invalid_utf8_at_the_first_bad_byte(self):
        directory = self.make_temp_dir()
        write_files(directory, {"invalid.agc": b"# caf\xc3\xa9\ndef \xff\n"})
        outputs = self.run_sections(["invalid.agc"], cwd=directory)
        self.assertEqual(outputs["invalid.agc"], (FROZEN / "parser" / "invalid-utf8.expected").read_text(encoding="utf-8"))

    def test_the_first_node_id_can_be_chosen_so_modules_can_share_one_numbering(self):
        path = "tests/fixtures/frontend/parser/synthetic.input"
        shifted = self.run_sections([path], "--first-id=1000")
        self.assertEqual(shifted[path], (FROZEN / "parser" / "first-id.expected").read_text(encoding="utf-8"))
        self.assertIn(" #1000 ", shifted[path])

    def test_a_second_file_continues_the_numbering_from_the_next_free_id_of_the_first(self):
        first = "tests/fixtures/frontend/parser/hello.input"
        second = "tests/fixtures/frontend/parser/synthetic.input"
        continued = self.run_sections([first, second], "--continue")
        self.assertEqual(continued[first], (PARSER_FIXTURES / "hello.ast").read_text(encoding="utf-8"))
        self.assertEqual(continued[second], (FROZEN / "parser" / "continue-synthetic.expected").read_text(encoding="utf-8"))

    @slow
    def test_corpus(self):
        files = {path: text for path, text in load_corpus("examples", "stdlib", "fixtures").items()
                 if path.startswith(("examples/", "stdlib/", "tests/fixtures/vm/"))}
        directory = self.make_temp_dir()
        write_files(directory, files)
        outputs = self.run_sections(sorted(files), cwd=directory)
        self.assert_manifest(outputs, "parser/corpus.sha256", files)

    @slow
    def test_300_generated_inputs(self):
        cases = {"case-%d" % n: text for n, text in enumerate(load_json("parser/generated.json"))}
        outputs = self.check_cases(cases, "parser/generated.sha256")
        errors = sum(1 for text in outputs.values() if text.startswith("ERROR"))
        self.assertTrue(30 < errors < 270, "%d of 300 generated inputs are errors" % errors)

    @slow
    def test_the_nesting_limit_falls_at_the_same_token_in_both_parsers(self):
        cases = {}
        for count in range(NESTING_LIMIT - 5, NESTING_LIMIT + 4):
            for name, text in nesting_shapes(count):
                if name in ("parentheses", "types", "binary chain", "mixed chain"):
                    cases["boundary-%s-%d" % (key_of(name), count)] = text
        outputs = self.check_cases(cases, "parser/boundary.sha256")
        results = {is_too_deep(text) for text in outputs.values()}
        self.assertEqual(results, {True, False}, "the boundary cases cross the limit")

    @slow
    def test_nesting_far_below_and_above_the_limit_gives_the_same_tree_or_the_same_too_deep(self):
        cases = {}
        deep = {}
        for count in (300, 900, NESTING_LIMIT + 1, 3000):
            for name, text in nesting_shapes(count):
                key = "nest-%s-%d" % (key_of(name), count)
                cases[key] = text
                deep[key] = count > deepest_legal(name)
        outputs = self.check_cases(cases, "parser/nesting.sha256")
        for key, expected in deep.items():
            self.assertEqual(is_too_deep(outputs[key]), expected, key)

    @slow
    def test_a_large_file_parses_in_linear_time(self):
        started = time.monotonic()
        self.check_cases(large_files(), "parser/large.sha256")
        self.assertLess(time.monotonic() - started, 60)
