"""The narrow integer types (Int8, Int16, Int32, UInt8, UInt16, UInt32) through the product CLI: literals typed by their
context, the range of a literal, the conversions to and from Int, JSON, map keys and set elements, and the reserved
names, with their diagnostic codes and spans.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers. A
program that must check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule, check_many


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


PIXEL = "struct Pixel\n  r: UInt8\nend\n\n"
A_B = ("a: UInt8 = 1", "b: UInt8 = 2")

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
    # Operators and the list sums of the narrow types come in later pull requests of #984.
    "no + yet": (main(*A_B, "puts(a + b)"), "CHECK-TYPE-MISMATCH", "+"),
    "no < yet": (main(*A_B, "puts(a < b)"), "CHECK-TYPE-MISMATCH", "<"),
    "no unary minus yet": (main("a: Int8 = 1", "puts(-a)"), "CHECK-TYPE-MISMATCH", "-"),
    "no += yet": (main("a: UInt8 = 1", "a += 1", "puts(a)"), "CHECK-TYPE-MISMATCH", "+="),
    "no literal on the other side of == yet": (main("a: UInt8 = 1", "puts(a == 255)"), "CHECK-TYPE-MISMATCH", "=="),
    "JSON encodes, decodes and describes a narrow type": (
        PIXEL + main("a: UInt8 = 1", "puts(JSON.encode(a))", 'puts(JSON.decode("{}", Pixel).ok?)',
                     "puts(JSON.schema(Pixel))", "xs: List[Int8] = [-1]", "puts(JSON.from(xs))"), None, None),
    "a narrow type is a map key and a set element": (
        main("m: Map[UInt8, Int] = {255: 1}", "s: Set[Int16] = Set.new([-32768])", "puts(m[255])",
             "puts(s.include?(1))", "xs: List[UInt8] = [1, 1]", "puts(xs.tally)", "puts(xs.uniq)",
             "puts(xs.group_by do |x: UInt8| x end)"), None, None),
    "a map key literal out of range": (main("m: Map[UInt8, Int] = {256: 1}", "puts(m)"), "CHECK-INT-RANGE", "256"),
    "a set element literal out of range": (main("s: Set[Int8] = Set.new([128])", "puts(s)"), "CHECK-INT-RANGE",
                                           "128"),
    "a map with narrow keys is not JSON": (main("m: Map[UInt8, Int] = {}", "puts(JSON.encode(m))"),
                                           "CHECK-NOT-ENCODABLE", "m"),
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
