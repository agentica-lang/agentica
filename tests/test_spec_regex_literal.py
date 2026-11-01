"""The regex literal `/pattern/flags` (docs/grammar/04-lexical.md), checked through the product CLI.

A diagnostic case asserts its code and its span (line and column of the start and of the exclusive end), never the
message. A run case checks that a literal behaves as `Regex.compile` of its body with the flags written as (?i) and (?s);
tests/fixtures/vm/regex-literal.agc is the golden of the same rule.
"""
import json

from tests.test_spec_lexer import run_all, span_of

IMPORT = 'import Regex from "std/regex"\n\n'


def program(*lines):
    return IMPORT + "def main() -> Void\n" + "".join("  " + line + "\n" for line in lines) + "end\n"


# (case, source, code, span): the span is (line, column, end line, end column). Line 4 is the first line of main.
DIAGNOSTICS = [
    ("no import of std/regex", "def main() -> Void\n  r = /a+/\nend\n", "CHECK-REGEX-IMPORT", (2, 7, 2, 11)),
    ("no import, in a constant", "RE = /a/\n\ndef main() -> Void\nend\n", "CHECK-REGEX-IMPORT", (1, 6, 1, 9)),
    # The span is the character of the body that std/regex names, counted from the opening /.
    ("unmatched close", program("r = /ab)/"), "CHECK-INVALID-REGEX", (4, 10, 4, 11)),
    ("bad repetition in a constant", IMPORT + "RE = /a{2,1}/\n\ndef main() -> Void\nend\n",
     "CHECK-INVALID-REGEX", (3, 8, 3, 9)),
    # An error past the body (the group is never closed) is the whole literal.
    ("unclosed group", program("r = /a(b/"), "CHECK-INVALID-REGEX", (4, 7, 4, 12)),
    ("unknown flag", program("r = /a/x"), "LEX-REGEX-FLAG", (4, 10, 4, 11)),
    ("repeated flag", program("r = /a/ii"), "LEX-REGEX-FLAG", (4, 11, 4, 12)),
    ("unterminated", program("r = /a"), "LEX-UNTERMINATED-REGEX", (4, 7, 4, 9)),
    ("interpolation", program("r = /a#{1}/"), "LEX-REGEX-INTERPOLATION", (4, 9, 4, 11)),
    # After an operator a / starts a regex, so a lone / with no closing one is an unterminated literal.
    ("slash with no operand", program("x = / 2"), "LEX-UNTERMINATED-REGEX", (4, 7, 4, 10)),
    # After a name a / is division, so `puts /x/` ends in a / with no operand; the help shows puts(/x/).
    ("regex after a name", program("puts /ab/"), "PARSE-UNEXPECTED-TOKEN", (4, 12, 5, 1)),
    ("regex as a case pattern", program('case "a"', "  /a/ -> puts(1)", "  _ -> puts(2)", "end"),
     "PARSE-UNEXPECTED-TOKEN", (5, 5, 5, 8)),
]

# (case, source, stdout)
RUNS = [
    ("a literal is Regex.compile of its body and flags",
     program('a = /(\\w+)@(\\w+)/i', 'b = Regex.compile("(?i)(\\\\w+)@(\\\\w+)").unwrap!',
             'puts(a.source == b.source)', 'text = "Ada@Home bob@x"',
             'puts(Regex.find_all(text, a).size == Regex.find_all(text, b).size)',
             'puts(Regex.match?("a\\nb", /a.b/m))', 'puts(Regex.match?("a\\nb", /a.b/))'),
     "true\ntrue\ntrue\nfalse\n"),
    ("a slash is division after a value and a regex after an operator",
     program("x = 12", "x /= 2", "puts(x / 3 / 2)", 'puts(Regex.match?("a/b", /a\\/b/))', "puts((/=x/).source)"),
     "1\ntrue\n=x\n"),
    ("a literal in a loop and in a constant",
     IMPORT + "WORDS = [/a/, /b/i]\n\ndef main() -> Void\n  count = 0\n  for text in [\"ab\", \"B\", \"c\"]\n"
     "    if Regex.match?(text, /[ab]/i) and Regex.match?(text, WORDS[1])\n      count += 1\n    end\n  end\n\n"
     "  puts(count)\nend\n",
     "2\n"),
]


def outcome(result):
    """The exit code, then the code and span of the diagnostic of a `--json check` run."""
    if result.code != 1:
        return (result.code, result.stdout, None)
    problem = json.loads(result.stderr.strip().split("\n")[-1])
    return (1, problem["code"], span_of(problem))


def test_diagnostics_carry_the_code_and_span_of_the_rule(tmp_path):
    results = run_all(tmp_path, {case: source for case, source, *_ in DIAGNOSTICS}, ["--json", "check"])
    found = [(case, *outcome(results[case])) for case, *_ in DIAGNOSTICS]
    assert found == [(case, 1, code, where) for case, _source, code, where in DIAGNOSTICS]


def test_programs_print_what_the_rule_says(tmp_path):
    results = run_all(tmp_path, {case: source for case, source, _ in RUNS})
    found = [(case, results[case].code, results[case].stdout) for case, *_ in RUNS]
    assert found == [(case, 0, stdout) for case, _source, stdout in RUNS]
