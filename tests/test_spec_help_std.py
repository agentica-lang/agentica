"""`agentica help std/MODULE[.NAME]` through the product CLI: the exports of a standard module, or one export, with
their `##` docs (docs/future/32-doc-comments.md, 32.6). The cases read the JSON form and assert fields, codes and exit
codes, never message text; one case reads the text form."""
import json

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import problem


def help_std(words, *flags, cwd):
    # A folder with no std/ of its own: the name is not a path of the disk.
    return run(cli() + [*flags, "help", *words], env=vm_environment(), cwd=cwd)


def test_a_module_lists_its_exports_with_their_summaries(tmp_path):
    result = help_std(["std/queue", "--json"], cwd=tmp_path)
    assert result.code == 0, result.stderr
    report = json.loads(result.stdout)
    assert set(report) == {"module", "doc", "items"}
    assert report["module"] == "std/queue" and report["doc"] is not None
    items = {item["name"]: item for item in report["items"]}
    assert set(items["pop"]) == {"kind", "name", "summary"}
    assert items["pop"]["kind"] == "function" and items["QueueState"]["kind"] == "struct"
    assert items["pop"]["summary"].startswith("Takes the oldest value.")
    # `doc` and `help` read the same module: the same exports, in the same order.
    documented = run(cli() + ["--json", "doc", "std/queue"], env=vm_environment(), cwd=tmp_path)
    assert [item["name"] for item in report["items"]] == [item["name"] for item in json.loads(documented.stdout)["items"]]


def test_one_function_has_the_fields_of_a_builtin_help(tmp_path):
    result = help_std(["std/queue.pop"], "--json", cwd=tmp_path)
    assert result.code == 0, result.stderr
    item = json.loads(result.stdout)
    assert item["name"] == "pop" and item["kind"] == "function" and item["module"] == "std/queue"
    assert item["signature"] == "pop(q: QueueState) -> Result[Popped]"
    assert (item["arity"], item["result"]) == (1, "Result[Popped]")
    assert item["parameters"] == [{"name": "q", "type": "QueueState", "default": None}]
    assert item["description"].startswith("Takes the oldest value.")
    assert item["summary"] == item["description"]
    assert "effects" not in item
    # The style may come before the command or after the name.
    assert help_std(["std/queue.pop", "--json"], cwd=tmp_path).stdout == result.stdout


def test_a_struct_lists_its_fields(tmp_path):
    item = json.loads(help_std(["std/queue.QueueState"], "--json", cwd=tmp_path).stdout)
    assert item["kind"] == "struct" and "arity" not in item
    assert item["fields"] == [
        {"name": "items", "type": "List[String]", "default": None, "doc": "The values, oldest first."},
    ]


def test_text_form(tmp_path):
    listed = help_std(["std/queue"], cwd=tmp_path)
    assert listed.code == 0, listed.stderr
    lines = listed.stdout.split("\n")
    assert lines[0] == "std/queue"
    assert "  pop(q: QueueState) -> Result[Popped]" in lines
    one = help_std(["std/queue.pop"], cwd=tmp_path)
    lines = one.stdout.split("\n")
    assert lines[0] == "pop(q: QueueState) -> Result[Popped]"
    assert lines[1].startswith("Takes the oldest value.")


def test_an_unknown_module_or_name_is_a_query_diagnostic(tmp_path):
    for words in (["std/nope"], ["std/prelude/list"], ["std/internal/websocket"], ["std//queue"]):
        diagnostic = problem(help_std(words, "--json", cwd=tmp_path), "QUERY-NOT-FOUND", 2)
        assert diagnostic["file"] == "<arguments>"
    # A name close to an export is offered; the plain form exits 2 too.
    diagnostic = problem(help_std(["std/queue.pup"], "--json", cwd=tmp_path), "QUERY-NOT-FOUND", 2)
    assert "pop" in diagnostic["help"]
    assert help_std(["std/queue.nope"], cwd=tmp_path).code == 2
    # A missing name after the dot is a mistake in the words.
    problem(help_std(["std/queue."], "--json", cwd=tmp_path), "QUERY-USAGE", 2)
