"""Namespaced packages and workspace dependencies (docs/grammar/05b-modules.md, issue 1850).

A dependency with `workspace = true` is a whole workspace repository under one name: the lock has the entry `finn` and
one entry `finn/folder` for each member, deps/ keeps the members in `deps/finn/folder/`, and an import is
`pkg/finn/folder/module`. A dependency of a member on a folder of its own workspace is that member, whatever pin it
writes, so the names of the members stay out of the flat space of the project.

The remote of every case is a bare git repository behind a throwaway HOME (tests/package_support.py, `Remotes`), so
nothing touches the network. Cases assert codes and the file and key path, never message text (AGENTS.md).
"""
import json
import os
import shutil
import stat
import tomllib
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, run
from tests.package_support import (assert_at_key, build, cached_files, dependency, environment, git,  # noqa: F401
                                    inline_table, package_hash, problem_of, remotes, run_json, ws)


REPOSITORY = "owner/finn"
OTHER = "owner/other"
MINE = "owner/mine"
TAG = "finn-1"


def url(remotes):
    return remotes.url(REPOSITORY)


def member_files(remotes):
    """The files of the repository: a root with the workspace table and three members. `core` depends on `protocol`
    and `llm`, as a user outside the repository writes it, with the pin of a tag that the repository does not have, and
    on `other`, a package of another repository; `llm` depends on `protocol` too."""
    here = url(remotes)
    siblings = {name: dependency(here, tag="finn-0", subdir=name) for name in ("protocol", "llm")}
    core = {**siblings, "other": dependency(remotes.url(OTHER), tag="v1")}
    return {
        "agentica.toml": 'name = "finn"\n\n[workspace]\nrepository = "%s"\nmembers = ["core", "protocol", "llm"]\n' % here,
        "core/agentica.toml": 'name = "core"\n\n[dependencies]\n'
                              + "".join("%s = %s\n" % (name, inline_table(entry)) for name, entry in core.items()),
        "core/core.agc": ('import Protocol from "pkg/protocol/protocol"\nimport Llm from "pkg/llm/llm"\n'
                          'import Other from "pkg/other/other"\n\n'
                          'def describe() -> String\n  return "core " + Protocol.name() + " " + Llm.name() + " "'
                          ' + Other.name()\nend\n'),
        "protocol/agentica.toml": 'name = "protocol"\n',
        "protocol/protocol.agc": 'def name() -> String\n  return "finn-protocol"\nend\n',
        "llm/agentica.toml": 'name = "llm"\n\n[dependencies]\nprotocol = %s\n' % inline_table(siblings["protocol"]),
        "llm/llm.agc": ('import Protocol from "pkg/protocol/protocol"\n\n'
                        'def name() -> String\n  return "llm+" + Protocol.name()\nend\n'),
        "llm/util/text.agc": "# text\n",
    }


def publish(remotes, files=None, tag=TAG):
    commit = remotes.publish(REPOSITORY, member_files(remotes) if files is None else files, tag=tag)
    remotes.publish(OTHER, {"other.agc": 'def name() -> String\n  return "other"\nend\n'}, tag="v1")
    remotes.publish(MINE, {"mine.agc": 'def name() -> String\n  return "my protocol"\nend\n'}, tag="v1")
    return commit


# The app's own `protocol` is a package of another repository: the name that the members use inside `finn` stays free.
MAIN = ('import Core from "pkg/finn/core/core"\nimport Protocol from "pkg/protocol/mine"\n\n'
        'def main() -> Void\n  puts(Core.describe())\n  puts(Protocol.name())\nend\n')


def project(ws, remotes, workspace=True, extra=""):
    """A project that depends on the workspace `finn` and on its own `protocol`."""
    flag = ", workspace = true" if workspace else ""
    text = 'name = "app"\n\n[dependencies]\nfinn = { git = "%s", tag = "%s"%s }\nprotocol = %s\n' % (
        url(remotes), TAG, flag, inline_table(dependency(remotes.url(MINE), tag="v1")))
    (ws.project / "agentica.toml").write_text(text + extra, encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def lock_of(ws):
    return tomllib.loads((ws.project / "agentica.lock").read_text(encoding="utf-8"))["package"]


def update(ws, remotes, *words, **extra):
    return run(cli() + ["update", *words], cwd=ws.project, env=environment(ws, remotes, **extra))


def locked(ws, remotes, edit=None):
    """A project and the lock that `update` wrote for it, which `edit` may change as a list of entries."""
    publish(remotes)
    project(ws, remotes)
    assert update(ws, remotes).code == 0
    if edit:
        entries = lock_of(ws)
        edit(entries)
        text = "version = 1\n"
        for entry in entries:
            text += "\n[[package]]\n" + "".join('%s = "%s"\n' % pair for pair in entry.items())
        (ws.project / "agentica.lock").write_text(text, encoding="utf-8")


def git_logger(base):
    """A PATH whose `git` writes each command line to a file and then runs the real one (POSIX), and that file."""
    folder = Path(base) / "git-logger"
    folder.mkdir()
    log = folder / "log"
    script = folder / "git"
    script.write_text('#!/bin/sh\necho "$@" >> "%s"\nexec "%s" "$@"\n' % (log, shutil.which("git")), encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return folder.as_posix() + os.pathsep + os.environ["PATH"], log


def fetches(log):
    lines = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    return [line for line in lines if " fetch " in line]


def test_update_locks_a_workspace_dependency_as_one_entry_and_one_for_each_member_and_the_project_builds(ws, remotes):
    commit = publish(remotes)
    project(ws, remotes)
    result = update(ws, remotes)
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [
        "added finn@finn-1", "added finn/core@finn-1 (folder core)", "added finn/llm@finn-1 (folder llm)",
        "added finn/protocol@finn-1 (folder protocol)", "added other@v1", "added protocol@v1"]

    packages = {entry["name"]: entry for entry in lock_of(ws)}
    assert sorted(packages) == ["finn", "finn/core", "finn/llm", "finn/protocol", "other", "protocol"]
    assert packages["finn"] == {"name": "finn", "git": url(remotes), "tag": TAG, "commit": commit,
                                "repository": url(remotes)}
    for folder in ("core", "llm", "protocol"):
        member = packages["finn/" + folder]
        assert (member["git"], member["subdir"], member["tag"], member["commit"]) == (url(remotes), folder, TAG, commit)
        assert member["hash"] == package_hash(ws.deps / "finn" / folder)
        assert "repository" not in member
    # The pin that a member writes for a sibling (finn-0) is ignored: the members have the pin of the workspace.
    assert "finn-0" not in (ws.project / "agentica.lock").read_text(encoding="utf-8")

    assert sorted(os.listdir(ws.deps)) == ["finn", "other", "protocol"]
    assert sorted(os.listdir(ws.deps / "finn")) == ["core", "llm", "protocol"]
    assert cached_files(ws.deps / "finn" / "llm") == ["agentica.toml", "llm.agc", "util/text.agc"]
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "core finn-protocol llm+finn-protocol other\nmy protocol\n"), ran.stderr
    assert problem_of(ws, remotes) is None


@pytest.mark.skipif(WINDOWS, reason="the git wrapper is a shell script")
def test_update_and_install_fetch_the_workspace_once_and_update_of_another_name_keeps_it(ws, remotes, tmp_path):
    publish(remotes)
    project(ws, remotes)
    path, log = git_logger(tmp_path)
    assert update(ws, remotes, PATH=path).code == 0
    # One fetch for finn (its root manifest and every member), one for `other` and one for `protocol`.
    assert len(fetches(log)) == 3
    lock = (ws.project / "agentica.lock").read_text(encoding="utf-8")

    # `update protocol` fetches that pin again and keeps the workspace as locked, with no fetch for it.
    log.unlink()
    assert update(ws, remotes, "protocol", PATH=path).stdout == "nothing to update\n"
    assert len(fetches(log)) == 1
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == lock

    # A cold cache and an empty deps/: install fetches the group once.
    shutil.rmtree(ws.pkg_root)
    shutil.rmtree(ws.deps)
    log.unlink()
    result = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes, PATH=path))
    assert (result.code, result.stdout.splitlines()) == (0, [
        "fetched finn/core@finn-1", "fetched finn/llm@finn-1", "fetched finn/protocol@finn-1", "fetched other@v1",
        "fetched protocol@v1"]), result.stderr
    assert len(fetches(log)) == 3
    assert build(ws, remotes).code == 0


def test_a_member_in_a_folder_below_the_root_is_installed_in_the_same_folders(ws, remotes):
    files = member_files(remotes)
    files["agentica.toml"] = files["agentica.toml"].replace('"llm"]', '"llm", "examples/extension"]')
    files["examples/extension/agentica.toml"] = 'name = "extension"\n'
    files["examples/extension/main.agc"] = 'def name() -> String\n  return "extension"\nend\n'
    publish(remotes, files)
    project(ws, remotes)
    (ws.project / "main.agc").write_text(
        'import Extension from "pkg/finn/examples/extension/main"\n\ndef main() -> Void\n  puts(Extension.name())\nend\n',
        encoding="utf-8")
    assert update(ws, remotes).code == 0
    assert cached_files(ws.deps / "finn" / "examples" / "extension") == ["agentica.toml", "main.agc"]
    assert "finn/examples/extension" in [entry["name"] for entry in lock_of(ws)]
    shutil.rmtree(ws.deps)
    assert run_json("install", ws, remotes)[1] is None
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "extension\n"), ran.stderr


def test_update_gives_back_the_lock_it_wrote_and_install_reads_it(ws, remotes):
    locked(ws, remotes)
    lock = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    again = update(ws, remotes)
    assert (again.code, again.stdout) == (0, "nothing to update\n"), again.stderr
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == lock
    shutil.rmtree(ws.deps)
    assert run_json("install", ws, remotes)[1] is None
    assert sorted(os.listdir(ws.deps / "finn")) == ["core", "llm", "protocol"]


def test_a_moved_tag_is_taken_by_update_for_the_workspace_and_every_member(ws, remotes):
    first = publish(remotes)
    project(ws, remotes)
    assert update(ws, remotes).code == 0
    files = member_files(remotes)
    files["protocol/protocol.agc"] = 'def name() -> String\n  return "finn-protocol-2"\nend\n'
    second = remotes.publish(REPOSITORY, files, tag=TAG)
    assert second != first
    result = update(ws, remotes, "finn")
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [
        "updated finn@finn-1", "updated finn/core@finn-1 (folder core)", "updated finn/llm@finn-1 (folder llm)",
        "updated finn/protocol@finn-1 (folder protocol)"]
    assert {entry["commit"] for entry in lock_of(ws) if entry["name"].startswith("finn")} == {second}
    ran = build(ws, remotes)
    assert ran.stdout.splitlines()[0] == "core finn-protocol-2 llm+finn-protocol-2 other", ran.stderr


def test_the_workspace_and_a_folder_of_the_same_repository_are_two_packages_that_share_the_cache(ws, remotes):
    commit = publish(remotes)
    project(ws, remotes, extra="proto = %s\n" % inline_table(dependency(url(remotes), tag=TAG, subdir="protocol")))
    assert update(ws, remotes).code == 0
    packages = {entry["name"]: entry for entry in lock_of(ws)}
    assert packages["proto"]["subdir"] == "protocol"
    assert packages["proto"]["hash"] == packages["finn/protocol"]["hash"]
    assert cached_files(ws.deps / "proto") == cached_files(ws.deps / "finn" / "protocol")
    assert sorted(os.listdir(ws.folder(url(remotes), commit).parent)) == [
        commit + "@core", commit + "@llm", commit + "@protocol"]
    assert build(ws, remotes).code == 0


@pytest.mark.parametrize("files, code_key", [
    (lambda remotes: {"core/agentica.toml": 'name = "core"\n', "core/core.agc": "# core\n"}, "workspace"),
    (lambda remotes: {"agentica.toml": 'name = "finn"\n', "core/agentica.toml": 'name = "core"\n'}, "workspace"),
    (lambda remotes: {"agentica.toml": '[workspace]\nrepository = "%s"\nmembers = []\n' % url(remotes)}, "workspace"),
    (lambda remotes: {"agentica.toml": '[workspace]\nrepository = "%s"\nmembers = ["nope"]\n' % url(remotes)},
     "workspace"),
    (lambda remotes: {"agentica.toml": '[workspace]\nrepository = "ssh://x"\nmembers = ["core"]\n',
                      "core/agentica.toml": ""}, "workspace"),
    (lambda remotes: {"agentica.toml": "name = [\n"}, "workspace"),
    (lambda remotes: {"agentica.toml": '[workspace]\nrepository = "%s"\nmembers = ["core", "core/inner"]\n' % url(remotes),
                      "core/agentica.toml": "", "core/inner/agentica.toml": ""}, "workspace"),
], ids=["no-root-manifest", "no-table", "no-members", "member-missing", "bad-repository", "not-toml",
        "member-in-member"])
def test_a_repository_that_is_not_a_good_workspace_is_pkg_fetch_at_the_workspace_key(ws, remotes, files, code_key):
    remotes.publish(REPOSITORY, files(remotes), tag=TAG)
    project(ws, remotes)
    result = run(cli() + ["--json", "update", "finn"], cwd=ws.project, env=environment(ws, remotes))
    assert result.code == 1, result.stdout
    assert_at_key(json.loads(result.stderr), "PKG-FETCH", ws.project / "agentica.toml", "dependencies.finn." + code_key)
    assert not (ws.project / "agentica.lock").exists()


@pytest.mark.parametrize("entry", [
    '{ git = "URL", tag = "finn-1", workspace = true, subdir = "core" }',
    '{ path = "../finn", workspace = true }',
    '{ git = "URL", tag = "finn-1", workspace = "yes" }',
], ids=["subdir", "path", "not-a-bool"])
def test_a_workspace_dependency_is_the_whole_repository_and_a_flag(ws, remotes, entry):
    (ws.project / "agentica.toml").write_text("[dependencies]\nfinn = %s\n" % entry.replace("URL", url(remotes)),
                                              encoding="utf-8")
    (ws.project / "main.agc").write_text("def main() -> Void\n  puts(1)\nend\n", encoding="utf-8")
    assert_at_key(problem_of(ws, remotes), "PKG-MANIFEST-INVALID", ws.project / "agentica.toml",
                  "dependencies.finn.workspace")


def test_the_lock_and_the_manifest_must_agree_on_the_workspace(ws, remotes):
    locked(ws, remotes)
    # The manifest says package, the lock says workspace.
    project(ws, remotes, workspace=False)
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.finn")
    # And the other way round: the lock has `finn` as one package.

    def flat(entries):
        entries[:] = [entry for entry in entries if not entry["name"].startswith("finn/")]
        entries[0].pop("repository")
        entries[0]["hash"] = "sha256:" + "0" * 64

    locked(ws, remotes, edit=flat)
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.finn")


def test_an_import_of_a_workspace_names_a_member_and_a_module_of_it(ws, remotes):
    locked(ws, remotes)
    for imported, code in (("pkg/finn/nothing/x", "CHECK-IMPORT-PACKAGE"), ("pkg/finn/core", "CHECK-IMPORT-PATH"),
                           ("pkg/finn", "CHECK-IMPORT-PATH"), ("pkg/finn/core/absent", "CHECK-IMPORT-IO")):
        (ws.project / "main.agc").write_text('import X from "%s"\n\ndef main() -> Void\n  puts(1)\nend\n' % imported,
                                             encoding="utf-8")
        assert problem_of(ws, remotes)["code"] == code, imported


def test_a_member_imports_only_the_packages_its_manifest_declares(ws, remotes):
    files = member_files(remotes)
    # `protocol` declares nothing, so `llm`, a member of the same workspace, is not a name it may use.
    files["protocol/protocol.agc"] = 'import Llm from "pkg/llm/llm"\n\ndef name() -> String\n  return "x"\nend\n'
    publish(remotes, files)
    project(ws, remotes)
    assert update(ws, remotes).code == 0
    assert problem_of(ws, remotes)["code"] == "CHECK-IMPORT-PACKAGE"


def test_an_edited_member_is_written_again_a_stray_file_beside_it_stays_and_a_dropped_workspace_goes_whole(ws, remotes):
    locked(ws, remotes)
    protocol = ws.deps / "finn" / "protocol" / "protocol.agc"
    original = protocol.read_text(encoding="utf-8")
    protocol.write_text("# edited\n", encoding="utf-8")
    (ws.deps / "finn" / "note.txt").write_text("mine", encoding="utf-8")
    assert run_json("install", ws, remotes)[1] is None
    assert protocol.read_text(encoding="utf-8") == original
    assert (ws.deps / "finn" / "note.txt").read_text(encoding="utf-8") == "mine"
    # A project that drops the workspace loses its folder in deps/ as a dropped package does, a stray file with it.
    (ws.project / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nprotocol = %s\n' % inline_table(dependency(remotes.url(MINE), tag="v1")),
        encoding="utf-8")
    (ws.project / "main.agc").write_text('import Protocol from "pkg/protocol/mine"\n\ndef main() -> Void\n'
                                         '  puts(Protocol.name())\nend\n', encoding="utf-8")
    result = update(ws, remotes)
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == ["removed finn", "removed finn/core", "removed finn/llm",
                                          "removed finn/protocol", "removed other"]
    assert sorted(os.listdir(ws.deps)) == ["protocol"]


@pytest.mark.skipif(WINDOWS, reason="symbolic links need a privilege on Windows")
def test_install_does_not_write_through_a_link_in_the_place_of_the_namespace_folder(ws, remotes, tmp_path):
    locked(ws, remotes)
    shutil.rmtree(ws.deps / "finn")
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, ws.deps / "finn")
    _, problem = run_json("install", ws, remotes)
    assert_at_key(problem, "PKG-SYMLINK", ws.deps / "finn", "")
    assert os.listdir(outside) == []


@pytest.mark.parametrize("edit, index", [
    (lambda entries: entries[1].update(name="finn/llm"), 1),
    (lambda entries: entries[1].update(name="Finn/core"), 1),
    (lambda entries: entries[1].update(name="finn/"), 1),
    (lambda entries: entries[1].update(name="finn/../core"), 1),
    (lambda entries: entries[1].pop("subdir"), 1),
    (lambda entries: entries[1].update(commit="b" * 40), 1),
    (lambda entries: entries[1].update(git="https://example.test/owner/else"), 1),
    (lambda entries: entries[1].update(tag="finn-2"), 1),
    (lambda entries: entries.pop(0), 0),
    (lambda entries: (entries[0].pop("repository"), entries[0].update(hash=entries[1]["hash"])), 0),
], ids=["another-subdir", "bad-namespace", "empty-subdir", "dot-dot", "no-subdir", "other-commit", "other-git",
        "other-pin", "no-workspace-entry", "namespace-is-a-package"])
def test_a_namespaced_name_must_be_the_namespace_and_the_subdir_of_an_entry_of_its_workspace(ws, remotes, edit, index):
    locked(ws, remotes, edit=edit)
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-INVALID", ws.project / "agentica.lock",
                  "package[%d].name" % index)


@pytest.mark.parametrize("edit, key", [
    (lambda entry: entry.update(repository="ssh://x"), "repository"),
    (lambda entry: entry.update(hash="sha256:" + "0" * 64), "hash"),
    (lambda entry: entry.update(subdir="core"), "subdir"),
    (lambda entry: entry.pop("commit"), "commit"),
    (lambda entry: entry.update(commit="b" * 7), "commit"),
])
def test_a_workspace_entry_has_a_commit_and_a_repository_and_no_hash_and_no_subdir(ws, remotes, edit, key):
    locked(ws, remotes, edit=lambda entries: edit(entries[0]))
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-INVALID", ws.project / "agentica.lock", "package[0]." + key)


def test_a_native_artifact_may_belong_to_a_namespaced_package(ws, remotes):
    locked(ws, remotes)
    lock = ws.project / "agentica.lock"
    text = lock.read_text(encoding="utf-8") + (
        '\n[[native-artifact]]\npackage = "finn/core"\nlibrary = "bash"\nsystem = "linux"\n'
        'url = "https://example.test/bash.so"\nsha256 = "%s"\nmember = "bash.so"\n' % ("a" * 64))
    lock.write_text(text, encoding="utf-8")
    assert problem_of(ws, remotes) is None
    lock.write_text(text.replace('package = "finn/core"', 'package = "Finn/core"'), encoding="utf-8")
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-INVALID", lock, "native-artifact[0].package")
