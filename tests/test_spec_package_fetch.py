"""`agentica install`: the git fetch, the commit and hash checks, and the cache fill (docs/future/45-packages.md, 45b).

The remote of every case is a bare git repository in a temporary folder; a throwaway HOME has a .gitconfig whose
`url.<base>.insteadOf` sends `https://example.test/` there (tests/package_support.py, `Remotes`). The manifest and the lock
keep the https URL, git is the system git, and nothing touches the network or the real git config or package cache.
Cases assert codes and the file and key path, never message text (AGENTS.md).
"""
import json
import os
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, tool, vm_environment
from tests.package_support import Remotes, Workspace, dependency, package_hash

pytestmark = host_only(WINDOWS, "the git remote of these cases is a file:// folder, tested on POSIX")

GREETER = "owner/greeter"
TOOLS = "owner/tools"
GREET = ('import Tools from "pkg/tools/bang"\n\nexport def hello() -> String\n  return "hello" + Tools.bang()\nend\n')
BANG = 'export def bang() -> String\n  return "!"\nend\n'
MAIN = 'import Greet from "pkg/greeter/greet"\n\ndef main() -> Void\n  puts(Greet.hello())\nend\n'


@pytest.fixture
def git():
    return tool("git")


@pytest.fixture
def remotes(tmp_path, git):
    return Remotes(tmp_path)


@pytest.fixture
def ws(tmp_path):
    return Workspace(tmp_path)


def lock_entry(ws, remotes, path, files, commit, tag=None, ref=None, name=None):
    """Notes the lock entry of a package whose files the remote holds. The hash comes from the Python implementation of
    the hash rule, over a scratch copy of the .agc files."""
    scratch = ws.base / ("scratch-" + path.replace("/", "-"))
    for relative, content in files.items():
        if relative.endswith(".agc"):
            (scratch / relative).parent.mkdir(parents=True, exist_ok=True)
            (scratch / relative).write_bytes(content if isinstance(content, bytes) else content.encode("utf-8"))
    entry = {"name": name or path.split("/")[1], "git": remotes.url(path), "commit": commit,
             "hash": package_hash(scratch) if scratch.exists() else package_hash(ws.base)}
    entry.update({"tag": tag} if ref is None else {"ref": ref})
    ws.locked.append(entry)
    return entry


def environment(ws, remotes, **extra):
    return vm_environment({"AGENTICA_PATH": "", **ws.cache_variables, **remotes.environment, **extra})


def install(ws, remotes, *words, **extra):
    """The result of `--json install` in the project folder, and the problem it reported, or None for a success."""
    result = run(cli() + ["--json", "install", *words], cwd=ws.project, env=environment(ws, remotes, **extra))
    if result.code == 0:
        assert result.stdout == '{"ok":true}\n'
        return result, None
    return result, json.loads(result.stderr) if result.code == 1 else None


def assert_at_key(problem, code, file, key_path):
    assert problem["code"] == code
    assert Path(problem["file"]) == Path(file)
    assert problem.get("key_path", "") == key_path


def project(ws, dependencies):
    ws.write_manifest(dependencies)
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def one_package(ws, remotes, files=None):
    """The project depends on greeter v1.0.0, which the remote holds; returns the locked commit."""
    files = files or {"one.agc": "# one\n"}
    commit = remotes.publish(GREETER, files, tag="v1.0.0")
    lock_entry(ws, remotes, GREETER, files, commit, tag="v1.0.0")
    project(ws, {"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    return commit


def cached_files(folder):
    return sorted(path.relative_to(folder).as_posix() for path in folder.rglob("*") if path.is_file())


def test_install_fetches_a_tag_and_a_commit_then_a_program_runs_from_the_cache_with_no_git(ws, remotes, tmp_path):
    tools_files = {"bang.agc": BANG, "docs/notes.md": "not code", ".github/hidden.agc": "junk", "agc_libs/x.agc": "junk",
                   ".gitattributes": "*.agc text eol=crlf\n"}
    tools_commit = remotes.publish(TOOLS, tools_files, tag="v9", annotated=False)
    greeter_files = {"greet.agc": GREET, "util/more.agc": "# more\n"}
    manifest = ('name = "greeter"\n\n[dependencies]\ntools = { git = "%s", ref = "%s" }\n'
                % (remotes.url(TOOLS), tools_commit[:9]))
    greeter_commit = remotes.publish(GREETER, {**greeter_files, "agentica.toml": manifest}, tag="v1.0.0")
    # A package pinned by a tag, and one by a commit (tools: the fetch asks for the full locked commit).
    lock_entry(ws, remotes, GREETER, greeter_files, greeter_commit, tag="v1.0.0")
    lock_entry(ws, remotes, TOOLS, tools_files, tools_commit, ref=tools_commit[:9])
    project(ws, {"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})

    result, problem = install(ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    plain = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes))
    assert plain.stdout == "in the cache greeter@v1.0.0\nin the cache tools@%s\n" % tools_commit[:12]

    # Only the .agc files and the manifest are copied, with the bytes of the blobs: a checkout would make them CRLF here,
    # because of the .gitattributes of the repository.
    greeter = ws.folder(remotes.url(GREETER), greeter_commit)
    assert cached_files(greeter) == ["agentica.toml", "greet.agc", "util/more.agc"]
    tools = ws.folder(remotes.url(TOOLS), tools_commit)
    assert cached_files(tools) == ["bang.agc"]
    assert (tools / "bang.agc").read_bytes() == BANG.encode("utf-8")
    assert not [name for name in os.listdir(ws.pkg_root) if name.startswith(".")]

    # The program builds and runs with no git on PATH: a build never fetches.
    empty = tmp_path / "no-git"
    empty.mkdir()
    ran = run(cli() + [str(ws.project / "main.agc")], cwd=ws.project, env=environment(ws, remotes, PATH=str(empty)))
    assert (ran.code, ran.stdout) == (0, "hello!\n"), ran.stderr
    again = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes, PATH=str(empty)))
    assert again.code == 0, again.stderr


def test_install_fetches_the_missing_package_and_leaves_the_cached_one_alone(ws, remotes):
    files = {"one.agc": "export def one() -> Int\n  return 1\nend\n"}
    commit = remotes.publish(GREETER, files, tag="v1.0.0")
    entry = lock_entry(ws, remotes, GREETER, files, commit, tag="v1.0.0")
    project(ws, {"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    folder = ws.folder(remotes.url(GREETER), commit)
    folder.mkdir(parents=True)
    (folder / "one.agc").write_text(files["one.agc"], encoding="utf-8")
    # Present with the locked hash: no fetch, so a remote that is gone does not matter.
    remotes_gone = {"HOME": str(ws.base / "nowhere")}
    result = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes, **remotes_gone))
    assert (result.code, result.stdout) == (0, "in the cache greeter@v1.0.0\n"), result.stderr
    assert entry["hash"] == package_hash(folder)


def test_a_moved_tag_is_pkg_tag_moved_and_the_cache_is_not_filled(ws, remotes):
    commit = one_package(ws, remotes)
    remotes.publish(GREETER, {"one.agc": "# changed\n"}, tag="v1.0.0")
    result, problem = install(ws, remotes)
    assert result.code == 1
    assert_at_key(problem, "PKG-TAG-MOVED", ws.project / "agentica.lock", "package[0].tag")
    assert not ws.folder(remotes.url(GREETER), commit).exists()


def test_files_that_are_not_the_locked_ones_are_pkg_hash_mismatch_and_nothing_is_overwritten(ws, remotes):
    commit = one_package(ws, remotes)
    # The same commit, but the lock was written for other bytes: the fetched files fail the hash and are not kept.
    ws.write_lock(lambda entries: entries[0].update(hash="sha256:" + "0" * 64))
    result, problem = install(ws, remotes)
    assert_at_key(problem, "PKG-HASH-MISMATCH", ws.project / "agentica.lock", "package[0].hash")
    folder = ws.folder(remotes.url(GREETER), commit)
    assert not folder.exists()
    # A folder already in the cache that is not the locked one is refused, and its bytes stay.
    folder.mkdir(parents=True)
    (folder / "one.agc").write_text("# edited by hand\n", encoding="utf-8")
    result, problem = install(ws, remotes)
    assert_at_key(problem, "PKG-HASH-MISMATCH", ws.project / "agentica.lock", "package[0].hash")
    assert (folder / "one.agc").read_text(encoding="utf-8") == "# edited by hand\n"


def test_a_repository_that_git_cannot_fetch_is_pkg_fetch(ws, remotes, tmp_path):
    commit = one_package(ws, remotes)
    # The repository does not exist for another owner; the tag does not exist in the repository.
    for path, tag in [("nobody/greeter", "v1.0.0"), (GREETER, "v2.0.0")]:
        ws.write_lock(lambda entries: entries[0].update(git=remotes.url(path), tag=tag))
        ws.write_manifest({"greeter": dependency(remotes.url(path), tag=tag)})
        _, problem = install(ws, remotes)
        assert_at_key(problem, "PKG-FETCH", ws.project / "agentica.lock", "package[0].git")
    # No git on PATH.
    empty = tmp_path / "no-git"
    empty.mkdir()
    project(ws, {"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    _, problem = install(ws, remotes, PATH=str(empty))
    assert_at_key(problem, "PKG-FETCH", ws.project / "agentica.lock", "package[0].git")


@pytest.mark.parametrize("files, extra, code", [
    ({"a.agc": "# a\n"}, {"links": {"b.agc": "a.agc"}}, "PKG-SYMLINK"),
    ({"a.agc": "# a\n"}, {"gitlinks": ["sub.agc"]}, "PKG-SYMLINK"),
    ({"a.agc": "# a\n", "A.agc": "# A\n"}, {}, "PKG-PATH-COLLISION"),
    ({"x/a.agc": "# 1\n", "X/a.agc": "# 2\n"}, {}, "PKG-PATH-COLLISION"),
    ({"a\\b.agc": "# a\n"}, {}, "PKG-FETCH"),
    ({"big.agc": "# " + "x" * (1 << 20) + "\n"}, {}, "PKG-FETCH"),
], ids=["a symbolic link named like a source file", "a submodule named like a source file",
        "two files that differ in case", "two folders that differ in case", "a backslash in a name",
        "a file over 1 MiB"])
def test_a_commit_that_cannot_be_a_package_is_refused(ws, remotes, files, extra, code):
    commit = remotes.publish(GREETER, files, tag="v1.0.0", **extra)
    lock_entry(ws, remotes, GREETER, files, commit, tag="v1.0.0")
    project(ws, {"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    _, problem = install(ws, remotes)
    assert_at_key(problem, code, ws.project / "agentica.lock", "package[0]")
    assert not ws.folder(remotes.url(GREETER), commit).exists()


def test_a_file_of_the_largest_size_is_fetched(ws, remotes):
    # 1 MiB is the limit of a file, and git's output for it is larger than the VM keeps of a child's output at once:
    # it is read as it arrives.
    big = "# " + "x" * ((1 << 20) - 3) + "\n"
    commit = one_package(ws, remotes, {"big.agc": big})
    result, problem = install(ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    assert (ws.folder(remotes.url(GREETER), commit) / "big.agc").read_bytes() == big.encode("utf-8")


def test_install_never_changes_the_lock_and_a_manifest_that_asks_for_more_is_stale(ws, remotes):
    commit = one_package(ws, remotes)
    before = (ws.project / "agentica.lock").read_bytes()
    assert install(ws, remotes)[0].code == 0
    assert (ws.project / "agentica.lock").read_bytes() == before
    # The manifest names a dependency that the lock lacks: nothing is fetched and the lock stays.
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0"),
                       "tools": dependency(remotes.url(TOOLS), tag="v1")})
    cache_before = cached_files(ws.pkg_root)
    _, problem = install(ws, remotes)
    assert_at_key(problem, "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.tools")
    assert (ws.project / "agentica.lock").read_bytes() == before
    assert cached_files(ws.pkg_root) == cache_before


def test_the_manifest_of_a_fetched_package_is_checked_against_the_lock(ws, remotes):
    # greeter's own manifest asks for a package the lock lacks.
    files = {"one.agc": "# one\n"}
    manifest = '[dependencies]\ntools = { git = "%s", tag = "v1" }\n' % remotes.url(TOOLS)
    commit = remotes.publish(GREETER, {**files, "agentica.toml": manifest}, tag="v1.0.0")
    lock_entry(ws, remotes, GREETER, files, commit, tag="v1.0.0")
    project(ws, {"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    _, problem = install(ws, remotes)
    folder = ws.folder(remotes.url(GREETER), commit)
    assert_at_key(problem, "PKG-LOCK-STALE", folder / "agentica.toml", "dependencies.tools")


def test_install_with_no_manifest_or_with_a_word_is_an_error(ws, remotes):
    _, problem = install(ws, remotes)
    assert problem["code"] == "PKG-MANIFEST-MISSING"
    result = run(cli() + ["install", "extra"], cwd=ws.project, env=environment(ws, remotes))
    assert result.code == 2
    # A manifest with no dependency has nothing to install.
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    plain = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes))
    assert (plain.code, plain.stdout) == (0, "nothing to install\n")
