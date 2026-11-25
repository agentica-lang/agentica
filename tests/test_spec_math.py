"""Math.exp, log, log10, sin and cos through the product CLI: the results against Python's math module as the peer,
and the domain error of log and log10 below zero at the argument.

A Float travels as its 64-bit pattern, so each result is compared bit for bit. Both sides call the C library, but the
VM and Python may link different ones, so a finite result may be one unit in the last place away; zeros, infinities
and NaN compare exactly. Where Python raises and Ruby gives a value (log of zero, an exp that overflows, sin and cos
of an infinity), the expected value is Ruby's.
"""

import json
import math
import struct

import pytest

from tests.agentica_test import cli, run
from tests.spec_support import covered

MAIN = "def main() -> Void\n"
FUNCTIONS = {"exp": math.exp, "log": math.log, "log10": math.log10, "sin": math.sin, "cos": math.cos}
INPUTS = [
    0.0,
    -0.0,
    0.1,
    0.5,
    1.0,
    -1.0,
    2.0,
    -2.5,
    10.0,
    100.0,
    1000.0,
    math.pi,
    -math.pi,
    math.pi / 2,
    1e-300,
    5e-324,
    1e22,
    1e300,
    -1e300,
    709.78,
    710.0,
    -745.1,
    -746.0,
    math.inf,
    -math.inf,
    math.nan,
]


def bits(x: float) -> int:
    return struct.unpack(">Q", struct.pack(">d", x))[0]


def ruby(name: str, x: float) -> float | None:
    """Ruby's result, or None for Math::DomainError (an argument below zero)."""
    if name in ("log", "log10"):
        if x < 0:
            return None
        if x == 0:
            return -math.inf
    if name == "exp" and x > 709.79:
        return math.inf
    if name in ("sin", "cos") and math.isinf(x):
        return math.nan
    return FUNCTIONS[name](x)


def same(got: int, want: float) -> bool:
    if math.isnan(want):
        return math.isnan(struct.unpack(">d", struct.pack(">Q", got))[0])
    if want == 0 or math.isinf(want):
        return got == bits(want)
    return (got >> 63) == (bits(want) >> 63) and abs(got - bits(want)) <= 1


def test_math_functions_match_python(tmp_path):
    cases = [(name, x) for name in FUNCTIONS for x in INPUTS if ruby(name, x) is not None]
    lines = [f"  puts(Math.{name}(Float.from_bits({bits(x)})).to_bits)" for name, x in cases]
    path = tmp_path / "math.agc"
    path.write_text(MAIN + "\n".join(lines) + "\nend\n", encoding="utf-8")
    result = run(cli() + [str(path)])
    assert result.code == 0, result.stderr
    found = [int(line) for line in result.stdout.splitlines()]
    assert len(found) == len(cases) > 100
    wrong = [(name, x, got) for (name, x), got in zip(cases, found) if not same(got, ruby(name, x))]
    assert wrong == []


@pytest.mark.parametrize("name", ["log", "log10"])
@pytest.mark.parametrize(
    "argument", ["0.0 - 2.0", "Float.from_bits(18442240474082181120)", "Float.from_bits(9223372036854775809)"]
)
def test_math_log_below_zero_is_a_domain_error(tmp_path, name, argument):
    # The patterns are -inf and the negative Float nearest zero, -5e-324.
    source = MAIN + f"  puts(Math.{name}({argument}))\nend\n"
    path = tmp_path / "domain.agc"
    path.write_text(source, encoding="utf-8")
    result = run(cli() + ["--json", str(path)])
    assert result.code == 1
    found = json.loads(result.stderr)
    assert found["code"] == "RUNTIME-INVALID-NUMBER"
    assert covered(source, found["range"]) == argument
