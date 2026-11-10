"""The rest of the checker rules, through the product CLI.

tests/test_spec_checker.py has the cases about spans, pipes and the nesting limit. The other cases of the old
checker test are in tests/fixtures/spec/checker-rest.json: one list of programs for each rule group, in the
order of that file. Each program is written to a file of its own and one `--json check FILE...` call checks them all
(`check_many`: the diagnostic of a check of each file alone); each case keeps its own test id. A case says what the
check gives:

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
from tests.spec_support import check_many, covered

GROUPS = json.loads((FIXTURES / "spec" / "checker-rest.json").read_text(encoding="utf-8"))

FIELDS = ("expected", "actual", "function", "callee")


@pytest.fixture(scope="module")
def diagnostic(tmp_path_factory):
    programs = ["\n".join(case["program"]) for cases in GROUPS.values() for case in cases]
    return check_many(programs, tmp_path_factory.mktemp("checker-rest"), "program.agc")


def assert_case(case, diagnostic):
    text = "\n".join(case["program"])
    found = diagnostic(text)
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
    def test(case, diagnostic):
        assert_case(case, diagnostic)

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


def test_a_json_field_in_a_list_of_an_imported_struct_is_misplaced(agentica_check):
    """The CHECK-JSON-FIELD-PLACE walk follows a struct of another module, and reports at the target."""
    root = 'import Models from "models"\n\ndef main() -> Void\n  x = JSON.schema(Models.Patch)\nend\n'
    files = {
        "models.agc": "export struct Patch\n  ages: List[JsonField[Int]]\nend\n",
        "root.agc": root,
    }
    found = agentica_check(files, "root.agc")
    assert found is not None and found["code"] == "CHECK-JSON-FIELD-PLACE"
    assert covered(root, found["range"]) == "Models.Patch"
