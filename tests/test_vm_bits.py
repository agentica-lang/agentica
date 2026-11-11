"""Spans of the diagnostics of the bit and number builtins.

Each fixture of tests/fixtures/vm/ halts with a runtime diagnostic, and its golden holds the code; the test checks the
code and that the range covers the bad argument: the count of a shift, the exponent of pow, the argument of Math.sqrt,
the whole call of clamp (as for Random.int).
"""
import json

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

# (fixture, code, start, end): the positions are (line, column).
SPANS = [
    ("int-shift-negative", "RUNTIME-INVALID-COUNT", (4, 21), (4, 26)),
    ("int-shift-right-negative", "RUNTIME-INVALID-COUNT", (3, 27), (3, 29)),
    ("int-shift-right-unsigned-negative", "RUNTIME-INVALID-COUNT", (3, 36), (3, 60)),
    ("float-from-bits32-negative", "RUNTIME-INVALID-NUMBER", (3, 26), (3, 28)),
    ("float-from-bits32-range", "RUNTIME-INVALID-NUMBER", (3, 26), (3, 36)),
    ("int-pow-negative", "RUNTIME-INVALID-COUNT", (3, 14), (3, 19)),
    ("math-sqrt-negative", "RUNTIME-INVALID-NUMBER", (3, 18), (3, 28)),
    ("int-clamp-range", "RUNTIME-INVALID-RANGE", (3, 8), (3, 21)),
]


@pytest.mark.parametrize("name, code, start, end", SPANS, ids=[row[0] for row in SPANS])
def test_the_diagnostic_points_at_the_bad_argument(tmp_path, name, code, start, end):
    bytecode = compile_agc(FIXTURES / "vm" / f"{name}.agc", tmp_path / f"{name}.agcb")
    result = run_vm(bytecode, "--json")
    assert result.code == 1
    # The diagnostic is the last line of stderr; the program may print before it.
    diagnostic = json.loads(result.stderr.strip().split("\n")[-1])
    assert diagnostic["code"] == code
    span = diagnostic["range"]
    assert (span["start"]["line"], span["start"]["column"]) == start
    assert (span["end"]["line"], span["end"]["column"]) == end
