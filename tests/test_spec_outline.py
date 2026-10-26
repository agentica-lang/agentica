"""`agentica outline` through the product CLI: the declarations of one file, private ones included, with their docs and
spans (docs/future/39-semantic-cli.md, 39.2 to 39.7). The cases read the JSON form and assert fields, spans, codes and
exit codes, never message text; one case reads the text form."""
import json
import os

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import end, items_by_name, problem, start

# Every kind of declaration, exported or not, an import list and an import that does not exist: `outline` only parses,
# so the imports cannot make it fail. Line numbers are asserted below.
MODULE = '''## Shapes and helpers.
##
## Second paragraph.

import Nowhere from "./nowhere"
import {first, Second as Other} from "./other"

## The largest size.
export LIMIT: Int = 5

PRIVATE_LIMIT = 1

## A shape.
##
## Longer text.
export enum Shape[T]
  ## A circle with a radius.
  Circle(Float)
  Rect(Float, Map[String, List[Int]])
end

## A point.
struct Point
  ## The x position.
  x: Int = 0
  user: Nowhere.User
end

export type Grid[T] = List[List[T]]

## Adds two numbers.
export def add(a: Int, b: Int = 2) -> Int
  return a + b
end

def hidden(f: Fn[Int, String]) -> Nowhere.User
  return f
end
'''


def outline(*words, cwd=None, stdin=None):
    return run(cli() + list(words), env=vm_environment(), cwd=cwd, stdin=stdin)


def answer(*words, cwd=None, stdin=None):
    result = outline("--json", "outline", *words, cwd=cwd, stdin=stdin)
    assert result.code == 0, result.stderr
    return json.loads(result.stdout)


def test_items_in_source_order_with_exported_docs_signatures_and_spans(tmp_path):
    (tmp_path / "shapes.agc").write_text(MODULE, encoding="utf-8")
    report = answer("shapes.agc", cwd=tmp_path)
    assert (report["version"], report["command"], report["file"]) == (1, "outline", "shapes.agc")
    assert report["doc"] == "Shapes and helpers.\n\nSecond paragraph."
    # Private declarations are listed too, in source order.
    assert [(item["kind"], item["name"], item["exported"]) for item in report["items"]] == [
        ("constant", "LIMIT", True), ("constant", "PRIVATE_LIMIT", False), ("enum", "Shape", True),
        ("struct", "Point", False), ("alias", "Grid", True), ("function", "add", True), ("function", "hidden", False),
    ]
    items = items_by_name(report)
    # `span` is the whole declaration, `export` included; `name_span` is the name alone, on the same line.
    shape = items["Shape"]
    assert (start(shape["span"]), start(shape["name_span"]), end(shape["name_span"])) == ((16, 1), (16, 13), (16, 18))
    assert shape["span"]["file"] == shape["name_span"]["file"] == "shapes.agc"
    assert start(items["Point"]["span"]) == (23, 1) and start(items["Point"]["name_span"]) == (23, 8)
    assert start(items["add"]["name_span"]) == (32, 12)
    assert start(items["LIMIT"]["name_span"]) == (9, 8)
    assert start(items["PRIVATE_LIMIT"]["name_span"]) == (11, 1)
    assert start(items["Grid"]["name_span"]) == (29, 13)

    add = items["add"]
    assert (add["signature"], add["summary"]) == ("add(a: Int, b: Int = 2) -> Int", "Adds two numbers.")
    assert [(p["name"], p["default"]) for p in add["parameters"]] == [("a", None), ("b", "2")]
    hidden = items["hidden"]
    assert hidden["signature"] == "hidden(f: Fn[Int, String]) -> Nowhere.User"
    assert (hidden["doc"], hidden["summary"], hidden["result"]) == (None, None, "Nowhere.User")
    assert (shape["summary"], shape["doc"]) == ("A shape.", "A shape.\n\nLonger text.")
    assert shape["signature"] == "enum Shape[T]"
    assert items["Grid"]["signature"] == "type Grid[T] = List[List[T]]"

    # Fields and variants carry their own name span.
    assert [(v["name"], v["payload"], v["doc"], start(v["name_span"])) for v in shape["variants"]] == [
        ("Circle", ["Float"], "A circle with a radius.", (18, 3)),
        ("Rect", ["Float", "Map[String, List[Int]]"], None, (19, 3)),
    ]
    fields = items["Point"]["fields"]
    assert [(f["name"], f["type"], f["default"], f["doc"], start(f["name_span"])) for f in fields] == [
        ("x", "Int", "0", "The x position.", (25, 3)), ("user", "Nowhere.User", None, None, (26, 3)),
    ]


def test_imports_with_path_alias_and_span_even_when_they_do_not_exist(tmp_path):
    (tmp_path / "shapes.agc").write_text(MODULE, encoding="utf-8")
    report = answer("shapes.agc", cwd=tmp_path)
    aliased, listed = report["imports"]
    assert (aliased["path"], aliased["alias"], aliased["names"]) == ("./nowhere", "Nowhere", [])
    assert (start(aliased["span"]), aliased["span"]["file"]) == ((5, 1), "shapes.agc")
    assert (listed["path"], listed["alias"]) == ("./other", None)
    assert [(n["name"], n["local"], start(n["span"])) for n in listed["names"]] == [
        ("first", "first", (6, 9)), ("Second", "Other", (6, 16)),
    ]


def test_the_file_is_named_by_its_canonical_path_relative_to_the_working_folder(tmp_path):
    work = tmp_path / "work"
    (work / "sub").mkdir(parents=True)
    (work / "sub" / "one.agc").write_text("def one() -> Int\n  return 1\nend\n", encoding="utf-8")
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    real = (work / "sub" / "one.agc").resolve()
    # Any spelling of a file below the working folder gives one name; a file outside it gives its absolute path.
    for typed in ["sub/one.agc", "./sub/../sub/one.agc", str(work / "sub" / "one.agc")]:
        report = answer(typed, cwd=work)
        assert report["file"] == "sub/one.agc"
        assert report["items"][0]["span"]["file"] == "sub/one.agc"
    # The spelling of an absolute path is the system's own (a drive letter, a separator), so compare the files.
    outside = answer(str(real), cwd=elsewhere)["file"]
    assert os.path.isabs(outside) and os.path.samefile(outside, real)


def test_an_embedded_std_module_is_named_with_its_extension(tmp_path):
    # A folder with no std/ of its own: the name is not a path of the disk.
    report = answer("std/queue", cwd=tmp_path)
    assert report["file"] == "std/queue.agc"
    items = items_by_name(report)
    assert items["pop"]["signature"] == "pop(q: QueueState) -> Result[Popped]"
    assert items["pop"]["exported"] is True
    assert items["pop"]["span"]["file"] == "std/queue.agc"
    assert [f["name"] for f in items["Popped"]["fields"]] == ["value", "remaining"]
    assert answer("std/queue.agc", cwd=tmp_path) == report
    for name in ["std/nothing", "std/../x", "std/prelude/lazy"]:
        problem(outline("--json", "outline", name, cwd=tmp_path), "QUERY-USAGE", 2)


def test_a_lex_or_parse_error_exits_1_with_its_code(tmp_path):
    (tmp_path / "lexer.agc").write_text("export def broken(\n", encoding="utf-8")
    (tmp_path / "parser.agc").write_text('def ok() -> Int\n  return 1\nend\n\nputs("x")\n', encoding="utf-8")
    cases = [("lexer.agc", "LEX-UNCLOSED-DELIMITER", 1), ("parser.agc", "PARSE-TOP-LEVEL-STATEMENT", 5)]
    for name, code, line in cases:
        diagnostic = problem(outline("--json", "outline", name, cwd=tmp_path), code, 1)
        assert diagnostic["file"] == name
        assert diagnostic["range"]["start"]["line"] == line


def test_the_buffer_on_standard_input_wins_over_the_file_on_the_disk(tmp_path):
    (tmp_path / "main.agc").write_text("def on_disk() -> Int\n  return 1\nend\n", encoding="utf-8")
    buffer = "export def in_buffer(n: Int) -> Int\n  return n\nend\n"
    report = answer("--stdin", "main.agc", cwd=tmp_path, stdin=buffer)
    assert report["file"] == "main.agc"
    assert [item["name"] for item in report["items"]] == ["in_buffer"]
    # The style may stand after the command, and the disk is not written.
    after = outline("outline", "--stdin", "main.agc", "--json", cwd=tmp_path, stdin=buffer)
    assert json.loads(after.stdout) == report
    assert (tmp_path / "main.agc").read_text() == "def on_disk() -> Int\n  return 1\nend\n"
    # FILE need not exist, and an error of the buffer is a diagnostic of FILE.
    assert answer("--stdin", "new.agc", cwd=tmp_path, stdin=buffer)["file"] == "new.agc"
    broken = outline("--json", "outline", "--stdin", "main.agc", cwd=tmp_path, stdin="export def broken(\n")
    assert problem(broken, "LEX-UNCLOSED-DELIMITER", 1)["file"] == "main.agc"


@pytest.mark.parametrize("words", [
    [],  # missing FILE
    ["--stdin"],  # --stdin without FILE
    ["--stdin", "--json"],  # an option is not the FILE of --stdin
    ["--stdin", "a.agc", "--stdin", "b.agc"],  # --stdin twice
    ["one.agc", "two.agc"],  # extra argument
    ["--stdin", "one.agc", "two.agc"],  # a FILE besides --stdin FILE
    ["--unknown", "one.agc"],  # unknown option
    ["absent.agc"],  # unreadable path
    ["."],  # a folder is not a file
])
def test_a_mistake_in_the_question_is_query_usage_at_the_arguments(tmp_path, words):
    (tmp_path / "one.agc").write_text("def one() -> Int\n  return 1\nend\n", encoding="utf-8")
    diagnostic = problem(outline("--json", "outline", *words, cwd=tmp_path, stdin=""), "QUERY-USAGE", 2)
    assert diagnostic["file"] == "<arguments>"
    assert diagnostic["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 1}}


def test_ai_form_of_query_usage_has_no_empty_source_line(tmp_path):
    result = outline("--ai", "outline", cwd=tmp_path)
    assert (result.code, result.stdout) == (2, "")
    lines = result.stderr.split("\n")
    assert "[QUERY-USAGE]" in lines
    # The arguments are not a file: no source line, not even an empty one.
    assert not [line for line in lines if line.startswith("  source:")]


def test_a_file_with_crlf_line_ends_keeps_its_spans_and_docs(tmp_path):
    text = "## Adds.\r\nexport def add(a: Int) -> Int\r\n  return a\r\nend\r\n"
    (tmp_path / "crlf.agc").write_bytes(text.encode("utf-8"))
    add = items_by_name(answer("crlf.agc", cwd=tmp_path))["add"]
    assert (start(add["name_span"]), end(add["name_span"])) == ((2, 12), (2, 15))
    assert add["doc"] == "Adds."


def test_text_form_lists_one_line_per_declaration(tmp_path):
    (tmp_path / "shapes.agc").write_text(MODULE, encoding="utf-8")
    result = outline("outline", "shapes.agc", cwd=tmp_path)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        'shapes.agc:5:1 import Nowhere from "./nowhere"',
        'shapes.agc:6:1 import {first, Second as Other} from "./other"',
        "shapes.agc:9:1 export LIMIT: Int",
        "shapes.agc:11:1 PRIVATE_LIMIT",
        "shapes.agc:16:1 export enum Shape[T]",
        "shapes.agc:18:3 variant Shape.Circle(Float)",
        "shapes.agc:19:3 variant Shape.Rect(Float, Map[String, List[Int]])",
        "shapes.agc:23:1 struct Point",
        "shapes.agc:25:3 field Point.x: Int = 0",
        "shapes.agc:26:3 field Point.user: Nowhere.User",
        "shapes.agc:29:1 export type Grid[T] = List[List[T]]",
        "shapes.agc:32:1 export def add(a: Int, b: Int = 2) -> Int",
        "shapes.agc:36:1 def hidden(f: Fn[Int, String]) -> Nowhere.User",
        "",
    ]


# A resource of an extern block is an item of its own kind, with its doc, its export and the name of its free function
# in the signature; the functions of the block follow.
def test_a_resource_of_an_extern_block_is_a_resource_item(tmp_path):
    source = ('extern "libdb.so"\n  ## An open database.\n  export resource Db, free: db_close\n'
              "  def db_open(path: C.String) -> Db\nend\n")
    (tmp_path / "db.agc").write_text(source, encoding="utf-8")
    report = answer("db.agc", cwd=tmp_path)
    assert [(item["kind"], item["name"], item["exported"]) for item in report["items"]] == [
        ("resource", "Db", True), ("function", "db_open", False),
    ]
    db = items_by_name(report)["Db"]
    assert (db["signature"], db["doc"]) == ("resource Db, free: db_close", "An open database.")
    assert (start(db["span"]), start(db["name_span"]), end(db["name_span"])) == ((3, 3), (3, 19), (3, 21))


def test_a_facade_lists_its_reexports_with_the_docs_of_the_originals(tmp_path):
    models = "## Makes a user.\nexport def make(name: String) -> Int\n  return 1\nend\n"
    facade = 'import Models from "models"\n\nexport Models.make\n\ndef hidden() -> Int\n  return 1\nend\n'
    (tmp_path / "models.agc").write_text(models, encoding="utf-8")
    (tmp_path / "facade.agc").write_text(facade, encoding="utf-8")
    make = items_by_name(answer("facade.agc", cwd=tmp_path))["make"]
    assert (make["exported"], make["signature"], make["doc"]) == (True, "make(name: String) -> Int", "Makes a user.")
    assert (make["span"]["file"], start(make["name_span"]), end(make["name_span"])) == ("facade.agc", (3, 15), (3, 19))
    result = outline("outline", "facade.agc", cwd=tmp_path)
    assert result.stdout.split("\n")[1:3] == [
        "facade.agc:3:1 export def make(name: String) -> Int",
        "facade.agc:5:1 def hidden() -> Int",
    ]
