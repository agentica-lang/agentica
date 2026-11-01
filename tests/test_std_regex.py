"""std/regex: regular expressions with a Pike VM written in Agentica (docs/future/48-regex.md, phase 48a).

tests/fixtures/regex/driver.agc reads one JSON case per line of stdin and prints one JSON reply per line. The peer is
Python's re with re.ASCII, which is not the code under test, after mechanical translations of the forms where Python
differs (48.4): `\\z` is `\\Z`, `(?<name>` is `(?P<name>`, and a `$` outside a class, in a pattern without `(?m)`, is
`\\Z` (Python's `$` also matches before a final newline). The Go rules that Python does not follow (the empty match
right after a match is dropped, `split` ignores empty matches, the `$` template) are applied to Python's spans here.
Whole-match spans are always compared; group spans only where no group sits inside a repetition, since Python keeps
the last iteration of `(a*)*` where Go does not. Forms Python rejects or reads otherwise are in the VM golden
tests/fixtures/vm/std-regex.agc.
"""
import json
import random
import re

import pytest

from tests.agentica_test import FIXTURES, cli, compile_agc, compile_text, run, run_json_cases, run_vm

# (pattern, texts, compare_groups)
TABLE = [
    ("abc", ["abc", "xxabcxabc", "ab", ""], True),
    ("a|ab", ["ab", "b", "aab"], True),
    ("ab|a", ["ab", "a b"], True),
    ("(foo|foobar)bar", ["foobarbar", "foobar"], True),
    ("(a|ab)(c|bcd)(d*)", ["abcd", "acd"], True),
    ("a*", ["", "aaa", "baaab"], True),
    ("a+", ["aaa", "baab", "b"], True),
    ("a?b", ["ab", "b", "aab"], True),
    ("a*?b", ["aaab", "b"], True),
    ("a+?", ["aaa"], True),
    ("(a+?)(a*)", ["aaaa"], True),
    ("a??b", ["ab"], True),
    ("<.+?>", ["<a><bb>", "<>"], True),
    ("<.+>", ["<a><bb>"], True),
    ("a{2}", ["aaaaa", "a"], True),
    ("a{2,}", ["aaaaa", "a aa"], True),
    ("a{2,3}", ["aaaaaaa"], True),
    ("a{2,3}?", ["aaaaaaa"], True),
    ("a{0}b", ["ab", "b"], True),
    ("(ab){1,2}c", ["ababc", "abc", "abababc"], False),
    ("x*", ["abxd", "xx", ""], True),
    ("", ["abc", ""], True),
    ("[a-c]+", ["xxabcbay", "d"], True),
    ("[^a-c]+", ["abxyzc", "abc"], True),
    ("[]a]+", ["a]]a b"], True),
    ("[^]a]+", ["a]]bc"], True),
    ("[a-]+", ["--a-b"], True),
    ("[-a]+", ["--a-b"], True),
    ("[\\d.]+", ["v1.25 and 3"], True),
    ("[\\w-]+", ["foo-bar baz_1"], True),
    ("[^\\s]+", ["a b\tc\nd"], True),
    ("[\\]\\[]+", ["x[]]y"], True),
    ("\\d+", ["abc 123 def 45", "none", "٣٤"], True),
    ("\\D+", ["ab12cd"], True),
    ("\\w+", ["hello wörld_1 !", "日本 abc"], True),
    ("\\W+", ["a, b; c"], True),
    ("\\s+", ["a \t\r\n\fb", "ab"], True),
    ("\\S+", ["a  bc\nd"], True),
    ("^ab", ["abab", "xab"], True),
    ("ab$", ["abab", "ab\n", "abx"], True),
    ("^$", ["", "a", "\n"], True),
    ("(?m)^\\w+", ["one\ntwo\n\nthree"], True),
    ("(?m)\\w+$", ["one\ntwo\n\nthree"], True),
    ("(?m)^", ["a\nb\n"], True),
    ("(?m)$", ["a\nb\n"], True),
    ("\\bfoo\\b", ["foo food afoo foo.", "foo"], True),
    ("\\Bo\\B", ["foo boo o"], True),
    ("\\b", ["ab cd"], True),
    ("\\Aab", ["abab"], True),
    ("ab\\z", ["abab", "ab\n"], True),
    ("(a)(b)?", ["ab", "a", "ba"], True),
    ("(a)|(b)", ["b", "a"], True),
    ("(?:ab)+", ["ababx", "aba"], True),
    ("(?P<x>a+)(?<y>b)", ["aab", "xab"], True),
    ("(a|b)*c", ["abac", "c", "ab"], False),
    ("((a)|b)+", ["ab", "ba"], False),
    ("(?i)abc", ["ABC", "aBc", "xAbCx"], True),
    ("(?i)[a-c]+", ["xAbCd"], True),
    ("(?i)[^a]+", ["AaBb"], True),
    ("(?i:a)b", ["Ab", "AB", "ab"], True),
    ("a(?i:b)c", ["aBc", "ABc", "abC"], True),
    ("(?s)a.b", ["a\nb", "axb"], True),
    ("a.b", ["a\nb", "axb", "a€b"], True),
    ("(?s:.)+", ["a\nb"], True),
    ("\\x41\\x{42}", ["ABC", "ab"], True),
    ("\\x{20AC}+", ["a€€b"], True),
    ("[\\x41-\\x43]+", ["xABCD"], True),
    ("\\.\\+\\*\\?\\(\\)\\|\\[\\]\\{\\}\\^\\$\\\\", [".+*?()|[]{}^$\\"], True),
    ("\\n\\t", ["a\n\tb"], True),
    ("a{x}", ["a{x}"], True),
    ("a{", ["a{"], True),
    ("{", ["{a{"], True),
    ("a}", ["a}"], True),
    ("]", ["a]"], True),
    ("é+", ["cafééé"], True),
    ("[é-ü]+", ["aéöü"], True),
    ("😀(.)", ["a😀b😀"], True),
    ("(\\w+)@(\\w+)\\.com", ["mail bob@example.com and al@b.com"], True),
    ("(\\d{4})-(\\d{2})-(\\d{2})", ["on 2024-05-06 and 1999-12-31"], True),
    ("(a*)+", ["b", "aa"], False),
    ("(a*)*", ["b", "aa"], False),
    ("(a|)+", ["aab"], False),
    ("(?:a*)*b", ["aaab", "aaa"], True),
    ("x*y*z*", ["xxyz zz", ""], True),
]

TEMPLATES = ["<$0>", "[${0}]", "$$", ""]


def to_python(pattern):
    """The pattern with the translations of the module doc, for re.compile(..., re.ASCII)."""
    out = []
    i = 0
    in_class = False
    multiline = "(?m" in pattern
    while i < len(pattern):
        c = pattern[i]
        braced = re.match(r"\\x\{([0-9A-Fa-f]+)\}", pattern[i:])
        if braced:
            out.append("\\U%08x" % int(braced.group(1), 16))
            i += len(braced.group())
            continue
        if c == "\\" and i + 1 < len(pattern):
            pair = pattern[i:i + 2]
            out.append("\\Z" if pair == "\\z" else pair)
            i += 2
            continue
        if in_class:
            in_class = c != "]"
        elif c == "[":
            in_class = True
            out.append(c)
            i += 1
            # A `]` right after `[` or `[^` is a literal.
            if i < len(pattern) and pattern[i] == "^":
                out.append("^")
                i += 1
            if i < len(pattern) and pattern[i] == "]":
                out.append("\\]")
                i += 1
            continue
        elif c == "$" and not multiline:
            out.append("\\Z")
            i += 1
            continue
        elif pattern.startswith("(?<", i) and pattern[i + 3:i + 4] not in ("=", "!"):
            out.append("(?P<")
            i += 3
            continue
        out.append(c)
        i += 1
    return "".join(out)


def go_spans(rx, text):
    """Every match as a list of group spans, by Go's rule for empty matches (48.5)."""
    found = []
    pos = 0
    prev_end = -1
    while pos <= len(text):
        m = rx.search(text, pos)
        if m is None:
            break
        if m.end() == pos:
            if m.start() != prev_end:
                found.append(m)
            pos += 1
        else:
            found.append(m)
            pos = m.end()
        prev_end = m.end()
    return found


def flat(m):
    return [x for g in range(len(m.groups()) + 1) for x in m.span(g)]


def expand(template, m, names):
    """The template rules of 48.5, written apart from std/regex."""
    out = []
    i = 0
    while i < len(template):
        if template[i] != "$":
            out.append(template[i])
            i += 1
            continue
        rest = template[i + 1:]
        if rest.startswith("$"):
            out.append("$")
            i += 2
            continue
        digits = re.match(r"[0-9]+", rest)
        braced = re.match(r"\{([0-9A-Za-z_]+)\}", rest)
        if digits:
            ref = int(digits.group())
            i += 1 + len(digits.group())
        else:
            key = braced.group(1)
            ref = int(key) if key.isdigit() else names[key]
            i += 1 + len(braced.group())
        out.append(m.group(ref) or "")
    return "".join(out)


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "regex" / "driver.agc", tmp_path_factory.mktemp("agentica-regex-") / "driver.agcb")


def call(driver, cases):
    """Run [{op, pattern, text, template}] through the driver and return one reply dict per case."""
    return run_json_cases(driver, [{"op": "", "pattern": "", "text": "", "template": "", **case} for case in cases])


def peer_cases(table):
    """The cases of the table and the reply Python's re gives for each, with the Go rules applied."""
    cases = []
    expected = []
    for pattern, texts, compare_groups in table:
        rx = re.compile(to_python(pattern), re.ASCII)
        names = rx.groupindex
        templates = TEMPLATES + (["[$1]", "${1}x$$"] if rx.groups and compare_groups else [])
        for text in texts:
            matches = go_spans(rx, text)
            spans = [flat(m) if compare_groups else list(m.span()) for m in matches]
            cases.append({"op": "find_all", "pattern": pattern, "text": text})
            expected.append(("find_all", compare_groups, spans))
            first = rx.search(text)
            cases.append({"op": "match", "pattern": pattern, "text": text})
            expected.append(("match", compare_groups, [flat(first) if compare_groups else list(first.span())]
                             if first else None))
            cases.append({"op": "match?", "pattern": pattern, "text": text})
            expected.append(("match?", True, first is not None))
            parts = []
            last = 0
            for m in matches:
                if m.end() > m.start():
                    parts.append(text[last:m.start()])
                    last = m.end()
            parts.append(text[last:])
            cases.append({"op": "split", "pattern": pattern, "text": text})
            expected.append(("split", True, parts))
            for template in templates:
                pieces = []
                last = 0
                for m in matches:
                    pieces.append(text[last:m.start()])
                    pieces.append(expand(template, m, names))
                    last = m.end()
                pieces.append(text[last:])
                cases.append({"op": "replace", "pattern": pattern, "text": text, "template": template})
                expected.append(("replace", True, "".join(pieces)))
    return cases, expected


def check_against_peer(driver, table):
    cases, expected = peer_cases(table)
    replies = call(driver, cases)
    for case, (op, compare_groups, want), reply in zip(cases, expected, replies):
        if op == "match" and want is None:
            assert not reply["success"] and reply["message"] == "no match", (case, reply)
            continue
        assert reply["success"], (case, reply)
        if op in ("find_all", "match"):
            got = reply["spans"] if compare_groups else [spans[:2] for spans in reply["spans"]]
        else:
            got = {"match?": reply["found"], "split": reply["parts"], "replace": reply["text"]}[op]
        assert got == want, (case, got, want)


def test_the_table_gives_what_python_re_gives_with_the_go_rules(driver):
    check_against_peer(driver, TABLE)


# Generated patterns over a small alphabet: literals, classes, groups, alternation and the quantifiers.
def random_pattern(rng, depth=0):
    parts = []
    for _ in range(rng.randint(1, 4)):
        roll = rng.random()
        if roll < 0.35 or depth > 2:
            atom = rng.choice(["a", "b", "c", ".", "[ab]", "[^a]", "\\w", "\\s", "\\d", "\\b", "^", "$"])
        elif roll < 0.6:
            atom = "(" + random_pattern(rng, depth + 1) + ")"
        elif roll < 0.8:
            atom = "(?:" + random_pattern(rng, depth + 1) + "|" + random_pattern(rng, depth + 1) + ")"
        else:
            atom = "(?i:" + random_pattern(rng, depth + 1) + ")"
        if atom not in ("\\b", "^", "$") and rng.random() < 0.4:
            atom += rng.choice(["*", "+", "?", "{1,2}", "*?", "+?", "??", "{2}"])
        parts.append(atom)
    return "".join(parts)


@pytest.mark.slow
def test_generated_patterns_give_what_python_re_gives(driver):
    rng = random.Random(4801)
    table = []
    while len(table) < 400:
        pattern = random_pattern(rng)
        try:
            re.compile(to_python(pattern), re.ASCII)
        except re.error:
            continue
        texts = ["".join(rng.choice("abcAB1 \n") for _ in range(rng.randint(0, 12))) for _ in range(3)]
        # A group inside a repetition may differ (module doc): such patterns compare whole matches only.
        table.append((pattern, texts, not re.search(r"\)[*+?{]", pattern)))
    check_against_peer(driver, table)


# (pattern, character of the error, a word of the message)
ERRORS = [
    ("(abc", 5, "missing ')' for the group at character 1"),
    ("a(b(c)", 7, "missing ')' for the group at character 2"),
    ("ab)", 3, "unexpected ')'"),
    ("[abc", 5, "missing ']' for the class at character 1"),
    ("a[^]", 5, "missing ']'"),
    ("\\q", 1, "invalid escape"),
    ("ab\\", 3, "trailing backslash"),
    ("a{3,2}", 2, "invalid repetition"),
    ("a{1001}", 2, "repetition count over 1000"),
    ("a**", 3, "nested repetition"),
    ("a+*", 3, "nested repetition"),
    ("a{2}{3}", 5, "nested repetition"),
    ("*a", 1, "nothing to repeat"),
    ("a|+", 3, "nothing to repeat"),
    ("(?i)*", 5, "nothing to repeat"),
    ("(?x)", 3, "unknown flag 'x'"),
    ("(?U)a", 3, "unknown flag 'U'"),
    ("(?i-)", 5, "missing flag"),
    ("(?P<a>x)(?P<a>y)", 9, "duplicate group name \"a\""),
    ("(?P<1a>x)", 1, "invalid group name"),
    ("(?<a", 1, "invalid group name"),
    ("[z-a]", 2, "invalid class range"),
    ("[\\d-z]", 4, "invalid class range"),
    ("\\x{D800}", 1, "not a Unicode scalar value"),
    ("\\x{110000}", 1, "not a Unicode scalar value"),
    ("\\xG1", 1, "invalid escape \\x"),
    ("(a)\\1", 4, "backreferences are not supported"),
    ("(?P<n>a)(?P=n)", 9, "backreferences are not supported"),
    ("(?=a)", 1, "lookaround is not supported"),
    ("(?<!a)b", 1, "lookaround is not supported"),
    ("(?>a)", 1, "atomic groups are not supported"),
    ("\\pL", 1, "\\p is not supported yet"),
    ("\\Qa\\E", 1, "\\Q...\\E is not supported"),
    ("\\Z", 1, "invalid escape \\Z"),
    ("[\\b]", 2, "invalid escape \\b"),
    ("[[:alpha:]]", 2, "POSIX classes such as [:alpha:] are not supported"),
    ("[a[:digit:]b]", 3, "POSIX classes"),
    ("\\a", 1, "invalid escape \\a"),
    ("\\0", 1, "invalid escape \\0"),
    ("(" * 257 + ")" * 257, 257, "groups nest more than 256 levels"),
    ("()" * 257, 513, "more than 256 groups"),
    ("a" * 4097, 4097, "longer than 4096 characters"),
    ("(?:a{1000}){11}", 1, "more than 10000 instructions"),
    ("((((a{1000}){1000}){1000}){1000})", 1, "more than 10000 instructions"),
]


def test_a_compile_error_starts_with_the_character_where_it_is(driver):
    replies = call(driver, [{"op": "compile", "pattern": pattern} for pattern, _, _ in ERRORS])
    for (pattern, place, words), reply in zip(ERRORS, replies):
        assert not reply["success"], pattern
        assert reply["message"].startswith(f"character {place}: "), (pattern[:40], reply["message"])
        assert words in reply["message"], (pattern[:40], reply["message"])


def test_the_limits_themselves_compile(driver):
    patterns = ["a" * 4096, "(" * 256 + ")" * 256, "()" * 256, "a{1000}", "(?:a{1000}){9}"]
    replies = call(driver, [{"op": "compile", "pattern": pattern} for pattern in patterns])
    assert [reply["message"] for reply in replies] == [""] * len(patterns)


def test_a_bad_template_is_an_error_before_anything_is_replaced(driver):
    cases = [
        ("(a)", "$2", "no group 2"),
        ("(a)", "$10", "no group 10"),
        ("(a)", "${x}", "no group named \"x\""),
        ("(a)", "a$", "template character 2"),
        ("(a)", "$x", "template character 1"),
        ("(a)", "${1", "template character 1"),
        ("(a)", "${}", "template character 1"),
    ]
    replies = call(driver, [{"op": "replace", "pattern": p, "text": "zzz", "template": t} for p, t, _ in cases])
    for (pattern, template, words), reply in zip(cases, replies):
        assert not reply["success"] and words in reply["message"], (template, reply)


def test_escape_gives_a_pattern_that_matches_its_input(driver):
    texts = ["a.b*c", "\\.+*?()|[]{}^$", "(?i)x", "a{2}", "é😀 #-"]
    escaped = [reply["text"] for reply in call(driver, [{"op": "escape", "text": text} for text in texts + [""]])]
    assert escaped.pop() == ""
    assert escaped[1] == "\\\\\\.\\+\\*\\?\\(\\)\\|\\[\\]\\{\\}\\^\\$"
    replies = call(driver, [{"op": "match", "pattern": pattern, "text": "x" + text + "y"} for pattern, text
                            in zip(escaped, texts)])
    for text, reply in zip(texts, replies):
        assert reply["spans"][0][:2] == [1, 1 + len(text)], (text, reply)
    assert all(re.fullmatch(pattern, text) for pattern, text in zip(escaped, texts))


REDOS = """import Regex from "std/regex"

def main() -> Void
  size = System.args()[0].to_i!
  re = Regex.compile("(a+)+$").unwrap!
  text = List.repeat("a", size).join("") + "!"
  before = Profile.steps()
  puts(Regex.match?(text, re))
  puts(Regex.match(text, re).ok?)
  puts(before)
  puts(Profile.steps() - before)
end
"""


def test_a_pathological_pattern_runs_in_linear_steps_and_stops_at_the_step_limit(tmp_path):
    """`(a+)+$` on "a" * n + "!" takes exponential time in a backtracking matcher. Here the two searches take a step
    per chunk of at most 256 characters each, so 24000 more characters cost at most about 2 * 24000 / 256 more steps,
    and a budget that ends in the middle stops them with RUNTIME-STEP-LIMIT."""
    bytecode = compile_text(REDOS, "redos", tmp_path)
    spent = {}
    for size in (8000, 32000):
        result = run_vm(bytecode, args=[str(size)])
        lines = result.stdout.splitlines()
        assert result.code == 0 and lines[:2] == ["false", "false"], (size, result.stderr)
        before, spent[size] = int(lines[2]), int(lines[3])
    assert spent[32000] - spent[8000] <= 2 * (24000 // 256 + 2), spent
    result = run_vm(bytecode, "--json", "--max-steps", str(before + spent[32000] // 2), args=["32000"])
    assert result.code == 1 and '"RUNTIME-STEP-LIMIT"' in result.stderr, result.stderr


CANCEL = """import Regex from "std/regex"

def search(text: String) -> Result[Bool]
  re = try Regex.compile("(a+)+$")
  return ok(Regex.match?(text, re))
end

def main() -> Void
  text = "a"
  while text.length < 4000000
    text = text + text
  end
  task = Task.spawn(&search, text + "!")
  Task.sleep(1)
  Task.cancel(task)
  puts(Task.await(task))
end
"""


def test_a_long_search_hands_the_scheduler_back_and_can_be_cancelled(tmp_path):
    """On one scheduler, main gets its turn back while the search of millions of characters runs, and cancels it."""
    result = run_vm(compile_text(CANCEL, "cancel", tmp_path), "--schedulers", "1")
    assert result.code == 0 and result.stdout == 'error("task: cancelled")\n', result.stderr


@pytest.mark.parametrize("body, code", [
    ("def make(p: Regex.Program) -> Regex.Regex\n  return Regex.Regex(source: \"x\", program: p)\nend\n",
     "CHECK-IMPORT-NAME"),
    ("def bad(re: Regex.Regex) -> Regex.Regex\n  return re.with(program: re.program.with(ops: []))\nend\n",
     "CHECK-IMPORT-NAME"),
    ("def bad(text: String) -> Result[Regex.Regex]\n  return JSON.decode(text, Regex.Regex)\nend\n",
     "CHECK-NOT-DECODABLE"),
])
def test_only_compile_makes_the_program_of_a_regex(tmp_path, body, code):
    source = tmp_path / "forge.agc"
    source.write_text('import Regex from "std/regex"\n\n' + body, encoding="utf-8")
    result = run([*cli(), "--json", "check", source])
    assert result.code == 1 and json.loads(result.stderr.splitlines()[0])["code"] == code, result.stderr
