"""Lexer rules of the language, checked through the product CLI.

A source text is checked with `--json check`, or run as a program. A diagnostic case asserts its code and its span: the
line and column of the start, and of the end when the case gives one (the end is exclusive). `help` is asserted only as
present or absent: messages and helps are text, and the tests do not compare text. Token kinds, lexemes and values are
not visible through the CLI; tests/test_frontend_lexer.py pins the token output of the Agentica lexer.
"""
import json
from concurrent.futures import ThreadPoolExecutor

from tests.agentica_test import cli, run

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
    # Heredocs (§25.10): the opener `<<~NAME` is the span of the errors about the whole heredoc.
    ("heredoc without an end line", "x = <<~A\n  one\n  two\n", "LEX-UNTERMINATED-HEREDOC", (1, 5, 1, 9), True),
    ("heredoc opener at the end of the file", "x = <<~A", "LEX-UNTERMINATED-HEREDOC", (1, 5, 1, 9), None),
    ("heredoc end line with trailing text", "x = <<~A\n  one\n  two\nA b\n", "LEX-UNTERMINATED-HEREDOC", (1, 5, 1, 9), None),
    ("heredoc with one line", "x = <<~A\n  one\nA\n", "LEX-HEREDOC-ONE-LINE", (1, 5, 1, 9), True),
    ("heredoc with no line", "x = <<~A\nA\n", "LEX-HEREDOC-ONE-LINE", (1, 5, 1, 9), None),
    ("heredoc with a tab in a body line", "x = <<~A\n  one\n\ttwo\nA\n", "LEX-HEREDOC-INDENT", (3, 1, 3, 2), True),
    ("heredoc with a tab in a blank line", "x = <<~A\n  one\n \t\n  two\nA\n", "LEX-HEREDOC-INDENT", (3, 2, 3, 3), None),
    ("heredoc with a tab before the end name", "x = <<~A\n  one\n  two\n\tA\n", "LEX-HEREDOC-INDENT", (4, 1, 4, 2), None),
    ("heredoc name in lower case", "x = <<~text\n  a\n  b\ntext\n", "LEX-UNEXPECTED-CHAR", (1, 5, 1, 8), True),
    ("heredoc name that ends in lower case", "x = <<~Ab\n  a\n  b\nAb\n", "LEX-UNEXPECTED-CHAR", (1, 5, 1, 8), None),
    ("heredoc without the tilde", "x = <<NAME\n  a\n  b\nNAME\n", "LEX-UNEXPECTED-CHAR", (1, 5, 1, 7), True),
    ("heredoc with a dash", "x = <<-NAME\n  a\n  b\nNAME\n", "LEX-UNEXPECTED-CHAR", (1, 5, 1, 8), True),
    ("quoted heredoc name", "x = <<~'NAME'\n  a\n  b\nNAME\n", "LEX-UNEXPECTED-CHAR", (1, 5, 1, 8), True),
    ("invalid escape in a heredoc", "x = <<~A\n  a \\q\n  b\nA\n", "LEX-INVALID-ESCAPE", (2, 5, 2, 7), None),
    ("interpolation of a heredoc that does not end on its line", "x = <<~A\n  a #{1 +\n  b\nA\n",
     "LEX-UNTERMINATED-STRING", (2, 5), None),
    ("heredoc inside an interpolation", 'x = "#{<<~A}"\n  a\n  b\nA\n', "LEX-UNTERMINATED-STRING", (1, 5), None),
    ("heredoc inside the interpolation of a heredoc", "x = <<~A\n  a #{<<~B}\n  b\nA\n",
     "LEX-UNTERMINATED-STRING", (2, 5), None),
    ("an error inside a heredoc interpolation points into the body",
     program(MAIN, "  text = <<~A", "    one", '    two #{1 + "x"}', "  A", "end"),
     "CHECK-TYPE-MISMATCH", (4, 13), None),
    # Digit separators: only between two digits; the span is the literal as written.
    ("trailing separator", "1_", "LEX-INVALID-NUMBER", (1, 1, 1, 3), None),
    ("trailing separator before a letter", "1_a", "LEX-INVALID-NUMBER", (1, 1, 1, 3), None),
    ("double separator", "1__0", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("separator before the dot", "1_.5", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("separator after the dot", "1._5", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("trailing separator in the fraction", "1.5_", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("double separator in the fraction", "1.5__5", "LEX-INVALID-NUMBER", (1, 1, 1, 7), None),
    ("trailing separator after digits", "1_000_", "LEX-INVALID-NUMBER", (1, 1, 1, 7), None),
    ("separator before the exponent", "1_e5", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("trailing separator in the exponent", "1e5_", "LEX-INVALID-NUMBER", (1, 1, 1, 5), None),
    ("separator before a method", "x = 1_.times", "LEX-INVALID-NUMBER", (1, 5, 1, 7), None),
    # Hex, binary and octal literals: a prefix needs a digit, a digit of its base, and a `_` between two digits.
    ("radix prefix with no digit", "x = 0x", "LEX-INVALID-NUMBER", (1, 5, 1, 7), None),
    ("separator after the radix prefix", "x = 0b_1", "LEX-INVALID-NUMBER", (1, 5, 1, 9), None),
    ("trailing separator in a hex literal", "x = 0xFF_", "LEX-INVALID-NUMBER", (1, 5, 1, 10), None),
    ("double separator in a binary literal", "x = 0b1__0", "LEX-INVALID-NUMBER", (1, 5, 1, 11), None),
    ("binary digit above 1", "x = 0b102", "LEX-INVALID-NUMBER", (1, 5, 1, 10), None),
    ("octal digit above 7", "x = 0o8", "LEX-INVALID-NUMBER", (1, 5, 1, 8), None),
    ("hex letter above f", "x = 0xFG", "LEX-INVALID-NUMBER", (1, 5, 1, 9), None),
    ("hex literal above the Int range", program(MAIN, "  x = 0x8000_0000_0000_0000", "end"), "CHECK-INT-RANGE",
     (2, 7, 2, 28), None),
    # A very long literal lexes in linear time: it is out of range without its decimal value being worked out.
    ("hex literal of 20000 digits", program(MAIN, "  x = 0x" + "F" * 20000, "end"), "CHECK-INT-RANGE",
     (2, 7, 2, 20009), None),
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
    # Leading-dot continuation (§4): a line that starts with `.name` continues the line before it.
    ("blank line ends a chain", program(MAIN, "  xs = [1]", "", "    .size", "end"),
     "PARSE-UNEXPECTED-TOKEN", (4, 5, 4, 6), True),
    ("blank line after a comment ends a chain", program(MAIN, "  xs = [1]", "  # note", "", "  .size", "end"),
     "PARSE-UNEXPECTED-TOKEN", (5, 3, 5, 4), True),
    ("stray leading dot in a block", program(MAIN, "  .size", "end"), "PARSE-UNEXPECTED-TOKEN", (2, 3, 2, 4), True),
    ("stray leading dot after a do head", program(MAIN, "  [1].each do |x|", "    .size", "  end", "end"),
     "PARSE-UNEXPECTED-TOKEN", (3, 5, 3, 6), True),
    ("stray leading dot after a return type", "def f() -> Int\n  .size\nend\n",
     "PARSE-UNEXPECTED-TOKEN", (2, 3, 2, 4), None),
    ("stray leading dot after a field type", "struct P\n  a: Int\n  .size\nend\n",
     "PARSE-UNEXPECTED-TOKEN", (3, 3, 3, 4), None),
    ("leading dot on the first line of an if body", program(MAIN, "  x = [1]", "  if x.size > 0", "    .size", "  end",
                                                            "end"),
     "PARSE-UNEXPECTED-TOKEN", (4, 5, 4, 6), True),
    ("leading dot on the first line of an elsif body",
     program(MAIN, "  x = [1]", "  if false", "    puts(1)", "  elsif x.size > 0", "    .size", "  end", "end"),
     "PARSE-UNEXPECTED-TOKEN", (6, 5, 6, 6), True),
    ("leading dot on the first line of a while body", program(MAIN, "  x = [1]", "  while x.size > 0", "    .size",
                                                               "  end", "end"),
     "PARSE-UNEXPECTED-TOKEN", (4, 5, 4, 6), True),
    ("leading dot on the first line of a for body", program(MAIN, "  x = [1]", "  for a in x", "    .size", "  end",
                                                             "end"),
     "PARSE-UNEXPECTED-TOKEN", (4, 5, 4, 6), True),
    ("leading dot on the first line of a case body", program(MAIN, "  x = 1", "  case x", "    .size", "  end", "end"),
     "PARSE-UNEXPECTED-TOKEN", (4, 5, 4, 6), None),
    ("stray leading dot after a generic return type", "def f() -> List[Int]\n  .size\nend\n",
     "PARSE-UNEXPECTED-TOKEN", (2, 3, 2, 4), None),
    ("stray leading dot after a qualified return type",
     'import M from "m"\n\ndef f() -> M.T\n  .size\nend\n', "PARSE-UNEXPECTED-TOKEN", (4, 3, 4, 4), None),
    ("stray leading dot after a map field type", "struct P\n  a: Map[String, Int]\n  .x\nend\n",
     "PARSE-UNEXPECTED-TOKEN", (3, 3, 3, 4), None),
    ("keyword method name after a leading dot", program(MAIN, "  x = [1]", "    .end", "end"),
     "PARSE-UNEXPECTED-TOKEN", (3, 6, 3, 9), None),
    ("leading dot after the end of an if", program(MAIN, "  if true", "    puts(1)", "  end", "  .size", "end"),
     "PARSE-UNEXPECTED-TOKEN", (5, 3, 5, 4), None),
    ("leading dot after an operator", program(MAIN, "  x = 1 +", "  .size", "end"),
     "PARSE-UNEXPECTED-TOKEN", (2, 10, 3, 1), None),
    ("leading dot before a doc line", program(MAIN, "  x = [1]", "  ## doc", "  .size", "end"),
     "PARSE-DETACHED-DOC", (3, 3, 3, 9), None),
    ("leading range does not continue", program(MAIN, "  x = 1", "  ..3", "end"),
     "PARSE-UNEXPECTED-TOKEN", (3, 3, 3, 5), None),
    ("leading ellipsis does not continue", program(MAIN, "  x = 1", "  ...3", "end"),
     "PARSE-UNEXPECTED-TOKEN", (3, 3, 3, 6), None),
    ("leading dot and a number does not continue", program(MAIN, "  x = 1", "  .5", "end"),
     "PARSE-UNEXPECTED-TOKEN", (3, 3, 3, 4), None),
    ("leading pipe does not continue", program(MAIN, "  x = 1", "    |> f()", "end"),
     "PARSE-UNEXPECTED-TOKEN", (3, 5, 3, 7), None),
    ("error in a joined chain spans its lines", program(MAIN, "  xs = [1, 2]", "    .map do |x| x end", "    .nope",
                                                       "end"),
     "CHECK-UNKNOWN-METHOD", (2, 8, 4, 10), None),
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
    ("leading-dot chain with a comment line and CRLF",
     "def main() -> Void\r\n  xs = [1, 2]  # raw\r\n  # step\r\n    .map do |x| x end\r\nend\r\n"),
    ("doc lines with tabs", PRE + "  ## a\n\t## b\ndef main() -> Void\nend\n"),
    # An empty file lexes and parses with no error; `check` does not need a main.
    ("empty file", ""),
]

# (case, source, stdout): the program runs and prints this, with exit status 0.
RUNS = [
    ("leading-dot chain over lines, comments and blocks",
     program(MAIN, "  xs = [1, 2, 3, 4]  # the numbers", "    .drop(1)  # header", "    # twice", "    .map do |x|",
             "      y = x * 2", "      y", "    end", "    .filter do |x| x > 4 end", "    .map do |x| x + 1 end",
             "  puts(xs)", "end"),
     "[7, 9]\n"),
    ("leading-dot struct update chain and heredoc",
     "struct P\n  a: Int\n  b: Int\nend\n\n"
     + program(MAIN, "  p = P(a: 1, b: 2)", "    .with(a: 5)", "    .with(b: 6)", "  puts(p.a + p.b)", "  s = <<~T",
               "    hi", "    yo", "  T", "    .upcase", "  puts(s.length)", "end"),
     "11\n6\n"),
    ("leading-dot chain in a block inside parentheses",
     program(MAIN, "  xs = [-1, 2]", "  puts(xs", "    .map do |x|", "      x", "        .to_s", "    end)", "end"),
     '["-1", "2"]\n'),
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
    ("heredoc: common indentation, blank lines, escapes and interpolation",
     program(MAIN, "  name = \"tool\"", "  text = <<~TEXT", "    Usage: #{name} [options]", "", "      --verbose   print more",
             "   ", '    "quoted" \\t tab \\#{not} # not a comment', "  TEXT", "  puts(text)", "end"),
     'Usage: tool [options]\n\n  --verbose   print more\n\n"quoted" \t tab #{not} # not a comment\n\n'),
    ("heredoc: two on one line take their bodies in order",
     program("def pair(a: String, b: String) -> String", '  return "#{a}|#{b}"', "end", "", MAIN,
             "  puts(pair(<<~FIRST, <<~SECOND))", "    one", "    two", "  FIRST", "    three", "    four", "  SECOND",
             "  puts(1)", "end"),
     "one\ntwo\n|three\nfour\n\n1\n"),
    ("heredoc: the call goes on after the end line",
     program("def pair(a: String, b: Int) -> String", '  return "#{a}|#{b}"', "end", "", MAIN,
             "  puts(pair(<<~A,", "    first", "    second", "  A", "    7))", "end"),
     "first\nsecond\n|7\n"),
    ("heredoc: strings, maps and calls inside the interpolation",
     program(MAIN, '  n = "x"', "  text = <<~T", '    #{1 + 2} #{"a#{n}b"} #{{"k": 5}["k"]} #{n.upcase}', "    tail", "  T",
             "  puts(text)", "end"),
     "3 axb 5 X\ntail\n\n"),
    ("heredoc: the end line may end the file, and CRLF lines read as LF",
     "def main() -> Void\r\n  puts(<<~A)\r\n    one\r\n      two\r\n  A\r\nend\r\n",
     "one\n  two\n\n"),
    ("heredoc: << and <= keep their tokens",
     program(MAIN, "  a = 1", "  b = 2", "  puts(a <= b)", "  puts(a < b)", "end"),
     "true\ntrue\n"),
    ("digit separators are dropped from the value",
     program(MAIN, "  puts(1_000)", "  puts(1_000_000)", "  puts(1_000.000_5)", "  puts(0.5_5)", "  puts(1_000.5)",
             "  puts(-1_000)", "  puts(1_000.to_s)", "  puts((1_000..1_002).to_a)", "  puts((1_000...1_002).to_a)",
             "  _1 = 5", "  puts(_1)", "  _n = 2", "  puts((0.._n).to_a)", "  1_000.times do |i|", "  end", "end"),
     "1000\n1000000\n1000.0005\n0.55\n1000.5\n-1000\n1000\n[1000, 1001, 1002]\n[1000, 1001]\n5\n[0, 1, 2]\n"),
    ("hex, binary and octal literals in either case, with separators, the Int bounds and a pattern",
     program(MAIN, "  puts(0xFF + 0Xff_ff)", "  puts(0b1010 + 0B1111_0000)", "  puts(0o755 + 0O17)",
             "  puts(0x7FFF_FFFF_FFFF_FFFF)", "  puts(-0x8000_0000_0000_0000)", "  puts(0xFF.to_s)",
             "  case 255", "    0xFF -> puts(\"ff\")", "    _ -> puts(\"other\")", "  end", "end"),
     "65790\n250\n508\n9223372036854775807\n-9223372036854775808\n255\nff\n"),
]


def span_of(problem):
    where = problem["range"]
    return (where["start"]["line"], where["start"]["column"], where["end"]["line"], where["end"]["column"])


def run_all(tmp_path, sources, arguments=()):
    """Run each source through the CLI side by side; return results by case name."""
    directory = tmp_path / "cases"
    directory.mkdir()
    cases = list(sources)
    paths = []
    for index, case in enumerate(cases):
        path = directory / ("case-%d.agc" % index)
        path.write_text(sources[case], encoding="utf-8")
        paths.append(path)
    with ThreadPoolExecutor(WORKERS) as pool:
        results = list(pool.map(lambda path: run(cli() + list(arguments) + [str(path)]), paths))
    return dict(zip(cases, results))


def test_diagnostics_carry_the_code_and_span_of_the_rule(tmp_path):
    sources = {case: source for case, source, *_ in DIAGNOSTICS}
    results = run_all(tmp_path, sources, ["--json", "check"])
    for case, _source, code, where, help_ in DIAGNOSTICS:
        result = results[case]
        assert result.code == 1, f"{case}: {result.stdout}{result.stderr}"
        problem = json.loads(result.stderr.strip().split("\n")[-1])
        assert problem["code"] == code, case
        if where is not None:
            assert span_of(problem)[:len(where)] == where, case
        if help_ is not None:
            assert ("help" in problem) == help_, case


def test_sources_that_check_clean(tmp_path):
    results = run_all(tmp_path, dict(CLEAN), ["--json", "check"])
    for case, _source in CLEAN:
        result = results[case]
        assert (result.code, result.stdout) == (0, '{"ok":true}\n'), case


def test_programs_print_what_the_rule_says(tmp_path):
    sources = {case: source for case, source, _stdout in RUNS}
    results = run_all(tmp_path, sources)
    for case, _source, stdout in RUNS:
        result = results[case]
        assert (result.code, result.stdout) == (0, stdout), f"{case}: {result.stderr}"
