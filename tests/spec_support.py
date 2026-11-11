"""Shared assertions for language-spec tests."""

import json
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path

import pytest

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


def _program_key(program: str | Mapping[str, str]) -> object:
    return program if isinstance(program, str) else tuple(sorted(program.items()))


# Windows refuses a command line over 32,767 characters (WinError 206); a few hundred temp paths pass it.
COMMAND_LINE_BUDGET = 16_000


def _command_lines(paths: list[str]) -> list[list[str]]:
    """Split PATHS into groups whose joined length stays under COMMAND_LINE_BUDGET."""
    groups: list[list[str]] = []
    size = COMMAND_LINE_BUDGET
    for path in paths:
        if size + len(path) + 1 > COMMAND_LINE_BUDGET:
            groups.append([])
            size = 0
        groups[-1].append(path)
        size += len(path) + 1
    return groups


def check_paths(paths: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> dict[str, object]:
    """`--json check` of PATHS in as few calls as the command-line budget allows: each path's diagnostic, or None."""
    found = {}
    for group in _command_lines(paths):
        result = run(cli() + ["--json", "check", *group], cwd=cwd, env=env)
        assert result.code in (0, 1), result.stderr
        if len(group) == 1:
            # One file gets the one-file form: the diagnostic on stderr, or {"ok":true} on stdout.
            assert result.code or result.stdout == '{"ok":true}\n', result.stdout
            found[group[0]] = json.loads(result.stderr) if result.code else None
        else:
            found.update({entry["file"]: entry.get("diagnostic") for entry in json.loads(result.stdout)["files"]})
    return found


def check_many(programs: Iterable[str | Mapping[str, str]], directory: Path, root: str = "main.agc") -> Check:
    """Check every program with one `--json check` call and return a Check that looks their diagnostics up.

    A program is its source text, or a map of file names to texts that holds ROOT. Each one goes in a folder of its
    own under DIRECTORY with the name ROOT and is listed as a root of its own, so it gets the diagnostic that a
    `--json check` of that file alone gives, file field included (tests/test_cli_check.py has the multi-file form).
    One process instead of one per case is most of the time saved (a few processes when the paths would pass the
    Windows command-line limit). The Check takes a program of the batch and ROOT,
    and gives its diagnostic or None; any other program is a KeyError. A program listed twice is checked once.
    """
    roots = {}
    for program in programs:
        key = _program_key(program)
        if key in roots:
            continue
        folder = directory / str(len(roots))
        files = {root: program} if isinstance(program, str) else program
        for name, text in files.items():
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        roots[key] = str(folder / root)
    found = check_paths(list(roots.values()))
    diagnostics = {key: found[path] for key, path in roots.items()}

    def check(program: str | Mapping[str, str], name: str = root) -> dict[str, object] | None:
        assert name == root, name
        return diagnostics[_program_key(program)]

    return check


class Batch:
    """The programs of the parametrized tables of a module, checked by one check_many call."""

    def __init__(self, root: str = "main.agc") -> None:
        self.root = root
        self.programs: list[str | Mapping[str, str]] = []

    def table(self, names, rows, program: object = "%s"):
        """`pytest.mark.parametrize(NAMES, ROWS)`, and the program of each row joins the batch.

        PROGRAM is a template that the first value of a row fills (by default that value is the program), or a
        function of the row's values. The test builds its program the same way and looks it up in the fixture.
        A row is a value or a tuple of values, never a `pytest.param`: that is a tuple of (values, marks, id), so
        PROGRAM would be built from the wrong values.
        """
        build = program if callable(program) else lambda first, *_: program % first
        self.programs.extend(build(*(row if isinstance(row, tuple) else (row,))) for row in rows)
        return pytest.mark.parametrize(names, rows)

    def fixture(self):
        """A module fixture, `checked`, that checks the batch and gives its Check."""
        @pytest.fixture(scope="module")
        def checked(tmp_path_factory):
            return check_many(self.programs, tmp_path_factory.mktemp("batch"), self.root)

        return checked


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


def assert_rule(found, program, code, text):
    """Assert a rule case: `found` is the diagnostic of `program` (None when it checks clean), `code` the expected code
    (None for a clean program) and `text` the source text its range must cover (None when the span is not asserted)."""
    assert (found and found["code"]) == code, program
    if text is not None:
        assert covered(program, found["range"]) == text


def covered(text, span):
    """Return the source text from a diagnostic range's start to its exclusive end."""
    lines = text.split("\n")

    def offset(point):
        return sum(len(line) + 1 for line in lines[:point["line"] - 1]) + point["column"] - 1

    return text[offset(span["start"]):offset(span["end"])]
