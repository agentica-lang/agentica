"""Native libraries in packages (docs/grammar/05b-modules.md, docs/future/45-packages.md 45.10), through the CLI.

The package is a bare git repository in a temporary folder (tests/package_support.py, `Remotes`) that ships a small
library, built here from tests/fixtures/native/pkgdemo.c with the system C compiler, in its native/ folder. `install`
fetches it, and a build opens it by its path in deps/. The cases that only check or fail need no compiler or libffi and
run everywhere; the ones that call the library need libffi (Linux x86_64, Windows x64, macOS). Cases assert codes and
the file and key path, never message text (AGENTS.md).
"""
import json
import shutil

import pytest

from tests.agentica_test import TARGET_OS, WINDOWS, cli, host_only, run, vm_environment
from tests.package_support import (assert_at_key, build, cached_files, dependency, git,  # noqa: F401
                                    install, lock_entry, package_hash, plain, problem_of, remotes, ws)
from tests.test_vm_native import NATIVE_CALLS, library_name, shared_library

REPO = "owner/pkgdemo"
MACOS = TARGET_OS == "darwin"
# The name of this system in a [native] table.
HERE = "windows" if WINDOWS else "macos" if MACOS else "linux"
OTHER = "linux" if WINDOWS else "windows"

DEMO = 'extern "pkgdemo"\n  export def pkgdemo_add(a: C.Int32, b: C.Int32) -> C.Int32\nend\n'
MAIN = 'import Demo from "pkg/pkgdemo/demo"\n\ndef main() -> Void\n  puts(Demo.pkgdemo_add(40, 2))\nend\n'
LIBM = 'extern "cmath"\n  export def cos(x: C.Double) -> C.Double\nend\n'
SYSTEM_MAIN = 'import Math from "pkg/pkgdemo/math"\n\ndef main() -> Void\n  puts(Math.cos(0.0))\nend\n'
# The libraries of the C runtime and the math library, found by name by the system loader.
SYSTEM_TABLE = """[native.cmath]
linux = { system = "libm.so.6" }
macos = { system = "libSystem.B.dylib" }
windows = { system = "ucrtbase.dll" }
"""


def environment_of(ws):
    return vm_environment({"AGENTICA_PATH": "", **ws.cache_variables})


def manifest(extra):
    return 'name = "pkgdemo"\n\n' + extra


def table(**files):
    """A [native.pkgdemo] table that names a file of the package for each of these systems."""
    return "[native.pkgdemo]\n" + "".join('%s = { file = "%s" }\n' % pair for pair in files.items())


def library_path(system):
    return "native/%s/%s" % (system, library_name("pkgdemo"))


@pytest.fixture(scope="module")
def library(tmp_path_factory):
    """The bytes of the library built for this system."""
    path = shared_library(tmp_path_factory, "pkgdemo")
    return path.read_bytes()


def declare(ws, files, extra_manifest, name="pkgdemo"):
    """A package in deps/ and the lock, by hand, with this manifest text; the project imports it."""
    ws.add_package(name, "https://example.test/owner/pkgdemo", {**files, "agentica.toml": manifest(extra_manifest)})
    ws.write_manifest({name: dependency("https://example.test/owner/pkgdemo", tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def files_of(library):
    """The package: the module, the library of this system and files for the other systems that this one never opens."""
    # The dotfile and Thumbs.db are never part of the package.
    return {"demo.agc": DEMO, library_path(HERE): library, "native/other/lib.bin": b"not a library for here",
            "native/.DS_Store": b"junk", "native/Thumbs.db": b"junk"}


def table_of_all():
    other = "native/other/lib.bin"
    return table(**{"linux": other, "macos": other, "windows": other, HERE: library_path(HERE)})


@NATIVE_CALLS
def test_a_package_ships_a_library_install_copies_it_and_a_build_opens_it_by_its_path(library, remotes, ws, tmp_path):
    files = {**files_of(library), "agentica.toml": manifest(table_of_all())}
    commit = remotes.publish(REPO, files, tag="v1.0.0")
    lock_entry(ws, remotes, REPO, files, commit, tag="v1.0.0")
    ws.write_manifest({"pkgdemo": dependency(remotes.url(REPO), tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")

    result, problem = install(ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    # Every file of native/ is copied, for all systems, and is part of the hash of the lock.
    assert cached_files(ws.deps / "pkgdemo") == sorted(
        ["agentica.toml", "demo.agc", library_path(HERE), "native/other/lib.bin"])
    assert package_hash(ws.deps / "pkgdemo") == ws.locked[0]["hash"]

    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    # The same program again is served from _build/ and still works; native code is refused where it is denied.
    again = build(ws, remotes)
    assert (again.code, again.stdout) == (0, "42\n"), again.stderr
    for flag in ("--deny-native", "--sandbox"):
        denied = plain(ws, remotes, flag, str(ws.project / "main.agc"))
        assert denied.code == 2, flag
        assert json.loads(plain(ws, remotes, "--json", flag, str(ws.project / "main.agc")).stderr)["code"] == \
            "RUNTIME-NATIVE-DENIED"

    # A library edited in deps/ is not the locked one: the cached program is not used and the hash is checked.
    path = ws.deps / "pkgdemo" / library_path(HERE)
    path.write_bytes(path.read_bytes() + b"\0")
    assert build(ws, remotes).code == 1
    assert problem_of(ws, remotes)["code"] == "PKG-HASH-MISMATCH"
    assert install(ws, remotes)[1] is None
    assert build(ws, remotes).stdout == "42\n"

    # Any other file of native/ is covered too (a library may load a sibling), warm cache or not.
    sibling = ws.deps / "pkgdemo" / "native" / "other" / "lib.bin"
    assert build(ws, remotes).code == 0
    sibling.write_bytes(b"swapped")
    assert build(ws, remotes).code == 1
    assert problem_of(ws, remotes)["code"] == "PKG-HASH-MISMATCH"
    assert install(ws, remotes)[1] is None

    # The manifest picks the library, so it is covered: pointing it at another file or a system library is a mismatch
    # with a warm cache (the entry watches the manifest), with none, and `install` puts the locked one back.
    manifest_file = ws.deps / "pkgdemo" / "agentica.toml"
    locked_manifest = manifest_file.read_text(encoding="utf-8")
    assert build(ws, remotes).stdout == "42\n"
    for swapped in (table(**{HERE: "native/other/lib.bin"}), '[native.pkgdemo]\n%s = { system = "libc.so.6" }\n' % HERE):
        manifest_file.write_text(manifest(swapped), encoding="utf-8")
        assert build(ws, remotes).code == 1
        assert plain(ws, remotes, "--no-cache", str(ws.project / "main.agc")).code == 1
        assert problem_of(ws, remotes)["code"] == "PKG-HASH-MISMATCH"
        assert install(ws, remotes)[1] is None
        assert manifest_file.read_text(encoding="utf-8") == locked_manifest
    assert build(ws, remotes).stdout == "42\n"


@NATIVE_CALLS
def test_a_project_declares_its_own_libraries_and_its_files_use_them(library, ws):
    path = ws.project / library_path(HERE)
    path.parent.mkdir(parents=True)
    path.write_bytes(library)
    (ws.project / "agentica.toml").write_text(manifest(table(**{HERE: library_path(HERE)})), encoding="utf-8")
    own = DEMO + "\ndef main() -> Void\n  puts(pkgdemo_add(40, 2))\nend\n"
    (ws.project / "main.agc").write_text(own, encoding="utf-8")
    ran = run(cli() + [str(ws.project / "main.agc")], cwd=ws.project, env=environment_of(ws))
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    # A file the project lacks is PKG-NATIVE-MISSING at the project's manifest.
    path.unlink()
    assert_at_key(check(ws), "PKG-NATIVE-MISSING", ws.project / "agentica.toml", "native.pkgdemo.%s.file" % HERE)


@NATIVE_CALLS
def test_a_system_library_is_named_for_each_system_and_needs_no_file(ws):
    declare(ws, {"math.agc": LIBM}, SYSTEM_TABLE)
    (ws.project / "main.agc").write_text(SYSTEM_MAIN, encoding="utf-8")
    ran = run(cli() + [str(ws.project / "main.agc")], cwd=ws.project, env=environment_of(ws))
    assert (ran.code, ran.stdout) == (0, "1.0\n"), ran.stderr


def check(ws):
    """The problem that `--json check` reports for main.agc of the project, or None."""
    result = run(cli() + ["--json", "check", str(ws.project / "main.agc")], cwd=ws.project, env=environment_of(ws))
    return json.loads(result.stderr) if result.code == 1 else None


def test_a_manifest_without_native_files_or_a_native_table_is_not_part_of_the_hash(ws):
    declare(ws, {"demo.agc": DEMO}, "# a note\n")
    assert check(ws) is None
    (ws.deps / "pkgdemo" / "agentica.toml").write_text(manifest("# another note\n"), encoding="utf-8")
    assert check(ws) is None


@host_only(WINDOWS, "a symbolic link needs a privilege on Windows")
def test_a_link_named_native_is_a_symlink_error_in_the_build_and_in_the_fetch(ws, remotes, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "lib.bin").write_bytes(b"x")
    declare(ws, {"demo.agc": DEMO}, table(**{HERE: library_path(HERE)}))
    (ws.deps / "pkgdemo" / "native").symlink_to(outside, target_is_directory=True)
    assert check(ws)["code"] == "PKG-SYMLINK"
    files = {"demo.agc": DEMO}
    commit = remotes.publish(REPO, files, tag="v1.0.0", links={"native": "outside"})
    ws.locked.clear()
    lock_entry(ws, remotes, REPO, files, commit, tag="v1.0.0")
    ws.write_manifest({"pkgdemo": dependency(remotes.url(REPO), tag="v1.0.0")})
    ws.write_lock()
    shutil.rmtree(ws.deps)
    result, problem = install(ws, remotes)
    assert result.code == 1 and problem["code"] == "PKG-SYMLINK"


def test_a_package_that_names_no_library_for_this_system_is_refused_where_it_uses_it(ws):
    declare(ws, {"demo.agc": DEMO}, table(**{OTHER: library_path(OTHER)}))
    assert_at_key(check(ws), "PKG-NATIVE-PLATFORM", ws.deps / "pkgdemo" / "agentica.toml", "native.pkgdemo")


def test_a_library_file_that_the_package_lacks_is_pkg_native_missing_at_its_key(ws):
    declare(ws, {"demo.agc": DEMO}, table(**{HERE: library_path(HERE)}))
    assert_at_key(check(ws), "PKG-NATIVE-MISSING", ws.deps / "pkgdemo" / "agentica.toml",
                  "native.pkgdemo.%s.file" % HERE)


def test_an_extern_name_that_the_manifest_does_not_declare_stays_a_system_library_name(ws):
    declare(ws, {"demo.agc": DEMO}, table(**{HERE: library_path(HERE)}).replace("pkgdemo", "other"))
    # Nothing declares pkgdemo, so the name goes to the system loader unchanged: the check passes, and a run would
    # fail to open it (RUNTIME-NATIVE-LOAD).
    assert check(ws) is None


@pytest.mark.parametrize("text, key", [
    ('[native.pkgdemo]\nfreebsd = { system = "libc.so" }\n', "native.pkgdemo.freebsd"),
    ('[native.pkgdemo]\nlinux = { file = "lib/x.so" }\n', "native.pkgdemo.linux.file"),
    ('[native.pkgdemo]\nlinux = { file = "native/../x.so" }\n', "native.pkgdemo.linux.file"),
    ('[native.pkgdemo]\nlinux = { file = "native/x.so", system = "libx.so" }\n', "native.pkgdemo.linux"),
    ('[native.pkgdemo]\nlinux = { system = "/usr/lib/libx.so" }\n', "native.pkgdemo.linux.system"),
    ('[native.pkgdemo]\nlinux = { url = "https://example.test/x.so" }\n', "native.pkgdemo.linux.url"),
    ('[native.Demo]\nlinux = { system = "libx.so" }\n', "native.Demo"),
])
def test_a_bad_native_table_is_pkg_manifest_invalid_at_its_key(ws, text, key):
    declare(ws, {"demo.agc": DEMO}, text)
    assert_at_key(check(ws), "PKG-MANIFEST-INVALID", ws.deps / "pkgdemo" / "agentica.toml", key)
