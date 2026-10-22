"""`agentica symbol` through the product CLI: where a name is defined in the files of PATH... and what they import
(docs/future/39-semantic-cli.md, 39.3 to 39.7). The cases read the JSON form and assert kinds, names, spans, codes and
exit codes, never message text; one case reads the text form."""
import json
import os

import pytest

from tests.agentica_test import POSIX_PYTHON, cli, run, vm_environment
from tests.span_support import end, problem, start, where

ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0

# The module the cases import: a struct, an enum, a type alias, a constant, an exported and a private function.
MODELS = '''## The cap.
export LIMIT: Int = 5

## A user.
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

export type Names = List[String]

## Makes a user.
##
## The age is 3.
export def make(name: String) -> User
  return User(name: name, age: 3)
end

def hidden() -> Int
  return 1
end
'''

# The file that imports it. Its uses of `Models` are the places `type-at` is asked from in the round trip.
ORDERS = '''import Models from "models"
import Queue from "std/queue"

struct Order
  user: Models.User
end

def total(order: Order) -> Int
  made = Models.make("x")
  built = Models.User(name: "n", age: 1)
  puts(built)
  shape = Models.Shape.Circle(1.5)
  puts(shape)
  pile = Queue.new()
  puts(pile)
  return order.user.age + made.age
end
'''


def symbol(*words, cwd, stdin=None, style="--json"):
    return run(cli() + [style, "symbol", *words], env=vm_environment(), cwd=cwd, stdin=stdin)


def answer(*words, cwd, stdin=None):
    result = symbol(*words, cwd=cwd, stdin=stdin)
    assert (result.code, result.stderr) == (0, ""), result.stderr
    return json.loads(result.stdout)


def one(*words, cwd, stdin=None):
    matches = answer(*words, cwd=cwd, stdin=stdin)["matches"]
    assert len(matches) == 1, matches
    return matches[0]


@pytest.fixture
def program(tmp_path):
    (tmp_path / "models.agc").write_text(MODELS, encoding="utf-8")
    (tmp_path / "orders.agc").write_text(ORDERS, encoding="utf-8")
    return tmp_path


def test_a_bare_name_finds_each_kind_of_top_level_declaration_with_its_signature_doc_and_spans(program):
    report = answer("make", "models.agc", cwd=program)
    assert (report["version"], report["command"], report["query"], report["skipped"]) == (1, "symbol", "make", [])
    make = report["matches"][0]
    assert (make["kind"], make["name"], make["module"], make["exported"]) == ("function", "make", "models.agc", True)
    assert make["signature"] == "make(name: String) -> User"
    assert make["doc"] == "Makes a user.\n\nThe age is 3."
    # `span` is the whole declaration, `export` included, as in `outline`; `name_span` is the name alone.
    assert make["span"]["file"] == make["name_span"]["file"] == "models.agc"
    assert start(make["span"]) == where(MODELS, "export def make")
    assert (start(make["name_span"]), end(make["name_span"])) == (where(MODELS, "make(name"),
                                                                  where(MODELS, "make(name", 4))
    cases = [("User", "struct", "struct User", "A user."), ("Shape", "enum", "enum Shape", None),
             ("Names", "alias", "type Names = List[String]", None), ("LIMIT", "constant", "LIMIT: Int", "The cap.")]
    for name, kind, signature, doc in cases:
        found = one(name, "models.agc", cwd=program)
        assert (found["kind"], found["name"], found["exported"]) == (kind, name, True)
        assert (found["signature"], found["doc"]) == (signature, doc)


def test_a_private_declaration_is_found_by_its_bare_name_and_not_through_an_alias(program):
    hidden = one("hidden", "models.agc", cwd=program)
    assert (hidden["kind"], hidden["exported"], hidden["doc"]) == ("function", False, None)
    assert start(hidden["span"]) == where(MODELS, "def hidden")
    # `Models.hidden` is not code that can be written: the alias reaches the exports only.
    problem(symbol("Models.hidden", "orders.agc", cwd=program), "QUERY-NOT-FOUND", 2)


def test_a_field_and_a_variant_are_found_by_their_owner_and_carry_their_own_data(program):
    forms = ["User.name", "Models.User.name"]
    for written in forms:
        field = one(written, "orders.agc", cwd=program)
        assert (field["kind"], field["name"], field["struct"], field["type"]) == ("field", "name", "User", "String")
        assert (field["module"], field["exported"], field["signature"], field["doc"]) == ("models.agc", True,
                                                                                         "name: String", "The name.")
        assert start(field["span"]) == start(field["name_span"]) == where(MODELS, "name: String")
        assert end(field["name_span"]) == where(MODELS, "name: String", 4)
    for written in ["Shape.Circle", "Models.Shape.Circle"]:
        variant = one(written, "orders.agc", cwd=program)
        assert (variant["kind"], variant["name"], variant["enum"], variant["payload"]) == (
            "variant", "Circle", "Shape", ["Float"])
        assert (variant["signature"], variant["doc"]) == ("Circle(Float)", "A round one.")
        assert start(variant["name_span"]) == where(MODELS, "Circle(Float)")
    square = one("Shape.Square", "orders.agc", cwd=program)
    assert (square["payload"], square["signature"], square["doc"]) == ([], "Square", None)


def test_a_name_through_an_import_alias_is_found_in_the_module_the_alias_names(program):
    assert one("Models.make", "orders.agc", cwd=program)["module"] == "models.agc"
    assert one("Models.User", "orders.agc", cwd=program)["kind"] == "struct"
    # An alias works only in the files of PATH... : `models.agc` alone imports nothing, so the name is not written.
    problem(symbol("Models.make", "models.agc", cwd=program), "QUERY-NOT-FOUND", 2)


def test_a_std_module_is_named_with_its_std_path_and_its_declarations_come_from_the_embedded_source(program):
    pop = one("std/queue.pop", "orders.agc", cwd=program)
    assert (pop["kind"], pop["module"], pop["span"]["file"]) == ("function", "std/queue.agc", "std/queue.agc")
    assert pop["signature"] == "pop(q: QueueState) -> Result[Popped]"
    field = one("std/queue.Popped.value", "orders.agc", cwd=program)
    assert (field["kind"], field["struct"], field["type"]) == ("field", "Popped", "String")
    # The alias of the file reaches it as well.
    assert one("Queue.pop", "orders.agc", cwd=program)["module"] == "std/queue.agc"


def test_a_builtin_carries_the_help_object_and_no_place(program):
    for name in ["Map.get", "puts"]:
        found = one(name, "orders.agc", cwd=program)
        help_json = run(cli() + ["help", name, "--json"], env=vm_environment(), cwd=program)
        assert (found["kind"], found["name"], found["module"], found["span"], found["name_span"]) == (
            "builtin", name, None, None, None)
        assert found["help"] == json.loads(help_json.stdout)
        assert (found["exported"], found["doc"], found["signature"] != "") == (True, None, True)
    assert one("String.trim", "orders.agc", cwd=program)["help"]["ruby"] == "s.strip() -> String"


def test_a_bare_name_lists_every_module_that_declares_it_in_link_order_and_the_same_alias_for_two_modules(tmp_path):
    (tmp_path / "one").mkdir()
    (tmp_path / "two").mkdir()
    (tmp_path / "one" / "lib.agc").write_text("export def parse(a: Int) -> Int\n  return a\nend\n", encoding="utf-8")
    (tmp_path / "two" / "lib.agc").write_text("export def parse(a: String) -> String\n  return a\nend\n",
                                              encoding="utf-8")
    (tmp_path / "one" / "main.agc").write_text('import Lib from "lib"\n\ndef run() -> Int\n  return Lib.parse(1)\nend\n',
                                               encoding="utf-8")
    (tmp_path / "two" / "main.agc").write_text('import Lib from "lib"\n\ndef run() -> String\n  return Lib.parse("")\n'
                                               "end\n", encoding="utf-8")
    report = answer("parse", ".", cwd=tmp_path)
    # Roots in bytewise order of the path; each root, then what it imports.
    assert [(m["module"], m["signature"]) for m in report["matches"]] == [
        ("one/lib.agc", "parse(a: Int) -> Int"), ("two/lib.agc", "parse(a: String) -> String")]
    # The same alias names a different module in each file: both are matches.
    through = answer("Lib.parse", ".", cwd=tmp_path)["matches"]
    assert [m["module"] for m in through] == ["one/lib.agc", "two/lib.agc"]
    # A name that two modules declare is only found by `run` once per module that declares it.
    assert [m["module"] for m in answer("run", ".", cwd=tmp_path)["matches"]] == ["one/main.agc", "two/main.agc"]


def test_a_name_that_nothing_declares_is_query_not_found_at_the_arguments(program):
    diagnostic = problem(symbol("mak", "orders.agc", cwd=program), "QUERY-NOT-FOUND", 2)
    assert diagnostic["file"] == "<arguments>"
    assert diagnostic["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 1}}
    assert diagnostic["help"]


def test_a_folder_is_every_agc_file_under_it_without_hidden_folders_and_agc_libs_in_bytewise_order(tmp_path):
    for folder in ["a", "a.d", ".hidden", "agc_libs", "deep/er"]:
        (tmp_path / folder).mkdir(parents=True)
    body = "def pick() -> Int\n  return 1\nend\n"
    for name in ["b.agc", "a/x.agc", "a.d/y.agc", "a.agc", ".hidden/h.agc", "agc_libs/l.agc", "deep/er/z.agc"]:
        (tmp_path / name).write_text(body, encoding="utf-8")
    (tmp_path / "notes.txt").write_text(body, encoding="utf-8")
    modules = [m["module"] for m in answer("pick", cwd=tmp_path)["matches"]]
    assert modules == ["a.agc", "a.d/y.agc", "a/x.agc", "b.agc", "deep/er/z.agc"]
    # A file named twice, by two spellings, is one root; arguments keep their order.
    again = answer("pick", "b.agc", str(tmp_path / "b.agc"), "./a.agc", cwd=tmp_path)["matches"]
    assert [m["module"] for m in again] == ["b.agc", "a.agc"]


def test_a_root_that_does_not_link_is_skipped_with_its_first_diagnostic_and_the_others_answer(tmp_path):
    (tmp_path / "good.agc").write_text("def found() -> Int\n  return 1\nend\n", encoding="utf-8")
    (tmp_path / "lexer.agc").write_text("export def broken(\n", encoding="utf-8")
    (tmp_path / "bad.agc").write_text('def broken() -> Int\n  return "\n', encoding="utf-8")
    (tmp_path / "one.agc").write_text('import Bad from "bad"\n\ndef a() -> Int\n  return 1\nend\n', encoding="utf-8")
    (tmp_path / "two.agc").write_text('import Bad from "bad"\n\ndef b() -> Int\n  return 1\nend\n', encoding="utf-8")
    (tmp_path / "missing.agc").write_text('import Nowhere from "./nowhere"\n\ndef c() -> Int\n  return 1\nend\n',
                                          encoding="utf-8")
    report = answer("found", cwd=tmp_path)
    assert [m["module"] for m in report["matches"]] == ["good.agc"]
    skipped = {item["file"]: item["diagnostic"] for item in report["skipped"]}
    assert sorted(skipped) == ["bad.agc", "lexer.agc", "missing.agc", "one.agc", "two.agc"]
    assert skipped["lexer.agc"]["code"] == "LEX-UNCLOSED-DELIMITER" and skipped["lexer.agc"]["file"] == "lexer.agc"
    assert skipped["bad.agc"]["code"] == "LEX-UNTERMINATED-STRING" and skipped["bad.agc"]["file"] == "bad.agc"
    assert skipped["missing.agc"]["code"] == "CHECK-IMPORT-IO" and skipped["missing.agc"]["file"] == "missing.agc"
    # Two roots that import the same broken module are both skipped with that module's diagnostic.
    assert skipped["one.agc"] == skipped["two.agc"]
    assert skipped["one.agc"]["code"] == "LEX-UNTERMINATED-STRING"
    assert skipped["one.agc"]["file"].endswith("bad.agc")
    # The roots that do not link are not searched, and the answer to a name only they declare says which were left out.
    problem(symbol("a", "one.agc", cwd=tmp_path), "LEX-UNTERMINATED-STRING", 1)


def test_a_chain_of_imports_is_linked_once_and_its_matches_come_in_the_order_the_roots_were_linked(tmp_path):
    # Each file imports the one before it, which sorts first: every root reaches all the files before it.
    count = 30
    for number in range(1, count + 1):
        previous = f'import Before from "f{number - 1:03d}"\n\n' if number > 1 else ""
        call = f"Before.step() + 1" if number > 1 else "1"
        (tmp_path / f"f{number:03d}.agc").write_text(
            f"{previous}export def step() -> Int\n  return {call}\nend\n", encoding="utf-8")
    report = answer("step", ".", cwd=tmp_path)
    assert [m["module"] for m in report["matches"]] == [f"f{number:03d}.agc" for number in range(1, count + 1)]
    assert report["skipped"] == []
    # Only the file asked for and what it imports are searched, the file first and then its imports in order.
    assert [m["module"] for m in answer("step", "f005.agc", cwd=tmp_path)["matches"]] == [
        f"f{number:03d}.agc" for number in range(5, 0, -1)]


def test_a_root_is_a_transaction_the_modules_it_linked_stay_and_a_module_that_failed_fails_every_root_that_reaches_it(
        tmp_path):
    (tmp_path / "lib.agc").write_text("export def helper() -> Int\n  return 1\nend\n", encoding="utf-8")
    (tmp_path / "dep_bad.agc").write_text(
        'import Lib from "lib"\n\nexport def bad() -> Int\n  return Lib.nothere()\nend\n', encoding="utf-8")
    for name in ("a_first", "b_second"):
        (tmp_path / f"{name}.agc").write_text(
            'import Lib from "lib"\nimport Dep from "dep_bad"\n\ndef %s() -> Int\n  return Lib.helper()\nend\n' % name,
            encoding="utf-8")
    (tmp_path / "z_third.agc").write_text(
        'import Lib from "lib"\n\ndef z_third() -> Int\n  return Lib.helper()\nend\n', encoding="utf-8")
    report = answer("helper", ".", cwd=tmp_path)
    # `lib.agc` linked while `a_first` was tried; the root that failed left nothing else behind.
    assert [m["module"] for m in report["matches"]] == ["lib.agc"]
    skipped = {item["file"]: item["diagnostic"] for item in report["skipped"]}
    assert sorted(skipped) == ["a_first.agc", "b_second.agc", "dep_bad.agc"]
    assert {item["code"] for item in skipped.values()} == {"CHECK-IMPORT-NAME"}
    assert skipped["a_first.agc"] == skipped["b_second.agc"] and skipped["a_first.agc"]["file"].endswith("dep_bad.agc")
    assert skipped["dep_bad.agc"]["file"] == "dep_bad.agc"
    assert answer("z_third", ".", cwd=tmp_path)["matches"][0]["module"] == "z_third.agc"
    # The skipped roots are not searched.
    problem(symbol("a_first", ".", cwd=tmp_path), "QUERY-NOT-FOUND", 2)


def test_a_folder_names_agc_and_agc_libs_in_any_case_as_the_package_hash_does(tmp_path):
    (tmp_path / "AGC_LIBS").mkdir()
    body = "def pick() -> Int\n  return 1\nend\n"
    for name in ["a.agc", "b.AGC", "AGC_LIBS/l.agc"]:
        (tmp_path / name).write_text(body, encoding="utf-8")
    assert [m["module"] for m in answer("pick", cwd=tmp_path)["matches"]] == ["a.agc", "b.AGC"]


def test_a_root_that_is_not_utf8_is_skipped_with_its_lexer_diagnostic_and_the_others_answer(tmp_path):
    (tmp_path / "good.agc").write_text("def found() -> Int\n  return 1\nend\n", encoding="utf-8")
    (tmp_path / "binary.agc").write_bytes(b'def broken() -> Int\n  return "\xff\xfe"\nend\n')
    report = answer("found", cwd=tmp_path)
    assert [m["module"] for m in report["matches"]] == ["good.agc"]
    [skipped] = report["skipped"]
    assert skipped["file"] == "binary.agc"
    assert skipped["diagnostic"]["code"] == "LEX-INVALID-UTF8" and skipped["diagnostic"]["file"] == "binary.agc"
    assert start(skipped["diagnostic"]) == (2, 11) and end(skipped["diagnostic"]) == (2, 12)
    # The same file alone leaves nothing to answer: its diagnostic is the answer, exit 1.
    problem(symbol("found", "binary.agc", cwd=tmp_path), "LEX-INVALID-UTF8", 1)


@pytest.mark.skipif(not POSIX_PYTHON or ROOT_USER, reason="host-only: a file mode binds a POSIX user, not root")
def test_a_root_that_cannot_be_read_is_skipped_and_the_others_answer(tmp_path):
    (tmp_path / "good.agc").write_text("def found() -> Int\n  return 1\nend\n", encoding="utf-8")
    locked = tmp_path / "locked.agc"
    locked.write_text("def found() -> Int\n  return 2\nend\n", encoding="utf-8")
    locked.chmod(0)
    try:
        report = answer("found", cwd=tmp_path)
    finally:
        locked.chmod(0o644)
    assert [m["module"] for m in report["matches"]] == ["good.agc"]
    [skipped] = report["skipped"]
    assert skipped["file"] == "locked.agc"
    assert skipped["diagnostic"]["code"] == "CHECK-IMPORT-IO" and skipped["diagnostic"]["file"] == "locked.agc"


def test_an_alias_comes_only_from_a_whole_module_import_not_from_a_selective_one(tmp_path):
    (tmp_path / "m.agc").write_text("export def make() -> Int\n  return 1\nend\n", encoding="utf-8")
    (tmp_path / "u.agc").write_text('import {make as mk} from "m"\n\ndef run() -> Int\n  return mk()\nend\n',
                                    encoding="utf-8")
    problem(symbol("mk", "u.agc", cwd=tmp_path), "QUERY-NOT-FOUND", 2)
    found = one("make", "u.agc", cwd=tmp_path)
    assert (found["kind"], found["module"], found["name"]) == ("function", "m.agc", "make")
    assert start(found["span"]) == (1, 1) and end(found["span"]) == (4, 1)


def test_when_every_root_is_skipped_the_first_diagnostic_is_the_answer_with_exit_1(tmp_path):
    (tmp_path / "broken.agc").write_text("export def broken(\n", encoding="utf-8")
    (tmp_path / "other.agc").write_text('def other() -> Int\n  return "\n', encoding="utf-8")
    first = problem(symbol("broken", "broken.agc", "other.agc", cwd=tmp_path), "LEX-UNCLOSED-DELIMITER", 1)
    assert first["file"] == "broken.agc"
    assert problem(symbol("broken", "other.agc", "broken.agc", cwd=tmp_path), "LEX-UNTERMINATED-STRING", 1)["file"] == (
        "other.agc")


def test_a_file_has_one_name_whatever_the_spelling_of_its_path(tmp_path):
    work = tmp_path / "work"
    (work / "sub").mkdir(parents=True)
    (work / "sub" / "one.agc").write_text("def one() -> Int\n  return 1\nend\n", encoding="utf-8")
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    for typed in ["sub/one.agc", "./sub/../sub/one.agc", str(work / "sub" / "one.agc"), "sub/"]:
        found = one("one", typed, cwd=work)
        assert found["module"] == found["span"]["file"] == "sub/one.agc"
    outside = one("one", str(work / "sub" / "one.agc"), cwd=elsewhere)["module"]
    assert os.path.isabs(outside) and os.path.samefile(outside, work / "sub" / "one.agc")


def test_the_buffer_on_standard_input_wins_over_the_file_on_the_disk_and_comes_first(program):
    buffer = "export def make(name: String, age: Int) -> Int\n  return age\nend\n\nexport def fresh() -> Int\n  return 1\nend\n"
    report = answer("make", "orders.agc", "--stdin", "models.agc", cwd=program, stdin=buffer)
    assert [(m["module"], m["signature"]) for m in report["matches"]] == [("models.agc",
                                                                            "make(name: String, age: Int) -> Int")]
    # FILE need not exist; the style may stand before the command; the disk is not written.
    assert one("fresh", "--stdin", "new.agc", cwd=program, stdin="def fresh() -> Int\n  return 1\nend\n")["module"] == (
        "new.agc")
    assert (program / "models.agc").read_text(encoding="utf-8") == MODELS
    after = symbol("make", "--stdin", "models.agc", "--json", cwd=program, stdin=buffer, style="--ai")
    assert json.loads(after.stdout) == answer("make", "--stdin", "models.agc", cwd=program, stdin=buffer)
    # An error of the buffer skips that root only: the others still answer.
    (program / "plain.agc").write_text("def plain() -> Int\n  return 1\nend\n", encoding="utf-8")
    broken = answer("plain", "plain.agc", "--stdin", "models.agc", cwd=program, stdin="export def broken(\n")
    assert [m["module"] for m in broken["matches"]] == ["plain.agc"]
    assert [(item["file"], item["diagnostic"]["code"]) for item in broken["skipped"]] == [
        ("models.agc", "LEX-UNCLOSED-DELIMITER")]


# A name, and a use of it in ORDERS: the needle and how far into it the position is.
USES = [("make", "Models.make", 8), ("User.age", "order.user.age", 11), ("Shape.Circle", "Models.Shape.Circle(1.5)", 14),
        ("User", "Models.User(name", 8)]


@pytest.mark.parametrize("name, needle, inside", USES)
def test_the_match_of_a_name_used_in_a_file_is_the_definition_type_at_gives_there(program, name, needle, inside):
    match = one(name, "orders.agc", cwd=program)
    line, column = where(ORDERS, needle, inside)
    result = run(cli() + ["--json", "type-at", f"orders.agc:{line}:{column}"], env=vm_environment(), cwd=program)
    assert (result.code, result.stderr) == (0, "")
    definition = json.loads(result.stdout)["definition"]
    assert (definition["kind"], definition["name"], definition["file"]) == (match["kind"], match["name"],
                                                                            match["module"])
    assert definition["name_span"] == match["name_span"]
    assert (definition["signature"], definition["doc"]) == (match["signature"], match["doc"])
    # type-at starts the range of an exported declaration at the keyword after `export`; the match, as `outline`
    # does, at `export`. The end is the same.
    assert definition["range"]["end"] == match["span"]["range"]["end"]
    if not match["exported"] or match["kind"] in ("field", "variant"):
        assert definition["range"] == match["span"]["range"]


def test_text_form_lists_one_line_per_match_as_outline_does_and_the_skipped_roots_on_stderr(program):
    (program / "broken.agc").write_text("export def broken(\n", encoding="utf-8")
    result = run(cli() + ["symbol", "make", "."], env=vm_environment(), cwd=program)
    assert result.code == 0
    assert result.stdout.split("\n") == ["models.agc:%d:%d export def make(name: String) -> User" % where(
        MODELS, "export def make"), ""]
    assert result.stderr.strip().split("\n") == ["skipped broken.agc: LEX-UNCLOSED-DELIMITER"]
    members = run(cli() + ["symbol", "User.name", "orders.agc"], env=vm_environment(), cwd=program)
    assert members.stdout == "models.agc:%d:%d field User.name: String\n" % where(MODELS, "name: String")
    variant = run(cli() + ["symbol", "Shape.Circle", "orders.agc"], env=vm_environment(), cwd=program)
    assert variant.stdout == "models.agc:%d:%d variant Shape.Circle(Float)\n" % where(MODELS, "Circle(Float)")
    builtin = run(cli() + ["symbol", "String.split", "orders.agc"], env=vm_environment(), cwd=program)
    assert builtin.stdout.startswith("builtin String.split(")


@pytest.mark.parametrize("words", [
    [],  # missing NAME
    [""],  # an empty NAME
    ["--stdin"],  # --stdin without FILE
    ["make", "--stdin", "--json"],  # an option is not the FILE of --stdin
    ["make", "--stdin", "a.agc", "--stdin", "b.agc"],  # --stdin twice
    ["make", "--unknown"],  # unknown option
    ["make", "absent.agc"],  # unreadable path
    ["make", "empty"],  # a folder with no *.agc file
])
def test_a_mistake_in_the_question_is_query_usage_at_the_arguments(program, words):
    (program / "empty").mkdir()
    diagnostic = problem(symbol(*words, cwd=program, stdin=""), "QUERY-USAGE", 2)
    assert diagnostic["file"] == "<arguments>"
    assert diagnostic["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 1}}
