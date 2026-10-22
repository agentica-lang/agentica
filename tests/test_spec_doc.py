"""`agentica doc` through the product CLI: the exported API of one module with its `##` docs
(docs/future/32-doc-comments.md, 32.5). The cases read the JSON form and assert fields, spans and exit codes, never
message text; one case reads the Markdown form."""
import json

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import end, items_by_name, start

# A module with every kind of export, a private declaration of each kind that must be left out, and an import that does
# not exist: `doc` only parses, so the import cannot make it fail. Line numbers are asserted below.
MODULE = '''## Shapes and helpers.
##
## Second paragraph.

import Nowhere from "./nowhere"

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
  ## Nothing at all.
  Empty
end

## A point.
export struct Point
  ## The x position.
  x: Int
  user: Nowhere.User
end

struct Hidden
  value: Int
end

## A grid of cells.
export type Grid[T] = List[List[T]]

## Adds two numbers.
export def add(a: Int, b: Int = 2) -> Int
  return a + b
end

export def bare(f: Fn[Int, Map[String, List[Int]]]) -> Nowhere.User
  return f
end

## Documented but private.
def hidden() -> Int
  return 1
end
'''


def doc(path, *flags, cwd=None):
    return run(cli() + [*flags, "doc", str(path)], env=vm_environment(), cwd=cwd)


def test_exports_in_source_order_with_docs_and_spans(tmp_path):
    path = tmp_path / "shapes.agc"
    path.write_text(MODULE, encoding="utf-8")
    result = doc(path, "--json")
    assert result.code == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["module"] == str(path)
    assert report["doc"] == "Shapes and helpers.\n\nSecond paragraph."
    # Private declarations (even documented ones) are left out; the others keep their source order.
    assert [(item["kind"], item["name"]) for item in report["items"]] == [
        ("constant", "LIMIT"), ("enum", "Shape"), ("struct", "Point"), ("alias", "Grid"), ("function", "add"),
        ("function", "bare"),
    ]
    items = items_by_name(report)
    # The span is the whole declaration, `export` included, in the file as typed.
    assert items["Shape"]["span"]["file"] == str(path)
    assert start(items["Shape"]["span"]) == (15, 1)
    assert start(items["LIMIT"]["span"]) == (8, 1)
    # Lines and columns start at 1 and the end is exclusive: a declaration followed by a line break ends at the next
    # line, column 1. The span does not cover the `##` block above it.
    assert end(items["LIMIT"]["span"]) == (9, 1)

    # `export def`: the doc sits on the export, and an undocumented export is still listed.
    add = items["add"]
    assert add["signature"] == "add(a: Int, b: Int = 2) -> Int"
    assert (add["doc"], add["summary"]) == ("Adds two numbers.", "Adds two numbers.")
    assert add["parameters"] == [
        {"name": "a", "type": "Int", "default": None}, {"name": "b", "type": "Int", "default": "2"},
    ]
    assert add["result"] == "Int"
    bare = items["bare"]
    assert (bare["doc"], bare["summary"]) == (None, None)
    assert bare["signature"] == "bare(f: Fn[Int, Map[String, List[Int]]]) -> Nowhere.User"
    assert bare["result"] == "Nowhere.User"

    # The summary is the first paragraph; the doc is all of it.
    assert items["Shape"]["summary"] == "A shape."
    assert items["Shape"]["doc"] == "A shape.\n\nLonger text."
    assert items["Shape"]["signature"] == "enum Shape[T]"
    assert items["Shape"]["variants"] == [
        {"name": "Circle", "payload": ["Float"], "doc": "A circle with a radius."},
        {"name": "Rect", "payload": ["Float", "Map[String, List[Int]]"], "doc": None},
        {"name": "Empty", "payload": [], "doc": "Nothing at all."},
    ]
    assert items["Point"]["signature"] == "struct Point"
    assert items["Point"]["fields"] == [
        {"name": "x", "type": "Int", "doc": "The x position."},
        {"name": "user", "type": "Nowhere.User", "doc": None},
    ]
    assert items["Grid"]["signature"] == "type Grid[T] = List[List[T]]"
    assert items["LIMIT"]["signature"] == "LIMIT: Int"
    # A constant carries its own doc and an alias the doc of its export.
    assert items["LIMIT"]["doc"] == "The largest size."
    assert items["Grid"]["doc"] == "A grid of cells."


def test_a_trailing_json_flag_and_a_module_without_docs(tmp_path):
    path = tmp_path / "plain.agc"
    path.write_text("export def one() -> Int\n  return 1\nend\n", encoding="utf-8")
    before = doc(path, "--json")
    after = run(cli() + ["doc", str(path), "--json"], env=vm_environment())
    assert before.code == after.code == 0
    assert before.stdout == after.stdout
    report = json.loads(after.stdout)
    assert report["doc"] is None
    assert [(item["name"], item["doc"], item["summary"]) for item in report["items"]] == [("one", None, None)]


def test_std_module_comes_from_the_embedded_sources(tmp_path):
    # A folder with no std/ of its own: the name is not a path of the disk.
    result = run(cli() + ["--json", "doc", "std/queue"], env=vm_environment(), cwd=tmp_path)
    assert result.code == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["module"] == "std/queue"
    assert report["doc"] is not None
    items = items_by_name(report)
    assert items["QueueState"]["kind"] == "struct"
    assert items["pop"]["signature"] == "pop(q: QueueState) -> Result[Popped]"
    assert items["pop"]["span"]["file"] == "std/queue"


def test_markdown_form(tmp_path):
    path = tmp_path / "shapes.agc"
    path.write_text(MODULE, encoding="utf-8")
    result = doc(path)
    assert result.code == 0, result.stderr
    lines = result.stdout.split("\n")
    assert lines[0] == "# %s" % path
    assert "Shapes and helpers." in lines
    # An export is a heading with its signature, then its doc; a field or variant is a list line with its doc.
    heading = lines.index("## `add(a: Int, b: Int = 2) -> Int`")
    assert lines[heading + 2] == "Adds two numbers."
    assert "- `x: Int` - The x position." in lines
    assert "- `Rect(Float, Map[String, List[Int]])`" in lines
    assert "## `bare(f: Fn[Int, Map[String, List[Int]]]) -> Nowhere.User`" in lines
    assert not any("hidden" in line.lower() for line in lines)


def test_summary_skips_blank_lines_and_a_default_is_printed_as_written(tmp_path):
    path = tmp_path / "blank.agc"
    path.write_text(
        '##\n##\n## Leading blank.\n##  indented\n##\n## Second.\n##\n'
        'export def f(a: Int = -1, b: String = "x" + "y") -> Int\n  return a\nend\n\n'
        '##\n##\nexport def g() -> Int\n  return 1\nend\n',
        encoding="utf-8",
    )
    items = items_by_name(json.loads(doc(path, "--json").stdout))
    # The doc keeps its lines as written, less the blank ones at both ends; the summary is trimmed and on one line.
    assert items["f"]["doc"] == "Leading blank.\n indented\n\nSecond."
    assert items["f"]["summary"] == "Leading blank. indented"
    assert items["f"]["signature"] == 'f(a: Int = -1, b: String = "x" + "y") -> Int'
    assert [p["default"] for p in items["f"]["parameters"]] == ["-1", '"x" + "y"']
    assert (items["g"]["doc"], items["g"]["summary"]) == (None, None)


def test_a_lex_or_parse_error_exits_1_with_its_code(tmp_path):
    lexer = tmp_path / "lexer.agc"
    lexer.write_text("export def broken(\n", encoding="utf-8")
    parser = tmp_path / "parser.agc"
    parser.write_text('## Fine.\nexport def ok() -> Int\n  return 1\nend\n\nputs("x")\n', encoding="utf-8")
    for path, code, line in [(lexer, "LEX-UNCLOSED-DELIMITER", 1), (parser, "PARSE-TOP-LEVEL-STATEMENT", 6)]:
        result = doc(path, "--json")
        assert result.code == 1
        assert result.stdout == ""
        problem = json.loads(result.stderr)
        assert problem["code"] == code
        assert problem["file"] == str(path)
        assert problem["range"]["start"]["line"] == line


def test_an_unreadable_path_or_a_wrong_command_line_exits_2(tmp_path):
    assert doc(tmp_path / "absent.agc", "--json").code == 2
    # A `std/` name gets the checks of an import: only plain parts, and never the compiler prelude.
    for name in ["std/nothing", "std/../x", "std/prelude/lazy"]:
        assert run(cli() + ["doc", name], env=vm_environment(), cwd=tmp_path).code == 2
    assert run(cli() + ["doc"], env=vm_environment()).code == 2
    assert run(cli() + ["doc", "a.agc", "b.agc"], env=vm_environment()).code == 2


# An exported resource is documented with its kind and signature; a private one is left out.
def test_an_exported_resource_is_documented_and_a_private_one_is_not(tmp_path):
    path = tmp_path / "db.agc"
    path.write_text('extern "libdb.so"\n  ## An open database.\n  export resource Db, free: db_close\n'
                    "  resource Row, free: row_free\n  export def db_open(path: C.String) -> Db\nend\n",
                    encoding="utf-8")
    result = doc(path, "--json")
    assert (result.code, result.stderr) == (0, "")
    report = json.loads(result.stdout)
    assert [(item["kind"], item["name"]) for item in report["items"]] == [("resource", "Db"), ("function", "db_open")]
    db = items_by_name(report)["Db"]
    assert (db["signature"], db["summary"], start(db["span"])) == (
        "resource Db, free: db_close", "An open database.", (3, 3))
    assert items_by_name(report)["db_open"]["result"] == "Result[Db]"
