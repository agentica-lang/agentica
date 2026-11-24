"""The narrow integer types (Int8, Int16, Int32, UInt8, UInt16, UInt32) through the product CLI: literals typed by their
context, the range of a literal, the conversions to and from Int, the operators and the reserved names, with their
diagnostic codes and spans.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers. A
program that must check clean has no code.
"""

import json

import pytest

from tests.agentica_test import cli, run
from tests.spec_support import assert_rule, check_many, covered


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


PIXEL = "struct Pixel\n  r: UInt8\nend\n\n"

RULES = {
    "a literal takes the type of an annotation, a field, a parameter, a return, an item and a case": (
        PIXEL
        + "def half(x: Int16) -> Int16 = x\n\ndef top() -> UInt32 = 4294967295\n\n"
        + main("a: UInt8 = 255", "b: Int8 = -128", "c: Int32 = -2147483648", "d: UInt16 = 0xFFFF",
               "puts(half(-32768))", "puts(top())", "puts(Pixel(r: 0).r)", "xs: List[UInt8] = [0, 255]",
               'm: Map[String, Int8] = {"k": 127}', "puts(\"#{a} #{b} #{c} #{d} #{xs} #{m}\")",
               "case a", "  255 -> puts(a.inspect)", "  _ -> puts(a.to_s)", "end"), None, None),
    "a minus folds into the literal": (main("x: UInt8 = -0", "puts(x)"), None, None),
    "Int64 is Int and Float64 is Float": (
        main("a: Int64 = 1", "b: Int = a", "f: Float64 = 1.5", "g: Float = f", "puts(b + 1)", "puts(g)"), None, None),
    "the conversions to and from Int": (
        main("a: UInt8 = 7", "n: Int = a.to_i", "b: Result[UInt8] = n.to_uint8", "c: UInt8 = n.to_uint8!",
             "puts(a == c)", "puts(b.ok?)"), None, None),
    "two values of a narrow type compare with ==": (main("a: UInt8 = 1", "b: UInt8 = 2", "puts(a == b)"), None, None),
    "a literal above the type": (main("x: UInt8 = 256"), "CHECK-INT-RANGE", "256"),
    "a negative literal for an unsigned type": (main("x: UInt8 = -1"), "CHECK-INT-RANGE", "-1"),
    "a literal below a signed type": (main("x: Int8 = -129"), "CHECK-INT-RANGE", "-129"),
    "a literal above a signed type": (main("x: Int8 = 128"), "CHECK-INT-RANGE", "128"),
    "a hex literal above the type": (main("x: UInt8 = 0x100"), "CHECK-INT-RANGE", "0x100"),
    "a literal past the Int range": (main("x: UInt32 = 99999999999999999999"), "CHECK-INT-RANGE",
                                     "99999999999999999999"),
    "the least Int is no Int8": (main("x: Int8 = -9223372036854775808"), "CHECK-INT-RANGE", "-9223372036854775808"),
    "a field out of range": (PIXEL + main("p = Pixel(r: 256)"), "CHECK-INT-RANGE", "256"),
    "an argument out of range": ("def half(x: Int16) -> Int16 = x\n\n" + main("puts(half(32768))"),
                                 "CHECK-INT-RANGE", "32768"),
    "a return out of range": ("def top() -> UInt32 = 4294967296\n\n" + main("puts(top())"), "CHECK-INT-RANGE",
                              "4294967296"),
    "an item out of range": (main("xs: List[UInt8] = [1, 256]"), "CHECK-INT-RANGE", "256"),
    "a case pattern out of range": (main("x: UInt8 = 1", "case x", '  300 -> puts("a")', '  _ -> puts("b")', "end"),
                                    "CHECK-INT-RANGE", "300"),
    "no Int becomes a UInt8": (main("n = 1", "x: UInt8 = n"), "CHECK-TYPE-MISMATCH", "n"),
    "no UInt8 becomes an Int": (main("x: UInt8 = 1", "n: Int = x"), "CHECK-TYPE-MISMATCH", "x"),
    "no float literal becomes a UInt8": (main("x: UInt8 = 1.5"), "CHECK-TYPE-MISMATCH", "1.5"),
    "to_<type> is a Result": (main("n = 5", "x: UInt8 = n.to_uint8"), "CHECK-TYPE-MISMATCH", "n.to_uint8"),
    "a default out of range": ("def f(x: UInt8 = 256) -> UInt8 = x\n\n" + main("puts(f())"), "CHECK-INT-RANGE", "256"),
    "a constant out of range": ("LIMIT: UInt8 = 256\n\n" + main("puts(LIMIT)"), "CHECK-INT-RANGE", "256"),
    "a reassignment out of range": (main("x: UInt8 = 1", "x = 256", "puts(x)"), "CHECK-INT-RANGE", "256"),
    "a nested item out of range": (main("xs: List[Optional[UInt8]] = [some(256)]", "puts(xs)"), "CHECK-INT-RANGE",
                                   "256"),
    "operators on one narrow type, a literal on either side, and compound assignment": (
        main("a: UInt8 = 200", "b: UInt8 = 50", "s: Int8 = -5", "x: UInt8 = 1 + 2", "y: UInt8 = (1 + 2) * b",
             "a += 1", "puts(a + b - 2 * b / 3 % 7)", "puts(a < 255 and 0 <= a and 255 == a or a != b)",
             "puts(a >= b and a > b)", "puts(-s + -(1 + 2))", "puts(\"#{x} #{y}\")"), None, None),
    "a Bool context gives a literal tree Int": (main("x: Bool = 1 < 2", "puts(x)"), None, None),
    "two narrow types in +": (main("a: UInt8 = 1", "b: UInt16 = 2", "puts(a + b)"), "CHECK-TYPE-MISMATCH", "+"),
    "two narrow types in <": (main("a: Int8 = 1", "b: Int16 = 2", "puts(a < b)"), "CHECK-TYPE-MISMATCH", "<"),
    "two narrow types in ==": (main("a: Int8 = 1", "b: UInt8 = 2", "puts(a == b)"), "CHECK-TYPE-MISMATCH", "=="),
    "a narrow type and an Int in %": (main("a: UInt8 = 1", "n = 2", "puts(a % n)"), "CHECK-TYPE-MISMATCH", "%"),
    "a narrow type and an Int variable in +": (
        main("a: UInt8 = 1", "n = 2", "puts(n + a)"), "CHECK-TYPE-MISMATCH", "+"),
    "a narrow type and a Float literal": (main("a: UInt8 = 1", "puts(a + 1.5)"), "CHECK-TYPE-MISMATCH", "+"),
    "a literal above the other side": (main("a: UInt8 = 1", "puts(a + 256)"), "CHECK-INT-RANGE", "256"),
    "a literal above the other side, on the left": (main("a: UInt8 = 1", "puts(300 < a)"), "CHECK-INT-RANGE", "300"),
    "a negative literal against an unsigned side": (main("a: UInt8 = 1", "puts(a == -1)"), "CHECK-INT-RANGE", "-1"),
    "a compound assignment with a literal above the type": (main("a: UInt8 = 1", "a += 300"), "CHECK-INT-RANGE", "300"),
    "a literal tree above the context": (main("x: UInt8 = 200 + 300"), "CHECK-INT-RANGE", "300"),
    "two narrow types in %": (main("a: UInt8 = 1", "b: UInt16 = 2", "puts(a % b)"), "CHECK-TYPE-MISMATCH", "%"),
    "no unary minus on an unsigned value": (main("a: UInt8 = 1", "puts(-a)"), "CHECK-TYPE-MISMATCH", "-"),
    # JSON, keys and the list sums of the narrow types come in later pull requests of #984.
    "no JSON.encode yet": (main("a: UInt8 = 1", "puts(JSON.encode(a))"), "CHECK-NOT-ENCODABLE", "a"),
    "no JSON.decode yet": (PIXEL + main('puts(JSON.decode("{}", Pixel).ok?)'), "CHECK-NOT-DECODABLE", "Pixel"),
    "no map key yet": (main("m: Map[UInt8, Int] = {}", "puts(m)"), "CHECK-MAP-KEY-TYPE", "UInt8"),
    "no set element yet": (main("s: Set[UInt8] = Set.new([])", "puts(s)"), "CHECK-SET-ELEMENT-TYPE", "UInt8"),
    "no sum yet": (main("xs: List[UInt8] = [1]", "puts(xs.sum)"), "CHECK-TYPE-MISMATCH", "xs"),
    "a struct may not take a narrow name": ("struct Int8\n  a: Int\nend\n\n" + main(), "CHECK-REDEFINED-NAME", None),
    "an enum may not take a sized name": ("enum UInt64\n  A\nend\n\n" + main(), "CHECK-REDEFINED-NAME", None),
    "an alias may not take a sized name": ("type Float32 = Int\n\n" + main(), "CHECK-REDEFINED-NAME", "Float32"),
    "Int64 is reserved": ("struct Int64\n  a: Int\nend\n\n" + main(), "CHECK-REDEFINED-NAME", None),
    "a type parameter may not take a narrow name": ("def id[UInt8](x: UInt8) -> UInt8 = x\n\n" + main(),
                                                    "CHECK-REDEFINED-NAME", "UInt8"),
    "an import alias may not take a narrow name": ('import Int16 from "std/json"\n\n' + main(),
                                                   "CHECK-REDEFINED-NAME", None),
}


@pytest.fixture(scope="module")
def batch(tmp_path_factory):
    """The programs of the table, checked by one `check` call."""
    return check_many([rule[0] for rule in RULES.values()], tmp_path_factory.mktemp("sized"))


@pytest.mark.parametrize("name", list(RULES))
def test_sized_rules(batch, name):
    program, code, text = RULES[name]
    assert_rule(batch(program), program, code, text)


BOUNDS = {
    "Int8": (-(1 << 7), (1 << 7) - 1),
    "Int16": (-(1 << 15), (1 << 15) - 1),
    "Int32": (-(1 << 31), (1 << 31) - 1),
    "UInt8": (0, (1 << 8) - 1),
    "UInt16": (0, (1 << 16) - 1),
    "UInt32": (0, (1 << 32) - 1),
}


def halting_cases() -> dict[str, tuple[str, str, str]]:
    """Per type, the operation at its edge that leaves the range: id -> (program, code, operator text)."""
    cases = {}
    for name, (low, high) in BOUNDS.items():
        edges = {"+": (high, "a + 1"), "-": (low, "a - 1"), "*": (high, "a * 2")}
        if low < 0:
            edges["/"] = (low, "a / -1")
            edges["neg"] = (low, "-a")
        for operator, (start, expression) in edges.items():
            shown = "-" if operator == "neg" else operator
            cases[f"{name} {operator}"] = (
                main(f"a: {name} = {start}", f"puts({expression})"), "RUNTIME-INTEGER-OVERFLOW", shown)
        for operator in ("/", "%"):
            cases[f"{name} {operator} 0"] = (
                main(f"a: {name} = 1", f"puts(a {operator} 0)"), "RUNTIME-DIVISION-BY-ZERO", operator)
    return cases


HALTING = halting_cases()


@pytest.mark.parametrize("name", list(HALTING))
def test_sized_halts(tmp_path, name):
    """An operation that leaves the type stops the program at the operator; a zero divisor is not an overflow."""
    program, code, text = HALTING[name]
    path = tmp_path / "program.agc"
    path.write_text(program, encoding="utf-8")
    result = run(cli() + ["--json", str(path)])
    assert result.code == 1, result.stderr
    found = json.loads(result.stderr)
    assert found["code"] == code
    assert covered(program, found["range"]) == text
