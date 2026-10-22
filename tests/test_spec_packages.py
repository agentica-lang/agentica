"""Package imports, the manifest and the lock, through the CLI (docs/future/45-packages.md, phase 45a).

Each case builds a project folder with its deps/ folder by hand (no fetching), runs `--json check` on
the root file and asserts the code and where it is: the span of the import, or the file and key path of a manifest or
lock error. Message and help text are not asserted (AGENTS.md).
"""
import json
import os
import shutil
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, unreadable, vm_environment
from tests.package_support import COMMIT, Workspace, dependency, package_hash

# No AGENTICA_PATH roots and no user data folder, so only what a case builds resolves; deps/ is each case's own.
HERMETIC = {"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg",
            "LOCALAPPDATA": "/nonexistent-agentica-xdg"}

# root can read a folder whatever its mode, so the cases that need an unreadable one do not hold for it.
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0

GREETER_GIT = "https://github.com/owner/greeter.git"
TOOLS_GIT = "https://gitlab.com/team/tools"
# The project depends on `greeter` (a tag), which depends on `tools` (a ref), as its own manifest says.
GREETER = dependency(GREETER_GIT, tag="v1.2.3")
TOOLS = dependency(TOOLS_GIT, ref="bbbbbbb")
TOOLS_COMMIT = "b" * 40

GREET = ('import Shout from "util/shout"\nimport Tools from "pkg/tools/bang"\n\n'
         'export def hello(name: String) -> String\n  return Shout.shout("hello #{name}") + Tools.bang()\nend\n')
SHOUT = "export def shout(text: String) -> String\n  return text.upcase\nend\n"
BANG = 'export def bang() -> String\n  return "!"\nend\n'
ONE = "export def one() -> Int\n  return 1\nend\n"
MAIN = 'import Greet from "pkg/greeter/greet"\n\ndef main() -> Void\n  puts(Greet.hello("ana"))\nend\n'


def build(base):
    """A workspace whose project depends on greeter, which depends on tools: both are in deps/ and the lock."""
    workspace = Workspace(base)
    workspace.add_package("tools", TOOLS_GIT, {"bang.agc": BANG}, ref="bbbbbbb", commit=TOOLS_COMMIT)
    workspace.add_package("greeter", GREETER_GIT, {"greet.agc": GREET, "util/shout.agc": SHOUT}, tag="v1.2.3",
                          dependencies={"tools": TOOLS})
    workspace.write_manifest({"greeter": GREETER})
    workspace.write_lock()
    (workspace.project / "main.agc").write_text(MAIN, encoding="utf-8")
    return workspace


@pytest.fixture
def ws(tmp_path):
    return build(tmp_path)


def environment(ws, **extra):
    return vm_environment({**HERMETIC, **ws.cache_variables, **extra})


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
    # A failure of the file as a whole (the lock that is missing) has no key path and no place in the file.
    assert problem.get("key_path", "") == key_path
    if key_path == "":
        assert start(problem) == (0, 0)


def assert_at_import(problem, code, line=1):
    assert problem["code"] == code
    assert start(problem) == (line, 1)
    assert "key_path" not in problem


def test_a_package_module_cannot_import_the_private_core_of_std(ws):
    # Only a module of std/ may import std/internal/; a locked package is not one, and its file is named in the error.
    snoop = 'import Ast from "std/internal/compiler/syntax/ast"\n\nexport def one() -> Int\n  return 1\nend\n'
    git = "https://github.com/owner/snoop.git"
    ws.add_package("snoop", git, {"snoop.agc": snoop})
    ws.write_manifest({"greeter": GREETER, "snoop": dependency(git, tag="v1.0.0")})
    ws.write_lock()
    write_main(ws, 'import Snoop from "pkg/snoop/snoop"')
    problem = check(ws)
    assert problem["code"] == "CHECK-IMPORT-IO"
    assert Path(problem["file"]).name == "snoop.agc"
    assert problem["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 2, "column": 1}}


def write_main(ws, text):
    (ws.project / "main.agc").write_text(text + "\ndef main() -> Void\nend\n", encoding="utf-8")


def test_a_package_import_runs_from_deps_and_stores_logical_paths(ws, tmp_path):
    # The program imports greeter, which imports its own util/shout and its dependency tools by pkg/tools/.
    ran = run(cli() + [str(ws.project / "main.agc")], cwd=ws.base, env=environment(ws))
    assert (ran.code, ran.stdout) == (0, "HELLO ANA!\n"), ran.stderr
    # The .agcb names each package file by name, version and path, so its bytes do not depend on the folder of the project.
    built = []
    for index in range(2):
        other = build(tmp_path / ("copy%d" % index))
        output = tmp_path / ("out%d.agcb" % index)
        result = run(cli() + ["compile", str(other.project / "main.agc"), "-o", str(output)], cwd=other.base,
                     env=environment(other))
        assert result.code == 0, result.stderr
        built.append(output.read_bytes())
    assert built[0] == built[1]
    # A tag names the version; a ref names the first 12 digits of the commit.
    for name in [b"pkg/greeter@v1.2.3/greet.agc", b"pkg/greeter@v1.2.3/util/shout.agc",
                 b"pkg/tools@bbbbbbbbbbbb/bang.agc", b"main.agc"]:
        assert name in built[0]
    assert str(tmp_path).encode() not in built[0]


def test_the_hash_covers_the_agc_files_only_and_matches_a_second_implementation(ws):
    # Non-.agc files, a hidden folder and the agc_libs folder of the package are not hashed: adding them changes nothing.
    folder = ws.deps / "greeter"
    (folder / "README.md").write_text("not code", encoding="utf-8")
    (folder / ".git").mkdir()
    (folder / ".git" / "x.agc").write_text("junk", encoding="utf-8")
    (folder / "agc_libs").mkdir()
    (folder / "agc_libs" / "y.agc").write_text("junk", encoding="utf-8")
    assert check(ws) is None
    # A package of many files, a name that is not ASCII and a file larger than the 256 KiB the hash reads at a time:
    # the lock holds the hash that Python computed, so the two implementations agree on it.
    big = {"core.agc": ONE, "módulo/x.agc": "# é\n", "a.agc": "# a\n", "a/b.agc": "# b\n",
           "big.agc": "# " + "x" * 300000 + "\n"}
    big.update({"part%02d.agc" % number: "# %d\n" % number for number in range(40)})
    ws.add_package("big", "https://github.com/big/pack", big)
    ws.write_manifest({"greeter": GREETER, "big": dependency("https://github.com/big/pack", tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "big.agc").write_text(
        'import Core from "pkg/big/core"\n\ndef main() -> Void\n  puts(Core.one())\nend\n', encoding="utf-8")
    assert check(ws, "big.agc") is None
    assert package_hash(ws.deps / "big").startswith("sha256:")


def deps(line):
    return '[dependencies]\n%s\n' % line


SOURCE = 'git = "https://github.com/owner/repo"'

MANIFEST_CASES = [
    ("an unknown key", 'colour = "red"\n', "colour"),
    ("the old version key", 'version = "1.0.0"\n', "version"),
    ("a name that is not a package name", 'name = "Not A Name"\n', "name"),
    ("a table where a string goes", 'name = { a = 1 }\n', "name"),
    ("a dependency name with capitals", deps('Sqlite = { %s, tag = "v1" }' % SOURCE), "dependencies.Sqlite"),
    ("a dependency name that is an owner/repo", deps('"owner/repo" = { %s, tag = "v1" }' % SOURCE),
     "dependencies.owner/repo"),
    ("a dependency name that starts with a digit", deps('"1x" = { %s, tag = "v1" }' % SOURCE), "dependencies.1x"),
    ("a dependency that is a string", deps('sqlite = "1.0.0"'), "dependencies.sqlite"),
    ("a dependency with no git", deps('sqlite = { tag = "v1" }'), "dependencies.sqlite"),
    ("a source that is a path", deps('sqlite = { path = "../x" }'), "dependencies.sqlite.path"),
    ("a branch", deps('sqlite = { %s, branch = "main" }' % SOURCE), "dependencies.sqlite.branch"),
    ("a version range", deps('sqlite = { %s, version = "^1" }' % SOURCE), "dependencies.sqlite.version"),
    ("neither a tag nor a ref", deps('sqlite = { %s }' % SOURCE), "dependencies.sqlite"),
    ("both a tag and a ref", deps('sqlite = { %s, tag = "v1", ref = "abcdef0" }' % SOURCE), "dependencies.sqlite"),
    ("a tag that is not a string", deps('sqlite = { %s, tag = 1 }' % SOURCE), "dependencies.sqlite.tag"),
    ("a tag with a slash", deps('sqlite = { %s, tag = "rel/1" }' % SOURCE), "dependencies.sqlite.tag"),
    ("a ref that is too short", deps('sqlite = { %s, ref = "abc" }' % SOURCE), "dependencies.sqlite.ref"),
    ("a ref in capitals", deps('sqlite = { %s, ref = "ABCDEF0" }' % SOURCE), "dependencies.sqlite.ref"),
    ("a git URL over http", deps('sqlite = { git = "http://github.com/o/r", tag = "v1" }'), "dependencies.sqlite.git"),
    ("a git URL for ssh", deps('sqlite = { git = "git@github.com:o/r.git", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git URL with a port", deps('sqlite = { git = "https://github.com:8443/o/r", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git URL with a user", deps('sqlite = { git = "https://me@github.com/o/r", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git URL with a host in capitals", deps('sqlite = { git = "https://GitHub.com/o/r", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git URL with one part", deps('sqlite = { git = "https://github.com/owner", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git URL with three parts", deps('sqlite = { git = "https://github.com/a/b/c", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git URL with a slash at the end", deps('sqlite = { git = "https://github.com/o/r/", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git URL with a query", deps('sqlite = { git = "https://github.com/o/r?x=1", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git owner that is a Windows device name", deps('sqlite = { git = "https://github.com/con/r", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a git repository that is a device name with an extension",
     deps('sqlite = { git = "https://github.com/o/NUL.txt", tag = "v1" }'), "dependencies.sqlite.git"),
    ("a git repository that is a numbered device name",
     deps('sqlite = { git = "https://github.com/o/com1", tag = "v1" }'), "dependencies.sqlite.git"),
    ("a git repository that ends in a dot", deps('sqlite = { git = "https://github.com/o/x..git", tag = "v1" }'),
     "dependencies.sqlite.git"),
    ("a tag that starts with a dot", deps('sqlite = { %s, tag = ".v1" }' % SOURCE), "dependencies.sqlite.tag"),
    ("a tag that starts with a dash", deps('sqlite = { %s, tag = "-v1" }' % SOURCE), "dependencies.sqlite.tag"),
    ("a tag of 129 characters", deps('sqlite = { %s, tag = "%s" }' % (SOURCE, "v" * 129)), "dependencies.sqlite.tag"),
    ("an unknown style key", '[style]\ncolour = 1\n', "style.colour"),
    ("a style width that is not positive", '[style]\nmax_line_width = 0\n', "style.max_line_width"),
]


@pytest.mark.parametrize("what, text, key_path", MANIFEST_CASES, ids=[case[0] for case in MANIFEST_CASES])
def test_a_bad_manifest_names_the_file_and_the_key_path(ws, what, text, key_path):
    (ws.project / "agentica.toml").write_text(text, encoding="utf-8")
    assert_at_key(check(ws), "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key_path)


def test_every_good_form_of_a_dependency_is_accepted(ws):
    forms = {"sqlite": dependency("https://github.com/owner/sqlite-ac", tag="v1.2.0"),
             "json5": dependency("https://gitlab.com/someone/json5.git", ref="3f2a9c1"),
             "a_b-2": dependency("https://git.example.org/Some.Owner/Repo_1", tag="1.0+build.5")}
    for name, entry in forms.items():
        commit = "3f2a9c1" + "0" * 33 if "ref" in entry else COMMIT
        ws.add_package(name, entry["git"], {"x.agc": ONE}, tag=entry.get("tag"), ref=entry.get("ref"), commit=commit)
    ws.write_manifest(forms)
    ws.write_lock()
    (ws.project / "plain.agc").write_text("def main() -> Void\nend\n", encoding="utf-8")
    assert check(ws, "plain.agc") is None


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


def set_field(key, value, name="greeter"):
    def edit(entries):
        for entry in entries:
            if entry["name"] == name:
                entry[key] = value
    return edit


def drop(key, name="greeter"):
    def edit(entries):
        for entry in entries:
            if entry["name"] == name:
                entry.pop(key, None)
    return edit


def both(first, second):
    return lambda entries: (first(entries), second(entries))


# (what, edit of the lock entries, key path); entries are sorted by name, so greeter is entry 0 and tools entry 1.
LOCK_CASES = [
    ("a package with no hash", drop("hash"), "package[0].hash"),
    ("a hash that is not a hash", set_field("hash", "sha256:abc"), "package[0].hash"),
    ("a hash in capitals", set_field("hash", "sha256:" + "A" * 64), "package[0].hash"),
    ("a commit that is not a commit", set_field("commit", "main"), "package[0].commit"),
    ("a commit that does not start with the ref", set_field("commit", "c" * 40, "tools"), "package[1].commit"),
    ("a package with no git", drop("git"), "package[0].git"),
    ("a git URL that is not https", set_field("git", "git@github.com:o/r.git"), "package[0].git"),
    ("a package with no tag and no ref", drop("tag"), "package[0]"),
    ("a package with a tag and a ref", set_field("ref", "abcdef0"), "package[0]"),
    ("a tag that is not a tag", set_field("tag", "a/b"), "package[0].tag"),
    ("a name that is not a package name", set_field("name", "Greeter"), "package[0].name"),
    ("a package locked twice", set_field("name", "tools"), "package[1].name"),
    ("a key the lock does not know", set_field("requires", []), "package[0].requires"),
]


@pytest.mark.parametrize("what, edit, key_path", LOCK_CASES, ids=[case[0] for case in LOCK_CASES])
def test_a_bad_lock_names_the_file_and_the_key_path(ws, what, edit, key_path):
    ws.write_lock(edit)
    assert_at_key(check(ws), "PKG-LOCK-INVALID", ws.project / "agentica.lock", key_path)


def test_a_lock_of_another_format_is_invalid(ws):
    (ws.project / "agentica.lock").write_text("version = 2\n", encoding="utf-8")
    assert_at_key(check(ws), "PKG-LOCK-INVALID", ws.project / "agentica.lock", "version")


STALE_CASES = [
    ("the lock has another tag", set_field("tag", "v1.2.4"), {}),
    ("the lock has another git URL", set_field("git", "https://github.com/owner/other.git"), {}),
    ("the lock pins a ref where the manifest has a tag", both(drop("tag"), set_field("ref", "aaaaaaa")), {}),
    ("the lock lacks a dependency of the manifest", lambda entries: entries.pop(0), {}),
    ("the manifest has a dependency that the lock lacks", None, {"extra": dependency("https://github.com/o/r", ref="abcdef0")}),
]


@pytest.mark.parametrize("what, edit, extra", STALE_CASES, ids=[case[0] for case in STALE_CASES])
def test_a_lock_that_differs_from_the_manifest_is_stale(ws, what, edit, extra):
    if extra:
        ws.write_manifest({"greeter": GREETER, **extra})
        expected = "dependencies.extra"
    else:
        ws.write_lock(edit)
        expected = "dependencies.greeter"
    assert_at_key(check(ws), "PKG-LOCK-STALE", ws.project / "agentica.toml", expected)


def test_the_same_spelling_of_a_git_URL_with_or_without_dot_git_is_one_source(ws):
    ws.write_manifest({"greeter": dependency(GREETER_GIT[:-4], tag="v1.2.3")})
    assert check(ws) is None


def test_one_name_with_two_sources_in_the_tree_is_a_conflict(ws):
    # The manifest of greeter, in deps/, asks for another tag of tools than the lock (and the project) has.
    manifest = ws.deps / "greeter" / "agentica.toml"
    manifest.write_text('[dependencies]\ntools = { git = "%s", tag = "v9.9.9" }\n' % TOOLS_GIT, encoding="utf-8")
    assert_at_key(check(ws), "PKG-SOURCE-CONFLICT", manifest, "dependencies.tools")
    # The same name from another repository.
    manifest.write_text('[dependencies]\ntools = { git = "https://gitlab.com/else/tools", ref = "bbbbbbb" }\n',
                        encoding="utf-8")
    assert_at_key(check(ws), "PKG-SOURCE-CONFLICT", manifest, "dependencies.tools")
    # A name that the lock does not hold at all is a lock that does not cover the tree.
    manifest.write_text('[dependencies]\nmore = { git = "https://gitlab.com/else/more", ref = "bbbbbbb" }\n',
                        encoding="utf-8")
    assert_at_key(check(ws), "PKG-LOCK-STALE", manifest, "dependencies.more")
    # The manifest of a package is checked like the project's: an unknown key is PKG-MANIFEST-INVALID in its file.
    manifest.write_text('colour = "red"\n', encoding="utf-8")
    assert_at_key(check(ws), "PKG-MANIFEST-INVALID", manifest, "colour")


def test_the_project_and_a_package_may_declare_one_name_with_the_same_source(ws):
    # The project asks for tools too, with the source the lock and greeter's manifest hold: not a conflict.
    ws.write_manifest({"greeter": GREETER, "tools": TOOLS})
    assert check(ws) is None


def test_a_folder_of_deps_that_does_not_match_the_lock_is_refused_when_the_package_is_loaded(ws):
    greet = ws.deps / "greeter" / "greet.agc"
    original = greet.read_bytes()
    greet.write_bytes(original + b"# changed\n")
    assert_at_import(check(ws), "PKG-HASH-MISMATCH")
    greet.write_bytes(original)
    assert check(ws) is None
    # A new .agc file changes the listing, so it changes the hash too.
    (ws.deps / "greeter" / "extra.agc").write_text("# new\n", encoding="utf-8")
    assert_at_import(check(ws), "PKG-HASH-MISMATCH")
    # The hash is checked for what a build loads: a file that imports nothing from the package never pays for it.
    (ws.project / "plain.agc").write_text("def main() -> Void\nend\n", encoding="utf-8")
    assert check(ws, "plain.agc") is None


def test_a_symbolic_link_among_the_agc_files_of_a_package_is_refused(ws):
    folder = ws.deps / "greeter"
    (folder / "linked.agc").symlink_to(folder / "greet.agc")
    assert_at_import(check(ws), "PKG-SYMLINK")


def test_a_declared_package_missing_from_deps_says_so_and_the_cache_is_not_needed(ws, tmp_path):
    # A build reads only deps/: it needs no package cache, and a package that deps/ lacks is CHECK-IMPORT-PACKAGE.
    shutil.rmtree(ws.cache, ignore_errors=True)
    assert check(ws, XDG_CACHE_HOME="relative", HOME=None, LOCALAPPDATA=None) is None
    (ws.deps / "greeter").rename(tmp_path / "moved")
    assert_at_import(check(ws), "CHECK-IMPORT-PACKAGE")


IMPORT_CASES = [
    ("a package named with no module", 'import G from "pkg/greeter"\n', "CHECK-IMPORT-PATH"),
    ("a dot dot part", 'import G from "pkg/greeter/../greeter/greet"\n', "CHECK-IMPORT-PATH"),
    ("a module the package lacks", 'import G from "pkg/greeter/missing"\n', "CHECK-IMPORT-IO"),
    ("the old owner/repo form", 'import G from "owner/greeter/greet"\n', "CHECK-IMPORT-IO"),
    ("the old host form", 'import G from "github.com/owner/greeter/greet"\n', "CHECK-IMPORT-IO"),
]


@pytest.mark.parametrize("what, line, code", IMPORT_CASES, ids=[case[0] for case in IMPORT_CASES])
def test_a_package_import_is_pkg_name_and_a_module(ws, what, line, code):
    write_main(ws, line)
    assert_at_import(check(ws), code)


def test_an_undeclared_name_falls_back_to_the_pkg_roots_and_the_project_cannot_reach_a_transitive_package(ws):
    # tools is in the lock because greeter needs it, but the manifest of the project does not declare it, so
    # pkg/tools/ is today's library search: nothing there.
    write_main(ws, 'import Tools from "pkg/tools/bang"\n')
    assert_at_import(check(ws), "CHECK-IMPORT-IO")
    # deps/tools is the locked package, never a library, but agc_libs/ is the project's own: a library there is found.
    (ws.project / "agc_libs" / "tools").mkdir(parents=True)
    (ws.project / "agc_libs" / "tools" / "bang.agc").write_text(BANG, encoding="utf-8")
    assert check(ws) is None
    (ws.project / "agc_libs" / "tools" / "bang.agc").unlink()
    # The other roots are searched as before.
    root = ws.base / "libs"
    (root / "tools").mkdir(parents=True)
    (root / "tools" / "bang.agc").write_text(BANG, encoding="utf-8")
    assert check(ws, AGENTICA_PATH=str(root)) is None


def test_agc_libs_of_a_locked_but_undeclared_name_is_searched(ws):
    # tools is locked (greeter needs it) and not declared by the project: agc_libs/tools is the project's own library.
    (ws.project / "agc_libs" / "tools").mkdir(parents=True)
    (ws.project / "agc_libs" / "tools" / "bang.agc").write_text(BANG, encoding="utf-8")
    write_main(ws, 'import Tools from "pkg/tools/bang"\n')
    assert check(ws) is None


def test_a_declared_name_shadows_a_library_of_the_same_name(ws):
    # AGENTICA_PATH holds a greeter/greet.agc, but the manifest declares greeter, so the package is the one that loads.
    root = ws.base / "libs"
    (root / "greeter").mkdir(parents=True)
    (root / "greeter" / "greet.agc").write_text(
        'export def hello(name: String) -> String\n  return "library"\nend\n', encoding="utf-8")
    ran = run(cli() + [str(ws.project / "main.agc")], cwd=ws.base, env=environment(ws, AGENTICA_PATH=str(root)))
    assert (ran.code, ran.stdout) == (0, "HELLO ANA!\n"), ran.stderr
    # Undeclared, the same import is the library.
    ws.write_manifest({"tools": TOOLS})
    ws.write_lock()
    ran = run(cli() + [str(ws.project / "main.agc")], cwd=ws.base, env=environment(ws, AGENTICA_PATH=str(root)))
    assert (ran.code, ran.stdout) == (0, "library\n"), ran.stderr


def test_agc_libs_of_a_declared_name_is_not_read_and_a_file_edited_in_deps_is_a_hash_mismatch(ws):
    # A declared name shadows the library roots, agc_libs/ included, so a library of that name changes nothing ...
    (ws.project / "agc_libs" / "greeter").mkdir(parents=True)
    (ws.project / "agc_libs" / "greeter" / "greet.agc").write_text(
        'export def hello(name: String) -> String\n  return "library"\nend\n', encoding="utf-8")
    assert check(ws) is None
    # ... while a file of deps/greeter that is not the locked one is PKG-HASH-MISMATCH at the import.
    (ws.deps / "greeter" / "greet.agc").write_text("# edited\n", encoding="utf-8")
    assert_at_import(check(ws), "PKG-HASH-MISMATCH")
    # A file added to the folder changes the hash too.
    (ws.deps / "greeter" / "greet.agc").write_text(GREET, encoding="utf-8")
    (ws.deps / "greeter" / "extra.agc").write_text("# extra\n", encoding="utf-8")
    assert_at_import(check(ws), "PKG-HASH-MISMATCH")


def test_the_manifest_directory_holds_agc_libs_when_there_is_a_manifest(ws):
    # pkg/ libraries are searched in agc_libs/ beside agentica.toml, even for a root file in a folder below it.
    (ws.project / "agc_libs").mkdir()
    (ws.project / "agc_libs" / "tool.agc").write_text(ONE, encoding="utf-8")
    (ws.project / "src").mkdir()
    (ws.project / "src" / "use.agc").write_text(
        'import Tool from "pkg/tool"\n\ndef main() -> Void\n  puts(Tool.one())\nend\n', encoding="utf-8")
    assert check(ws, "src/use.agc") is None
    (ws.project / "src" / "agc_libs").mkdir()
    (ws.project / "agc_libs" / "tool.agc").rename(ws.project / "src" / "agc_libs" / "tool.agc")
    assert_at_import(check(ws, "src/use.agc"), "CHECK-IMPORT-IO")
    assert os.path.exists(ws.project / "src" / "agc_libs" / "tool.agc")


# A line that a package file adds at its top, and the code of the report. The report is in the package file.
PACKAGE_IMPORT_CASES = [
    ("an import that leaves the package", 'import X from "../outside"\n', "CHECK-IMPORT-PATH"),
    ("an import of a hidden folder", 'import X from ".hidden/x"\n', "CHECK-IMPORT-PATH"),
    ("an import of agc_libs", 'import X from "agc_libs/x"\n', "CHECK-IMPORT-PATH"),
    ("a package it did not declare", 'import X from "pkg/other/x"\n', "CHECK-IMPORT-PACKAGE"),
    ("itself by name", 'import X from "pkg/greeter/util/shout"\n', "CHECK-IMPORT-PACKAGE"),
    ("a package of the project that it does not declare", 'import X from "pkg/greeter2/x"\n',
     "CHECK-IMPORT-PACKAGE"),
]


@pytest.mark.parametrize("what, line, code", PACKAGE_IMPORT_CASES, ids=[case[0] for case in PACKAGE_IMPORT_CASES])
def test_a_package_file_may_import_only_inside_itself_and_what_its_manifest_declares(ws, what, line, code):
    # The package is built again with the added import, as another commit, and the lock is made for it.
    ws.locked = [entry for entry in ws.locked if entry["name"] != "greeter"]
    ws.add_package("greeter", GREETER_GIT, {"greet.agc": line + GREET, "util/shout.agc": SHOUT, ".hidden/x.agc": SHOUT,
                                            "agc_libs/x.agc": SHOUT}, tag="v1.2.3", dependencies={"tools": TOOLS},
                   commit="c" * 40)
    ws.write_lock()
    # The project declares greeter2 as well, and pkg/ libraries exist, so only the manifest of the package decides.
    ws.write_manifest({"greeter": GREETER})
    (ws.project / "agc_libs" / "other").mkdir(parents=True)
    (ws.project / "agc_libs" / "other" / "x.agc").write_text(ONE, encoding="utf-8")
    problem = check(ws)
    assert problem["code"] == code
    assert Path(problem["file"]) == ws.deps / "greeter" / "greet.agc"
    assert start(problem) == (1, 1)


# A package of one module that imports nothing: its manifest and its files are what a case changes.
ALONE_GIT = "https://github.com/owner/alone"
USE_ALONE = 'import Alone from "pkg/alone/one"\n'


def add_alone(ws, files=None, **extra):
    """Adds the package `alone` (in deps/, the lock and the manifest of the project) and a file that imports it."""
    ws.add_package("alone", ALONE_GIT, files or {"one.agc": ONE}, tag="v1.0.0", **extra)
    ws.write_manifest({"greeter": GREETER, "alone": dependency(ALONE_GIT, tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "use.agc").write_text(USE_ALONE + "\ndef main() -> Void\nend\n", encoding="utf-8")
    return ws.deps / "alone"


def test_a_manifest_that_is_a_symbolic_link_is_refused_and_never_read(ws, tmp_path):
    folder = add_alone(ws)
    outside = tmp_path / "outside.toml"
    outside.write_text("secret_token_key = 1\n", encoding="utf-8")
    (folder / "agentica.toml").symlink_to(outside)
    # PKG-SYMLINK at the import, not PKG-MANIFEST-INVALID, which would name a key of the file outside the package.
    assert_at_import(check(ws, "use.agc"), "PKG-SYMLINK")
    # Nothing imports the package: the manifest is not opened, so the build passes.
    (ws.project / "plain.agc").write_text("def main() -> Void\nend\n", encoding="utf-8")
    assert check(ws, "plain.agc") is None


def test_a_manifest_that_is_not_a_regular_file_is_refused(ws):
    folder = add_alone(ws)
    (folder / "agentica.toml").mkdir()
    assert_at_import(check(ws, "use.agc"), "PKG-SYMLINK")


def test_a_symbolic_link_to_a_folder_that_leaves_the_package_is_not_importable(ws, tmp_path):
    folder = add_alone(ws)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "stolen.agc").write_text(ONE, encoding="utf-8")
    (folder / "out").symlink_to(outside, target_is_directory=True)
    write_main(ws, 'import Stolen from "pkg/alone/out/stolen"\n')
    # The link is not .agc, so the hash ignores it and the package is intact; the file it leads to is outside.
    assert_at_import(check(ws), "CHECK-IMPORT-PATH")
    assert check(ws, "use.agc") is None


def test_the_agc_extension_and_agc_libs_are_compared_without_regard_to_case(ws):
    # x.AGC is hashed (the peer hashes it too, so the lock matches) and AGC_LIBS/ is left out, as on a system that
    # ignores case, where a build could open them by their lowercase names.
    folder = add_alone(ws, {"one.agc": ONE, "x.AGC": ONE, "AGC_LIBS/y.agc": ONE})
    assert check(ws, "use.agc") is None
    (folder / "x.AGC").write_text(ONE + "# changed\n", encoding="utf-8")
    assert_at_import(check(ws, "use.agc"), "PKG-HASH-MISMATCH")
    (folder / "x.AGC").write_text(ONE, encoding="utf-8")
    (folder / "AGC_LIBS" / "y.agc").write_text(ONE + "# changed\n", encoding="utf-8")
    assert check(ws, "use.agc") is None
    # What the hash leaves out cannot be imported, whatever the case of its name.
    write_main(ws, 'import Y from "pkg/alone/AGC_LIBS/y"\n')
    assert_at_import(check(ws), "CHECK-IMPORT-PATH")


@host_only(WINDOWS, "a folder or file made unreadable with chmod 000 has no equivalent on Windows, which has no mode bits")
@pytest.mark.skipif(ROOT_USER, reason="root can read any folder")
def test_a_package_folder_or_file_that_cannot_be_read_is_an_import_error_not_a_crash(ws, request):
    folder = add_alone(ws, {"one.agc": ONE, "inner/two.agc": ONE})
    # An unreadable subfolder: the walk of the hash cannot list it.
    (folder / "inner").chmod(0o000)
    request.addfinalizer(lambda: (folder / "inner").chmod(0o700))
    assert_at_import(check(ws, "use.agc"), "CHECK-IMPORT-IO")
    (folder / "inner").chmod(0o700)
    # An unreadable .agc file: the hash cannot read its bytes.
    (folder / "inner" / "two.agc").chmod(0o000)
    request.addfinalizer(lambda: (folder / "inner" / "two.agc").chmod(0o600))
    assert_at_import(check(ws, "use.agc"), "CHECK-IMPORT-IO")
    (folder / "inner" / "two.agc").chmod(0o600)
    # An unreadable package folder: the manifests are checked up front, but only what can be listed.
    folder.chmod(0o000)
    request.addfinalizer(lambda: folder.chmod(0o700))
    assert_at_import(check(ws, "use.agc"), "CHECK-IMPORT-IO")
    folder.chmod(0o700)
    assert check(ws, "use.agc") is None


def test_a_package_with_no_manifest_declares_nothing(ws):
    folder = add_alone(ws)
    assert not (folder / "agentica.toml").exists()
    assert check(ws, "use.agc") is None
    # Its files may import each other, but no package: nothing declares one.
    ws.locked = [entry for entry in ws.locked if entry["name"] != "alone"]
    folder = add_alone(ws, {"one.agc": 'import Tools from "pkg/tools/bang"\n' + ONE})
    problem = check(ws, "use.agc")
    assert problem["code"] == "CHECK-IMPORT-PACKAGE"
    assert Path(problem["file"]) == folder / "one.agc"


def test_two_local_names_for_one_repository_are_two_packages(ws):
    ws.add_package("alone", ALONE_GIT, {"one.agc": ONE}, tag="v1.0.0")
    ws.add_package("other", ALONE_GIT, {"one.agc": ONE}, tag="v1.0.0")
    ws.write_manifest({"alone": dependency(ALONE_GIT, tag="v1.0.0"), "other": dependency(ALONE_GIT, tag="v1.0.0")})
    ws.write_lock()
    both_text = ('import A from "pkg/alone/one"\nimport B from "pkg/other/one"\n\n'
                 'def main() -> Void\n  puts(A.one() + B.one())\nend\n')
    (ws.project / "both.agc").write_text(both_text, encoding="utf-8")
    ran = run(cli() + [str(ws.project / "both.agc")], cwd=ws.base, env=environment(ws))
    assert (ran.code, ran.stdout) == (0, "2\n"), ran.stderr
    # A name that the lock lacks for the same repository is still stale: the names are local to each manifest.
    ws.write_manifest({"alone": dependency(ALONE_GIT, tag="v1.0.0"), "third": dependency(ALONE_GIT, tag="v1.0.0")})
    assert_at_key(check(ws, "both.agc"), "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.third")


def test_a_conflict_in_a_package_that_no_import_reaches_is_still_reported(ws):
    # The manifest of greeter asks for another tag of tools than the lock has, and the build imports nothing.
    manifest = ws.deps / "greeter" / "agentica.toml"
    manifest.write_text('[dependencies]\ntools = { git = "%s", tag = "v9.9.9" }\n' % TOOLS_GIT, encoding="utf-8")
    (ws.project / "plain.agc").write_text("def main() -> Void\nend\n", encoding="utf-8")
    assert_at_key(check(ws, "plain.agc"), "PKG-SOURCE-CONFLICT", manifest, "dependencies.tools")
    manifest.write_text('[dependencies]\nmore = { git = "https://gitlab.com/else/more", ref = "bbbbbbb" }\n',
                        encoding="utf-8")
    assert_at_key(check(ws, "plain.agc"), "PKG-LOCK-STALE", manifest, "dependencies.more")


def test_a_locked_package_that_is_not_in_deps_fails_only_when_it_is_imported(ws):
    shutil.rmtree(ws.deps / "tools")
    (ws.project / "plain.agc").write_text("def main() -> Void\nend\n", encoding="utf-8")
    assert check(ws, "plain.agc") is None
    # greeter is there, and imports tools from deps/: the missing package is told at that import.
    problem = check(ws)
    assert problem["code"] == "CHECK-IMPORT-PACKAGE"


def run_text(ws, *flags):
    """The stderr and exit code of a text form of `check` on main.agc."""
    result = run(cli() + list(flags) + ["check", str(ws.project / "main.agc")], cwd=ws.base, env=environment(ws))
    assert result.code == 1, result.stderr
    return result.stderr


def test_a_lock_that_is_missing_shows_the_file_and_no_place_in_the_plain_and_ai_forms(ws):
    (ws.project / "agentica.lock").unlink()
    lock = str(ws.project / "agentica.lock")
    plain = run_text(ws)
    head, rest = plain.split(": error[", 1)
    assert Path(head) == Path(lock) and rest.startswith("PKG-LOCK-MISSING]")
    # No position, no source box, no key line.
    assert ":1:1" not in plain and "|" not in plain and "= key:" not in plain
    ai = run_text(ws, "--ai").splitlines()
    assert "[PKG-LOCK-MISSING]" in ai
    at = [line for line in ai if line.startswith("  at: ")]
    assert len(at) == 1 and Path(at[0][len("  at: "):]) == Path(lock)
    assert not [line for line in ai if line.startswith(("  source:", "  key:"))]


def test_a_manifest_or_lock_error_with_a_key_shows_the_key_in_the_plain_and_ai_forms(ws):
    ws.write_lock(drop("hash"))
    plain = run_text(ws)
    head, rest = plain.split(": error[", 1)
    assert Path(head) == ws.project / "agentica.lock" and rest.startswith("PKG-LOCK-INVALID]")
    assert "  = key: package[0].hash" in plain.splitlines()
    assert ":1:1" not in plain and "|" not in plain
    ai = run_text(ws, "--ai").splitlines()
    assert "  key: package[0].hash" in ai
    assert not [line for line in ai if line.startswith("  source:")]
    assert [line for line in ai if line.startswith("  at: ")] == ["  at: " + head]


@pytest.mark.skipif(ROOT_USER, reason="root can read any file")
def test_a_manifest_or_lock_that_cannot_be_read_is_a_failure_of_the_whole_file(ws):
    for name, code in [("agentica.toml", "PKG-MANIFEST-INVALID"), ("agentica.lock", "PKG-LOCK-INVALID")]:
        path = ws.project / name
        with unreadable(path):
            assert_at_key(check(ws), code, path, "")
            assert ":1:1" not in run_text(ws)
