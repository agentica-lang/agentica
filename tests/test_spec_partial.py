"""`--partial` of `agentica type-at` and `refs`: answers from a program in which some functions do not check
(docs/future/39-semantic-cli.md, 39.6). The cases read the JSON form and assert the marker, kinds, spans, the codes and
the exit codes, never message text; one case reads the text form."""
import json

import pytest

from tests.agentica_test import cli, compile_agc, run, run_vm, vm_environment
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

# Programs whose declarations (a constant, a field type, `main`) do not check: no function is checked at all, so there is
# nothing to answer from beyond the first problem.
BAD_DECLARATIONS = {
    "constant.agc": ('LIMIT: Int = "s"\n\ndef other() -> Int\n  return 1\nend\n', "CHECK-TYPE-MISMATCH"),
    "field.agc": ("struct S\n  a: Nope\nend\n\ndef other() -> Int\n  return 1\nend\n", "CHECK-UNKNOWN-TYPE"),
    "main.agc": ("def main(x: Int) -> Void\n  puts(x)\nend\n\ndef other() -> Int\n  return 1\nend\n", "CHECK-MAIN"),
}

# Two failing functions (the second inside nested blocks) and a function that calls the first one, which checks since
# only the signature of what it calls matters.
MANY = '''def first(n: Int) -> Int
  return n
end

def one() -> Int
  return first("a")
end

def calls_one() -> Int
  return one() + 1
end

def two(flag: Bool) -> Int
  if flag
    total = 0
    while total < 3
      total = total + "b"
    end
  end
  return first(2)
end
'''

# A small program that checks, to ask about every position of.
SMALL = '''import Models from "models"

def total(user: Models.User) -> Int
  return user.age + 1
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
    (tmp_path / "many.agc").write_text(MANY, encoding="utf-8")
    (tmp_path / "small.agc").write_text(SMALL, encoding="utf-8")
    for name, (text, _) in BAD_DECLARATIONS.items():
        (tmp_path / name).write_text(text, encoding="utf-8")
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


def test_a_position_on_no_expression_is_told_from_a_broken_program_when_the_parse_can_tell(program):
    # A blank line, an import line and the gap between functions are on no expression; so is a parameter annotation of
    # a function that checked, as in a program that checks. A token of a failed function that the link cannot name
    # could be an expression, so it is the first problem.
    annotation = where(APP, "Models.User) -> Int", 2)
    for verb in ("type-at", "refs"):
        for spot in ((2, 1), where(APP, "import"), where(APP, "end\n\ndef helper", 3), annotation):
            result = asked(verb, ("app.agc", spot), "--partial", cwd=program)
            assert problem(result, "QUERY-NO-EXPRESSION", 2)["file"] == "app.agc"
        inside = asked(verb, ("app.agc", where(APP, "return helper(\"no\")")), "--partial", cwd=program)
        assert problem(inside, "CHECK-TYPE-MISMATCH", 1)["file"] == "app.agc"
    whole = asked("type-at", ("fixed.agc", annotation), cwd=program)
    assert problem(whole, "QUERY-NO-EXPRESSION", 2)["range"] == problem(
        asked("type-at", ("app.agc", annotation), "--partial", cwd=program), "QUERY-NO-EXPRESSION", 2)["range"]


@pytest.mark.parametrize("name", sorted(BAD_DECLARATIONS))
def test_declarations_that_do_not_check_are_the_first_problem_with_or_without_the_option(program, name):
    code = BAD_DECLARATIONS[name][1]
    line, column = where(BAD_DECLARATIONS[name][0], "other", 4)
    for verb in ("type-at", "refs"):
        plain = problem(asked(verb, (name, (line, column)), cwd=program), code, 1)
        partial = problem(asked(verb, (name, (line, column)), "--partial", cwd=program), code, 1)
        assert partial == plain


def test_two_failed_functions_are_two_diagnostics_in_program_order_and_a_caller_of_one_still_checks(program):
    spot = ("many.agc", where(MANY, "one() + 1"))
    report = answer("type-at", spot, "--partial", cwd=program)
    assert (report["partial"], report["type"], report["definition"]["name"]) == (True, "Int", "one")
    codes = [(error["code"], error["range"]["start"]["line"]) for error in report["diagnostics"]]
    assert [line for _, line in codes] == [where(MANY, '"a"')[0], where(MANY, '"b"')[0]]
    assert all(code.startswith("CHECK-") for code, _ in codes)
    assert all(error["file"] == "many.agc" for error in report["diagnostics"])
    # Without the option the first of them is the answer.
    first = problem(asked("type-at", spot, cwd=program), codes[0][0], 1)
    assert first["range"] == report["diagnostics"][0]["range"]
    # The calls of `one` are those of the function that checked; the failed nested function gives the first problem for
    # a local, and a name in it from the link.
    uses = answer("refs", ("many.agc", where(MANY, "def one", 4)), "--partial", cwd=program)
    assert places(uses) == [("many.agc", *where(MANY, "one() + 1"), "call", "calls_one")]
    nested = answer("type-at", ("many.agc", where(MANY, "first(2)")), "--partial", cwd=program)
    assert (nested["definition"]["name"], nested["type"], len(nested["diagnostics"])) == ("first", None, 2)
    local = asked("type-at", ("many.agc", where(MANY, "total < 3")), "--partial", cwd=program)
    assert problem(local, codes[1][0], 1)["range"]["start"]["line"] == codes[1][1]
    assert answer("refs", ("many.agc", where(MANY, "def first", 4)), "--partial", cwd=program)["references"] != []


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc("tests/fixtures/analysis/driver.agc", tmp_path_factory.mktemp("agentica-partial-") / "driver.agcb")


def test_each_diagnostic_of_an_answer_is_read_back_by_the_library_as_the_same_object(program, driver):
    report = answer("type-at", ("many.agc", where(MANY, "one() + 1")), "--partial", cwd=program)
    assert len(report["diagnostics"]) == 2
    for number, diagnostic in enumerate(report["diagnostics"]):
        written = program / f"diagnostic{number}.json"
        written.write_text(json.dumps(diagnostic), encoding="utf-8")
        read = run_vm(driver, args=("diagnostic", str(written)), cwd=program, env=vm_environment())
        assert (read.code, read.stderr) == (0, "")
        assert json.loads(read.stdout) == diagnostic


def test_a_program_that_checks_gives_the_same_bytes_at_every_position_with_or_without_the_option(program):
    lines = SMALL.split("\n")
    for verb in ("type-at", "refs"):
        for line, text in enumerate(lines, 1):
            for column in range(1, len(text) + 2):
                plain = asked(verb, ("small.agc", (line, column)), cwd=program)
                marked = asked(verb, ("small.agc", (line, column)), "--partial", cwd=program)
                assert (marked.code, marked.stdout, marked.stderr) == (plain.code, plain.stdout, plain.stderr)
                assert plain.code in (0, 2)


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
    line, column = where(APP, "helper(1)")
    result = run(cli() + ["--json", "type-at", "--partial", "--stdin", f"app.agc:{line}:{column}"],
                 env=vm_environment(), cwd=program, stdin=APP)
    report = json.loads(result.stdout)
    assert (result.code, report["partial"], report["definition"]["name"]) == (0, True, "helper")
    result = run(cli() + ["--json", "symbol", "--partial", "helper"], env=vm_environment(), cwd=program)
    assert problem(result, "QUERY-USAGE", 2)["file"] == "<arguments>"


def test_the_buffer_on_standard_input_in_text_form_has_the_lines_and_the_note_of_the_buffer(program):
    # The file on the disk is fixed; the buffer is not, and the answer and the note are those of the buffer.
    (program / "app.agc").write_text(FIXED, encoding="utf-8")
    line, column = where(APP, "helper(1)")
    result = run(cli() + ["type-at", "--stdin", f"app.agc:{line}:{column}", "--partial"],
                 env=vm_environment(), cwd=program, stdin=APP)
    mistake = where(APP, '"no"')
    assert result.code == 0
    assert result.stdout.splitlines()[0].startswith(f"app.agc:{line}:{column}-{line}:{column + 6} helper: ?")
    assert result.stderr.splitlines() == [f"partial app.agc:{mistake[0]}:{mistake[1]}: CHECK-TYPE-MISMATCH"]
