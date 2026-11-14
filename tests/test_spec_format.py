"""format(...), Ruby's Kernel#format (#982), through the product CLI: `--json check FILE`, asserting the code and the
source text that the range covers, never the message.

The format string is a one-line string literal that the checker reads: a bad conversion is CHECK-FORMAT-SPEC at its
characters, a format that only puts values in the text is CHECK-FORMAT-SPEC at the literal, a format that is not such a
literal is CHECK-FORMAT-LITERAL, the count of arguments is CHECK-ARITY and an argument of the wrong type is
CHECK-TYPE-MISMATCH with a label at its conversion. The fixture tests/fixtures/vm/format.agc runs the conversions,
against a Python and a Node peer."""
import pytest

from tests.agentica_test import FIXTURES, PYTHON, cli, run, tool, vm_environment
from tests.spec_support import Batch, covered


def program(body):
    return "def main() -> Void\n  %s\nend\n" % body.replace("\n", "\n  ")


# Programs that check: the conversions and flags, %% next to a conversion, and the name format for a variable, a
# parameter and a field, which only a def may not take.
ACCEPTED = {
    "conversions": program('puts(format("%-8s|%6.2f|%03d|%x|%f|%5s|%d", "a", 2.5, 7, 255, 1.0, [1], 3))'),
    "percent": program('puts(format("%5.1f%%", 99.5))'),
    "escapes": program('puts(format("\\"%5d\\"\\n", 1))'),
    "result_type": program('s: String = format("%x", 255)\nputs(s.length)'),
    "variable": program('format = "x"\nputs(format)'),
    "parameter": 'def f(format: String) -> String = format\n\ndef main() -> Void\n  puts(f("x"))\nend\n',
    "field": 'struct Opts\n  format: String\nend\n\ndef main() -> Void\n  puts(Opts(format: "x").format)\nend\n',
}

# Programs that do not check: the code, the source text the range covers, and the number of labels when it matters.
REJECTED = {
    "not_literal": (program('f = "%5d"\nputs(format(f, 1))'), "CHECK-FORMAT-LITERAL", "f"),
    "interpolated": (program('x = 1\nputs(format("#{x}%5d", 1))'), "CHECK-FORMAT-LITERAL", '"#{x}%5d"'),
    "heredoc": (program('puts(format(<<~T, 1))\n  %5d\n  and more\nT'), "CHECK-FORMAT-LITERAL", None),
    "no_arguments": (program("puts(format())"), "CHECK-ARITY", "format()"),
    "unknown_type": (program('puts(format("%5q", 1))'), "CHECK-FORMAT-SPEC", "%5q"),
    "upper_hex": (program('puts(format("%X", 1))'), "CHECK-FORMAT-SPEC", "%X"),
    "plus_flag": (program('puts(format("%+5d", 1))'), "CHECK-FORMAT-SPEC", "%+"),
    "space_flag": (program('puts(format("% d", 1))'), "CHECK-FORMAT-SPEC", "% "),
    "trailing_percent": (program('puts(format("%5d %", 1))'), "CHECK-FORMAT-SPEC", "%"),
    "precision_on_d": (program('puts(format("%.2d", 1))'), "CHECK-FORMAT-SPEC", "%.2d"),
    "precision_on_s": (program('puts(format("%5.2s", "a"))'), "CHECK-FORMAT-SPEC", "%5.2s"),
    "zero_on_s": (program('puts(format("%05s", "a"))'), "CHECK-FORMAT-SPEC", "%05s"),
    "width_too_big": (program('puts(format("%1001d", 1))'), "CHECK-FORMAT-SPEC", "%1001"),
    "precision_too_big": (program('puts(format("%.51f", 1.0))'), "CHECK-FORMAT-SPEC", "%.51"),
    "after_escapes": (program('puts(format("a\\"\\t%5d %y", 1))'), "CHECK-FORMAT-SPEC", "%y"),
    "only_bare": (program('puts(format("%s and %d", "a", 1))'), "CHECK-FORMAT-SPEC", '"%s and %d"'),
    "no_conversion": (program('puts(format("abc %%"))'), "CHECK-FORMAT-SPEC", '"abc %%"'),
    "too_few": (program('puts(format("%5d %5d", 1))'), "CHECK-ARITY", 'format("%5d %5d", 1)'),
    "too_many": (program('puts(format("%5d", 1, 2))'), "CHECK-ARITY", "2"),
    "float_for_d": (program('puts(format("%5d", 1.5))'), "CHECK-TYPE-MISMATCH", "1.5", 1),
    "int_for_f": (program('puts(format("%5.1f", 2))'), "CHECK-TYPE-MISMATCH", "2", 1),
    "string_for_x": (program('puts(format("%x", "ff"))'), "CHECK-TYPE-MISMATCH", '"ff"', 1),
    "no_to_s": (program('f = ->(x: Int) { x }\nputs(format("%5s", f))'), "CHECK-TYPE-MISMATCH", "f", 1),
    "def_format": (
        'def format(x: Int) -> Int = x\n\ndef main() -> Void\n  puts(format(1))\nend\n',
        "CHECK-REDEFINED-NAME",
        "def format(x: Int) -> Int = x\n",
    ),
    # The forms of other languages and the old ways to write digits name format in their help.
    "sprintf": (program('puts(sprintf("%5d", 1))'), "CHECK-UNKNOWN-NAME", 'sprintf("%5d", 1)'),
    "string_format": (program('puts("%5d".format(1))'), "CHECK-UNKNOWN-METHOD", '"%5d".format(1)'),
    "string_modulo": (program('puts("%5d" % 1)'), "CHECK-TYPE-MISMATCH", "%"),
    "to_fixed": (program("puts(2.5.to_fixed(2))"), "CHECK-UNKNOWN-METHOD", "2.5.to_fixed(2)"),
    "round_digits": (program("puts(2.5.round(2))"), "CHECK-ARITY", "2.5.round(2)"),
}

HELPED = {"sprintf", "string_format", "string_modulo", "to_fixed", "round_digits", "only_bare", "no_conversion"}


BATCH = Batch("program.agc")


@BATCH.table("source", list(ACCEPTED.values()))
def test_a_valid_format_checks(checked, source):
    assert checked(source) is None


@BATCH.table("name", list(REJECTED), lambda name: REJECTED[name][0])
def test_a_bad_format_is_reported_where_it_is(checked, name):
    source, code, covers, *labels = REJECTED[name]
    found = checked(source)
    assert (found and found["code"]) == code, source
    if covers is not None:
        assert covered(source, found["range"]) == covers, source
    if labels:
        assert len(found.get("labels", [])) == labels[0], found
    if name in HELPED:
        assert found.get("help"), found


checked = BATCH.fixture()


def test_the_fixture_prints_what_the_python_and_node_peers_print():
    fixture = FIXTURES / "vm" / "format.agc"
    result = run(cli() + [str(fixture)], env=vm_environment())
    assert result.code == 0, result.stderr
    python = run([PYTHON, str(FIXTURES / "format-peer.py")])
    node = run([tool("node"), str(FIXTURES / "format-peer.js")])
    assert (python.code, node.code) == (0, 0)
    assert result.stdout == python.stdout == node.stdout
