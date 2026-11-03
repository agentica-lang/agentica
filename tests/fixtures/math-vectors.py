"""Write tests/fixtures/vm/math-vectors.stdin: the number helpers worked out in Python.

Ints are Python ints, so a result outside 64 bits is seen and left out (those
cases halt, and the error fixtures cover them). Floats travel as their 64-bit
patterns (Float.from_bits on the Agentica side) so every value is exact. The
results come from exact arithmetic, not from the C library the VM uses: floor
and ceil from math.floor and math.ceil on Python ints, round from Decimal with
halves away from zero, and each square root is checked to be the correctly
rounded one with Fraction.
"""
import math
import struct
import sys
from decimal import ROUND_HALF_UP, Decimal
from fractions import Fraction
from pathlib import Path

INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1
OUTPUT = Path(__file__).resolve().parent / "vm" / "math-vectors.stdin"
HEADER = (
    "# math-vectors.stdin: made by python3 tests/fixtures/math-vectors.py "
    "(Python ints, Decimal and Fraction); do not edit by hand"
)
CANONICAL_NAN64 = 0x7FF8000000000000

INTS = [0, 1, -1, 2, -2, 3, 7, -7, 10, 12, -18, 255, 4294967296, INT_MIN, INT_MIN + 1, INT_MAX, -(1 << 62), 1 << 62]
EXPONENTS = [0, 1, 2, 3, 31, 32, 62, 63, 64, 100, INT_MAX]
BOUNDS = [(0, 0), (-5, 5), (1, 3), (INT_MIN, INT_MAX), (INT_MAX, INT_MAX), (-1, -1)]
FLOATS = [
    0.0,
    -0.0,
    0.5,
    -0.5,
    1.5,
    -1.5,
    2.5,
    -2.5,
    0.49999999999999994,
    -0.49999999999999994,
    1.0,
    -1.0,
    2.0,
    3.141592653589793,
    -3.141592653589793,
    0.1,
    1e-300,
    5e-324,
    -5e-324,
    4503599627370497.0,
    9007199254740993.0,
    9.223372036854775e18,
    -9.223372036854776e18,
    9.223372036854776e18,
    1e300,
    -1e300,
    math.inf,
    -math.inf,
    math.nan,
]
FLOAT_BOUNDS = [(0.0, 1.0), (-1.0, 1.0), (-0.0, 0.0), (2.0, 2.0), (-math.inf, math.inf), (-1e300, -1.0)]


def bits(x: float) -> int:
    if math.isnan(x):
        return CANONICAL_NAN64
    return struct.unpack(">q", struct.pack(">d", x))[0]


def fits(n: int) -> bool:
    return INT_MIN <= n <= INT_MAX


def int_pow(n: int, exponent: int) -> int | None:
    # Python's n ** INT_MAX never ends for |n| >= 2, so stop once the result has left Int.
    if n in (0, 1, -1):
        return n**exponent
    result = 1
    for _ in range(exponent):
        result *= n
        if not fits(result):
            return None
    return result


def rounded(x: float) -> int:
    return int(Decimal(x).to_integral_value(rounding=ROUND_HALF_UP))


def check_sqrt(x: float, root: float) -> None:
    """Assert that root is the binary64 nearest to the exact square root of x (ties cannot happen)."""
    if x == 0 or math.isinf(x) or math.isnan(x):
        return
    exact = Fraction(x)
    below, above = math.nextafter(root, 0.0), math.nextafter(root, math.inf)
    low = (Fraction(below) + Fraction(root)) / 2
    high = (Fraction(root) + Fraction(above)) / 2
    assert low * low < exact < high * high, x


def int_lines() -> list[str]:
    lines = []
    for n in INTS:
        if fits(abs(n)):
            lines.append(f"abs {n} {abs(n)}")
        for exponent in EXPONENTS:
            result = int_pow(n, exponent)
            if result is not None:
                lines.append(f"pow {n} {exponent} {result}")
        for m in INTS:
            if fits(math.gcd(n, m)):
                lines.append(f"gcd {n} {m} {math.gcd(n, m)}")
        for low, high in BOUNDS:
            lines.append(f"clamp {n} {low} {high} {min(max(n, low), high)}")
    return lines


def float_lines() -> list[str]:
    lines = []
    for x in FLOATS:
        lines.append(f"fabs {bits(x)} {bits(abs(x))}")
        if math.isfinite(x):
            for name, value in (("floor", math.floor(x)), ("ceil", math.ceil(x)), ("round", rounded(x))):
                if fits(value):
                    lines.append(f"{name} {bits(x)} {value}")
        if math.isnan(x) or x >= 0:
            root = math.sqrt(x)
            check_sqrt(x, root)
            lines.append(f"sqrt {bits(x)} {bits(root)}")
        for low, high in FLOAT_BOUNDS:
            result = x if math.isnan(x) else low if x < low else high if x > high else x
            lines.append(f"fclamp {bits(x)} {bits(low)} {bits(high)} {bits(result)}")
    return lines


def list_lines() -> list[str]:
    lines = []
    int_lists = [[3, 1, 2], [5], [-1, -1, -2], [INT_MAX, INT_MIN, 0], [7, 7]]
    for items in int_lists:
        text = ",".join(str(n) for n in items)
        lines.append(f"min {text} {min(items)}")
        lines.append(f"max {text} {max(items)}")
    # A NaN never wins unless every item is NaN; the first item wins a tie (0.0 and -0.0 compare equal).
    float_lists = [[2.5, -1.5, 0.5], [math.nan, 1.0, 2.0], [1.0, math.nan], [math.nan, math.nan], [0.0, -0.0], [-0.0, 0.0]]
    for items in float_lists:
        numbers = [x for x in items if not math.isnan(x)]
        low = items[0] if not numbers else next(x for x in numbers if x == min(numbers))
        high = items[0] if not numbers else next(x for x in numbers if x == max(numbers))
        text = ",".join(str(bits(x)) for x in items)
        lines.append(f"fmin {text} {bits(low)}")
        lines.append(f"fmax {text} {bits(high)}")
    return lines


def main() -> None:
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    lines = [HEADER, *int_lines(), *float_lines(), *list_lines()]
    with open(target, "w", encoding="ascii", newline="\n") as out:
        out.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
