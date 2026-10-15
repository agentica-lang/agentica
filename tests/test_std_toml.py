"""std/toml: the TOML 1.0 parser and encoder written in Agentica.

Peers, none of them the code under test:
- the files of toml-lang/toml-test for TOML 1.0.0 (tests/fixtures/toml-test, MIT), valid inputs with their
  expected value and invalid inputs that must be rejected;
- Python's tomllib (3.11 or later), which reads our own inputs (tests/fixtures/toml/valid) and the output of the
  Agentica encoder. A missing tomllib skips the test locally and fails it in CI.

tests/fixtures/toml/driver.agc parses the files named on its command line and prints one JSON line per file with the
value in a tagged form: {"t": "int", "v": "12"} (ints as text, floats as their 64 bits as text, date-times as the
text that was written). Each peer's value is converted to the same canonical Python form and compared.
"""
import json
import math
import re
import struct
import tempfile
import unittest
from pathlib import Path

from tests.agentica_test import FIXTURES, TestCase, compile_agc, require, run_vm

try:
    import tomllib
except ImportError:  # Python before 3.11
    tomllib = None

TOML_DIR = FIXTURES / "toml"
TOML_TEST = FIXTURES / "toml-test"
POSITION = re.compile(r"^line \d+, column \d+: \S")


def float_bits(x):
    # The sign of a NaN carries no meaning in TOML, and std/toml reads every NaN as one value.
    if math.isnan(x):
        x = math.nan
    return struct.unpack("<q", struct.pack("<d", x))[0]


DATE_TIME = re.compile(
    r"^(?:(\d{4}-\d\d-\d\d))?(?:[Tt ])?(?:(\d\d:\d\d:\d\d)(?:\.(\d+))?)?(?:([Zz])|([+-])(\d\d):(\d\d))?$")


def date_time(text):
    """Canonical form of a date-time text: kind, date, time, fraction without trailing zeros, offset in minutes."""
    match = DATE_TIME.match(text)
    assert match, text
    date, clock, fraction, zulu, sign, hours, minutes = match.groups()
    offset = None
    if zulu:
        offset = 0
    elif sign:
        offset = (1 if sign == "+" else -1) * (int(hours) * 60 + int(minutes))
    kind = {(True, True, True): "datetime", (True, True, False): "datetime-local", (True, False, False): "date-local",
            (False, True, False): "time-local"}[(date is not None, clock is not None, offset is not None)]
    return ("dt", kind, date, clock, (fraction or "").rstrip("0"), offset)


def from_driver(node):
    kind, value = node["t"], node["v"]
    if kind == "int":
        return ("int", int(value))
    if kind == "float":
        return ("float", int(value))
    if kind == "datetime":
        return date_time(value)
    if kind == "array":
        return ("array", [from_driver(item) for item in value])
    if kind == "table":
        return ("table", {key: from_driver(item) for key, item in value.items()})
    return (kind, value)


def from_tomllib(value):
    import datetime
    if isinstance(value, bool):
        return ("bool", value)
    if isinstance(value, int):
        return ("int", value)
    if isinstance(value, float):
        return ("float", float_bits(value))
    if isinstance(value, str):
        return ("str", value)
    if isinstance(value, datetime.datetime):
        return date_time(value.isoformat())
    if isinstance(value, (datetime.date, datetime.time)):
        return date_time(value.isoformat())
    if isinstance(value, list):
        return ("array", [from_tomllib(item) for item in value])
    return ("table", {key: from_tomllib(item) for key, item in value.items()})


def from_toml_test(node):
    """The expected value of a toml-test file: tables and arrays are plain JSON, a scalar is {"type", "value"}."""
    if isinstance(node, list):
        return ("array", [from_toml_test(item) for item in node])
    if "type" not in node or "value" not in node or set(node) != {"type", "value"}:
        return ("table", {key: from_toml_test(item) for key, item in node.items()})
    kind, value = node["type"], node["value"]
    if kind == "integer":
        return ("int", int(value))
    if kind == "float":
        return ("float", float_bits(float(value)))
    if kind == "bool":
        return ("bool", value == "true")
    if kind == "string":
        return ("str", value)
    result = date_time(value)
    assert result[1] == kind, (kind, value)
    return result


def relative(path):
    return str(Path(path).relative_to(FIXTURES))


class Reports:
    """The driver's lines for a list of files, by path."""

    def __init__(self, case, bytecode, paths):
        self.by_path = {}
        # A few hundred paths per run keep the command line short.
        for start in range(0, len(paths), 300):
            result = run_vm(bytecode, args=[str(p) for p in paths[start:start + 300]])
            case.assertEqual(result.code, 0, result.stderr)
            for line in result.stdout.splitlines():
                report = json.loads(line)
                self.by_path[report["name"]] = report
        case.assertEqual(len(self.by_path), len(paths))

    def of(self, path):
        return self.by_path[str(path)]


class TomlTestCase(TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        work = tempfile.TemporaryDirectory(prefix="agentica-toml-")
        cls.addClassCleanup(work.cleanup)
        cls.work = Path(work.name)
        cls.driver = compile_agc(TOML_DIR / "driver.agc", cls.work / "driver.agcb")

    def reports(self, paths):
        return Reports(self, self.driver, paths)

    def parse_text(self, name, text):
        """The driver's report for a text written to a file (bytes are written as they are)."""
        path = self.work / (name + ".toml")
        path.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
        return self.reports([path]).of(path)


class TomlTestSuite(TomlTestCase):
    """The vendored toml-test files, read without any other parser."""

    def test_valid_inputs_decode_to_the_expected_value(self):
        paths = sorted((TOML_TEST / "valid").rglob("*.toml"))
        self.assertGreater(len(paths), 200)
        reports = self.reports(paths)
        for path in paths:
            report = reports.of(path)
            expected = from_toml_test(json.loads(path.with_suffix(".json").read_text(encoding="utf-8")))
            self.assertTrue(report["ok"], "%s: %s" % (relative(path), report.get("error")))
            self.assertEqual(from_driver(report["tagged"]), expected, relative(path))

    def test_valid_inputs_round_trip_through_the_encoder(self):
        paths = sorted((TOML_TEST / "valid").rglob("*.toml"))
        reports = self.reports(paths)
        for path in paths:
            report = reports.of(path)
            self.assertNotIn("encode_error", report, relative(path))
            self.assertNotIn("reparse_error", report, relative(path))
            self.assertEqual(from_driver(report["again"]), from_driver(report["tagged"]), relative(path))

    def test_invalid_inputs_are_errors_with_a_position(self):
        paths = sorted((TOML_TEST / "invalid").rglob("*.toml"))
        self.assertGreater(len(paths), 400)
        reports = self.reports(paths)
        for path in paths:
            report = reports.of(path)
            self.assertFalse(report["ok"], "%s was accepted" % relative(path))
            # A file that is not UTF-8 never reaches the parser: the file read fails.
            if not report["error"].startswith("line "):
                self.assertRaises(UnicodeDecodeError, path.read_bytes().decode, "utf-8")
            else:
                self.assertRegex(report["error"], POSITION, relative(path))


class TomllibPeer(TomlTestCase):
    """Python's tomllib reads the same inputs and the encoder output."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        require(tomllib is not None, "tomllib needs Python 3.11 or later")

    def own_valid(self):
        return sorted((TOML_DIR / "valid").glob("*.toml"))

    def test_own_inputs_match_tomllib(self):
        paths = self.own_valid()
        self.assertGreaterEqual(len(paths), 10)
        reports = self.reports(paths)
        for path in paths:
            report = reports.of(path)
            self.assertTrue(report["ok"], "%s: %s" % (path.name, report.get("error")))
            expected = from_tomllib(tomllib.loads(path.read_bytes().decode("utf-8")))
            self.assertEqual(from_driver(report["tagged"]), expected, path.name)

    def test_toml_test_inputs_match_tomllib(self):
        paths = sorted((TOML_TEST / "valid").rglob("*.toml"))
        reports = self.reports(paths)
        for path in paths:
            expected = from_tomllib(tomllib.loads(path.read_bytes().decode("utf-8")))
            self.assertEqual(from_driver(reports.of(path)["tagged"]), expected, relative(path))

    def test_encoder_output_is_valid_toml_with_the_same_value(self):
        paths = self.own_valid() + sorted((TOML_TEST / "valid").rglob("*.toml"))
        reports = self.reports(paths)
        for path in paths:
            report = reports.of(path)
            # Our reader and the peer read what the encoder wrote, and agree with the first decode.
            self.assertEqual(from_driver(report["again"]), from_driver(report["tagged"]), relative(path))
            peer = from_tomllib(tomllib.loads(report["encoded"]))
            self.assertEqual(peer, from_driver(report["tagged"]), relative(path))

    def test_encoder_is_stable(self):
        paths = self.own_valid()
        first = self.reports(paths)
        for path in paths:
            report = first.of(path)
            again = self.parse_text("again-" + path.stem, report["encoded"])
            self.assertEqual(again["encoded"], report["encoded"], path.name)

    def test_peer_rejects_what_we_reject(self):
        for name, text in INVALID.items():
            with self.assertRaises(tomllib.TOMLDecodeError, msg=name):
                tomllib.loads(text)


# Inputs that both parsers must reject. The values are written with escapes: no control character in this source.
INVALID = {
    "duplicate-key": "a = 1\na = 2\n",
    "duplicate-key-after-dotted": "a.b = 1\na = 2\n",
    "table-defined-twice": "[a]\n[a]\n",
    "table-then-dotted": "[a]\nb.c = 1\n[a.b]\n",
    "dotted-then-header": "a.b = 1\n[a]\n",
    "extend-inline-table": "a = {b = 1}\n[a.c]\n",
    "extend-inline-table-key": "a = {b = 1}\na.c = 2\n",
    "static-array-then-aot": "a = [{b = 1}]\n[[a]]\n",
    "aot-then-table": "[[a]]\n[a]\n",
    "table-then-aot": "[a]\n[[a]]\n",
    "value-then-table": "a = 1\n[a]\n",
    "key-without-value": "a =\n",
    "key-without-equals": "a 1\n",
    "two-keys-on-a-line": "a = 1 b = 2\n",
    "unterminated-string": "a = \"abc\n",
    "unterminated-multiline": "a = \"\"\"abc\n",
    "bad-escape": "a = \"\\q\"\n",
    "short-unicode-escape": "a = \"\\u12\"\n",
    "surrogate-escape": "a = \"\\ud800\"\n",
    "too-big-escape": "a = \"\\U00110000\"\n",
    "control-in-string": "a = \"x\\x01y\"\n".replace("\\x01", "\x01"),
    "del-in-string": "a = \"x\x7fy\"\n",
    "control-in-comment": "# bad \x00 comment\n",
    "lone-cr": "a = 1\rb = 2\n",
    "leading-zero": "a = 01\n",
    "leading-zero-float": "a = 00.5\n",
    "double-underscore": "a = 1__0\n",
    "trailing-underscore": "a = 10_\n",
    "underscore-after-point": "a = 1._5\n",
    "float-no-digits-after-point": "a = 1.\n",
    "float-no-digits-before-point": "a = .5\n",
    "float-bad-exponent": "a = 1e\n",
    "hex-with-sign": "a = +0x10\n",
    "hex-capital-prefix": "a = 0X10\n",
    "bin-bad-digit": "a = 0b12\n",
    "oct-bad-digit": "a = 0o8\n",
    "empty-hex": "a = 0x\n",
    "plus-inf-typo": "a = infinity\n",
    "bad-bool": "a = True\n",
    "bool-with-tail": "a = truex\n",
    "month-13": "a = 1979-13-01\n",
    "day-30-of-february": "a = 2024-02-30\n",
    "feb-29-not-leap": "a = 2023-02-29\n",
    "hour-24": "a = 07:32:00\nb = 24:00:00\n",
    "offset-without-time": "a = 1979-05-27Z\n",
    "time-with-offset": "a = 07:32:00Z\n",
    "date-with-T-and-nothing": "a = 1979-05-27T\n",
    "array-missing-comma": "a = [1 2]\n",
    "array-double-comma": "a = [1,,2]\n",
    "array-leading-comma": "a = [,1]\n",
    "array-unterminated": "a = [1, 2\n",
    "inline-table-trailing-comma": "a = {b = 1,}\n",
    "inline-table-newline": "a = {b = 1,\nc = 2}\n",
    "inline-table-unterminated": "a = {b = 1\n",
    "inline-table-duplicate": "a = {b = 1, b = 2}\n",
    "inline-table-dotted-clash": "a = {b = 1, b.c = 2}\n",
    "header-unterminated": "[a\n",
    "header-aot-unterminated": "[[a]\n",
    "header-empty": "[]\n",
    "header-empty-part": "[a..b]\n",
    "header-trailing-dot": "[a.]\n",
    "header-then-junk": "[a] b = 1\n",
    "key-empty-part": "a..b = 1\n",
    "key-bare-unicode": "k\u00e9 = 1\n",
    "key-multiline": "\"\"\"a\"\"\" = 1\n",
    "bom": "\ufeffa = 1\n",
    "multiline-too-many-quotes": "a = \"\"\"x\"\"\"\"\"\"\n",
    "line-ending-backslash-with-text": "a = \"\"\"x\\ y\n z\"\"\"\n",
    "single-line-string-with-newline": "a = 'x\ny'\n",
}


class OwnInvalid(TomlTestCase):
    def test_invalid_inputs_are_errors_with_a_position(self):
        paths = []
        for name, text in INVALID.items():
            path = self.work / ("invalid-" + name + ".toml")
            path.write_bytes(text.encode("utf-8"))
            paths.append(path)
        reports = self.reports(paths)
        for path in paths:
            report = reports.of(path)
            self.assertFalse(report["ok"], "%s was accepted" % path.name)
            self.assertRegex(report["error"], POSITION, path.name)

    def test_error_messages_name_line_and_column(self):
        cases = [
            ("a = 1\nb = 2\nc d\n", "line 3, column 3: expected '=' after key"),
            ("a = 1\nb =\n", "line 2, column 4: expected a value"),
            ("a = 1\na = 2\n", "line 2, column 1: key \"a\" is already defined"),
            ("  x = [1, 2\n", "line 2, column 1: expected ',' or ']' in an array"),
            ("s = \"abc\n", "line 1, column 5: unterminated string"),
            ("a = 1 # ok\nb = 1979-02-30\n", "line 2, column 5: invalid date"),
            ("t = \"caf\u00e9\" x\n", "line 1, column 12: expected a line end after the value"),
            ("\u00e9 = 1\n", "line 1, column 1: expected a key"),
            ("a = \"\\q\"\n", "line 1, column 6: invalid escape in a string"),
            ("[a]\nb = 1\n[a]\n", "line 3, column 1: table \"a\" is already defined"),
            ("a = 1\r\nb = ?\r\n", "line 2, column 5: expected a value"),
        ]
        paths = []
        for index, (text, _) in enumerate(cases):
            path = self.work / ("position-%d.toml" % index)
            path.write_bytes(text.encode("utf-8"))
            paths.append(path)
        reports = self.reports(paths)
        for path, (text, message) in zip(paths, cases):
            self.assertEqual(reports.of(path).get("error"), message, text)

    def test_integer_bounds(self):
        text = ("max = 9223372036854775807\nmin = -9223372036854775808\n"
                "hex_max = 0x7FFFFFFFFFFFFFFF\noct_max = 0o777777777777777777777\nbin_max = 0b" + "1" * 63 + "\n")
        report = self.parse_text("bounds", text)
        self.assertTrue(report["ok"], report.get("error"))
        values = {k: v["v"] for k, v in report["tagged"]["v"].items()}
        self.assertEqual(values["max"], "9223372036854775807")
        self.assertEqual(values["min"], "-9223372036854775808")
        self.assertEqual(values["hex_max"], "9223372036854775807")
        self.assertEqual(values["oct_max"], "9223372036854775807")
        self.assertEqual(values["bin_max"], "9223372036854775807")
        for bad in ("9223372036854775808", "-9223372036854775809", "0x8000000000000000", "0xFFFFFFFFFFFFFFFF",
                    "0o1000000000000000000000", "0b1" + "0" * 63, "99999999999999999999999999"):
            report = self.parse_text("overflow", "a = %s\n" % bad)
            self.assertFalse(report["ok"], bad)
            self.assertIn("64-bit", report["error"], bad)

    def test_nesting_limit(self):
        limit = 256
        cases = {
            "arrays-at-limit": ("a = " + "[" * limit + "]" * limit + "\n", True),
            "arrays-over-limit": ("a = " + "[" * (limit + 1) + "]" * (limit + 1) + "\n", False),
            "arrays-far-over": ("a = " + "[" * 100000 + "]" * 100000 + "\n", False),
            "arrays-unclosed": ("a = " + "[" * 100000 + "\n", False),
            "inline-at-limit": ("a = " + "{a=" * limit + "1" + "}" * limit + "\n", True),
            "inline-over-limit": ("a = " + "{a=" * (limit + 1) + "1" + "}" * (limit + 1) + "\n", False),
            "inline-far-over": ("a = " + "{a=" * 100000 + "1" + "}" * 100000 + "\n", False),
            "mixed-over-limit": ("a = " + "[{a=" * 129 + "1" + "}]" * 129 + "\n", False),
            "header-at-limit": ("[" + ".".join(["a"] * limit) + "]\n", True),
            "header-over-limit": ("[" + ".".join(["a"] * (limit + 1)) + "]\n", False),
            "dotted-key-over-limit": (".".join(["a"] * (limit + 1)) + " = 1\n", False),
            "header-far-over": ("[" + ".".join(["a"] * 50000) + "]\n", False),
        }
        paths = {}
        for name, (text, _) in cases.items():
            path = self.work / ("deep-" + name + ".toml")
            path.write_bytes(text.encode("utf-8"))
            paths[name] = path
        reports = self.reports(list(paths.values()))
        for name, (_, accepted) in cases.items():
            report = reports.of(paths[name])
            self.assertEqual(report["ok"], accepted, "%s: %s" % (name, report.get("error")))
            if accepted:
                # The deepest value can still be written and read back.
                self.assertNotIn("encode_error", report, name)
                self.assertEqual(from_driver(report["again"]), from_driver(report["tagged"]), name)
            else:
                self.assertRegex(report["error"], POSITION, name)
                self.assertTrue("nest more than 256" in report["error"] or "more than 256 parts" in report["error"], name)


class Misc(TestCase):
    """Programs that use the module as a caller would: encoder rules, to_json into structs, get."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        work = tempfile.TemporaryDirectory(prefix="agentica-toml-")
        cls.addClassCleanup(work.cleanup)
        cls.bytecode = compile_agc(TOML_DIR / "misc.agc", Path(work.name) / "misc.agcb")

    def lines(self, case):
        result = run_vm(self.bytecode, args=[case])
        self.assertEqual(result.code, 0, result.stderr)
        return result.stdout.rstrip("\n").split("\n")

    def test_encoder_puts_plain_entries_before_tables_and_arrays_of_tables(self):
        # The Map inserts the table and the array of tables before the scalars.
        text = "\n".join(self.lines("order")).replace("<NL>", "\n")
        self.assertEqual(text, (
            "title = \"x\"\nflag = true\n\n[sub]\nz = 1\n\n[[rows]]\nn = 1\n\n[[rows]]\nn = 2\n"))
        self.assertEqual(tomllib_loads(text), {"title": "x", "flag": True, "sub": {"z": 1}, "rows": [{"n": 1}, {"n": 2}]})

    def test_encoder_quotes_keys_and_strings_and_writes_special_floats(self):
        out = self.lines("quoting")
        text = out[0].replace("<NL>", "\n")
        self.assertEqual(out[1], "same")
        self.assertIn("\"a b\" = 1\n", text)
        self.assertIn("\"\" = 2\n", text)
        self.assertIn("\"dot.key\" = 3\n", text)
        self.assertIn("plain-key_1 = 4\n", text)
        self.assertIn("inf = inf\n", text)
        self.assertIn("neg = -inf\n", text)
        self.assertIn("nothing = nan\n", text)
        self.assertIn("\"[quoted.tbl]\"", text)
        loaded = tomllib_loads(text)
        self.assertEqual(loaded["a b"], 1)
        self.assertEqual(loaded["s"], "tab\there \"q\" back\\slash \x01 \x7f nl\n \u00e9 \U0001F600")
        self.assertEqual(loaded["inf"], math.inf)
        self.assertTrue(math.isnan(loaded["nothing"]))

    def test_encoder_errors(self):
        self.assertEqual(self.lines("encode_errors"), [
            "root: the root of a TOML document must be a table",
            "datetime: not a valid TOML date-time: \"yesterday\"",
            "nested datetime: not a valid TOML date-time: \"1979-02-30\"",
            "ok datetime: ok",
        ])

    def test_to_json_decodes_into_structs(self):
        self.assertEqual(self.lines("to_json"), [
            "name=demo",
            "port=8080",
            "ratio=0.5",
            "debug=true",
            "tags=a,b",
            "since=1979-05-27T07:32:00Z",
            "limits.cpu=4",
            "float as int: error",
            "inf: cannot convert inf to JSON",
            "nan inside: cannot convert nan to JSON",
        ])

    def test_to_json_keeps_floats_and_integers_apart(self):
        text = self.lines("json_kinds")[0]
        self.assertEqual(json.loads(text), {"f": 1.0, "i": 1, "e": 1e20, "z": -0.0})
        self.assertIn("\"f\":1.0", text)
        self.assertIn("\"i\":1", text)
        self.assertNotIn("\"i\":1.", text)

    def test_get(self):
        self.assertEqual(self.lines("get"), [
            "package.name: str demo",
            "bin.1.path: str b",
            "package: table 2",
            "missing: no key \"nope\" in \"package.nope\"",
            "bad index: no index \"7\" in \"bin.7\"",
            "into scalar: \"x\" in \"package.name.x\" is not inside a table or an array",
        ])

    def test_encode_then_parse_is_the_identity_for_built_values(self):
        self.assertEqual(self.lines("round_trip"), ["same"])


def tomllib_loads(text):
    require(tomllib is not None, "tomllib needs Python 3.11 or later")
    return tomllib.loads(text)


if __name__ == "__main__":
    unittest.main()
