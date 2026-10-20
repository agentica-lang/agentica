"""The Agentica lexer (compiler/syntax/lex.agc) against the frozen output of the original lexer.

This module compares the Agentica lexer with what the original lexer printed once for the same inputs (frozen in
tests/fixtures/frontend/frozen/; tools/refreeze.py rewrites them from the Agentica stages), so the comparison survives
the original front end. It also compares with the goldens in fixtures/frontend/lexer/ and checks the Unicode table. The
frozen inputs are the corpus (examples/, stdlib/ and tests/fixtures/vm/ as they were at the freeze), 300 generated
inputs, deeply nested files and a file with invalid UTF-8.
"""
import re

import pytest

from tests.agentica_test import ROOT, timeout
from tests.frontend_support import (FROZEN, PytestStageCase, load_corpus, load_json, pytest_stage_fixtures,
                                    write_files)

FIXTURES = ROOT / "tests" / "fixtures" / "frontend" / "lexer"

# The linear lexer costs about 1,000 steps per line and the budget allows 3,000, so a scan of the whole frame stack
# for each line fails it. A step budget makes the check deterministic on a loaded runner, where a clock would not.
STEPS_PER_LINE = 3000


def nested(depth):
    return "if x\n" * depth


class LexerStage(PytestStageCase):
    ENTRY = "syntax/lex.agc"

    def lex(self, files, directory, *, flags=()):
        """Lex the files {path: text} written into `directory`; gives the output of each by its path."""
        write_files(directory, files)
        return self.run_sections(sorted(files), flags=flags, cwd=directory)


_lexer_stage_class, lexer_stage = pytest_stage_fixtures(LexerStage, pytest, "lexer_stage")


def check_nested(lexer_stage, tmp_path, depth):
    name = "nested-%d" % depth
    outputs = lexer_stage.lex({name + ".agc": nested(depth)}, tmp_path,
                              flags=("--max-steps", str(depth * STEPS_PER_LINE)))
    lexer_stage.assert_manifest({name: outputs[name + ".agc"]}, "lexer/nested.sha256", {name: nested(depth)}, keys=[name])


def test_every_input_has_a_golden_and_no_golden_is_left_over(lexer_stage):
    lexer_stage.fixture_pairs(FIXTURES, ".input", ".tokens")


def test_the_lexer_matches_the_goldens_of_the_fixtures(lexer_stage):
    pairs = lexer_stage.fixture_pairs(FIXTURES, ".input", ".tokens")
    outputs = lexer_stage.run_sections(["tests/fixtures/frontend/lexer/" + name for name in pairs], cwd=ROOT)
    lexer_stage.assert_goldens({name: outputs["tests/fixtures/frontend/lexer/" + name] for name in pairs}, pairs,
                               "lexer fixtures")


def test_the_unicode_table_is_the_char_graphic_table_of_the_freeze(lexer_stage):
    # compiler/syntax/unicode_table.agc is hand-edited data (its header has the provenance, Unicode 17.0); the ranges
    # of the original table are frozen in lexer/graphic-ranges.expected.
    text = (ROOT / "compiler" / "syntax" / "unicode_table.agc").read_text(encoding="utf-8")
    body = text.split("export GRAPHIC_RANGES = [", 1)[1].split("]", 1)[0]
    numbers = [int(number) for number in re.findall(r"\d+", body)]
    ranges = ["%d %d" % pair for pair in zip(numbers[::2], numbers[1::2])]
    lexer_stage.assert_golden("".join(line + "\n" for line in ranges), FROZEN / "lexer" / "graphic-ranges.expected")


def test_invalid_utf8_is_lex_invalid_utf8_at_the_first_bad_byte(lexer_stage, tmp_path):
    # The file is read by compiler/modules/source_file.agc before the lexer sees it.
    outputs = lexer_stage.lex({"invalid.agc": b"# caf\xc3\xa9\ndef \xff\n"}, tmp_path)
    lexer_stage.assert_golden(outputs["invalid.agc"], FROZEN / "lexer" / "invalid-utf8.expected")
    assert re.search(r"^ERROR LEX-INVALID-UTF8 11:2:5-12:2:6 ", outputs["invalid.agc"])


def test_a_deeply_nested_file_lexes_in_a_linear_number_of_steps(lexer_stage, tmp_path):
    check_nested(lexer_stage, tmp_path, 4000)


@pytest.mark.slow
@timeout(1800)
def test_a_much_deeper_nested_file_lexes_in_a_linear_number_of_steps(lexer_stage, tmp_path):
    check_nested(lexer_stage, tmp_path, 10000)


@pytest.mark.slow
@timeout(1800)
def test_corpus(lexer_stage, tmp_path):
    files = {path: text for path, text in load_corpus("examples", "stdlib", "fixtures").items()
             if path.startswith(("examples/", "stdlib/", "tests/fixtures/vm/"))}
    outputs = lexer_stage.lex(files, tmp_path)
    lexer_stage.assert_manifest(outputs, "lexer/corpus.sha256", files)


@pytest.mark.slow
@timeout(1800)
def test_300_generated_inputs(lexer_stage, tmp_path):
    cases = {"case-%d" % n: text for n, text in enumerate(load_json("lexer/generated.json"))}
    outputs = lexer_stage.lex({key + ".agc": text for key, text in cases.items()}, tmp_path)
    lexer_stage.assert_manifest({key: outputs[key + ".agc"] for key in cases}, "lexer/generated.sha256", cases)
