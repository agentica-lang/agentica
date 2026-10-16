import json

from tests.agentica_test import TestCase, cli, output_lines, run, vm_environment


class SpecAliasTest(TestCase):
    def setUp(self):
        self.work = self.make_temp_dir()

    def check(self, text, name="main.agc"):
        path = self.work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        result = run(cli() + ["--json", "check", str(path)])
        if result.code == 0:
            return None
        self.assertEqual(result.code, 1, result.stderr)
        return json.loads(result.stderr)

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
        self.assertEqual(found["range"]["start"]["line"], 1)

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
        for text, code in [
            (constructor, "CHECK-UNKNOWN-TYPE"),
            (pattern, "CHECK-PATTERN-TYPE"),
        ]:
            with self.subTest(code=code):
                found = self.check(text)
                self.assertEqual(found["code"], code)
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
