"""Lexer rules of the language, checked through the product CLI (the cases of tests/lexer-test.rkt).

A source text is checked with `--json check`, or run as a program. A diagnostic case asserts its code and its span: the
line and column of the start, and of the end when the case gives one (the end is exclusive). `help` is asserted only as
present or absent: messages and helps are text, and the tests do not compare text. Token kinds, lexemes and values are
not visible through the CLI; tests/test_frontend_lexer.py pins the token output of the Agentica lexer.
"""
import json
from concurrent.futures import ThreadPoolExecutor

from tests.agentica_test import TestCase, cli, run

# One start of the front end takes about a second, so the cases of a group run side by side.
WORKERS = 4

MAIN = "def main() -> Void"
# A declaration before a doc case: the blank line after its `end` is the separator that the rule for declarations asks
# for, and the doc block after it is not the module doc.
PRE = "def h() -> Int\n  return 1\nend\n\n"
INC = "def inc(x: Int) -> Int\n  return x + 1\nend\n\n"
SUFFIX_DEFS = "def ready?() -> Bool\n  return true\nend\n\ndef save!(value: Int) -> Int\n  return value\nend\n\n"


def program(*lines):
    return "\n".join(lines) + "\n"


# (case, source, code, span, help): the span is None, (line, column) or (line, column, end line, end column); help is
# True or False when the case asserts it, else None.
DIAGNOSTICS = [
    # Ranges lex as two integers, so a second range operator is a parse error at that operator.
    ("second range operator", program(MAIN, "  x = 1..2..3", "end"), "PARSE-UNEXPECTED-TOKEN", (2, 11, 2, 13), None),
    ("second range operator after names", program(MAIN, "  x = a...b..c", "end"),
     "PARSE-UNEXPECTED-TOKEN", (2, 12, 2, 14), None),
    # |> is one token: next to a name it leaves a pipe with no call on the right.
    ("pipe without spaces", program(MAIN, "  x = a|>b", "end"), "PARSE-PIPE-TARGET", (2, 10, 2, 11), None),
    ("|| then > is not a pipe", program(MAIN, "  x = a ||> b", "end"), "PARSE-UNEXPECTED-TOKEN", (2, 11, 2, 12), None),
    ("|| then a lone pipe", program(MAIN, "  x = a || b | c", "end"), "PARSE-UNEXPECTED-TOKEN", (2, 14, 2, 15), None),
    # Strings.
    ("unterminated string, newline in the interpolation", 'x = "a#{n\n}"',
     "LEX-UNTERMINATED-STRING", (1, 5), None),
    ("unterminated string in the interpolation", 'x = "a#{n', "LEX-UNTERMINATED-STRING", (1, 5), None),
    ("unterminated string after an interpolation", 'x = "#{n}', "LEX-UNTERMINATED-STRING", (1, 5), None),
    ("unfinished string", '"unfinished', "LEX-UNTERMINATED-STRING", None, None),
    ("invalid escape", r'"bad\q"', "LEX-INVALID-ESCAPE", None, None),
    # Digit separators: only between two digits; the span is the literal as written.
    ("trailing separator", "1_", "LEX-INVALID-NUMBER", (1, 1, 1, 3), None),
    ("trailing separator before a letter", "1_a", "LEX-INVALID-NUMBER", (1, 1, 1, 3), None),
    ("double separator", "1__0", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("separator before the dot", "1_.5", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("separator after the dot", "1._5", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("trailing separator in the fraction", "1.5_", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("double separator in the fraction", "1.5__5", "LEX-INVALID-NUMBER", (1, 1, 1, 7), None),
    ("trailing separator after digits", "1_000_", "LEX-INVALID-NUMBER", (1, 1, 1, 7), None),
    ("separator before a method", "x = 1_.times", "LEX-INVALID-NUMBER", (1, 5, 1, 7), None),
    # Characters and delimiters, with the C-style habits that get a help.
    ("unexpected character", "x @", "LEX-UNEXPECTED-CHAR", (1, 3), False),
    ("semicolon", "x = 1;\ny = 2", "LEX-UNEXPECTED-CHAR", (1, 6), True),
    ("single quote", "x = s[0] == '+'", "LEX-UNEXPECTED-CHAR", (1, 13), True),
    ("stray closing brace", "def main() -> Void\n  puts(1)\n}\n", "LEX-UNMATCHED-DELIMITER", (3, 1), True),
    ("closing brace inside a call", "f(1}", "LEX-UNMATCHED-DELIMITER", None, False),
    ("lone closing paren", ")", "LEX-UNMATCHED-DELIMITER", None, False),
    ("lone closing brace", "}", "LEX-UNMATCHED-DELIMITER", None, None),
    ("unclosed map", 'x = {"a": 1', "LEX-UNCLOSED-DELIMITER", None, True),
    ("unclosed paren and bracket", "([", "LEX-UNCLOSED-DELIMITER", None, None),
    ("lone opening brace", "{", "LEX-UNCLOSED-DELIMITER", None, None),
    ("closing paren while a block is open", "f(xs.map do |x|\n  x\n)", "LEX-UNMATCHED-DELIMITER", (3, 1), None),
    ("block open at the end of a call", "f(xs.map do |x|\n", "LEX-UNCLOSED-DELIMITER", None, None),
    ("block with no end at the end of the file", "def f()\n  if x\n", "PARSE-UNEXPECTED-TOKEN", None, None),
    ("bare carriage return after a doc line", "## a\rb", "LEX-UNEXPECTED-CHAR", None, None),
    # An empty file lexes with no error: the first diagnostic is the missing main.
    ("empty file", "", "CHECK-MAIN", None, None),
    # Doc blocks: a block that is not directly above a declaration is detached, and the span is the whole block.
    ("doc block followed by a blank line", PRE + "## a\n\ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (5, 1), None),
    ("doc block followed by a line of spaces", PRE + "## a\n   \ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (5, 1), None),
    ("doc block followed by a comment", PRE + "## a\n# note\ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (5, 1), None),
    ("doc block followed by an indented comment", PRE + "## a\n  # note\ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (5, 1), None),
    ("doc block at the end of the file", PRE + "## a\n", "PARSE-DETACHED-DOC", (5, 1), None),
    ("doc block at the end of the file without a newline", PRE + "## a", "PARSE-DETACHED-DOC", (5, 1), None),
    ("doc block followed by a blank CRLF line",
     "def h() -> Int\r\n  return 1\r\nend\r\n\r\n## a\r\n\r\ndef main() -> Void\r\nend\r\n",
     "PARSE-DETACHED-DOC", (5, 1), None),
    ("doc block of several lines", PRE + "## First\n##\n##   Third\n  ### Heading\n\ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (5, 1, 8, 14), None),
    ("doc marker without a space", PRE + "##tight\n\ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (5, 1), None),
    ("### opens a doc block", PRE + "###\n\ndef main() -> Void\nend\n", "PARSE-DETACHED-DOC", (5, 1), None),
    ("indented doc lines with a tab", PRE + "  ## a\n\t## b\n\ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (5, 3, 6, 6), None),
    ("doc blocks split by blank and comment lines", "## a\n\n## b\n# c\n## d\ndef main() -> Void\nend\n",
     "PARSE-DETACHED-DOC", (3, 1), None),
    ("doc block alone", "## a", "PARSE-DETACHED-DOC", (1, 1, 1, 5), None),
    ("doc block inside a function body", program(MAIN, "  x = 1 # note", "  ## doc", "  y = 2", "end"),
     "PARSE-DETACHED-DOC", (3, 3, 3, 9), None),
    ("doc line inside parentheses", program(MAIN, "  f(1,", "## doc", "2)", "end"),
     "PARSE-DETACHED-DOC", (3, 1, 3, 7), None),
]

# Sources that check clean; the doc blocks here are attached to the declaration under them.
CLEAN = [
    ("doc above a declaration", PRE + "## a\ndef main() -> Void\nend\n"),
    ("doc above an indented declaration", PRE + "## a\n  def main() -> Void\nend\n"),
    ("module doc followed by a blank line", "## a\n\ndef main() -> Void\nend\n"),
    ("doc above a declaration with CRLF",
     "def h() -> Int\r\n  return 1\r\nend\r\n\r\n## a\r\ndef main() -> Void\r\nend\r\n"),
    ("doc lines with CRLF", "## a\r\n## b\r\ndef main() -> Void\r\nend\r\n"),
    ("doc lines with tabs", PRE + "  ## a\n\t## b\ndef main() -> Void\nend\n"),
]

# (case, source, stdout): the program runs and prints this, with exit status 0.
RUNS = [
    ("range operators lex after integers",
     program(MAIN, "  puts((1..5).to_a)", "  puts(1.5)", "  n = 3", "  puts((0...n + 1).to_a)", "end"),
     "[1, 2, 3, 4, 5]\n1.5\n[0, 1, 2, 3]\n"),
    ("keywords, identifiers and numeric literals",
     program(MAIN, "  count = 12", "  ratio = 1.25", "  puts(count)", "  puts(ratio)", "end"),
     "12\n1.25\n"),
    ("Ruby-style operators and name suffixes",
     SUFFIX_DEFS + program(MAIN, "  a = false", "  b = true", "  c = true", "  puts(!a && b || c)", "  puts(a&&!b||c)",
                           "  puts(a!=b)", "  puts(save!(1)!=2)", "  puts(ready?())", "  x = 1", "  x += 1",
                           "  x -= 1", "  x *= 3", "  x /= 2", "  x %= 2", "  puts(x)", "end"),
     "true\ntrue\ntrue\ntrue\ntrue\n1\n"),
    ("interpolated strings split around expression tokens",
     program(MAIN, "  n = 2", r'  x = "a#{n + {"k": 1}["k"]}b#{"q"}c\#{d}"', "  puts(x)", '  puts("plain # text")',
             '  puts("## text")', '  puts("a#{1 + 2} ## b") ## note', "end"),
     "a3bqc#{d}\nplain # text\n## text\na3 ## b\n"),
    ("CRLF and comment newlines",
     "def main() -> Void\r\n  x = 1 # comment\r\n  puts(x)\r\nend\r\n",
     "1\n"),
    ("newlines inside parentheses, brackets and braces are suppressed",
     program(MAIN, "  x = ([", "1,", "2", "  ])", "  puts(x.length)", "  m = {", '"a": 1,', "  }", '  puts(m["a"])',
             "end"),
     "2\n1\n"),
    ("blocks and newlines inside a call's parentheses",
     program("def f(xs: List[Int], k: Int) -> Int", "  return xs.length + k", "end", "",
             "def g(n: Int) -> Int", "  return n", "end", "", MAIN,
             "  puts(f([1, 2].map do |x|", "    if x > 1", "      puts(x)", "    end", "    x", "  end, 1))",
             "  puts(g(", "1))", "end"),
     "2\n3\n1\n"),
    ("operators and delimiters",
     program(MAIN, "  a = 7", "  b = 2", "  puts(a + b)", "  puts(a - b)", "  puts(a * b)", "  puts(a / b)",
             "  puts(a % b)", "  puts(a == b)", "  puts(a != b)", "  puts(a < b)", "  puts(a > b)", "  puts(a <= b)",
             "  puts(a >= b)", "  xs = [a, b]", "  puts(xs[0])", '  m = {"k": a}', '  puts(m["k"])', "end"),
     "9\n5\n14\n3\n1\nfalse\ntrue\nfalse\ntrue\nfalse\ntrue\n7\n7\n"),
    ("pipe is the longest match next to | and ||",
     INC + program(MAIN, "  puts(1 |> inc())", "end"),
     "2\n"),
    ("function names take ? and ! with or without a space before the parentheses",
     SUFFIX_DEFS + program(MAIN, '  s = "abc"', '  puts(String.contains?(s, "b"))',
                           '  puts(String.contains? (s, "b"))', "  puts(ready?())", "  puts(save!(1)!=2)", "end"),
     "true\ntrue\ntrue\ntrue\n"),
    ("blank and comment lines emit NL without changing parsing",
     program(MAIN, "  x = 1", "", "  # comment", "  puts(x)", "end"),
     "1\n"),
    ("## after code and ## inside a string stay ordinary text",
     program("# plain", "#", "#! also plain", MAIN, "  x = 1 ## note", '  puts("## text")', "  puts(x)", "end"),
     "## text\n1\n"),
    ("strings decode only the specified escapes",
     r'def main() -> Void' + "\n" + r'  puts("quote: \" slash: \\ newline: \n return: \r tab: \t")' + "\nend\n",
     'quote: " slash: \\ newline: \n return: \r tab: \t\n'),
    ("digit separators are dropped from the value",
     program(MAIN, "  puts(1_000)", "  puts(1_000_000)", "  puts(1_000.000_5)", "  puts(0.5_5)", "  puts(1_000.5)",
             "  puts(-1_000)", "  puts(1_000.to_s)", "  puts((1_000..1_002).to_a)", "  puts((1_000...1_002).to_a)",
             "  _1 = 5", "  puts(_1)", "  _n = 2", "  puts((0.._n).to_a)", "  1_000.times do |i|", "  end", "end"),
     "1000\n1000000\n1000.0005\n0.55\n1000.5\n-1000\n1000\n[1000, 1001, 1002]\n[1000, 1001]\n5\n[0, 1, 2]\n"),
]


def span_of(problem):
    where = problem["range"]
    return (where["start"]["line"], where["start"]["column"], where["end"]["line"], where["end"]["column"])


class LexerSpec(TestCase):
    def check_all(self, sources):
        """Check each {case: source} as a file with `--json check`, side by side; gives {case: problem or None}."""
        directory = self.make_temp_dir()
        cases = list(sources)
        paths = []
        for index, case in enumerate(cases):
            path = directory / ("case-%d.agc" % index)
            path.write_bytes(sources[case].encode("utf-8"))
            paths.append(path)
        with ThreadPoolExecutor(WORKERS) as pool:
            results = list(pool.map(self.check_file, paths))
        return dict(zip(cases, results))

    def check_file(self, path):
        result = run(cli() + ["--json", "check", str(path)])
        if result.code == 0:
            self.assertEqual(result.stdout, '{"ok":true}\n')
            return None
        self.assertEqual(result.code, 1, result.stderr)
        return json.loads(result.stderr.strip().split("\n")[-1])

    def test_diagnostics_carry_the_code_and_span_of_the_rule(self):
        problems = self.check_all({case: source for case, source, *_ in DIAGNOSTICS})
        for case, _source, code, where, help_ in DIAGNOSTICS:
            with self.subTest(case):
                problem = problems[case]
                self.assertIsNotNone(problem, "the source checks clean")
                self.assertEqual(problem["code"], code)
                if where is not None:
                    self.assertEqual(span_of(problem)[:len(where)], where)
                if help_ is not None:
                    self.assertEqual("help" in problem, help_)

    def test_sources_that_check_clean(self):
        problems = self.check_all(dict(CLEAN))
        for case, _source in CLEAN:
            with self.subTest(case):
                self.assertIsNone(problems[case], problems[case])

    def test_programs_print_what_the_rule_says(self):
        directory = self.make_temp_dir()
        paths = {}
        for index, (case, source, _stdout) in enumerate(RUNS):
            path = directory / ("run-%d.agc" % index)
            path.write_bytes(source.encode("utf-8"))
            paths[case] = path
        with ThreadPoolExecutor(WORKERS) as pool:
            results = dict(zip(paths, pool.map(lambda path: run(cli() + [str(path)]), paths.values())))
        for case, _source, stdout in RUNS:
            with self.subTest(case):
                result = results[case]
                self.assertEqual((result.code, result.stdout), (0, stdout), result.stderr)
