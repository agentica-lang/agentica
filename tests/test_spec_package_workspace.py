"""Local workspaces: a repository of packages whose root agentica.toml has a `[workspace]` table (docs/grammar/05b-modules.md,
issue 573). Inside the repository a dependency on a member of the same repository is read from the member's folder, with
no fetch and no copy in deps/; outside it the same dependency goes through the cache and deps/, and the table is ignored.

The repository of every case is a plain folder (`repo/`); the remote for the cases that fetch is a bare git repository
behind a throwaway HOME (tests/package_support.py, `Remotes`), so nothing touches the network. Cases assert codes and the
file and key path, never message text (AGENTS.md).
"""
import json
import os
import shutil
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run
from tests.package_support import (assert_at_key, cached_files, dependency, environment, git, inline_table,  # noqa: F401
                                    remotes, ws)

pytestmark = host_only(WINDOWS, "the git remote of these cases is a file:// folder, tested on POSIX")

REPOSITORY = "owner/agentica-packages"
TABLE = '[workspace]\nrepository = "%s"\nmembers = ["sqlite", "common"]\n'


def shout(version):
    return 'export def shout() -> String\n  return "common %s"\nend\n' % version


def files_of(remotes, root_manifest=None, sqlite_manifest_extra=""):
    """The files of the repository: a root with the workspace table, `common`, and `sqlite`, which depends on `common`
    as a user outside the repository would write it (git, tag and subdir)."""
    url = remotes.url(REPOSITORY)
    sqlite = 'name = "sqlite"\n\n[dependencies]\ncommon = %s\n%s' % (
        inline_table(dependency(url, tag="common-1", subdir="common")), sqlite_manifest_extra)
    return {
        "agentica.toml": TABLE % url if root_manifest is None else root_manifest,
        "common/agentica.toml": 'name = "common"\n',
        "common/util.agc": shout("v1"),
        "sqlite/agentica.toml": sqlite,
        "sqlite/db.agc": 'import Util from "pkg/common/util"\n\nexport def open() -> String\n'
                         '  return "sqlite+" + Util.shout()\nend\n',
        "sqlite/main.agc": 'import Db from "db"\n\ndef main() -> Void\n  puts(Db.open())\nend\n',
    }


def lay_out(folder, files):
    for relative, text in files.items():
        path = folder / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def at(folder, ws, remotes, *words, **extra):
    """The result of `agentica WORDS` run in `folder`, and the problem of a `--json` run that failed with one."""
    result = run(cli() + list(words), cwd=folder, env=environment(ws, remotes, **extra))
    problem = None
    if result.code == 1 and "--json" in words:
        problem = json.loads(result.stderr)
    return result, problem


def publish_tags(remotes, files, *tags):
    """Publishes the files as the repository and tags that commit with every tag; returns the commit."""
    commit = remotes.publish(REPOSITORY, files, tag=tags[0])
    work = remotes.work / REPOSITORY
    for tag in tags[1:]:
        remotes.git("tag", "-f", tag, cwd=work)
        remotes.git("push", "--quiet", "--force", "origin", "refs/tags/" + tag, cwd=work)
    return commit


def test_a_member_reads_its_sibling_from_the_folder_and_an_edit_there_is_seen_with_no_tag_or_install(
        ws, remotes, tmp_path):
    repo = tmp_path / "repo"
    lay_out(repo, files_of(remotes))
    sqlite = repo / "sqlite"
    # The remote holds nothing and no tag common-1 exists: the dependency can only come from the folder.
    result, problem = at(sqlite, ws, remotes, "--json", "update")
    assert (result.code, problem) == (0, None), result.stderr
    url = remotes.url(REPOSITORY)
    # The lock records the member: its source and pin as the manifest writes them, `workspace = true`, no commit, no hash.
    assert (sqlite / "agentica.lock").read_text(encoding="utf-8") == (
        'version = 1\n\n[[package]]\nname = "common"\ngit = "%s"\nsubdir = "common"\ntag = "common-1"\n'
        'workspace = true\n' % url)
    # `install` fetches nothing and writes no deps/ folder, and a build needs neither git nor a cache.
    no_git = tmp_path / "no-git"
    no_git.mkdir()
    installed, _ = at(sqlite, ws, remotes, "install", PATH=str(no_git))
    assert (installed.code, installed.stdout) == (0, "in the workspace common@workspace\n"), installed.stderr
    assert not (sqlite / "deps").exists() and not ws.pkg_root.exists()
    ran, _ = at(sqlite, ws, remotes, "main.agc", PATH=str(no_git))
    assert (ran.code, ran.stdout) == (0, "sqlite+common v1\n"), ran.stderr
    # An edit in the sibling is the next run, with no tag, no install and no new lock (the bytecode cache sees it too).
    (repo / "common" / "util.agc").write_text(shout("v2"), encoding="utf-8")
    ran, _ = at(sqlite, ws, remotes, "main.agc", PATH=str(no_git))
    assert (ran.code, ran.stdout) == (0, "sqlite+common v2\n"), ran.stderr
    # The root of the workspace is in it too, and a project below a member that is not one is not.
    (repo / "main.agc").write_text('import Db from "pkg/sqlite/db"\n\ndef main() -> Void\n  puts(Db.open())\nend\n',
                                   encoding="utf-8")
    added, problem = at(repo, ws, remotes, "--json", "add", "sqlite", url, "--tag", "sqlite-1", "--subdir", "sqlite")
    assert (added.code, problem) == (0, None), added.stderr
    assert 'name = "sqlite"' in (repo / "agentica.lock").read_text(encoding="utf-8")
    assert not (repo / "deps").exists()
    ran, _ = at(repo, ws, remotes, "main.agc", PATH=str(no_git))
    assert (ran.code, ran.stdout) == (0, "sqlite+common v2\n"), ran.stderr


def test_the_same_member_from_outside_the_repository_goes_through_the_cache_and_deps_and_the_table_is_ignored(
        ws, remotes, tmp_path):
    # The packages carry a `[workspace]` table that no workspace reads: it is not even checked.
    repo = tmp_path / "repo"
    files = files_of(remotes, sqlite_manifest_extra="\n[workspace]\nunknown = 1\n")
    lay_out(repo, files)
    publish_tags(remotes, files, "sqlite-1", "common-1")
    url = remotes.url(REPOSITORY)
    main = 'import Db from "pkg/sqlite/db"\n\ndef main() -> Void\n  puts(Db.open())\nend\n'
    outside = ws.project
    (outside / "main.agc").write_text(main, encoding="utf-8")
    # A project in the repository folder that is not a member (`repo/app`) is outside the workspace as well.
    inside_folder = repo / "app"
    inside_folder.mkdir()
    (inside_folder / "main.agc").write_text(main, encoding="utf-8")
    for project in (outside, inside_folder):
        manifest = '[dependencies]\nsqlite = %s\n' % inline_table(dependency(url, tag="sqlite-1", subdir="sqlite"))
        (project / "agentica.toml").write_text(manifest, encoding="utf-8")
        result, problem = at(project, ws, remotes, "--json", "update")
        assert (result.code, problem) == (0, None), result.stderr
        lock = (project / "agentica.lock").read_text(encoding="utf-8")
        assert "workspace" not in lock and lock.count("commit = ") == 2 and lock.count("hash = ") == 2
        assert sorted(os.listdir(project / "deps")) == ["common", "sqlite"]
        assert cached_files(project / "deps" / "common") == ["agentica.toml", "util.agc"]
        # The edit of the working copy is not seen: the project reads the tagged commit from deps/.
        (repo / "common" / "util.agc").write_text(shout("edited"), encoding="utf-8")
        ran, _ = at(project, ws, remotes, "main.agc")
        assert (ran.code, ran.stdout) == (0, "sqlite+common v1\n"), ran.stderr
        (repo / "common" / "util.agc").write_text(shout("v1"), encoding="utf-8")


@pytest.mark.parametrize("table, key", [
    ('[workspace]\nrepository = "%s"\nmembers = ["sqlite", "common"]\nextra = 1\n', "workspace.extra"),
    ('[workspace]\nrepository = "http://example.test/owner/repo"\nmembers = ["sqlite"]\n', "workspace.repository"),
    ('[workspace]\nrepository = "%s"\n', "workspace.members"),
    ('[workspace]\nrepository = "%s"\nmembers = ["sqlite", "../common"]\n', "workspace.members[1]"),
    ('[workspace]\nrepository = "%s"\nmembers = ["sqlite", "sqlite"]\n', "workspace.members[1]"),
    ('[workspace]\nrepository = "%s"\nmembers = ["sqlite", "ghost"]\n', "workspace.members[1]"),
    ('workspace = 3\n', "workspace"),
], ids=["unknown-key", "http-repository", "no-members", "dot-dot", "twice", "no-manifest", "not-a-table"])
def test_a_bad_workspace_table_is_pkg_manifest_invalid_at_its_key(ws, remotes, tmp_path, table, key):
    repo = tmp_path / "repo"
    lay_out(repo, files_of(remotes, root_manifest=table.replace("%s", remotes.url(REPOSITORY))))
    # A member folder with no manifest is the case "ghost": the folder exists, its agentica.toml does not.
    (repo / "ghost").mkdir()
    (repo / "main.agc").write_text('def main() -> Void\n  puts("x")\nend\n', encoding="utf-8")
    # The project that is the root, or a listed member, reports the table.
    # (When the table does not list sqlite, only the root is in the workspace: see the next test.)
    for folder in (repo, repo / "sqlite") if '"sqlite"' in table else (repo,):
        problem = at(folder, ws, remotes, "--json", "check", "main.agc")[1]
        assert_at_key(problem, "PKG-MANIFEST-INVALID", repo / "agentica.toml", key)


def test_the_lock_must_agree_with_whether_the_dependency_is_a_member(ws, remotes, tmp_path):
    repo = tmp_path / "repo"
    lay_out(repo, files_of(remotes))
    sqlite = repo / "sqlite"
    assert at(sqlite, ws, remotes, "--json", "update")[1] is None
    member_lock = (sqlite / "agentica.lock").read_text(encoding="utf-8")
    # A member with a commit, or a hash, is a bad lock entry.
    for extra, key in (('commit = "%s"\n' % ("a" * 40), "package[0].commit"), ('hash = "sha256:%s"\n' % ("b" * 64),
                                                                              "package[0].hash")):
        (sqlite / "agentica.lock").write_text(member_lock + extra, encoding="utf-8")
        assert_at_key(at(sqlite, ws, remotes, "--json", "check", "main.agc")[1], "PKG-LOCK-INVALID",
                      sqlite / "agentica.lock", key)
    (sqlite / "agentica.lock").write_text(member_lock.replace('subdir = "common"\n', ""), encoding="utf-8")
    assert_at_key(at(sqlite, ws, remotes, "--json", "check", "main.agc")[1], "PKG-LOCK-INVALID",
                  sqlite / "agentica.lock", "package[0].subdir")
    # The same project and lock, copied where no workspace holds it, wants the dependency fetched.
    (sqlite / "agentica.lock").write_text(member_lock, encoding="utf-8")
    away = tmp_path / "away"
    shutil.copytree(sqlite, away, ignore=shutil.ignore_patterns("_build"))
    assert_at_key(at(away, ws, remotes, "--json", "check", "main.agc")[1], "PKG-LOCK-STALE", away / "agentica.toml",
                  "dependencies.common")


@pytest.mark.parametrize("table", ['[workspace]\nrepository = "%s"\nmembers = ["ghost"]\n', "workspace = 5\n"],
                         ids=["ghost-member", "not-a-table"])
def test_a_project_that_a_broken_table_does_not_list_builds_as_if_the_table_were_not_there(
        ws, remotes, tmp_path, table):
    repo = tmp_path / "repo"
    lay_out(repo, {"agentica.toml": table.replace("%s", remotes.url(REPOSITORY)), "app/agentica.toml": 'name = "app"\n',
                   "app/main.agc": 'def main() -> Void\n  puts("app")\nend\n'})
    ran, _ = at(repo / "app", ws, remotes, "main.agc")
    assert (ran.code, ran.stdout) == (0, "app\n"), ran.stderr


def test_a_lock_of_members_alone_needs_no_cache_folder(ws, remotes, tmp_path):
    repo = tmp_path / "repo"
    lay_out(repo, files_of(remotes))
    no_home = {"HOME": None, "XDG_CACHE_HOME": None}
    for words in (["add", "sqlite", remotes.url(REPOSITORY), "--tag", "sqlite-1", "--subdir", "sqlite"],
                  ["update"], ["install"]):
        result, problem = at(repo, ws, remotes, "--json", *words, **no_home)
        assert (result.code, problem) == (0, None), (words, result.stderr)
    assert not (repo / "deps").exists()


def test_a_fetched_package_that_depends_on_a_member_reads_it_from_the_folder(ws, remotes, tmp_path):
    # The package lives in another repository and declares the member as a user outside would: with the tag that
    # the remote does not have. In the workspace of the project the member is the working copy.
    repo = tmp_path / "repo"
    url = remotes.url(REPOSITORY)
    library = {"agentica.toml": 'name = "lib"\n\n[dependencies]\ncommon = %s\n' % inline_table(
                   dependency(url, tag="common-1", subdir="common")),
               "x.agc": 'import Util from "pkg/common/util"\n\nexport def go() -> String\n'
                        '  return "lib+" + Util.shout()\nend\n'}
    remotes.publish("other/lib", library, tag="v1")
    files = files_of(remotes)
    files["agentica.toml"] += '\n[dependencies]\nlib = %s\n' % inline_table(
        dependency(remotes.url("other/lib"), tag="v1"))
    files["main.agc"] = 'import Lib from "pkg/lib/x"\n\ndef main() -> Void\n  puts(Lib.go())\nend\n'
    lay_out(repo, files)
    result, problem = at(repo, ws, remotes, "--json", "update")
    assert (result.code, problem) == (0, None), result.stderr
    lock = (repo / "agentica.lock").read_text(encoding="utf-8")
    assert lock.count("workspace = true") == 1 and lock.count("commit = ") == 1
    assert sorted(os.listdir(repo / "deps")) == ["lib"]
    ran, _ = at(repo, ws, remotes, "main.agc")
    assert (ran.code, ran.stdout) == (0, "lib+common v1\n"), ran.stderr
    (repo / "common" / "util.agc").write_text(shout("v2"), encoding="utf-8")
    ran, _ = at(repo, ws, remotes, "main.agc")
    assert (ran.code, ran.stdout) == (0, "lib+common v2\n"), ran.stderr


def test_a_name_that_becomes_a_member_loses_its_deps_folder_and_install_removes_a_stale_one(ws, remotes, tmp_path):
    repo = tmp_path / "repo"
    files = files_of(remotes, root_manifest='name = "root"\n')
    lay_out(repo, files)
    publish_tags(remotes, files, "sqlite-1", "common-1")
    sqlite = repo / "sqlite"
    # With no [workspace] table, common is fetched and written to deps/.
    assert at(sqlite, ws, remotes, "--json", "update")[1] is None
    assert (sqlite / "deps" / "common" / "util.agc").is_file()
    # The table appears: update locks common as a member and removes the folder of deps/.
    (repo / "agentica.toml").write_text(TABLE % remotes.url(REPOSITORY), encoding="utf-8")
    result, _ = at(sqlite, ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "updated common@workspace (folder common)\n"), result.stderr
    assert "workspace = true" in (sqlite / "agentica.lock").read_text(encoding="utf-8")
    assert not (sqlite / "deps" / "common").exists()
    # A folder that comes back (a checkout of an old deps/, say) is removed by install as well.
    (sqlite / "deps" / "common").mkdir()
    (sqlite / "deps" / "common" / "old.agc").write_text("# old\n", encoding="utf-8")
    assert at(sqlite, ws, remotes, "--json", "install")[1] is None
    assert not (sqlite / "deps" / "common").exists()
