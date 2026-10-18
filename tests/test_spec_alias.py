"""Alias rules through the product CLI, including diagnostic codes and spans."""

import json

import pytest

from tests.agentica_test import cli, output_lines, run, vm_environment


def assert_diagnostic(found: dict[str, object] | None, code: str, start: tuple[int, int]) -> None:
    assert found is not None
    assert found["code"] == code
    position = found["range"]["start"]
    assert (position["line"], position["column"]) == start


def test_aliases_are_transparent_and_can_be_chained(agentica_check):
    text = (
        "type Names = List[String]\n\n"
        "type MoreNames = Names\n\n"
        "def echo(names: MoreNames) -> Names\n"
        "  return names\n"
        "end\n\n"
        "def main() -> Void\n"
        '  names: MoreNames = ["Ada"]\n'
        "  puts(echo(names).size)\n"
        "end\n\n"
    )
    assert agentica_check(text) is None


def test_alias_types_run_as_the_expanded_type(tmp_path):
    text = (
        "type Names = List[String]\n\n"
        "def main() -> Void\n"
        '  names: Names = ["Ada", "Lin"]\n'
        "  puts(names.size)\n"
        "end\n\n"
    )
    path = tmp_path / "main.agc"
    path.write_text(text, encoding="utf-8")
    result = run(cli() + [str(path)], env=vm_environment())
    assert result.code == 0, result.stderr
    assert output_lines(result.stdout) == ["2"]


def test_exported_alias_imports_by_name_and_qualified_name(tmp_path, agentica_check):
    (tmp_path / "models.agc").write_text(
        "export type Names = List[String]\n", encoding="utf-8"
    )
    text = (
        'import Models from "models"\n'
        'import {Names as Labels} from "models"\n\n'
        "def main() -> Void\n"
        '  a: Models.Names = ["a"]\n'
        "  b: Labels = a\n"
        "  puts(b.size)\n"
        "end\n\n"
    )
    assert agentica_check(text) is None


def test_exported_alias_can_name_a_private_struct(tmp_path, agentica_check):
    (tmp_path / "models.agc").write_text(
        "struct User\n  name: String\nend\n\n"
        "export type Person = User\n\n"
        "export def person() -> Person\n"
        '  return User(name: "Ada")\n'
        "end\n",
        encoding="utf-8",
    )
    text = (
        'import Models from "models"\n\n'
        "def main() -> Void\n"
        "  person = Models.person()\n"
        "  puts(person.name)\n"
        "end\n\n"
    )
    assert agentica_check(text) is None


def test_private_alias_cannot_be_imported(tmp_path, agentica_check):
    (tmp_path / "models.agc").write_text(
        "type Names = List[String]\n", encoding="utf-8"
    )
    found = agentica_check('import {Names} from "models"\n\ndef main() -> Void\nend\n\n')
    assert found["code"] == "CHECK-IMPORT-NAME"


def test_alias_cycle_points_to_the_reference_that_closes_it(agentica_check):
    text = "type First = Second\n\ntype Second = First\n\ndef main() -> Void\nend\n\n"
    assert_diagnostic(agentica_check(text), "CHECK-TYPE-ALIAS-CYCLE", (1, 14))


def test_alias_name_collision_points_to_the_name(agentica_check):
    text = "type Names = Int\n\ntype Names = String\n\ndef main() -> Void\nend\n\n"
    assert_diagnostic(agentica_check(text), "CHECK-REDEFINED-NAME", (3, 6))


def test_type_is_an_ordinary_name_outside_alias_declarations(agentica_check):
    text = (
        "struct Holder\n"
        "  type: Int\n"
        "end\n\n"
        "def type(value: Int) -> Int\n"
        "  return value\n"
        "end\n\n"
        "def echo(type: Int) -> Int\n"
        "  return type\n"
        "end\n\n"
        "def main() -> Void\n"
        "  type = 7\n"
        "  holder = Holder(type: type)\n"
        "  puts(type(echo(holder.type)))\n"
        "end\n\n"
    )
    assert agentica_check(text) is None


@pytest.mark.parametrize(
    ("text", "code", "start"),
    [
        ("type\n", "PARSE-UNEXPECTED-TOKEN", (1, 5)),
        ("type X\n", "PARSE-UNEXPECTED-TOKEN", (1, 7)),
        ("type X =\n", "PARSE-UNEXPECTED-TOKEN", (1, 9)),
        ("type x = Int\n", "PARSE-UNEXPECTED-TOKEN", (1, 6)),
        ("export type\n", "PARSE-UNEXPECTED-TOKEN", (1, 12)),
        ("type X = Int = 3\n", "PARSE-UNEXPECTED-TOKEN", (1, 14)),
        (
            "type X = Nope\n\ndef main() -> Void\nend\n\n",
            "CHECK-UNKNOWN-TYPE",
            (1, 10),
        ),
        (
            "def main() -> Void\n  type X = Int\nend\n\n",
            "PARSE-TOP-LEVEL-STATEMENT",
            (2, 3),
        ),
    ],
)
def test_malformed_alias_declarations_report_the_code_and_span(
    text, code, start, agentica_check
):
    assert_diagnostic(agentica_check(text), code, start)


@pytest.mark.parametrize(
    ("text", "code", "start"),
    [
        (
            "type Value = Void\n\ndef main() -> Void\n  values: List[Value] = []\nend\n\n",
            "CHECK-VOID-TYPE",
            (4, 16),
        ),
        (
            "type Key = List[Int]\n\ndef main() -> Void\n  values: Map[Key, Int] = {}\nend\n\n",
            "CHECK-MAP-KEY-TYPE",
            (4, 15),
        ),
    ],
)
def test_expanded_type_errors_point_to_the_alias_use(text, code, start, agentica_check):
    assert_diagnostic(agentica_check(text), code, start)


def test_repeated_alias_expansion_is_bounded(agentica_check):
    aliases = ["type T0 = Int"]
    for index in range(1, 17):
        prior = f"T{index - 1}"
        aliases.append(f"type T{index} = Fn[{prior}, {prior}]")
    text = "\n\n".join(aliases) + "\n\ndef main() -> Void\nend\n\n"
    assert_diagnostic(agentica_check(text), "CHECK-TOO-DEEP", (17, 18))


@pytest.mark.parametrize(
    ("body", "code", "start"),
    [
        (
            "  figure = Figure.Circle(1)\n",
            "CHECK-UNKNOWN-TYPE",
            (8, 12),
        ),
        (
            "  figure: Figure = Shape.Circle(1)\n"
            "  case figure\n"
            "    Figure.Circle(radius) -> puts(radius)\n"
            "  end\n",
            "CHECK-PATTERN-TYPE",
            (10, 5),
        ),
    ],
)
def test_enum_aliases_are_not_variant_constructors_or_patterns(
    body, code, start, agentica_check
):
    prefix = "enum Shape\n  Circle(Int)\nend\n\ntype Figure = Shape\n\n"
    text = prefix + "def main() -> Void\n" + body + "end\n\n"
    found = agentica_check(text)
    assert_diagnostic(found, code, start)
    assert "Shape.Circle" in json.dumps(found)


@pytest.mark.parametrize(
    ("text", "code"),
    [
        (
            "type Names = List[String]\n\ntype Names = Int\n\ndef main() -> Void\nend\n\n",
            "CHECK-REDEFINED-NAME",
        ),
        (
            "type Names = Missing\n\ndef main() -> Void\nend\n\n",
            "CHECK-UNKNOWN-TYPE",
        ),
        (
            "struct User\n  name: String\nend\n\ntype Account = User\n\ndef main() -> Void\n"
            '  a = Account(name: "Ada")\nend\n\n',
            "CHECK-UNKNOWN-TYPE",
        ),
        (
            "type Names = List[String]\n\ndef main() -> Void\n  names: Names[Int] = []\nend\n\n",
            "CHECK-UNKNOWN-TYPE",
        ),
    ],
)
def test_alias_collision_unknown_target_constructor_and_arguments(
    text, code, agentica_check
):
    found = agentica_check(text)
    assert found is not None
    assert found["code"] == code
