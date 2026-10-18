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
import unittest

from tests.agentica_test import FIXTURES, TestCase
from tests.spec_support import covered, json_diagnostic

GROUPS = json.loads((FIXTURES / "spec" / "checker-rest.json").read_text(encoding="utf-8"))

FIELDS = ("expected", "actual", "function", "callee")


class SpecCheckerRestTest(TestCase):
    def setUp(self):
        self.work = self.make_temp_dir()

    def diagnostic(self, text):
        return json_diagnostic(self, self.work, text)

    def assert_case(self, case):
        text = "\n".join(case["program"])
        found = self.diagnostic(text)
        self.assertEqual(found and found["code"], case["code"], text)
        if found is None:
            return
        start = found["range"]["start"]
        if "start" in case:
            self.assertEqual([start["line"], start["column"]], case["start"], text)
        if "covers" in case:
            self.assertEqual(covered(text, found["range"]), case["covers"], text)
        if "help" in case:
            self.assertEqual(bool(found.get("help")), case["help"], text)
        for field in FIELDS:
            if field in case:
                self.assertEqual(found.get(field), case[field], text)
        if "labels" in case:
            self.assertEqual(len(found.get("labels", [])), case["labels"], text)


def group_test(cases):
    def test(self):
        for number, case in enumerate(cases):
            with self.subTest(case=number):
                self.assert_case(case)
    return test


def method_name(title):
    return "test_group_" + re.sub(r"[^a-z0-9]+", "_", title.lower()).strip("_")[:90]


for title, group_cases in GROUPS.items():
    name = method_name(title)
    assert not hasattr(SpecCheckerRestTest, name), name
    method = group_test(group_cases)
    method.__doc__ = title
    setattr(SpecCheckerRestTest, name, method)


if __name__ == "__main__":
    unittest.main()
