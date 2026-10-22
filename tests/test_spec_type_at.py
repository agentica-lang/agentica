"""`agentica type-at` through the product CLI: the type and the definition at a position of a checked program
(docs/future/39-semantic-cli.md, 39.3 to 39.7). The cases read the JSON form and assert the type, the kind, the spans,
the codes and the exit codes, never message text; one case reads the text form."""
import json
import os

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import end, problem, start, where

# The module the cases import: a struct, an enum with a payload and without, a function and a constant.
MODELS = '''## A user.
export struct User
  ## The name.
  name: String
  age: Int
end

export enum Shape
  ## A round one.
  Circle(Float)
  Square
end

export enum Slot[T]
  Full(T)
  Empty
end

## Makes a user.
##
## The age is 3.
export def make(name: String) -> User
  return User(name: name, age: 3)
end
'''

# The file asked about. It has no `main`: `type-at` also answers for a library file. Positions are found by text with
# `where`, so a line added here does not move them.
ORDERS = '''import Models from "models"
import Queue from "std/queue"

## The cap.
LIMIT = 10
NAMES = ["a", "b"]

def total(user: Models.User) -> Int
  return user.age + 1
end

def build(names: List[String]) -> List[Models.User]
  made = Models.make("é😀 x")
  shape = Models.Shape.Circle(1.5)
  upper = names.map do |name: String| name.upcase end
  fixed = LIMIT. to_s
  pile = Queue.new()
  built = Models.User(name: "n", age: 1)
  slot = Models.Slot.Full(made)
  count = NAMES
    .size
  table = {"a": 1}
  found = table.get("a")
  puts(count)
  return [made]
end
'''


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
    # On the target, the answer is the target: a parameter, whose binding is the definition.
    on_target = answer(("orders.agc", where(ORDERS, "user.age", 1)), cwd=program)
    assert (on_target["kind"], on_target["type"], on_target["text"]) == ("name", "Models.User", "user")
    assert (on_target["definition"]["kind"], on_target["definition"]["file"]) == ("parameter", "orders.agc")
    assert start(on_target["definition"]["name_span"]) == where(ORDERS, "user: Models.User")


def test_a_method_call_is_a_name_on_its_method_and_a_builtin_has_no_definition(program):
    report = answer(("orders.agc", where(ORDERS, "name.upcase", 6)), cwd=program)
    assert (report["kind"], report["type"], report["text"]) == ("builtin", "String", "name.upcase")
    assert report["definition"] is None
    # A method with a block: the field access `names.map` became the call when the block was attached.
    block = answer(("orders.agc", where(ORDERS, "names.map", 7)), cwd=program)
    assert (block["kind"], block["type"]) == ("builtin", "List[String]")
    assert block["text"].startswith("names.map do |name: String|")
    # A member of a constant keeps the span of its member, whatever blanks stand around the dot.
    constant = answer(("orders.agc", where(ORDERS, "LIMIT. to_s", 8)), cwd=program)
    # `to_s` on an Int is the builtin that the checker resolved it to.
    assert (constant["kind"], constant["type"], constant["text"]) == ("builtin", "String", "LIMIT. to_s")
    assert constant["help"]["name"] == "String.from_int"
    on_receiver = answer(("orders.agc", where(ORDERS, "LIMIT. to_s", 1)), cwd=program)
    assert (on_receiver["kind"], on_receiver["type"], on_receiver["definition"]["kind"]) == ("name", "Int", "constant")
    # A dot that starts the next line: the member is a name on its own line, and the dot before it is not.
    leading = answer(("orders.agc", where(ORDERS, ".size", 1)), cwd=program)
    assert (leading["kind"], leading["type"], leading["text"]) == ("builtin", "Int", "NAMES\n    .size")
    assert leading["help"]["name"] == "List.size"
    assert end(leading["span"]) == where(ORDERS, ".size", 5)
    on_dot = answer(("orders.agc", where(ORDERS, ".size")), cwd=program)
    assert (on_dot["kind"], on_dot["type"]) == ("expression", "Int")


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


def test_a_constant_and_a_struct_have_their_declaration_as_definition(program):
    constant = answer(("orders.agc", where(ORDERS, "NAMES\n", 2)), cwd=program)
    assert (constant["kind"], constant["type"], constant["text"]) == ("name", "List[String]", "NAMES")
    declared = constant["definition"]
    assert (declared["kind"], declared["name"], declared["file"]) == ("constant", "NAMES", "orders.agc")
    assert start(declared["name_span"]) == where(ORDERS, "NAMES = ")
    assert end(declared["name_span"]) == where(ORDERS, "NAMES = ", 5)
    # A construction through the alias of the import names the struct, whose type is written with that alias.
    built = answer(("orders.agc", where(ORDERS, "Models.User(name", 8)), cwd=program)
    assert (built["kind"], built["type"]) == ("name", "Models.User")
    struct = built["definition"]
    assert (struct["kind"], struct["name"], struct["file"]) == ("struct", "User", "models.agc")
    assert start(struct["name_span"]) == where(MODELS, "User\n")
    assert start(struct) == where(MODELS, "struct User")


def test_a_generic_enum_of_an_imported_file_is_written_through_the_alias_in_its_arguments(program):
    report = answer(("orders.agc", where(ORDERS, "Models.Slot.Full", 13)), cwd=program)
    assert (report["type"], report["text"]) == ("Models.Slot[Models.User]", "Models.Slot.Full(made)")
    variant = report["definition"]
    assert (variant["kind"], variant["name"], variant["file"]) == ("variant", "Full", "models.agc")


def test_an_absolute_path_with_a_drive_colon_is_the_file_and_is_answered_back(program):
    file = str(program / "orders.agc")
    line, column = where(ORDERS, "user.age", 5)
    report = answer((file, (line, column)), cwd=program)
    assert (report["kind"], report["type"], report["text"]) == ("name", "Int", "user.age")
    # The files of the answer are printed as `check` prints them (relative to the folder when below it), so they are
    # not compared whole; the import of the file is found beside it all the same.
    assert (report["position"]["line"], report["position"]["column"]) == (line, column)
    assert report["position"]["file"].endswith("orders.agc") and report["span"]["file"].endswith("orders.agc")
    assert (report["definition"]["name"], report["definition"]["file"].endswith("models.agc")) == ("age", True)


@pytest.mark.skipif(os.name == "nt", reason="host-only: Windows forbids a colon in a file name")
def test_a_file_name_with_a_colon_is_the_file_since_the_last_two_colons_end_it(tmp_path):
    (tmp_path / "a:b.agc").write_text("def f() -> Int\n  return 12\nend\n", encoding="utf-8")
    report = answer(("a:b.agc", (2, 10)), cwd=tmp_path)
    assert (report["type"], report["text"], report["position"]["file"]) == ("Int", "12", "a:b.agc")
    assert report["span"]["file"] == "a:b.agc"


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


def test_a_keyword_of_an_expression_answers_it_and_a_heredoc_body_only_by_its_interpolation(tmp_path):
    source = ("def f(n: Int, flag: Bool, r: Result[Int]) -> Result[String]\n  v = try r\n  w = !flag\n  both = flag and flag\n"
              "  text = <<~TXT\n    hello #{n} world\n    second\n  TXT\n  return ok(text)\nend\n")
    (tmp_path / "k.agc").write_text(source, encoding="utf-8")
    on_try = answer(("k.agc", where(source, "try r")), cwd=tmp_path)
    assert (on_try["text"], on_try["type"]) == ("try r", "Int")
    assert answer(("k.agc", where(source, "and flag", 1)), cwd=tmp_path)["text"] == "flag and flag"
    assert answer(("k.agc", where(source, "!flag")), cwd=tmp_path)["text"] == "!flag"
    for needle in ("return ok", "end\n", "hello", "second"):
        problem(type_at(("k.agc", where(source, needle)), cwd=tmp_path), "QUERY-NO-EXPRESSION", 2)
    interpolated = answer(("k.agc", where(source, "#{n}", 2)), cwd=tmp_path)
    assert (interpolated["text"], interpolated["type"]) == ("n", "Int")


def test_past_the_end_of_a_line_or_of_the_file_the_span_is_that_end(program):
    last = ORDERS.count("\n")
    row = where(ORDERS, "user.age + 1")[0]
    line_end = len("  return user.age + 1") + 1
    after_line = problem(type_at(("orders.agc", (row, line_end + 5)), cwd=program), "QUERY-NO-EXPRESSION", 2)
    assert after_line["range"]["start"] == after_line["range"]["end"] == {"line": row, "column": line_end}
    on_break = problem(type_at(("orders.agc", (row, line_end)), cwd=program), "QUERY-NO-EXPRESSION", 2)
    assert on_break["range"]["start"] == {"line": row, "column": line_end}
    after_file = problem(type_at(("orders.agc", (last + 40, 3)), cwd=program), "QUERY-NO-EXPRESSION", 2)
    # The text ends with a line feed, so the end of the file is the empty last line.
    assert after_file["range"]["start"] == after_file["range"]["end"] == {"line": last + 1, "column": 1}


def test_a_file_without_main_is_answered(program):
    assert answer(("models.agc", where(MODELS, "3)")), cwd=program)["type"] == "Int"


def test_a_main_with_a_wrong_signature_is_check_main_at_its_def(program):
    (program / "wrong.agc").write_text("def main(x: Int) -> Void\nend\n", encoding="utf-8")
    failed = problem(type_at(("wrong.agc", (1, 1)), cwd=program), "CHECK-MAIN", 1)
    assert (start(failed), failed["file"]) == ((1, 1), "wrong.agc")


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


def cli_help(name):
    """The object of `agentica help NAME --json`."""
    result = run(cli() + ["help", name, "--json"], env=vm_environment())
    assert (result.code, result.stderr) == (0, "")
    return json.loads(result.stdout)


def test_a_definition_carries_its_doc_and_signature(program):
    # A function: the full text of the `##` block on its `export`, blank line included, and its signature.
    made = answer(("orders.agc", where(ORDERS, "Models.make", 8)), cwd=program)["definition"]
    assert made["doc"] == "Makes a user.\n\nThe age is 3."
    assert made["signature"] == "make(name: String) -> User"
    # A struct, a field, a variant and a constant; what has no `##` text has a null doc, and every kind has a signature.
    struct = answer(("orders.agc", where(ORDERS, "Models.User(name", 8)), cwd=program)["definition"]
    assert (struct["doc"], struct["signature"]) == ("A user.", "struct User")
    undocumented = answer(("orders.agc", where(ORDERS, "user.age", 5)), cwd=program)["definition"]
    assert (undocumented["kind"], undocumented["doc"], undocumented["signature"]) == ("field", None, "age: Int")
    variant = answer(("orders.agc", where(ORDERS, "Models.Shape.Circle(1.5)", 14)), cwd=program)["definition"]
    assert (variant["doc"], variant["signature"]) == ("A round one.", "Circle(Float)")
    constant = answer(("orders.agc", where(ORDERS, "NAMES\n", 2)), cwd=program)["definition"]
    assert (constant["doc"], constant["signature"]) == (None, "NAMES")
    capped = answer(("orders.agc", where(ORDERS, "LIMIT. to_s", 1)), cwd=program)["definition"]
    assert (capped["doc"], capped["signature"]) == ("The cap.", "LIMIT")


def test_the_doc_of_a_field_is_read_from_the_struct_that_the_target_names(program):
    source = ORDERS + "\ndef label(user: Models.User) -> String\n  return user.name\nend\n"
    (program / "orders.agc").write_text(source, encoding="utf-8")
    field = answer(("orders.agc", where(source, "user.name", 6)), cwd=program)["definition"]
    assert (field["kind"], field["doc"], field["signature"]) == ("field", "The name.", "name: String")


def test_a_builtin_is_answered_with_its_help_object_and_no_definition(program):
    report = answer(("orders.agc", where(ORDERS, "name.upcase", 6)), cwd=program)
    assert (report["kind"], report["definition"]) == ("builtin", None)
    # The same object as `agentica help NAME --json`, name included.
    assert report["help"] == cli_help("String.upcase")
    assert report["help"]["name"] == "String.upcase"
    assert report["help"]["ruby"] == "s.upcase() -> String"
    # A builtin with two forms answers with its overloads; the bare function `puts` is a builtin too, on its name only.
    overloaded = answer(("orders.agc", where(ORDERS, "table.get", 7)), cwd=program)
    assert (overloaded["kind"], overloaded["help"]) == ("builtin", cli_help("Map.get"))
    assert [form["arity"] for form in overloaded["help"]["overloads"]] == [2, 3]
    bare = answer(("orders.agc", where(ORDERS, "puts(count)", 1)), cwd=program)
    assert (bare["kind"], bare["help"]) == ("builtin", cli_help("puts"))
    # The receiver and the arguments are expressions of their own, with no help; so is the rest of the call.
    for position in (where(ORDERS, "table.get", 1), where(ORDERS, '"a")', 1), where(ORDERS, "puts(count)", 4)):
        other = answer(("orders.agc", position), cwd=program)
        assert (other["kind"] != "builtin", other["help"]) == (True, None)
    # An answer that is not a builtin has a null `help`: the key is always there.
    assert answer(("orders.agc", where(ORDERS, "Models.make", 8)), cwd=program)["help"] is None


def test_a_pipe_into_a_builtin_is_the_builtin_on_its_right_hand_side(tmp_path):
    source = "def wrap() -> Result[Int]\n  return 5 |> ok()\nend\n"
    (tmp_path / "piped.agc").write_text(source, encoding="utf-8")
    report = answer(("piped.agc", where(source, "ok()", 1)), cwd=tmp_path)
    line, column = where(source, "ok()")
    assert (report["kind"], report["type"], report["text"], report["definition"]) == ("builtin", "Result[Int]", "ok()", None)
    assert report["help"] == cli_help("ok")
    # The span is the right-hand side, not the whole pipe.
    assert report["span"]["range"] == {
        "start": {"line": line, "column": column},
        "end": {"line": line, "column": column + 4},
    }


def test_a_declaration_of_a_std_module_carries_its_doc_and_signature(program):
    queue = answer(("orders.agc", where(ORDERS, "Queue.new", 6)), cwd=program)["definition"]
    assert (queue["file"], queue["kind"], queue["name"]) == ("std/queue.agc", "function", "new")
    assert queue["signature"] == "new() -> QueueState"
    assert queue["doc"] == "Returns an empty queue."


def test_text_form_of_a_builtin_gives_a_line_with_its_signature(program):
    position = where(ORDERS, "name.upcase", 6)
    result = run(cli() + ["type-at", f"orders.agc:{position[0]}:{position[1]}"], env=vm_environment(), cwd=program)
    assert (result.code, result.stderr) == (0, "")
    line, column = where(ORDERS, "name.upcase")
    assert result.stdout.split("\n") == [
        f"orders.agc:{line}:{column}-{line}:{column + 11} name.upcase: String",
        "builtin String.upcase(s: String) -> String",
        "",
    ]


# The locals of one file: every form that binds a name, each name used, and a name bound in sibling scopes (`i` in two
# loops, `note` in three branches, `n` in two blocks).
LOCALS = '''DOUBLED = [1, 2].map do |x| x * 2 end
IGNORED = [1].map do |_| 0 end

enum Pair
  Two(Int, Int)
  Gone
end

enum Box
  Full(Int)
  Empty
end

enum Shape
  Nest(Box)
  Flat
end

def measure(pair: Pair, scale: Int, parsed: Result[Int]) -> Int
  total = 0
  case pair
    Pair.Two(left, right) if left > 0 -> total = left * right + scale
    Pair.Two(_, _) -> total = 1
    Pair.Gone -> total = 2
  end
  case parsed
    ok(value) -> total += value
    error(reason) -> total += reason.size
  end
  for i in 1..3
    total += i
  end
  for i in [4, 5]
    total = total + i
  end
  if scale > 1
    note = "big"
    puts(note)
  elsif scale > 0
    note = "small"
    puts(note)
  else
    note = "none"
    puts(note)
  end
  scaled = [1, 2].map do |n| n * scale + total end
  [3].each do |n|
    deeper = [n].map do |m| m + n + scale end
    puts(deeper.size)
  end
  label = total |> to_text()
  return scaled.size + "#{label}".size
end

def to_text(n: Int) -> String
  return "#{n}"
end

def weigh(shape: Shape) -> Int
  case shape
    Shape.Nest(Box.Full(w)) -> return w + 1
    _ -> return 0
  end
end

def countdown(limit: Int) -> Int
  while limit > 0
    step = limit - 1
    limit = step
  end
  return limit
end
'''


@pytest.fixture
def locals_file(tmp_path):
    (tmp_path / "locals.agc").write_text(LOCALS, encoding="utf-8")
    return tmp_path


def local_at(needle, inside=0, nth=1, *, cwd):
    return answer(("locals.agc", where(LOCALS, needle, inside, nth)), cwd=cwd)


def binding_of(report):
    """(kind, name, start of the name) of the definition of an answer."""
    definition = report["definition"]
    assert definition["name_span"]["file"] == definition["file"] == "locals.agc"
    return definition["kind"], definition["name"], start(definition["name_span"])


# Each local of the file: the name, its type and kind, where it is bound (the text that starts at the name), and a use
# of it (the text that starts at the use). Every form that binds a name is here.
LOCAL_CASES = [
    ("pair", "Pair", "parameter", "pair: Pair", "pair\n"),
    ("scale", "Int", "parameter", "scale: Int", "scale\n"),
    ("parsed", "Result[Int]", "parameter", "parsed: Result", "parsed\n"),
    ("left", "Int", "pattern", "left, right", "left * right"),
    ("right", "Int", "pattern", "right)", "right + scale"),
    ("value", "Int", "pattern", "value)", "value\n"),
    ("reason", "String", "pattern", "reason)", "reason.size"),
    ("total", "Int", "local", "total = 0", "total |>"),
    ("i", "Int", "loop", "i in 1..3", "i\n  end"),
    ("note", "String", "local", 'note = "big"', "note)"),
    ("scaled", "List[Int]", "local", "scaled = ", "scaled.size"),
    ("n", "Int", "parameter", "n| n * scale", "n * scale"),
    ("deeper", "List[Int]", "local", "deeper = ", "deeper.size"),
    ("m", "Int", "parameter", "m| m + n", "m + n"),
    ("label", "String", "local", "label = ", "label}"),
    # A block in a constant has no function around it; a name nested in a pattern is typed by its own slot; a binding
    # in a `while` body is gone after it.
    ("x", "Int", "parameter", "x| x * 2", "x * 2"),
    ("w", "Int", "pattern", "w))", "w + 1"),
    ("step", "Int", "local", "step = limit", "step\n  end"),
]


def test_a_use_of_a_local_has_its_type_and_its_binding_as_definition(locals_file):
    for name, type_, kind, binding, use in LOCAL_CASES:
        report = local_at(use, cwd=locals_file)
        assert (report["kind"], report["type"], report["text"], report["help"]) == ("name", type_, name, None), name
        assert binding_of(report) == (kind, name, where(LOCALS, binding)), name
        definition = report["definition"]
        assert (definition["signature"], definition["doc"]) == (f"{name}: {type_}", None), name
        assert end(definition["name_span"]) == where(LOCALS, binding, len(name)), name
        # The span of the answer is the name where it is used, not the expression around it.
        assert end(report["span"]) == where(LOCALS, use, len(name)), name


def test_the_binding_site_of_a_local_answers_that_binding_and_the_definition_can_be_asked_back(locals_file):
    for name, type_, kind, binding, use in LOCAL_CASES:
        site = local_at(binding, cwd=locals_file)
        assert (site["kind"], site["type"], site["text"]) == ("name", type_, name), name
        assert binding_of(site) == (kind, name, where(LOCALS, binding)), name
        # The span of the answer is the name alone, which is also the name_span of the definition.
        assert (site["span"]["range"], site["span"]["file"]) == (site["definition"]["name_span"]["range"], "locals.agc")
        # What a use answers can be asked back: the definition's name_span is a position that answers the same binding.
        used = local_at(use, cwd=locals_file)
        again = answer(("locals.agc", start(used["definition"]["name_span"])), cwd=locals_file)
        assert again["definition"] == used["definition"] == site["definition"], name


def test_a_name_bound_in_sibling_scopes_points_at_the_binding_of_its_own_scope(locals_file):
    # `note` is bound in each branch of an if: three bindings, each use belongs to the branch it is in.
    for nth, value in enumerate(('"big"', '"small"', '"none"'), start=1):
        binding = where(LOCALS, f"note = {value}")
        used = local_at("puts(note)", 5, nth, cwd=locals_file)
        assert binding_of(used) == ("local", "note", binding)
        assert local_at(f"note = {value}", cwd=locals_file)["definition"] == used["definition"]
    # The variable of two loops, and the parameter `n` of two blocks.
    assert binding_of(local_at("+= i\n  end", 3, cwd=locals_file))[2] == where(LOCALS, "i in 1..3")
    assert binding_of(local_at("+ i\n  end", 2, cwd=locals_file))[2] == where(LOCALS, "i in [4, 5]")
    assert binding_of(local_at("n * scale", cwd=locals_file))[2] == where(LOCALS, "n| n * scale")
    assert binding_of(local_at("[n].map", 1, cwd=locals_file))[2] == where(LOCALS, "n|", 0, 2)
    # A reassignment in a loop points at the first binding of the name.
    assert binding_of(local_at("total = total + i", 8, cwd=locals_file))[2] == where(LOCALS, "total = 0")


def test_a_block_that_captures_a_local_points_at_the_outer_binding(locals_file):
    outer = where(LOCALS, "scale: Int")
    # `scale` is a parameter of the function, read in a block and in a block inside a block.
    for needle, inside in (("* scale", 2), ("+ scale end", 2)):
        report = local_at(needle, inside, cwd=locals_file)
        assert (binding_of(report), report["type"]) == (("parameter", "scale", outer), "Int"), needle
    # `n` is a parameter of the outer block, read in the inner one; `m` is the inner block's own.
    assert binding_of(local_at("m + n", 4, cwd=locals_file)) == ("parameter", "n", where(LOCALS, "n|", 0, 2))
    assert binding_of(local_at("m + n", 0, cwd=locals_file)) == ("parameter", "m", where(LOCALS, "m|"))
    # `total` is an outer local read in a block, and the target of an assignment is the binding it assigns.
    first = where(LOCALS, "total = 0")
    assert binding_of(local_at("+ total end", 2, cwd=locals_file))[2] == first
    assert binding_of(local_at("total += value", cwd=locals_file))[2] == first
    assert binding_of(local_at("total = total + i", cwd=locals_file)) == ("local", "total", first)
    assert end(local_at("total += value", cwd=locals_file)["span"]) == where(LOCALS, "total += value", 5)


def test_the_definition_range_is_the_binding_node_when_it_has_one_else_the_name(locals_file):
    # A parameter with a type and an assignment have a node of their own (the statement ends with its line); a block
    # parameter without a type, a `for` variable and a pattern name are the name alone.
    for name, binding, text, kind in (
        ("scale", "scale: Int", "scale: Int", "parameter"),
        ("step", "step = limit", None, "local"),
        ("x", "x| x * 2", "x", "parameter"),
        ("i", "i in 1..3", "i", "loop"),
        ("w", "w))", "w", "pattern"),
    ):
        definition = local_at(binding, cwd=locals_file)["definition"]
        line, column = where(LOCALS, binding)
        assert definition["kind"] == kind, name
        assert start(definition) == (line, column), name
        assert end(definition) == ((line + 1, 1) if text is None else (line, column + len(text))), name
        assert end(definition["name_span"]) == (line, column + len(name)), name


def test_a_discard_binds_nothing_and_is_on_no_expression(locals_file):
    problem(type_at(("locals.agc", where(LOCALS, "(_, _)", 1)), cwd=locals_file), "QUERY-NO-EXPRESSION", 2)
    # A discarded block parameter is on no expression either, not on the block around it.
    problem(type_at(("locals.agc", where(LOCALS, "|_|", 1)), cwd=locals_file), "QUERY-NO-EXPRESSION", 2)


def test_text_form_of_a_local_gives_the_name_with_its_type_and_the_binding(locals_file):
    line, column = where(LOCALS, "scale\n")
    result = run(cli() + ["type-at", f"locals.agc:{line}:{column}"], env=vm_environment(), cwd=locals_file)
    assert (result.code, result.stderr) == (0, "")
    bound = where(LOCALS, "scale: Int")
    assert result.stdout.split("\n") == [
        f"locals.agc:{line}:{column}-{line}:{column + 5} scale: Int",
        f"locals.agc:{bound[0]}:{bound[1]} parameter scale",
        "",
    ]


# The types of a program, named in every place a type is written, and the file they come from.
KINDS = '''## A user of the other file.
export struct User
  name: String
end

## An id.
export type Id = Int
'''

TYPES = '''import Kinds from "kinds"
import {Id} from "kinds"

## A point.
struct Point
  x: Int
  items: List[Point]
end

enum Shape
  Circle(Point)
  Pair(Kinds.User, Int)
end

type Points = List[Point]

def origin(p: Point, user: Kinds.User, id: Id, all: Points) -> Result[Point]
  q: Point = Point(x: 0, items: [])
  moved = [q].map do |each: Point| each end
  return ok(moved[0])
end

def main() -> Void
  puts(JSON.decode("{}", Point))
end
'''


@pytest.fixture
def types_file(tmp_path):
    (tmp_path / "kinds.agc").write_text(KINDS, encoding="utf-8")
    (tmp_path / "types.agc").write_text(TYPES, encoding="utf-8")
    return tmp_path


def type_name_at(needle, inside=0, nth=1, *, cwd):
    return answer(("types.agc", where(TYPES, needle, inside, nth)), cwd=cwd)


# Each place that writes a type: the text that starts at the name, the name, and the nth occurrence of the text.
POINT_PLACES = [
    ("Point, user", 1, "a parameter"),
    ("Point]\n  q:", 1, "the type of the result, as a type argument"),
    ("Point = Point(x", 1, "the annotation of a local"),
    ("Point]\nend", 1, "a type argument in a field"),
    ("Point)\n  Pair", 1, "the payload of a variant"),
    ("Point]\n\ndef origin", 1, "the target of an alias"),
    ("Point| each", 1, "the parameter of a block"),
    ("Point))\nend", 1, "a type as an argument of a call"),
]


@pytest.mark.parametrize("needle,nth,place", POINT_PLACES, ids=[place for _, _, place in POINT_PLACES])
def test_the_name_of_a_struct_in_a_type_is_a_type_with_the_struct_as_definition(types_file, needle, nth, place):
    found = type_name_at(needle, nth=nth, cwd=types_file)
    assert (found["kind"], found["text"], found["type"]) == ("type", "Point", "Point"), place
    assert start(found["span"]) == where(TYPES, needle, 0, nth) and found["span"]["file"] == "types.agc", place
    assert end(found["span"]) == where(TYPES, needle, 5, nth), place
    definition = found["definition"]
    assert (definition["kind"], definition["name"], definition["file"]) == ("struct", "Point", "types.agc"), place
    assert (definition["signature"], definition["doc"]) == ("struct Point", "A point."), place
    assert start(definition["name_span"]) == where(TYPES, "Point\n  x: Int") and found["help"] is None, place


def test_a_position_inside_the_name_is_the_type_and_the_brackets_around_a_type_argument_are_not(types_file):
    inside = type_name_at("Point, user", 4, cwd=types_file)
    assert (inside["kind"], start(inside["span"])) == ("type", where(TYPES, "Point, user"))
    bracket = type_at(("types.agc", where(TYPES, "List[Point]", 4)), cwd=types_file)
    problem(bracket, "QUERY-NO-EXPRESSION", 2)


def test_a_builtin_type_is_a_type_with_no_definition_and_no_help(types_file):
    for needle, name in (("Int\n  items", "Int"), ("List[Point]\nend", "List"), ("Result[Point]", "Result")):
        found = type_name_at(needle, cwd=types_file)
        assert (found["kind"], found["text"], found["type"], found["definition"]) == ("type", name, name, None), name
        assert (found["help"], end(found["span"])) == (None, where(TYPES, needle, len(name))), name
    nested = type_name_at("List[Point]", 5, cwd=types_file)
    assert (nested["text"], nested["definition"]["kind"]) == ("Point", "struct")


def test_a_qualified_name_is_one_span_and_the_definition_is_in_the_file_of_the_import(types_file):
    for inside in (0, 3, 5, 6, 9):
        found = type_name_at("Kinds.User, id", inside, cwd=types_file)
        assert (found["kind"], found["text"], found["type"]) == ("type", "Kinds.User", "Kinds.User"), inside
        assert start(found["span"]) == where(TYPES, "Kinds.User, id"), inside
        assert end(found["span"]) == where(TYPES, "Kinds.User, id", 10), inside
        definition = found["definition"]
        assert (definition["kind"], definition["name"], definition["file"]) == ("struct", "User", "kinds.agc"), inside
        assert definition["doc"] == "A user of the other file." and definition["signature"] == "struct User"
        assert definition["name_span"]["file"] == "kinds.agc"
        assert start(definition["name_span"]) == where(KINDS, "User\n  name")
    payload = type_name_at("Kinds.User, Int", cwd=types_file)
    assert (payload["kind"], payload["definition"]["name"]) == ("type", "User")


def test_an_alias_imported_by_name_is_a_type_with_the_alias_as_definition(types_file):
    found = type_name_at("Id, all", cwd=types_file)
    assert (found["kind"], found["text"], found["type"]) == ("type", "Id", "Id")
    definition = found["definition"]
    assert (definition["kind"], definition["name"], definition["file"]) == ("alias", "Id", "kinds.agc")
    assert (definition["signature"], definition["doc"]) == ("type Id = Int", "An id.")
    # The alias declared in the file itself.
    own = type_name_at("Points) ->", cwd=types_file)
    assert own["definition"]["kind"] == "alias" and own["definition"]["file"] == "types.agc"


def test_a_construction_is_still_an_expression_with_the_struct_as_definition(types_file):
    built = type_name_at("Point(x: 0", cwd=types_file)
    assert (built["kind"], built["type"], built["definition"]["kind"]) == ("name", "Point", "struct")
