import math
import struct
import sys
from fractions import Fraction
from pathlib import Path

MASK = (1 << 64) - 1
INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1
OUTPUT = Path(__file__).resolve().parent / "vm" / "bits-vectors.stdin"
HEADER = (
    "# bits-vectors.stdin: made by python3 tests/fixtures/bits-vectors.py "
    "(Python ints masked to 64 bits and struct); do not edit by hand"
)
CANONICAL_NAN64 = 0x7FF8000000000000
CANONICAL_NAN32 = 0x7FC00000
F32_OVERFLOW = float.fromhex("0x1.ffffffp127")


def signed(value: int) -> int:
    value &= MASK
    return value - (1 << 64) if value >> 63 else value


INTS = [
    0,
    1,
    -1,
    INT_MIN,
    INT_MAX,
    signed(0x5555555555555555),
    signed(0xAAAAAAAAAAAAAAAA),
    255,
    4294967295,
    4294967296,
    signed(0x0123456789ABCDEF),
    INT_MIN + 1,
]
COUNTS = [0, 1, 7, 8, 31, 32, 63, 64, 65, 127, INT_MAX]


def shift_left(a: int, n: int) -> int:
    return 0 if n >= 64 else signed((a & MASK) << n)


def shift_right(a: int, n: int) -> int:
    return a >> n


def shift_right_unsigned(a: int, n: int) -> int:
    return signed((a & MASK) >> n)


def int_lines() -> list[str]:
    lines = []
    binary = {
        "bit_and": lambda a, b: signed((a & MASK) & (b & MASK)),
        "bit_or": lambda a, b: signed((a & MASK) | (b & MASK)),
        "bit_xor": lambda a, b: signed((a & MASK) ^ (b & MASK)),
    }
    for name, operation in binary.items():
        for a in INTS:
            for b in INTS:
                lines.append(f"{name} {a} {b} {operation(a, b)}")
    for a in INTS:
        lines.append(f"bit_not {a} {signed(~(a & MASK))}")
    shifts = {
        "shift_left": shift_left,
        "shift_right": shift_right,
        "shift_right_unsigned": shift_right_unsigned,
    }
    for name, operation in shifts.items():
        for a in INTS:
            for n in COUNTS:
                lines.append(f"{name} {a} {n} {operation(a, n)}")
    return lines


def encode_float(x: float) -> str:
    if math.isnan(x):
        return "nan"
    if math.isinf(x):
        return "inf" if x > 0 else "-inf"
    if x == 0:
        return "-0" if math.copysign(1.0, x) < 0 else "0p0"
    numerator, denominator = x.as_integer_ratio()
    if denominator == 1:
        zeros = (numerator & -numerator).bit_length() - 1
        significand, exponent = numerator >> zeros, zeros
    else:
        significand, exponent = numerator, 1 - denominator.bit_length()
    assert abs(significand) < 1 << 53 and -1074 <= exponent <= 1023
    assert math.ldexp(significand, exponent) == x
    return f"{significand}p{exponent}"


def f32_bits_exact(x: float) -> int:
    if math.isnan(x):
        return CANONICAL_NAN32
    sign = 0x80000000 if math.copysign(1.0, x) < 0 else 0
    if math.isinf(x) or abs(x) >= F32_OVERFLOW:
        return sign | 0x7F800000
    value = abs(Fraction(x))
    if value == 0:
        return sign
    exponent = value.numerator.bit_length() - value.denominator.bit_length()
    if Fraction(2) ** exponent > value:
        exponent -= 1
    exponent = max(exponent, -126)
    significand = round(value / Fraction(2) ** (exponent - 23))
    return sign | (((exponent + 127) << 23) + significand - (1 << 23))


def f32_bits(x: float) -> int:
    expected = f32_bits_exact(x)
    if math.isnan(x):
        return expected
    try:
        packed = struct.unpack(">I", struct.pack(">f", x))[0]
    except OverflowError:
        packed = (0x80000000 if x < 0 else 0) | 0x7F800000
    assert packed == expected, (x, packed, expected)
    return expected


def f64_bits(x: float) -> int:
    if math.isnan(x):
        return CANONICAL_NAN64
    return struct.unpack(">q", struct.pack(">d", x))[0]


def f64_from_bits(bits: int) -> float:
    return struct.unpack(">d", struct.pack(">q", bits))[0]


def f32_from_bits(bits: int) -> float:
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def power(exponent: int) -> float:
    return math.ldexp(1.0, exponent)


FLOATS = [
    0.0,
    -0.0,
    1.0,
    -1.0,
    -1.5,
    0.1,
    -0.1,
    2.5,
    3.141592653589793,
    1.7976931348623157e308,
    -1.7976931348623157e308,
    2.2250738585072014e-308,
    float.fromhex("0x0.fffffffffffffp-1022"),
    5e-324,
    -5e-324,
    math.inf,
    -math.inf,
    math.nan,
    power(53),
    power(100),
    1 + power(-24),
    1 + 3 * power(-24),
    -(1 + power(-24)),
    math.nextafter(1 + power(-24), math.inf),
    math.nextafter(1 + power(-24), 0.0),
    16777217.0,
    16777219.0,
    float.fromhex("0x1.fffffep127"),
    -float.fromhex("0x1.fffffep127"),
    F32_OVERFLOW,
    -F32_OVERFLOW,
    math.nextafter(F32_OVERFLOW, 0.0),
    math.nextafter(F32_OVERFLOW, math.inf),
    -math.nextafter(F32_OVERFLOW, 0.0),
    power(128),
    1e300,
    -1e300,
    power(-126),
    power(-126) - power(-149),
    power(-149),
    -power(-149),
    power(-150),
    -power(-150),
    3 * power(-150),
    5 * power(-150),
    math.nextafter(power(-150), math.inf),
    math.nextafter(power(-150), 0.0),
    power(-151),
]
BITS64 = [
    0,
    1,
    -1,
    INT_MIN,
    INT_MAX,
    0x7FF0000000000000,
    0x7FF0000000000001,
    0x7FF8000000000001,
    signed(0xFFF8000000000000),
    signed(0xFFF0000000000000),
    0x3FF0000000000001,
    signed(0x0123456789ABCDEF),
    signed(0x8000000000000001),
]
BITS32 = [
    0,
    1,
    2,
    8388607,
    8388608,
    0x3F800000,
    0x3F800001,
    0x3DCCCCCD,
    0x7F7FFFFF,
    0x7F800000,
    0x80000000,
    0x80000001,
    0xFF7FFFFF,
    0xFF800000,
    0x7FC00000,
    0x7FC00001,
    0x7F800001,
    0xFFC00000,
    0x7FFFFFFF,
    0xFFFFFFFF,
]


def float_lines() -> list[str]:
    lines = []
    for x in FLOATS:
        text = encode_float(x)
        lines.append(f"to_bits {text} {f64_bits(x)}")
        lines.append(f"from_bits {f64_bits(x)} {text}")
        lines.append(f"to_bits32 {text} {f32_bits(x)}")
    for bits in BITS64:
        lines.append(f"from_bits {bits} {encode_float(f64_from_bits(bits))}")
    for bits in BITS32:
        x = f32_from_bits(bits)
        expected = CANONICAL_NAN32 if math.isnan(x) else bits
        assert f32_bits(x) == expected
        lines.append(f"from_bits32 {bits} {encode_float(x)}")
        lines.append(f"to_bits32 {encode_float(x)} {expected}")
    return lines


def main() -> None:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    lines = [HEADER, *int_lines(), *float_lines()]
    with open(target, "w", encoding="ascii", newline="\n") as out:
        out.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
