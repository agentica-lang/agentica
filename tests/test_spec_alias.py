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
    text = """\
struct Holder
  type: Int
end

def type(value: Int) -> Int
  return value
end

def echo(type: Int) -> Int
  return type
end

def main() -> Void
  type = 7
  holder = Holder(type: type)
  puts(type(echo(holder.type)))
end

"""
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
    ],
)
def test_alias_collision_unknown_target_constructor_and_arguments(
    text, code, agentica_check
):
    found = agentica_check(text)
    assert found is not None
    assert found["code"] == code


def test_plain_alias_takes_no_arguments(agentica_check):
    text = "type Names = List[String]\n\ndef main() -> Void\n  names: Names[Int] = []\nend\n\n"
    assert_diagnostic(agentica_check(text), "CHECK-UNKNOWN-TYPE", (4, 10))


GENERIC = "type Matrix[T] = List[List[T]]\n\n"


def test_generic_alias_is_the_expanded_type_and_chains(agentica_check):
    text = (
        GENERIC
        + "type Grid = Matrix[Float]\n\n"
        + "type Unused[T] = Int\n\n"
        + "enum Tree[T]\n  Leaf(Matrix[T])\nend\n\n"
        + "def main() -> Void\n"
        + "  m: Matrix[Int] = [[1]]\n"
        + "  plain: List[List[Int]] = m\n"
        + "  grid: Grid = [[1.5]]\n"
        + "  nested: Matrix[Matrix[Int]] = [[[[1]]]]\n"
        + "  tree = Tree.Leaf(plain)\n"
        + "  puts(plain.size + grid.size + nested.size)\n"
        + "end\n\n"
    )
    assert agentica_check(text) is None


def test_exported_generic_alias_imports_by_name_and_qualified_name(
    tmp_path, agentica_check
):
    (tmp_path / "shapes.agc").write_text(
        "export type Matrix[T] = List[List[T]]\n", encoding="utf-8"
    )
    text = (
        'import Shapes from "shapes"\n'
        'import {Matrix as M} from "shapes"\n\n'
        "def main() -> Void\n"
        "  a: Shapes.Matrix[Int] = [[1]]\n"
        "  b: M[Int] = a\n"
        "  puts(b.size)\n"
        "end\n\n"
    )
    assert agentica_check(text) is None


@pytest.mark.parametrize(
    ("use", "start"),
    [
        ("Matrix", (3, 10)),
        ("Matrix[Int, Int]", (3, 10)),
        ("List[Matrix]", (3, 15)),
    ],
)
def test_generic_alias_needs_exactly_its_arguments(use, start, agentica_check):
    text = GENERIC + f"def f(m: {use}) -> Void\nend\n\n"
    assert_diagnostic(agentica_check(text), "CHECK-UNKNOWN-TYPE", start)


@pytest.mark.parametrize(
    ("text", "code", "start"),
    [
        ("type Box[T, T] = List[T]\n\n", "CHECK-REDEFINED-NAME", (1, 1)),
        ("type Box[Int] = List[Int]\n\n", "CHECK-REDEFINED-NAME", (1, 1)),
        ("type Box[T] = List[U]\n\n", "CHECK-UNKNOWN-TYPE", (1, 20)),
        ("type Box[T] = List[T][T]\n\n", "PARSE-UNEXPECTED-TOKEN", (1, 22)),
        ("type Box[] = List[Int]\n\n", "PARSE-UNEXPECTED-TOKEN", (1, 10)),
        ("type Box[t] = List[Int]\n\n", "PARSE-UNEXPECTED-TOKEN", (1, 10)),
        ("type Box[T] = List[Box[T]]\n\n", "CHECK-TYPE-ALIAS-CYCLE", (1, 20)),
        (
            "type Left[T] = Right[T]\n\ntype Right[T] = Left[List[T]]\n\n",
            "CHECK-TYPE-ALIAS-CYCLE",
            (1, 16),
        ),
        (
            "type Box[T] = List[T]\n\ntype Index[K] = Map[K, Int]\n\n"
            "def f(i: Index[Box[Int]]) -> Void\nend\n\n",
            "CHECK-MAP-KEY-TYPE",
            (5, 16),
        ),
        ("type B[T] = Map[Float, T]\n\n", "CHECK-MAP-KEY-TYPE", (1, 17)),
        ("type Ap[F] = F[Int]\n\n", "CHECK-UNKNOWN-TYPE", (1, 14)),
    ],
)
def test_generic_alias_declaration_errors(text, code, start, agentica_check):
    found = agentica_check(text + "def main() -> Void\nend\n\n")
    assert_diagnostic(found, code, start)


@pytest.mark.parametrize(
    ("body", "code", "start"),
    [
        ("  figure = Figure.Circle(1)\n", "CHECK-UNKNOWN-TYPE", (8, 12)),
        (
            "  figure: Figure[Int] = Shape.Circle(1)\n"
            "  case figure\n"
            "    Figure.Circle(radius) -> puts(radius)\n"
            "  end\n",
            "CHECK-PATTERN-TYPE",
            (10, 5),
        ),
    ],
)
def test_generic_enum_aliases_are_not_variant_constructors_or_patterns(
    body, code, start, agentica_check
):
    prefix = "enum Shape[T]\n  Circle(T)\nend\n\ntype Figure[T] = Shape[T]\n\n"
    found = agentica_check(prefix + "def main() -> Void\n" + body + "end\n\n")
    assert_diagnostic(found, code, start)
    assert "Shape[T].Circle" in json.dumps(found)


@pytest.mark.parametrize(
    ("text", "code", "start"),
    [
        (
            "type Index[K] = Map[K, Int]\n\ndef f(i: Index[Float]) -> Void\nend\n\n",
            "CHECK-MAP-KEY-TYPE",
            (3, 16),
        ),
        (
            "type S[T] = Set[T]\n\ndef f(s: S[Float]) -> Void\nend\n\n",
            "CHECK-SET-ELEMENT-TYPE",
            (3, 12),
        ),
        (
            "type Index[K] = Map[K, Int]\n\nenum E[T]\n  V(Index[T])\nend\n\n",
            "CHECK-MAP-KEY-TYPE",
            (4, 11),
        ),
        (
            "type Id[T] = T\n\ndef f(x: Id[Void]) -> Void\nend\n\n",
            "CHECK-VOID-TYPE",
            (3, 13),
        ),
    ],
)
def test_arguments_are_judged_where_the_parameter_lands(text, code, start, agentica_check):
    found = agentica_check(text + "def main() -> Void\nend\n\n")
    assert_diagnostic(found, code, start)


@pytest.mark.parametrize(
    ("use", "code", "start"),
    [
        ("Unused[Nope]", "CHECK-UNKNOWN-TYPE", (3, 17)),
        ("Unused[Map[List[Int], Int]]", "CHECK-MAP-KEY-TYPE", (3, 21)),
    ],
)
def test_argument_of_an_unused_parameter_is_still_checked(use, code, start, agentica_check):
    text = f"type Unused[T] = Int\n\ndef f(x: {use}) -> Void\nend\n\ndef main() -> Void\nend\n\n"
    assert_diagnostic(agentica_check(text), code, start)


def test_argument_of_an_unused_parameter_may_be_void(agentica_check):
    text = "type Unused[T] = Int\n\ndef f(x: Unused[Void]) -> Void\nend\n\ndef main() -> Void\nend\n\n"
    assert agentica_check(text) is None


def test_generic_alias_in_a_struct_field_a_constant_and_a_lambda(agentica_check):
    text = (
        "ORIGIN: Matrix[Int] = [[0]]\n\n"
        "type Matrix[T] = List[List[T]]\n\n"
        "type Row[T] = List[T]\n\n"
        "struct Board\n  cells: Matrix[Int]\nend\n\n"
        "def main() -> Void\n"
        "  board = Board(cells: ORIGIN)\n"
        "  sizes = [[1], [2]].map do |row: Row[Int]| row.size end\n"
        "  puts(board.cells.size + sizes.size)\n"
        "end\n\n"
    )
    assert agentica_check(text) is None


@pytest.mark.parametrize(
    ("old", "new", "start"),
    [
        ("ORIGIN: Matrix[Int] = [[0]]", 'ORIGIN: Matrix[Int] = [["a"]]', (1, 25)),
        ("Board(cells: ORIGIN)", 'Board(cells: [["a"]])', (12, 26)),
        ("row: Row[Int]", "row: Row[String]", (13, 11)),
    ],
)
def test_generic_alias_types_are_enforced_in_fields_constants_and_lambdas(
    old, new, start, agentica_check
):
    text = (
        "ORIGIN: Matrix[Int] = [[0]]\n\n"
        "type Matrix[T] = List[List[T]]\n\n"
        "type Row[T] = List[T]\n\n"
        "struct Board\n  cells: Matrix[Int]\nend\n\n"
        "def main() -> Void\n"
        "  board = Board(cells: ORIGIN)\n"
        "  sizes = [[1], [2]].map do |row: Row[Int]| row.size end\n"
        "  puts(board.cells.size + sizes.size)\n"
        "end\n\n"
    )
    assert_diagnostic(agentica_check(text.replace(old, new)), "CHECK-TYPE-MISMATCH", start)


def test_identity_alias_is_its_argument(agentica_check):
    text = (
        "type Id[T] = T\n\n"
        "def echo(x: Id[Int], names: Id[List[String]]) -> Id[Int]\n"
        "  return x + names.size\n"
        "end\n\n"
        "def main() -> Void\n"
        '  puts(echo(1, ["a"]))\n'
        "end\n\n"
    )
    assert agentica_check(text) is None


def test_chain_of_generic_aliases_is_bounded(agentica_check):
    aliases = ["type C0[T] = List[T]"]
    for index in range(1, 1002):
        aliases.append(f"type C{index}[T] = C{index - 1}[T]")
    text = "\n\n".join(aliases) + "\n\ndef f(x: C1001[Int]) -> Void\nend\n\ndef main() -> Void\nend\n\n"
    assert_diagnostic(agentica_check(text), "CHECK-TOO-DEEP", (1001, 16))


def test_copies_of_an_argument_count_against_the_expansion_limit(agentica_check):
    use = "Dup[Int]"
    for _ in range(11):
        use = f"Dup[{use}]"
    text = f"type Dup[T] = Fn[T, T]\n\ndef f(x: {use}) -> Void\nend\n\ndef main() -> Void\nend\n\n"
    assert_diagnostic(agentica_check(text), "CHECK-TOO-DEEP", (3, 10))


def test_parameter_named_like_an_alias_or_a_struct_is_the_parameter(agentica_check):
    for head in ("type Foo = Int\n\n", "struct Foo\n  n: Int\nend\n\n"):
        text = (
            head
            + "type Box[Foo] = List[Foo]\n\n"
            + "def main() -> Void\n"
            + '  a: Box[String] = ["a"]\n'
            + "  puts(a.size)\n"
            + "end\n\n"
        )
        assert agentica_check(text) is None
    wrong = "type Foo = Int\n\ntype Box[Foo] = List[Foo]\n\ndef main() -> Void\n  a: Box[String] = [1]\nend\n\n"
    assert_diagnostic(agentica_check(wrong), "CHECK-TYPE-MISMATCH", (6, 21))


def test_enum_parameter_does_not_capture_a_name_in_an_alias_target(agentica_check):
    text = (
        "struct Item\n  n: Int\nend\n\n"
        "type Items = List[Item]\n\n"
        "enum E[Item]\n  V(Items)\nend\n\n"
        "def main() -> Void\nend\n\n"
    )
    assert_diagnostic(agentica_check(text), "CHECK-UNKNOWN-TYPE", (8, 5))
