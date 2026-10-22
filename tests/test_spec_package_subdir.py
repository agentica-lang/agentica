"""Several packages in one repository: the `subdir` key of a git dependency (docs/grammar/05b-modules.md, issue 573).

The remote of every case is a bare git repository in a temporary folder behind a throwaway HOME (tests/package_support.py,
`Remotes`), so nothing touches the network. The repository holds `sqlite/`, `postgres/` and `common/`; a project uses
the first two. Cases assert codes and the file and key path, never message text (AGENTS.md).
"""
import json
import os
import shutil
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run
from tests.package_support import (assert_at_key, cached_files, command, dependency, environment, git,  # noqa: F401
                                    inline_table, lock_entry, package_hash, problem_of, remotes, run_json, ws)

pytestmark = host_only(WINDOWS, "the git remote of these cases is a file:// folder, tested on POSIX")

REPOSITORY = "owner/agentica-packages"
SQLITE = {"db.agc": 'export def open() -> String\n  return "sqlite"\nend\n', "util/text.agc": "# text\n"}
POSTGRES = {"db.agc": 'export def open() -> String\n  return "postgres"\nend\n'}
# Files of the repository outside the two folders, and the junk a package leaves out.
ELSEWHERE = {"common/util.agc": "# common\n", "README.md": "not code", "root.agc": "# root\n",
             "other/y.agc": "# other\n"}
MAIN = ('import Sqlite from "pkg/sqlite/db"\nimport Postgres from "pkg/postgres/db"\n\n'
        'def main() -> Void\n  puts(Sqlite.open() + " " + Postgres.open())\nend\n')


def tree(sqlite=None, postgres=None, **extra):
    """The files of the repository: both packages under their folders, and what lies beside them."""
    files = dict(ELSEWHERE, **extra)
    files.update({"sqlite/" + path: text for path, text in (SQLITE if sqlite is None else sqlite).items()})
    files.update({"postgres/" + path: text for path, text in (POSTGRES if postgres is None else postgres).items()})
    return files


def url(remotes):
    return remotes.url(REPOSITORY)


def locked(ws, remotes, commit, sqlite=None, postgres=None, tag="sqlite-0.1.0"):
    """Notes the lock entries of the two folders at one commit (the tag pins sqlite; postgres has its own)."""
    lock_entry(ws, remotes, REPOSITORY, SQLITE if sqlite is None else sqlite, commit, tag=tag, name="sqlite",
               subdir="sqlite")
    lock_entry(ws, remotes, REPOSITORY, POSTGRES if postgres is None else postgres, commit, tag="postgres-0.1.0",
               name="postgres", subdir="postgres")


def tag_too(remotes, *tags):
    """Tags the commit that was published last with more tags, as a repository of several packages does."""
    work = remotes.work / REPOSITORY
    for tag in tags:
        remotes.git("tag", "-f", tag, cwd=work)
        remotes.git("push", "--quiet", "--force", "origin", "refs/tags/" + tag, cwd=work)


def declare(ws, remotes):
    """Writes the manifest (both folders), the lock of what was noted and the program that imports both."""
    ws.write_manifest({"sqlite": dependency(url(remotes), tag="sqlite-0.1.0", subdir="sqlite"),
                       "postgres": dependency(url(remotes), tag="postgres-0.1.0", subdir="postgres")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def project(ws, remotes):
    """A project that uses both folders, locked at one commit with a tag each; returns the commit."""
    commit = remotes.publish(REPOSITORY, tree(), tag="sqlite-0.1.0")
    tag_too(remotes, "postgres-0.1.0")
    locked(ws, remotes, commit)
    declare(ws, remotes)
    return commit


def build(ws, remotes, **extra):
    return run(cli() + [str(ws.project / "main.agc")], cwd=ws.project, env=environment(ws, remotes, **extra))


def test_two_folders_of_one_repository_are_two_packages_and_install_keeps_only_the_declared_folders(ws, remotes, tmp_path):
    commit = project(ws, remotes)
    result, problem = run_json("install", ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    # The lock is sorted by name.
    plain = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes))
    assert plain.stdout == "in the cache postgres@postgres-0.1.0\nin the cache sqlite@sqlite-0.1.0\n", plain.stderr

    # One cache folder for each package holds the files of its folder and nothing else of the repository.
    sqlite = ws.folder(url(remotes), commit, "sqlite")
    assert cached_files(sqlite) == ["db.agc", "util/text.agc"]
    assert cached_files(ws.folder(url(remotes), commit, "postgres")) == ["db.agc"]
    assert not ws.folder(url(remotes), commit).exists()
    assert package_hash(sqlite) == ws.locked[0]["hash"]
    assert sorted(os.listdir(ws.pkg_root / "example.test" / "owner" / "agentica-packages")) == [
        commit + "@postgres", commit + "@sqlite"]
    assert not [name for name in os.listdir(ws.pkg_root) if name.startswith(".")]

    # The program builds and runs from deps/ with no git: a build never fetches.
    empty = tmp_path / "no-git"
    empty.mkdir()
    ran = build(ws, remotes, PATH=str(empty))
    assert (ran.code, ran.stdout) == (0, "sqlite postgres\n"), ran.stderr


def test_a_nested_subdir_is_one_cache_folder_and_a_package_inside_another_package_is_not_part_of_it(ws, remotes):
    files = {"libs/sql/db.agc": SQLITE["db.agc"], "libs/sql/nested/more.agc": "# more\n", "libs/other.agc": "# other\n"}
    commit = remotes.publish(REPOSITORY, files, tag="v1")
    lock_entry(ws, remotes, REPOSITORY, {"db.agc": SQLITE["db.agc"], "nested/more.agc": "# more\n"}, commit, tag="v1",
               name="sql", subdir="libs/sql")
    ws.write_manifest({"sql": dependency(url(remotes), tag="v1", subdir="libs/sql")})
    ws.write_lock()
    (ws.project / "main.agc").write_text('import Db from "pkg/sql/db"\n\ndef main() -> Void\n  puts(Db.open())\nend\n',
                                         encoding="utf-8")
    assert run_json("install", ws, remotes)[1] is None
    assert cached_files(ws.folder(url(remotes), commit, "libs/sql")) == ["db.agc", "nested/more.agc"]
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "sqlite\n"), ran.stderr


def test_the_hash_ignores_a_change_outside_the_folder_and_update_keeps_it(ws, remotes):
    first = project(ws, remotes)
    assert run_json("install", ws, remotes)[1] is None
    before = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    # A new commit changes postgres/, the common folder and the root; sqlite/ is the same. The tag moves to it.
    second = remotes.publish(REPOSITORY, tree(postgres={"db.agc": "# changed\n"}, **{"common/util.agc": "# new\n"}),
                             tag="sqlite-0.1.0")
    assert second != first
    plain = run(cli() + ["update", "sqlite"], cwd=ws.project, env=environment(ws, remotes))
    assert (plain.code, plain.stdout) == (0, "updated sqlite@sqlite-0.1.0 (folder sqlite)\n"), plain.stderr
    after = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    # The commit is the new one, the hash of sqlite/ is the old one, and postgres (not asked to move) is untouched.
    assert after != before
    assert package_hash(ws.folder(url(remotes), second, "sqlite")) == ws.locked[0]["hash"]
    ws.locked[0]["commit"] = second
    assert after == ws.lock_text()
    assert problem_of(ws, remotes) is None


@pytest.mark.parametrize("subdir", [
    "../sqlite", "sqlite/..", "/sqlite", "sqlite/", "a//b", "", ".", ".hidden", "sqlite/.git", "agc_libs", "a/AGC_LIBS/b",
    "a b", "a\\b", "a:b", "sqlite.", "con", "a/nul.txt", "a@b", "x" * 129,
], ids=lambda value: value or "empty")
def test_a_bad_subdir_in_the_manifest_is_pkg_manifest_invalid_at_its_key(ws, remotes, subdir):
    ws.write_manifest({"sqlite": dependency(url(remotes), tag="v1", subdir=subdir)})
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    assert_at_key(problem_of(ws, remotes), "PKG-MANIFEST-INVALID", ws.project / "agentica.toml",
                  "dependencies.sqlite.subdir")


def test_a_subdir_that_is_not_text_is_refused_and_a_good_one_is_not(ws, remotes):
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    ws.write_lock()
    for value in ("3", "[\"a\"]"):
        (ws.project / "agentica.toml").write_text(
            '[dependencies]\nsqlite = { git = "%s", tag = "v1", subdir = %s }\n' % (url(remotes), value), encoding="utf-8")
        assert_at_key(problem_of(ws, remotes), "PKG-MANIFEST-INVALID", ws.project / "agentica.toml",
                      "dependencies.sqlite.subdir")
    for good in ("sqlite", "a/b-c/d_e.f", "A1", "x" * 128):
        ws.write_manifest({"sqlite": dependency(url(remotes), tag="v1", subdir=good)})
        # The manifest is good: the next failure is the lock, which has no such entry.
        assert problem_of(ws, remotes)["code"] == "PKG-LOCK-STALE"


def test_a_bad_subdir_in_the_lock_is_pkg_lock_invalid_at_its_key(ws, remotes):
    project(ws, remotes)
    ws.write_lock(lambda entries: entries[1].update(subdir="../sqlite"))
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-INVALID", ws.project / "agentica.lock", "package[1].subdir")


def test_the_lock_and_the_manifest_must_agree_on_the_subdir(ws, remotes):
    project(ws, remotes)
    # The lock names another folder of the same repository, and the same folder without a subdir is another source too.
    ws.write_lock(lambda entries: entries[1].update(subdir="sqlite2"))
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.sqlite")
    ws.write_lock(lambda entries: entries[1].pop("subdir"))
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.sqlite")


def test_a_package_that_names_another_folder_for_a_name_is_a_source_conflict(ws, remotes):
    # The lock has common as the folder "other"; postgres asks for the folder "common" under the same name.
    manifest = 'name = "postgres"\n\n[dependencies]\ncommon = %s\n' % inline_table(
        dependency(url(remotes), tag="common-1", subdir="common"))
    files = tree(postgres={"db.agc": POSTGRES["db.agc"], "agentica.toml": manifest})
    commit = remotes.publish(REPOSITORY, files, tag="sqlite-0.1.0")
    tag_too(remotes, "postgres-0.1.0", "common-1")
    locked(ws, remotes, commit, postgres=dict(POSTGRES, **{"agentica.toml": manifest}))
    lock_entry(ws, remotes, REPOSITORY, {"y.agc": "# other\n"}, commit, tag="common-1", name="common", subdir="other")
    declare(ws, remotes)
    _, problem = run_json("install", ws, remotes)
    cached = ws.folder(url(remotes), commit, "postgres") / "agentica.toml"
    assert_at_key(problem, "PKG-SOURCE-CONFLICT", cached, "dependencies.common")
    # The manifests are checked in the cache before anything is written to deps/.
    assert not ws.deps.exists()


def test_a_relative_import_cannot_leave_the_folder(ws, remotes):
    sqlite = dict(SQLITE, **{"db.agc": 'import Util from "../common/util"\n\n' + SQLITE["db.agc"]})
    commit = remotes.publish(REPOSITORY, tree(sqlite=sqlite), tag="sqlite-0.1.0")
    lock_entry(ws, remotes, REPOSITORY, sqlite, commit, tag="sqlite-0.1.0", name="sqlite", subdir="sqlite")
    ws.write_manifest({"sqlite": dependency(url(remotes), tag="sqlite-0.1.0", subdir="sqlite")})
    ws.write_lock()
    (ws.project / "main.agc").write_text('import Sqlite from "pkg/sqlite/db"\n\ndef main() -> Void\n  puts(Sqlite.open())\nend\n',
                                         encoding="utf-8")
    assert run_json("install", ws, remotes)[1] is None
    # The file is in the repository, one folder up, but the package is the folder: the import is refused at the import.
    problem = problem_of(ws, remotes)
    assert problem["code"] == "CHECK-IMPORT-PATH"
    assert Path(problem["file"]) == ws.deps / "sqlite" / "db.agc"


def test_install_refuses_a_subdir_that_the_commit_lacks_or_that_is_not_a_folder(ws, remotes):
    commit = remotes.publish(REPOSITORY, tree(), tag="sqlite-0.1.0", links={"link": "sqlite"}, gitlinks=["module"])
    for index, subdir in enumerate(["missing", "root.agc", "link", "module", "sqlite/missing"]):
        lock_entry(ws, remotes, REPOSITORY, SQLITE, commit, tag="sqlite-0.1.0", name="sqlite", subdir=subdir)
        ws.write_manifest({"sqlite": dependency(url(remotes), tag="sqlite-0.1.0", subdir=subdir)})
        ws.write_lock()
        _, problem = run_json("install", ws, remotes)
        assert_at_key(problem, "PKG-FETCH", ws.project / "agentica.lock", "package[0].subdir")
        ws.locked.clear()
    assert not ws.folder(url(remotes), commit, "missing").exists()


def test_install_writes_one_deps_folder_for_each_package_with_only_its_folder_and_a_build_needs_no_cache(
        ws, remotes, tmp_path):
    project(ws, remotes)
    result, problem = run_json("install", ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    deps = ws.deps
    # The files of the folder only: nothing of common/, other/ or the root of the repository, and no .gitignore.
    assert sorted(os.listdir(deps)) == ["postgres", "sqlite"]
    assert cached_files(deps / "sqlite") == ["db.agc", "util/text.agc"]
    assert cached_files(deps / "postgres") == ["db.agc"]
    assert package_hash(deps / "sqlite") == ws.locked[0]["hash"]
    # No cache, no git: deps/ is enough, and the stored names are the paths inside the folders.
    shutil.rmtree(ws.pkg_root)
    empty = tmp_path / "no-git"
    empty.mkdir()
    ran = build(ws, remotes, PATH=str(empty))
    assert (ran.code, ran.stdout) == (0, "sqlite postgres\n"), ran.stderr
    out = tmp_path / "deps.agcb"
    assert run(cli() + ["compile", str(ws.project / "main.agc"), "-o", str(out)], cwd=ws.project,
               env=environment(ws, remotes, PATH=str(empty))).code == 0
    assert b"pkg/sqlite@sqlite-0.1.0/db.agc" in out.read_bytes()
    # An edit in the folder of one package is a hash mismatch for that package only.
    (deps / "postgres" / "db.agc").write_text("# edited\n", encoding="utf-8")
    assert problem_of(ws, remotes)["code"] == "PKG-HASH-MISMATCH"


def test_add_with_subdir_writes_the_key_in_the_manifest_and_the_lock(ws, remotes, tmp_path):
    remotes.publish(REPOSITORY, tree(), tag="sqlite-0.1.0")
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    for name, tag, subdir in [("sqlite", "sqlite-0.1.0", "sqlite"), ("postgres", "sqlite-0.1.0", "postgres")]:
        result = run(cli() + ["add", name, url(remotes), "--subdir", subdir, "--tag", tag], cwd=ws.project,
                     env=environment(ws, remotes))
        assert (result.code, result.stdout) == (0, "added %s@%s (folder %s)\n" % (name, tag, subdir)), result.stderr
    text = (ws.project / "agentica.toml").read_text(encoding="utf-8")
    assert text == ('name = "app"\n\n[dependencies]\nsqlite = %s\npostgres = %s\n' % (
        inline_table(dependency(url(remotes), tag="sqlite-0.1.0", subdir="sqlite")),
        inline_table(dependency(url(remotes), tag="sqlite-0.1.0", subdir="postgres"))))
    commit = remotes.git("rev-parse", "HEAD", cwd=remotes.work / REPOSITORY)
    lock_entry(ws, remotes, REPOSITORY, SQLITE, commit, tag="sqlite-0.1.0", name="sqlite", subdir="sqlite")
    lock_entry(ws, remotes, REPOSITORY, POSTGRES, commit, tag="sqlite-0.1.0", name="postgres", subdir="postgres")
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == ws.lock_text()
    # What `add` wrote is what `install` and a build read, with no git.
    empty = tmp_path / "no-git"
    empty.mkdir()
    assert run_json("install", ws, remotes, PATH=str(empty))[1] is None
    ran = build(ws, remotes, PATH=str(empty))
    assert (ran.code, ran.stdout) == (0, "sqlite postgres\n"), ran.stderr


def test_add_refuses_a_bad_or_repeated_subdir_as_a_usage_error_and_a_missing_folder_as_pkg_fetch(ws, remotes):
    remotes.publish(REPOSITORY, tree(), tag="sqlite-0.1.0")
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    base = ["add", "sqlite", url(remotes), "--tag", "sqlite-0.1.0"]
    for words in ([*base, "--subdir", "../x"], [*base, "--subdir"], [*base, "--subdir", "a", "--subdir", "b"],
                  [*base, "--ref", "a" * 40], ["add", "sqlite", url(remotes), "--subdir", "sqlite"]):
        result = run(cli() + words, cwd=ws.project, env=environment(ws, remotes))
        assert result.code == 2, words
    assert (ws.project / "agentica.toml").read_text(encoding="utf-8") == 'name = "app"\n'
    assert not (ws.project / "agentica.lock").exists()
    result, problem = command(ws, remotes, *base, "--subdir", "nothing")
    assert_at_key(problem, "PKG-FETCH", ws.project / "agentica.toml", "dependencies.sqlite.subdir")
    assert (ws.project / "agentica.toml").read_text(encoding="utf-8") == 'name = "app"\n'
    assert not (ws.project / "agentica.lock").exists()


def test_a_package_can_declare_another_folder_of_its_own_repository(ws, remotes, tmp_path):
    manifest = 'name = "postgres"\n\n[dependencies]\ncommon = %s\n' % inline_table(
        dependency(url(remotes), tag="common-1", subdir="common"))
    files = {"postgres/agentica.toml": manifest,
             "postgres/db.agc": 'import Common from "pkg/common/util"\n\nexport def open() -> String\n'
                                '  return "postgres+" + Common.name()\nend\n',
             "common/util.agc": 'export def name() -> String\n  return "common"\nend\n'}
    remotes.publish(REPOSITORY, files, tag="postgres-0.1.0")
    tag_too(remotes, "common-1")
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    (ws.project / "main.agc").write_text('import Db from "pkg/postgres/db"\n\ndef main() -> Void\n  puts(Db.open())\nend\n',
                                         encoding="utf-8")
    result = run(cli() + ["add", "postgres", url(remotes), "--tag", "postgres-0.1.0", "--subdir", "postgres"],
                 cwd=ws.project, env=environment(ws, remotes))
    # Both are locked, the sibling folder because the package asks for it.
    assert (result.code, result.stdout) == (
        0, "added common@common-1 (folder common)\nadded postgres@postgres-0.1.0 (folder postgres)\n"), result.stderr
    lock = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert lock.count('subdir = "common"') == 1 and lock.count('subdir = "postgres"') == 1
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "postgres+common\n"), ran.stderr
    again = run(cli() + ["update"], cwd=ws.project, env=environment(ws, remotes))
    assert (again.code, again.stdout) == (0, "nothing to update\n"), again.stderr
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == lock
    # `add` wrote both folders to deps/, so the program runs with no cache and no git.
    assert sorted(os.listdir(ws.deps)) == ["common", "postgres"]
    shutil.rmtree(ws.pkg_root)
    empty = tmp_path / "no-git"
    empty.mkdir()
    ran = build(ws, remotes, PATH=str(empty))
    assert (ran.code, ran.stdout) == (0, "postgres+common\n"), ran.stderr


def test_a_symlink_to_a_source_file_inside_the_folder_is_refused_and_a_submodule_below_it_is_not(ws, remotes):
    commit = remotes.publish(REPOSITORY, tree(), tag="sqlite-0.1.0", links={"sqlite/alias.agc": "db.agc"})
    lock_entry(ws, remotes, REPOSITORY, SQLITE, commit, tag="sqlite-0.1.0", name="sqlite", subdir="sqlite")
    ws.write_manifest({"sqlite": dependency(url(remotes), tag="sqlite-0.1.0", subdir="sqlite")})
    ws.write_lock()
    _, problem = run_json("install", ws, remotes)
    assert_at_key(problem, "PKG-SYMLINK", ws.project / "agentica.lock", "package[0]")
    assert not ws.folder(url(remotes), commit, "sqlite").exists()
    # A submodule that is not named like a source file is left out, as in a package that is a whole repository.
    commit = remotes.publish(REPOSITORY, tree(), tag="sqlite-0.1.0", gitlinks=["sqlite/vendor"])
    ws.locked.clear()
    lock_entry(ws, remotes, REPOSITORY, SQLITE, commit, tag="sqlite-0.1.0", name="sqlite", subdir="sqlite")
    ws.write_lock()
    result, problem = run_json("install", ws, remotes)
    assert (result.code, problem) == (0, None), result.stderr
    assert cached_files(ws.folder(url(remotes), commit, "sqlite")) == ["db.agc", "util/text.agc"]


def test_a_commit_pin_with_a_subdir_is_stored_by_the_short_commit_and_update_does_not_move_it(ws, remotes):
    commit = remotes.publish(REPOSITORY, tree(), tag="sqlite-0.1.0")
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    (ws.project / "main.agc").write_text('import Db from "pkg/sqlite/db"\n\ndef main() -> Void\n  puts(Db.open())\nend\n',
                                         encoding="utf-8")
    result = run(cli() + ["add", "sqlite", url(remotes), "--ref", commit, "--subdir", "sqlite"], cwd=ws.project,
                 env=environment(ws, remotes))
    assert (result.code, result.stdout) == (0, "added sqlite@%s (folder sqlite)\n" % commit[:12]), result.stderr
    lock_entry(ws, remotes, REPOSITORY, SQLITE, commit, ref=commit, name="sqlite", subdir="sqlite")
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == ws.lock_text()
    out = ws.base / "ref.agcb"
    assert run(cli() + ["compile", str(ws.project / "main.agc"), "-o", str(out)], cwd=ws.project,
               env=environment(ws, remotes)).code == 0
    assert ("pkg/sqlite@%s/db.agc" % commit[:12]).encode() in out.read_bytes()
    # The folder changes in a later commit; a commit pin stays where it is.
    remotes.publish(REPOSITORY, tree(sqlite={"db.agc": "# new\n"}), tag="sqlite-0.1.0")
    again = run(cli() + ["update"], cwd=ws.project, env=environment(ws, remotes))
    assert (again.code, again.stdout) == (0, "nothing to update\n"), again.stderr
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == ws.lock_text()
