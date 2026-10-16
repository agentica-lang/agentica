"""tools/refreeze.py and the refreeze mode of tests/frontend_support.py, on a scratch copy of the frozen files.

The goldens of the front end are rewritten from the Agentica stages with the tool, so the path that
rewrites them is tested here without running a stage: a manifest and a text golden are compared with changed output.
"""
import importlib.util
import json
import os
from pathlib import Path
from unittest import mock

from tests import frontend_support
from tests.agentica_test import ROOT
from tests.frontend_support import GoldenTestCase, read_manifest, sha256

spec = importlib.util.spec_from_file_location("refreeze", ROOT / "tools" / "refreeze.py")
refreeze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refreeze)


def manifest_line(text, key, source):
    return "%s %d %s %s\n" % (sha256(text), len(text.encode("utf-8")), sha256(source), key)


class RefreezeTest(GoldenTestCase):
    def setUp(self):
        self.frozen = self.make_temp_dir()
        self.log = self.frozen / "log.jsonl"
        (self.frozen / "x").mkdir()
        patches = [mock.patch.object(frontend_support, "FROZEN", self.frozen),
                   mock.patch.dict(os.environ, {"AGENTICA_REFREEZE": "1", "AGENTICA_REFREEZE_LOG": str(self.log)})]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def records(self):
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def test_a_manifest_is_rewritten_and_the_changes_are_logged_and_summarized(self):
        (self.frozen / "x" / "m.sha256").write_text(
            manifest_line("old a\n", "a", "in a") + manifest_line("same\n", "b", "in b")
            + manifest_line("gone\n", "c", "in c"), encoding="utf-8")
        outputs = {"a": "new a\n", "b": "same\n", "d": "added\n"}
        self.assert_manifest(outputs, "x/m.sha256", {"a": "in a", "b": "in b", "d": "in d"})
        entries = {entry.key: entry for entry in read_manifest("x/m.sha256")}
        self.assertEqual(sorted(entries), ["a", "b", "d"])
        self.assertEqual(entries["a"].output_sha, sha256("new a\n"))
        self.assertEqual(entries["d"].input_sha, sha256("in d"))
        record, = self.records()
        self.assertEqual((record["file"], [e["key"] for e in record["changed"]], record["added"], record["removed"]),
                         ("frozen/x/m.sha256", ["a"], ["d"], ["c"]))
        summary = "\n".join(refreeze.summarize(record, 40))
        self.assertIn("changed a: output", summary)
        self.assertIn("added d", summary)
        self.assertIn("removed c", summary)

    def test_a_manifest_that_does_not_change_is_not_rewritten_or_logged(self):
        text = manifest_line("same\n", "a", "in a")
        (self.frozen / "x" / "m.sha256").write_text(text, encoding="utf-8")
        self.assert_manifest({"a": "same\n"}, "x/m.sha256", {"a": "in a"})
        self.assertEqual((self.frozen / "x" / "m.sha256").read_text(encoding="utf-8"), text)
        self.assertFalse(self.log.exists())

    def test_a_text_golden_is_rewritten_and_summarized_as_a_diff(self):
        golden = self.frozen / "x" / "g.expected"
        golden.write_bytes(b"one\ntwo\n")
        self.assert_golden("one\n2\n", golden)
        self.assertEqual(golden.read_bytes(), b"one\n2\n")
        summary = "\n".join(refreeze.summarize(self.records()[0], 40))
        self.assertIn("-two", summary)
        self.assertIn("+2", summary)

    def test_without_the_refreeze_mode_a_difference_fails(self):
        golden = self.frozen / "x" / "g.expected"
        golden.write_bytes(b"one\n")
        with mock.patch.dict(os.environ, {"AGENTICA_REFREEZE": ""}):
            with self.assertRaises(AssertionError):
                self.assert_golden("two\n", golden)
        self.assertEqual(golden.read_bytes(), b"one\n")

    def test_the_stages_of_the_tool_are_the_test_modules(self):
        for stage in refreeze.STAGES:
            self.assertTrue((Path(ROOT) / "tests" / ("test_frontend_%s.py" % stage)).exists(), stage)
        self.assertEqual(refreeze.parse_stages(["lexer,parser", "lexer"]), ["lexer", "parser"])

    def test_a_stage_whose_tests_were_all_skipped_is_counted(self):
        all_skipped = "sss\n" + "-" * 70 + "\nRan 3 tests in 0.001s\n\nOK (skipped=3)\n"
        some_skipped = "Ran 5 tests in 1.0s\n\nFAILED (failures=1, skipped=2)\n"
        self.assertEqual(refreeze.count_skips(all_skipped), (3, 3, 0))
        self.assertEqual(refreeze.count_skips(some_skipped), (5, 2, 0))
        self.assertEqual(refreeze.count_skips("Ran 4 tests in 1.0s\n\nOK\n"), (4, 0, 0))

    def test_only_a_skip_for_another_reason_than_the_tier_is_a_missing_tool(self):
        output = ("test_a (m.C) ... skipped 'slow tier only'\n"
                  "test_b (m.C) ... skipped 'node is required (not found on PATH)'\n"
                  "setUpClass (m.D) ... skipped 'no cases in this tier'\n"
                  "\nRan 3 tests in 0.1s\n\nOK (skipped=3)\n")
        self.assertEqual(refreeze.count_skips(output), (3, 3, 1))
