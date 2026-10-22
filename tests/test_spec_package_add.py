"""`agentica add` and `agentica update`: the lock writer and the manifest writer (docs/future/45-packages.md, 45c).

The remote of every case is a bare git repository in a temporary folder behind a throwaway HOME (tests/package_support.py,
`Remotes`), so nothing touches the network. The lock the commands write is compared byte for byte with the one the Python
writer of `Workspace.lock_text` makes, and the manifest with the text the case expects: these are the round trips of the
writers with the readers (`install` and a build read back what was written). Cases assert codes and the file and key
path, never message text (AGENTS.md).
"""
import os

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run
from tests.package_support import (BANG, GREET, MAIN, assert_at_key, command, dependency, environment,  # noqa: F401
                                    git, inline_table, lock_entry, remotes, ws)

pytestmark = host_only(WINDOWS, "the git remote of these cases is a file:// folder, tested on POSIX")

GREETER = "owner/greeter"
TOOLS = "owner/tools"
GREETER_FILES = {"greet.agc": GREET, "agentica.toml": None}
TOOLS_FILES = {"bang.agc": BANG}


def plain(ws, remotes, *words, **extra):
    return run(cli() + list(words), cwd=ws.project, env=environment(ws, remotes, **extra))


def tools_manifest(remotes, tag="v1"):
    return 'name = "greeter"\n\n[dependencies]\ntools = %s\n' % inline_table(dependency(remotes.url(TOOLS), tag=tag))


def publish_greeter(remotes, manifest=None, tag="v1.0.0", extra=""):
    """greeter, which imports tools (its manifest asks for tools at v1 unless `manifest` says otherwise)."""
    files = {"greet.agc": GREET + extra, "agentica.toml": tools_manifest(remotes) if manifest is None else manifest}
    return files, remotes.publish(GREETER, files, tag=tag)


def line(remotes, path=GREETER, **pin):
    """The line `add` writes for a dependency: its local name is the last part of the path."""
    return "%s = %s\n" % (path.split("/")[1], inline_table(dependency(remotes.url(path), **pin)))


def lock_of(ws, *entries):
    """The text the Python writer makes of these lock entries."""
    ws.locked = list(entries)
    return ws.lock_text()


def add_greeter_and_tools(ws, remotes):
    """`add greeter`, which brings tools along: both are added."""
    result = plain(ws, remotes, "add", "greeter", remotes.url(GREETER), "--tag", "v1.0.0")
    assert (result.code, result.stdout) == (0, "added greeter@v1.0.0\nadded tools@v1\n"), result.stderr


def read(ws, name):
    return (ws.project / name).read_bytes().decode("utf-8")


def test_add_writes_the_manifest_and_the_lock_with_the_dependencies_of_the_package_and_a_program_runs(ws, remotes, tmp_path):
    tools_commit = remotes.publish(TOOLS, TOOLS_FILES, tag="v1", annotated=False)
    files, greeter_commit = publish_greeter(remotes)
    before = '# The app.\nname = "app"\n\n[style]\nmax_line_width = 119  # the longest line\n'
    (ws.project / "agentica.toml").write_text(before, encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")

    add_greeter_and_tools(ws, remotes)

    # The manifest is the old text and one new table; the lock has the dependency of the package too, in the layout of 05b.
    assert read(ws, "agentica.toml") == before + "\n[dependencies]\n" + line(remotes, tag="v1.0.0")
    expected = lock_of(ws, lock_entry(ws, remotes, GREETER, files, greeter_commit, tag="v1.0.0"),
                       lock_entry(ws, remotes, TOOLS, TOOLS_FILES, tools_commit, tag="v1"))
    assert read(ws, "agentica.lock") == expected
    assert not [path for path in ws.pkg_root.iterdir() if path.name.startswith(".")]

    # What was written is what a build and `install` read: the program runs from the cache with no git on PATH.
    empty = tmp_path / "no-git"
    empty.mkdir()
    ran = plain(ws, remotes, str(ws.project / "main.agc"), PATH=str(empty))
    assert (ran.code, ran.stdout) == (0, "hello!\n"), ran.stderr
    installed = plain(ws, remotes, "install", PATH=str(empty))
    assert (installed.stdout) == "in the cache greeter@v1.0.0\nin the cache tools@v1\n", installed.stderr


@pytest.mark.parametrize("before, middle, after", [
    ("", "", "[dependencies]\n{line}"),
    ('name = "app"', "", 'name = "app"\n\n[dependencies]\n{line}'),
    ('name = "app"\n\n\n', "", 'name = "app"\n\n\n[dependencies]\n{line}'),
    ('name = "app"\r\n\r\n[dependencies]\r\n', "", 'name = "app"\r\n\r\n[dependencies]\r\n{line_crlf}'),
    ('name = "app"\n\n[dependencies]  # none yet\n\n# the style\n[style]\nmax_line_width = 100\n', "",
     'name = "app"\n\n[dependencies]  # none yet\n{line}\n# the style\n[style]\nmax_line_width = 100\n'),
    ('[dependencies]\n# the helpers\ntools = {tools}  # pinned\n\n# the style\n[style]\nmax_line_width = 100\n', "",
     '[dependencies]\n# the helpers\ntools = {tools}  # pinned\n{line}\n# the style\n[style]\nmax_line_width = 100\n'),
    ('[dependencies.tools]\ngit = "{tools_git}"\ntag = "v1"\n', "",
     '[dependencies.tools]\ngit = "{tools_git}"\ntag = "v1"\n\n[dependencies]\n{line}'),
    ('[dependencies]\r\ntools = {tools}', "", '[dependencies]\r\ntools = {tools}\r\n{line_bare}'),
], ids=["an empty file", "no final newline", "blank lines at the end", "CRLF line endings", "an empty table",
        "an entry, comments and the next table", "sub-tables", "CRLF, the last entry has no line ending"])
def test_add_changes_only_one_line_of_the_manifest_whatever_its_layout(ws, remotes, before, middle, after):
    remotes.publish(TOOLS, TOOLS_FILES, tag="v1", annotated=False)
    remotes.publish(GREETER, {"greet.agc": "# greet\n"}, tag="v1.0.0")
    tools = inline_table(dependency(remotes.url(TOOLS), tag="v1"))
    new = line(remotes, tag="v1.0.0")
    fill = {"line": new, "line_crlf": new.replace("\n", "\r\n"), "line_bare": new.rstrip("\n"), "tools": tools, "tools_git": remotes.url(TOOLS)}
    (ws.project / "agentica.toml").write_bytes(before.format(**fill).encode("utf-8"))

    result, problem = command(ws, remotes, "add", "greeter", remotes.url(GREETER), "--tag", "v1.0.0")
    assert (result.code, problem) == (0, None), result.stderr
    assert (ws.project / "agentica.toml").read_bytes() == after.format(**fill).encode("utf-8")
    # The text reads back: the manifest is valid and its lock matches it.
    assert command(ws, remotes, "install")[0].code == 0


def test_add_a_commit_pins_it_by_the_whole_id(ws, remotes):
    commit = remotes.publish(GREETER, {"greet.agc": "# greet\n"}, tag="v1.0.0")
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    result, problem = command(ws, remotes, "add", "greeter", remotes.url(GREETER), "--ref", commit)
    assert (result.code, problem) == (0, None), result.stderr
    assert read(ws, "agentica.toml") == 'name = "app"\n\n[dependencies]\n' + line(remotes, ref=commit)
    entry = lock_entry(ws, remotes, GREETER, {"greet.agc": "# greet\n"}, commit, ref=commit)
    assert read(ws, "agentica.lock") == lock_of(ws, entry)
    assert command(ws, remotes, "install")[0].code == 0


@pytest.mark.parametrize("words", [
    [], ["greeter"], ["greeter", "{url}"], ["greeter", "{url}", "--tag"], ["greeter", "{url}", "--branch", "main"],
    ["greeter", "{url}", "--tag", "v1.0.0", "extra"], ["Greeter", "{url}", "--tag", "v1.0.0"],
    ["greeter", "http://example.test/owner/greeter", "--tag", "v1.0.0"], ["greeter", "{url}", "--tag", "a/b"],
    ["greeter", "{url}", "--ref", "3f2a9c1"], ["greeter", "{url}", "--ref", "NOT-HEX-AT-ALL-HERE-NOPE"],
], ids=["nothing", "a name", "no pin", "no tag", "a branch", "a fifth word", "a bad name", "http", "a bad tag",
        "an abbreviated commit", "not a commit"])
def test_add_with_a_bad_command_line_is_a_usage_error_and_writes_nothing(ws, remotes, words):
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    result = plain(ws, remotes, "add", *[word.format(url=remotes.url(GREETER)) for word in words])
    assert (result.code, result.stdout) == (2, "")
    assert sorted(path.name for path in ws.project.iterdir()) == ["agentica.toml"]
    assert read(ws, "agentica.toml") == 'name = "app"\n'


def test_add_that_cannot_finish_writes_nothing(ws, remotes):
    remotes.publish(GREETER, {"greet.agc": "# greet\n"}, tag="v1.0.0")
    url = remotes.url(GREETER)
    manifest = 'name = "app"\n\n[dependencies]\ngreeter = %s\n' % inline_table(dependency(url, tag="v1.0.0"))
    (ws.project / "agentica.toml").write_text(manifest, encoding="utf-8")
    manifest_file = ws.project / "agentica.toml"

    # The name is a dependency already: the pin changes in the manifest, then `update`.
    _, problem = command(ws, remotes, "add", "greeter", url, "--tag", "v2.0.0")
    assert_at_key(problem, "PKG-DEPENDENCY-EXISTS", manifest_file, "dependencies.greeter")

    # The tag is not in the repository: git fails at the dependency that was asked for.
    _, problem = command(ws, remotes, "add", "tools", url, "--tag", "v9")
    assert_at_key(problem, "PKG-FETCH", manifest_file, "dependencies.tools.git")

    # A table that is written as an inline value has no [dependencies] header for the new line to join.
    manifest_file.write_text('name = "app"\ndependencies = {}\n', encoding="utf-8")
    _, problem = command(ws, remotes, "add", "greeter", url, "--tag", "v1.0.0")
    assert_at_key(problem, "PKG-MANIFEST-EDIT", manifest_file, "dependencies")

    assert read(ws, "agentica.toml") == 'name = "app"\ndependencies = {}\n'
    assert sorted(path.name for path in ws.project.iterdir()) == ["agentica.toml"]


def two_direct(ws, remotes):
    """A project that depends on greeter and tools, both tags, locked at their first commits; returns those files."""
    tools_files = {"bang.agc": BANG}
    greeter_files = {"greet.agc": GREET}
    tools = remotes.publish(TOOLS, tools_files, tag="v1", annotated=False)
    greeter = remotes.publish(GREETER, greeter_files, tag="v1.0.0")
    entries = [lock_entry(ws, remotes, GREETER, greeter_files, greeter, tag="v1.0.0"),
               lock_entry(ws, remotes, TOOLS, tools_files, tools, tag="v1")]
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0"),
                       "tools": dependency(remotes.url(TOOLS), tag="v1")})
    ws.write_lock()
    return entries


def test_update_of_a_lock_that_is_right_changes_not_one_byte_and_a_moved_tag_changes_what_was_asked(ws, remotes):
    first = two_direct(ws, remotes)
    written = read(ws, "agentica.lock")

    # The lock was made by the Python writer: reading it and writing it again gives the same bytes.
    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "nothing to update\n"), result.stderr
    assert read(ws, "agentica.lock") == written

    # Both tags move. `update greeter` takes the new greeter and leaves tools where the lock has it.
    new_greeter = {"greet.agc": GREET + "# newer\n"}
    new_tools = {"bang.agc": BANG + "# newer\n"}
    greeter_commit = remotes.publish(GREETER, new_greeter, tag="v1.0.0")
    tools_commit = remotes.publish(TOOLS, new_tools, tag="v1", annotated=False)
    ws.locked.clear()
    moved_greeter = lock_entry(ws, remotes, GREETER, new_greeter, greeter_commit, tag="v1.0.0")
    moved_tools = lock_entry(ws, remotes, TOOLS, new_tools, tools_commit, tag="v1")
    result = plain(ws, remotes, "update", "greeter")
    assert (result.code, result.stdout) == (0, "updated greeter@v1.0.0\n"), result.stderr
    assert read(ws, "agentica.lock") == lock_of(ws, moved_greeter, first[1])

    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "updated tools@v1\n"), result.stderr
    assert read(ws, "agentica.lock") == lock_of(ws, moved_greeter, moved_tools)
    # The new files are in the cache, and the next update has nothing to do.
    assert command(ws, remotes, "install")[0].code == 0
    assert plain(ws, remotes, "update").stdout == "nothing to update\n"


def test_update_drops_a_package_that_nothing_asks_for_and_a_commit_pin_does_not_move(ws, remotes):
    tools_commit = remotes.publish(TOOLS, TOOLS_FILES, tag="v1", annotated=False)
    files, greeter_commit = publish_greeter(remotes)
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    result, problem = command(ws, remotes, "update")
    assert (result.code, problem) == (0, None), result.stderr
    assert read(ws, "agentica.lock") == lock_of(
        ws, lock_entry(ws, remotes, GREETER, files, greeter_commit, tag="v1.0.0"),
        lock_entry(ws, remotes, TOOLS, TOOLS_FILES, tools_commit, tag="v1"))

    # The new greeter has no manifest, so tools is no longer part of the build.
    ws.locked.clear()
    plain_files = {"greet.agc": "# greet\n"}
    commit = remotes.publish(GREETER, plain_files, tag="v1.0.0")
    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "updated greeter@v1.0.0\nremoved tools\n"), result.stderr
    assert read(ws, "agentica.lock") == lock_of(ws, lock_entry(ws, remotes, GREETER, plain_files, commit, tag="v1.0.0"))

    # A dependency pinned by its commit takes that pin, and then stays on it whatever the repository does next.
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), ref=commit)})
    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "updated greeter@%s\n" % commit[:12]), result.stderr
    pinned = read(ws, "agentica.lock")
    assert pinned == lock_of(ws, lock_entry(ws, remotes, GREETER, plain_files, commit, ref=commit, name="greeter"))
    remotes.publish(GREETER, {"greet.agc": "# later\n"}, tag="v1.0.0")
    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "nothing to update\n"), result.stderr
    assert read(ws, "agentica.lock") == pinned


def test_update_writes_the_lock_that_a_manifest_edited_by_hand_needs(ws, remotes):
    tools_commit = remotes.publish(TOOLS, TOOLS_FILES, tag="v1", annotated=False)
    ws.write_manifest({"tools": dependency(remotes.url(TOOLS), tag="v1")})
    # There is no lock: a build says so, and `update` makes it.
    assert command(ws, remotes, "install")[1]["code"] == "PKG-LOCK-MISSING"
    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "added tools@v1\n"), result.stderr
    assert read(ws, "agentica.lock") == lock_of(ws, lock_entry(ws, remotes, TOOLS, TOOLS_FILES, tools_commit, tag="v1"))
    assert command(ws, remotes, "install")[0].code == 0


def test_update_and_add_need_a_manifest_and_update_a_dependency_of_it(ws, remotes):
    for words in (["update"], ["add", "tools", remotes.url(TOOLS), "--tag", "v1"]):
        _, problem = command(ws, remotes, *words)
        assert problem["code"] == "PKG-MANIFEST-MISSING"
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    _, problem = command(ws, remotes, "update", "tools")
    assert_at_key(problem, "PKG-DEPENDENCY-UNKNOWN", ws.project / "agentica.toml", "")
    # A project with no dependency has nothing to lock, so no lock is made.
    assert plain(ws, remotes, "update").stdout == "nothing to update\n"
    assert not (ws.project / "agentica.lock").exists()
    assert plain(ws, remotes, "update", "a", "b").code == 2


def test_a_package_that_asks_for_another_source_of_a_name_is_a_conflict_and_nothing_is_written(ws, remotes):
    remotes.publish(TOOLS, TOOLS_FILES, tag="v1", annotated=False)
    remotes.publish(TOOLS, TOOLS_FILES, tag="v2", annotated=False)
    _, greeter_commit = publish_greeter(remotes, manifest=tools_manifest(remotes, tag="v2"))
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0"),
                       "tools": dependency(remotes.url(TOOLS), tag="v1")})
    _, problem = command(ws, remotes, "update")
    folder = ws.folder(remotes.url(GREETER), greeter_commit)
    assert_at_key(problem, "PKG-SOURCE-CONFLICT", folder / "agentica.toml", "dependencies.tools")
    assert not (ws.project / "agentica.lock").exists()


def test_a_package_that_asks_for_a_commit_by_a_part_of_its_id_is_pkg_fetch(ws, remotes):
    manifest = 'name = "greeter"\n\n[dependencies]\ntools = %s\n' % inline_table(
        dependency(remotes.url(TOOLS), ref="3f2a9c1"))
    _, greeter_commit = publish_greeter(remotes, manifest=manifest)
    ws.write_manifest({"greeter": dependency(remotes.url(GREETER), tag="v1.0.0")})
    _, problem = command(ws, remotes, "update")
    folder = ws.folder(remotes.url(GREETER), greeter_commit)
    assert_at_key(problem, "PKG-FETCH", folder / "agentica.toml", "dependencies.tools.ref")


def test_packages_that_ask_for_each_other_and_for_themselves_are_locked_once(ws, remotes):
    # greeter asks for tools and for itself, and tools asks for greeter: a name is settled once, so this ends.
    tools_manifest_text = 'name = "tools"\n\n[dependencies]\ngreeter = %s\n' % inline_table(
        dependency(remotes.url(GREETER), tag="v1.0.0"))
    greeter_manifest = tools_manifest(remotes) + 'greeter = %s\n' % inline_table(
        dependency(remotes.url(GREETER), tag="v1.0.0"))
    remotes.publish(TOOLS, {**TOOLS_FILES, "agentica.toml": tools_manifest_text}, tag="v1", annotated=False)
    publish_greeter(remotes, manifest=greeter_manifest)
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    add_greeter_and_tools(ws, remotes)
    assert read(ws, "agentica.lock").count("[[package]]") == 2

    # `add` of a name that is locked as the dependency of a package says so, and `update` takes direct names only
    # and no option.
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    result = plain(ws, remotes, "add", "tools", remotes.url(TOOLS), "--tag", "v1")
    assert (result.code, result.stdout.splitlines()[0]) == (0, "added tools@v1"), result.stderr
    _, problem = command(ws, remotes, "update", "greeter")
    assert_at_key(problem, "PKG-DEPENDENCY-UNKNOWN", ws.project / "agentica.toml", "")
    for word in ["--help", "-x"]:
        assert plain(ws, remotes, "update", word).code == 2


def git_shim(tmp_path, body):
    """A folder to put first on PATH whose `git` runs `body` (shell) and then the real git. $PPID is the agentica
    process, which started git."""
    folder = tmp_path / "shim"
    folder.mkdir()
    script = folder / "git"
    script.write_text("#!/bin/sh\n%s\nPATH=%s exec git \"$@\"\n" % (body, os.environ["PATH"]), encoding="utf-8")
    script.chmod(0o755)
    return str(folder) + os.pathsep + os.environ["PATH"]


def test_add_refuses_a_manifest_that_changed_while_the_packages_were_fetched(ws, remotes, tmp_path):
    remotes.publish(GREETER, {"greet.agc": "# greet\n"}, tag="v1.0.0")
    manifest = ws.project / "agentica.toml"
    manifest.write_text('name = "app"\n', encoding="utf-8")
    path = git_shim(tmp_path, 'echo "# edited meanwhile" >> %s' % manifest)
    result, problem = command(ws, remotes, "add", "greeter", remotes.url(GREETER), "--tag", "v1.0.0", PATH=path)
    assert_at_key(problem, "PKG-WRITE", manifest, "")
    assert read(ws, "agentica.toml").startswith('name = "app"\n# edited meanwhile\n')
    assert "greeter" not in read(ws, "agentica.toml")
    assert sorted(path.name for path in ws.project.iterdir()) == ["agentica.toml"]


def test_a_manifest_that_cannot_be_written_after_the_lock_is_pkg_write_and_update_repairs_it(ws, remotes, tmp_path):
    files = {"greet.agc": "# greet\n"}
    remotes.publish(GREETER, files, tag="v1.0.0")
    manifest = ws.project / "agentica.toml"
    manifest.write_text('name = "app"\n', encoding="utf-8")
    # A folder where the new manifest is written first makes that write fail, after the lock was written.
    path = git_shim(tmp_path, 'mkdir -p %s/agentica.toml.new-$PPID' % ws.project)
    result, problem = command(ws, remotes, "add", "greeter", remotes.url(GREETER), "--tag", "v1.0.0", PATH=path)
    assert_at_key(problem, "PKG-WRITE", manifest, "")
    assert "agentica update" in problem["help"]
    assert read(ws, "agentica.toml") == 'name = "app"\n'
    assert read(ws, "agentica.lock").count("[[package]]") == 1
    assert not [entry for entry in ws.project.iterdir() if ".new-" in entry.name or ".old-" in entry.name]

    # The lock has a package that the manifest does not ask for: `update` makes them agree again.
    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "removed greeter\n"), result.stderr
    assert read(ws, "agentica.lock") == "version = 1\n"
