"""Source builds of native modules (`[native.NAME] build`, docs/grammar/05b-modules.md), through the CLI.

The project (or a `path` dependency) holds a small native module in its native/ folder, which a run, `compile`, `test`
or `install` builds with the system C compiler into the package cache of a temporary folder; `check` never builds, and
a fetched package never does either. The cases that only check or fail before the compiler runs need no compiler and
run everywhere; the ones that build and call the module need one and native calls (NATIVE_CALLS). Cases assert codes
and the file and key path, never message text (AGENTS.md).
"""
import json
import os
import re
import shutil
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, tool, vm_environment
from tests.package_support import assert_at_key, ws  # noqa: F401
from tests.test_spec_package_native import LIBM, SYSTEM_MAIN, SYSTEM_TABLE
from tests.test_vm_native import NATIVE_CALLS

ADDER_C = """#include "agentica_native.h"
#include "offset.h"

static an_term add(an_env *env, int argc, const an_term *argv) {
  int64_t a, b;
  (void)argc;
  if (!an_get_int(env, argv[0], &a) || !an_get_int(env, argv[1], &b)) return an_badarg(env, 0);
  return an_int(env, a * SCALE + b + OFFSET);
}

static const an_function functions[] = {{"add", "(Int, Int) -> Int", add, AN_SHORT}};

AN_MODULE("adder", functions, NULL)
"""
ADDER_AGC = 'extern module "adder"\n  export def add(a: Int, b: Int) -> Int\nend\n'
MAIN = 'import Adder from "adder"\n\ndef main() -> Void\n  puts(Adder.add(40, 2))\nend\n'
TABLE = '[native.adder]\nbuild = { sources = ["native/adder.c"], defines = ["SCALE=1"] }\n'
BUILT = re.compile(r"built native adder: (.+)\n")


def environment(ws, **extra):
    """The bytecode cache of the runs is on, in a folder of the case (bytecode_entries)."""
    return vm_environment({"AGENTICA_PATH": "", "AGENTICA_BUILD_DIR": str(ws.base / "build"), **ws.cache_variables,
                           **extra})


def bytecode_entries(ws):
    return [path for path in (ws.base / "build").rglob("*.agcb")]


def agentica(ws, *words, folder=None, **extra):
    return run(cli() + list(words), cwd=folder or ws.project, env=environment(ws, **extra))


def problem(result):
    assert result.code == 1, result.stderr
    return json.loads(result.stderr)


def module_folder(folder, table=TABLE, name="app", source=ADDER_C):
    """A package folder with the adder module: its manifest, adder.agc, native/adder.c and the header it includes."""
    (folder / "native").mkdir(parents=True, exist_ok=True)
    (folder / "agentica.toml").write_text('name = "%s"\n\n%s' % (name, table), encoding="utf-8")
    (folder / "adder.agc").write_text(ADDER_AGC, encoding="utf-8")
    (folder / "native" / "adder.c").write_text(source, encoding="utf-8")
    (folder / "native" / "offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")


def project(ws, **options):
    module_folder(ws.project, **options)
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def path_dependency(ws, source=ADDER_C):
    """A project whose main file uses the adder module of the `path` dependency ../adder, locked."""
    module_folder(ws.base / "adder", name="adder", source=source)
    (ws.project / "agentica.toml").write_text('name = "app"\n\n[dependencies]\nadder = { path = "../adder" }\n',
                                              encoding="utf-8")
    (ws.project / "agentica.lock").write_text('version = 1\n\n[[package]]\nname = "adder"\npath = "../adder"\n',
                                              encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")


def builds(ws):
    """The entries of the build cache, temporary folders included."""
    base = ws.pkg_root / "native-build"
    return sorted(path.name for path in base.iterdir()) if base.exists() else []


def files_of(folder):
    """The files below the folder, outside a _build/ folder."""
    return sorted(str(path.relative_to(folder)) for path in folder.rglob("*") if "_build" not in path.parts)


def no_compiler(ws):
    """A CC that cannot start: a run that tried to build would fail."""
    return {"CC": str(ws.base / "no-such-cc")}


@pytest.mark.parametrize("build, key", [
    ('{ sources = ["src/adder.c"] }', "native.adder.build.sources[0]"),
    ('{ sources = ["native/../adder.c"] }', "native.adder.build.sources[0]"),
    ('{ sources = ["native/adder.h"] }', "native.adder.build.sources[0]"),
    ('{ sources = ["native/adder.c"], defines = ["X -o /tmp/evil"] }', "native.adder.build.defines[0]"),
    ('{ sources = ["native/adder.c"], defines = ["X=\\"1\\""] }', "native.adder.build.defines[0]"),
    ('{ sources = ["native/adder.c"], libs = ["-Wl,-rpath,/tmp"] }', "native.adder.build.libs[0]"),
    ('{ sources = ["native/adder.c"], flags = ["-O0"] }', "native.adder.build.flags"),
    ('{ sources = [] }', "native.adder.build.sources"),
    ('{ defines = ["X"] }', "native.adder.build"),
], ids=["outside native", "dot dot", "not C", "a flag in a define", "a quote in a define", "a flag as a lib",
        "an unknown key", "no source", "no sources key"])
def test_a_build_table_holds_only_sources_in_native_defines_and_library_names(ws, build, key):
    project(ws, table="[native.adder]\nbuild = %s\n" % build)
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key)


def test_check_never_builds_and_a_missing_source_is_pkg_native_missing_at_its_item(ws):
    project(ws)
    checked = agentica(ws, "--json", "check", str(ws.project / "main.agc"), **no_compiler(ws))
    assert (checked.code, checked.stdout, checked.stderr) == (0, '{"ok":true}\n', "")
    assert builds(ws) == []
    (ws.project / "native" / "adder.c").unlink()
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-MISSING", ws.project / "agentica.toml", "native.adder.build.sources[0]")


def test_a_compiler_that_cannot_start_is_pkg_native_build_at_the_build_table(ws):
    project(ws)
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc"), **no_compiler(ws)))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


@host_only(WINDOWS, "a symbolic link needs a privilege on Windows")
def test_a_link_in_native_is_refused_so_a_build_reads_only_the_package(ws, tmp_path):
    project(ws)
    outside = tmp_path / "outside.c"
    outside.write_text(ADDER_C, encoding="utf-8")
    (ws.project / "native" / "adder.c").unlink()
    (ws.project / "native" / "adder.c").symlink_to(outside)
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


@NATIVE_CALLS
def test_a_fetched_package_never_builds_and_uses_its_system_entry(ws):
    table = SYSTEM_TABLE.replace("[native.cmath]\n", '[native.cmath]\nbuild = { sources = ["native/cmath.c"] }\n')
    ws.add_package("pkgdemo", "https://example.test/owner/pkgdemo",
                   {"math.agc": LIBM, "agentica.toml": 'name = "pkgdemo"\n\n' + table})
    (ws.project / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\npkgdemo = { git = "https://example.test/owner/pkgdemo", tag = "v1.0.0" }\n',
        encoding="utf-8")
    ws.write_lock()
    (ws.project / "main.agc").write_text(SYSTEM_MAIN, encoding="utf-8")
    ran = agentica(ws, str(ws.project / "main.agc"), **no_compiler(ws))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "1.0\n", "")
    assert builds(ws) == []


@NATIVE_CALLS
def test_a_run_builds_the_project_module_into_the_cache_and_builds_again_after_an_edit(ws):
    tool("cc")
    project(ws)
    before = files_of(ws.project)
    ran = agentica(ws, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    built = BUILT.fullmatch(ran.stderr)
    assert built, ran.stderr
    # The library is in the build cache under its key, and nothing but _build/ is written into the project.
    entry = builds(ws)
    assert len(entry) == 1 and re.fullmatch(r"[0-9a-f]{64}", entry[0])
    library = Path(built.group(1))
    assert library.is_file() and library.parent == ws.pkg_root / "native-build" / entry[0]
    assert files_of(ws.project) == before

    again = agentica(ws, str(ws.project / "main.agc"))
    assert (again.code, again.stdout, again.stderr) == (0, "42\n", "")
    # A header the source includes is a file of native/, so the key covers it: the cached program misses and the
    # module is built again, under another key.
    (ws.project / "native" / "offset.h").write_text("#define OFFSET 1\n", encoding="utf-8")
    edited = agentica(ws, str(ws.project / "main.agc"))
    assert (edited.code, edited.stdout) == (0, "43\n"), edited.stderr
    assert BUILT.fullmatch(edited.stderr) and len(builds(ws)) == 2
    quiet = agentica(ws, "--json", "--no-cache", str(ws.project / "main.agc"))
    assert (quiet.code, quiet.stdout, quiet.stderr) == (0, "43\n", "")


@NATIVE_CALLS
def test_a_failed_build_is_pkg_native_build_and_leaves_no_entry(ws):
    tool("cc")
    project(ws, source=ADDER_C + "int broken = ;\n")
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    assert builds(ws) == []


@NATIVE_CALLS
def test_install_builds_the_module_of_a_path_dependency_and_a_run_finds_it_built(ws):
    tool("cc")
    path_dependency(ws)
    installed = agentica(ws, "install")
    assert (installed.code, installed.stdout) == (0, "in place adder@path\n"), installed.stderr
    assert BUILT.fullmatch(installed.stderr), installed.stderr
    ran = agentica(ws, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "42\n", "")
    # The compiled program names the library by its path in the cache, so `run --` opens it as it is.
    compiled = agentica(ws, "compile", str(ws.project / "main.agc"), "-o", str(ws.base / "main.agcb"))
    assert (compiled.code, compiled.stderr) == (0, "")
    assert agentica(ws, "run", "--", str(ws.base / "main.agcb")).stdout == "42\n"


@host_only(WINDOWS, "a symbolic link needs a privilege on Windows")
@pytest.mark.parametrize("hidden", [False, True], ids=["a linked native folder", "a hidden link"])
def test_a_linked_native_folder_or_a_hidden_link_in_it_is_refused(ws, tmp_path, hidden):
    project(ws)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")
    if hidden:
        (ws.project / "native" / ".offset.h").symlink_to(outside / "offset.h")
    else:
        (ws.project / "native" / "adder.c").rename(outside / "adder.c")
        (ws.project / "native" / "offset.h").unlink()
        (ws.project / "native").rmdir()
        (ws.project / "native").symlink_to(outside, target_is_directory=True)
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


def test_a_windows_device_name_is_not_a_library_name_to_build(ws):
    project(ws, table='[native.con]\nbuild = { sources = ["native/adder.c"] }\n')
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", "native.con")


def test_a_library_no_file_uses_never_builds(ws):
    project(ws)
    (ws.project / "main.agc").write_text('def main() -> Void\n  puts(1)\nend\n', encoding="utf-8")
    ran = agentica(ws, str(ws.project / "main.agc"), **no_compiler(ws))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "1\n", "")
    assert builds(ws) == []


@NATIVE_CALLS
@pytest.mark.parametrize("flag", ["--deny-native", "--deny-run", "--deny-fs", "--sandbox"])
def test_under_a_deny_flag_nothing_builds_and_a_run_is_refused_alike_on_a_cache_hit_and_a_miss(ws, flag):
    tool("cc")
    project(ws)
    main = str(ws.project / "main.agc")
    ran = agentica(ws, main)
    assert (ran.code, ran.stdout) == (0, "42\n") and BUILT.fullmatch(ran.stderr), ran.stderr
    # The CC cannot start, so a build would fail: the miss and then the hit of the refused run are the VM's refusal.
    for _ in range(2):
        denied = agentica(ws, "--json", flag, main, **no_compiler(ws))
        assert (denied.code, json.loads(denied.stderr)["code"]) == (2, "RUNTIME-NATIVE-DENIED"), denied.stderr
    assert len(builds(ws)) == 1 and len(bytecode_entries(ws)) == 2
    # `compile` writes a program that may run without the flag, so it refuses the module instead.
    found = problem(agentica(ws, "--json", flag, "compile", main, "-o", str(ws.base / "main.agcb")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    assert not (ws.base / "main.agcb").exists()
    # The refused runs kept their programs apart: a plain run takes its own, with the built library.
    assert agentica(ws, main).stdout == "42\n"


@NATIVE_CALLS
@pytest.mark.parametrize("words", [["--deny-native", "--json", "test"], ["--json", "test", "--deny-run"]],
                         ids=["in front of test", "after test"])
def test_test_under_a_deny_flag_builds_nothing_and_the_test_file_is_refused(ws, words):
    project(ws)
    (ws.project / "test").mkdir()
    (ws.project / "test" / "adder_test.agc").write_text(
        'import Adder from "../adder"\n\ndef main() -> Void\n'
        '  Test.run([Test.test("adds") do Test.eq(Adder.add(40, 2), 42) end])\nend\n', encoding="utf-8")
    tested = agentica(ws, *words, **no_compiler(ws))
    assert (tested.code, tested.stderr) == (1, ""), tested.stdout
    report = json.loads(tested.stdout)
    assert [entry["error"]["code"] for entry in report["files"]] == ["RUNTIME-NATIVE-DENIED"]
    assert builds(ws) == []


def test_a_lock_row_that_says_member_outside_its_workspace_never_builds(ws):
    module_folder(ws.base / "repo" / "adder", name="adder")
    url = "https://example.test/owner/repo"
    (ws.project / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nadder = { git = "%s", tag = "v1", subdir = "adder" }\n' % url,
        encoding="utf-8")
    (ws.project / "agentica.lock").write_text(
        'version = 1\n\n[[package]]\nname = "adder"\ngit = "%s"\nsubdir = "adder"\ntag = "v1"\nworkspace = true\n'
        % url, encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc"), **no_compiler(ws)))
    assert_at_key(found, "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.adder")
    assert builds(ws) == []


@NATIVE_CALLS
def test_a_workspace_member_builds_in_place(ws, tmp_path):
    tool("cc")
    repo = tmp_path / "repo"
    url = "https://example.test/owner/repo"
    repo.mkdir()
    (repo / "agentica.toml").write_text('[workspace]\nrepository = "%s"\nmembers = ["adder", "app"]\n' % url,
                                        encoding="utf-8")
    module_folder(repo / "adder", name="adder")
    app = repo / "app"
    app.mkdir()
    (app / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nadder = { git = "%s", tag = "adder-1", subdir = "adder" }\n' % url,
        encoding="utf-8")
    (app / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")
    updated = agentica(ws, "--json", "update", folder=app)
    assert updated.code == 0, updated.stderr
    ran = agentica(ws, str(app / "main.agc"), folder=app)
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    assert BUILT.fullmatch(ran.stderr) and len(builds(ws)) == 1


@NATIVE_CALLS
def test_agentica_test_builds_the_module_a_test_file_uses(ws):
    tool("cc")
    project(ws)
    (ws.project / "test").mkdir()
    (ws.project / "test" / "adder_test.agc").write_text(
        'import Adder from "../adder"\n\ndef main() -> Void\n'
        '  Test.run([Test.test("adds") do Test.eq(Adder.add(40, 2), 42) end])\nend\n', encoding="utf-8")
    tested = agentica(ws, "test")
    assert tested.code == 0, tested.stdout + tested.stderr
    assert BUILT.search(tested.stderr) and len(builds(ws)) == 1


@NATIVE_CALLS
def test_another_define_or_compiler_is_another_entry_and_a_tampered_entry_is_pkg_native_build(ws):
    compiler = tool("cc")
    project(ws)
    main = str(ws.project / "main.agc")
    assert agentica(ws, "--no-cache", main).stdout == "42\n"
    (ws.project / "agentica.toml").write_text('name = "app"\n\n' + TABLE.replace("SCALE=1", "SCALE=2"),
                                              encoding="utf-8")
    assert agentica(ws, "--no-cache", main).stdout == "82\n"
    assert agentica(ws, "--no-cache", main, CC=compiler).stdout == "82\n"
    entries = builds(ws)
    assert len(entries) == 3
    # The entry of this table and CC: its library, then its receipt, changed after the build.
    newest = max((ws.pkg_root / "native-build" / name for name in entries), key=lambda path: path.stat().st_mtime_ns)
    library = next(path for path in newest.iterdir() if path.name.startswith(("libadder", "adder")))
    built = library.read_bytes()
    library.write_bytes(built + b"\0")
    found = problem(agentica(ws, "--json", "--no-cache", main, CC=compiler))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    library.write_bytes(built)
    (newest / "receipt").write_text("0" * 64 + "\n", encoding="utf-8")
    found = problem(agentica(ws, "--json", "--no-cache", main, CC=compiler))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


@host_only(WINDOWS, "a named pipe is a POSIX file")
def test_a_pipe_in_native_is_refused(ws):
    project(ws)
    os.mkfifo(ws.project / "native" / "fifo")
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


@NATIVE_CALLS
def test_with_the_bytecode_cache_a_new_file_a_changed_library_and_a_removed_entry_are_seen(ws):
    tool("cc")
    project(ws)
    main = str(ws.project / "main.agc")
    assert BUILT.fullmatch(agentica(ws, main).stderr)
    assert agentica(ws, main).stderr == ""
    assert bytecode_entries(ws), "no bytecode cache entry"
    # A new file of native/ is in the key, so the cached program misses and the module is built again.
    (ws.project / "native" / "notes.txt").write_text("new\n", encoding="utf-8")
    added = agentica(ws, main)
    assert (added.code, added.stdout) == (0, "42\n") and BUILT.fullmatch(added.stderr), added.stderr
    assert agentica(ws, main).stderr == ""
    entry = ws.pkg_root / "native-build" / BUILT.fullmatch(added.stderr).group(1).split("/")[-2]
    library = Path(BUILT.fullmatch(added.stderr).group(1))
    built = library.read_bytes()
    library.write_bytes(built + b"\0")
    found = problem(agentica(ws, "--json", main))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    library.unlink()
    found = problem(agentica(ws, "--json", main))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    # Removing the entry, as the help says, builds it again.
    shutil.rmtree(entry)
    again = agentica(ws, main)
    assert (again.code, again.stdout) == (0, "42\n") and BUILT.fullmatch(again.stderr), again.stderr


@NATIVE_CALLS
def test_with_the_bytecode_cache_an_edit_to_a_hidden_header_of_a_path_dependency_builds_again(ws):
    tool("cc")
    path_dependency(ws, source=ADDER_C.replace('"offset.h"', '".offset.h"'))
    (ws.base / "adder" / "native" / ".offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")
    main = str(ws.project / "main.agc")
    ran = agentica(ws, main)
    assert (ran.code, ran.stdout) == (0, "42\n") and BUILT.fullmatch(ran.stderr), ran.stderr
    assert agentica(ws, main).stderr == ""
    (ws.base / "adder" / "native" / ".offset.h").write_text("#define OFFSET 1\n", encoding="utf-8")
    edited = agentica(ws, main)
    assert (edited.code, edited.stdout) == (0, "43\n") and BUILT.fullmatch(edited.stderr), edited.stderr


@NATIVE_CALLS
def test_compile_builds_the_module_a_file_uses_and_the_bytecode_opens_it(ws):
    tool("cc")
    project(ws)
    compiled = agentica(ws, "compile", str(ws.project / "main.agc"), "-o", str(ws.base / "main.agcb"))
    assert compiled.code == 0 and BUILT.fullmatch(compiled.stderr), compiled.stderr
    ran = agentica(ws, "run", "--", str(ws.base / "main.agcb"))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "42\n", "")
