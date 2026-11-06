"""`override = true` and `path` dependencies of the root project's manifest (docs/grammar/05b-modules.md, issue 1144).

An override makes the root's source win for a name everywhere in the tree, so a package that asks for another source of
it is no conflict; a `path` is a folder read in place, never fetched. Both are refused in the manifest of a package.
The remotes are bare git repositories behind a throwaway HOME (tests/package_support.py, `Remotes`), so nothing touches
the network. Cases assert codes and key paths, never message text (AGENTS.md); the help of PKG-SOURCE-CONFLICT is the
one exception, because naming `override = true` is what that help is for.
"""
import pytest

from tests.package_support import (assert_at_key, build, command, git, no_git_path, plain, problem_of,  # noqa: F401
                                    remotes, ws)

BOND = "owner/bond"
CHANNELS = "owner/channels"


def bond_module(version):
    return 'export def version() -> String\n  return "bond %s"\nend\n' % version


MAIN = ('import Bond from "pkg/bond/bond"\nimport Channels from "pkg/channels/channels"\n\n'
        'def main() -> Void\n  puts(Channels.describe())\n  puts(Bond.version())\nend\n')


def publish_bond(remotes):
    """Two versions of bond, tagged v1 and v2."""
    for version in ("1", "2"):
        remotes.publish(BOND, {"bond.agc": bond_module(version), "agentica.toml": 'name = "bond"\n'}, tag="v" + version)


def publish_channels(remotes, bond_entry=None):
    """channels, which depends on bond (as `bond_entry` says, bond v1 by default) and prints what bond says."""
    entry = bond_entry or '{ git = "%s", tag = "v1" }' % remotes.url(BOND)
    manifest = 'name = "channels"\n\n[dependencies]\nbond = %s\n' % entry
    module = ('import Bond from "pkg/bond/bond"\n\nexport def describe() -> String\n'
              '  return "channels over " + Bond.version()\nend\n')
    remotes.publish(CHANNELS, {"agentica.toml": manifest, "channels.agc": module}, tag="v1")


def write_project(ws, remotes, bond):
    """The root manifest: channels from the remote, and bond as `bond` says (an inline table)."""
    (ws.project / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nchannels = { git = "%s", tag = "v1" }\nbond = %s\n' % (
            remotes.url(CHANNELS), bond), encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def lock_of(ws):
    return (ws.project / "agentica.lock").read_text(encoding="utf-8")


def test_an_override_wins_over_a_transitive_tag_and_is_locked(ws, remotes):
    publish_bond(remotes)
    publish_channels(remotes)
    url = remotes.url(BOND)
    # Without the override, channels asks for bond v1 and the project for v2: a conflict that says how to get out.
    write_project(ws, remotes, '{ git = "%s", tag = "v2" }' % url)
    result, problem = command(ws, remotes, "update")
    assert result.code == 1
    assert problem["code"] == "PKG-SOURCE-CONFLICT" and problem["key_path"] == "dependencies.bond"
    assert "override = true" in problem["help"]
    # With it, the project's v2 wins everywhere, and the command says which package asked for another source.
    write_project(ws, remotes, '{ git = "%s", tag = "v2", override = true }' % url)
    updated = plain(ws, remotes, "update")
    assert (updated.code, updated.stdout) == (
        0, "added bond@v2\nadded channels@v1\noverridden bond@v2 (another source asked by channels)\n"), updated.stderr
    lock = lock_of(ws)
    assert lock.count("override = true") == 1
    assert 'name = "bond"\ngit = "%s"\ntag = "v2"' % url in lock
    # The build uses v2 for channels too; a second update and an install change nothing and still report the override.
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "channels over bond 2\nbond 2\n"), ran.stderr
    again = plain(ws, remotes, "update")
    assert (again.code, again.stdout) == (0, "nothing to update\noverridden bond@v2 (another source asked by channels)\n")
    assert lock_of(ws) == lock
    installed = plain(ws, remotes, "install")
    assert installed.code == 0 and installed.stdout.endswith("overridden bond@v2\n"), installed.stderr
    # The lock records the override: a manifest without it is stale.
    write_project(ws, remotes, '{ git = "%s", tag = "v2" }' % url)
    assert_at_key(problem_of(ws, remotes), "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.bond")


@pytest.mark.parametrize("key, entry", [
    ("override", '{ git = "https://example.test/owner/bond", tag = "v1", override = true }'),
    ("path", '{ path = "../bond" }'),
], ids=["an override", "a path"])
def test_a_package_cannot_override_or_name_a_path(ws, remotes, key, entry):
    publish_channels(remotes, entry)
    (ws.project / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nchannels = { git = "%s", tag = "v1" }\n' % remotes.url(CHANNELS),
        encoding="utf-8")
    result, problem = command(ws, remotes, "update")
    assert result.code == 1
    assert problem["code"] == "PKG-ROOT-ONLY" and problem["key_path"] == "dependencies.bond." + key


def test_a_path_is_read_in_place_with_no_fetch_no_cache_and_no_hash(ws, remotes):
    bond = ws.base / "bond"
    bond.mkdir()
    (bond / "agentica.toml").write_text('name = "bond"\n', encoding="utf-8")
    (bond / "bond.agc").write_text(bond_module("1"), encoding="utf-8")
    (ws.project / "agentica.toml").write_text('name = "app"\n\n[dependencies]\nbond = { path = "../bond" }\n',
                                              encoding="utf-8")
    (ws.project / "main.agc").write_text(
        'import Bond from "pkg/bond/bond"\n\ndef main() -> Void\n  puts(Bond.version())\nend\n', encoding="utf-8")
    no_git = no_git_path(ws.base)
    updated = plain(ws, remotes, "update", PATH=no_git)
    assert (updated.code, updated.stdout) == (0, "added bond@path\n"), updated.stderr
    assert lock_of(ws) == 'version = 1\n\n[[package]]\nname = "bond"\npath = "../bond"\n'
    installed = plain(ws, remotes, "install", PATH=no_git)
    assert (installed.code, installed.stdout) == (0, "in place bond@path\n"), installed.stderr
    assert not ws.deps.exists() and not ws.pkg_root.exists()
    ran = plain(ws, remotes, str(ws.project / "main.agc"), PATH=no_git)
    assert (ran.code, ran.stdout) == (0, "bond 1\n"), ran.stderr
    # An edit in the folder is the next run: no tag, no install, no new lock.
    (bond / "bond.agc").write_text(bond_module("local"), encoding="utf-8")
    ran = plain(ws, remotes, str(ws.project / "main.agc"), PATH=no_git)
    assert (ran.code, ran.stdout) == (0, "bond local\n"), ran.stderr


def test_a_path_override_replaces_a_transitive_git_dependency_and_the_lock_round_trips(ws, remotes):
    publish_bond(remotes)
    publish_channels(remotes)
    bond = ws.base / "bond"
    bond.mkdir()
    (bond / "agentica.toml").write_text('name = "bond"\n', encoding="utf-8")
    (bond / "bond.agc").write_text(bond_module("local"), encoding="utf-8")
    write_project(ws, remotes, '{ path = "../bond", override = true }')
    updated = plain(ws, remotes, "update")
    assert (updated.code, updated.stdout) == (
        0, "added bond@path\nadded channels@v1\noverridden bond@path (another source asked by channels)\n"), updated.stderr
    lock = lock_of(ws)
    assert 'name = "bond"\npath = "../bond"\noverride = true\n' in lock
    # Only channels was fetched: bond has a path and no folder in deps/.
    assert sorted(path.name for path in ws.deps.iterdir()) == ["channels"]
    ran = build(ws, remotes)
    assert (ran.code, ran.stdout) == (0, "channels over bond local\nbond local\n"), ran.stderr
    # The lock that was written is read back and written again unchanged, by `update` and by a build that reads it.
    again = plain(ws, remotes, "update")
    assert again.code == 0, again.stderr
    assert lock_of(ws) == lock
    assert problem_of(ws, remotes) is None
