"""Writes tests/fixtures/vm/set-vectors.stdin, the vectors that set-vectors.agc checks.

The peer is an insertion-ordered set built on a Python list and `in`, so it shares no
code or structure with the VM's hash trie. Each line is five fields joined by ";":
kind (i for Int, s for String), operation, set A, operand B, expected result. A set
or list is its elements joined by "," ("-" when empty); a Bool is true or false; a
number is decimal; "walk" takes "+x" and "-x" steps in B.

Run by hand: python3 tests/fixtures/set-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import random
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent / "vm" / "set-vectors.stdin"
HEADER = (
    "# set-vectors.stdin: made by python3 tests/fixtures/set-vectors.py "
    "(list-backed ordered sets); do not edit by hand"
)

INT_MAX = (1 << 63) - 1
INT_MIN = -(1 << 63)
INTS = [0, 1, -1, 2, 3, 7, 42, 255, 256, 65536, 1000000, INT_MAX, INT_MIN, INT_MIN + 1]
WORDS = ["a", "b", "c", "d", "apple", "pear", "key1", "key10", "é", "日本", "ünï", "x_y", "A", "Z"]


def new(items):
    out = []
    for x in items:
        if x not in out:
            out.append(x)
    return out


def add(a, x):
    return a if x in a else a + [x]


def delete(a, x):
    return [y for y in a if y != x]


def union(a, b):
    return a + [x for x in b if x not in a]


def intersection(a, b):
    return [x for x in a if x in b]


def difference(a, b):
    return [x for x in a if x not in b]


def subset(a, b):
    return all(x in b for x in a)


def walk(a, steps):
    for step in steps:
        a = add(a, step[1]) if step[0] == "+" else delete(a, step[1])
    return a


def text(a, kind):
    if kind == "i":
        return "Set[" + ", ".join(str(x) for x in a) + "]"
    return "Set[" + ", ".join('"' + x + '"' for x in a) + "]"


def field(items):
    return ",".join(str(x) for x in items) if items else "-"


def flag(value):
    return "true" if value else "false"


def vectors_for(kind, a_items, b_items, pick):
    """All operations on the input lists a_items and b_items; pick is an element for add/delete."""
    a = new(a_items)
    b = new(b_items)
    rows = [
        ("new", field(a_items), "-", field(a)),
        ("size", field(a_items), "-", str(len(a))),
        ("empty", field(a_items), "-", flag(not a)),
        ("add", field(a_items), str(pick), field(add(a, pick))),
        ("delete", field(a_items), str(pick), field(delete(a, pick))),
        ("include", field(a_items), str(pick), flag(pick in a)),
        ("union", field(a_items), field(b_items), field(union(a, b))),
        ("intersection", field(a_items), field(b_items), field(intersection(a, b))),
        ("difference", field(a_items), field(b_items), field(difference(a, b))),
        ("subset", field(a_items), field(b_items), flag(subset(a, b))),
        ("subset", field(b_items), field(a_items), flag(subset(b, a))),
    ]
    return [";".join([kind, op, left, right, want]) for op, left, right, want in rows]


def fixed_pairs(universe):
    u = universe
    return [
        ([], []),
        ([u[0]], []),
        ([], [u[0]]),
        ([u[0]], [u[0]]),
        ([u[0], u[1]], [u[1], u[0]]),
        ([u[0], u[1], u[0], u[2], u[1]], [u[2], u[3]]),
        ([u[3], u[2], u[1]], [u[1], u[2], u[3], u[4]]),
        ([u[1], u[2], u[3], u[4]], [u[2], u[3]]),
        (u[:8], u[4:12]),
        (u[::-1], u),
        (u, u[5:]),
    ]


def random_lists(rng, universe, count):
    for _ in range(count):
        yield (
            [rng.choice(universe) for _ in range(rng.randint(0, 24))],
            [rng.choice(universe) for _ in range(rng.randint(0, 24))],
        )


def walks(kind, rng, universe, count, base_max=6, step_counts=(10, 60), moves="+-"):
    rows = []
    for _ in range(count):
        base = [rng.choice(universe) for _ in range(rng.randint(0, base_max))]
        steps = [(rng.choice(moves), rng.choice(universe)) for _ in range(rng.randint(*step_counts))]
        result = walk(new(base), steps)
        encoded = ",".join(op + str(x) for op, x in steps)
        rows.append(";".join([kind, "walk", field(base), encoded, field(result)]))
    return rows


def large(rng):
    """Sets past the first HAMT levels: a 32-way node holds at most 32 entries."""
    numbers = list(range(-150, 450))
    rng.shuffle(numbers)
    a_items = numbers[:300] + numbers[:40]
    b_items = numbers[150:450]
    words = [f"w{n}" for n in numbers[:420]]
    rng.shuffle(words)
    a_words = words[:300] + words[:40]
    b_words = words[150:420]
    return (
        vectors_for("i", a_items, b_items, numbers[7])
        + vectors_for("i", a_items, b_items, 100000)
        + vectors_for("s", a_words, b_words, words[9])
        + vectors_for("s", a_words, b_words, "absent")
    )


def main():
    rng = random.Random(20260301)
    rows = []
    for kind, universe in (("i", INTS), ("s", WORDS)):
        for index, (a_items, b_items) in enumerate(fixed_pairs(universe)):
            for pick in (universe[0], universe[1], universe[-1]):
                rows += vectors_for(kind, a_items, b_items, pick)
            rows.append(";".join([kind, "text", field(a_items), "-", text(new(a_items), kind)]))
        small = universe[:6]
        for a_items, b_items in random_lists(rng, small, 40):
            rows += vectors_for(kind, a_items, b_items, rng.choice(universe))
        rows += walks(kind, rng, small, 25)
    rows += large(rng)
    # Long walks, two deletes for each add, so that deleted elements outnumber
    # the ones left and the VM rebuilds its key list.
    rows += walks("i", rng, list(range(-100, 200)), 2, 400, (900, 1200), "+--")
    rows += walks("s", rng, [f"k{n}" for n in range(300)], 1, 400, (900, 1200), "+--")
    OUTPUT.write_text(HEADER + "\n" + "\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} vectors to {OUTPUT}")


if __name__ == "__main__":
    main()
