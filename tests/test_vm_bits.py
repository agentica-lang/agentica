"""Spans of the diagnostics of the bit builtins.

Each fixture of tests/fixtures/vm/ halts with a runtime diagnostic; the test
checks the code and that the range covers the bad argument.
"""
import json

from tests.agentica_test import FIXTURES, compile_agc, run_vm


def check_span(name, code, start, end, tmp_path):
    """Assert the diagnostic code and its start and end positions."""
    bytecode = compile_agc(
        FIXTURES / "vm" / f"{name}.agc",
        tmp_path / f"{name}.agcb",
    )
    result = run_vm(bytecode, "--json")
    assert result.code == 1, name
    # The diagnostic is the last line of stderr; the program may print before it.
    diagnostic = json.loads(result.stderr.strip().split("\n")[-1])
    assert diagnostic["code"] == code
    span = diagnostic["range"]
    assert (span["start"]["line"], span["start"]["column"]) == start, name
    assert (span["end"]["line"], span["end"]["column"]) == end, name


def test_int_shift_negative(tmp_path):
    check_span("int-shift-negative", "RUNTIME-INVALID-COUNT", (4, 21), (4, 26), tmp_path)


def test_int_shift_right_negative(tmp_path):
    check_span("int-shift-right-negative", "RUNTIME-INVALID-COUNT", (3, 27), (3, 29), tmp_path)


def test_int_shift_right_unsigned_negative(tmp_path):
    check_span("int-shift-right-unsigned-negative", "RUNTIME-INVALID-COUNT", (3, 36), (3, 60), tmp_path)


def test_float_from_bits32_negative(tmp_path):
    check_span("float-from-bits32-negative", "RUNTIME-INVALID-NUMBER", (3, 26), (3, 28), tmp_path)


def test_float_from_bits32_range(tmp_path):
    check_span("float-from-bits32-range", "RUNTIME-INVALID-NUMBER", (3, 26), (3, 36), tmp_path)
