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
    needs = {package: key(newer())}
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
