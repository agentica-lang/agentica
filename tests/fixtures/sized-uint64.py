"""Write tests/fixtures/vm/sized-uint64.stdin: the vectors of UInt64, with the result each operation must give, worked
out with Python ints. The VM fixture sized-uint64.agc reads the vectors and counts the ones that differ.

An operand is written as the Int that holds its 64 bits (a value from 2**63 is written less 2**64), which the fixture
turns into a UInt64 with Int.wrap_uint64. A result is the decimal text of the UInt64, or `-` when the operation leaves
the range or divides by zero, which halts and is tested in tests/test_spec_sized.py.

A line is `arith a b` and the results of +, -, *, /, %, <, <=, ==, !=, >, >=; `bits a b` and the results of bit_and,
bit_or, bit_xor, wrapping_add, wrapping_sub and wrapping_mul; `not a want`; `shift a count` and the results of
shift_left and shift_right; `convert a` and to_i (`-` above the Int range) and the bits of to_f; `widen a` for an a
that a UInt32 holds; `wrap n want checked` for any Int n: the result of Int.wrap_uint64 and of Int.to_uint64 (`-` when
n is negative); `order a b c ... | x y z`: the operands sorted give x y z.
"""

import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "vm" / "sized-uint64.stdin"
HEADER = "# sized-uint64.stdin: made by python3 tests/fixtures/sized-uint64.py (Python ints); do not edit by hand"
LIMIT = 1 << 64
COUNTS = [0, 1, 7, 8, 31, 32, 33, 63, 64, 65, 100]
WRAPS = [-(1 << 63), -(1 << 32), -2, -1, 0, 1, (1 << 31), (1 << 63) - 1]


def operands() -> list[int]:
    """The edges of the 64 bits and of the sign of an Int, and values that make a product just fit or just not."""
    found = {0, 1, 2, 3, 10, 255, 256, 65535, 65536, (1 << 32) - 1, 1 << 32, (1 << 32) + 1, (1 << 63) - 1, 1 << 63,
             (1 << 63) + 1, LIMIT - 2, LIMIT - 1, 0x5555555555555555, 0xAAAAAAAAAAAAAAAA, 10**19, 10**18}
    return sorted(found)


def signed(n: int) -> int:
    """The Int with the 64 bits of n."""
    return n - LIMIT if n >= 1 << 63 else n


def bits_of_float(x: float) -> int:
    return struct.unpack("<q", struct.pack("<d", x))[0]


def result(n: int) -> str:
    return str(n) if 0 <= n < LIMIT else "-"


def flag(value: bool) -> str:
    return "true" if value else "false"


def lines() -> list[str]:
    out = []
    values = operands()
    for a in values:
        for b in values:
            sums = [result(a + b), result(a - b), result(a * b), result(a // b) if b else "-"]
            sums.append(result(a % b) if b else "-")
            sums += [flag(a < b), flag(a <= b), flag(a == b), flag(a != b), flag(a > b), flag(a >= b)]
            out.append(f"arith {signed(a)} {signed(b)} {' '.join(sums)}")
            wide = [a & b, a | b, a ^ b, (a + b) % LIMIT, (a - b) % LIMIT, (a * b) % LIMIT]
            out.append(f"bits {signed(a)} {signed(b)} {' '.join(map(str, wide))}")
        out.append(f"not {signed(a)} {LIMIT - 1 - a}")
        for count in COUNTS:
            left = (a << count) % LIMIT if count < 64 else 0
            right = a >> count if count < 64 else 0
            out.append(f"shift {signed(a)} {count} {left} {right}")
        out.append(f"convert {signed(a)} {a if a < 1 << 63 else '-'} {bits_of_float(float(a))}")
        if a < 1 << 32:
            out.append(f"widen {a}")
    for n in WRAPS:
        out.append(f"wrap {n} {n % LIMIT} {n if n >= 0 else '-'}")
    descending = " ".join(str(signed(a)) for a in sorted(values, reverse=True))
    ascending = " ".join(str(signed(a)) for a in sorted(values))
    out.append(f"order {descending} | {ascending}")
    return out


if __name__ == "__main__":
    OUTPUT.write_text("\n".join([HEADER, *lines()]) + "\n", encoding="utf-8")
