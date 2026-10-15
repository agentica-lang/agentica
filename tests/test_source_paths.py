"""The source paths stored in an .agcb are relative to the project root (docs/future/35-self-hosting.md, 35.4).

The root is the folder of the entry file. The bytes must not depend on where
the project lives or on how the entry file is named on the command line. A
runtime trace prints the stored name, and the CLI puts the entry's folder (as
seen from the working directory) before it with `agentica-vm --source-root`.
"""
import shutil

from tests.agentica_test import TestCase, cli, compile_agc, run, run_vm, vm_binary, vm_environment

MAIN = """import Util from "lib/util"
import Shared from "../shared/x"
import Logger from "std/logger"

def main() -> Void
  puts(Util.twice(2).to_s)
  puts(Shared.name())
  attached = Logger.attach("boom", LogLevel.Info, &Util.boom)
  Logger.info("go")
end
"""

UTIL = """import Shared from "../../shared/x"

export def twice(n: Int) -> Int
  return n * 2
end

export def boom(event: LogEvent) -> Void
  puts(Shared.fail().to_s)
end
"""

SHARED = """export def name() -> String
  return "shared"
end

export def fail() -> Int
  xs = [1]
  return xs[3]
end
"""

STD_MAIN = """import Helper from "./std/helper"
import Other from "stdx"

def main() -> Void
  if System.args().size > 0
    puts(Other.fail().to_s)
  end
  puts(Helper.fail().to_s)
end
"""

STD_FAIL = """export def fail() -> Int
  xs = [1]
  return xs[3]
end
"""

PKG_MAIN = """import Helper from "pkg/helper"

def main() -> Void
  puts(Helper.name())
end
"""

PKG_HELPER = """export def name() -> String
  return "helper"
end
"""


class SourcePathsTest(TestCase):
    def project(self, files=None):
        """A fresh copy of the program: app/main.agc, app/lib/util.agc and shared/x.agc above the root."""
        base = self.make_temp_dir()
        for name, text in (files or {"app/main.agc": MAIN, "app/lib/util.agc": UTIL, "shared/x.agc": SHARED}).items():
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return base

    def compile_in(self, cwd, source, output):
        result = run(cli() + ["compile", source, "-o", output], cwd=cwd)
        self.assertEqual(result.code, 0, result.stderr)
        return output.read_bytes()

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

    def test_bytes_do_not_depend_on_how_the_entry_is_named(self):
        base = self.project()
        link = base / "linkapp"
        link.symlink_to(base / "app", target_is_directory=True)
        absolute = self.compile_in(base, str(base / "app" / "main.agc"), base / "absolute.agcb")
        relative = self.compile_in(base, "app/main.agc", base / "relative.agcb")
        inside = self.compile_in(base / "app", "main.agc", base / "inside.agcb")
        through_link = self.compile_in(base, "linkapp/main.agc", base / "link.agcb")
        for other in (relative, inside, through_link):
            self.assertEqual(absolute, other)

    def test_a_library_in_agc_libs_is_stored_under_the_root(self):
        files = {"app/main.agc": PKG_MAIN, "app/agc_libs/helper.agc": PKG_HELPER}
        first, second = self.project(files), self.project(files)
        one = compile_agc(first / "app" / "main.agc", first / "one.agcb").read_bytes()
        two = compile_agc(second / "app" / "main.agc", second / "two.agcb").read_bytes()
        self.assertEqual(one, two)
        self.assertIn(b"agc_libs/helper.agc", one)

    def test_stored_paths(self):
        base = self.project()
        data = compile_agc(base / "app" / "main.agc", base / "out.agcb").read_bytes()
        for stored in (b"main.agc", b"lib/util.agc", b"../shared/x.agc", b"std/logger.agc"):
            self.assertIn(stored, data)
        self.assertNotIn(str(base).encode(), data)

    def test_the_vm_prints_the_stored_path_without_a_source_root(self):
        base = self.project()
        bytecode = compile_agc(base / "app" / "main.agc", base / "out.agcb")
        result = run_vm(bytecode, env=vm_environment())
        self.assertEqual(result.code, 1)
        self.assertEqual(result.stdout, "4\nshared\n")
        self.assertRegex(result.stderr, r"(?m)^\.\./shared/x\.agc:\d+:\d+ error\[RUNTIME-INDEX-OUT-OF-RANGE\]")
        self.assertIn("    boom at lib/util.agc:", result.stderr)
        self.assertIn("    main at main.agc:", result.stderr)
        self.assertNotIn(str(base), result.stderr)

    def test_source_root_goes_before_every_name_but_std_names(self):
        base = self.project()
        bytecode = compile_agc(base / "app" / "main.agc", base / "out.agcb")
        # The trace has a file above the root, a lib/ file, a std/ frame and the entry.
        result = run_vm(bytecode, "--source-root", "work/app", env=vm_environment())
        self.assertEqual(result.code, 1)
        self.assertRegex(result.stderr, r"(?m)^work/app/\.\./shared/x\.agc:\d+:\d+ error\[RUNTIME-INDEX-OUT-OF-RANGE\]")
        self.assertRegex(result.stderr, r"\n    boom at work/app/lib/util\.agc:\d+:\d+\n")
        self.assertRegex(result.stderr, r"\n    [a-z_]+ at std/logger\.agc:\d+:\d+\n")
        self.assertRegex(result.stderr, r"\n    main at work/app/main\.agc:\d+:\d+\n")
        for fmt in ("--ai", "--json"):
            shaped = run_vm(bytecode, fmt, "--source-root", "work/app/", env=vm_environment())
            self.assertIn("work/app/lib/util.agc", shaped.stderr)
            self.assertNotIn("work/app//", shaped.stderr)
        # An empty root is the same as no flag, and the option can be given once.
        def trace(*flags):
            return run_vm(bytecode, *flags, env=vm_environment()).stderr.split("\n", 1)[1]  # after the log line
        self.assertEqual(trace("--source-root", ""), trace())
        twice = run_vm(bytecode, "--source-root", "a", "--source-root", "b", env=vm_environment())
        self.assertEqual(twice.code, 2)
        # A missing folder, "--" taken as the folder, and a folder that is not UTF-8 are usage errors.
        env = vm_environment()
        missing = run([vm_binary(), "--source-root"], env=env)
        taken_dashes = run_vm(bytecode, "--source-root", "--", env=env)
        not_utf8 = run_vm(bytecode, "--source-root", "\udcff", env=env)
        for usage in (missing, taken_dashes, not_utf8):
            self.assertEqual(usage.code, 2)
            self.assertIn("--source-root needs a folder name in UTF-8", usage.stderr)

    def test_the_cli_prints_paths_as_seen_from_the_working_directory(self):
        base = self.project()
        app = str(base / "app") + "/"
        for cwd, entry, folder in (
            (base, "app/main.agc", "app/"),
            (base / "app", "main.agc", ""),
            (base, app + "main.agc", app),
        ):
            result = run(cli() + [entry], cwd=cwd)
            self.assertEqual(result.code, 1, result.stderr)
            self.assertIn("\n    boom at %slib/util.agc:" % folder, result.stderr)
            self.assertIn("\n    main at %smain.agc:" % folder, result.stderr)
        # An entry typed through a link prints the real folder, relative to the working directory.
        (base / "linkapp").symlink_to(base / "app", target_is_directory=True)
        result = run(cli() + ["linkapp/main.agc"], cwd=base)
        self.assertIn("\n    boom at app/lib/util.agc:", result.stderr)

    def test_a_user_std_folder_is_not_a_standard_module(self):
        files = {"app/main.agc": STD_MAIN, "app/std/helper.agc": STD_FAIL, "app/stdx.agc": STD_FAIL}
        first, second = self.project(files), self.project(files)
        one = compile_agc(first / "app" / "main.agc", first / "one.agcb")
        two = compile_agc(second / "app" / "main.agc", second / "two.agcb")
        self.assertEqual(one.read_bytes(), two.read_bytes())
        self.assertIn(b"./std/helper.agc", one.read_bytes())
        # Stored as written; with a root the "./" goes away and the folder joins, as for any user file.
        stored = run_vm(one, env=vm_environment())
        self.assertTrue(stored.stderr.startswith("./std/helper.agc:"), stored.stderr)
        rooted = run_vm(one, "--source-root", "app", env=vm_environment())
        self.assertTrue(rooted.stderr.startswith("app/std/helper.agc:"), rooted.stderr)
        self.assertIn("\n    main at app/main.agc:", rooted.stderr)
        # stdx.agc only starts with "std": it is joined like any user file.
        other = run_vm(one, "--source-root", "app", args=("x",), env=vm_environment())
        self.assertTrue(other.stderr.startswith("app/stdx.agc:"), other.stderr)
        # The CLI does the same from the working directory.
        result = run(cli() + ["app/main.agc"], cwd=first)
        self.assertTrue(result.stderr.startswith("app/std/helper.agc:"), result.stderr)
