"""Float32 through the product CLI: float literals typed by their context, CHECK-FLOAT-RANGE for a literal that rounds
to an infinity (in Float too), the operators on one type, the conversions, JSON, case patterns, and the refusals,
with their diagnostic codes and spans. tests/fixtures/vm/float32-*.agc hold the values, against a Python peer.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers. A
program that must check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule, check_many, covered, halted
from tests.spec_support import main_of as main


SAMPLE = "struct Sample\n  x: Float32 = 0.5\nend\n\n"

RULES = {
    "a float literal takes Float32 from an annotation, a field, a parameter, a return, an item and a case": (
        "LIMIT: Float32 = -1.5\n\n" + SAMPLE
        + "def half(x: Float32) -> Float32 = x * 0.5\n\ndef top() -> Float32 = 3.4028235e38\n\n"
        + main("a: Float32 = 0.1", "puts(half(1.5))", "puts(top())", "puts(Sample(x: 2.5).x)", "puts(Sample().x)",
               "xs: List[Float32] = [0.5, -0.25]", "puts(\"#{a} #{xs} #{LIMIT}\")",
               "case a", "  0.1 -> puts(a.inspect)", "  _ -> puts(a.to_s)", "end"), None, None),
    "operators on Float32, a literal on either side": (
        main("a: Float32 = 1.5", "b: Float32 = 2.0 * a", "c: Float32 = 1.5 + 2.5", "a += 0.5",
             "puts(a + b - 2.0 * b / 3.0)", "puts(a < 2.0 and 0.5 <= a and 2.0 == a or a != b)",
             "puts(-a + -(1.5 * 2.0))", "puts(c)"), None, None),
    "the conversions": (
        main("f: Float32 = 1.5", "x: Float = f.to_f", "g: Float32 = x.to_float32", "n = 3", "h: Float32 = n.to_float32",
             "u: UInt8 = 7", "k: Float32 = u.to_float32", "bits: UInt32 = f.to_bits",
             "puts(Float32.from_bits(bits) == g)", "puts(h + k)"), None, None),
    "JSON encodes, decodes and describes Float32": (
        SAMPLE + main("puts(JSON.encode(Sample(x: 0.1)))", 'puts(JSON.decode("{\\"x\\": 0.1}", Sample))',
                      "puts(JSON.schema(Sample))", "xs: List[Float32] = [0.1]", "puts(JSON.from(xs))"), None, None),
    "a Float literal past the largest Float": (main("x = 1e309"), "CHECK-FLOAT-RANGE", "1e309"),
    "a Float literal at the largest Float": (main("x = 1.7976931348623157e308", "puts(x)"), None, None),
    "a Float32 literal past the largest Float32": (main("x: Float32 = 3.5e38"), "CHECK-FLOAT-RANGE", "3.5e38"),
    "a Float32 literal at the halfway point rounds to an infinity": (
        main("x: Float32 = 340282356779733661637539395458142568448.0"), "CHECK-FLOAT-RANGE",
        "340282356779733661637539395458142568448.0"),
    "a Float32 literal just under the halfway point is the largest Float32": (
        main("x: Float32 = 340282356779733661637539395458142568447.9", "puts(x)"), None, None),
    "a negative Float32 literal past the largest": (main("x: Float32 = -1e39"), "CHECK-FLOAT-RANGE", "1e39"),
    "a Float32 argument past the largest": ("def f(x: Float32) -> Float32 = x\n\n" + main("puts(f(1e39))"),
                                            "CHECK-FLOAT-RANGE", "1e39"),
    "a Float32 field default past the largest": ("struct S\n  x: Float32 = 1e39\nend\n\n" + main(),
                                                 "CHECK-FLOAT-RANGE", "1e39"),
    "a Float32 case pattern past the largest": (
        main("x: Float32 = 1.0", "case x", '  1e39 -> puts("a")', '  _ -> puts("b")', "end"), "CHECK-FLOAT-RANGE",
        "1e39"),
    "a Float case pattern past the largest": (
        main("x = 1.0", "case x", '  1e309 -> puts("a")', '  _ -> puts("b")', "end"), "CHECK-FLOAT-RANGE", "1e309"),
    "a tiny Float32 literal rounds to zero": (main("x: Float32 = 1e-50", "puts(x)"), None, None),
    "no integer literal becomes a Float32": (main("x: Float32 = 1"), "CHECK-TYPE-MISMATCH", "1"),
    "no Float becomes a Float32": (main("f = 1.5", "x: Float32 = f"), "CHECK-TYPE-MISMATCH", "f"),
    "no Float32 becomes a Float": (main("x: Float32 = 1.5", "f: Float = x"), "CHECK-TYPE-MISMATCH", "x"),
    "a Float32 and a Float in +": (main("a: Float32 = 1.5", "b = 2.5", "puts(a + b)"), "CHECK-TYPE-MISMATCH", "+"),
    "a Float32 and a Float in ==": (main("a: Float32 = 1.5", "b = 2.5", "puts(a == b)"), "CHECK-TYPE-MISMATCH",
                                    "=="),
    "a Float32 and an integer literal": (main("a: Float32 = 1.5", "puts(a + 1)"), "CHECK-TYPE-MISMATCH", "+"),
    "no % on Float32": (main("a: Float32 = 1.5", "puts(a % a)"), "CHECK-TYPE-MISMATCH", "%"),
    "a Float32 is no map key": (main("m: Map[Float32, Int] = {}", "puts(m)"), "CHECK-MAP-KEY-TYPE", "Float32"),
}


@pytest.fixture(scope="module")
def batch(tmp_path_factory):
    """The programs of the table, checked by one `check` call."""
    return check_many([rule[0] for rule in RULES.values()], tmp_path_factory.mktemp("float32"))


@pytest.mark.parametrize("name", list(RULES))
def test_float32_rules(batch, name):
    program, code, text = RULES[name]
    assert_rule(batch(program), program, code, text)


def test_float32_divided_by_zero_halts_at_the_operator(tmp_path):
    program = main("a: Float32 = 1.5", "b: Float32 = 0.0", "puts(a / b)")
    found = halted(program, tmp_path)
    assert found["code"] == "RUNTIME-DIVISION-BY-ZERO"
    assert covered(program, found["range"]) == "/"
