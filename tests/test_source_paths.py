"""The source paths stored in an .agcb are relative to the project root (docs/future/18-front-end-language.md §18.3).

The root is the folder of the entry file. The bytes must not depend on where
the project lives or on how the entry file is named on the command line. A
runtime trace prints the stored name, and the CLI puts the entry's folder (as
seen from the working directory) before it with `agentica run --source-root`.
"""
import os
import shutil
import struct

from tests.agentica_test import FIXTURES, TARGET_OS, TestCase, cli, compile_agc, run, run_vm, vm_command, vm_environment

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

HELLO = """def main() -> Void
  puts("hi")
end
"""


def pad_source_names(data, extra):
    """The bytes of an .agcb with `extra` more sources that have an empty name and an empty text.

    They go after the real ones, so every span still points at its source. Only the Sources section is read, with
    the layout of docs/vm/03-ir-and-bytecode.md 4.6: magic, u32 format, str version, u32 count, (str, str) entries.
    """
    def skip_string(pos):
        return pos + 4 + struct.unpack_from("<I", data, pos)[0]

    pos = skip_string(8)
    (count,) = struct.unpack_from("<I", data, pos)
    end = pos + 4
    for _ in range(count):
        end = skip_string(skip_string(end))
    return data[:pos] + struct.pack("<I", count + extra) + data[pos + 4:end] + bytes(8 * extra) + data[end:]


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

    def test_absolute_paths_require_a_drive_and_separator(self) -> None:
        cases = (
            ("", False),
            ("main.agc", False),
            ("std/queue.agc", False),
            ("/", True),
            ("/tmp/main.agc", True),
            ("C:/main.agc", True),
            ("z:\\main.agc", True),
            ("//server/share/main.agc", True),
            ("\\\\server\\share\\main.agc", True),
            ("C:", False),
            ("C:main.agc", False),
            ("1:/main.agc", False),
            ("é:/main.agc", False),
        )
        result = run(
            [*cli(), FIXTURES / "source-paths" / "rooted.agc", *(path for path, _ in cases)],
            env=vm_environment(),
        )
        expected = ["true false" if rooted else "false true" for _, rooted in cases]
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), expected)

    def test_a_relative_colon_path_keeps_a_relative_source_root(self) -> None:
        if TARGET_OS == "windows":
            self.skipTest("Windows filenames cannot contain a colon")
        program = 'def main() -> Void\n  xs = [1]\n  puts(xs[3])\nend\n'
        for folder in ("1:", "C:relative"):
            with self.subTest(folder=folder):
                entry = f"{folder}/main.agc"
                base = self.project({entry: program})
                result = run([*cli(), entry], cwd=base, env=vm_environment())
                self.assertEqual(result.code, 1, result.stderr)
                self.assertTrue(result.stderr.startswith(f"{entry}:"), result.stderr)
                self.assertNotIn(str(base), result.stderr)

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
        missing = run([*vm_command(), "--source-root"], env=env)
        taken_dashes = run_vm(bytecode, "--source-root", "--", env=env)
        not_utf8 = run_vm(bytecode, "--source-root", "\udcff", env=env)
        for usage in (missing, taken_dashes):
            self.assertEqual(usage.code, 2)
            self.assertIn("--source-root needs a folder name in UTF-8", usage.stderr)
        # Native Windows reads the command line as UTF-16 and refuses a lone surrogate before reading the
        # option. Under Wine, Unix execve passes its encoded byte instead, so the Windows conversion path is not
        # exercised.
        if os.environ.get("AGENTICA_TEST_WINE"):
            self.assertEqual(not_utf8.code, 1, not_utf8.stderr)
        else:
            self.assertEqual(not_utf8.code, 2)
            self.assertIn("cannot decode command line arguments" if TARGET_OS == "windows" else
                          "--source-root needs a folder name in UTF-8", not_utf8.stderr)

    def test_the_cli_prints_paths_as_seen_from_the_working_directory(self):
        base = self.project()
        # The product prints canonical paths with "/" separators. Wine exposes the Linux filesystem as drive Z:.
        prefix = "Z:" if os.environ.get("AGENTICA_TEST_WINE") else ""
        app = prefix + (base / "app").as_posix() + "/"
        for cwd, entry, folder in (
            (base, "app/main.agc", "app/"),
            (base / "app", "main.agc", ""),
            (base, app + "main.agc", app),
        ):
            result = run(cli() + [entry], cwd=cwd)
            self.assertEqual(result.code, 1, result.stderr)
            self.assertIn("\n    boom at %slib/util.agc:" % folder, result.stderr)
            self.assertIn("\n    main at %smain.agc:" % folder, result.stderr)
        # An entry typed through a link prints the real folder on native hosts. Wine does not resolve the symlink in
        # the Windows path API, so it preserves the name the caller typed.
        (base / "linkapp").symlink_to(base / "app", target_is_directory=True)
        result = run(cli() + ["linkapp/main.agc"], cwd=base)
        expected = "linkapp" if os.environ.get("AGENTICA_TEST_WINE") else "app"
        self.assertIn("\n    boom at %s/lib/util.agc:" % expected, result.stderr)

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

    def test_a_source_root_past_the_cap_is_refused(self):
        base = self.project({"app/main.agc": HELLO})
        data = compile_agc(base / "app" / "main.agc", base / "out.agcb").read_bytes()
        # Every padded name is empty, relative and not under std/, so each gets the root and the guard refuses once
        # count * (root + "/") passes 64 MiB. 4000 names and a 17000-character root keep the command line under the
        # 32767-character limit of CreateProcess, so the case runs on Windows too.
        padded = base / "padded.agcb"
        padded.write_bytes(pad_source_names(data, 4000))
        env = vm_environment()
        plain = run_vm(padded, env=env)
        self.assertEqual((plain.code, plain.stdout), (0, "hi\n"), plain.stderr)
        short = run_vm(padded, "--source-root", "app", env=env)
        self.assertEqual((short.code, short.stdout), (0, "hi\n"), short.stderr)
        refused = run_vm(padded, "--source-root", "r" * 17000, env=env)
        self.assertEqual(refused.code, 2)
        self.assertEqual(refused.stdout, "")
        self.assertEqual(refused.stderr, "agentica run: --source-root is too long for this program\n")
