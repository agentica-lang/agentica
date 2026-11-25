"""Write the Float32 vectors, with the binary32 each one must give, worked out with fractions.Fraction: every decimal
text, sum, product and integer is rounded to binary32 exactly, by hand, never through a double.

tests/fixtures/vm/float32-vectors.stdin, which float32-vectors.agc reads, has one vector a line:

- `json <text> <bits>`: the Float32 field of `{"x": <text>}` decoded, from the text and from its JSON.Value; `error`
  when the text rounds past the largest Float32.
- `text <bits> <text>`: Float32.from_bits(bits).to_s, the fewest digits that read back.
- `int <n> <bits>`: n.to_float32. `float <bits64> <bits>`: Float.from_bits(bits64).to_float32.
- `ops <a> <b>` and the bits of a + b, a - b, a * b and a / b (`x` for a zero divisor), then a < b, a <= b and a == b.

tests/fixtures/vm/float32-literals.agc checks the same decimal texts written as Float32 literals.

Run by hand: python3 tests/fixtures/float32-vectors.py, and commit the files it writes. tests/test_spec_float32.py
checks that the committed files are what it writes.
"""

import random
import struct
from fractions import Fraction
from pathlib import Path

HERE = Path(__file__).resolve().parent / "vm"
HEADER = "made by python3 tests/fixtures/float32-vectors.py (fractions.Fraction); do not edit by hand"
INFINITY = 0x7F800000
SIGN = 0x80000000
HALFWAY = Fraction(2**128 - 2**103)


def nearest(value: Fraction) -> int | None:
    """The bits of the binary32 nearest value, ties to even; None past the largest one."""
    sign = SIGN if value < 0 else 0
    q = abs(value)
    if q == 0:
        return sign
    e = q.numerator.bit_length() - q.denominator.bit_length() - 24
    while q / Fraction(2) ** e >= 2**24:
        e += 1
    while e > -149 and q / Fraction(2) ** e < 2**23:
        e -= 1
    e = max(e, -149)
    scaled = q / Fraction(2) ** e
    m = scaled.numerator // scaled.denominator
    rest = scaled - m
    if rest > Fraction(1, 2) or (rest == Fraction(1, 2) and m % 2 == 1):
        m += 1
    if m == 2**24:
        m //= 2
        e += 1
    if e > 104:
        return None
    if m < 2**23:
        return sign | m
    return sign | (e + 150) << 23 | (m - 2**23)


def rounded(value: Fraction, negative_zero: bool = False) -> int:
    """nearest, with an infinity past the largest; a zero gets the sign IEEE gives it."""
    bits = nearest(value)
    if bits is None:
        return (SIGN if value < 0 else 0) | INFINITY
    if value == 0 and negative_zero:
        return SIGN
    return bits


def exact(bits: int) -> Fraction:
    """The value of finite binary32 bits."""
    biased = bits >> 23 & 0xFF
    m = bits & 0x7FFFFF
    value = Fraction(m, 2**149) if biased == 0 else Fraction(m + 2**23) * Fraction(2) ** (biased - 150)
    return -value if bits & SIGN else value


def finite(bits: int) -> bool:
    return bits >> 23 & 0xFF != 0xFF


def layout(digits: str, e: int) -> str:
    """digits times 10^e for the first digit, positional or scientific as the VM writes a Float."""
    n = len(digits)
    magnitude = abs(e)
    exponent_digits = 3 if magnitude >= 100 else 2 if magnitude >= 10 else 1
    positional = n + 1 if n > e + 1 else e + 3
    scientific = n + (n > 1) + 2 + exponent_digits
    if e < -4 or (e >= 0 and positional > 16 and positional > scientific):
        mantissa = digits[0] + ("." + digits[1:] if n > 1 else "")
        return f"{mantissa}e{'-' if e < 0 else '+'}{magnitude}"
    if e < 0:
        return "0." + "0" * (-e - 1) + digits
    if n > e + 1:
        return digits[: e + 1] + "." + digits[e + 1 :]
    return digits + "0" * (e + 1 - n) + ".0"


def leading(value: Fraction) -> int:
    """The power of ten of the first digit of value > 0."""
    e = len(str(value.numerator)) - len(str(value.denominator))
    while Fraction(10) ** e > value:
        e -= 1
    while Fraction(10) ** (e + 1) <= value:
        e += 1
    return e


def shortest(bits: int) -> str:
    """The fewest digits that round back to bits; of two as short, the nearer, and the upper in a tie."""
    if not finite(bits):
        return "+nan.0" if bits & 0x7FFFFF else ("-inf.0" if bits & SIGN else "+inf.0")
    value = exact(bits)
    sign = "-" if bits & SIGN else ""
    if value == 0:
        return sign + "0.0"
    value = abs(value)
    e = leading(value)
    for n in range(1, 10):
        unit = Fraction(10) ** (e - n + 1)
        scaled = value / unit
        down = scaled.numerator // scaled.denominator
        rest = scaled - down
        order = [down, down + 1] if rest < Fraction(1, 2) else [down + 1, down]
        for candidate in order:
            if nearest(candidate * unit) == bits & ~SIGN:
                digits = str(candidate).rstrip("0")
                return sign + layout(digits, e - n + 1 + len(str(candidate)) - 1)
    raise AssertionError(f"no 9-digit text for {bits:#x}")


def decimal(value: Fraction) -> str:
    """The exact decimal text of a dyadic value."""
    sign = "-" if value < 0 else ""
    value = abs(value)
    places = 0
    while (value * 10**places).denominator != 1:
        places += 1
    digits = str((value * 10**places).numerator).rjust(places + 1, "0")
    if places == 0:
        return sign + digits + ".0"
    return sign + digits[:-places] + "." + digits[-places:]


def double_text(value: Fraction) -> str:
    """repr of the double nearest value: the shortest text a double producer writes."""
    return repr(float(value))


def special_bits() -> list[int]:
    one = 0x3F800000
    found = [
        0, SIGN, one, one | SIGN, one + 1, one - 1, 0x3DCCCCCD, 0x3EAAAAAB, 0x7F7FFFFF, 0x7F7FFFFE, 0x00800000,
        0x007FFFFF, 0x00000001, 0x00000002, 0x4B800000, 0x4B800001, 0x40400000, 0x0DA24260, 0x7149F2CA, 0x5F000000,
        0x501502F9, 0x2F800000,
    ]
    return found + [bits | SIGN for bits in found[2:8]]


def decimal_texts() -> list[str]:
    """Texts on both sides of binary32 midpoints, where a double rounds them to the midpoint itself, and texts at the
    top of the range and among the subnormals."""
    found = ["0.1", "1.0", "3.14159274", "16777217.0", "16777219.0", "3.4028234663852886e38", "3.4028235e38",
             "1.17549435e-38", "1.4e-45", "1e-45", "7.1e-46", "7e-46", "1e-50", "123456789.0", "0.000001",
             "340282346638528859811704183484516925440.0", "1.000000059604644775390625",
             "1.0000000596046447753906250000000001", "1.0000000596046447753906249999999999", "0.0", "1E10", "2.5e-1",
             "-0.0", "-2.5"]
    tiny = Fraction(1, 10**60)
    rng = random.Random(984)
    lows = [0x3F800000, 0x3F800001, 0x7F7FFFFE, 0x00000000, 0x00000001, 0x00800000, 0x4B800000, 0x3DCCCCCC]
    lows += [rng.randrange(0, 0x7F7FFFFF) for _ in range(40)]
    for low in lows:
        middle = (exact(low) + exact(low + 1)) / 2
        found += [decimal(middle), decimal(middle + middle * tiny), decimal(middle - middle * tiny)]
        found.append(double_text(middle))
    top = HALFWAY
    found += [decimal(top - top * tiny), decimal(top).removesuffix(".0") + "e0", decimal(top + top * tiny)]
    found += ["2.9802322387695312e-8", "1.401298464324817e-45", "7.006492321624085e-46", "7.006492321624087e-46"]
    return found


def lines() -> list[str]:
    out = []
    for text in decimal_texts():
        bits = nearest(Fraction(text))
        if bits == 0 and text.startswith("-"):
            bits = SIGN
        out.append(f"json {text} {'error' if bits is None else bits}")
    rng = random.Random(42)
    texts = special_bits() + [0x7F800000, 0xFF800000, 0x7FC00000]
    texts += [rng.randrange(0, 2**32) for _ in range(1500)]
    for bits in texts:
        if not finite(bits) and bits & 0x7FFFFF:
            bits = 0x7FC00000
        out.append(f"text {bits} {shortest(bits)}")
    for n in [0, 1, -1, 16777217, 16777219, 2**53 + 2**29 + 1, 2**63 - 1, -(2**63), 2**24 + 1, -(2**31) - 1]:
        out.append(f"int {n} {nearest(Fraction(n))}")
    doubles = [0.1, 1 / 3, 3.4028235677973366e38, 3.4028235677973362e38, 1e39, -1e39, 1e-46, -1e-46]
    doubles += [float((exact(low) + exact(low + 1)) / 2) for low in (0x3F800000, 0x3F800001, 0x00000001)]
    for x in doubles:
        bits64 = struct.unpack("<q", struct.pack("<d", x))[0]
        out.append(f"float {bits64} {rounded(Fraction(x))}")
    operands = special_bits()
    pairs = [(a, b) for a in operands for b in operands]
    for _ in range(400):
        pairs.append(tuple(rng.randrange(0, 0x7F7FFFFF) | rng.choice([0, SIGN]) for _ in range(2)))
    for a, b in pairs:
        x, y = exact(a), exact(b)
        add = rounded(x + y, a & SIGN and b & SIGN)
        sub = rounded(x - y, a & SIGN and not b & SIGN)
        mul_sign = bool((a ^ b) & SIGN)
        mul = rounded(x * y, mul_sign)
        div = "x" if y == 0 else rounded(x / y, mul_sign)
        flags = [x < y, x <= y, x == y]
        out.append(f"ops {a} {b} {add} {sub} {mul} {div} " + " ".join(str(f).lower() for f in flags))
    return out


def literal_lines() -> list[str]:
    """check(<literal>, <bits>) for each decimal text that is a literal: no exponent letter E, within the range."""
    found = []
    for text in decimal_texts():
        bits = nearest(Fraction(text))
        if bits is None or "E" in text or text.startswith("-"):
            continue
        found.append(f"  failed += check({text}, {bits})")
        if text != "0.0":
            found.append(f"  failed += check(-{text}, {bits | SIGN})")
    return found


LITERALS = """# Float32 literals: each decimal text of tests/fixtures/float32-vectors.py, which the VM rounds once
# to binary32 when it loads the program, against the bits the peer gives with fractions.Fraction.
# {header}.
def check(x: Float32, want: Int) -> Int
  return 0 if x.to_bits.to_i == want

  puts("#{{x}} has bits #{{x.to_bits}}, want #{{want}}")
  1
end

def main() -> Void
  failed = 0
{lines}
  puts("#{{failed}} literals differ")
end
"""


def stdin_text() -> str:
    return "\n".join([f"# float32-vectors.stdin: {HEADER}", *lines()]) + "\n"


def literals_text() -> str:
    return LITERALS.format(header=HEADER, lines="\n".join(literal_lines()))


if __name__ == "__main__":
    (HERE / "float32-vectors.stdin").write_text(stdin_text())
    (HERE / "float32-literals.agc").write_text(literals_text())
