"""`agentica type-at` through the product CLI: the type and the definition at a position of a checked program
(docs/future/39-semantic-cli.md, 39.3 to 39.7). The cases read the JSON form and assert the type, the kind, the spans,
the codes and the exit codes, never message text; one case reads the text form."""
import json

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import end, problem, start

# The module the cases import: a struct, an enum with a payload and without, a function and a constant.
MODELS = '''## A user.
export struct User
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

# The file asked about. It has no `main`: `type-at` also answers for a library file. Positions are found by text with
# `where`, so a line added here does not move them.
ORDERS = '''import Models from "models"
import Queue from "std/queue"

LIMIT = 10

def total(user: Models.User) -> Int
  return user.age + 1
end

def build(names: List[String]) -> List[Models.User]
  made = Models.make("é😀 x")
  shape = Models.Shape.Circle(1.5)
  upper = names.map do |name: String| name.upcase end
  fixed = LIMIT. to_s
  pile = Queue.new()
  return [made]
end
'''


def where(source, needle, inside=0, nth=1):
    """The (line, column) of the character `inside` characters into the `nth` occurrence of `needle`."""
    at = -1
    for _ in range(nth):
        at = source.index(needle, at + 1)
    at += inside
    before = source[:at]
    return before.count("\n") + 1, at - (before.rfind("\n") + 1) + 1


def type_at(position, *words, cwd, stdin=None):
    file, (line, column) = position
    words = ["--json", "type-at", *words, f"{file}:{line}:{column}"]
    return run(cli() + words, env=vm_environment(), cwd=cwd, stdin=stdin)


def answer(position, *words, cwd, stdin=None):
    result = type_at(position, *words, cwd=cwd, stdin=stdin)
    assert (result.code, result.stderr) == (0, "")
    return json.loads(result.stdout)


@pytest.fixture
def program(tmp_path):
    (tmp_path / "models.agc").write_text(MODELS, encoding="utf-8")
    (tmp_path / "orders.agc").write_text(ORDERS, encoding="utf-8")
    return tmp_path


def test_an_expression_has_its_type_and_span_and_no_definition(program):
    report = answer(("orders.agc", where(ORDERS, "1\nend")), cwd=program)
    assert (report["version"], report["command"], report["kind"]) == (1, "type-at", "expression")
    assert (report["type"], report["text"], report["definition"]) == ("Int", "1", None)
    assert report["span"]["file"] == "orders.agc"
    assert start(report["span"]) == where(ORDERS, "1\nend") and end(report["span"]) == where(ORDERS, "1\nend", 1)
    line, column = start(report["span"])
    assert report["position"] == {"file": "orders.agc", "line": line, "column": column}
    # The position of an answer is a question: it can be asked back unchanged.
    assert answer((report["position"]["file"], (line, column)), cwd=program) == report


def test_the_name_of_a_field_access_is_the_whole_access_with_the_field_as_definition(program):
    on_name = answer(("orders.agc", where(ORDERS, "user.age", 5)), cwd=program)
    assert (on_name["kind"], on_name["type"], on_name["text"]) == ("name", "Int", "user.age")
    assert start(on_name["span"]) == where(ORDERS, "user.age") and end(on_name["span"]) == where(ORDERS, "user.age", 8)
    field = on_name["definition"]
    assert (field["kind"], field["name"], field["file"], field["name_span"]["file"]) == ("field", "age", "models.agc",
                                                                                      "models.agc")
    assert start(field["name_span"]) == where(MODELS, "age: Int")
    assert end(field["name_span"]) == where(MODELS, "age: Int", 3)
    assert start(field) == where(MODELS, "age: Int")
    # On the target, the answer is the target: a parameter, whose binding is not recorded yet.
    on_target = answer(("orders.agc", where(ORDERS, "user.age", 1)), cwd=program)
    assert (on_target["kind"], on_target["type"], on_target["text"]) == ("name", "Models.User", "user")
    assert on_target["definition"] is None


def test_a_method_call_is_a_name_on_its_method_and_a_builtin_has_no_definition(program):
    report = answer(("orders.agc", where(ORDERS, "name.upcase", 6)), cwd=program)
    assert (report["kind"], report["type"], report["text"]) == ("name", "String", "name.upcase")
    assert report["definition"] is None
    # A method with a block: the field access `names.map` became the call when the block was attached.
    block = answer(("orders.agc", where(ORDERS, "names.map", 7)), cwd=program)
    assert (block["kind"], block["type"]) == ("name", "List[String]")
    assert block["text"].startswith("names.map do |name: String|")
    # A member of a constant keeps the span of its member, whatever blanks stand around the dot.
    constant = answer(("orders.agc", where(ORDERS, "LIMIT. to_s", 8)), cwd=program)
    assert (constant["kind"], constant["type"], constant["text"]) == ("name", "String", "LIMIT. to_s")
    on_receiver = answer(("orders.agc", where(ORDERS, "LIMIT. to_s", 1)), cwd=program)
    assert (on_receiver["kind"], on_receiver["type"], on_receiver["definition"]["kind"]) == ("name", "Int", "constant")


def test_a_call_to_a_user_function_has_the_function_as_definition(program):
    report = answer(("orders.agc", where(ORDERS, "Models.make", 8)), cwd=program)
    assert (report["kind"], report["type"]) == ("name", "Models.User")
    definition = report["definition"]
    assert (definition["kind"], definition["name"], definition["file"]) == ("function", "make", "models.agc")
    assert start(definition["name_span"]) == where(MODELS, "make(name")
    assert start(definition) == where(MODELS, "def make")
    # The arguments are expressions of their own.
    argument = answer(("orders.agc", where(ORDERS, '"é😀 x"', 2)), cwd=program)
    assert (argument["kind"], argument["type"], argument["definition"]) == ("expression", "String", None)
    # A call into std/ names the embedded module.
    queue = answer(("orders.agc", where(ORDERS, "Queue.new", 6)), cwd=program)
    assert queue["type"] == "Queue.QueueState"
    assert (queue["definition"]["file"], queue["definition"]["kind"]) == ("std/queue.agc", "function")


def test_an_enum_variant_has_the_variant_as_definition(program):
    report = answer(("orders.agc", where(ORDERS, "Models.Shape.Circle(1.5)", 14)), cwd=program)
    assert (report["type"], report["text"]) == ("Models.Shape", "Models.Shape.Circle(1.5)")
    variant = report["definition"]
    assert (variant["kind"], variant["name"], variant["file"]) == ("variant", "Circle", "models.agc")
    assert start(variant["name_span"]) == where(MODELS, "Circle(Float)")
    # The payload is an expression inside the constructor.
    payload = answer(("orders.agc", where(ORDERS, "1.5")), cwd=program)
    assert (payload["type"], payload["kind"], payload["definition"]) == ("Float", "expression", None)


def test_an_imported_type_is_written_through_the_alias_of_the_file(program):
    assert answer(("orders.agc", where(ORDERS, "[made]", 1)), cwd=program)["type"] == "Models.User"
    assert answer(("orders.agc", where(ORDERS, "[made]")), cwd=program)["type"] == "List[Models.User]"
    # In its own file the same type has no alias.
    own = answer(("models.agc", where(MODELS, "User(name: name", 1)), cwd=program)
    assert (own["type"], own["definition"]["kind"]) == ("User", "struct")


def test_a_position_that_is_on_no_expression_is_query_no_expression_at_the_position(program):
    cases = {
        "a blank between tokens": (where(ORDERS, "user.age + 1", 8), 1),
        "a keyword": (where(ORDERS, "return user"), 1),
        "an import": (where(ORDERS, "import Models"), 1),
        "a declaration name": (where(ORDERS, "total(user"), 1),
    }
    for label, (position, width) in cases.items():
        diagnostic = problem(type_at(("orders.agc", position), cwd=program), "QUERY-NO-EXPRESSION", 2)
        line, column = position
        assert diagnostic["file"] == "orders.agc", label
        assert diagnostic["range"] == {
            "start": {"line": line, "column": column}, "end": {"line": line, "column": column + width},
        }, label


def test_past_the_end_of_a_line_or_of_the_file_the_span_is_that_end(program):
    last = ORDERS.count("\n")
    line_end = len("  return user.age + 1") + 1
    after_line = problem(type_at(("orders.agc", (7, line_end + 5)), cwd=program), "QUERY-NO-EXPRESSION", 2)
    assert after_line["range"]["start"] == after_line["range"]["end"] == {"line": 7, "column": line_end}
    on_break = problem(type_at(("orders.agc", (7, line_end)), cwd=program), "QUERY-NO-EXPRESSION", 2)
    assert on_break["range"]["start"] == {"line": 7, "column": line_end}
    after_file = problem(type_at(("orders.agc", (last + 40, 3)), cwd=program), "QUERY-NO-EXPRESSION", 2)
    # The text ends with a line feed, so the end of the file is the empty last line.
    assert after_file["range"]["start"] == after_file["range"]["end"] == {"line": last + 1, "column": 1}


def test_a_file_without_main_is_answered(program):
    assert answer(("models.agc", where(MODELS, "3)")), cwd=program)["type"] == "Int"


def test_the_buffer_on_standard_input_wins_over_the_file_on_the_disk(program):
    buffer = "def double(n: Int) -> Int\n  return n * 2\nend\n"
    report = answer(("orders.agc", (2, 12)), "--stdin", cwd=program, stdin=buffer)
    assert (report["type"], report["text"], report["position"]["file"]) == ("Int", "n * 2", "orders.agc")
    assert report["span"]["file"] == "orders.agc"
    # FILE need not exist, and the style may stand after the command.
    new = run(cli() + ["type-at", "--stdin", "new.agc:2:12", "--json"],
              env=vm_environment(), cwd=program, stdin=buffer)
    assert json.loads(new.stdout)["text"] == "n * 2"
    assert (program / "orders.agc").read_text(encoding="utf-8") == ORDERS
    # The buffer imports from the folder of FILE, and an error of the buffer is a diagnostic of FILE.
    imports = 'import Models from "models"\n\ndef f(u: Models.User) -> String\n  return u.name\nend\n'
    through = answer(("orders.agc", (4, 12)), "--stdin", cwd=program, stdin=imports)
    assert (through["type"], through["definition"]["file"]) == ("String", "models.agc")
    broken = type_at(("orders.agc", (1, 1)), "--stdin", cwd=program, stdin="def f() -> Int\n  return \"x\"\nend\n")
    assert problem(broken, "CHECK-TYPE-MISMATCH", 1)["file"] == "orders.agc"


def test_a_check_error_in_the_file_or_in_an_import_exits_1_with_its_code(program):
    (program / "bad.agc").write_text('def f() -> Int\n  return "x"\nend\n', encoding="utf-8")
    here = problem(type_at(("bad.agc", (2, 10)), cwd=program), "CHECK-TYPE-MISMATCH", 1)
    assert (here["file"], here["range"]["start"]["line"]) == ("bad.agc", 2)
    (program / "uses.agc").write_text('import Bad from "bad"\n\ndef g() -> Int\n  return 1\nend\n', encoding="utf-8")
    there = problem(type_at(("uses.agc", (4, 10)), cwd=program), "CHECK-TYPE-MISMATCH", 1)
    assert there["file"].endswith("bad.agc")
    (program / "lex.agc").write_text("def f(\n", encoding="utf-8")
    assert problem(type_at(("lex.agc", (1, 1)), cwd=program), "LEX-UNCLOSED-DELIMITER", 1)["file"] == "lex.agc"


def test_a_column_counts_the_characters_of_the_line_before_it(program):
    # `é` and the emoji are one character each, so the columns after them are the same as for ASCII.
    text = '"é😀 x"'
    report = answer(("orders.agc", where(ORDERS, text, 5)), cwd=program)
    assert (report["text"], report["type"]) == (text, "String")
    assert end(report["span"])[1] - start(report["span"])[1] == len(text)
    after = answer(("orders.agc", where(ORDERS, 'x")', 2)), cwd=program)
    assert (after["text"], after["type"]) == ('Models.make("é😀 x")', "Models.User")


def test_a_deep_expression_is_walked_without_recursion(tmp_path):
    depth = 480
    source = "def deep() -> Int\n  return " + "(1 + " * depth + "1" + ")" * depth + "\nend\n"
    (tmp_path / "deep.agc").write_text(source, encoding="utf-8")
    report = answer(("deep.agc", (2, 10 + 5 * depth)), cwd=tmp_path)
    assert (report["text"], report["type"]) == ("1", "Int")


@pytest.mark.parametrize("words", [
    [],  # missing position
    ["orders.agc"],  # a file, not a position
    ["orders.agc:3"],  # no column
    ["orders.agc:x:3"],  # a line that is not a number
    ["orders.agc:3:y"],  # a column that is not a number
    ["orders.agc:0:3"],  # lines start at 1
    ["orders.agc:3:0"],  # columns start at 1
    ["orders.agc:-1:3"],  # a sign is not a digit
    ["orders.agc:3:99999999999"],  # more digits than a position has
    [":3:4"],  # no file
    ["orders.agc:3:4", "extra"],  # extra argument
    ["--stdin"],  # --stdin without a position
    ["--stdin", "--json"],  # an option is not the position of --stdin
    ["--stdin", "orders.agc"],  # --stdin with a file only
    ["--stdin", "orders.agc:3:4", "orders.agc:3:4"],  # a position beside --stdin
    ["--unknown", "orders.agc:3:4"],  # unknown option
    ["absent.agc:1:1"],  # unreadable file
    [".:1:1"],  # a folder is not a file
])
def test_a_mistake_in_the_question_is_query_usage_at_the_arguments(program, words):
    result = run(cli() + ["--json", "type-at", *words], env=vm_environment(), cwd=program, stdin="")
    diagnostic = problem(result, "QUERY-USAGE", 2)
    assert diagnostic["file"] == "<arguments>"
    assert diagnostic["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 1}}


def test_text_form_gives_the_span_the_text_the_type_and_the_definition(program):
    position = where(ORDERS, "user.age", 5)
    result = run(cli() + ["type-at", f"orders.agc:{position[0]}:{position[1]}"], env=vm_environment(), cwd=program)
    assert (result.code, result.stderr) == (0, "")
    line, column = where(ORDERS, "user.age")
    assert result.stdout.split("\n") == [
        f"orders.agc:{line}:{column}-{line}:{column + 8} user.age: Int",
        f"models.agc:{where(MODELS, 'age: Int')[0]}:{where(MODELS, 'age: Int')[1]} field age",
        "",
    ]
