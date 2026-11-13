"""Test-only dependencies: `group = "test"` on a dependency of agentica.toml (docs/grammar/05b-modules.md, issue 1196).

The project locks and installs its test group like any dependency, but only its tests import it: the `*_test.agc` files
and the step program of `agentica test`. A project that depends on the package neither fetches nor locks the package's
test group. The remotes are bare git repositories behind a throwaway HOME (tests/package_support.py, `Remotes`), so
nothing touches the network. Cases assert codes, spans and key paths, never message text (AGENTS.md).
"""
import json

import pytest

from tests.package_support import (assert_at_key, cache_path, command, git, lock_entry, plain,  # noqa: F401
                                    problem_of, remotes, ws)

DICE = "owner/dice"
PROP = "owner/prop"
LIB = "owner/lib"
USER = "owner/user"

DICE_FILES = {"dice.agc": 'def roll() -> Int\n  return 4\nend\n', "agentica.toml": 'name = "dice"\n'}


def prop_files(remotes, version):
    """prop, which depends on dice: a dependency of a test-only dependency."""
    manifest = 'name = "prop"\n\n[dependencies]\ndice = { git = "%s", tag = "v1" }\n' % remotes.url(DICE)
    module = ('import Dice from "pkg/dice/dice"\n\n'
              'def check(n: Int) -> Bool\n  return n + Dice.roll() > %s\nend\n' % version)
    return {"agentica.toml": manifest, "prop.agc": module}


def publish_prop(remotes):
    """dice v1, and prop v1 and v2; returns the files and the commits of dice and prop v1."""
    dice = remotes.publish(DICE, DICE_FILES, tag="v1")
    files = prop_files(remotes, 0)
    prop = remotes.publish(PROP, files, tag="v1")
    remotes.publish(PROP, prop_files(remotes, 1), tag="v2")
    return files, dice, prop


def group_entry(remotes, tag="v1"):
    return 'prop = { git = "%s", tag = "%s", group = "test" }' % (remotes.url(PROP), tag)


def group_line(remotes):
    return group_entry(remotes) + "\n"


HELPER = 'import Prop from "pkg/prop/prop"\n\ndef holds() -> Bool\n  return Prop.check(1)\nend\n'
UNIT = ('import Helper from "../src/helper"\nimport Prop from "pkg/prop/prop"\n\n'
        'def test_prop() -> Result[Void]\n  return Test.eq(Prop.check(1) and Helper.holds(), true)\nend\n')
STEPS = ('import BDD from "std/bdd"\nimport Prop from "pkg/prop/prop"\n\n'
         'def holds(ctx: BDD.Context, args: List[String]) -> BDD.Context\n'
         '  return BDD.assert(ctx, Prop.check(args[0].to_i!), "prop")\nend\n\n'
         'def main() -> Void\n  BDD.run([BDD.step("prop holds for {int}", &holds)])\nend\n')
FEATURE = "Feature: Prop\n  Scenario: One\n    Then prop holds for 1\n"
MAIN = 'import Helper from "src/helper"\n\ndef main() -> Void\n  puts(Helper.holds())\nend\n'


def test_the_tests_of_the_project_import_its_test_group_and_nothing_else_does(ws, remotes):
    files, dice_commit, prop_commit = publish_prop(remotes)
    before = 'name = "app"\n'
    (ws.project / "agentica.toml").write_text(before, encoding="utf-8")
    for path, text in {"main.agc": MAIN, "src/helper.agc": HELPER, "test/app_test.agc": UNIT,
                       "specs/prop.feature": FEATURE, "specs/steps.agc": STEPS}.items():
        (ws.project / path).parent.mkdir(parents=True, exist_ok=True)
        (ws.project / path).write_text(text, encoding="utf-8")

    # `add --group test` writes the key last in the line, and locks the dependency and what it needs.
    added = plain(ws, remotes, "add", "prop", remotes.url(PROP), "--tag", "v1", "--group", "test")
    assert (added.code, added.stdout) == (0, "added dice@v1\nadded prop@v1\n"), added.stderr
    assert (ws.project / "agentica.toml").read_text(encoding="utf-8") == before + "\n[dependencies]\n" + group_line(
        remotes)
    # The lock has no key for the group: it is the layout a lock had before groups, and it reads back unchanged.
    lock_entry(ws, remotes, DICE, DICE_FILES, dice_commit, tag="v1")
    lock_entry(ws, remotes, PROP, files, prop_commit, tag="v1")
    lock = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert lock == ws.lock_text()
    again = plain(ws, remotes, "update")
    assert (again.code, again.stdout) == (0, "nothing to update\n"), again.stderr
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == lock

    # The unit test and the step program import it, and so does a file of the project that they import.
    tested = command(ws, remotes, "test")[0]
    report = json.loads(tested.stdout)
    assert (tested.code, report["ok"], report["failed"]) == (0, True, 0), tested.stdout + tested.stderr
    for path in ("test/app_test.agc", "specs/steps.agc"):
        assert command(ws, remotes, "check", str(ws.project / path))[1] is None
    # The queries read a test file as `check` does: `type-at` answers on the use of the test group.
    typed = command(ws, remotes, "type-at", "%s:5:19" % (ws.project / "test" / "app_test.agc"))[0]
    assert typed.code == 0, typed.stderr
    assert json.loads(typed.stdout)["type"] == "Bool"
    result, problem = command(ws, remotes, "type-at", "%s:4:8" % (ws.project / "main.agc"))
    assert result.code == 1 and problem["code"] == "CHECK-IMPORT-PACKAGE"
    assert problem["file"].endswith("helper.agc") and problem["range"]["start"] == {"line": 1, "column": 1}

    # A program that is not a test cannot import it, even through a file that a test imports and checked before.
    problem = problem_of(ws, remotes)
    assert problem["code"] == "CHECK-IMPORT-PACKAGE"
    assert problem["file"].endswith("helper.agc") and problem["range"]["start"] == {"line": 1, "column": 1}


def test_a_project_that_depends_on_the_package_neither_fetches_nor_locks_its_test_group(ws, remotes):
    publish_prop(remotes)
    manifest = 'name = "lib"\n\n[dependencies]\n%s\n' % group_entry(remotes)
    library = 'def double(n: Int) -> Int\n  return n * 2\nend\n'
    unit = ('import Prop from "pkg/prop/prop"\n\n'
            'def test_prop() -> Result[Void]\n  return Test.eq(Prop.check(1), true)\nend\n')
    remotes.publish(LIB, {"agentica.toml": manifest, "lib.agc": library, "lib_test.agc": unit}, tag="v1")
    # v2: a file of the package that is not a test imports its own test group.
    remotes.publish(LIB, {"agentica.toml": manifest, "lib.agc": 'import Prop from "pkg/prop/prop"\n\n' + library},
                    tag="v2")
    main = 'import Lib from "pkg/lib/lib"\n\ndef main() -> Void\n  puts(Lib.double(2))\nend\n'
    (ws.project / "main.agc").write_text(main, encoding="utf-8")
    write = (ws.project / "agentica.toml").write_text
    write('name = "app"\n\n[dependencies]\nlib = { git = "%s", tag = "v1" }\n' % remotes.url(LIB), encoding="utf-8")

    updated = plain(ws, remotes, "update")
    assert (updated.code, updated.stdout) == (0, "added lib@v1\n"), updated.stderr
    lock = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert "prop" not in lock and "dice" not in lock
    for path in (PROP, DICE):
        assert not (ws.pkg_root / cache_path(remotes.url(path))).exists()
    ran = plain(ws, remotes, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout) == (0, "4\n"), ran.stderr

    write('name = "app"\n\n[dependencies]\nlib = { git = "%s", tag = "v2" }\n' % remotes.url(LIB), encoding="utf-8")
    assert plain(ws, remotes, "update").code == 0
    problem = problem_of(ws, remotes)
    assert problem["code"] == "CHECK-IMPORT-PACKAGE"
    assert problem["file"].endswith("lib.agc") and problem["range"]["start"] == {"line": 1, "column": 1}


def test_a_test_group_name_that_a_package_needs_is_one_source_and_still_only_for_the_tests(ws, remotes):
    publish_prop(remotes)
    user = 'name = "user"\n\n[dependencies]\nprop = { git = "%s", tag = "v1" }\n' % remotes.url(PROP)
    remotes.publish(USER, {"agentica.toml": user, "user.agc": 'def name() -> String\n  return "user"\nend\n'},
                    tag="v1")
    (ws.project / "main.agc").write_text(
        'import Prop from "pkg/prop/prop"\n\ndef main() -> Void\n  puts(Prop.check(1))\nend\n', encoding="utf-8")

    def write(tag):
        text = 'name = "app"\n\n[dependencies]\nuser = { git = "%s", tag = "v1" }\n%s\n' % (
            remotes.url(USER), group_entry(remotes, tag))
        (ws.project / "agentica.toml").write_text(text, encoding="utf-8")

    # The same tag: one entry in the lock, which the package uses, and the program still cannot import it.
    write("v1")
    updated = plain(ws, remotes, "update")
    assert (updated.code, updated.stdout) == (0, "added dice@v1\nadded prop@v1\nadded user@v1\n"), updated.stderr
    problem = problem_of(ws, remotes)
    assert problem["code"] == "CHECK-IMPORT-PACKAGE" and problem["range"]["start"] == {"line": 1, "column": 1}
    # Another tag: one name is one source in a build, as for any dependency.
    write("v2")
    result, problem = command(ws, remotes, "update")
    assert result.code == 1
    assert (problem["code"], problem["key_path"]) == ("PKG-SOURCE-CONFLICT", "dependencies.prop")


@pytest.mark.parametrize("value", ['"dev"', "true", '"Test"'])
def test_test_is_the_only_group(ws, remotes, value):
    manifest = ws.project / "agentica.toml"
    manifest.write_text('name = "app"\n\n[dependencies]\nprop = { git = "%s", tag = "v1", group = %s }\n'
                        % (remotes.url(PROP), value), encoding="utf-8")
    (ws.project / "main.agc").write_text('def main() -> Void\n  puts("hi")\nend\n', encoding="utf-8")
    assert_at_key(problem_of(ws, remotes), "PKG-MANIFEST-INVALID", manifest, "dependencies.prop.group")
    added = plain(ws, remotes, "add", "dice", remotes.url(DICE), "--tag", "v1", "--group", "dev")
    assert added.code == 2
