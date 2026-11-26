"""Write tests/fixtures/vm/list-float32-vectors.stdin, the vectors that list-float32-vectors.agc reads: List[Float32]
operations over random binary32 bit patterns and the special ones (zeros, infinities, NaN, subnormals, the extremes),
at the lengths around the 32-way trie boundaries. The values and the operations are worked out here with Python's
struct 'f' (IEEE 754 binary32) and plain lists, so a packed 4-byte item must give back exactly the bits it was given.

A line is `in N BITS...` (the list the following lines work on) or `OP ARGS : SIZE DIGEST`, the size and the digest
of the resulting list or Float32, with a NaN counted as 1 (an operation on NaN gives a platform's NaN):
`acc = (acc * 31 + word % 1000003) % 1000003` over the items' bits.

Run by hand: python3 tests/fixtures/list-float32-vectors.py, and commit the file it writes.
tests/test_vm_list_float32.py checks that the committed file is what it writes.
"""

import math
import random
import struct
from pathlib import Path

HERE = Path(__file__).resolve().parent / "vm"
HEADER = "made by python3 tests/fixtures/list-float32-vectors.py (struct 'f'); do not edit by hand"
SPECIAL = [0x00000000, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00000, 0x00000001, 0x80000001,
           0x007FFFFF, 0x00800000, 0x7F7FFFFF, 0xFF7FFFFF, 0x3F800000, 0xBF800000, 0x3DCCCCCD, 0x4B800001]
LENGTHS = [1, 31, 32, 33, 64, 65, 1056, 1057, 1100]


def value(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def bits_of(x: float) -> int:
    return struct.unpack("<I", struct.pack("<f", x))[0]


def narrow(x: float) -> float:
    """x rounded to binary32, an infinity past the largest."""
    try:
        return struct.unpack("<f", struct.pack("<f", x))[0]
    except OverflowError:
        return math.copysign(math.inf, x)


def word(x: float) -> int:
    return 1 if math.isnan(x) else bits_of(x)


def digest(items: list[float]) -> str:
    acc = 0
    for x in items:
        acc = (acc * 31 + word(x) % 1000003) % 1000003
    return f"{len(items)} {acc}"


def finite(x: float) -> bool:
    return math.isfinite(x)


def cuts(n: int) -> list[int]:
    return sorted({k for k in (0, 1, 31, 32, 33, n // 2, n - 1, n) if 0 <= k <= n})


def sort_key(x: float) -> tuple[bool, float]:
    return (True, 0.0) if math.isnan(x) else (False, x)


def vectors(bits: list[int], rng: random.Random) -> list[str]:
    xs = [value(b) for b in bits]
    n = len(xs)
    out = [f"in {n} " + " ".join(str(b) for b in bits)]
    for op in ("push", "map", "reverse", "filter", "json", "sort_by"):
        if op == "reverse":
            want = xs[::-1]
        elif op in ("filter", "json"):
            want = [x for x in xs if finite(x)]
        elif op == "sort_by":
            want = sorted(xs, key=sort_key)
        else:
            want = xs
        out.append(f"{op} : {digest(want)}")
    for k in cuts(n):
        out.append(f"take {k} : {digest(xs[:k])}")
        out.append(f"drop {k} : {digest(xs[k:])}")
        out.append(f"swap {k} : {digest(xs[k:] + xs[:k])}")
    for i in sorted({0, n // 2, n - 1}):
        b = rng.choice(SPECIAL)
        out.append(f"set {i} {b} : {digest(xs[:i] + [value(b)] + xs[i + 1:])}")
    for b in SPECIAL[:4] + [rng.randrange(2**32)]:
        out.append(f"repeat {b} {n} : {digest([value(b)] * n)}")
    out.append("product : " + digest([narrow(xs[i] * xs[(i * 7 + 3) % n]) for i in range(n)]))
    total = 0.0
    for x in xs:
        total = narrow(total + x)
    out.append(f"sum : {digest([total])}")
    return out


def lines() -> list[str]:
    rng = random.Random(2019)
    out = []
    for n in LENGTHS:
        bits = [rng.choice(SPECIAL) if rng.random() < 0.08 else rng.randrange(2**32) for _ in range(n)]
        out += vectors(bits, rng)
    return out


def stdin_text() -> str:
    return "\n".join([f"# list-float32-vectors.stdin: {HEADER}", *lines()]) + "\n"


if __name__ == "__main__":
    (HERE / "list-float32-vectors.stdin").write_text(stdin_text())
