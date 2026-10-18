"""The rest of the checker rules, through the product CLI.

tests/test_spec_checker.py has the cases about spans, pipes and the nesting limit. The other cases of the old
checker test are in tests/fixtures/spec/checker-rest.json: one list of programs for each rule group, in the
order of that file. Each program is written to a file and checked with `--json check FILE`. A case says what the check
gives:

- `code`: the diagnostic code, or null when the program checks clean (always asserted).
- `start`: the line and column where the range starts; `covers`: the source text that the range covers.
- `help`: whether the diagnostic has a help text (its wording is never asserted, AGENTS.md).
- `expected`, `actual`, `function`, `callee`, `labels`: the structured fields of the diagnostic (`labels` is a count).

A key that a case does not have is not asserted. A group is one test method, named after the group.
"""
import json
import re
import pytest

from tests.agentica_test import FIXTURES
from tests.spec_support import check_diagnostic as diagnostic, covered

GROUPS = json.loads((FIXTURES / "spec" / "checker-rest.json").read_text(encoding="utf-8"))

FIELDS = ("expected", "actual", "function", "callee")


def assert_case(case, tmp_path):
    text = "\n".join(case["program"])
    found = diagnostic(text, tmp_path)
    assert (found and found["code"]) == case["code"], text
    if found is None:
        return
    start = found["range"]["start"]
    if "start" in case:
        assert [start["line"], start["column"]] == case["start"], text
    if "covers" in case:
        assert covered(text, found["range"]) == case["covers"], text
    if "help" in case:
        assert bool(found.get("help")) == case["help"], text
    for field in FIELDS:
        if field in case:
            assert found.get(field) == case[field], text
    if "labels" in case:
        assert len(found.get("labels", [])) == case["labels"], text


def method_name(title):
    return "test_group_" + re.sub(r"[^a-z0-9]+", "_", title.lower()).strip("_")[:90]


def group_test(title, cases):
    def test(case, tmp_path):
        assert_case(case, tmp_path)

    test.__name__ = method_name(title)
    test.__doc__ = title
    return pytest.mark.parametrize(
        "case",
        cases,
        ids=[f"{title} [{index}]" for index in range(len(cases))],
    )(test)


for title, group_cases in GROUPS.items():
    name = method_name(title)
    assert name not in globals(), name
    globals()[name] = group_test(title, group_cases)
