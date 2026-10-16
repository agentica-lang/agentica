"""How `check` prints a diagnostic as text: the header, the source line, the caret run, the labels and the help line.

These are the cases of the old diagnostic test that a program can reach through the product CLI. Each program
is written to a file and checked from its folder, so the header names the file as typed. The message, the text of a
label and the help text are not asserted (AGENTS.md): the test checks that they are there, and where the marks stand.
"""
import re
import unittest

from tests.agentica_test import TestCase, cli, run

# Label texts are words on a line of their own after the marks; they are replaced by a placeholder at the same column.
LABEL_TEXT = re.compile(r"^(  \|\s+)[A-Za-z].*$")

CASES = {
    "one mark under the span": (
        'def main() -> Void\n  age: Int = "25"\nend\n',
        "CHECK-TYPE-MISMATCH", (2, 14),
        ['2 |   age: Int = "25"', "  |              ^^^^"], True),
    "labels run under their line, the later one first": (
        "def f(a: Int, b: Float) -> Float\n  return a * b\nend\n\ndef main() -> Void\nend\n",
        "CHECK-TYPE-MISMATCH", (2, 12),
        ["2 |   return a * b", "  |          - ^ -", "  |              <label>", "  |          <label>"], True),
    "a label on an earlier line comes with its own source line": (
        'def main() -> Void\n  x = [1, 2,\n    3] + "s"\nend\n',
        "CHECK-TYPE-MISMATCH", (3, 8),
        ["2 |   x = [1, 2,", "  |       ------", "  |       <label>", '3 |     3] + "s"', "  |        ^ ---",
         "  |          <label>"], False),
    "a CRLF line ends before the CR": (
        'def main() -> Void\r\n  x: Int = "a"\r\n  puts(x)\r\nend\r\n',
        "CHECK-TYPE-MISMATCH", (2, 12),
        ['2 |   x: Int = "a"', "  |            ^^^"], True),
    "a tab stays a tab in the line and under the marks": (
        'def main() -> Void\n\tx: Int = "a"\nend\n',
        "CHECK-TYPE-MISMATCH", (2, 11),
        ['2 | \tx: Int = "a"', "  | \t         ^^^"], True),
    "a span that ends on a later line keeps the marks on its first line": (
        "def main() -> Void\n  x = [1,\n",
        "LEX-UNCLOSED-DELIMITER", (2, 7),
        ["2 |   x = [1,", "  |       ^^^"], False),
}


class SpecDiagnosticTest(TestCase):
    def render(self, text):
        path = self.make_temp_dir() / "t.agc"
        path.write_bytes(text.encode("utf-8"))
        result = run(cli() + ["check", "t.agc"], cwd=path.parent)
        self.assertEqual(result.code, 1, result.stderr)
        return result.stderr

    def test_the_text_form_of_a_diagnostic(self):
        for title, (text, code, start, shown, has_help) in CASES.items():
            with self.subTest(title):
                lines = self.render(text).rstrip("\n").split("\n")
                self.assertNotIn("\r", "".join(lines))
                self.assertEqual(lines[0], "t.agc:%d:%d error[%s]" % (start + (code,)))
                # The message line, then a blank line, then the source and the marks.
                self.assertTrue(lines[1], lines)
                self.assertEqual(lines[2], "")
                tail = lines[3:]
                helped = bool(tail) and tail[-1].startswith("  = help: ")
                self.assertEqual(helped, has_help)
                if helped:
                    tail = tail[:-1]
                self.assertEqual([LABEL_TEXT.sub(lambda m: m.group(1) + "<label>", line) for line in tail], shown)


if __name__ == "__main__":
    unittest.main()
