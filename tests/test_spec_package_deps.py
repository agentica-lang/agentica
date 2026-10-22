"""`agentica install`, `add` and `update` write the packages to deps/, and a build reads only deps/
(docs/grammar/05b-modules.md, issue 578).

The remote of every case is a bare git repository in a temporary folder (tests/package_support.py, `Remotes`); the HOME,
the git config and the package cache are throwaway, and nothing touches the network. Cases assert codes and the file
and key path, never message text (AGENTS.md).
"""
import contextlib
import json
import os
import shutil
import stat
import time
from pathlib import Path

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.package_support import (BANG, GREET, MAIN, assert_at_key, build, cached_files, dependency,  # noqa: F401
                                    environment, git, install, lock_entry, no_git_path, package_hash, problem_of, remotes,
                                    remove_tree, ws)


# root can write into a folder whatever its mode, so the case that needs a read-only one does not hold for it.
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0

GREETER = "owner/greeter"
TOOLS = "owner/tools"
TOOLS_FILES = {"bang.agc": BANG, "docs/notes.md": "not code", ".github/hidden.agc": "junk", "agc_libs/x.agc": "junk"}
GREETER_FILES = {"greet.agc": GREET, "util/more.agc": "# more\n"}


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


def make_old(path, seconds=3600):
    """Sets the modification time of `path` itself, not of what a link leads to, to `seconds` ago. Python cannot do it
    for a link on Windows (`os.utime` has no `follow_symlinks=False` there), so that is one call of the Windows API."""
    when = time.time() - seconds
    if os.name != "nt":
        os.utime(path, (when, when), follow_symlinks=False)
        return
    import ctypes
    from ctypes import byref, c_void_p, c_wchar_p, wintypes
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = [c_wchar_p, wintypes.DWORD, wintypes.DWORD, c_void_p, wintypes.DWORD, wintypes.DWORD,
                                     c_void_p]
    kernel32.CreateFileW.restype = c_void_p
    kernel32.SetFileTime.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
    kernel32.CloseHandle.argtypes = [c_void_p]
    ticks = int((when + 11644473600) * 10_000_000)  # 100 ns since 1601, as FILETIME counts
    stamp = wintypes.FILETIME(ticks & 0xFFFFFFFF, ticks >> 32)
    # FILE_WRITE_ATTRIBUTES, shared with all, OPEN_EXISTING, BACKUP_SEMANTICS (a folder) | OPEN_REPARSE_POINT (the link).
    handle = kernel32.CreateFileW(str(path), 0x100, 7, None, 3, 0x02000000 | 0x00200000, None)
    assert handle not in (None, c_void_p(-1).value), ctypes.WinError(ctypes.get_last_error())
    try:
        assert kernel32.SetFileTime(handle, None, None, byref(stamp)), ctypes.WinError(ctypes.get_last_error())
    finally:
        kernel32.CloseHandle(handle)


@contextlib.contextmanager
def write_blocked(package):
    """While the block runs, a write of the folder `package` of deps/ fails. POSIX: deps/ is read-only. Windows has no
    such mode, but a file that a process holds open (an editor, for instance) stops the rename of the folder that holds
    it."""
    if os.name == "nt":
        with open(package / "stale.agc", "rb"):
            yield
        return
    package.parent.chmod(0o555)
    try:
        yield
    finally:
        package.parent.chmod(0o755)


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
    remove_tree(ws.pkg_root)
    empty = no_git_path(tmp_path)
    ran = build(ws, remotes, PATH=empty, HOME=None, XDG_CACHE_HOME=None)
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
    # A folder that already has the locked hash is not written again, so the bytecode cache keeps its entries.
    greet = deps / "greeter" / "greet.agc"
    before = greet.stat().st_mtime_ns
    assert install(ws, remotes)[1] is None
    assert greet.stat().st_mtime_ns == before
    # Leftovers of a killed command (.old-* and .tmp-*, a link among them) that are older than ten minutes are removed,
    # without following links; a younger one (a command may still be using it) and any other hidden entry stay.
    (deps / ".old-1-greeter").mkdir()
    (deps / ".old-1-greeter" / "x.agc").write_text("# old\n", encoding="utf-8")
    (deps / ".tmp-2").mkdir()
    os.symlink(outside, deps / ".tmp-3")
    (deps / ".tmp-fresh").mkdir()
    os.symlink(outside, deps / ".old-fresh")
    (deps / ".keep").write_text("keep\n", encoding="utf-8")
    for name in (".old-1-greeter", ".tmp-2", ".tmp-3"):
        make_old(deps / name)
    assert install(ws, remotes)[1] is None
    assert sorted(os.listdir(deps)) == [".keep", ".old-fresh", ".tmp-fresh", "gone", "greeter", "notes.txt", "tools"]
    assert cached_files(outside) == ["keep.agc"]
    (deps / ".keep").unlink()
    (deps / ".old-fresh").unlink()
    (deps / ".tmp-fresh").rmdir()
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
    with write_blocked(deps / "greeter"):
        _, problem = install(ws, remotes)
    assert problem["code"] == "PKG-WRITE"
    assert sorted(os.listdir(deps)) == ["greeter", "tools"]
    assert (deps / "greeter" / "stale.agc").exists()


TEST_FILE = 'def main() -> Void\n  Test.run([Test.test("t") do ok() end])\nend\n'
MODULE = 'export def mine() -> Int\n  return 1\nend\n'


def test_the_walks_of_test_and_symbol_skip_the_deps_of_the_project(tmp_path):
    # Installed packages are not the tests or the modules of the project: `test .` and `symbol` with no path skip the
    # deps/ beside agentica.toml, while a path that names a folder of deps/ reads it.
    (tmp_path / "deps" / "tools").mkdir(parents=True)
    (tmp_path / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    (tmp_path / "mine_test.agc").write_text(TEST_FILE, encoding="utf-8")
    (tmp_path / "mine.agc").write_text(MODULE, encoding="utf-8")
    (tmp_path / "deps" / "tools" / "bang_test.agc").write_text(TEST_FILE, encoding="utf-8")
    (tmp_path / "deps" / "tools" / "bang.agc").write_text(BANG, encoding="utf-8")
    ran = run(cli() + ["--json", "test", "."], cwd=tmp_path, env=vm_environment())
    assert ran.code == 0, ran.stderr
    assert [Path(item["path"]).name for item in json.loads(ran.stdout)["files"]] == ["mine_test.agc"]
    ran = run(cli() + ["--json", "test", "deps"], cwd=tmp_path, env=vm_environment())
    assert [Path(item["path"]).name for item in json.loads(ran.stdout)["files"]] == ["bang_test.agc"]
    listed = run(cli() + ["--json", "symbol", "bang"], cwd=tmp_path, env=vm_environment())
    assert json.loads(listed.stderr or listed.stdout)["code"] == "QUERY-NOT-FOUND"
    named = run(cli() + ["--json", "symbol", "bang", "deps"], cwd=tmp_path, env=vm_environment())
    assert [item["module"] for item in json.loads(named.stdout)["matches"]] == ["deps/tools/bang.agc"]


def test_update_that_cannot_write_deps_has_saved_the_lock_and_says_so(project, remotes, tmp_path):
    ws = project
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, ws.deps)
    # The project stops using greeter, so the new lock is empty and the old folders are to be removed from deps/.
    ws.write_manifest({})
    before = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    result = run(cli() + ["--json", "update"], cwd=ws.project, env=environment(ws, remotes))
    problem = json.loads(result.stderr)
    assert (result.code, problem["code"]) == (1, "PKG-SYMLINK")
    # The one help the test reads: it is the behavior under test (PKG-SYMLINK has a help of its own).
    assert "agentica install" in problem.get("help", "")
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") != before
    assert os.listdir(outside) == []
