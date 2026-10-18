"""Shared CLI helpers for language-spec tests."""

import json
import pathlib
import unittest
from collections import namedtuple

from tests.agentica_test import cli, run

Starts = namedtuple("Starts", "text")


def covered(text: str, span: dict) -> str:
    """Return the source text from a diagnostic range's start to its exclusive end."""
    lines = text.split("\n")

    def offset(point: dict) -> int:
        return sum(len(line) + 1 for line in lines[:point["line"] - 1]) + point["column"] - 1

    return text[offset(span["start"]):offset(span["end"])]


def assert_span_covers(
    test_case: unittest.TestCase,
    program: str,
    span: dict,
    expected: str | Starts,
    *,
    trim_newline: bool = False,
) -> None:
    """Assert a diagnostic range covers expected text or starts with its prefix."""
    seen = covered(program, span)
    if isinstance(expected, Starts):
        test_case.assertTrue(seen.startswith(expected.text), seen)
    elif trim_newline:
        test_case.assertEqual(seen.rstrip("\n"), expected)
    else:
        test_case.assertEqual(seen, expected)


def assert_single_file_cases(
    test_case: unittest.TestCase,
    cases: list,
    diagnostic,
    *,
    trim_newline: bool = False,
) -> None:
    """Assert the diagnostic contract for each one-file language case."""
    for title, program, code, text in cases:
        with test_case.subTest(title):
            found = diagnostic({"program.agc": program})
            test_case.assertEqual(found and found["code"], code, program)
            if text is not None:
                assert_span_covers(
                    test_case, program, found["range"], text, trim_newline=trim_newline
                )


def assert_module_cases(
    test_case: unittest.TestCase,
    cases: list,
    diagnostic,
    *,
    trim_newline: bool = False,
) -> None:
    """Assert diagnostics for language cases spread across imported files."""
    for title, files, code, file, text in cases:
        with test_case.subTest(title):
            test_case.work = test_case.make_temp_dir()
            found = diagnostic(files, "root.agc")
            test_case.assertEqual(found and found["code"], code, files)
            if found is None:
                continue
            test_case.assertTrue(found["file"].endswith(file), found["file"])
            assert_span_covers(
                test_case,
                files[file],
                found["range"],
                text,
                trim_newline=trim_newline,
            )


def json_diagnostic(
    test_case: unittest.TestCase,
    work: pathlib.Path,
    text: str,
    name: str = "program.agc",
) -> dict | None:
    """Check one source file and return its JSON diagnostic, if any."""
    return json_diagnostic_files(test_case, work, {name: text}, name)


def json_diagnostic_files(
    test_case: unittest.TestCase,
    work: pathlib.Path,
    files: dict[str, str],
    root: str = "program.agc",
) -> dict | None:
    """Check source files with the CLI and return the root's JSON diagnostic, if any."""
    for name, text in files.items():
        path = work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    result = run(cli() + ["--json", "check", str(work / root)])
    if result.code == 0:
        return None
    test_case.assertEqual(result.code, 1, result.stderr)
    return json.loads(result.stderr)
