"""The printer of the formatter (compiler/format/, docs/future/47-formatter.md 47.5 and 47.7).

The stage compiler/format/fmt.agc prints each file formatted, or the diagnostic line of a file it refuses; with
`--tree` it prints the normal form of 47.7. The goldens are the `.formatted` files beside the `.input` files of
fixtures/frontend/format/, which also have the `.comments` goldens of test_frontend_format.py; tools/refreeze.py
rewrites them. Every golden must format to itself and keep the normal form of its input, and a peer written here
checks the shape of the text. The slow tier formats every `.agc` file of the repo twice.
"""
import re

import pytest

from tests.agentica_test import ROOT, scaled, timeout
from tests.frontend_support import PytestStageCase, pytest_stage_fixtures

FIXTURES = ROOT / "tests" / "fixtures" / "frontend" / "format"
RELATIVE = "tests/fixtures/frontend/format/"
WIDTH = 119
# A word of the peer: a string literal or a run of characters that are not spaces.
WORD = re.compile(r'"(?:[^"\\]|\\.)*"|\S+')


class FmtStage(PytestStageCase):
    ENTRY = "format/fmt.agc"


_fmt_stage_class, fmt_stage = pytest_stage_fixtures(FmtStage, pytest, "fmt_stage")


def peer_problems(text, width=WIDTH):
    """What an independent reader finds wrong with formatted text: tabs, trailing spaces, CR, a missing final line
    break, an empty last line, or a line over the width that would fit without its longest word (a string literal
    counts as one word, and a line that starts with a string holds only it), which the printer could have broken."""
    found = []
    if not text.endswith("\n") or text.endswith("\n\n"):
        found.append("the text must end with exactly one line break")
    for number, line in enumerate(text.split("\n"), 1):
        if "\t" in line or "\r" in line:
            found.append("%d: a tab or a CR" % number)
        if line != line.rstrip(" "):
            found.append("%d: trailing spaces" % number)
        # A line that starts with a string holds that string alone, interpolated parts and all.
        if len(line) > width and not line.lstrip().startswith('"'):
            longest = max(len(word) for word in WORD.findall(line))
            if len(line) - longest > width:
                found.append("%d: %d columns" % (number, len(line)))
    return found


def formatted_goldens(stage):
    return stage.fixture_pairs(FIXTURES, ".input", ".formatted")


def test_every_input_has_a_formatted_golden(fmt_stage):
    formatted_goldens(fmt_stage)


def test_the_files_are_formatted_as_the_goldens_say(fmt_stage):
    pairs = formatted_goldens(fmt_stage)
    outputs = fmt_stage.run_sections([RELATIVE + name for name in pairs], cwd=ROOT)
    fmt_stage.assert_goldens({name: outputs[RELATIVE + name] for name in pairs}, pairs, "formatted fixtures")


def test_a_golden_formats_to_itself_keeps_the_tree_and_passes_the_peer(fmt_stage):
    pairs = formatted_goldens(fmt_stage)
    kept = {name: golden for name, golden in pairs.items() if not golden.read_text(encoding="utf-8").startswith("ERROR")}
    assert len(kept) >= 10
    goldens = [str(golden.relative_to(ROOT)) for golden in kept.values()]
    again = fmt_stage.run_sections(goldens, cwd=ROOT)
    trees = fmt_stage.run_sections(goldens + [RELATIVE + name for name in kept], "--tree", cwd=ROOT)
    for name, golden in kept.items():
        path = str(golden.relative_to(ROOT))
        text = golden.read_text(encoding="utf-8")
        assert again[path] == text, name
        assert trees[path] == trees[RELATIVE + name], name
        assert peer_problems(text) == [], name


def test_a_file_that_does_not_parse_is_refused_with_its_diagnostic(fmt_stage):
    output = fmt_stage.run_sections([RELATIVE + "parse-error.input"], cwd=ROOT)[RELATIVE + "parse-error.input"]
    assert output.startswith("ERROR LEX-UNCLOSED-DELIMITER 37:2:9-")


@pytest.mark.slow
@timeout(3600)
def test_every_file_of_the_repo_that_parses_formats_once_and_for_all(fmt_stage):
    skipped = {"build", "dist", "agc_libs", ".git"}
    paths = sorted(str(path.relative_to(ROOT)) for path in ROOT.glob("**/*.agc")
                   if path.is_file() and not skipped.intersection(path.relative_to(ROOT).parts))
    assert len(paths) > 1000
    first = fmt_stage.run_sections(paths, cwd=ROOT, timeout=scaled(3000))
    kept = {path: text for path, text in first.items() if not text.startswith("ERROR")}
    assert all(not text.startswith("ERROR FMT-") for text in first.values())
    directory = fmt_stage.make_temp_dir()
    for path, text in kept.items():
        (directory / path).parent.mkdir(parents=True, exist_ok=True)
        (directory / path).write_text(text, encoding="utf-8")
    second = fmt_stage.run_sections(sorted(kept), cwd=directory, timeout=scaled(3000))
    assert [path for path in kept if second[path] != kept[path]] == []
    assert {path: peer_problems(text) for path, text in kept.items() if peer_problems(text)} == {}
