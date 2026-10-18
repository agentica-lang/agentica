"""Shared assertions for language-spec tests."""

import json
from collections.abc import Callable, Mapping
from pathlib import Path

from tests.agentica_test import cli, run

Check = Callable[[str | Mapping[str, str], str], dict[str, object] | None]
SpanAssertion = Callable[[str, dict[str, object], object], None]


def check_diagnostic(text: str, directory: Path) -> dict[str, object] | None:
    """Run `check` and return its JSON diagnostic, or None for a clean program."""
    path = directory / "program.agc"
    path.write_text(text, encoding="utf-8")
    result = run(cli() + ["--json", "check", str(path)])
    assert result.code in (0, 1), result.stderr
    return json.loads(result.stderr) if result.code else None


def assert_program_diagnostic(check: Check, program: str, code: str | None) -> dict[str, object] | None:
    """Check one-file source and assert its expected diagnostic code."""
    found = check(program, "program.agc")
    assert (found and found["code"]) == code, program
    return found


def assert_module_diagnostic(
    check: Check, files: Mapping[str, str], code: str | None, file: str | None
) -> dict[str, object] | None:
    """Check a multi-file source map and assert its diagnostic code and file suffix."""
    found = check(files, "root.agc")
    assert (found and found["code"]) == code, files
    if found is not None:
        assert file is not None
        assert found["file"].endswith(file), found["file"]
    return found


def assert_single_file_case(
    check: Check,
    program: str,
    code: str | None,
    expected_span: object,
    assert_span: SpanAssertion,
) -> None:
    """Assert a one-file diagnostic and delegate its span convention."""
    found = assert_program_diagnostic(check, program, code)
    if expected_span is not None:
        assert found is not None
        assert_span(program, found["range"], expected_span)


def assert_multi_file_case(
    check: Check,
    files: Mapping[str, str],
    code: str | None,
    file: str | None,
    expected_span: object,
    assert_span: SpanAssertion,
) -> None:
    """Assert a multi-file diagnostic and delegate its span convention."""
    found = assert_module_diagnostic(check, files, code, file)
    if found is not None:
        assert file is not None and expected_span is not None
        assert_span(files[file], found["range"], expected_span)


def assert_exact_span(source: str, span: dict[str, object], expected: object) -> None:
    """Assert a diagnostic covers exactly the expected source text."""
    assert covered(source, span) == expected


def covered(text, span):
    """Return the source text from a diagnostic range's start to its exclusive end."""
    lines = text.split("\n")

    def offset(point):
        return sum(len(line) + 1 for line in lines[:point["line"] - 1]) + point["column"] - 1

    return text[offset(span["start"]):offset(span["end"])]
