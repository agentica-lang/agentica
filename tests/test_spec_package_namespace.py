"""Namespaced packages: a lock name `namespace/subdir` for a folder of a repository, kept in `deps/namespace/subdir/`
(docs/grammar/05b-modules.md, issue 1850).

The remote of every case is a bare git repository behind a throwaway HOME (tests/package_support.py, `Remotes`), so
nothing touches the network. Cases assert codes and the file and key path, never message text (AGENTS.md).
"""
import os
import shutil
import stat
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, run
from tests.package_support import (assert_at_key, build, cached_files, dependency, environment,  # noqa: F401
                                    git, lock_entry, package_hash, problem_of, remotes, run_json, ws)


REPOSITORY = "owner/finn"
TAG = "finn-1"
CORE = {"core.agc": 'def name() -> String\n  return "core"\nend\n'}
LLM = {"llm.agc": 'def name() -> String\n  return "llm"\nend\n', "util/text.agc": "# text\n"}
TOOLS = {"tools.agc": 'def name() -> String\n  return "tools"\nend\n'}
MAIN = 'import Tools from "pkg/tools/tools"\n\ndef main() -> Void\n  puts(Tools.name())\nend\n'


def url(remotes):
    return remotes.url(REPOSITORY)


def project(ws, remotes):
    """A repository of three folders at one commit. The project depends on `tools`, and its lock also has `core` and `llm`
    as the namespaced packages `finn/core` and `finn/llm`, which nothing in the manifest asks for."""
    files = {"core/" + path: text for path, text in CORE.items()}
    files.update({"llm/" + path: text for path, text in LLM.items()})
    files.update({"tools/" + path: text for path, text in TOOLS.items()})
    commit = remotes.publish(REPOSITORY, files, tag=TAG)
    lock_entry(ws, remotes, REPOSITORY, CORE, commit, tag=TAG, name="finn/core", subdir="core")
    lock_entry(ws, remotes, REPOSITORY, LLM, commit, tag=TAG, name="finn/llm", subdir="llm")
    lock_entry(ws, remotes, REPOSITORY, TOOLS, commit, tag=TAG, name="tools", subdir="tools")
    ws.write_manifest({"tools": dependency(url(remotes), tag=TAG, subdir="tools")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    return commit


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


def test_install_writes_a_namespaced_package_in_a_folder_of_its_namespace_and_fetches_the_repository_once(
        ws, remotes, tmp_path):
    commit = project(ws, remotes)
    result = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes))
    assert (result.code, result.stdout) == (
        0, "fetched finn/core@finn-1\nfetched finn/llm@finn-1\nfetched tools@finn-1\n"), result.stderr
    assert cached_files(ws.deps / "finn" / "core") == ["core.agc"]
    assert cached_files(ws.deps / "finn" / "llm") == ["llm.agc", "util/text.agc"]
    assert package_hash(ws.deps / "finn" / "llm") == ws.locked[1]["hash"]
    assert sorted(os.listdir(ws.deps)) == ["finn", "tools"]
    # One cache folder for each folder of the commit, and no temporary folder left.
    assert sorted(os.listdir(ws.folder(url(remotes), commit).parent)) == [
        commit + "@core", commit + "@llm", commit + "@tools"]
    assert not [name for name in os.listdir(ws.pkg_root) if name.startswith(".")]
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "tools\n"), ran.stderr


@pytest.mark.skipif(WINDOWS, reason="the git wrapper is a shell script")
def test_packages_of_one_repository_pin_and_commit_are_fetched_with_one_git_fetch(ws, remotes, tmp_path):
    project(ws, remotes)
    path, log = git_logger(tmp_path)
    result = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes, PATH=path))
    assert result.code == 0, result.stderr
    assert len(fetches(log)) == 1
    # Everything is in the cache now: a second install starts no git fetch.
    log.unlink()
    again = run(cli() + ["install"], cwd=ws.project, env=environment(ws, remotes, PATH=path))
    assert (again.code, again.stdout) == (
        0, "in the cache finn/core@finn-1\nin the cache finn/llm@finn-1\nin the cache tools@finn-1\n"), again.stderr
    assert fetches(log) == []


def test_update_drops_a_namespaced_package_that_nothing_asks_for_and_its_empty_namespace_folder(ws, remotes):
    project(ws, remotes)
    assert run_json("install", ws, remotes)[1] is None
    result = run(cli() + ["update"], cwd=ws.project, env=environment(ws, remotes))
    assert (result.code, result.stdout) == (0, "removed finn/core\nremoved finn/llm\n"), result.stderr
    assert sorted(os.listdir(ws.deps)) == ["tools"]
    assert 'name = "finn/' not in (ws.project / "agentica.lock").read_text(encoding="utf-8")


def test_a_namespaced_package_that_is_edited_in_deps_is_written_again_and_a_stray_file_beside_it_stays(ws, remotes):
    project(ws, remotes)
    assert run_json("install", ws, remotes)[1] is None
    (ws.deps / "finn" / "core" / "core.agc").write_text("# edited\n", encoding="utf-8")
    (ws.deps / "finn" / "note.txt").write_text("mine", encoding="utf-8")
    assert run_json("install", ws, remotes)[1] is None
    assert (ws.deps / "finn" / "core" / "core.agc").read_text(encoding="utf-8") == CORE["core.agc"]
    assert (ws.deps / "finn" / "note.txt").read_text(encoding="utf-8") == "mine"
    # The folder of the namespace is not removed while it holds something else.
    assert run_json("update", ws, remotes)[1] is None
    assert sorted(os.listdir(ws.deps / "finn")) == ["note.txt"]


@pytest.mark.skipif(WINDOWS, reason="symbolic links need a privilege on Windows")
def test_install_does_not_write_through_a_link_in_the_place_of_the_namespace_folder(ws, remotes, tmp_path):
    project(ws, remotes)
    outside = tmp_path / "outside"
    outside.mkdir()
    ws.deps.mkdir()
    os.symlink(outside, ws.deps / "finn")
    _, problem = run_json("install", ws, remotes)
    assert_at_key(problem, "PKG-SYMLINK", ws.deps / "finn", "")
    assert os.listdir(outside) == []


@pytest.mark.parametrize("edit, key", [
    (lambda entry: entry.update(name="finn/llm"), "name"),
    (lambda entry: entry.update(name="Finn/core"), "name"),
    (lambda entry: entry.update(name="finn/"), "name"),
    (lambda entry: entry.update(name="finn/../core"), "name"),
    (lambda entry: entry.update(name="finn/core/"), "name"),
    (lambda entry: entry.pop("subdir"), "name"),
    (lambda entry: entry.update(workspace=True) or entry.pop("commit") or entry.pop("hash"), "name"),
], ids=["another-subdir", "bad-namespace", "empty-subdir", "dot-dot", "final-slash", "no-subdir", "member"])
def test_a_namespaced_name_must_be_the_namespace_and_the_subdir_of_a_fetched_entry(ws, remotes, edit, key):
    project(ws, remotes)
    ws.write_lock(lambda entries: edit(entries[0]))
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-INVALID", ws.project / "agentica.lock", "package[0]." + key)


def test_a_namespace_is_not_the_name_of_a_package(ws, remotes):
    project(ws, remotes)
    ws.write_lock(lambda entries: entries.append(dict(entries[2], name="finn")))
    problem = problem_of(ws, remotes)
    assert_at_key(problem, "PKG-LOCK-INVALID", ws.project / "agentica.lock", "package[3].name")


def test_a_native_artifact_may_belong_to_a_namespaced_package(ws, remotes):
    project(ws, remotes)
    text = ws.lock_text() + (
        '\n[[native-artifact]]\npackage = "finn/core"\nlibrary = "bash"\nsystem = "linux"\n'
        'url = "https://example.test/bash.so"\nsha256 = "%s"\nmember = "bash.so"\n' % ("a" * 64))
    (ws.project / "agentica.lock").write_text(text, encoding="utf-8")
    # The lock is read in full before the import of `tools` finds deps/ empty.
    assert problem_of(ws, remotes)["code"] == "CHECK-IMPORT-PACKAGE"
    bad = text.replace('package = "finn/core"', 'package = "Finn/core"')
    (ws.project / "agentica.lock").write_text(bad, encoding="utf-8")
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-INVALID", ws.project / "agentica.lock",
                  "native-artifact[0].package")
