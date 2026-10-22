"""`agentica install`, `add` and `update` write the packages to deps/, and a build reads only deps/
(docs/grammar/05b-modules.md, issue 578).

The remote of every case is a bare git repository in a temporary folder (tests/package_support.py, `Remotes`); the HOME,
the git config and the package cache are throwaway, and nothing touches the network. Cases assert codes and the file
and key path, never message text (AGENTS.md).
"""
import os
import shutil
import stat

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run
from tests.package_support import (BANG, GREET, MAIN, assert_at_key, cached_files, dependency, environment,  # noqa: F401
                                    git, lock_entry, package_hash, problem_of, remotes, run_json, ws)

pytestmark = host_only(WINDOWS, "the git remote of these cases is a file:// folder, tested on POSIX")

# root can write into a folder whatever its mode, so the case that needs a read-only one does not hold for it.
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0

GREETER = "owner/greeter"
TOOLS = "owner/tools"
TOOLS_FILES = {"bang.agc": BANG, "docs/notes.md": "not code", ".github/hidden.agc": "junk", "agc_libs/x.agc": "junk"}
GREETER_FILES = {"greet.agc": GREET, "util/more.agc": "# more\n"}


def install(ws, remotes, *words, **extra):
    """The result of `--json install` in the project folder, and the problem it reported, or None for a success."""
    return run_json("install", ws, remotes, *words, **extra)


def build(ws, remotes, **extra):
    """The result of running main.agc, which imports greeter, which imports tools."""
    return run(cli() + [str(ws.project / "main.agc")], cwd=ws.project, env=environment(ws, remotes, **extra))


@pytest.fixture
def project(ws, remotes):
    """A project that depends on greeter (a tag), which depends on tools (a commit), both locked and on the remote."""
    tools_commit = remotes.publish(TOOLS, TOOLS_FILES, tag="v9", annotated=False)
    manifest = ('name = "greeter"\n\n[dependencies]\ntools = { git = "%s", ref = "%s" }\n'
                % (remotes.url(TOOLS), tools_commit))
    greeter_commit = remotes.publish(GREETER, {**GREETER_FILES, "agentica.toml": manifest}, tag="v1.0.0")
    lock_entry(ws, remotes, GREETER, GREETER_FILES, greeter_commit, tag="v1.0.0")
    lock_entry(ws, remotes, TOOLS, TOOLS_FILES, tools_commit, ref=tools_commit)
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    return ws


def test_install_writes_every_locked_package_flat_into_deps_and_a_build_runs_with_no_cache_and_no_git(
        project, remotes, tmp_path):
    ws = project
    result, problem = install(ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    deps = ws.deps
    # The transitive package is as flat as the direct one. Only what the hash covers and the manifest are written: not
    # the notes, the hidden folder or the package's own agc_libs/. The tool writes no .gitignore.
    assert sorted(os.listdir(deps)) == ["greeter", "tools"]
    assert cached_files(deps / "greeter") == ["agentica.toml", "greet.agc", "util/more.agc"]
    assert cached_files(deps / "tools") == ["bang.agc"]
    assert package_hash(deps / "greeter") == ws.locked[0]["hash"]
    # Folders and files have the ordinary mode, not the private one of the staging folder: another user reads them.
    umask = os.umask(0)
    os.umask(umask)
    for folder in (deps / "greeter", deps / "greeter" / "util", deps / "tools"):
        assert stat.S_IMODE(folder.stat().st_mode) == 0o777 & ~umask, folder
    assert stat.S_IMODE((deps / "greeter" / "greet.agc").stat().st_mode) & 0o044 == 0o044 & ~umask

    # The cache is only a download cache: with it gone, and no git and no HOME, the build still runs.
    shutil.rmtree(ws.pkg_root)
    empty = tmp_path / "no-git"
    empty.mkdir()
    ran = build(ws, remotes, PATH=str(empty), HOME=None, XDG_CACHE_HOME=None)
    assert (ran.code, ran.stdout) == (0, "hello!\n"), ran.stderr


def test_a_declared_package_that_deps_lacks_is_check_import_package_and_a_changed_file_is_a_hash_mismatch(
        project, remotes):
    ws = project
    # Nothing was installed: the build does not fall back to the cache, which install would have filled.
    assert problem_of(ws, remotes)["code"] == "CHECK-IMPORT-PACKAGE"
    assert install(ws, remotes)[1] is None
    assert build(ws, remotes).stdout == "hello!\n"
    shutil.rmtree(ws.deps / "greeter")
    assert problem_of(ws, remotes)["code"] == "CHECK-IMPORT-PACKAGE"
    assert install(ws, remotes)[1] is None
    # A file edited by hand is PKG-HASH-MISMATCH, and so is a file added.
    (ws.deps / "greeter" / "greet.agc").write_text("# edited\n", encoding="utf-8")
    assert problem_of(ws, remotes)["code"] == "PKG-HASH-MISMATCH"
    assert install(ws, remotes)[1] is None
    (ws.deps / "greeter" / "extra.agc").write_text("# extra\n", encoding="utf-8")
    assert problem_of(ws, remotes)["code"] == "PKG-HASH-MISMATCH"


def test_install_again_puts_the_locked_files_back_replaces_a_link_and_leaves_other_entries_alone(
        project, remotes, tmp_path):
    ws = project
    deps = ws.deps
    # Entries that are not the folder of a locked package stay as they are.
    (deps / "gone").mkdir(parents=True)
    (deps / "gone" / "old.agc").write_text("# old\n", encoding="utf-8")
    (deps / "notes.txt").write_text("keep\n", encoding="utf-8")
    # The folder of a locked package is replaced whatever it holds: a link is replaced as a link, its target is not
    # touched.
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.agc").write_text("# outside\n", encoding="utf-8")
    os.symlink(outside, deps / "tools")
    assert install(ws, remotes)[1] is None
    assert not (deps / "tools").is_symlink()
    assert cached_files(deps / "tools") == ["bang.agc"]
    assert cached_files(outside) == ["keep.agc"]
    assert cached_files(deps / "gone") == ["old.agc"]
    assert (deps / "notes.txt").read_text(encoding="utf-8") == "keep\n"
    # An edited copy and a stale file are gone after the next install, and no staging folder stays behind.
    (deps / "greeter" / "greet.agc").write_text("# edited\n", encoding="utf-8")
    (deps / "greeter" / "stale.agc").write_text("# stale\n", encoding="utf-8")
    assert install(ws, remotes)[1] is None
    assert cached_files(deps / "greeter") == ["agentica.toml", "greet.agc", "util/more.agc"]
    assert sorted(os.listdir(deps)) == ["gone", "greeter", "notes.txt", "tools"]
    assert build(ws, remotes).stdout == "hello!\n"


def test_install_never_writes_through_a_link_that_deps_is(project, remotes, tmp_path):
    ws = project
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, ws.deps)
    _, problem = install(ws, remotes)
    assert problem["code"] == "PKG-SYMLINK"
    assert os.listdir(outside) == []
    # A file where the folder belongs is PKG-WRITE.
    ws.deps.unlink()
    ws.deps.write_text("not a folder", encoding="utf-8")
    _, problem = install(ws, remotes)
    assert problem["code"] == "PKG-WRITE"


def test_a_cache_that_fails_the_hash_writes_nothing_to_deps(project, remotes):
    ws = project
    assert install(ws, remotes)[1] is None
    shutil.rmtree(ws.deps)
    greeter = ws.folder(remotes.url(GREETER), ws.locked[0]["commit"])
    (greeter / "greet.agc").write_text("# edited cache\n", encoding="utf-8")
    _, problem = install(ws, remotes)
    assert_at_key(problem, "PKG-HASH-MISMATCH", ws.project / "agentica.lock", "package[0].hash")
    assert not ws.deps.exists()


def test_install_with_no_manifest_a_word_or_nothing_locked_writes_no_deps(ws, remotes):
    _, problem = install(ws, remotes)
    assert problem["code"] == "PKG-MANIFEST-MISSING"
    ws.write_manifest({})
    ws.write_lock()
    result = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes))
    assert (result.code, result.stdout) == (0, "nothing to install\n"), result.stderr
    assert not ws.deps.exists()
    assert run(cli() + ["install", "extra"], cwd=ws.project, env=environment(ws, remotes)).code == 2
    # The manifest asks for a package the lock lacks: nothing is written.
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    _, problem = install(ws, remotes)
    assert_at_key(problem, "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.greeter")
    assert not ws.deps.exists()


def test_update_removes_a_dropped_package_without_following_a_link_and_leaves_other_entries(project, remotes, tmp_path):
    ws = project
    assert install(ws, remotes)[1] is None
    (ws.deps / "notes.txt").write_text("keep\n", encoding="utf-8")
    # tools becomes a link to a folder outside the project: removing it removes the link, never the target.
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.agc").write_text("# outside\n", encoding="utf-8")
    shutil.rmtree(ws.deps / "tools")
    os.symlink(outside, ws.deps / "tools")
    # The project stops using greeter, so greeter and tools (which only it needed) leave the lock.
    ws.write_manifest({})
    result = run(cli() + ["update"], cwd=ws.project, env=environment(ws, remotes))
    assert (result.code, result.stdout) == (0, "removed greeter\nremoved tools\n"), result.stderr
    assert sorted(os.listdir(ws.deps)) == ["notes.txt"]
    assert cached_files(outside) == ["keep.agc"]


@pytest.mark.skipif(ROOT_USER, reason="root writes into a read-only folder")
def test_a_write_that_fails_keeps_the_old_copy_and_leaves_no_hidden_folder(project, remotes):
    ws = project
    deps = ws.deps
    assert install(ws, remotes)[1] is None
    (deps / "greeter" / "stale.agc").write_text("# stale\n", encoding="utf-8")
    deps.chmod(0o555)
    try:
        _, problem = install(ws, remotes)
    finally:
        deps.chmod(0o755)
    assert problem["code"] == "PKG-WRITE"
    assert sorted(os.listdir(deps)) == ["greeter", "tools"]
    assert (deps / "greeter" / "stale.agc").exists()

