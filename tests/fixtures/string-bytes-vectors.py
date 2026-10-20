"""Writes tests/fixtures/vm/string-bytes-vectors.stdin, the vectors that string-bytes-vectors.agc checks.

The peer is Python's str.encode("utf-8"), which shares no code with the VM. Each line is two fields
joined by ";": the code points of the String as decimal numbers joined by "," ("-" when empty), then
the expected UTF-8 bytes joined by "," ("-" when empty). Code points avoid any decoding of the input.

Run by hand: python3 tests/fixtures/string-bytes-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import random
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent / "vm" / "string-bytes-vectors.stdin"
HEADER = (
    "# string-bytes-vectors.stdin: made by python3 tests/fixtures/string-bytes-vectors.py "
    "(str.encode); do not edit by hand"
)

# The edges of each UTF-8 length, the surrogate gap, the NUL and the last scalar value.
EDGES = [0, 1, 0x41, 0x7F, 0x80, 0xE9, 0x7FF, 0x800, 0x20AC, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x1F600, 0x10FFFF]
RANGES = [(0, 0xD7FF), (0xE000, 0x10FFFF)]


def field(numbers):
    return ",".join(str(n) for n in numbers) or "-"


def row(codes):
    text = "".join(chr(c) for c in codes)
    return field(codes) + ";" + field(text.encode("utf-8"))


def scalar(rng):
    low, high = rng.choice(RANGES)
    return rng.randint(low, high)


def main():
    rng = random.Random(20261020)
    rows = [row([])]
    rows += [row([c]) for c in EDGES]
    rows.append(row(EDGES))
    for _ in range(60):
        rows.append(row([scalar(rng) for _ in range(rng.randint(1, 12))]))
    OUTPUT.write_text(HEADER + "\n" + "\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} vectors to {OUTPUT}")


if __name__ == "__main__":
    main()
