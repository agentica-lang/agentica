"""`agentica init`: starts a project in the working folder, and the project it writes is one that `add` and a run read.

Cases assert codes and the file and key path, never message text (AGENTS.md). The remote of the `add` case is a bare git
repository behind a throwaway HOME (tests/package_support.py), so nothing touches the network.
"""
import pytest

from tests.agentica_test import agentica_version
from tests.package_support import BANG, assert_at_key, command, git, plain, remotes, ws  # noqa: F401

TOOLS = "owner/tools"
HELLO = 'def main() -> Void\n  puts("Hello, world!")\nend\n'


def test_init_writes_a_project_that_runs_and_takes_a_dependency_with_add(ws, remotes):
    result = plain(ws, remotes, "init")
    assert (result.code, result.stdout) == (0, "created main.agc\ncreated agentica.toml\n"), result.stderr
    # The folder of the project is called "project": the default name.
    manifest = ws.project / "agentica.toml"
    assert manifest.read_text(encoding="utf-8") == 'name = "project"\nagentica = "%s"\n' % agentica_version()
    assert (ws.project / "main.agc").read_text(encoding="utf-8") == HELLO
    ran = plain(ws, remotes, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout) == (0, "Hello, world!\n"), ran.stderr

    remotes.publish(TOOLS, {"bang.agc": BANG}, tag="v1", annotated=False)
    added, problem = command(ws, remotes, "add", "tools", remotes.url(TOOLS), "--tag", "v1")
    assert (added.code, problem) == (0, None), added.stderr
    assert manifest.read_text(encoding="utf-8").startswith('name = "project"\nagentica = "%s"\n' % agentica_version())
    assert command(ws, remotes, "install")[0].code == 0


def test_init_takes_the_name_and_keeps_the_main_file_it_finds(ws, remotes):
    (ws.project / "main.agc").write_text("# mine\n", encoding="utf-8")
    result = plain(ws, remotes, "init", "notes-app")
    assert (result.code, result.stdout) == (0, "created agentica.toml\n"), result.stderr
    assert (ws.project / "main.agc").read_text(encoding="utf-8") == "# mine\n"
    assert 'name = "notes-app"\n' in (ws.project / "agentica.toml").read_text(encoding="utf-8")


def test_init_never_changes_an_existing_manifest(ws, remotes):
    manifest = ws.project / "agentica.toml"
    manifest.write_text('name = "app"\n', encoding="utf-8")
    result, problem = command(ws, remotes, "init", "other")
    assert result.code == 1
    assert_at_key(problem, "PKG-MANIFEST-EXISTS", manifest, "")
    assert manifest.read_text(encoding="utf-8") == 'name = "app"\n'
    assert not (ws.project / "main.agc").exists()


@pytest.mark.parametrize("name", ["Notes", "1st", "a b", "a" * 65])
def test_init_refuses_a_name_that_the_manifest_would_refuse_and_writes_nothing(ws, remotes, name):
    result, problem = command(ws, remotes, "init", name)
    assert result.code == 1
    assert_at_key(problem, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", "name")
    assert list(ws.project.iterdir()) == []


def test_init_is_a_usage_error_with_two_names_or_an_option(ws, remotes):
    assert plain(ws, remotes, "init", "a", "b").code == 2
    assert plain(ws, remotes, "init", "--force").code == 2
