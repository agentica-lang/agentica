"""Write tests/fixtures/vm/sized-vectors.stdin: the vectors of the narrow integer types, with the result each one must
give, worked out with Python ints. The VM fixture sized-vectors.agc reads them and counts the ones that differ.

A line is `to <type> <n> <want>`: Int.to_<type> of n gives `ok <n>` or `error`.
"""

from pathlib import Path

OUTPUT = Path(__file__).resolve().parent / "vm" / "sized-vectors.stdin"
HEADER = (
    "# sized-vectors.stdin: made by python3 tests/fixtures/sized-vectors.py "
    "(Python ints); do not edit by hand"
)
INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1
BOUNDS = {
    "int8": (-(1 << 7), (1 << 7) - 1),
    "int16": (-(1 << 15), (1 << 15) - 1),
    "int32": (-(1 << 31), (1 << 31) - 1),
    "uint8": (0, (1 << 8) - 1),
    "uint16": (0, (1 << 16) - 1),
    "uint32": (0, (1 << 32) - 1),
}


def values() -> list[int]:
    found = {0, 1, -1, INT_MIN, INT_MAX, INT_MIN + 1, INT_MAX - 1}
    for low, high in BOUNDS.values():
        found |= {low - 1, low, low + 1, high - 1, high, high + 1}
    return sorted(found)


def lines() -> list[str]:
    out = []
    for name, (low, high) in BOUNDS.items():
        for n in values():
            want = f"ok {n}" if low <= n <= high else "error"
            out.append(f"to {name} {n} {want}")
    return out


if __name__ == "__main__":
    OUTPUT.write_text("\n".join([HEADER, *lines()]) + "\n", encoding="utf-8")
