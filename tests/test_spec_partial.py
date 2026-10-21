"""`--partial` of `agentica type-at` and `refs`: answers from a program in which some functions do not check
(docs/future/39-semantic-cli.md, 39.6). The cases read the JSON form and assert the marker, kinds, spans, the codes and
the exit codes, never message text; one case reads the text form."""
import json

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import end, problem, start, where

MODELS = '''export struct User
  name: String
  age: Int
end

export enum Shape
  Circle(Float)
  Square
end

export def make(name: String) -> User
  return User(name: name, age: 3)
end
'''

# `broken` does not check: `helper("no")` passes a String. The other functions do. Positions are found by text.
APP = '''import Models from "models"

def good(user: Models.User) -> Int
  return user.age + helper(2)
end

def helper(n: Int) -> Int
  return n * 2
end

def broken(user: Models.User) -> Int
  made = Models.make("x")
  shape = Models.Shape.Circle(1.0)
  count = user.age
  return helper("no") + count
end

def later() -> Int
  return helper(1)
end
'''

# The same program with the error fixed: what it answers is what a partial answer of `APP` says, outside `broken`.
FIXED = APP.replace('helper("no")', "helper(3)")

# A program whose declarations do not register (`main` has a parameter), so no function is checked at all.
UNREGISTERED = '''import Models from "models"

def main(x: Int) -> Int
  return 1
end

def other() -> Int
  return Models.make("a").age
end
'''


def asked(verb, position, *words, cwd, stdin=None, style="--json"):
    file, (line, column) = position
    return run(cli() + [style, verb, *words, f"{file}:{line}:{column}"], env=vm_environment(), cwd=cwd, stdin=stdin)


def answer(verb, position, *words, cwd, stdin=None):
    result = asked(verb, position, *words, cwd=cwd, stdin=stdin)
    assert (result.code, result.stderr) == (0, "")
    return json.loads(result.stdout)


def unmarked(report):
    """What a partial answer says besides its marker: the shape of the complete answer."""
    return {key: value for key, value in report.items() if key not in ("partial", "diagnostics")}


def places(report):
    return [(found["span"]["file"], *start(found["span"]), found["kind"], found["function"])
            for found in report["references"]]


@pytest.fixture
def program(tmp_path):
    (tmp_path / "models.agc").write_text(MODELS, encoding="utf-8")
    (tmp_path / "app.agc").write_text(APP, encoding="utf-8")
    (tmp_path / "fixed.agc").write_text(FIXED, encoding="utf-8")
    (tmp_path / "unregistered.agc").write_text(UNREGISTERED, encoding="utf-8")
    return tmp_path


def test_without_the_option_a_program_that_does_not_check_is_still_exit_1(program):
    for verb in ("type-at", "refs"):
        result = asked(verb, ("app.agc", where(APP, "helper(2)")), cwd=program)
        error = problem(result, "CHECK-TYPE-MISMATCH", 1)
        assert (error["file"], (error["range"]["start"]["line"], error["range"]["start"]["column"])) == (
            "app.agc", where(APP, '"no"'))


def test_a_position_in_a_function_that_checked_has_the_complete_answer_and_the_marker(program):
    for verb, spot in (("type-at", where(APP, "helper(2)")), ("type-at", where(APP, "user.age", 5)),
                       ("refs", where(APP, "helper(2)"))):
        partial = answer(verb, ("app.agc", spot), "--partial", cwd=program)
        assert partial["partial"] is True
        [error] = partial["diagnostics"]
        assert (error["code"], error["file"]) == ("CHECK-TYPE-MISMATCH", "app.agc")
        assert (error["range"]["start"]["line"], error["range"]["start"]["column"]) == where(APP, '"no"')
        # Outside the failing function the complete answer is that of the fixed program, positions included.
        if verb == "type-at":
            whole = answer(verb, ("fixed.agc", spot), cwd=program)
            assert whole["type"] != ""
            assert json.dumps(unmarked(partial)).replace("app.agc", "fixed.agc") == json.dumps(whole)


def test_a_name_in_a_function_that_did_not_check_is_answered_by_its_definition_without_a_type(program):
    function = answer("type-at", ("app.agc", where(APP, 'helper("no")')), "--partial", cwd=program)
    assert (function["partial"], function["kind"], function["type"], function["text"]) == (
        True, "name", None, "helper")
    assert start(function["span"]) == where(APP, 'helper("no")')
    assert end(function["span"]) == where(APP, 'helper("no")', 6)
    definition = function["definition"]
    assert (definition["kind"], definition["name"], definition["signature"]) == (
        "function", "helper", "helper(n: Int) -> Int")
    assert start(definition["name_span"]) == where(APP, "def helper", 4)
    # A qualified function, a variant and the enum of a variant: the written name is the span, whatever the alias.
    make = answer("type-at", ("app.agc", where(APP, "Models.make", 7)), "--partial", cwd=program)
    assert (make["definition"]["kind"], make["definition"]["file"], make["text"]) == (
        "function", "models.agc", "Models.make")
    circle = answer("type-at", ("app.agc", where(APP, "Circle(1.0)")), "--partial", cwd=program)
    assert (circle["definition"]["kind"], circle["definition"]["name"], circle["text"]) == (
        "variant", "Circle", "Circle")
    shape = answer("type-at", ("app.agc", where(APP, "Shape.Circle", 2)), "--partial", cwd=program)
    assert (shape["definition"]["kind"], shape["text"]) == ("enum", "Models.Shape")
    # The definition of a partial answer can be asked back: it names itself.
    own = answer("refs", ("app.agc", start(function["definition"]["name_span"])), "--partial", cwd=program)
    assert own["definition"]["name_span"] == function["definition"]["name_span"]
    assert ("app.agc", *start(function["span"]), "call", "broken") in places(own)


def test_a_position_that_the_link_cannot_answer_is_the_first_problem(program):
    # A field and a local of the failed function need its types; so does a blank.
    for spot in (where(APP, "user.age\n  return", 5), where(APP, "+ count", 2), where(APP, "def broken")):
        result = asked("type-at", ("app.agc", spot), "--partial", cwd=program)
        assert problem(result, "CHECK-TYPE-MISMATCH", 1)["file"] == "app.agc"


def test_references_of_a_function_are_complete_even_in_the_function_that_did_not_check(program):
    report = answer("refs", ("app.agc", where(APP, "def helper", 4)), "--partial", cwd=program)
    assert report["partial"] is True and [error["code"] for error in report["diagnostics"]] == ["CHECK-TYPE-MISMATCH"]
    assert (report["definition"]["kind"], report["definition"]["name"]) == ("function", "helper")
    assert places(report) == [
        ("app.agc", *where(APP, "helper(2)"), "call", "good"),
        ("app.agc", *where(APP, 'helper("no")'), "call", "broken"),
        ("app.agc", *where(APP, "helper(1)"), "call", "later"),
    ]
    # From a reference the definition and the references are the same, the question aside.
    from_use = answer("refs", ("app.agc", where(APP, 'helper("no")')), "--partial", cwd=program)
    assert (from_use["definition"], from_use["references"]) == (report["definition"], report["references"])
    # A struct and an enum are found in the annotations and constructions of the function that did not check as well.
    user = answer("refs", ("app.agc", where(APP, "Models.User", 7)), "--partial", cwd=program)
    assert (user["definition"]["kind"], user["partial"]) == ("struct", True)
    assert [use["function"] for use in user["references"]] == ["good", "broken", "make", "make"]
    shape = answer("refs", ("app.agc", where(APP, "Shape.Circle", 2)), "--partial", cwd=program)
    assert (shape["definition"]["kind"], [use["kind"] for use in shape["references"]]) == ("enum", ["construct"])


def test_a_local_of_a_function_that_checked_is_answered_and_a_field_or_a_builtin_is_the_first_problem(program):
    local = answer("refs", ("app.agc", where(APP, "user: Models.User", 0)), "--partial", cwd=program)
    assert (local["partial"], local["definition"]["kind"], [use["kind"] for use in local["references"]]) == (
        True, "parameter", ["binding"])
    for spot in (where(APP, "user.age", 5), where(APP, "count =")):
        result = asked("refs", ("app.agc", spot), "--partial", cwd=program)
        assert problem(result, "CHECK-TYPE-MISMATCH", 1)["file"] == "app.agc"


def test_a_program_that_checks_gives_the_same_bytes_with_or_without_the_option(program):
    for verb, spot in (("type-at", where(FIXED, "helper(2)")), ("refs", where(FIXED, "def helper", 4)),
                       ("type-at", where(FIXED, "user.age", 5))):
        plain = asked(verb, ("fixed.agc", spot), cwd=program)
        marked = asked(verb, ("fixed.agc", spot), "--partial", cwd=program)
        assert (plain.code, plain.stderr, marked.code, marked.stderr) == (0, "", 0, "")
        assert marked.stdout == plain.stdout
        assert "partial" not in json.loads(plain.stdout)


def test_declarations_that_do_not_register_leave_the_names_of_the_link(program):
    report = answer("type-at", ("unregistered.agc", where(UNREGISTERED, "Models.make", 7)), "--partial", cwd=program)
    assert (report["partial"], report["type"], report["definition"]["kind"]) == (True, None, "function")
    [error] = report["diagnostics"]
    assert (error["code"], error["file"], error["range"]["start"]["line"]) == ("CHECK-MAIN", "unregistered.agc", 3)
    refs = answer("refs", ("unregistered.agc", where(UNREGISTERED, "def other", 4)), "--partial", cwd=program)
    assert (refs["partial"], refs["references"]) == (True, [])


def test_a_problem_in_an_import_marks_the_answers_of_the_file_asked(program):
    (program / "models.agc").write_text(MODELS + "\ndef wrong() -> Int\n  return \"a\"\nend\n", encoding="utf-8")
    report = answer("type-at", ("fixed.agc", where(FIXED, "helper(2)")), "--partial", cwd=program)
    [error] = report["diagnostics"]
    # A problem outside the file asked about names that file by its canonical path, as the checker's do.
    assert (report["partial"], error["code"], error["file"].endswith("models.agc")) == (True, "CHECK-TYPE-MISMATCH", True)


def test_text_form_prints_the_answer_and_one_line_per_problem_on_stderr(program):
    result = asked("type-at", ("app.agc", where(APP, 'helper("no")')), "--partial", cwd=program, style="--ai")
    line, column = where(APP, 'helper("no")')
    assert result.code == 0
    assert result.stdout.splitlines()[0] == f"app.agc:{line}:{column}-{line}:{column + 6} helper: ?"
    assert result.stdout.splitlines()[1].endswith(" function helper")
    [note] = result.stderr.splitlines()
    mistake = where(APP, '"no"')
    assert note == f"partial app.agc:{mistake[0]}:{mistake[1]}: CHECK-TYPE-MISMATCH"


def test_a_program_that_does_not_link_or_parse_is_still_exit_1_and_outline_does_not_change(program):
    (program / "lexed.agc").write_text("def f(\n", encoding="utf-8")
    (program / "unlinked.agc").write_text('import Nowhere from "./nowhere"\n\ndef f() -> Int\n  return 1\nend\n',
                                           encoding="utf-8")
    for verb in ("type-at", "refs"):
        assert problem(asked(verb, ("lexed.agc", (1, 1)), "--partial", cwd=program), "LEX-UNCLOSED-DELIMITER", 1)
        assert problem(asked(verb, ("unlinked.agc", (3, 5)), "--partial", cwd=program), "CHECK-IMPORT-IO", 1)
    # `outline` only parses, so it takes the option and answers as it did: a file that does not check, then one that
    # does not parse.
    plain = run(cli() + ["--json", "outline", "unlinked.agc"], env=vm_environment(), cwd=program)
    marked = run(cli() + ["--json", "outline", "--partial", "unlinked.agc"], env=vm_environment(), cwd=program)
    assert (marked.code, marked.stdout, marked.stderr) == (plain.code, plain.stdout, plain.stderr) and plain.code == 0
    broken = run(cli() + ["--json", "outline", "--partial", "lexed.agc"], env=vm_environment(), cwd=program)
    assert problem(broken, "LEX-UNCLOSED-DELIMITER", 1)


def test_the_buffer_on_standard_input_is_answered_partially_and_symbol_has_no_such_option(program):
    result = run(cli() + ["--json", "type-at", "--partial", "--stdin", f"app.agc:{where(APP, 'helper(1)')[0]}:{where(APP, 'helper(1)')[1]}"], env=vm_environment(),
                 cwd=program, stdin=APP)
    report = json.loads(result.stdout)
    assert (result.code, report["partial"], report["definition"]["name"]) == (0, True, "helper")
    result = run(cli() + ["--json", "symbol", "--partial", "helper"], env=vm_environment(), cwd=program)
    assert problem(result, "QUERY-USAGE", 2)["file"] == "<arguments>"
