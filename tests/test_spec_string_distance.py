"""`String#edit_distance` and `String#jaro_winkler` through the product CLI: the type rules, a negative `max` at the
argument, and the results against Python peers (a full Levenshtein table, and Jaro-Winkler as Ruby's
DidYouMean::JaroWinkler computes it) on random texts with multibyte and combining characters.
"""

import json
import math
import random

import pytest

from tests.agentica_test import cli, compile_text, run, run_vm
from tests.spec_support import assert_rule, covered

MAIN = "def main() -> Void\n"

RULES = [
    (
        MAIN + '  d: Int = "a".edit_distance("b")\n  c: Int = "a".edit_distance("b", 1)\n  puts(d + c)\nend\n',
        None,
        None,
    ),
    (MAIN + '  x: Float = "a".jaro_winkler("b")\n  puts(x)\nend\n', None, None),
    (MAIN + '  puts("a".edit_distance(1))\nend\n', "CHECK-TYPE-MISMATCH", "1"),
    (MAIN + '  puts("a".edit_distance("b", 1.5))\nend\n', "CHECK-TYPE-MISMATCH", "1.5"),
    (MAIN + '  puts("a".jaro_winkler("b", 1))\nend\n', "CHECK-ARITY", None),
]


@pytest.mark.parametrize(("program", "code", "text"), RULES)
def test_string_distance_rules(agentica_check, program, code, text):
    assert_rule(agentica_check(program), program, code, text)


def levenshtein(a: str, b: str) -> int:
    """The full table, one row at a time, over code points (Python's str is code points, as Agentica's length)."""
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        previous, row = row, [i]
        for j, y in enumerate(b, 1):
            row.append(min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x != y)))
    return row[-1]


def jaro_winkler(a: str, b: str) -> float:
    """DidYouMean::Jaro and JaroWinkler of Ruby; two empty texts give 1.0, and of two texts of one length the first in
    UTF-8 byte order is matched against the other."""
    if len(a) > len(b) or (len(a) == len(b) and a.encode() > b.encode()):
        a, b = b, a
    if not b:
        return 1.0
    window = max(len(b) // 2 - 1, 0)
    flags_a, flags_b, m = [False] * len(a), [False] * len(b), 0
    for i, x in enumerate(a):
        for j in range(max(i - window, 0), min(i + window + 1, len(b))):
            if not flags_b[j] and x == b[j]:
                flags_a[i] = flags_b[j] = True
                m += 1
                break
    if m == 0:
        return 0.0
    matched_b = [y for y, flag in zip(b, flags_b) if flag]
    t = sum(x != y for x, y in zip((x for x, flag in zip(a, flags_a) if flag), matched_b)) // 2
    jaro = (m / len(a) + m / len(b) + (m - t) / m) / 3
    if jaro <= 0.7:
        return jaro
    prefix = 0
    while prefix < min(4, len(a)) and a[prefix] == b[prefix]:
        prefix += 1
    return jaro + prefix * 0.1 * (1 - jaro)


# Letters, two- three- and four-byte characters, a combining accent and an emoji modifier: each is one character.
ALPHABET = ["a", "b", "c", "é", "€", "😀", "́", "\U0001f3fd"]

KNOWN = [
    ("kitten", "sitting"),
    ("martha", "marhta"),
    ("dwayne", "duane"),
    ("dixon", "dicksonx"),
    ("", ""),
    ("", "abc"),
    ("a", "a"),
    ("a", "b"),
    ("abc", "xyz"),
    ("café", "cafe"),
    ("é", "é"),
    ("👍🏽", "👍"),
]


def pairs() -> list[tuple[str, str]]:
    rng = random.Random(1441)
    found = list(KNOWN)
    for _ in range(150):
        a = "".join(rng.choice(ALPHABET[: rng.randint(2, 8)]) for _ in range(rng.randint(0, 12)))
        b = "".join(rng.choice(ALPHABET[: rng.randint(2, 8)]) for _ in range(rng.randint(0, 12)))
        found.append((a, b))
    return found


def test_string_distance_matches_python(tmp_path):
    cases = pairs()
    lines = []
    for a, b in cases:
        lines.append(f'  puts("{a}".edit_distance("{b}"))')
        lines.append(f'  puts("{b}".edit_distance("{a}"))')
        lines.extend(f'  puts("{a}".edit_distance("{b}", {cap}))' for cap in range(4))
        lines.append(f'  puts("{a}".jaro_winkler("{b}"))')
        lines.append(f'  puts("{b}".jaro_winkler("{a}"))')
    path = tmp_path / "distance.agc"
    path.write_text(MAIN + "\n".join(lines) + "\nend\n", encoding="utf-8")
    result = run(cli() + [str(path)])
    assert result.code == 0, result.stderr
    out = iter(result.stdout.splitlines())
    for a, b in cases:
        distance = levenshtein(a, b)
        assert [int(next(out)) for _ in range(2)] == [distance, distance], (a, b)
        assert [int(next(out)) for _ in range(4)] == [min(distance, cap + 1) for cap in range(4)], (a, b)
        similarity = jaro_winkler(a, b)
        for _ in range(2):
            assert math.isclose(float(next(out)), similarity, rel_tol=1e-12, abs_tol=1e-15), (a, b)


def test_string_distance_known_values(tmp_path):
    # Winkler's examples, rounded as the literature gives them.
    source = MAIN + '  puts("MARTHA".jaro_winkler("MARHTA"))\n  puts("DWAYNE".jaro_winkler("DUANE"))\n'
    source += '  puts("DIXON".jaro_winkler("DICKSONX"))\nend\n'
    path = tmp_path / "known.agc"
    path.write_text(source, encoding="utf-8")
    result = run(cli() + [str(path)])
    assert result.code == 0, result.stderr
    assert [round(float(line), 3) for line in result.stdout.split()] == [0.961, 0.84, 0.813]


def test_string_distance_long_texts(tmp_path):
    rng = random.Random(7)
    letters = "abcdefghijklmnopqrstuvwxyz"
    # Two unrelated texts of 600 characters, for the whole table against the peer.
    a, b = ("".join(rng.choice(letters + "é😀") for _ in range(600)) for _ in range(2))
    # 20,000 characters with 5 replacements, the first and the last among them, so no common end is cut: with max the
    # band is 2 * max + 1 cells wide, and a row past max stops the walk.
    long = "".join(rng.choice(letters) for _ in range(20000))
    changed = list(long)
    for at in (0, 4000, 9000, 15000, 19999):
        changed[at] = "é"
    source = (
        MAIN
        + f'  a = "{a}"\n  b = "{b}"\n  long = "{long}"\n  changed = "{"".join(changed)}"\n'
        + "  puts(a.edit_distance(b))\n  puts(a.edit_distance(b, 3))\n  puts(a.jaro_winkler(b))\n"
        + "  puts(long.edit_distance(changed, 3))\n  puts(long.edit_distance(changed, 10))\n"
        + "  puts(long.edit_distance(long + \"\"))\n"
        # Each "a" of the first half scans about 1500 "b" of its window, so the budget runs out inside a window and the
        # walk resumes there.
        + '  puts(("a" * 1500 + "b" * 1500).jaro_winkler("b" * 1500 + "a" * 1500))\nend\n'
    )
    path = tmp_path / "long.agc"
    path.write_text(source, encoding="utf-8")
    result = run(cli() + [str(path)])
    assert result.code == 0, result.stderr
    out = result.stdout.split()
    assert out[:2] == [str(levenshtein(a, b)), "4"]
    assert math.isclose(float(out[2]), jaro_winkler(a, b), rel_tol=1e-12)
    assert out[3:6] == ["4", "5", "0"]
    halves = jaro_winkler("a" * 1500 + "b" * 1500, "b" * 1500 + "a" * 1500)
    assert math.isclose(halves, 0.8328888888888889, rel_tol=1e-12)
    assert math.isclose(float(out[6]), halves, rel_tol=1e-12)


def test_string_distance_negative_max(tmp_path):
    # RUNTIME-INVALID-COUNT at the max argument, as `s * n` gives for a negative count.
    for cap in ("0 - 1", "-9223372036854775807 - 1"):
        source = f'{MAIN}  max = {cap}\n  puts("ab".edit_distance("b", max))\nend\n'
        (tmp_path / "bad.agc").write_text(source, encoding="utf-8")
        result = run(cli() + ["--json", str(tmp_path / "bad.agc")])
        assert result.code == 1, cap
        diagnostic = json.loads(result.stderr)
        assert (diagnostic["code"], covered(source, diagnostic["range"])) == ("RUNTIME-INVALID-COUNT", "max")


STEPS = """def main() -> Void
  size = System.args()[0].to_i!
  a = "ab" * size
  b = "ba" * size
  before = Profile.steps()
  puts(a.edit_distance(b))
  middle = Profile.steps()
  puts(("a" * size).jaro_winkler("b" * size))
  puts(before)
  puts(middle - before)
  puts(Profile.steps() - middle)
end
"""


def test_string_distance_long_work_takes_steps_and_stops_at_the_step_limit(tmp_path):
    """Work past one turn's cost runs a step per 4096 table cells or Jaro comparisons: "ab" * 1000 against "ba" * 1000
    share no end, so the walk covers all 2000 * 2000 cells, and Jaro of "a" * 1000 against "b" * 1000 finds no match
    and compares each character with its whole window. A step budget that ends inside either call stops it with
    RUNTIME-STEP-LIMIT at the call."""
    bytecode = compile_text(STEPS, "steps", tmp_path)
    result = run_vm(bytecode, args=["1000"])
    lines = result.stdout.splitlines()
    assert result.code == 0 and lines[:2] == ["2", "0.0"], result.stderr
    before, distance_steps, jaro_steps = map(int, lines[2:])
    assert 2000 * 2000 // 4096 <= distance_steps <= 2000 * 2000 // 4096 + 10, distance_steps
    assert 100 < jaro_steps < 2000 * 2000 // 4096, jaro_steps
    limits = [(before + distance_steps // 2, "edit_distance"), (before + distance_steps + jaro_steps // 2, "jaro")]
    for limit, call in limits:
        result = run_vm(bytecode, "--json", "--max-steps", str(limit), args=["1000"])
        assert result.code == 1, result.stderr
        diagnostic = json.loads(result.stderr)
        assert diagnostic["code"] == "RUNTIME-STEP-LIMIT"
        assert call in covered(STEPS, diagnostic["range"])
