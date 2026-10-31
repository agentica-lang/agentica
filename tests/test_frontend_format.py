"""The comment attachment of the formatter (compiler/format/, docs/future/47-formatter.md 47.4).

The stage compiler/format/attach.agc lexes each file with its plain comments (Lexer.lex_with_comments), parses it and
prints one line per comment: where it starts, its role (leading, trailing or dangling), the kind of its node and where
that node starts, the keyword of a dangling comment before or after `elsif`, `else` or `end`, and the comment's text.
The goldens in fixtures/frontend/format/ cover the positions of 47.4; tools/refreeze.py rewrites them. The plain lexer
keeps its tokens: the lexer goldens of test_frontend_lexer.py do not move.
"""
import re
import time

import pytest

from tests.agentica_test import ROOT, TIMEOUT_SCALE
from tests.frontend_support import PytestStageCase, pytest_stage_fixtures

FIXTURES = ROOT / "tests" / "fixtures" / "frontend" / "format"
LINE = re.compile(r'^(\d+):(\d+) (leading|trailing|dangling) [A-Za-z]+ \d+:\d+(?: (?:elsif|else|end))? "(.*)"$')
# A large file of the repo with many comments and no heredoc, so a line that starts with `#` is a comment.
LARGE = "compiler/syntax/parser.agc"
# Declarations of the generated file of the timing test, three comments each.
GENERATED_DECLS = 6000
# Seconds the attachment of the generated file may take: well above the time of a linear search (about half a second),
# well below the time of a quadratic one (more than ten seconds). Slow runners scale it (AGENTICA_TEST_TIMEOUT_SCALE).
GENERATED_LIMIT = 4.0


class FormatStage(PytestStageCase):
    ENTRY = "format/attach.agc"


_format_stage_class, format_stage = pytest_stage_fixtures(FormatStage, pytest, "format_stage")


def test_every_input_has_a_golden_and_no_golden_is_left_over(format_stage):
    format_stage.fixture_pairs(FIXTURES, ".input", ".comments")


def test_the_comments_are_attached_as_the_goldens_say(format_stage):
    pairs = format_stage.fixture_pairs(FIXTURES, ".input", ".comments")
    outputs = format_stage.run_sections(["tests/fixtures/frontend/format/" + name for name in pairs], cwd=ROOT)
    format_stage.assert_goldens({name: outputs["tests/fixtures/frontend/format/" + name] for name in pairs}, pairs,
                                "format fixtures")


def test_every_own_line_comment_of_a_large_file_is_placed_once_in_source_order(format_stage):
    source = (ROOT / LARGE).read_text(encoding="utf-8").split("\n")
    expected = [(number, len(line) - len(line.lstrip(" ")) + 1) for number, line in enumerate(source, 1)
                if line.lstrip(" ").startswith("#") and not line.lstrip(" ").startswith("##")]
    output = format_stage.run_sections([LARGE], cwd=ROOT)[LARGE]
    placed = []
    for line in output.rstrip("\n").split("\n"):
        match = LINE.match(line)
        assert match, line
        number, column = int(match.group(1)), int(match.group(2))
        assert source[number - 1][column - 1:] == match.group(4).replace('\\"', '"').replace("\\\\", "\\"), line
        placed.append((number, column))
    assert placed == sorted(placed)
    assert [place for place in placed if place in set(expected)] == expected
    assert len(expected) > 100


def test_the_attachment_of_a_file_with_many_declarations_stays_near_linear(format_stage):
    lines = []
    for index in range(GENERATED_DECLS):
        lines += ["# leads f%d" % index, "def f%d() -> Int # on the header" % index,
                  "  return %d # on the value" % index, "end", ""]
    directory = format_stage.make_temp_dir()
    (directory / "many.agc").write_text("\n".join(lines), encoding="utf-8")
    started = time.monotonic()
    output = format_stage.run_sections(["many.agc"], cwd=directory)["many.agc"]
    elapsed = time.monotonic() - started
    placed = output.rstrip("\n").split("\n")
    assert len(placed) == 3 * GENERATED_DECLS
    last = 5 * GENERATED_DECLS - 4
    assert [line.split(" ")[:4] for line in placed[-3:]] == [
        ["%d:1" % last, "leading", "FunctionDecl", "%d:1" % (last + 1)],
        ["%d:20" % (last + 1), "trailing", "TypeRef", "%d:16" % (last + 1)],
        ["%d:15" % (last + 2), "trailing", "Return", "%d:3" % (last + 2)],
    ]
    assert elapsed < GENERATED_LIMIT * TIMEOUT_SCALE, elapsed
