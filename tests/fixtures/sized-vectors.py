"""Write tests/fixtures/vm/sized-vectors.stdin: the vectors of the narrow integer types, with the result each one must
give, worked out with Python ints. The VM fixture sized-vectors.agc reads them and counts the ones that differ.

A line is `to <type> <n> <want>`: Int.to_<type> of n gives `ok <n>` or `error`; or `ops <type> <a> <b>` and the
result of each operator of OPERATORS on a and b, `x` where it halts (out of the type, or a zero divisor). `/`
truncates toward zero and `%` takes the sign of the dividend.
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


OPERATORS = ["add", "sub", "mul", "div", "mod", "lt", "le", "gt", "ge", "eq", "ne", "neg"]


def quotient(a: int, b: int) -> int:
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def operated(name: str, a: int, b: int) -> int | bool | None:
    """The result of the operator, None where it halts before the range check (a zero divisor)."""
    if name in ("div", "mod") and b == 0:
        return None
    return {
        "add": lambda: a + b,
        "sub": lambda: a - b,
        "mul": lambda: a * b,
        "div": lambda: quotient(a, b),
        "mod": lambda: a - b * quotient(a, b),
        "lt": lambda: a < b,
        "le": lambda: a <= b,
        "gt": lambda: a > b,
        "ge": lambda: a >= b,
        "eq": lambda: a == b,
        "ne": lambda: a != b,
        "neg": lambda: -a,
    }[name]()


def shown(result: int | bool | None, low: int, high: int) -> str:
    if isinstance(result, bool):
        return str(result).lower()
    if result is None or not low <= result <= high:
        return "x"
    return str(result)


def operands(low: int, high: int) -> list[int]:
    return sorted(v for v in {low, low + 1, -2, -1, 0, 1, 2, 3, 7, 100, high - 1, high} if low <= v <= high)


def lines() -> list[str]:
    out = []
    for name, (low, high) in BOUNDS.items():
        for n in values():
            want = f"ok {n}" if low <= n <= high else "error"
            out.append(f"to {name} {n} {want}")
    for name, (low, high) in BOUNDS.items():
        for a in operands(low, high):
            for b in operands(low, high):
                results = [shown(operated(op, a, b), low, high) for op in OPERATORS]
                if low == 0:
                    results[-1] = "x"
                out.append(f"ops {name} {a} {b} {' '.join(results)}")
    return out


if __name__ == "__main__":
    OUTPUT.write_text("\n".join([HEADER, *lines()]) + "\n", encoding="utf-8")
