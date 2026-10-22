"""`agentica vendor`: the locked packages copied into agc_libs/ and read before the cache
(docs/future/45-packages.md, 45d).

The remote of every case is a bare git repository in a temporary folder (tests/package_support.py, `Remotes`); the HOME,
the git config and the package cache are throwaway, and nothing touches the network. Cases assert codes and the file
and key path, never message text (AGENTS.md).
"""
import json
import os
import shutil
import stat
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run

pytestmark = host_only(WINDOWS, "the git remote of these cases is a file:// folder, tested on POSIX")

from tests.package_support import (BANG, GREET, MAIN, assert_at_key, cached_files, dependency, environment,  # noqa: E402
                                    git, lock_entry, package_hash, remotes, run_json, ws)  # noqa: F401

# root can write into a folder whatever its mode, so the case that needs a read-only one does not hold for it.
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0

GREETER = "owner/greeter"
TOOLS = "owner/tools"
TOOLS_FILES = {"bang.agc": BANG, "docs/notes.md": "not code", ".github/hidden.agc": "junk", "agc_libs/x.agc": "junk"}
GREETER_FILES = {"greet.agc": GREET, "util/more.agc": "# more\n"}


def vendor(ws, remotes, *words, **extra):
    """The result of `--json vendor` in the project folder, and the problem it reported, or None for a success."""
    return run_json("vendor", ws, remotes, *words, **extra)


def build(ws, remotes, **extra):
    """The result of running main.agc, which imports greeter, which imports tools."""
    return run(cli() + [str(ws.project / "main.agc")], cwd=ws.project, env=environment(ws, remotes, **extra))


def problem_of(ws, remotes, **extra):
    """The problem that `--json check` reports for main.agc, or None."""
    result = run(cli() + ["--json", "check", str(ws.project / "main.agc")], cwd=ws.project,
                 env=environment(ws, remotes, **extra))
    return json.loads(result.stderr) if result.code == 1 else None


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


def test_vendor_copies_the_locked_files_and_a_build_runs_with_no_cache_and_no_git(project, remotes, tmp_path):
    ws = project
    result, problem = vendor(ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    plain = run(cli() + ["vendor"], cwd=ws.project, env=environment(ws, remotes))
    assert plain.stdout.splitlines()[0] == "vendored greeter@v1.0.0"
    libs = ws.project / "agc_libs"
    # Only what the hash covers and the manifest: not the notes, the hidden folder or the package's own agc_libs/.
    assert cached_files(libs / "greeter") == ["agentica.toml", "greet.agc", "util/more.agc"]
    assert cached_files(libs / "tools") == ["bang.agc"]
    assert sorted(os.listdir(libs)) == ["greeter", "tools"]
    assert package_hash(libs / "greeter") == ws.locked[0]["hash"]
    # Folders and files have the ordinary mode, not the private one of the staging folder: another user reads them.
    umask = os.umask(0)
    os.umask(umask)
    for folder in (libs / "greeter", libs / "greeter" / "util", libs / "tools"):
        assert stat.S_IMODE(folder.stat().st_mode) == 0o777 & ~umask, folder
    assert stat.S_IMODE((libs / "greeter" / "greet.agc").stat().st_mode) & 0o044 == 0o044 & ~umask

    # The bytecode names the files by package and version, so it is the same from the cache and from the copies.
    from_cache = tmp_path / "cache.agcb"
    assert run(cli() + ["compile", str(ws.project / "main.agc"), "-o", str(from_cache)], cwd=ws.project,
               env=environment(ws, remotes)).code == 0
    shutil.rmtree(ws.pkg_root)
    empty = tmp_path / "no-git"
    empty.mkdir()
    ran = build(ws, remotes, PATH=str(empty))
    assert (ran.code, ran.stdout) == (0, "hello!\n"), ran.stderr
    from_copies = tmp_path / "copies.agcb"
    assert run(cli() + ["compile", str(ws.project / "main.agc"), "-o", str(from_copies)], cwd=ws.project,
               env=environment(ws, remotes, PATH=str(empty))).code == 0
    assert from_cache.read_bytes() == from_copies.read_bytes()
    # No cache folder at all (no HOME): the copies are enough.
    nowhere = build(ws, remotes, HOME=None, XDG_CACHE_HOME=None, PATH=str(empty))
    assert (nowhere.code, nowhere.stdout) == (0, "hello!\n"), nowhere.stderr


def test_a_vendored_copy_is_read_before_the_cache_and_a_copy_that_differs_is_never_replaced_by_it(project, remotes):
    ws = project
    assert vendor(ws, remotes)[0].code == 0
    greeter = ws.folder(remotes.url(GREETER), ws.locked[0]["commit"])
    # The copy wins: a cache that was edited does not matter while the copy is good.
    (greeter / "greet.agc").write_text("# edited cache\n", encoding="utf-8")
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "hello!\n"), ran.stderr
    # A copy edited by hand is PKG-HASH-MISMATCH: the cache is not used instead, even though it is good here.
    (greeter / "greet.agc").write_text(GREET, encoding="utf-8")
    (ws.project / "agc_libs" / "greeter" / "greet.agc").write_text("# edited copy\n", encoding="utf-8")
    problem = problem_of(ws, remotes)
    assert problem["code"] == "PKG-HASH-MISMATCH"
    assert Path(problem["file"]) == ws.project / "main.agc"
    # A file added to the copy changes the hash too.
    (ws.project / "agc_libs" / "greeter" / "greet.agc").write_text(GREET, encoding="utf-8")
    (ws.project / "agc_libs" / "greeter" / "extra.agc").write_text("# extra\n", encoding="utf-8")
    assert problem_of(ws, remotes)["code"] == "PKG-HASH-MISMATCH"


def test_vendor_again_puts_the_locked_files_back_and_leaves_other_entries_of_agc_libs_alone(project, remotes, tmp_path):
    ws = project
    libs = ws.project / "agc_libs"
    # Entries that are not the folder of a locked package: a pkg/ library, a package that is not locked any more, a file.
    (libs / "acme").mkdir(parents=True)
    (libs / "acme" / "tools.agc").write_text("# acme\n", encoding="utf-8")
    (libs / "gone").mkdir()
    (libs / "gone" / "old.agc").write_text("# old\n", encoding="utf-8")
    (libs / "notes.txt").write_text("keep\n", encoding="utf-8")
    # The folder of a locked package is replaced whatever it holds: a link is replaced as a link, its target is not touched.
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.agc").write_text("# outside\n", encoding="utf-8")
    os.symlink(outside, libs / "tools")
    assert vendor(ws, remotes)[0].code == 0
    assert not (libs / "tools").is_symlink()
    assert cached_files(libs / "tools") == ["bang.agc"]
    assert cached_files(outside) == ["keep.agc"]
    assert cached_files(libs / "acme") == ["tools.agc"] and cached_files(libs / "gone") == ["old.agc"]
    assert (libs / "notes.txt").read_text(encoding="utf-8") == "keep\n"
    # An edited copy and a stale file are gone after the next vendor, and no staging folder stays behind.
    (libs / "greeter" / "greet.agc").write_text("# edited\n", encoding="utf-8")
    (libs / "greeter" / "stale.agc").write_text("# stale\n", encoding="utf-8")
    assert vendor(ws, remotes)[0].code == 0
    assert cached_files(libs / "greeter") == ["agentica.toml", "greet.agc", "util/more.agc"]
    assert package_hash(libs / "greeter") == ws.locked[0]["hash"]
    assert sorted(os.listdir(libs)) == ["acme", "gone", "greeter", "notes.txt", "tools"]
    assert build(ws, remotes).stdout == "hello!\n"


def test_vendor_never_writes_through_a_link_that_agc_libs_is(project, remotes, tmp_path):
    ws = project
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, ws.project / "agc_libs")
    _, problem = vendor(ws, remotes)
    assert problem["code"] == "PKG-SYMLINK"
    assert os.listdir(outside) == []
    # A file where the folder belongs is PKG-WRITE.
    (ws.project / "agc_libs").unlink()
    (ws.project / "agc_libs").write_text("not a folder", encoding="utf-8")
    _, problem = vendor(ws, remotes)
    assert problem["code"] == "PKG-WRITE"


def test_vendor_fills_the_missing_cache_and_a_cache_that_fails_the_hash_writes_nothing(project, remotes):
    ws = project
    # The cache is empty: vendor fetches (install's fetch), then copies.
    assert not ws.pkg_root.exists()
    assert vendor(ws, remotes)[0].code == 0
    assert ws.pkg_root.exists() and (ws.project / "agc_libs" / "greeter" / "greet.agc").exists()
    shutil.rmtree(ws.project / "agc_libs")
    greeter = ws.folder(remotes.url(GREETER), ws.locked[0]["commit"])
    (greeter / "greet.agc").write_text("# edited cache\n", encoding="utf-8")
    _, problem = vendor(ws, remotes)
    assert_at_key(problem, "PKG-HASH-MISMATCH", ws.project / "agentica.lock", "package[0].hash")
    assert not (ws.project / "agc_libs").exists()


def test_vendor_with_no_manifest_a_stale_lock_a_word_or_nothing_locked(ws, remotes):
    _, problem = vendor(ws, remotes)
    assert problem["code"] == "PKG-MANIFEST-MISSING"
    ws.write_manifest({})
    ws.write_lock()
    result = run(cli() + ["vendor"], cwd=ws.project, env=environment(ws, remotes))
    assert (result.code, result.stdout) == (0, "nothing to vendor\n"), result.stderr
    assert not (ws.project / "agc_libs").exists()
    result = run(cli() + ["vendor", "extra"], cwd=ws.project, env=environment(ws, remotes))
    assert result.code == 2
    # The manifest asks for a package the lock lacks: nothing is written.
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    _, problem = vendor(ws, remotes)
    assert_at_key(problem, "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.greeter")
    assert not (ws.project / "agc_libs").exists()


def test_a_locked_package_the_manifest_did_not_declare_is_not_reached_through_the_vendored_copy(project, remotes):
    ws = project
    # tools is locked because greeter needs it; the project does not declare it.
    (ws.project / "main.agc").write_text('import Tools from "pkg/tools/bang"\n', encoding="utf-8")
    before = problem_of(ws, remotes)
    assert vendor(ws, remotes)[0].code == 0
    after = problem_of(ws, remotes)
    assert (before["code"], after["code"]) == ("CHECK-IMPORT-IO", "CHECK-IMPORT-IO")
    assert before["range"] == after["range"]


@pytest.mark.skipif(ROOT_USER, reason="root writes into a read-only folder")
def test_a_write_that_fails_keeps_the_old_copy_and_leaves_no_hidden_folder(project, remotes):
    ws = project
    libs = ws.project / "agc_libs"
    assert vendor(ws, remotes)[0].code == 0
    (libs / "greeter" / "stale.agc").write_text("# stale\n", encoding="utf-8")
    libs.chmod(0o555)
    try:
        _, problem = vendor(ws, remotes)
    finally:
        libs.chmod(0o755)
    assert problem["code"] == "PKG-WRITE"
    assert sorted(os.listdir(libs)) == ["greeter", "tools"]
    assert (libs / "greeter" / "stale.agc").exists()


def test_a_package_with_nested_folders_is_vendored_and_imported(ws, remotes):
    files = {"a/b/c/z.agc": 'export def z() -> String\n  return "deep"\nend\n', "a/top.agc": "# top\n"}
    commit = remotes.publish("owner/nested", files, tag="v1.0.0")
    lock_entry(ws, remotes, "owner/nested", files, commit, tag="v1.0.0")
    ws.write_manifest({"nested": dependency(remotes.url("owner/nested"), tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(
        'import Z from "pkg/nested/a/b/c/z"\n\ndef main() -> Void\n  puts(Z.z())\nend\n', encoding="utf-8")
    assert vendor(ws, remotes)[0].code == 0
    copy = ws.project / "agc_libs" / "nested"
    assert cached_files(copy) == ["a/b/c/z.agc", "a/top.agc"]
    assert package_hash(copy) == ws.locked[0]["hash"]
    shutil.rmtree(ws.pkg_root)
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "deep\n"), ran.stderr
