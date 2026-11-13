"""`agentica help std/MODULE[.NAME]` through the product CLI: the exports of a standard module, or one export, with
their `##` docs. The cases read the JSON form and assert fields, codes and exit
codes, never message text; one case reads the text form."""
import json

from tests.agentica_test import ROOT, cli, run, vm_environment
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
    assert item["signature"] == "pop(queue: QueueState) -> Result[Popped]"
    assert (item["arity"], item["result"]) == (1, "Result[Popped]")
    assert item["parameters"] == [{"name": "queue", "type": "QueueState", "default": None}]
    assert item["description"].startswith("Takes the oldest value.")
    assert item["summary"] == item["description"]
    assert "effects" not in item
    # The style may come before the command or after the name.
    assert help_std(["std/queue.pop", "--json"], cwd=tmp_path).stdout == result.stdout


def test_a_parameter_default_and_a_variant_payload(tmp_path):
    mime = json.loads(help_std(["std/mime.mime_type"], "--json", cwd=tmp_path).stdout)
    assert mime["parameters"][1] == {
        "name": "fallback", "type": "String", "default": '"application/octet-stream"',
    }
    value = json.loads(help_std(["std/toml.Value"], "--json", cwd=tmp_path).stdout)
    assert value["kind"] == "enum" and "arity" not in value
    first = value["variants"][0]
    assert (first["name"], first["payload"]) == ("Str", ["String"])


def test_the_builtin_types_that_a_std_module_re_exports_are_listed_with_their_fields(tmp_path):
    # std/logger re-exports LogRegistry.Event and LogRegistry.Level, which no file declares: help and doc list them.
    names = [item["name"] for item in json.loads(help_std(["std/logger", "--json"], cwd=tmp_path).stdout)["items"]]
    documented = json.loads(run(cli() + ["--json", "doc", "std/logger"], env=vm_environment(), cwd=tmp_path).stdout)
    assert {"Event", "Level"} <= set(names)
    assert names == [item["name"] for item in documented["items"]]
    event = json.loads(help_std(["std/logger.Event"], "--json", cwd=tmp_path).stdout)
    assert event["kind"] == "struct"
    # A field and a signature write a re-exported type as a program does (Logger.Level), not by its builtin name.
    assert [(field["name"], field["type"]) for field in event["fields"]][:2] == [
        ("level", "Logger.Level"), ("message", "String"),
    ]
    level = json.loads(help_std(["std/logger.Level"], "--json", cwd=tmp_path).stdout)
    assert level["kind"] == "enum"
    assert [variant["name"] for variant in level["variants"]] == ["Debug", "Info", "Warning", "Error"]
    attach = json.loads(help_std(["std/logger.attach"], "--json", cwd=tmp_path).stdout)
    assert attach["signature"] == (
        "attach(name: String, level: Logger.Level, handler: Fn[Logger.Event, Void]) -> Result[Void]")


def test_std_http_lists_its_builtin_records_and_handles(tmp_path):
    # std/http re-exports the HttpWire records and the two handles: help lists them, a handle as a resource, and the
    # signatures write them as HTTP.X, a default value too.
    names = [item["name"] for item in json.loads(help_std(["std/http", "--json"], cwd=tmp_path).stdout)["items"]]
    assert {"Request", "Response", "Header", "ClientOptions", "ServerOptions", "Client", "Server"} <= set(names)
    response = json.loads(help_std(["std/http.Response"], "--json", cwd=tmp_path).stdout)
    assert response["kind"] == "struct"
    assert [(field["name"], field["type"]) for field in response["fields"]] == [
        ("status", "Int"), ("headers", "List[HTTP.Header]"), ("body", "Bytes")]
    client = json.loads(help_std(["std/http.Client"], "--json", cwd=tmp_path).stdout)
    assert client["kind"] == "resource"
    made = json.loads(help_std(["std/http.client"], "--json", cwd=tmp_path).stdout)
    assert made["signature"] == "client(options: HTTP.ClientOptions = HTTP.ClientOptions()) -> Result[HTTP.Client]"


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
    assert "  pop(queue: QueueState) -> Result[Popped]" in lines
    # A list line is the first sentence only; the JSON summary keeps the whole paragraph.
    assert "      Takes the oldest value." in lines
    long = help_std(["std/mime"], cwd=tmp_path).stdout.split("\n")
    shown = long[long.index(next(x for x in long if x.startswith("  mime_type("))) + 1]
    assert shown.endswith("…") and len(shown) <= 6 + 101
    one = help_std(["std/queue.pop"], cwd=tmp_path)
    lines = one.stdout.split("\n")
    assert lines[0] == "pop(queue: QueueState) -> Result[Popped]"
    assert lines[1].startswith("Takes the oldest value.")


def test_an_unknown_module_or_name_is_a_query_diagnostic(tmp_path):
    for words in (["std"], ["std/"], ["std/nope"], ["std/prelude/list"], ["std/internal/websocket"], ["std//queue"]):
        diagnostic = problem(help_std(words, "--json", cwd=tmp_path), "QUERY-NOT-FOUND", 2)
        assert diagnostic["file"] == "<arguments>"
    # A name close to an export is offered; the plain form exits 2 too.
    diagnostic = problem(help_std(["std/queue.pup"], "--json", cwd=tmp_path), "QUERY-NOT-FOUND", 2)
    assert "pop" in diagnostic["help"]
    assert help_std(["std/queue.nope"], cwd=tmp_path).code == 2
    # A missing name after the dot is a mistake in the words.
    problem(help_std(["std/queue."], "--json", cwd=tmp_path), "QUERY-USAGE", 2)


# Named arguments make parameter names public: every builtin and std/ parameter name has at least two characters.
# scrypt keeps its own n, r and p.
SHORT_NAMES = {("OpenSSL.KDF.scrypt", "n"), ("OpenSSL.KDF.scrypt", "r"), ("OpenSSL.KDF.scrypt", "p")}


def test_every_builtin_and_std_parameter_name_has_two_characters_or_more(tmp_path):
    found = set()
    for builtin in json.loads(run(cli() + ["help", "--json"], env=vm_environment(), cwd=tmp_path).stdout):
        if "kind" in builtin:
            continue  # a builtin type: it has fields, not parameters
        for form in builtin.get("overloads", [builtin]):
            found |= {(form["name"], parameter["name"]) for parameter in form["parameters"]}
    modules = (ROOT / "stdlib" / "MODULES").read_text(encoding="utf-8").split()
    for module in [name.removesuffix(".agc") for name in modules if not name.startswith(("prelude/", "internal/"))]:
        documented = run(cli() + ["--json", "doc", f"std/{module}"], env=vm_environment(), cwd=tmp_path)
        assert documented.code == 0, documented.stderr
        for item in json.loads(documented.stdout)["items"]:
            found |= {(f"std/{module}.{item['name']}", parameter["name"]) for parameter in item.get("parameters", [])}
    assert {pair for pair in found if len(pair[1]) < 2} == SHORT_NAMES
