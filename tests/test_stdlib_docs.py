"""Every standard library module has a module doc and a doc on every export.

The check reads the source text, so it needs no front end: a doc block is a run of lines that start with `##`
(docs/grammar/04-lexical.md). The module doc is the first block of the file when only blank lines and `#` comments
come before it and a blank line follows it. An export is a top-level line that starts with `export`, and its doc is the
block on the lines directly above it. The parser rejects any other doc block (`PARSE-DETACHED-DOC`), which the
examples and goldens check.
"""
import re

from tests.agentica_test import ROOT, TestCase

STDLIB = ROOT / "stdlib"
EXPORT = re.compile(r"^export\s")


def doc_text(lines):
    """The text of a block of `##` lines."""
    return "\n".join(line.lstrip()[2:] for line in lines).strip()


def module_doc(lines):
    """The text of the module doc, or None when the file has none."""
    index = 0
    while index < len(lines) and (lines[index].strip() == "" or
                                  (lines[index].lstrip().startswith("#") and not lines[index].lstrip().startswith("##"))):
        index += 1
    start = index
    while index < len(lines) and lines[index].lstrip().startswith("##"):
        index += 1
    if index == start or index >= len(lines) or lines[index].strip() != "":
        return None
    return doc_text(lines[start:index])


def export_docs(lines):
    """[(line number, doc text or None)] for each top-level export."""
    found = []
    for number, line in enumerate(lines):
        if EXPORT.match(line):
            start = number
            while start > 0 and lines[start - 1].lstrip().startswith("##"):
                start -= 1
            found.append((number + 1, doc_text(lines[start:number]) if start < number else None))
    return found


class StdlibDocs(TestCase):
    def test_the_standard_library_has_files_to_check(self):
        self.assertGreaterEqual(len(sorted(STDLIB.rglob("*.agc"))), 9)

    def test_every_module_has_a_module_doc_and_a_doc_on_every_export(self):
        for file in sorted(STDLIB.rglob("*.agc")):
            name = str(file.relative_to(STDLIB))
            with self.subTest(name):
                lines = file.read_text(encoding="utf-8").split("\n")
                self.assertTrue(module_doc(lines), "%s: module doc" % name)
                for number, documented in export_docs(lines):
                    self.assertTrue(documented, "%s: line %d" % (name, number))
