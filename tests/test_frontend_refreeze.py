"""tools/refreeze.py and the refreeze mode of tests/frontend_support.py, on a scratch copy of the frozen files.

The goldens of the front end are rewritten from the Agentica stages with the tool, so the path that
rewrites them is tested here without running a stage: a manifest and a text golden are compared with changed output.
"""
import importlib.util
import json
import os
from pathlib import Path
from unittest import mock

import pytest

from tests import frontend_support
from tests.agentica_test import ROOT
from tests.frontend_support import assert_golden, assert_manifest, read_manifest, sha256

spec = importlib.util.spec_from_file_location("refreeze", ROOT / "tools" / "refreeze.py")
refreeze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refreeze)


def manifest_line(text, key, source):
    return "%s %d %s %s\n" % (sha256(text), len(text.encode("utf-8")), sha256(source), key)


@pytest.fixture
def frozen(tmp_path):
    """A scratch frozen/ tree with refreeze mode on; yields (directory, log path)."""
    directory = tmp_path / "frozen"
    directory.mkdir()
    log = directory / "log.jsonl"
    (directory / "x").mkdir()
    patches = [mock.patch.object(frontend_support, "FROZEN", directory),
               mock.patch.dict(os.environ, {"AGENTICA_REFREEZE": "1", "AGENTICA_REFREEZE_LOG": str(log)})]
    for patch in patches:
        patch.start()
    yield directory, log
    for patch in reversed(patches):
        patch.stop()


@pytest.fixture
def records(frozen):
    """The JSON records of the refreeze log, read on each call."""
    _, log = frozen

    def read():
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    return read


def test_a_manifest_is_rewritten_and_the_changes_are_logged_and_summarized(frozen, records):
    directory, _ = frozen
    (directory / "x" / "m.sha256").write_text(
        manifest_line("old a\n", "a", "in a") + manifest_line("same\n", "b", "in b")
        + manifest_line("gone\n", "c", "in c"), encoding="utf-8")
    outputs = {"a": "new a\n", "b": "same\n", "d": "added\n"}
    assert_manifest(outputs, "x/m.sha256", {"a": "in a", "b": "in b", "d": "in d"})
    entries = {entry.key: entry for entry in read_manifest("x/m.sha256")}
    assert sorted(entries) == ["a", "b", "d"]
    assert entries["a"].output_sha == sha256("new a\n")
    assert entries["d"].input_sha == sha256("in d")
    record, = records()
    assert (record["file"], [e["key"] for e in record["changed"]], record["added"], record["removed"]) == (
        "frozen/x/m.sha256", ["a"], ["d"], ["c"])
    summary = "\n".join(refreeze.summarize(record, 40))
    assert "changed a: output" in summary
    assert "added d" in summary
    assert "removed c" in summary


def test_a_manifest_that_does_not_change_is_not_rewritten_or_logged(frozen, records):
    directory, log = frozen
    text = manifest_line("same\n", "a", "in a")
    (directory / "x" / "m.sha256").write_text(text, encoding="utf-8")
    assert_manifest({"a": "same\n"}, "x/m.sha256", {"a": "in a"})
    assert (directory / "x" / "m.sha256").read_text(encoding="utf-8") == text
    assert not log.exists()


def test_a_text_golden_is_rewritten_and_summarized_as_a_diff(frozen, records):
    directory, _ = frozen
    golden = directory / "x" / "g.expected"
    golden.write_bytes(b"one\ntwo\n")
    assert_golden("one\n2\n", golden)
    assert golden.read_bytes() == b"one\n2\n"
    summary = "\n".join(refreeze.summarize(records()[0], 40))
    assert "-two" in summary
    assert "+2" in summary


def test_without_the_refreeze_mode_a_difference_fails(frozen):
    directory, _ = frozen
    golden = directory / "x" / "g.expected"
    golden.write_bytes(b"one\n")
    with mock.patch.dict(os.environ, {"AGENTICA_REFREEZE": ""}):
        with pytest.raises(AssertionError):
            assert_golden("two\n", golden)
    assert golden.read_bytes() == b"one\n"


def test_the_stages_of_the_tool_are_the_test_modules():
    for stage in refreeze.STAGES:
        assert (Path(ROOT) / "tests" / ("test_frontend_%s.py" % stage)).exists(), stage
    assert refreeze.parse_stages(["lexer,parser", "lexer"]) == ["lexer", "parser"]


def test_a_stage_whose_tests_were_all_skipped_is_counted():
    all_skipped = (
        '<testsuite tests="3" skipped="3">'
        '<testcase><skipped message="not selected in this test tier"/></testcase>'
        '<testcase><skipped message="not selected in this test tier"/></testcase>'
        '<testcase><skipped message="not selected in this test tier"/></testcase>'
        '</testsuite>'
    )
    some_skipped = (
        '<testsuite tests="3" skipped="2">'
        '<testcase><skipped message="not selected in this test tier"/></testcase>'
        '<testcase><skipped message="node is required (not found on PATH)"/></testcase>'
        '<testcase/>'
        '</testsuite>'
    )
    assert refreeze.count_skips(all_skipped) == (3, 3, 0)
    assert refreeze.count_skips(some_skipped) == (3, 2, 1)


def test_only_a_skip_for_another_reason_than_the_tier_is_a_missing_tool():
    report = (
        '<testsuite tests="4" skipped="2">'
        '<testcase><skipped message="slow tier only"/></testcase>'
        '<testcase><skipped message="fast tier only"/></testcase>'
        '<testcase/>'
        '<testcase/>'
        '</testsuite>'
    )
    assert refreeze.count_skips(report) == (4, 2, 0)
    assert refreeze.count_skips("<testsuite tests=\"2\"><testcase/><testcase/></testsuite>") == (2, 0, 0)
