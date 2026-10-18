"""Reading a source file: strict UTF-8 and no size limit (docs/future/18-front-end-language.md §18.3).

The front end decodes the bytes itself, so an invalid byte is LEX-INVALID-UTF8 at the first byte of the first
sequence that does not decode, not a U+FFFD in the text. Python's strict decoder is the independent oracle of that
place.
"""
import json

from tests.agentica_test import TestCase, cli, run

PROGRAM = "def main() -> Void\n  puts(\"ok\")\nend\n"

# (name, valid text before the bad bytes, bad bytes, what follows)
INVALID = [
    ("continuation byte alone", "# café\ndef main() -> Void\n  puts(\"日", b"\x80", b"\")\nend\n"),
    # CR and tab are one column each; only LF starts a line.
    ("CRLF and tab before the bad byte", "# a\r\n\tx = \"\t", b"\xff", b"\"\r\n"),
    ("byte that never occurs", "# \U0001F600\n", b"\xff", b"\n"),
    ("overlong", "x = \"", b"\xc0\x80", b"\"\n"),
    ("overlong three bytes", "x = \"", b"\xe0\x80\x80", b"\"\n"),
    ("surrogate", "x = \"", b"\xed\xa0\x80", b"\"\n"),
    ("above U+10FFFF", "x = \"", b"\xf4\x90\x80\x80", b"\"\n"),
    ("sequence cut by an ASCII byte", "x = \"", b"\xe2\x82", b"a\"\n"),
    ("truncated at the end of the file", PROGRAM, b"\xf0\x9f\x98", b""),
]


class SourceUtf8Test(TestCase):
    def check_file(self, path):
        """Run the product CLI's check on a file; return the diagnostic as a dict (None when it passes)."""
        result = run(cli() + ["--json", "check", path])
        if result.code == 0:
            return None
        self.assertEqual(result.code, 1, result.stderr)
        return json.loads(result.stderr)

    def test_invalid_byte_is_reported_where_python_stops(self):
        directory = self.make_temp_dir()
        for name, prefix, bad, suffix in INVALID:
            with self.subTest(name):
                content = prefix.encode("utf-8") + bad + suffix
                with self.assertRaises(UnicodeDecodeError) as raised:
                    content.decode("utf-8")
                before = content[:raised.exception.start].decode("utf-8")
                self.assertEqual(before, prefix)
                lines = before.split("\n")
                line, column = len(lines), len(lines[-1]) + 1
                path = directory / "bad.agc"
                path.write_bytes(content)
                problem = self.check_file(str(path))
                self.assertEqual(problem["code"], "LEX-INVALID-UTF8")
                self.assertEqual(problem["file"], str(path))
                self.assertEqual(problem["range"], {"start": {"line": line, "column": column},
                                                    "end": {"line": line, "column": column + 1}})

    def test_invalid_byte_in_an_import_names_the_imported_file(self):
        directory = self.make_suite({"root.agc": "import Bad from \"./bad\"\n\n" + PROGRAM})
        (directory / "bad.agc").write_bytes(b"export def one() -> Int\n  return \xff\nend\n")
        problem = self.check_file(str(directory / "root.agc"))
        self.assertEqual(problem["code"], "LEX-INVALID-UTF8")
        self.assertEqual(problem["file"], str(directory / "bad.agc"))
        self.assertEqual(problem["range"]["start"], {"line": 2, "column": 10})

    def test_source_files_over_1_mib_are_read(self):
        comment = "# " + "a" * 1100000 + "\n"
        directory = self.make_suite({
            "root.agc": "import Big from \"./big\"\n\ndef main() -> Void\n  puts(Big.one().to_s)\nend\n",
            "big.agc": comment + "export def one() -> Int\n  return 1\nend\n",
            "alone.agc": comment + PROGRAM,
        })
        for name in ("root.agc", "alone.agc"):
            with self.subTest(name):
                self.assertIsNone(self.check_file(str(directory / name)))

    def test_read_errors_keep_their_codes(self):
        directory = self.make_suite({"root.agc": "import Gone from \"./gone\"\nimport Folder from \"./dir\"\n\n" + PROGRAM})
        missing = run(cli() + ["check", str(directory / "missing.agc")])
        self.assertEqual(missing.code, 2)
        self.assertIn("cannot read", missing.stderr)
        problem = self.check_file(str(directory / "root.agc"))
        self.assertEqual((problem["code"], problem["message"]), ("CHECK-IMPORT-IO", "cannot read import"))
        self.assertEqual(problem["range"]["start"], {"line": 1, "column": 1})
        (directory / "gone.agc").write_text("export def one() -> Int\n  return 1\nend\n")
        (directory / "dir.agc").mkdir()
        problem = self.check_file(str(directory / "root.agc"))
        self.assertEqual((problem["code"], problem["message"]), ("CHECK-IMPORT-IO", "cannot read import"))
        self.assertEqual(problem["range"]["start"], {"line": 2, "column": 1})
