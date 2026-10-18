import json

from tests.agentica_test import TestCase, cli, output_lines, run, vm_environment
from tests.spec_support import json_diagnostic


class SpecAliasTest(TestCase):
    def setUp(self):
        self.work = self.make_temp_dir()

    def check(self, text, name="main.agc"):
        return json_diagnostic(self, self.work, text, name)

    def assert_diagnostic(self, text, code, start):
        found = self.check(text)
        self.assertEqual(found["code"], code)
        self.assertEqual(
            (found["range"]["start"]["line"], found["range"]["start"]["column"]),
            start,
        )
        return found

    def test_aliases_are_transparent_and_can_be_chained(self):
        text = (
            "type Names = List[String]\n\n"
            "type MoreNames = Names\n\n"
            "def echo(names: MoreNames) -> Names\n"
            "  return names\n"
            "end\n\n"
            "def main() -> Void\n"
            "  names: MoreNames = [\"Ada\"]\n"
            "  puts(echo(names).size)\n"
            "end\n\n"
        )
        self.assertIsNone(self.check(text))

    def test_alias_types_run_as_the_expanded_type(self):
        text = (
            "type Names = List[String]\n\n"
            "def main() -> Void\n"
            "  names: Names = [\"Ada\", \"Lin\"]\n"
            "  puts(names.size)\n"
            "end\n\n"
        )
        path = self.work / "main.agc"
        path.write_text(text, encoding="utf-8")
        result = run(cli() + [str(path)], env=vm_environment())
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(output_lines(result.stdout), ["2"])

    def test_exported_alias_imports_by_name_and_qualified_name(self):
        (self.work / "models.agc").write_text(
            "export type Names = List[String]\n", encoding="utf-8"
        )
        text = (
            'import Models from "models"\n'
            'import {Names as Labels} from "models"\n\n'
            "def main() -> Void\n"
            "  a: Models.Names = [\"a\"]\n"
            "  b: Labels = a\n"
            "  puts(b.size)\n"
            "end\n\n"
        )
        self.assertIsNone(self.check(text))

    def test_exported_alias_can_name_a_private_struct(self):
        (self.work / "models.agc").write_text(
            "struct User\n  name: String\nend\n\n"
            "export type Person = User\n\n"
            "export def person() -> Person\n"
            "  return User(name: \"Ada\")\n"
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
        self.assertIsNone(self.check(text))

    def test_private_alias_cannot_be_imported(self):
        (self.work / "models.agc").write_text("type Names = List[String]\n", encoding="utf-8")
        found = self.check('import {Names} from "models"\n\ndef main() -> Void\nend\n\n')
        self.assertEqual(found["code"], "CHECK-IMPORT-NAME")

    def test_alias_cycle_points_to_the_reference_that_closes_it(self):
        text = "type First = Second\n\ntype Second = First\n\ndef main() -> Void\nend\n\n"
        found = self.check(text)
        self.assertEqual(found["code"], "CHECK-TYPE-ALIAS-CYCLE")
        self.assertEqual(
            (found["range"]["start"]["line"], found["range"]["start"]["column"]),
            (1, 14),
        )

    def test_alias_name_collision_points_to_the_name(self):
        text = "type Names = Int\n\ntype Names = String\n\ndef main() -> Void\nend\n\n"
        found = self.check(text)
        self.assertEqual(found["code"], "CHECK-REDEFINED-NAME")
        self.assertEqual(
            (found["range"]["start"]["line"], found["range"]["start"]["column"]),
            (3, 6),
        )

    def test_type_is_an_ordinary_name_outside_alias_declarations(self):
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
        self.assertIsNone(self.check(text))

    def test_malformed_alias_declarations_report_the_code_and_span(self):
        cases = [
            ("type\n", "PARSE-UNEXPECTED-TOKEN", (1, 5)),
            ("type X\n", "PARSE-UNEXPECTED-TOKEN", (1, 7)),
            ("type X =\n", "PARSE-UNEXPECTED-TOKEN", (1, 9)),
            ("type x = Int\n", "PARSE-UNEXPECTED-TOKEN", (1, 6)),
            ("export type\n", "PARSE-UNEXPECTED-TOKEN", (1, 12)),
            ("type X = Int = 3\n", "PARSE-UNEXPECTED-TOKEN", (1, 14)),
            ("type X = Nope\n\ndef main() -> Void\nend\n\n", "CHECK-UNKNOWN-TYPE", (1, 10)),
            (
                "def main() -> Void\n  type X = Int\nend\n\n",
                "PARSE-TOP-LEVEL-STATEMENT",
                (2, 3),
            ),
        ]
        for text, code, start in cases:
            with self.subTest(text=text):
                self.assert_diagnostic(text, code, start)

    def test_expanded_type_errors_point_to_the_alias_use(self):
        cases = [
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
        ]
        for text, code, start in cases:
            with self.subTest(code=code):
                self.assert_diagnostic(text, code, start)

    def test_repeated_alias_expansion_is_bounded(self):
        aliases = ["type T0 = Int"]
        for index in range(1, 17):
            prior = f"T{index - 1}"
            aliases.append(f"type T{index} = Fn[{prior}, {prior}]")
        text = "\n\n".join(aliases) + "\n\ndef main() -> Void\nend\n\n"
        found = self.check(text)
        self.assertEqual(found["code"], "CHECK-TOO-DEEP")
        self.assertEqual(
            (found["range"]["start"]["line"], found["range"]["start"]["column"]),
            (17, 18),
        )

    def test_enum_aliases_are_not_variant_constructors_or_patterns(self):
        prefix = "enum Shape\n  Circle(Int)\nend\n\ntype Figure = Shape\n\n"
        constructor = prefix + (
            "def main() -> Void\n"
            "  figure = Figure.Circle(1)\n"
            "end\n\n"
        )
        pattern = prefix + (
            "def main() -> Void\n"
            "  figure: Figure = Shape.Circle(1)\n"
            "  case figure\n"
            "    Figure.Circle(radius) -> puts(radius)\n"
            "  end\n"
            "end\n\n"
        )
        for text, code, start in [
            (constructor, "CHECK-UNKNOWN-TYPE", (8, 12)),
            (pattern, "CHECK-PATTERN-TYPE", (10, 5)),
        ]:
            with self.subTest(code=code):
                found = self.assert_diagnostic(text, code, start)
                self.assertIn("Shape.Circle", json.dumps(found))

    def test_alias_collision_unknown_target_constructor_and_arguments(self):
        cases = [
            ("type Names = List[String]\n\ntype Names = Int\n\ndef main() -> Void\nend\n\n", "CHECK-REDEFINED-NAME"),
            ("type Names = Missing\n\ndef main() -> Void\nend\n\n", "CHECK-UNKNOWN-TYPE"),
            (
                "struct User\n  name: String\nend\n\ntype Account = User\n\ndef main() -> Void\n  a = Account(name: \"Ada\")\nend\n\n",
                "CHECK-UNKNOWN-TYPE",
            ),
            (
                "type Names = List[String]\n\ndef main() -> Void\n  names: Names[Int] = []\nend\n\n",
                "CHECK-UNKNOWN-TYPE",
            ),
        ]
        for text, code in cases:
            with self.subTest(code=code, text=text):
                found = self.check(text)
                self.assertIsNotNone(found)
                self.assertEqual(found["code"], code)
