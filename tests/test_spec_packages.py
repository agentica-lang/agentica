"""Package imports, the manifest and the lock, through the CLI (docs/future/45-packages.md, phase 45a).

Each case builds a project folder and a package cache folder by hand (there is no fetching yet), runs `--json check` on
the root file and asserts the code and where it is: the span of the import, or the file and key path of a manifest or
lock error. Message and help text are not asserted (AGENTS.md).
"""
import json
import os
from pathlib import Path

import pytest

from tests.agentica_test import POSIX_PYTHON, WINDOWS, cli, run, vm_environment
from tests.package_support import COMMIT, Workspace, package_hash

# No AGENTICA_PATH roots and no user data folder, so only what a case builds resolves; the cache is each case's own.
HERMETIC = {"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg",
            "LOCALAPPDATA": "/nonexistent-agentica-xdg"}

GREET = ('import Shout from "util/shout"\nimport Tools from "gitlab.com/team/tools/bang"\n\n'
         'export def hello(name: String) -> String\n  return Shout.shout("hello #{name}") + Tools.bang()\nend\n')
SHOUT = "export def shout(text: String) -> String\n  return text.upcase\nend\n"
BANG = 'export def bang() -> String\n  return "!"\nend\n'
MAIN = 'import Greet from "owner/repo/greet"\n\ndef main() -> Void\n  puts(Greet.hello("ana"))\nend\n'


@pytest.fixture
def ws(tmp_path):
    """A project that depends on owner/repo, which depends on gitlab.com/team/tools: both are in the cache."""
    workspace = Workspace(tmp_path)
    workspace.add_package("gitlab.com/team/tools", "0.4.1", {"bang.agc": BANG})
    workspace.add_package("owner/repo", "1.2.3", {"greet.agc": GREET, "util/shout.agc": SHOUT},
                          requires=["gitlab.com/team/tools@0.4.0"])
    workspace.write_manifest({"owner/repo": "1.2.0"})
    workspace.write_lock()
    (workspace.project / "main.agc").write_text(MAIN, encoding="utf-8")
    return workspace


def environment(ws, **extra):
    return vm_environment({**HERMETIC, "XDG_CACHE_HOME": str(ws.cache), **extra})


def check(ws, root="main.agc", **extra):
    """The problem that `--json check` reports for a file of the project, or None when it checks clean."""
    result = run(cli() + ["--json", "check", str(ws.project / root)], cwd=ws.base, env=environment(ws, **extra))
    if result.code == 0:
        assert result.stdout == '{"ok":true}\n'
        return None
    assert result.code == 1, result.stderr
    return json.loads(result.stderr)


def start(problem):
    return problem["range"]["start"]["line"], problem["range"]["start"]["column"]


def assert_at_key(problem, code, file, key_path):
    assert problem["code"] == code
    assert Path(problem["file"]) == Path(file)
    # A failure of the file as a whole (the lock that is missing) has no key path.
    assert problem.get("key_path", "") == key_path


def assert_at_import(problem, code, line=1):
    assert problem["code"] == code
    assert start(problem) == (line, 1)
    assert "key_path" not in problem


def test_a_package_import_runs_from_the_cache_and_stores_logical_paths(ws, tmp_path):
    # The program imports owner/repo, which imports its own util/shout and its dependency gitlab.com/team/tools.
    run_result = run(cli() + [str(ws.project / "main.agc")], cwd=ws.base, env=environment(ws))
    assert (run_result.code, run_result.stdout) == (0, "HELLO ANA!\n"), run_result.stderr
    # The .agcb names each package file by key, version and path, so its bytes do not depend on the cache folder.
    built = []
    for index in range(2):
        other = Workspace(tmp_path / ("copy%d" % index))
        other.add_package("gitlab.com/team/tools", "0.4.1", {"bang.agc": BANG})
        other.add_package("owner/repo", "1.2.3", {"greet.agc": GREET, "util/shout.agc": SHOUT},
                          requires=["gitlab.com/team/tools@0.4.0"])
        other.write_manifest({"owner/repo": "1.2.0"})
        other.write_lock()
        (other.project / "main.agc").write_text(MAIN, encoding="utf-8")
        output = tmp_path / ("out%d.agcb" % index)
        result = run(cli() + ["compile", str(other.project / "main.agc"), "-o", str(output)], cwd=other.base,
                     env=environment(other))
        assert result.code == 0, result.stderr
        built.append(output.read_bytes())
    assert built[0] == built[1]
    for name in [b"owner/repo@1.2.3/greet.agc", b"owner/repo@1.2.3/util/shout.agc",
                 b"gitlab.com/team/tools@0.4.1/bang.agc", b"main.agc"]:
        assert name in built[0]
    assert str(tmp_path).encode() not in built[0]


def test_the_hash_covers_the_agc_files_only_and_matches_a_second_implementation(ws, tmp_path):
    # Non-.agc files, a hidden folder and the agc_libs folder of the package are not hashed: adding them changes nothing.
    folder = ws.folder("owner/repo")
    (folder / "README.md").write_text("not code", encoding="utf-8")
    (folder / ".git").mkdir()
    (folder / ".git" / "x.agc").write_text("junk", encoding="utf-8")
    (folder / "agc_libs").mkdir()
    (folder / "agc_libs" / "y.agc").write_text("junk", encoding="utf-8")
    assert check(ws) is None
    # A package of many files, a name that is not ASCII and a file larger than the 256 KiB the hash reads at a time:
    # the lock holds the hash that Python computed, so the two implementations agree on it.
    big = {"core.agc": "export def one() -> Int\n  return 1\nend\n", "módulo/x.agc": "# é\n",
           "a.agc": "# a\n", "a/b.agc": "# b\n", "big.agc": "# " + "x" * 300000 + "\n"}
    big.update({"part%02d.agc" % number: "# %d\n" % number for number in range(40)})
    ws.add_package("big/pack", "1.0.0", big)
    ws.write_manifest({"owner/repo": "1.2.0", "big/pack": "1.0.0"})
    ws.write_lock()
    (ws.project / "big.agc").write_text(
        'import Core from "big/pack/core"\n\ndef main() -> Void\n  puts(Core.one())\nend\n', encoding="utf-8")
    assert check(ws, "big.agc") is None
    assert package_hash(ws.folder("big/pack")).startswith("sha256:")


MANIFEST_CASES = [
    ("an unknown key", 'colour = "red"\n', "colour"),
    ("a key that is not lowercase", '[dependencies]\n"Owner/Repo" = "1.0.0"\n', "dependencies.Owner/Repo"),
    ("GitHub written with its host", '[dependencies]\n"github.com/owner/repo" = "1.0.0"\n',
     "dependencies.github.com/owner/repo"),
    ("a reserved first part", '[dependencies]\n"std/queue" = "1.0.0"\n', "dependencies.std/queue"),
    ("a minimum that is not a version", '[dependencies]\n"owner/repo" = "1.x"\n', "dependencies.owner/repo"),
    ("a dependency that is not a string", '[dependencies]\n"owner/repo" = 1\n', "dependencies.owner/repo"),
    ("a name that is not a key", 'name = "Not A Key"\n', "name"),
    ("a version that is not semver", 'version = "1.2"\n', "version"),
    ("an unknown style key", '[style]\ncolour = 1\n', "style.colour"),
    ("a style width that is not positive", '[style]\nmax_line_width = 0\n', "style.max_line_width"),
    ("a table where a string goes", 'name = { a = 1 }\n', "name"),
]


@pytest.mark.parametrize("what, text, key_path", MANIFEST_CASES, ids=[case[0] for case in MANIFEST_CASES])
def test_a_bad_manifest_names_the_file_and_the_key_path(ws, what, text, key_path):
    (ws.project / "agentica.toml").write_text(text, encoding="utf-8")
    assert_at_key(check(ws), "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key_path)


def test_a_toml_syntax_error_in_the_manifest_has_a_line_and_column(ws):
    (ws.project / "agentica.toml").write_text('name = "x"\n[dependencies\n', encoding="utf-8")
    problem = check(ws)
    assert problem["code"] == "PKG-MANIFEST-INVALID"
    assert Path(problem["file"]) == ws.project / "agentica.toml"
    assert start(problem) == (2, 14)
    assert "key_path" not in problem


def test_the_manifest_is_found_above_the_root_file_and_a_project_with_no_dependency_needs_no_lock(ws):
    (ws.project / "src").mkdir()
    (ws.project / "src" / "main.agc").write_text(MAIN, encoding="utf-8")
    assert check(ws, "src/main.agc") is None
    (ws.project / "agentica.lock").unlink()
    assert_at_key(check(ws, "src/main.agc"), "PKG-LOCK-MISSING", ws.project / "agentica.lock", "")
    # A manifest with no dependency (as compiler/agentica.toml is) asks nothing of the build.
    (ws.project / "agentica.toml").write_text('[style]\nmax_line_width = 119\n', encoding="utf-8")
    (ws.project / "plain.agc").write_text("def main() -> Void\nend\n", encoding="utf-8")
    assert check(ws, "plain.agc") is None


def lock_edit(change):
    return lambda ws: ws.write_lock(change)


def drop(key):
    return lambda entries: [entry.pop(key) for entry in entries if entry["name"] == "owner/repo"]


def set_field(key, value, name="owner/repo"):
    def edit(entries):
        for entry in entries:
            if entry["name"] == name:
                entry[key] = value
    return edit


# (what, edit of the lock entries, code, file of the report, key path); entries are sorted by name, so the package
# gitlab.com/team/tools is entry 0 and owner/repo is entry 1.
LOCK_CASES = [
    ("a package with no hash", drop("hash"), "PKG-LOCK-INVALID", "agentica.lock", "package[1].hash"),
    ("a hash that is not a hash", set_field("hash", "sha256:abc"), "PKG-LOCK-INVALID", "agentica.lock",
     "package[1].hash"),
    ("a commit that is not a commit", set_field("commit", "main"), "PKG-LOCK-INVALID", "agentica.lock",
     "package[1].commit"),
    ("a version that is not semver", set_field("version", "one"), "PKG-LOCK-INVALID", "agentica.lock",
     "package[1].version"),
    ("a requirement that is not key@minimum", set_field("requires", ["gitlab.com/team/tools"]), "PKG-LOCK-INVALID",
     "agentica.lock", "package[1].requires[0]"),
    ("a package locked twice", set_field("name", "gitlab.com/team/tools"), "PKG-LOCK-INVALID", "agentica.lock",
     "package[1].name"),
    ("a locked version below a minimum of the manifest", set_field("version", "1.1.0"), "PKG-LOCK-STALE",
     "agentica.toml", "dependencies.owner/repo"),
    ("a locked version below a minimum of another package", set_field("version", "0.3.0", "gitlab.com/team/tools"),
     "PKG-LOCK-STALE", "agentica.lock", "package[1].requires[0]"),
    ("a requirement that the lock does not hold", set_field("requires", ["acme/other@1.0.0"]), "PKG-LOCK-STALE",
     "agentica.lock", "package[1].requires[0]"),
    ("another major than the manifest asks for", set_field("version", "2.0.0"), "PKG-MAJOR-CONFLICT", "agentica.toml",
     "dependencies.owner/repo"),
]


@pytest.mark.parametrize("what, edit, code, file, key_path", LOCK_CASES, ids=[case[0] for case in LOCK_CASES])
def test_a_lock_that_is_bad_or_stale_names_the_file_and_the_key_path(ws, what, edit, code, file, key_path):
    ws.write_lock(edit)
    assert_at_key(check(ws), code, ws.project / file, key_path)


def test_the_lock_must_hold_every_dependency_of_the_manifest(ws):
    ws.write_manifest({"owner/repo": "1.2.0", "owner/other": "1.0.0"})
    assert_at_key(check(ws), "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.owner/other")
    (ws.project / "agentica.lock").write_text("version = 2\n", encoding="utf-8")
    assert_at_key(check(ws), "PKG-LOCK-INVALID", ws.project / "agentica.lock", "version")


def test_a_cache_that_does_not_match_the_lock_is_refused_when_the_package_is_loaded(ws):
    greet = ws.folder("owner/repo") / "greet.agc"
    original = greet.read_bytes()
    greet.write_bytes(original + b"# changed\n")
    assert_at_import(check(ws), "PKG-HASH-MISMATCH")
    greet.write_bytes(original)
    assert check(ws) is None
    # A new .agc file changes the listing, so it changes the hash too.
    (ws.folder("owner/repo") / "extra.agc").write_text("# new\n", encoding="utf-8")
    assert_at_import(check(ws), "PKG-HASH-MISMATCH")
    # The hash is checked for what a build loads: a file that imports nothing from the package never pays for it.
    (ws.project / "plain.agc").write_text("def main() -> Void\nend\n", encoding="utf-8")
    assert check(ws, "plain.agc") is None


@pytest.mark.skipif(not POSIX_PYTHON, reason="host-only: a symbolic link needs no privilege on POSIX only")
def test_a_symbolic_link_among_the_agc_files_of_a_package_is_refused(ws):
    folder = ws.folder("owner/repo")
    (folder / "linked.agc").symlink_to(folder / "greet.agc")
    assert_at_import(check(ws), "PKG-SYMLINK")


def test_a_package_that_is_not_in_the_cache_says_so(ws, tmp_path):
    ws.cache.rename(tmp_path / "moved")
    assert_at_import(check(ws), "CHECK-IMPORT-PACKAGE")
    # With no cache folder at all (no usable XDG_CACHE_HOME and no HOME), the import says so as well.
    problem = check(ws, XDG_CACHE_HOME="relative", HOME=None, LOCALAPPDATA=None)
    assert_at_import(problem, "CHECK-IMPORT-PACKAGE")


def test_the_cache_folder_follows_the_environment_of_the_system(ws, tmp_path):
    # Where the cache is: XDG_CACHE_HOME, else ~/.cache, and %LOCALAPPDATA%/agentica/cache on Windows.
    home = tmp_path / "home"
    (home / ".cache").mkdir(parents=True)
    ws.cache.rename(home / ".cache")
    if WINDOWS:
        data = tmp_path / "data"
        (data / "agentica" / "cache").mkdir(parents=True)
        (home / ".cache" / "agentica" / "pkg").rename(data / "agentica" / "cache" / "pkg")
        # XDG_CACHE_HOME and HOME are not read on Windows.
        problem = check(ws, XDG_CACHE_HOME=str(tmp_path / "nowhere"), HOME=str(home), LOCALAPPDATA=str(data))
        assert problem is None
        assert_at_import(check(ws, HOME=str(home), LOCALAPPDATA="relative"), "CHECK-IMPORT-PACKAGE")
        return
    assert check(ws, XDG_CACHE_HOME="relative", HOME=str(home)) is None
    assert check(ws, XDG_CACHE_HOME="", HOME=str(home)) is None
    assert_at_import(check(ws, XDG_CACHE_HOME=str(tmp_path / "nowhere"), HOME=str(home)), "CHECK-IMPORT-PACKAGE")
    # LOCALAPPDATA is read on Windows only.
    assert check(ws, XDG_CACHE_HOME="relative", HOME=str(home), LOCALAPPDATA=str(tmp_path / "nowhere")) is None


def test_a_package_is_written_one_way_and_a_clash_with_a_relative_path_is_ambiguous(ws):
    root = ws.project / "main.agc"
    cases = [
        ('import G from "github.com/owner/repo/greet"\n', "CHECK-IMPORT-PATH"),
        ('import G from "owner/repo"\n', "CHECK-IMPORT-PATH"),
        ('import G from "owner/repo/../repo/greet"\n', "CHECK-IMPORT-PATH"),
        ('import G from "owner/repo/missing"\n', "CHECK-IMPORT-IO"),
        # A package that the manifest does not declare is an ordinary relative path, as before.
        ('import G from "gitlab.com/team/tools/bang"\n', "CHECK-IMPORT-IO"),
    ]
    for line, code in cases:
        root.write_text(line + "\ndef main() -> Void\nend\n", encoding="utf-8")
        assert_at_import(check(ws), code)
    # The folder or the file beside the importing file that the path also names.
    root.write_text(MAIN, encoding="utf-8")
    for relative in ["owner/repo/greet.agc", "owner/repo/other.agc"]:
        path = ws.project / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# a local file\n", encoding="utf-8")
        assert_at_import(check(ws), "CHECK-IMPORT-AMBIGUOUS")
        path.unlink()
        path.parent.rmdir()
        path.parent.parent.rmdir()
    assert check(ws) is None


def test_an_undeclared_name_in_the_project_stays_a_relative_path(ws):
    # `other/thing` is no key of the manifest, so the folder beside the file is imported as it always was.
    (ws.project / "other").mkdir()
    (ws.project / "other" / "thing.agc").write_text("export def one() -> Int\n  return 1\nend\n", encoding="utf-8")
    (ws.project / "local.agc").write_text(
        'import Thing from "other/thing"\n\ndef main() -> Void\n  puts(Thing.one())\nend\n', encoding="utf-8")
    assert check(ws, "local.agc") is None


# A line that a package file adds at its top, and the code of the report. The report is in the package file.
PACKAGE_IMPORT_CASES = [
    ("an import that leaves the package", 'import X from "../outside"\n', "CHECK-IMPORT-PATH"),
    ("an import of a hidden folder", 'import X from ".hidden/x"\n', "CHECK-IMPORT-PATH"),
    ("an import of agc_libs", 'import X from "agc_libs/x"\n', "CHECK-IMPORT-PATH"),
    ("a package it did not declare", 'import X from "acme/other/x"\n', "CHECK-IMPORT-IO"),
    ("a package of the project it does not require", 'import X from "owner/repo/util/shout"\n', "CHECK-IMPORT-IO"),
]


@pytest.mark.parametrize("what, line, code", PACKAGE_IMPORT_CASES, ids=[case[0] for case in PACKAGE_IMPORT_CASES])
def test_a_package_file_may_import_only_inside_itself_and_what_the_lock_says_it_requires(ws, what, line, code):
    # The package is built again with the added import, and the lock is made for it.
    ws.add_package("owner/repo", "1.2.3", {"greet.agc": line + GREET, "util/shout.agc": SHOUT,
                                            ".hidden/x.agc": SHOUT, "agc_libs/x.agc": SHOUT},
                   requires=["gitlab.com/team/tools@0.4.0"], commit="b" * 40)
    ws.locked = [entry for entry in ws.locked if entry["commit"] != COMMIT or entry["name"] != "owner/repo"]
    ws.write_lock()
    problem = check(ws)
    assert problem["code"] == code
    assert Path(problem["file"]) == ws.folder("owner/repo", "b" * 40) / "greet.agc"
    assert start(problem) == (1, 1)


def test_the_root_may_import_only_its_direct_dependencies(ws):
    # gitlab.com/team/tools is in the lock because owner/repo requires it, but the manifest does not declare it.
    (ws.project / "main.agc").write_text(
        'import Tools from "gitlab.com/team/tools/bang"\n\ndef main() -> Void\n  puts(Tools.bang())\nend\n',
        encoding="utf-8")
    assert_at_import(check(ws), "CHECK-IMPORT-IO")


def test_the_manifest_directory_holds_agc_libs_when_there_is_a_manifest(ws):
    # pkg/ libraries are searched in agc_libs/ beside agentica.toml, even for a root file in a folder below it.
    (ws.project / "agc_libs").mkdir()
    (ws.project / "agc_libs" / "tool.agc").write_text("export def one() -> Int\n  return 1\nend\n", encoding="utf-8")
    (ws.project / "src").mkdir()
    (ws.project / "src" / "use.agc").write_text(
        'import Tool from "pkg/tool"\n\ndef main() -> Void\n  puts(Tool.one())\nend\n', encoding="utf-8")
    assert check(ws, "src/use.agc") is None
    (ws.project / "src" / "agc_libs").mkdir()
    (ws.project / "agc_libs" / "tool.agc").rename(ws.project / "src" / "agc_libs" / "tool.agc")
    assert_at_import(check(ws, "src/use.agc"), "CHECK-IMPORT-IO")
    assert os.path.exists(ws.project / "src" / "agc_libs" / "tool.agc")
