"""`s * n`, Ruby's String#*, through the product CLI: the type rule (a String first, an Int count second), the runtime
errors of a bad count at the count, and the repeated text against Python's own `str * int` as the peer.
"""

import json

import pytest

from tests.agentica_test import cli, run
from tests.spec_support import assert_rule, covered

MAIN = "def main() -> Void\n"

RULES = [
    # A String times an Int is a String, in an expression, a compound assignment and a constant.
    (
        'LINE = "-" * 3\n\n' + MAIN + '  s: String = "ab" * 2\n  s *= 2\n  puts(s + LINE)\nend\n',
        None,
        None,
    ),
    # The count comes second, as in Ruby, and it is an Int.
    (MAIN + '  puts(3 * "ab")\nend\n', "CHECK-TYPE-MISMATCH", "*"),
    (MAIN + '  puts("ab" * "c")\nend\n', "CHECK-TYPE-MISMATCH", "*"),
    (MAIN + '  puts("ab" * 1.5)\nend\n', "CHECK-TYPE-MISMATCH", "*"),
    (MAIN + '  s = "ab"\n  s *= "c"\n  puts(s)\nend\n', "CHECK-TYPE-MISMATCH", None),
    # The other arithmetic stays off String.
    (MAIN + '  puts("ab" - 1)\nend\n', "CHECK-TYPE-MISMATCH", "-"),
]


@pytest.mark.parametrize(("program", "code", "text"), RULES)
def test_string_repeat_rules(agentica_check, program, code, text):
    assert_rule(agentica_check(program), program, code, text)


CASES = [("ab", n) for n in range(0, 10)] + [
    ("", 5),
    ("é€😀", 3),
    ("xyz", 1000),
    ("a\tb", 37),
    ("q", 4097),
]


def test_string_repeat_matches_python(tmp_path):
    lines = [f'  puts(("{text}" * {count}).inspect)' for text, count in CASES]
    path = tmp_path / "repeat.agc"
    path.write_text(MAIN + "\n".join(lines) + "\nend\n", encoding="utf-8")
    result = run(cli() + [str(path)])
    assert result.code == 0, result.stderr
    # Python's json.dumps escapes as Agentica's inspect does for these texts: a tab as \t, the rest as is.
    expected = [json.dumps(text * count, ensure_ascii=False) for text, count in CASES]
    assert result.stdout.splitlines() == expected


@pytest.mark.parametrize(
    "count",
    [
        "0 - 1",
        "-9223372036854775807 - 1",
        # 2 bytes times 2^27 is 256 MiB, the most a repeat makes; one more copy is over it.
        "134217729",
        "9223372036854775807",
    ],
)
def test_string_repeat_bad_count(tmp_path, count):
    source = MAIN + f'  n = {count}\n  puts("ab" * n)\nend\n'
    path = tmp_path / "bad.agc"
    path.write_text(source, encoding="utf-8")
    result = run(cli() + ["--json", str(path)])
    assert result.code == 1
    found = json.loads(result.stderr)
    assert found["code"] == "RUNTIME-INVALID-COUNT"
    assert covered(source, found["range"]) == "n"
