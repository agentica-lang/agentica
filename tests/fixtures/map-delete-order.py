"""Prints what tests/fixtures/vm/map-delete-order.agc prints, from Python dicts.

Python dicts keep insertion order: a deleted key put back goes last and a
replaced value keeps its place, the same rules as Agentica's Map and Set. The
peer shares no code with the VM.

Run by hand: python3 tests/fixtures/map-delete-order.py, and compare with the
stdout of tests/fixtures/vm/map-delete-order.expected.
"""

import json


def build_ints(n):
    m = {}
    for i in range(n):
        m[i * 37 % 1009] = i
    return m


def build_words(n):
    m = {}
    for i in range(n):
        m[f"w{i * 53 % 997}"] = i
    return m


def churn_ints(m, n):
    out = dict(m)
    for i in range(n):
        if i % 3 != 0:
            out.pop(i * 37 % 1009, None)
    for i in range(n):
        key = i * 37 % 1009
        if i % 9 == 1:
            out[key] = -i
        elif i % 6 == 0:
            out[key] = i * 100
    out.pop(5000, None)
    return out


def churn_words(m, n):
    out = dict(m)
    for i in range(n):
        if i % 3 != 2:
            out.pop(f"w{i * 53 % 997}", None)
    for i in range(n):
        if i % 7 == 0:
            out[f"w{i * 53 % 997}"] = -i
    out.pop("absent", None)
    return out


def show(x):
    if isinstance(x, bool):
        return "true" if x else "false"
    if isinstance(x, str):
        return '"' + x + '"'
    return str(x)


def show_list(items):
    return "[" + ", ".join(show(x) for x in items) + "]"


def show_map(m):
    return "{" + ", ".join(f"{show(k)}: {show(v)}" for k, v in m.items()) + "}"


def show_set(s):
    return "Set[" + ", ".join(show(x) for x in s) + "]"


def compact(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def main():
    ints = churn_ints(build_ints(300), 300)
    print(len(ints))
    print(show_list(ints.keys()))
    print(show_list(ints.values()))
    print(show_map(ints))
    total = 0
    for position, key in enumerate(ints, start=1):
        total = (total + key * position + ints[key]) % 1000000007
    print(total)
    print(compact(list(ints)))

    words = churn_words(build_words(300), 300)
    print(len(words))
    print(show_map(words))
    print(compact(words))

    fresh = {key: ints[key] for key in ints}
    print(show(show_map(ints) == show_map(fresh)))
    shorter = dict(ints)
    shorter.pop(next(iter(ints)))
    print(show(len(ints) == len(shorter) and show_map(ints) == show_map(shorter)))

    # A set is a dict with None values, so it keeps the same order rules.
    s = dict.fromkeys(range(300))
    for i in range(300):
        if i % 4 != 0:
            s.pop(i, None)
    for x in (7, 0, 301):
        s.setdefault(x)
    low = set(range(150))
    print(show_set(s))
    print(show_set(x for x in s if x in low))
    print(show_set(x for x in s if x not in low))
    union = dict(s)
    for x in (302, 4, 3):
        union.setdefault(x)
    print(show_set(union))
    trimmed = [x for x in s if x not in (301, 7)]
    print(show_list([all(x < 302 for x in s), all(x in low for x in s), all(x < 300 for x in trimmed)]))


if __name__ == "__main__":
    main()
