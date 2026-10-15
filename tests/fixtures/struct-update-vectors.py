"""Writes tests/fixtures/vm/struct-update-vectors.stdin, the vectors that struct-update-vectors.agc checks.

The peer models a struct as a Python dict and an update as "copy the dict, then
overwrite the keys", so it shares no code or structure with the VM's STRUCT_WITH.
Each line is `kind;steps;expected`. Kind r is the record Rec (seven fields, one of
them a nested struct and one a list), kind w the 20 field record Wide. Steps are
`op:number:text` joined by ",": each op is one `.with(...)` site of the program (a
different field set, a different argument order, values that read the old record).
Expected is the text form of the record after all steps.

Run by hand: python3 tests/fixtures/struct-update-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import copy
import random
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent / "vm" / "struct-update-vectors.stdin"
HEADER = (
    "# struct-update-vectors.stdin: made by python3 tests/fixtures/struct-update-vectors.py "
    "(dict copies); do not edit by hand"
)

WIDE_FIELDS = 20


def initial_rec():
    return {"a": 1, "b": "b", "c": [], "d": 4, "e": 5, "f": "f", "inner": {"x": 0, "y": "y"}}


def initial_wide():
    return {f"f{i}": i for i in range(WIDE_FIELDS)}


def replaced(old, **changes):
    """A new dict: the old one is never written to, as an immutable struct."""
    new = copy.deepcopy(old)
    new.update(changes)
    return new


# Every op reads `old` only: the values of one .with(...) see the record as it was before.
def rec_op(op, old, n, t):
    if op == 0:
        return replaced(old, a=n)
    if op == 1:
        return replaced(old, f=t)
    if op == 2:
        return replaced(old, c=old["c"] + [n])
    if op == 3:
        return replaced(old, a=n, d=n + 1)
    if op == 4:
        return replaced(old, d=n + 1, a=n)
    if op == 5:
        return replaced(old, e=old["a"], a=old["e"])
    if op == 6:
        return replaced(old, b=t + old["b"], f=old["f"] + "!", c=[], a=old["a"] + n, d=0, e=-n)
    if op == 7:
        return replaced(old, inner=replaced(old["inner"], x=n, y=t))
    if op == 8:
        # Chained updates: the second one reads the result of the first.
        first = replaced(old, a=n)
        return replaced(first, d=first["d"] + n)
    raise ValueError(op)


def wide_op(op, old, n, t):
    if op == 0:
        return replaced(old, f19=n)
    if op == 1:
        return replaced(old, f0=n, f19=n + 1)
    if op == 2:
        return replaced(old, f10=n, f3=n + 1, f17=n + 2, f0=n + 3)
    if op == 3:
        return replaced(old, f19=old["f0"], f0=old["f19"], f9=old["f10"] + n)
    raise ValueError(op)


def rec_text(r):
    inner = r["inner"]
    return (
        f'Rec(a: {r["a"]}, b: "{r["b"]}", c: [{", ".join(str(x) for x in r["c"])}], d: {r["d"]}, '
        f'e: {r["e"]}, f: "{r["f"]}", inner: Inner(x: {inner["x"]}, y: "{inner["y"]}"))'
    )


def wide_text(w):
    return "Wide(" + ", ".join(f"f{i}: {w[f'f{i}']}" for i in range(WIDE_FIELDS)) + ")"


def run(kind, steps):
    state = initial_rec() if kind == "r" else initial_wide()
    apply = rec_op if kind == "r" else wide_op
    for op, n, t in steps:
        state = apply(op, state, n, t)
    return rec_text(state) if kind == "r" else wide_text(state)


def line(kind, steps):
    encoded = ",".join(f"{op}:{n}:{t}" for op, n, t in steps)
    return ";".join([kind, encoded, run(kind, steps)])


def main():
    rng = random.Random(20261015)
    rows = []
    numbers = [0, 1, -1, 7, 42, 255, -1000, 65536, 2**40, -(2**40)]
    words = ["a", "xy", "hello", "q", "zzz", "m"]
    for op in range(9):
        for n in numbers[:4]:
            rows.append(line("r", [(op, n, rng.choice(words))]))
    for op in range(4):
        for n in numbers[:5]:
            rows.append(line("w", [(op, n, "t")]))
    for _ in range(250):
        steps = [(rng.randrange(9), rng.choice(numbers), rng.choice(words)) for _ in range(rng.randint(2, 14))]
        rows.append(line("r", steps))
    for _ in range(120):
        steps = [(rng.randrange(4), rng.choice(numbers), "t") for _ in range(rng.randint(2, 14))]
        rows.append(line("w", steps))
    OUTPUT.write_text(HEADER + "\n" + "\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} vectors to {OUTPUT}")


if __name__ == "__main__":
    main()
