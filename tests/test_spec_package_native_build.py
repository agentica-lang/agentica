"""Source builds of native modules (`[native.NAME] build`, docs/grammar/05b-modules.md), through the CLI.

The project (or a `path` dependency) holds a small native module in its native/ folder, which a run, `compile`, `test`
or `install` builds with the system C compiler into the package cache of a temporary folder; `check` never builds, and
a fetched package never does either. The cases that only check or fail before the compiler runs need no compiler and
run everywhere; the ones that build and call the module need one and native calls (NATIVE_CALLS). Cases assert codes
and the file and key path, never message text (AGENTS.md).
"""
import json
import re
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
    return vm_environment({"AGENTICA_PATH": "", **ws.cache_variables, **extra})


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
    module_folder(ws.base / "adder", name="adder")
    (ws.project / "agentica.toml").write_text('name = "app"\n\n[dependencies]\nadder = { path = "../adder" }\n',
                                              encoding="utf-8")
    (ws.project / "agentica.lock").write_text('version = 1\n\n[[package]]\nname = "adder"\npath = "../adder"\n',
                                              encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")
    installed = agentica(ws, "install")
    assert (installed.code, installed.stdout) == (0, "in place adder@path\n"), installed.stderr
    assert BUILT.fullmatch(installed.stderr), installed.stderr
    ran = agentica(ws, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "42\n", "")
    # The compiled program names the library by its path in the cache, so `run --` opens it as it is.
    compiled = agentica(ws, "compile", str(ws.project / "main.agc"), "-o", str(ws.base / "main.agcb"))
    assert (compiled.code, compiled.stderr) == (0, "")
    assert agentica(ws, "run", "--", str(ws.base / "main.agcb")).stdout == "42\n"
