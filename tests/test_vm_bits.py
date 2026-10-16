"""Spans of the diagnostics of the bit builtins.

Each fixture of tests/fixtures/vm/ halts with a runtime diagnostic; the test
checks the code and that the range covers the bad argument.
"""
import json

from tests.agentica_test import FIXTURES, TestCase, compile_agc, run_vm


class BitBuiltinSpans(TestCase):
    def check_span(self, name, code, start, end):
        """start and end are (line, column) pairs."""
        work = self.make_temp_dir("agentica-bits-")
        bytecode = compile_agc(FIXTURES / "vm" / (name + ".agc"), work / (name + ".agcb"))
        result = run_vm(bytecode, "--json")
        self.assertEqual(result.code, 1, name)
        # The diagnostic is the last line of stderr; the program may print before it.
        diagnostic = json.loads(result.stderr.strip().split("\n")[-1])
        self.assertEqual(diagnostic["code"], code)
        span = diagnostic["range"]
        self.assertEqual((span["start"]["line"], span["start"]["column"]), start, name)
        self.assertEqual((span["end"]["line"], span["end"]["column"]), end, name)

    def test_int_shift_negative(self):
        self.check_span("int-shift-negative", "RUNTIME-INVALID-COUNT", (4, 21), (4, 26))

    def test_int_shift_right_negative(self):
        self.check_span("int-shift-right-negative", "RUNTIME-INVALID-COUNT", (3, 27), (3, 29))

    def test_int_shift_right_unsigned_negative(self):
        self.check_span("int-shift-right-unsigned-negative", "RUNTIME-INVALID-COUNT", (3, 36), (3, 60))

    def test_float_from_bits32_negative(self):
        self.check_span("float-from-bits32-negative", "RUNTIME-INVALID-NUMBER", (3, 26), (3, 28))

    def test_float_from_bits32_range(self):
        self.check_span("float-from-bits32-range", "RUNTIME-INVALID-NUMBER", (3, 26), (3, 36))
