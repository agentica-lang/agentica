"""The source paths stored in an .agcb are relative to the project root (docs/future/35-self-hosting.md, 35.4).

The root is the folder of the entry file. The bytes must not depend on where
the project lives or on how the entry file is named on the command line. A
runtime trace prints the stored name, and the CLI puts the entry's folder (as
seen from the working directory) before it with `agentica run --source-root`.
"""
import os
import re
import shutil
import struct

import pytest

from tests.agentica_test import FIXTURES, TARGET_OS, cli, compile_agc, run, run_vm, vm_command, vm_environment

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


@pytest.fixture
def project_factory(tmp_path):
    count = 0

    def create(files=None):
        nonlocal count
        base = tmp_path / f"project-{count}"
        count += 1
        for name, text in (files or {"app/main.agc": MAIN, "app/lib/util.agc": UTIL, "shared/x.agc": SHARED}).items():
            path = base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return base

    return create


def compile_in(cwd, source, output):
    result = run(cli() + ["compile", source, "-o", output], cwd=cwd)
    assert result.code == 0, result.stderr
    return output.read_bytes()


def test_absolute_paths_require_a_drive_and_separator() -> None:
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
    assert (result.code) == (0), result.stderr
    assert (result.stdout.splitlines()) == (expected)


@pytest.mark.parametrize("folder", ("1:", "C:relative"))
def test_a_relative_colon_path_keeps_a_relative_source_root(folder, project_factory):
    if TARGET_OS == "windows":
        pytest.skip("Windows filenames cannot contain a colon")
    program = """\
def main() -> Void
  xs = [1]
  puts(xs[3])
end
"""
    entry = f"{folder}/main.agc"
    base = project_factory({entry: program})
    result = run([*cli(), entry], cwd=base, env=vm_environment())
    assert (result.code) == (1), result.stderr
    assert (result.stderr.startswith(f"{entry}:")), result.stderr
    assert (str(base)) not in (result.stderr)


def test_bytes_do_not_depend_on_the_checkout_location(project_factory):
    first, second = project_factory(), project_factory()
    assert (first) != (second)
    one = compile_agc(first / "app" / "main.agc", first / "one.agcb").read_bytes()
    two = compile_agc(second / "app" / "main.agc", second / "two.agcb").read_bytes()
    assert (one) == (two)


def test_bytes_do_not_depend_on_the_name_of_the_root_folder(project_factory):
    first, second = project_factory(), project_factory()
    shutil.move(str(second / "app"), str(second / "renamed"))
    one = compile_agc(first / "app" / "main.agc", first / "one.agcb").read_bytes()
    two = compile_agc(second / "renamed" / "main.agc", second / "two.agcb").read_bytes()
    assert (one) == (two)


def test_bytes_do_not_depend_on_how_the_entry_is_named(project_factory):
    base = project_factory()
    link = base / "linkapp"
    link.symlink_to(base / "app", target_is_directory=True)
    absolute = compile_in(base, str(base / "app" / "main.agc"), base / "absolute.agcb")
    relative = compile_in(base, "app/main.agc", base / "relative.agcb")
    inside = compile_in(base / "app", "main.agc", base / "inside.agcb")
    through_link = compile_in(base, "linkapp/main.agc", base / "link.agcb")
    for other in (relative, inside, through_link):
        assert (absolute) == (other)


def test_a_library_in_agc_libs_is_stored_under_the_root(project_factory):
    files = {"app/main.agc": PKG_MAIN, "app/agc_libs/helper.agc": PKG_HELPER}
    first, second = project_factory(files), project_factory(files)
    one = compile_agc(first / "app" / "main.agc", first / "one.agcb").read_bytes()
    two = compile_agc(second / "app" / "main.agc", second / "two.agcb").read_bytes()
    assert (one) == (two)
    assert (b"agc_libs/helper.agc") in (one)


def test_stored_paths(project_factory):
    base = project_factory()
    data = compile_agc(base / "app" / "main.agc", base / "out.agcb").read_bytes()
    for stored in (b"main.agc", b"lib/util.agc", b"../shared/x.agc", b"std/logger.agc"):
        assert (stored) in (data)
    assert (str(base).encode()) not in (data)


def test_the_vm_prints_the_stored_path_without_a_source_root(project_factory):
    base = project_factory()
    bytecode = compile_agc(base / "app" / "main.agc", base / "out.agcb")
    result = run_vm(bytecode, env=vm_environment())
    assert (result.code) == (1)
    assert (result.stdout) == ("4\nshared\n")
    assert re.search(r"(?m)^\.\./shared/x\.agc:\d+:\d+ error\[RUNTIME-INDEX-OUT-OF-RANGE\]", result.stderr)
    assert ("    boom at lib/util.agc:") in (result.stderr)
    assert ("    main at main.agc:") in (result.stderr)
    assert (str(base)) not in (result.stderr)


def test_source_root_goes_before_every_name_but_std_names(project_factory):
    base = project_factory()
    bytecode = compile_agc(base / "app" / "main.agc", base / "out.agcb")
    # The trace has a file above the root, a lib/ file, a std/ frame and the entry.
    result = run_vm(bytecode, "--source-root", "work/app", env=vm_environment())
    assert (result.code) == (1)
    assert re.search(r"(?m)^work/app/\.\./shared/x\.agc:\d+:\d+ error\[RUNTIME-INDEX-OUT-OF-RANGE\]", result.stderr)
    assert re.search(r"\n    boom at work/app/lib/util\.agc:\d+:\d+\n", result.stderr)
    assert re.search(r"\n    [a-z_]+ at std/logger\.agc:\d+:\d+\n", result.stderr)
    assert re.search(r"\n    main at work/app/main\.agc:\d+:\d+\n", result.stderr)
    for fmt in ("--ai", "--json"):
        shaped = run_vm(bytecode, fmt, "--source-root", "work/app/", env=vm_environment())
        assert ("work/app/lib/util.agc") in (shaped.stderr)
        assert ("work/app//") not in (shaped.stderr)
    # An empty root is the same as no flag, and the option can be given once.
    def trace(*flags):
        return run_vm(bytecode, *flags, env=vm_environment()).stderr.split("\n", 1)[1]  # after the log line
    assert (trace("--source-root", "")) == (trace())
    twice = run_vm(bytecode, "--source-root", "a", "--source-root", "b", env=vm_environment())
    assert (twice.code) == (2)
    # A missing folder, "--" taken as the folder, and a folder that is not UTF-8 are usage errors.
    env = vm_environment()
    missing = run([*vm_command(), "--source-root"], env=env)
    taken_dashes = run_vm(bytecode, "--source-root", "--", env=env)
    not_utf8 = run_vm(bytecode, "--source-root", "\udcff", env=env)
    for usage in (missing, taken_dashes):
        assert (usage.code) == (2)
        assert ("--source-root needs a folder name in UTF-8") in (usage.stderr)
    # Native Windows reads the command line as UTF-16 and refuses a lone surrogate before reading the
    # option. Under Wine, Unix execve passes its encoded byte instead, so the Windows conversion path is not
    # exercised.
    if os.environ.get("AGENTICA_TEST_WINE"):
        assert (not_utf8.code) == (1), not_utf8.stderr
    else:
        assert (not_utf8.code) == (2)
        assert ("cannot decode command line arguments" if TARGET_OS == "windows" else
                      "--source-root needs a folder name in UTF-8") in (not_utf8.stderr)


def test_the_cli_prints_paths_as_seen_from_the_working_directory(project_factory):
    base = project_factory()
    # The product prints canonical paths with "/" separators. Wine exposes the Linux filesystem as drive Z:.
    prefix = "Z:" if os.environ.get("AGENTICA_TEST_WINE") else ""
    app = prefix + (base / "app").as_posix() + "/"
    for cwd, entry, folder in (
        (base, "app/main.agc", "app/"),
        (base / "app", "main.agc", ""),
        (base, app + "main.agc", app),
    ):
        result = run(cli() + [entry], cwd=cwd)
        assert (result.code) == (1), result.stderr
        assert ("\n    boom at %slib/util.agc:" % folder) in (result.stderr)
        assert ("\n    main at %smain.agc:" % folder) in (result.stderr)
    # An entry typed through a link prints the real folder on native hosts. Wine does not resolve the symlink in
    # the Windows path API, so it preserves the name the caller typed.
    (base / "linkapp").symlink_to(base / "app", target_is_directory=True)
    result = run(cli() + ["linkapp/main.agc"], cwd=base)
    expected = "linkapp" if os.environ.get("AGENTICA_TEST_WINE") else "app"
    assert ("\n    boom at %s/lib/util.agc:" % expected) in (result.stderr)


def test_a_user_std_folder_is_not_a_standard_module(project_factory):
    files = {"app/main.agc": STD_MAIN, "app/std/helper.agc": STD_FAIL, "app/stdx.agc": STD_FAIL}
    first, second = project_factory(files), project_factory(files)
    one = compile_agc(first / "app" / "main.agc", first / "one.agcb")
    two = compile_agc(second / "app" / "main.agc", second / "two.agcb")
    assert (one.read_bytes()) == (two.read_bytes())
    assert (b"./std/helper.agc") in (one.read_bytes())
    # Stored as written; with a root the "./" goes away and the folder joins, as for any user file.
    stored = run_vm(one, env=vm_environment())
    assert (stored.stderr.startswith("./std/helper.agc:")), stored.stderr
    rooted = run_vm(one, "--source-root", "app", env=vm_environment())
    assert (rooted.stderr.startswith("app/std/helper.agc:")), rooted.stderr
    assert ("\n    main at app/main.agc:") in (rooted.stderr)
    # stdx.agc only starts with "std": it is joined like any user file.
    other = run_vm(one, "--source-root", "app", args=("x",), env=vm_environment())
    assert (other.stderr.startswith("app/stdx.agc:")), other.stderr
    # The CLI does the same from the working directory.
    result = run(cli() + ["app/main.agc"], cwd=first)
    assert (result.stderr.startswith("app/std/helper.agc:")), result.stderr


def test_a_source_root_past_the_cap_is_refused(project_factory):
    base = project_factory({"app/main.agc": HELLO})
    data = compile_agc(base / "app" / "main.agc", base / "out.agcb").read_bytes()
    # Every padded name is empty, relative and not under std/, so each gets the root and the guard refuses once
    # count * (root + "/") passes 64 MiB. 4000 names and a 17000-character root keep the command line under the
    # 32767-character limit of CreateProcess, so the case runs on Windows too.
    padded = base / "padded.agcb"
    padded.write_bytes(pad_source_names(data, 4000))
    env = vm_environment()
    plain = run_vm(padded, env=env)
    assert ((plain.code, plain.stdout)) == ((0, "hi\n")), plain.stderr
    short = run_vm(padded, "--source-root", "app", env=env)
    assert ((short.code, short.stdout)) == ((0, "hi\n")), short.stderr
    refused = run_vm(padded, "--source-root", "r" * 17000, env=env)
    assert (refused.code) == (2)
    assert (refused.stdout) == ("")
    assert (refused.stderr) == ("agentica run: --source-root is too long for this program\n")
