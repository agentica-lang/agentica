"""`version` requirements over git tags (docs/grammar/05b-modules.md, issue 1147), through the product CLI.

The remote of every case is a bare git repository behind a throwaway HOME (tests/package_support.py, `Remotes`), so
nothing touches the network. The requirement matcher below is a second implementation of the rules, written in Python
from RubyGems' Gem::Requirement (terms joined by commas, `~>` bumps the second-to-last segment, a pre-release only when
a term names one): a table of requirements is checked against the tag that `agentica update` locks for a repository
whose tags include pre-releases, a `v` prefix, versions that sort as numbers and names that are no version. The other
cases are the commands (`add --version`, `update`, `install`), the manifest and lock rules, and the failures. Cases
assert codes and the file and key path, never message text (AGENTS.md).
"""
import re
import tomllib

import pytest

from tests.package_support import (BANG, assert_at_key, command, dependency, environment, git,  # noqa: F401
                                    inline_table, lock_entry, no_git_path, plain, remotes, ws)

REPOSITORY = "owner/bond"
FILES = {"bond.agc": BANG}
MAIN = 'import Bond from "pkg/bond/bond"\n\ndef main() -> Void\n  puts(Bond.bang())\nend\n'

# Tags of the repository: releases of several lines, `v` and plain names, a pre-release of the next line, a tag that is
# no version and a tag of a folder of a monorepo. 0.10.0 sorts after 0.9.0 as a number, not as text.
TAGS = ["0.7.2", "0.8.0", "0.8.3", "v0.9.0", "0.9.0-rc.1", "0.10.0", "0.0.1234567890123", "1.0.0-rc.1", "1.0.0",
        "v1.2.3", "1.7.0", "v1.7.0", "1.8.0+build", "1.10.0", "2.0.0-alpha.1", "2.0.0-alpha.2", "2.0.0-alpha.10",
        "release-5", "lib-9.9.9"]

# Requirements and the tag that Gem::Requirement picks among TAGS, written by hand for the ones that pin the oracle:
# `~>` with a pre-release keeps RubyGems' bound, `< 0.9`, which a 0.9.0 pre-release is under; 1.7.0 and v1.7.0 are one
# version, and the first in text order wins; build metadata is ignored when comparing, and the tag keeps it.
BY_HAND = {
    "~> 0.8": "0.10.0",
    "~> 0.8.1": "0.8.3",
    "~> 1.0": "1.10.0",
    ">= 1.0, < 1.5": "v1.2.3",
    "< 0.8": "0.7.2",
    "== 0.8.0": "0.8.0",
    "0.8.3": "0.8.3",
    "> 1.2.3": "1.10.0",
    "<= 1.0.0": "1.0.0",
    ">= 2.0.0-alpha.1": "2.0.0-alpha.10",
    "~> 0.8.0-rc.1": "0.9.0-rc.1",
    "== 1.7.0": "1.7.0",
    "== 1.8.0": "1.8.0+build",
    "~> 1.0.0-rc.1": "1.0.0",
    ">= 0.9, < 0.10": "v0.9.0",
    "~> 0": "0.10.0",
}
REQUIREMENTS = list(BY_HAND) + ["> 0.0.1234567890122", "~> 0.9", "~> 1.2", ">= 0.7.2", "~> 0.7.2", "<= 0.9.0", "> 0.8.0, <= 0.8.3", "< 1.0.0",
                                "~> 1.10", ">= 1", "== 1.0.0-rc.1", "< 1.0.0-rc.1", ">=0.8,<0.9", "~>0.8.0"]
# No tag has a version that satisfies these.
NOTHING = ["~> 3.0", ">= 11", "< 0.0.1", "== 0.8.1", "~> 2.1", "> 1.10.0, < 2.0.0"]


def version_key(text):
    """The sort key of a SemVer version: the core as numbers, a release after its pre-releases, pre-release identifiers
    one by one (numbers before names, by value)."""
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?", text)
    if match is None:
        return None
    core = tuple(int(part) for part in match.groups()[:3])
    if match.group(4) is None:
        return core, (1,)
    return core, (0, *[(0, int(part), "") if part.isdigit() else (1, 0, part) for part in match.group(4).split(".")])


def bounds(requirement):
    """The (operator, version text) pairs that a requirement means: `~>` is `>=` and `<`."""
    found = []
    for term in requirement.split(","):
        match = re.fullmatch(r"\s*(~>|>=|<=|==|>|<)?\s*(\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.-]+)?)\s*", term)
        assert match, term
        operator, text = match.group(1) or "==", match.group(2)
        core, _, pre = text.partition("-")
        numbers = [int(part) for part in core.split(".")]
        full = ".".join(str(number) for number in numbers + [0] * (3 - len(numbers))) + ("-" + pre if pre else "")
        if operator != "~>":
            found.append((operator, full))
            continue
        # RubyGems: drop the last segment when there is more than one, then add one to what is left.
        kept = numbers[:-1] if len(numbers) > 1 else numbers
        upper = kept[:-1] + [kept[-1] + 1]
        found.append((">=", full))
        found.append(("<", ".".join(str(number) for number in upper + [0] * (3 - len(upper)))))
    return found


def chosen(requirement, tags, prefix=""):
    """The tag with the highest version that satisfies the requirement (the smallest text among equal versions)."""
    terms = bounds(requirement)
    pre_allowed = any("-" in text for _, text in terms)
    best = None
    for tag in sorted(tags):
        if prefix:
            if not tag.startswith(prefix):
                continue
            text = tag[len(prefix):]
        else:
            text = tag[1:] if tag.startswith("v") else tag
        key = version_key(text)
        if key is None or (key[1][0] == 0 and not pre_allowed):
            continue
        holds = all({">=": key >= version_key(bound), ">": key > version_key(bound), "<=": key <= version_key(bound),
                     "<": key < version_key(bound), "==": key == version_key(bound)}[operator]
                    for operator, bound in terms)
        if holds and (best is None or key > best[0]):
            best = (key, tag)
    return best[1] if best else None


def tag_all(remotes, tags, path=REPOSITORY):
    """Tags the commit that was published last with every tag, half of them annotated."""
    work = remotes.work / path
    for index, tag in enumerate(tags):
        remotes.git(*(["tag", "-f", "-a", "-m", tag] if index % 2 else ["tag", "-f"]), tag, cwd=work)
        remotes.git("push", "--quiet", "--force", "origin", "refs/tags/" + tag, cwd=work)


def lock_of(ws):
    return tomllib.loads((ws.project / "agentica.lock").read_text(encoding="utf-8"))["package"]


def manifest(ws, remotes, requirement, name="bond", **more):
    ws.write_manifest({name: dependency(remotes.url(REPOSITORY), version=requirement, **more)})


def test_a_requirement_locks_the_highest_tag_that_satisfies_it_as_rubygems_reads_it(ws, remotes):
    commit = remotes.publish(REPOSITORY, FILES, tag="0.7.2")
    tag_all(remotes, TAGS)
    names = {"r%02d" % index: requirement for index, requirement in enumerate(REQUIREMENTS)}
    ws.write_manifest({name: dependency(remotes.url(REPOSITORY), version=text) for name, text in names.items()})

    result = plain(ws, remotes, "update")
    assert result.code == 0, result.stderr
    locked = {entry["name"]: entry for entry in lock_of(ws)}
    assert sorted(locked) == sorted(names)
    for name, requirement in names.items():
        expected = chosen(requirement, TAGS)
        assert expected is not None, requirement
        assert (locked[name]["tag"], locked[name]["version"]) == (expected, requirement), requirement
        assert locked[name]["commit"] == commit, requirement
        if requirement in BY_HAND:
            assert locked[name]["tag"] == BY_HAND[requirement], requirement
    # The table reaches every kind of tag: plain, `v`, a pre-release, and a version that sorts as a number.
    assert {"0.10.0", "v0.9.0", "v1.2.3", "1.0.0-rc.1", "2.0.0-alpha.10", "1.10.0", "0.9.0-rc.1", "1.8.0+build"} <= {
        entry["tag"] for entry in locked.values()}


@pytest.mark.parametrize("requirement", NOTHING)
def test_a_requirement_that_no_tag_satisfies_is_pkg_version_unsatisfied_at_its_key_and_writes_nothing(
        ws, remotes, requirement):
    remotes.publish(REPOSITORY, FILES, tag="0.7.2")
    tag_all(remotes, TAGS)
    assert chosen(requirement, TAGS) is None
    manifest(ws, remotes, requirement)

    result, problem = command(ws, remotes, "update")
    assert result.code == 1
    assert_at_key(problem, "PKG-VERSION-UNSATISFIED", ws.project / "agentica.toml", "dependencies.bond.version")
    assert not (ws.project / "agentica.lock").exists()


def test_a_repository_with_no_version_tag_is_unsatisfied_and_one_that_cannot_be_listed_is_pkg_fetch(ws, remotes):
    remotes.publish(REPOSITORY, FILES, tag="release-5")
    manifest(ws, remotes, ">= 0")
    _, problem = command(ws, remotes, "update")
    assert_at_key(problem, "PKG-VERSION-UNSATISFIED", ws.project / "agentica.toml", "dependencies.bond.version")

    ws.write_manifest({"bond": dependency(remotes.url("owner/missing"), version=">= 0")})
    _, problem = command(ws, remotes, "update")
    assert_at_key(problem, "PKG-FETCH", ws.project / "agentica.toml", "dependencies.bond.git")


def test_add_writes_the_version_in_the_manifest_and_the_lock_and_a_program_runs_offline(ws, remotes, tmp_path):
    commit = remotes.publish(REPOSITORY, FILES, tag="1.0.0")
    remotes.publish(REPOSITORY, FILES, tag="1.0.5")
    commit = remotes.publish(REPOSITORY, FILES, tag="1.0.6")
    remotes.publish(REPOSITORY, FILES, tag="2.0.0")
    remotes.git("tag", "-f", "1.0.6", commit, cwd=remotes.work / REPOSITORY)
    remotes.git("push", "--quiet", "--force", "origin", "refs/tags/1.0.6", cwd=remotes.work / REPOSITORY)
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")

    result = plain(ws, remotes, "add", "bond", remotes.url(REPOSITORY), "--version", "~> 1.0")
    assert (result.code, result.stdout) == (0, "added bond@1.0.6\n"), result.stderr
    manifest_text = (ws.project / "agentica.toml").read_text(encoding="utf-8")
    assert manifest_text == 'name = "app"\n\n[dependencies]\nbond = { git = "%s", version = "~> 1.0" }\n' % (
        remotes.url(REPOSITORY))
    lock_entry(ws, remotes, REPOSITORY, FILES, commit, tag="1.0.6", version="~> 1.0")
    assert (ws.project / "agentica.lock").read_text(encoding="utf-8") == ws.lock_text()

    # What was written is what a build and `install` read, with no git on PATH.
    empty = no_git_path(tmp_path)
    assert plain(ws, remotes, str(ws.project / "main.agc"), PATH=empty).stdout == "!\n"
    installed = plain(ws, remotes, "install", PATH=empty)
    assert (installed.code, installed.stdout) == (0, "in the cache bond@1.0.6\n"), installed.stderr


def test_update_moves_to_the_newest_tag_that_satisfies_and_add_and_install_keep_the_locked_one(ws, remotes):
    remotes.publish(REPOSITORY, FILES, tag="1.0.0")
    manifest(ws, remotes, "~> 1.0")
    assert plain(ws, remotes, "update").stdout == "added bond@1.0.0\n"
    assert plain(ws, remotes, "update").stdout == "nothing to update\n"

    # A newer tag: install does not look for it, `update` takes it, and another `update` has nothing to do.
    remotes.publish(REPOSITORY, {**FILES, "extra.agc": "# more\n"}, tag="1.1.0")
    before = (ws.project / "agentica.lock").read_bytes()
    assert command(ws, remotes, "install")[0].code == 0
    assert (ws.project / "agentica.lock").read_bytes() == before
    assert plain(ws, remotes, "update", "bond").stdout == "updated bond@1.1.0\n"
    assert lock_of(ws)[0]["tag"] == "1.1.0"
    # A tag of the next major line does not satisfy `~> 1.0`.
    remotes.publish(REPOSITORY, FILES, tag="2.0.0")
    assert plain(ws, remotes, "update").stdout == "nothing to update\n"

    # `add` of another package keeps the locked tag, whatever tags the repository has now.
    remotes.publish("owner/other", {"other.agc": BANG}, tag="v1")
    remotes.publish(REPOSITORY, FILES, tag="1.2.0")
    added = plain(ws, remotes, "add", "other", remotes.url("owner/other"), "--tag", "v1")
    assert (added.code, added.stdout) == (0, "added other@v1\n"), added.stderr
    assert {entry["name"]: entry["tag"] for entry in lock_of(ws)} == {"bond": "1.1.0", "other": "v1"}


def test_the_tags_of_a_folder_are_name_dash_version_and_the_others_are_ignored(ws, remotes):
    files = {"lib/lib.agc": BANG, "tool/tool.agc": BANG}
    remotes.publish(REPOSITORY, files, tag="lib-1.0.0")
    tag_all(remotes, ["lib-1.2.0", "lib-2.0.0", "1.9.0", "tool-5.0.0", "lib-x"])
    manifest(ws, remotes, "~> 1.0", name="lib", subdir="lib")
    result = plain(ws, remotes, "update")
    assert (result.code, result.stdout) == (0, "added lib@lib-1.2.0 (folder lib)\n"), result.stderr
    assert lock_of(ws)[0]["tag"] == chosen("~> 1.0", ["lib-1.0.0", "lib-1.2.0", "lib-2.0.0", "1.9.0"], "lib-")

    # The repository itself takes only the tags X.Y.Z and vX.Y.Z: 1.9.0 is the one, lib-2.0.0 is not a version of it.
    manifest(ws, remotes, "~> 2.0", name="lib")
    _, problem = command(ws, remotes, "update")
    assert_at_key(problem, "PKG-VERSION-UNSATISFIED", ws.project / "agentica.toml", "dependencies.lib.version")


def test_add_with_a_version_and_a_subdir_writes_both_and_takes_the_tags_of_the_folder(ws, remotes):
    commit = remotes.publish(REPOSITORY, {"lib/lib.agc": BANG}, tag="lib-1.0.0")
    tag_all(remotes, ["lib-1.3.0", "1.9.0"])
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    result = plain(ws, remotes, "add", "lib", remotes.url(REPOSITORY), "--subdir", "lib", "--version", "~> 1.0")
    assert (result.code, result.stdout) == (0, "added lib@lib-1.3.0 (folder lib)\n"), result.stderr
    assert (ws.project / "agentica.toml").read_text(encoding="utf-8") == (
        'name = "app"\n\n[dependencies]\nlib = { git = "%s", version = "~> 1.0", subdir = "lib" }\n' % (
            remotes.url(REPOSITORY)))
    entry = lock_of(ws)[0]
    assert (entry["tag"], entry["subdir"], entry["version"], entry["commit"]) == ("lib-1.3.0", "lib", "~> 1.0", commit)


@pytest.mark.parametrize("entry, key_path", [
    ('{ git = "%s", tag = "v1", version = "~> 1.0" }', "dependencies.bond"),
    ('{ git = "%s" }', "dependencies.bond"),
    ('{ git = "%s", version = "latest" }', "dependencies.bond.version"),
    ('{ git = "%s", version = "~> 1.0, " }', "dependencies.bond.version"),
    ('{ git = "%s", version = "" }', "dependencies.bond.version"),
    ('{ git = "%s", version = 1 }', "dependencies.bond.version"),
    ('{ git = "%s", version = "~> 1.0", workspace = true }', "dependencies.bond.workspace"),
    ('{ path = "../x", version = "~> 1.0" }', "dependencies.bond"),
])
def test_a_manifest_that_asks_for_a_version_in_a_wrong_way_is_pkg_manifest_invalid_at_the_key(
        ws, remotes, entry, key_path):
    text = entry % remotes.url(REPOSITORY) if "%s" in entry else entry
    (ws.project / "agentica.toml").write_text('name = "app"\n\n[dependencies]\nbond = %s\n' % text, encoding="utf-8")
    _, problem = command(ws, remotes, "update")
    assert_at_key(problem, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key_path)


@pytest.mark.parametrize("words", [
    ["--version", "~> 1.0", "--tag", "v1"],
    ["--version", "~> 1.0", "--ref", "a" * 40],
    ["--version", "~> 1.0", "--workspace"],
    ["--version", "latest"],
    ["--version", ""],
    ["--version"],
])
def test_add_with_a_version_and_anything_else_that_does_not_fit_is_a_usage_error(ws, remotes, words):
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    result = plain(ws, remotes, "add", "bond", remotes.url(REPOSITORY), *words)
    assert result.code == 2, result.stderr
    assert (ws.project / "agentica.toml").read_text(encoding="utf-8") == 'name = "app"\n'


def locked_project(ws, remotes, requirement="~> 1.0"):
    commit = remotes.publish(REPOSITORY, FILES, tag="1.0.0")
    manifest(ws, remotes, requirement)
    assert plain(ws, remotes, "update").stdout == "added bond@1.0.0\n"
    return commit


def test_a_lock_tag_that_does_not_satisfy_its_version_is_invalid_and_a_changed_requirement_is_stale(ws, remotes):
    locked_project(ws, remotes)
    lock = ws.project / "agentica.lock"
    good = lock.read_text(encoding="utf-8")

    # The manifest changed its requirement: the lock is for the old one, and `update` makes it match again.
    remotes.publish(REPOSITORY, FILES, tag="1.1.0")
    manifest(ws, remotes, "~> 1.1")
    _, problem = command(ws, remotes, "install")
    assert_at_key(problem, "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.bond")
    assert plain(ws, remotes, "update").stdout == "updated bond@1.1.0\n"

    # The lock holds a tag its own version rejects, or a version with no tag, or a bad requirement.
    good = lock.read_text(encoding="utf-8")
    lock.write_text(good.replace('tag = "1.1.0"', 'tag = "2.0.0"'), encoding="utf-8")
    _, problem = command(ws, remotes, "install")
    assert_at_key(problem, "PKG-LOCK-INVALID", lock, "package[0].tag")
    lock.write_text(good.replace('version = "~> 1.1"', 'version = "latest"'), encoding="utf-8")
    _, problem = command(ws, remotes, "install")
    assert_at_key(problem, "PKG-LOCK-INVALID", lock, "package[0].version")
    lock.write_text(good.replace('tag = "1.1.0"\n', 'ref = "%s"\n' % ("a" * 40)), encoding="utf-8")
    _, problem = command(ws, remotes, "install")
    assert_at_key(problem, "PKG-LOCK-INVALID", lock, "package[0].version")

    lock.write_text(good, encoding="utf-8")
    assert command(ws, remotes, "install")[0].code == 0
    # A manifest with a tag for the same name is stale for a lock that holds a requirement.
    ws.write_manifest({"bond": dependency(remotes.url(REPOSITORY), tag="1.0.0")})
    _, problem = command(ws, remotes, "install")
    assert_at_key(problem, "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.bond")


def package(remotes, path, **needs):
    """Publishes a package whose manifest asks for the dependencies `needs` (name -> inline table). Returns the commit."""
    text = 'name = "%s"\n\n[dependencies]\n' % path.split("/")[1]
    text += "".join("%s = %s\n" % (name, inline_table(entry)) for name, entry in needs.items())
    return remotes.publish(path, {path.split("/")[1] + ".agc": BANG, "agentica.toml": text}, tag="v1")


def bond_tags(remotes, *tags):
    for tag in tags:
        remotes.publish(REPOSITORY, FILES, tag=tag)


def test_the_requirements_of_a_tree_meet_in_one_tag_and_the_pass_starts_again_for_a_stricter_one(ws, remotes):
    bond_tags(remotes, "1.0.0", "1.2.0", "1.4.0", "2.0.0")
    url = remotes.url(REPOSITORY)
    package(remotes, "owner/middle", bond=dependency(url, version="< 1.3"))
    package(remotes, "owner/other", bond=dependency(url, version="~>1.0"))
    ws.write_manifest({"bond": dependency(url, version="~> 1.0"),
                       "middle": dependency(remotes.url("owner/middle"), tag="v1"),
                       "other": dependency(remotes.url("owner/other"), tag="v1")})

    result = plain(ws, remotes, "update")
    assert result.code == 0, result.stderr
    locked = {entry["name"]: entry for entry in lock_of(ws)}
    assert (locked["bond"]["tag"], locked["bond"]["version"]) == ("1.2.0", "~> 1.0")
    # The lock is what the manifest asks for, so the build stays offline, and a requirement spelled another way is no change.
    assert command(ws, remotes, "install")[0].code == 0
    ws.write_manifest({"bond": dependency(url, version="~>1.0"),
                       "middle": dependency(remotes.url("owner/middle"), tag="v1"),
                       "other": dependency(remotes.url("owner/other"), tag="v1")})
    assert command(ws, remotes, "install")[0].code == 0
    assert plain(ws, remotes, "update").stdout == "nothing to update\n"

    # A newer tag that satisfies every ask is taken by `update`; one that `middle` rules out is not.
    bond_tags(remotes, "1.2.9", "1.3.1")
    assert plain(ws, remotes, "update").stdout == "updated bond@1.2.9\n"


def test_a_tag_pin_is_an_exact_version_that_the_requirements_of_the_tree_must_meet(ws, remotes):
    bond_tags(remotes, "1.0.0", "1.2.0", "1.4.0")
    url = remotes.url(REPOSITORY)
    package(remotes, "owner/middle", bond=dependency(url, tag="1.2.0"))
    package(remotes, "owner/other", bond=dependency(url, version="~> 1.0"))
    # A requirement first, then the pin of a package: the pass starts again and takes the pinned tag.
    ws.write_manifest({"other": dependency(remotes.url("owner/other"), tag="v1"),
                       "middle": dependency(remotes.url("owner/middle"), tag="v1")})
    result = plain(ws, remotes, "update")
    assert result.code == 0, result.stderr
    assert {entry["name"]: entry["tag"] for entry in lock_of(ws)}["bond"] == "1.2.0"

    # The pin first, then a requirement it meets: nothing moves, and the lock keeps the pin as the project wrote it.
    ws.write_manifest({"bond": dependency(url, tag="1.2.0"), "other": dependency(remotes.url("owner/other"), tag="v1")})
    assert plain(ws, remotes, "update").code == 0
    entry = {entry["name"]: entry for entry in lock_of(ws)}["bond"]
    assert (entry["tag"], "version" in entry) == ("1.2.0", False)


def test_asks_that_no_tag_meets_are_pkg_version_unsatisfied_and_the_message_names_who_asked_for_what(ws, remotes):
    bond_tags(remotes, "1.0.0", "1.2.0", "1.4.0", "2.0.0")
    url = remotes.url(REPOSITORY)
    package(remotes, "owner/middle", bond=dependency(url, version=">= 2.0"))
    ws.write_manifest({"bond": dependency(url, version="~> 1.0"), "middle": dependency(remotes.url("owner/middle"), tag="v1")})
    _, problem = command(ws, remotes, "update")
    assert_at_key(problem, "PKG-VERSION-UNSATISFIED", ws.project / "agentica.toml", "dependencies.bond.version")
    # The one thing about a message that the issue asks for: it names the askers and what each asked.
    for word in ["the project", "~> 1.0", "package middle", ">= 2.0"]:
        assert word in problem["message"]
    assert not (ws.project / "agentica.lock").exists()

    # A pinned tag that a requirement of a package rules out is the same failure, at that package's dependency.
    middle_commit = package(remotes, "owner/middle", bond=dependency(url, version="< 1.3"))
    ws.write_manifest({"bond": dependency(url, tag="1.4.0"), "middle": dependency(remotes.url("owner/middle"), tag="v1")})
    _, problem = command(ws, remotes, "update")
    folder = ws.folder(remotes.url("owner/middle"), middle_commit)
    assert_at_key(problem, "PKG-VERSION-UNSATISFIED", folder / "agentica.toml", "dependencies.bond.version")

    # Two different pins of one name stay what they were.
    package(remotes, "owner/middle", bond=dependency(url, tag="1.2.0"))
    _, problem = command(ws, remotes, "update")
    assert problem["code"] == "PKG-SOURCE-CONFLICT"
