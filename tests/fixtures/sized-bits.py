"""Write tests/fixtures/vm/sized-bits.stdin: the vectors of the bit and wrapping methods, Int.wrap_<type> and the
widenings of the integer types, with the result each must give, worked out with Python ints. The VM fixture
sized-bits.agc reads the vectors and counts the ones that differ.

A line is `wrap <type> <n> <want>`; `bits <type> <a> <b>` and the results of and, or, xor, wrapping_add, wrapping_sub
and wrapping_mul; `not <type> <a> <want>`; `shift <type> <a> <count>` and the results of shift_left, shift_right and
shift_right_unsigned; `widen <type> <a>` and the result of each widening of the type, then to_f. The type is
`int` (Int, 64 bits) or a narrow type.
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "vm" / "sized-bits.stdin"
HEADER = "# sized-bits.stdin: made by python3 tests/fixtures/sized-bits.py (Python ints); do not edit by hand"
TYPES = {
    "int8": (8, True),
    "int16": (16, True),
    "int32": (32, True),
    "uint8": (8, False),
    "uint16": (16, False),
    "uint32": (32, False),
    "int": (64, True),
}
COUNTS = [0, 1, 3, 7, 8, 15, 16, 31, 32, 33, 63, 64, 100]


def bounds(name: str) -> tuple[int, int]:
    width, signed = TYPES[name]
    return (-(1 << (width - 1)), (1 << (width - 1)) - 1) if signed else (0, (1 << width) - 1)


def wrap(n: int, name: str) -> int:
    """The low bits of n read in the type."""
    width, signed = TYPES[name]
    low = n & ((1 << width) - 1)
    return low - (1 << width) if signed and low >> (width - 1) else low


def operands(name: str) -> list[int]:
    low, high = bounds(name)
    found = {low, -1, 0, 1, 3, high // 2, high, wrap(0x5555555555555555, name)}
    return sorted(v for v in found if low <= v <= high)


def wraps(name: str) -> list[int]:
    """The Ints that Int.wrap_<type> reads: past the type on both sides, and the ends of Int."""
    low, high = bounds(name)
    found = {low - 1, high + 1, low * 2, high * 2 + 1, 1 << 32, -(1 << 33), 12345678901, -(1 << 63), (1 << 63) - 1}
    return sorted(found | {0, 1, -1, low, high})


def shift_right(a: int, count: int) -> int:
    return a >> count


def shift_right_unsigned(a: int, count: int, name: str) -> int:
    width, _ = TYPES[name]
    return wrap((a & ((1 << width) - 1)) >> count, name)


def widenings(name: str) -> list[str]:
    """The narrow types that hold every value of the type, in the order of TYPES."""
    low, high = bounds(name)
    wider = (other for other in TYPES if other not in (name, "int"))
    return [other for other in wider if bounds(other)[0] <= low and bounds(other)[1] >= high]


def lines() -> list[str]:
    out = []
    for name, (width, _) in TYPES.items():
        for n in wraps(name) if name != "int" else []:
            out.append(f"wrap {name} {n} {wrap(n, name)}")
        for a in operands(name):
            out.append(f"not {name} {a} {wrap(~a, name)}")
            for b in operands(name):
                results = [a & b, a | b, a ^ b, wrap(a + b, name), wrap(a - b, name), wrap(a * b, name)]
                out.append(f"bits {name} {a} {b} {' '.join(map(str, results))}")
            for count in COUNTS:
                results = [wrap(a << count, name) if count < width else 0, shift_right(a, count),
                           shift_right_unsigned(a, count, name)]
                out.append(f"shift {name} {a} {count} {' '.join(map(str, results))}")
            if name != "int":
                results = [str(a) for _ in widenings(name)] + [repr(float(a))]
                out.append(f"widen {name} {a} {' '.join(results)}")
    return out


if __name__ == "__main__":
    OUTPUT.write_text("\n".join([HEADER, *lines()]) + "\n", encoding="utf-8")
