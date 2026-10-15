"""The Agentica lexer (compiler/lex.agc) against the frozen output of the Racket lexer.

tests/frontend-lexer-test.rkt compares the two live. This module compares the Agentica lexer with what the Racket
lexer printed once for the same inputs (`make frontend-freeze`, tests/frontend-lexer-freeze.rkt), so the comparison
survives the Racket front end: the corpus (examples/, stdlib/ and tests/fixtures/vm/ as they were at the freeze), 300
generated inputs, deeply nested files and a file with invalid UTF-8.
"""
from tests.agentica_test import slow
from tests.frontend_support import FROZEN, StageTestCase, load_corpus, load_json, write_files

# The linear lexer costs about 1,000 steps per line and the budget allows 3,000, so a scan of the whole frame stack
# for each line fails it. A step budget makes the check deterministic on a loaded runner, where a clock would not.
STEPS_PER_LINE = 3000


def nested(depth):
    return "if x\n" * depth


class LexerFrozenTest(StageTestCase):
    ENTRY = "lex.agc"

    def lex(self, files, *, flags=()):
        """Lex the files {path: text} written into a fresh folder; gives the output of each by its path."""
        directory = self.make_temp_dir()
        write_files(directory, files)
        return self.run_sections(sorted(files), flags=flags, cwd=directory)

    def check_nested(self, depth):
        name = "nested-%d" % depth
        outputs = self.lex({name + ".agc": nested(depth)}, flags=("--max-steps", str(depth * STEPS_PER_LINE)))
        self.assert_manifest({name: outputs[name + ".agc"]}, "lexer/nested.sha256", {name: nested(depth)}, keys=[name])

    def test_invalid_utf8_is_lex_invalid_utf8_at_the_first_bad_byte(self):
        # The file is read by compiler/source_file.agc before the lexer sees it.
        outputs = self.lex({"invalid.agc": b"# caf\xc3\xa9\ndef \xff\n"})
        expected = (FROZEN / "lexer" / "invalid-utf8.expected").read_text(encoding="utf-8")
        self.assertEqual(outputs["invalid.agc"], expected)
        self.assertRegex(expected, r"^ERROR LEX-INVALID-UTF8 11:2:5-12:2:6 ")

    def test_a_deeply_nested_file_lexes_in_a_linear_number_of_steps(self):
        self.check_nested(4000)

    @slow
    def test_a_much_deeper_nested_file_lexes_in_a_linear_number_of_steps(self):
        self.check_nested(10000)

    @slow
    def test_corpus(self):
        files = {path: text for path, text in load_corpus("examples", "stdlib", "fixtures").items()
                 if path.startswith(("examples/", "stdlib/", "tests/fixtures/vm/"))}
        outputs = self.lex(files)
        self.assert_manifest(outputs, "lexer/corpus.sha256", files)

    @slow
    def test_300_generated_inputs(self):
        cases = {"case-%d" % n: text for n, text in enumerate(load_json("lexer/generated.json"))}
        outputs = self.lex({key + ".agc": text for key, text in cases.items()})
        self.assert_manifest({key: outputs[key + ".agc"] for key in cases}, "lexer/generated.sha256", cases)
