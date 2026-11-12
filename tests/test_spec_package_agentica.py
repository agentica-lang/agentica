"""The `agentica` key of agentica.toml: the oldest Agentica that a project or a package works with (issue 1469).

The key is checked against the running version by `install`, `check`, `run` and `test`, for the project and for every
locked package. Most cases fill deps/ by hand (tests/package_support.py, `Workspace`); the `install` cases fetch from a
bare git repository behind a throwaway HOME (`Remotes`). The order of versions is checked through the front end run with
another `--version`, as the binary runs it. Cases assert the code, the file and the key path, never message text
(AGENTS.md).
"""
import json

import pytest

from tests.agentica_test import ROOT, STAGE2, agentica_version, cli, require, run, vm_command, vm_environment
from tests.package_support import (BANG, GREET, MAIN, Remotes, Workspace, assert_at_key, command, dependency,
                                   install, lock_entry, manifest_text)

GREETER = "owner/greeter"
TOOLS = "owner/tools"
# A test file whose one test passes.
TEST_FILE = "def test_one() -> Result[Void]\n  ok()\nend\n"


def newer():
    """A version newer than the running one: the next major."""
    return "%d.0.0" % (int(agentica_version().split(".")[0]) + 1)


def key(version):
    return 'agentica = "%s"\n' % version


@pytest.fixture
def ws(tmp_path):
    """A project that depends on greeter, which depends on tools: both in deps/ and in the lock."""
    workspace = Workspace(tmp_path)
    tools = dependency("https://example.test/owner/tools", tag="v1")
    workspace.add_package("tools", tools["git"], {"bang.agc": BANG}, tag="v1")
    workspace.add_package("greeter", "https://example.test/owner/greeter", {"greet.agc": GREET}, tag="v1",
                          dependencies={"tools": tools})
    workspace.write_manifest({"greeter": dependency("https://example.test/owner/greeter", tag="v1")})
    workspace.write_lock()
    (workspace.project / "main.agc").write_text(MAIN, encoding="utf-8")
    (workspace.project / "main_test.agc").write_text(TEST_FILE, encoding="utf-8")
    return workspace


def environment(ws):
    """No AGENTICA_PATH roots, and the cache of the workspace."""
    return vm_environment({"AGENTICA_PATH": "", **ws.cache_variables})


def agentica(ws, *words):
    """`--json WORDS` in the project folder: the exit code and the problem it reported (None for none)."""
    ran = run(cli() + ["--json", *words], cwd=ws.project, env=environment(ws))
    if ran.code == 1 and ran.stderr:
        return ran.code, json.loads(ran.stderr)
    return ran.code, None


def every_command(ws):
    """The problem that check, run and test each report: test reports it as the error of the test file."""
    problems = []
    for words in (["check", "main.agc"], ["main.agc"]):
        code, problem = agentica(ws, *words)
        assert code == 1
        problems.append(problem)
    ran = run(cli() + ["--json", "test", "main_test.agc"], cwd=ws.project, env=environment(ws))
    assert ran.code == 1
    problems.append(json.loads(ran.stdout)["files"][0]["error"])
    return problems


def prepend(path, text):
    path.write_text(text + path.read_text(encoding="utf-8"), encoding="utf-8")


def test_a_project_and_its_packages_that_need_this_agentica_or_older_build(ws):
    prepend(ws.project / "agentica.toml", key(agentica_version()))
    prepend(ws.deps / "greeter" / "agentica.toml", key("0.1.0"))
    (ws.deps / "tools" / "agentica.toml").write_text(key("0.1.0-alpha.1"), encoding="utf-8")
    assert agentica(ws, "check", "main.agc") == (0, None)
    ran = run(cli() + ["main.agc"], cwd=ws.project, env=environment(ws))
    assert (ran.code, ran.stdout) == (0, "hello!\n"), ran.stderr


def test_a_project_that_needs_a_newer_agentica_is_refused_by_check_run_test_and_install(ws):
    manifest = ws.project / "agentica.toml"
    prepend(manifest, key(newer()))
    for problem in every_command(ws):
        assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", manifest, "agentica")
    code, problem = agentica(ws, "install")
    assert code == 1
    assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", manifest, "agentica")


@pytest.mark.parametrize("package", ["greeter", "tools"])
def test_a_package_or_the_package_of_a_package_that_needs_a_newer_agentica_is_refused(ws, package):
    # tools is a dependency of greeter only: the project never names it.
    manifest = ws.deps / package / "agentica.toml"
    if manifest.exists():
        prepend(manifest, key(newer()))
    else:
        manifest.write_text(key(newer()), encoding="utf-8")
    for problem in every_command(ws):
        assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", manifest, "agentica")


@pytest.mark.parametrize("where", ["project", "package"])
def test_the_version_is_checked_before_any_other_key_so_a_newer_manifest_reports_it(ws, where):
    # A later Agentica may add keys (`features` here): the version they need is what an older one reports.
    manifest = ws.project / "agentica.toml" if where == "project" else ws.deps / "greeter" / "agentica.toml"
    prepend(manifest, key(newer()) + "features = []\n")
    for problem in every_command(ws):
        assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", manifest, "agentica")


def test_a_bad_version_next_to_an_unknown_key_is_reported_at_the_version(ws):
    manifest = ws.project / "agentica.toml"
    prepend(manifest, 'agentica = ">=1.0.0"\nfeatures = []\n')
    assert_at_key(agentica(ws, "check", "main.agc")[1], "PKG-MANIFEST-INVALID", manifest, "agentica")


def test_broken_toml_before_a_newer_version_is_the_toml_error(ws):
    # The version is read from the parsed file: a file that does not parse reports that, at its line.
    manifest = ws.project / "agentica.toml"
    prepend(manifest, "features = [\n" + key(newer()))
    problem = agentica(ws, "check", "main.agc")[1]
    assert problem["code"] == "PKG-MANIFEST-INVALID"
    assert "key_path" not in problem
    assert problem["range"]["start"]["line"] >= 1


def test_the_version_of_the_project_is_checked_before_its_lock_and_a_package_before_its_dependencies(ws):
    # The lock no longer has greeter: a stale lock, after the version.
    ws.write_lock(lambda entries: entries.remove(next(e for e in entries if e["name"] == "greeter")))
    manifest = ws.project / "agentica.toml"
    prepend(manifest, key(newer()))
    for problem in every_command(ws):
        assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", manifest, "agentica")
    # A package that asks for a name the lock lacks.
    ws.write_lock()
    manifest.write_text(manifest_text({"greeter": dependency("https://example.test/owner/greeter", tag="v1")}),
                        encoding="utf-8")
    package = ws.deps / "greeter" / "agentica.toml"
    package.write_text(key(newer()) + manifest_text({"more": dependency("https://example.test/o/more", tag="v1")}),
                       encoding="utf-8")
    for problem in every_command(ws):
        assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", package, "agentica")


def test_an_edit_of_a_package_manifest_is_seen_by_a_run_from_the_bytecode_cache(ws):
    # No build folder of the harness: the entry goes to the project's _build/ (tests/test_bytecode_cache.py).
    env = vm_environment({"AGENTICA_PATH": "", "AGENTICA_BUILD_DIR": None, **ws.cache_variables})
    for _ in range(2):
        ran = run(cli() + ["main.agc"], cwd=ws.project, env=env)
        assert (ran.code, ran.stdout) == (0, "hello!\n"), ran.stderr
    assert list((ws.project / "_build" / "bytecode").iterdir())
    manifest = ws.deps / "greeter" / "agentica.toml"
    prepend(manifest, key(newer()))
    ran = run(cli() + ["--json", "main.agc"], cwd=ws.project, env=env)
    assert_at_key(json.loads(ran.stderr), "PKG-AGENTICA-TOO-OLD", manifest, "agentica")


def test_a_path_package_that_needs_a_newer_agentica_is_refused(ws):
    local = ws.base / "local"
    local.mkdir()
    (local / "agentica.toml").write_text(key(newer()) + 'name = "local"\n', encoding="utf-8")
    (local / "bang.agc").write_text(BANG, encoding="utf-8")
    (ws.project / "agentica.toml").write_text('name = "app"\n\n[dependencies]\nlocal = { path = "../local" }\n',
                                              encoding="utf-8")
    (ws.project / "agentica.lock").write_text('version = 1\n\n[[package]]\nname = "local"\npath = "../local"\n',
                                              encoding="utf-8")
    (ws.project / "main.agc").write_text('import Bang from "pkg/local/bang"\n\ndef main() -> Void\n'
                                         '  puts(Bang.bang())\nend\n', encoding="utf-8")
    for problem in every_command(ws):
        assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", local / "agentica.toml", "agentica")


BAD_VALUES = [
    ("two parts", '"0.31"'),
    ("a range", '">=0.31.0"'),
    ("a leading v", '"v0.31.0"'),
    ("a leading zero", '"01.0.0"'),
    ("an empty pre-release", '"1.0.0-"'),
    ("an empty pre-release identifier", '"1.0.0-alpha..1"'),
    ("a numeric pre-release identifier with a leading zero", '"1.0.0-alpha.01"'),
    ("an empty string", '""'),
    ("a number", "31"),
    ("a table", "{ min = \"0.31.0\" }"),
]


@pytest.mark.parametrize("what, value", BAD_VALUES, ids=[case[0] for case in BAD_VALUES])
def test_a_value_that_is_not_one_semver_version_is_an_invalid_manifest(ws, what, value):
    manifest = ws.project / "agentica.toml"
    prepend(manifest, "agentica = %s\n" % value)
    assert_at_key(agentica(ws, "check", "main.agc")[1], "PKG-MANIFEST-INVALID", manifest, "agentica")
    # The manifest of a package is read the same way.
    manifest.write_text(manifest_text({"greeter": dependency("https://example.test/owner/greeter", tag="v1")}),
                        encoding="utf-8")
    package = ws.deps / "greeter" / "agentica.toml"
    prepend(package, "agentica = %s\n" % value)
    assert_at_key(agentica(ws, "check", "main.agc")[1], "PKG-MANIFEST-INVALID", package, "agentica")


# (the version the project needs, the running version, whether it builds): the order of semver.org §11.
ORDER = [
    ("0.31.0", "0.31.0", True),
    ("0.31.0-alpha.1", "0.31.0-alpha.1", True),
    ("0.31.0-alpha.1", "0.31.0", True),
    ("0.31.0", "0.31.0-alpha.1", False),
    ("0.31.0-alpha.2", "0.31.0-alpha.10", True),
    ("0.31.0-alpha.10", "0.31.0-alpha.2", False),
    ("0.31.0-alpha.1", "0.31.0-alpha.2", True),
    ("0.31.0-alpha.2", "0.31.0-alpha.1", False),
    ("0.31.0-alpha", "0.31.0-alpha.1", True),
    ("0.31.0-alpha.1", "0.31.0-alpha", False),
    ("0.31.0-beta.1", "0.31.0-alpha.9", False),
    ("0.31.0-alpha.9", "0.31.0-beta.1", True),
    ("1.0.0-1", "1.0.0-alpha", True),
    ("1.0.0-alpha", "1.0.0-1", False),
    ("0.9.10", "0.10.0", True),
    ("0.10.0", "0.9.10", False),
    ("1.0.0+build.5", "1.0.0", True),
    ("0.32.0", "0.31.9", False),
    # An identifier with a hyphen is alphanumeric: "alpha" is its prefix, so the shorter one comes first.
    ("1.0.0-alpha", "1.0.0-alpha-1", True),
    ("1.0.0-alpha-1", "1.0.0-alpha", False),
    # Numbers longer than an Int are compared as text.
    ("99999999999999999999.0.0", "0.31.0", False),
    ("0.31.0", "99999999999999999999.0.0", True),
    ("99999999999999999999.0.0", "99999999999999999998.0.0", False),
]


@pytest.mark.parametrize("needed, running, builds", ORDER, ids=["%s by %s" % case[:2] for case in ORDER])
def test_versions_are_compared_in_semver_order(tmp_path, needed, running, builds):
    require(STAGE2.is_file(), "the front end is not built (%s): run make" % STAGE2)
    (tmp_path / "agentica.toml").write_text('name = "app"\n' + key(needed), encoding="utf-8")
    (tmp_path / "main.agc").write_text('def main() -> Void\n  puts("hi")\nend\n', encoding="utf-8")
    command = [*vm_command(), "--", STAGE2, "--version", running, "--stdlib", ROOT / "stdlib", "--", "--json",
               "check", "main.agc"]
    ran = run(command, cwd=tmp_path, env=vm_environment({"AGENTICA_PATH": ""}))
    if builds:
        assert ran.code == 0, ran.stderr
    else:
        assert ran.code == 1
        assert_at_key(json.loads(ran.stderr), "PKG-AGENTICA-TOO-OLD", tmp_path / "agentica.toml", "agentica")


@pytest.fixture
def remotes(tmp_path):
    return Remotes(tmp_path)


@pytest.mark.parametrize("package", ["greeter", "tools"])
def test_install_refuses_a_package_that_needs_a_newer_agentica_and_writes_no_deps(tmp_path, remotes, package):
    ws = Workspace(tmp_path / "w")
    # features is a key of a later Agentica: the version is still what is reported.
    needs = {package: key(newer()) + "features = []\n"}
    tools_files = {"bang.agc": BANG}
    if package == "tools":
        tools_files["agentica.toml"] = needs["tools"]
    tools_commit = remotes.publish(TOOLS, tools_files, tag="v1")
    greeter_manifest = needs.get("greeter", "") + manifest_text({"tools": dependency(remotes.url(TOOLS), tag="v1")})
    greeter_commit = remotes.publish(GREETER, {"greet.agc": GREET, "agentica.toml": greeter_manifest}, tag="v1")
    lock_entry(ws, remotes, GREETER, {"greet.agc": GREET}, greeter_commit, tag="v1")
    lock_entry(ws, remotes, TOOLS, {"bang.agc": BANG}, tools_commit, tag="v1")
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1")})
    ws.write_lock()
    _, problem = install(ws, remotes)
    commit = greeter_commit if package == "greeter" else tools_commit
    path = "owner/%s" % package
    cached = ws.folder(remotes.url(path), commit) / "agentica.toml"
    assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", cached, "agentica")
    assert not ws.deps.exists()
    # update resolves the tree again and stops at the same manifest, before it writes the lock.
    lock = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert_at_key(command(ws, remotes, "update")[1], "PKG-AGENTICA-TOO-OLD", cached, "agentica")
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == lock


def test_add_refuses_a_package_that_needs_a_newer_agentica_and_writes_nothing(tmp_path, remotes):
    ws = Workspace(tmp_path / "w")
    commit = remotes.publish(GREETER, {"bang.agc": BANG, "agentica.toml": key(newer()) + "features = []\n"}, tag="v1")
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    _, problem = command(ws, remotes, "add", "greeter", remotes.url(GREETER), "--tag", "v1")
    assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", ws.folder(remotes.url(GREETER), commit) / "agentica.toml",
                  "agentica")
    assert (ws.project / "agentica.toml").read_text(encoding="utf-8") == 'name = "app"\n'
    assert not (ws.project / "agentica.lock").exists()


def workspace_member(ws, root_text):
    """Makes the project a member of a workspace whose root, the folder above it, has root_text before its table."""
    root = ws.project.parent / "agentica.toml"
    folder = ws.project.name
    root.write_text(root_text + '\n[workspace]\nrepository = "https://example.test/owner/mono"\nmembers = ["%s"]\n'
                    % folder, encoding="utf-8")
    return root


def test_a_member_of_a_workspace_whose_root_needs_a_newer_agentica_is_refused(ws):
    # The root's version is checked before its other keys, so an unknown key of a later Agentica does not hide it.
    root = workspace_member(ws, key(newer()) + "features = []\n")
    for problem in every_command(ws):
        assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", root, "agentica")
    code, problem = agentica(ws, "install")
    assert code == 1
    assert_at_key(problem, "PKG-AGENTICA-TOO-OLD", root, "agentica")
    workspace_member(ws, key(agentica_version()))
    assert agentica(ws, "check", "main.agc") == (0, None)
