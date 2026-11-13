"""JSON.decode into a List[T] or a Map[String, T] (docs/grammar/06b-builtins.md, "JSON") through the product CLI:
`--json check FILE`, asserting the code and the source text the range covers, never the message. The run-time forms
are in the VM golden json-list-vectors.
"""
import pytest

from tests.agentica_test import cli, run
from tests.spec_support import assert_rule, check_diagnostic

HEAD = """struct Raw
  file: String
  line: Optional[Int]
end

enum Color
  Red
  Blue
end

"""


def main_with(body):
    return HEAD + "def main() -> Void\n" + body + "end\n"


# (name, program, code, covered text or None). A program that checks clean has the code None.
CASES = [
    (
        "decode takes a List or a Map from String of a decodable type, nested too",
        main_with(
            '  rows: Result[List[Raw]] = JSON.decode("[]", List[Raw])\n'
            '  by_file: Result[Map[String, Raw]] = JSON.decode("{}", Map[String, Raw])\n'
            '  colors: Result[List[Color]] = JSON.decode(JSON.parse("[]").unwrap!, List[Color])\n'
            '  grid: Result[List[Map[String, List[Int]]]] = JSON.decode("[]", List[Map[String, List[Int]]])\n'
            "  puts([rows.ok?, by_file.ok?, colors.ok?, grid.ok?])\n"
        ),
        None,
        None,
    ),
    (
        "a constant written in capitals is still indexed",
        "LIMITS = [1, 2]\n\ndef main() -> Void\n  puts(LIMITS[0])\nend\n",
        None,
        None,
    ),
    (
        "decode refuses a Map whose keys are not String",
        main_with('  puts(JSON.decode("{}", Map[Int, Raw]))\n'),
        "CHECK-NOT-DECODABLE",
        "Map[Int, Raw]",
    ),
    (
        "decode refuses a List of a type JSON cannot build",
        main_with('  puts(JSON.decode("[]", List[Set[Int]]))\n'),
        "CHECK-NOT-DECODABLE",
        "List[Set[Int]]",
    ),
    (
        "a JSON.Field as the item of a List target is no JSON field",
        main_with('  puts(JSON.decode("[]", List[JSON.Field[Int]]))\n'),
        "CHECK-JSON-FIELD-PLACE",
        "List[JSON.Field[Int]]",
    ),
    (
        "an unknown item type is reported at its name",
        main_with('  puts(JSON.decode("[]", List[Nope]))\n'),
        "CHECK-UNKNOWN-TYPE",
        "Nope",
    ),
    (
        "schema takes a named type only",
        main_with("  puts(JSON.schema(List[Raw]))\n"),
        "CHECK-TYPE-MISMATCH",
        "List[Raw]",
    ),
    (
        "decode takes a List through an alias",
        "type Rows = List[Raw]\n\n" + main_with('  rows: Result[List[Raw]] = JSON.decode("[]", Rows)\n  puts(rows.ok?)\n'),
        None,
        None,
    ),
    (
        "schema refuses a List through an alias",
        "type Rows = List[Raw]\n\n" + main_with("  puts(JSON.schema(Rows))\n"),
        "CHECK-TYPE-MISMATCH",
        "Rows",
    ),
    (
        "codec refuses a List through an alias",
        "type Rows = List[Raw]\n\n" + main_with("  puts(Rows.codec.members)\n"),
        "CHECK-TYPE-MISMATCH",
        "Rows",
    ),
    (
        "schema refuses a List before it looks at its item",
        main_with("  puts(JSON.schema(List[Set[Int]]))\n"),
        "CHECK-TYPE-MISMATCH",
        "List[Set[Int]]",
    ),
    (
        "codec takes a named type only",
        main_with('  puts(List[Raw].codec.encode([]))\n'),
        "CHECK-TYPE-MISMATCH",
        "List[Raw]",
    ),
    (
        "members takes a named type only",
        main_with("  puts(List[Raw].members)\n"),
        "CHECK-TYPE-MISMATCH",
        "List[Raw]",
    ),
    (
        "a List type is no value outside a JSON type argument",
        main_with("  x = List[Raw]\n  puts(x)\n"),
        "CHECK-TYPE-MISMATCH",
        "List[Raw]",
    ),
]


@pytest.mark.parametrize("name, program, code, covers", CASES, ids=[case[0] for case in CASES])
def test_json_list_rules(name, program, code, covers, tmp_path):
    assert_rule(check_diagnostic(program, tmp_path), program, code, covers)


def test_a_list_of_an_imported_type_decodes_through_its_alias(tmp_path):
    """The linker resolves the type arguments: the alias counts as used, and the decode builds the imported struct."""
    (tmp_path / "rows.agc").write_text("struct Raw\n  file: String\nend\n", encoding="utf-8")
    root = tmp_path / "root.agc"
    root.write_text(
        'import Rows from "rows"\n\n'
        "def main() -> Void\n"
        '  puts(JSON.decode("[{\\"file\\": \\"a.c\\"}]", List[Rows.Raw]).unwrap!)\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(root)])
    assert result.code == 0, result.stderr
    assert result.stdout == '[Raw(file: "a.c")]\n'


def test_an_alias_decodes_as_the_type_it_names_alone_and_as_an_item(tmp_path):
    """The lowering names a target by the type the checker resolved, so an alias of a struct works in both places."""
    program = tmp_path / "program.agc"
    program.write_text(
        HEAD
        + "type Pair = Raw\n\n"
        "def main() -> Void\n"
        '  puts(JSON.decode("{\\"file\\": \\"a.c\\"}", Pair).unwrap!)\n'
        '  puts(JSON.decode("[{\\"file\\": \\"b.c\\"}]", List[Pair]).unwrap!)\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(program)])
    assert result.code == 0, result.stderr
    assert result.stdout == 'Raw(file: "a.c", line: none)\n[Raw(file: "b.c", line: none)]\n'


def test_aliases_of_a_list_and_of_an_enum_reach_their_types(tmp_path):
    """An alias of a List decodes as the List, and the codec of an alias of an enum that nothing else names finds it."""
    program = tmp_path / "program.agc"
    program.write_text(
        "struct Raw\n  file: String\nend\n\nenum Color\n  Red\n  Blue\nend\n\n"
        "type Rows = List[Raw]\n\ntype Hue = Color\n\n"
        "def main() -> Void\n"
        '  puts(JSON.decode("[{\\"file\\": \\"a.c\\"}]", Rows).unwrap!)\n'
        '  puts(Hue.codec.decode("{\\"tag\\": \\"Red\\"}").unwrap!)\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(program)])
    assert result.code == 0, result.stderr
    assert result.stdout == '[Raw(file: "a.c")]\nColor.Red\n'
