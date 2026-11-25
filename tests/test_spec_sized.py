"""The sized integer types (Int8 to UInt64) through the product CLI: literals typed by their
context, the range of a literal, the conversions to and from Int, the operators, JSON, map keys and set elements, and
the reserved names, with their diagnostic codes and spans.

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
    "the bit patterns of a Float are a UInt64": (
        main("bits: UInt64 = Float.to_bits(-0.0)", "x: Float = Float.from_bits(bits)", "puts(x)"), None, None),
    "Float.from_bits takes no Int": (
        main("n = 1", "puts(Float.from_bits(n))"), "CHECK-TYPE-MISMATCH", "n"),
    "a negative literal is no bit pattern": (main("puts(Float.from_bits(-1))"), "CHECK-INT-RANGE", "-1"),
    "unwrap_or types an integer literal default by the Result": (
        main("n: Result[UInt8] = 300.to_uint8", "a: UInt8 = n.unwrap_or(0)", "b: UInt8 = Result.unwrap_or(n, 7)",
             "puts(a + b)"), None, None),
    "unwrap_or of an error call and a literal, and of an ok call under an expected type": (
        main("a = Result.unwrap_or(error(\"bad\"), 7)", "b: UInt8 = Result.unwrap_or(ok(1), 0)", "puts(a + b.to_i)"),
        None, None),
    "a float literal default must fit the Float32 of the Result": (
        main("n: Result[Float32] = ok(1.5)", "puts(n.unwrap_or(1e40))"), "CHECK-FLOAT-RANGE", "1e40"),
    "an integer literal default must fit the Result's type": (
        main("n: Result[UInt8] = 3.to_uint8", "puts(n.unwrap_or(256))"), "CHECK-INT-RANGE", "256"),
    "a Float32 and a sized integer do not mix": (
        main("u: UInt64 = 1", "f: Float32 = 1.5", "puts(u + f)"), "CHECK-TYPE-MISMATCH", None),
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
    "the bit, wrapping and widening methods": (
        main("a: UInt8 = 200", "b: Int8 = -100", "n = 300", "c: UInt16 = a.to_uint16", "d: Int32 = b.to_int32",
             "e: UInt8 = n.wrap_uint8", "f: Int8 = n.wrap_int8",
             "g: UInt8 = a.bit_not.bit_and(15).bit_or(1).bit_xor(a)",
             "h: Int8 = b.shift_left(1).shift_right(1).shift_right_unsigned(1)", "i: UInt8 = a.wrapping_add(100)",
             "j: Int8 = b.wrapping_sub(100).wrapping_mul(3)", "k: Int = n.wrapping_add(1)", "l: Float = a.to_f",
             "puts(\"#{c} #{d} #{e} #{f} #{g} #{h} #{i} #{j} #{k} #{l}\")"), None, None),
    "a bit method takes its own type": (main("a: UInt8 = 1", "b: UInt16 = 2", "puts(a.bit_and(b))"),
                                        "CHECK-TYPE-MISMATCH", "b"),
    "a literal argument of a bit method is typed by the method": (main("a: UInt8 = 1", "puts(a.bit_or(256))"),
                                                                  "CHECK-INT-RANGE", "256"),
    "no widening that can lose a value": (main("a: UInt8 = 1", "puts(a.to_int8)"), "CHECK-UNKNOWN-METHOD", "a.to_int8"),
    "no widening to the same type": (main("a: UInt8 = 1", "puts(a.to_uint8)"), "CHECK-UNKNOWN-METHOD", "a.to_uint8"),
    "no signed widening to an unsigned type": (main("a: Int8 = 1", "puts(a.to_uint32)"), "CHECK-UNKNOWN-METHOD",
                                               "a.to_uint32"),
    "wrap_<type> is on Int only": (main("a: UInt16 = 1", "puts(a.wrap_uint8)"), "CHECK-UNKNOWN-METHOD", "a.wrap_uint8"),
    "wrap_<type> gives the type, not a Result": (main("n = 1", "x: Result[UInt8] = n.wrap_uint8"),
                                                 "CHECK-TYPE-MISMATCH", "n.wrap_uint8"),
    "no unary minus on an unsigned value": (main("a: UInt8 = 1", "puts(-a)"), "CHECK-TYPE-MISMATCH", "-"),
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
    "a map with narrow keys is no decode target": (main('puts(JSON.decode("{}", Map[UInt8, Int]))'),
                                                   "CHECK-NOT-DECODABLE", "Map[UInt8, Int]"),
    "UInt64 takes literals up to its greatest value, in a hex form too, and is a case value": (
        PIXEL + main("a: UInt64 = 18446744073709551615", "b: UInt64 = 0xFFFFFFFFFFFFFFFF", "c: UInt64 = -0",
                     "xs: List[UInt64] = [0, 9223372036854775808]", "puts(xs)", "case a", "  18446744073709551615 -> puts(a)",
                     "  _ -> puts(b)", "end", "puts(a == b and c < a)"), None, None),
    "a long hex literal above UInt64": (main("x: UInt64 = 0x100000000000000000"), "CHECK-INT-RANGE",
                                        "0x100000000000000000"),
    "a long hex case pattern above UInt64": (main("x: UInt64 = 1", "case x", '  0x100000000000000000 -> puts("a")',
                                                  '  _ -> puts("b")', "end"), "CHECK-INT-RANGE",
                                             "0x100000000000000000"),
    "a literal above UInt64": (main("x: UInt64 = 18446744073709551616"), "CHECK-INT-RANGE", "18446744073709551616"),
    "a negative literal for UInt64": (main("x: UInt64 = -1"), "CHECK-INT-RANGE", "-1"),
    "a case pattern above UInt64": (main("x: UInt64 = 1", "case x", '  18446744073709551616 -> puts("a")',
                                         '  _ -> puts("b")', "end"), "CHECK-INT-RANGE", "18446744073709551616"),
    "no Int becomes a UInt64": (main("n = 1", "x: UInt64 = n"), "CHECK-TYPE-MISMATCH", "n"),
    "UInt64 and an Int variable in +": (main("a: UInt64 = 1", "n = 2", "puts(a + n)"), "CHECK-TYPE-MISMATCH", "+"),
    "UInt64 and UInt32 in <": (main("a: UInt64 = 1", "b: UInt32 = 2", "puts(a < b)"), "CHECK-TYPE-MISMATCH", "<"),
    "no unary minus on UInt64": (main("a: UInt64 = 1", "puts(-a)"), "CHECK-TYPE-MISMATCH", "-"),
    "UInt64 operators, conversions, bit methods, sort and a map key": (
        "struct Id\n  n: UInt64\nend\n\n" + main("a: UInt64 = 18446744073709551615", "b: UInt64 = 3", "n: Int = -1", "u: UInt32 = 7",
                     "c: UInt64 = a / b % 10 + b * 2 - 1", "d: UInt64 = u.to_uint64", "e: UInt64 = n.wrap_uint64",
                     "f: Result[UInt64] = n.to_uint64", "g: UInt64 = 5.to_uint64!", "h: Result[Int] = a.to_i",
                     "i: Int = b.to_i!", "j: Float = a.to_f", "k: UInt64 = a.bit_not.bit_and(b).bit_or(1).bit_xor(b)",
                     "l: UInt64 = a.shift_left(1).shift_right(1).wrapping_add(1).wrapping_sub(2).wrapping_mul(3)",
                     "m: Map[UInt64, Int] = {18446744073709551615: 1}", "s: Set[UInt64] = Set.new([0])",
                     "xs: List[UInt64] = [a, b].sort", "a += 1 - 1", "puts(a >= b and a > b or a <= b or a != b)",
                     'puts("#{c} #{d} #{e} #{f} #{g} #{h} #{i} #{j} #{k} #{l} #{m} #{s} #{xs}")',
                     "puts(JSON.encode(a))", "puts(JSON.schema(Id))", 'puts(JSON.decode("{\\"n\\": 1}", Id))'),
        None, None),
    "no widening of a signed type to UInt64": (main("a: Int8 = 1", "puts(a.to_uint64)"), "CHECK-UNKNOWN-METHOD",
                                               "a.to_uint64"),
    "UInt64 has no widening to a narrower type": (main("a: UInt64 = 1", "puts(a.to_uint32)"), "CHECK-UNKNOWN-METHOD",
                                                  "a.to_uint32"),
    "to_i of UInt64 is a Result": (main("a: UInt64 = 1", "n: Int = a.to_i"), "CHECK-TYPE-MISMATCH", "a.to_i"),
    "a UInt64 field default above the type": ("struct Id\n  n: UInt64 = 18446744073709551616\nend\n\n" + main(),
                                              "CHECK-INT-RANGE", "18446744073709551616"),
    "a field default out of range": ("struct Pixel\n  g: UInt8 = 300\nend\n\n" + main(), "CHECK-INT-RANGE", "300"),
    # The list sums of the narrow types come in a later pull request of #984.
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


UINT64_MAX = (1 << 64) - 1


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
        for method in ("shift_left", "shift_right", "shift_right_unsigned"):
            cases[f"{name} {method} -1"] = (
                main(f"a: {name} = 1", f"puts(a.{method}(-1))"), "RUNTIME-INVALID-COUNT", "-1")
        for operator in ("/", "%"):
            cases[f"{name} {operator} 0"] = (
                main(f"a: {name} = 1", f"puts(a {operator} 0)"), "RUNTIME-DIVISION-BY-ZERO", operator)
    for name, (program, operator) in {
        "UInt64 +": (main(f"a: UInt64 = {UINT64_MAX}", "puts(a + 1)"), "+"),
        "UInt64 - below zero": (main("a: UInt64 = 0", "puts(a - 1)"), "-"),
        "UInt64 * just past": (main(f"a: UInt64 = {1 << 32}", "puts(a * a)"), "*"),
        "UInt64 * at the top": (main(f"a: UInt64 = {1 << 63}", "puts(a * 2)"), "*"),
        "UInt64 / 0": (main(f"a: UInt64 = {UINT64_MAX}", "puts(a / 0)"), "/"),
        "UInt64 % 0": (main("a: UInt64 = 1", "puts(a % 0)"), "%"),
    }.items():
        code = "RUNTIME-DIVISION-BY-ZERO" if "0" == name[-1] and operator in "/%" else "RUNTIME-INTEGER-OVERFLOW"
        cases[name] = (program, code, operator)
    for method in ("shift_left", "shift_right"):
        cases[f"UInt64 {method} -1"] = (
            main("a: UInt64 = 1", f"puts(a.{method}(-1))"), "RUNTIME-INVALID-COUNT", "-1")
    cases["UInt64 to_i! above Int"] = (
        main("a: UInt64 = 9223372036854775808", "puts(a.to_i!)"), "RUNTIME-INTEGER-OVERFLOW", "a.to_i!")
    cases["Int to_uint64! below zero"] = (
        main("n = -1", "puts(n.to_uint64!)"), "RUNTIME-INTEGER-OVERFLOW", "n.to_uint64!")
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
