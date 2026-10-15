"""The source paths stored in an .agcb are relative to the project root (docs/future/35-self-hosting.md, 35.4).

The root is the folder of the entry file. The bytes must not depend on where
the project lives or on how the entry file is named on the command line, and a
runtime trace prints the stored path.
"""
import shutil

from tests.agentica_test import TestCase, compile_agc, run_vm, vm_environment

MAIN = """import Util from "lib/util"
import Shared from "../shared/x"

def main() -> Void
  puts(Util.twice(2).to_s)
  puts(Shared.name())
  xs = [1]
  puts(xs[3].to_s)
end
"""

UTIL = """export def twice(n: Int) -> Int
  return n * 2
end
"""

SHARED = """export def name() -> String
  return "shared"
end
"""


class SourcePathsTest(TestCase):
    def project(self):
        """A fresh copy of the program: app/main.agc, app/lib/util.agc and shared/x.agc above the root."""
        base = self.make_temp_dir()
        for name, text in (("app/main.agc", MAIN), ("app/lib/util.agc", UTIL), ("shared/x.agc", SHARED)):
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return base

    def test_bytes_do_not_depend_on_the_checkout_location(self):
        first, second = self.project(), self.project()
        self.assertNotEqual(first, second)
        one = compile_agc(first / "app" / "main.agc", first / "one.agcb").read_bytes()
        two = compile_agc(second / "app" / "main.agc", second / "two.agcb").read_bytes()
        self.assertEqual(one, two)

    def test_bytes_do_not_depend_on_the_name_of_the_root_folder(self):
        first, second = self.project(), self.project()
        shutil.move(str(second / "app"), str(second / "renamed"))
        one = compile_agc(first / "app" / "main.agc", first / "one.agcb").read_bytes()
        two = compile_agc(second / "renamed" / "main.agc", second / "two.agcb").read_bytes()
        self.assertEqual(one, two)

    def test_stored_paths(self):
        base = self.project()
        data = compile_agc(base / "app" / "main.agc", base / "out.agcb").read_bytes()
        for stored in (b"main.agc", b"lib/util.agc", b"../shared/x.agc"):
            self.assertIn(stored, data)
        self.assertNotIn(str(base).encode(), data)

    def test_runtime_trace_prints_the_stored_path(self):
        base = self.project()
        bytecode = compile_agc(base / "app" / "main.agc", base / "out.agcb")
        result = run_vm(bytecode, env=vm_environment())
        self.assertEqual(result.code, 1)
        self.assertEqual(result.stdout, "4\nshared\n")
        self.assertRegex(result.stderr, r"^main\.agc:\d+:\d+ error\[RUNTIME-INDEX-OUT-OF-RANGE\]")
        self.assertNotIn(str(base), result.stderr)
