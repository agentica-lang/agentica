"""examples/*.agc, rejected fragments and the Ruby names of the methods. The CLI exit codes, options and `help`
outputs are rows of tests/fixtures/cli/forms.json (test_cli_forms.py).

Each case runs the CLI as a child (`cli()`), like the original test did in
process. The two cases that the original file ran both in process and as a
subprocess run once here. The algorithm examples (knight tour, traveling
salesman, maze) read JSON from stdin and are checked by their properties, not
by one fixed answer; the slow tier has the full list of malformed inputs.
"""
import http.client
import itertools
import json
import os
import re
import signal
import socket
import time

import pytest

from tests.agentica_test import ROOT, WINDOWS, Child, cli, host_only, run, scaled, vm_environment, wait_readable
from tests.spec_support import check_diagnostic

EXAMPLES = ROOT / "examples"
STEP_BUDGET = "5000000"
WAIT_SECONDS = scaled(20)

# A name -> exact stdout table for the examples of one fixed output; the JSON examples add their stdin.
VALID_EXAMPLES = [
    ("hello.agc", "hello\n"),
    ("classify.agc", "adult\n"),
    ("result.agc", "42\nempty count\n0\n"),
    ("json.agc", '{"name":"Ana","age":25}\nhello, Ana\nmissing name\n'),
    ("tasks.agc", "Probar Agentica\n"),
    ("dispatch.agc", "42\n"),
    ("queue.agc", "first\nsecond\n"),
    ("inventory.agc", "apple\nkiwi\n"),
    ("strings.agc", "AGENTICA, HELLO\n8\n5\nAgentica, world\n"),
    ("blocks.agc", "cocoa: 3.0\ntea: 4.0\nunits: 15\nany empty: true\n"),
    ("constants.agc", "8 | 32\n5\nfruit | drink\n3\n"),
    ("module-blocks.agc", "apples: 0 items\npears: 3 items\n"),
    ("actor.agc", "counter: visits is taken\nok(110)\nok()\nerror(\"key \\\"visits\\\" is not in the table\")\nok()\n"),
    ("defaults.agc", "Level.Info start 0\nLevel.Warn slow 1\na, b, c\na-b-c\none\ntwo\n- one\n- two\n"
                     "- three\n"),
    ("enumerable.agc", "big order: eve\n"
                      "not found\n"
                      "cheapest: ana\n"
                      "most items: eve\n"
                      "tie: bob\n"
                      "ana: 5 items\n"
                      "bob: 1 items\n"
                      "eve: 5 items\n"
                      "{\"ana\": 2, \"bob\": 1, \"eve\": 1}\n"
                      "[\"ana\", \"bob\", \"eve\"]\n"
                      "revenue: 63.0\n"
                      "3 large, 1 small\n"
                      "[[1, 2, 3], [4, 5, 6], [7]]\n"
                      "[1, 2, 3]\n"
                      "[4, 5, 6, 7]\n"
                      "[\"a\", \"A\", \"b\", \"B\"]\n"
                      "0: x\n"
                      "1: y\n"
                      "-1\n"
                      "[\"ana\"]\n"),
    ("shared-cache.agc", "letters per worker: [87]\nlookups: 24\nstored: 6\n1 squared is 1\n2 squared is 4\n"
                         "3 squared is 9\n4 squared is 16\n5 squared is 25\n6 squared is 36\n"),
    ("generic-structs.agc", "[20, 40, 60]\nANA\npage 2: 2 item(s)\npage 3: 0 item(s)\n"
                            "Page(items: [\"ana\", \"ben\"], number: 9)\n"),
    ("generic-functions.agc", "ana\n0\nbanana\n6\n7\n42\n"),
    ("case-guards.agc", "big circle\nempty circle\ntwin\ndot\nnegative -3\nvalue 8\nmissing\n"
                        "timed out\n"),
    ("heredoc.agc", "Usage: tool [options] FILE\n\n  --verbose   print more\n"
                    "  --version   print 2.0 and stop\n\nExit code 0 on success.\n"
                    "NOTES\nfirst line\n  indented line\n14\n")]

JSON_EXAMPLES = [
    ("json-config.agc", '{"service":{"name":"api","port":8080,"enabled":false}}',
     '{"name":"api","port":8080,"enabled":false}\n'),
    ("json-config.agc", '{"service":{"name":"api","port":0,"enabled":true}}',
     '{"error":"invalid config"}\n'),
    ("json-expenses.agc",
     '[{"category":"food","amount":1200},{"category":"travel","amount":500},{"category":"food","amount":-200}]',
     '{"totals":{"food":1000,"travel":500}}\n'),
    ("json-expenses.agc", '[{"category":"food","amount":true}]', '{"error":"invalid expense"}\n'),
    ("json-lines.agc",
     '{"name":"Ana","score":75,"active":true}\nnot json\n{"name":"Luis","score":60,"active":false}\n',
     '{"name":"Ana","passed":true}\n{"error":"invalid record"}\n{"name":"Luis","passed":false}\n'),
    ("json-lines.agc", '{"name":"Ana","score":101,"active":true}\n', '{"error":"invalid record"}\n')]

NON_JSON_EXAMPLES = ["maze-bfs.agc", "knight-tour.agc", "traveling-salesman.agc"]


def compact(value):
    return json.dumps(value, separators=(",", ":"))


@pytest.fixture
def program(tmp_path):
    """A fresh temp file holding a program (the original gave each call its own folder); returns its path."""
    count = itertools.count()

    def write(text):
        path = tmp_path / ("program-%d.agc" % next(count))
        path.write_text(text, encoding="utf-8")
        return path

    return write




def cli_run(*arguments, stdin=b""):
    """The CLI run to its end; returns Result(code, stdout, stderr)."""
    return run(cli() + [str(argument) for argument in arguments], stdin=stdin, env=vm_environment())


def run_text_io(program, text, stdin="", max_steps=None):
    """Run program text with --json; returns (stdout, None) on exit 0, else (stdout, the code of the diagnostic)."""
    arguments = ["--json"] + (["--max-steps", str(max_steps)] if max_steps else []) + [program(text)]
    result = cli_run(*arguments, stdin=stdin.encode("utf-8"))
    if result.code == 0:
        return result.stdout, None
    lines = [line for line in result.stderr.split("\n") if line]
    try:
        data = json.loads(lines[-1])
    except (IndexError, ValueError):
        data = None
    assert isinstance(data, dict) and isinstance(data.get("code"), str), \
        "exit %s without a JSON diagnostic on stderr: %r" % (result.code, result.stderr)
    return result.stdout, data["code"]


def run_example(program, name, stdin="", max_steps=None):
    return run_text_io(program, (EXAMPLES / name).read_text(encoding="utf-8"), stdin, max_steps)


def code_of(program, body):
    return run_text_io(program, "def main() -> Void\n%s\nend\n\n" % body)[1]


def read_until(child, done, what):
    """Read the child's stdout bytes one at a time until done(bytes) is true; fail after WAIT_SECONDS."""
    fd = child.process.stdout.fileno()
    data = b""
    deadline = time.monotonic() + WAIT_SECONDS
    while not done(data):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not wait_readable(fd, remaining):
            raise AssertionError(what)
        chunk = os.read(fd, 1)
        if not chunk:
            raise AssertionError("stdout ended: " + what)
        data += chunk
    return data


@pytest.mark.parametrize("name,expected", VALID_EXAMPLES, ids=[name for name, _ in VALID_EXAMPLES])
def test_valid_examples_run_with_the_expected_output(program, name, expected):
    output, code = run_example(program, name)
    assert code is None, name
    assert output == expected, name


def test_file_task_process_and_http_examples_give_their_expected_output():
    def example(name):
        return str(EXAMPLES / name)

    assert cli_run(example("concurrency.agc")) == (0, "42\n14\n", "")
    assert cli_run(example("file-summary.agc"), example("hello.agc")) == (0, "39\n", "")
    assert cli_run(example("http_server.agc")) == (0, "200\nhello\n\n404\nok()\n", "")
    assert cli_run(example("http_sse.agc")) == (
        0, '200\n["chunked"]\ndata: tick 1\n\ndata: tick 2\n\ndata: tick 3\n\n\n404\nok()\n', "")
    tool = cli_run(example("process-tool.agc"))
    assert tool.code == 0, tool.stderr
    assert (tool.stdout, tool.stderr) == ("hello from sh\n", "")


@host_only(WINDOWS, "POSIX signals: System.subscribe takes no signal on Windows")
def test_http_server_example_stops_gracefully_on_sigterm(adopt):
    """`http_server.agc serve` under SIGTERM: the request in flight gets its answer, a new connection is refused and
    the program ends with 0."""
    server = adopt(Child(cli() + [str(EXAMPLES / "http_server.agc"), "serve"], env=vm_environment(),
                         capture_stderr=True))
    port = int(server.next_line())
    slow = http.client.HTTPConnection("127.0.0.1", port, timeout=scaled(10))
    slow.request("GET", "/slow")
    time.sleep(0.2)
    server.process.send_signal(signal.SIGTERM)
    response = slow.getresponse()
    assert (response.status, response.read(), response.getheader("Connection")) == (200, b"done\n", "close")
    slow.close()
    assert server.wait() == 0
    assert server.next_line() == "stopped"
    with pytest.raises(ConnectionRefusedError):
        socket.create_connection(("127.0.0.1", port), timeout=scaled(2)).close()


def test_echo_agc_reads_and_echoes_standard_input(program):
    output, code = run_example(program, "echo.agc", "one\ntwo\n")
    assert code is None
    assert output == "one\ntwo\n"


@pytest.mark.parametrize("name,stdin,expected", JSON_EXAMPLES,
                         ids=["%s-%d" % (name, index) for index, (name, _, _) in enumerate(JSON_EXAMPLES)])
def test_json_examples_validate_documents_and_recover_within_streams(program, name, stdin, expected):
    output, code = run_example(program, name, stdin)
    assert code is None, name
    assert output == expected, name


def test_knight_tours_cover_every_square_exactly_once_with_legal_moves(program):
    text = (EXAMPLES / "knight-tour.agc").read_text(encoding="utf-8")
    for size, start in [(1, 0), (5, 0), (8, 0), (8, 27)]:
        out, code = run_text_io(program, text, compact({"size": size, "start": start}), max_steps=STEP_BUDGET)
        assert code is None
        data = json.loads(out)
        assert data["found"] is True
        path = data["path"]
        assert path[0] == start
        assert sorted(path) == list(range(size * size))
        for source, target in zip(path, path[1:]):
            dx = abs(source % size - target % size)
            dy = abs(source // size - target // size)
            assert sorted([dx, dy]) == [1, 2]
    out, code = run_text_io(program, text, '{"size":3,"start":0}', max_steps=STEP_BUDGET)
    assert code is None
    assert json.loads(out) == {"found": False, "path": []}


def test_traveling_salesman_returns_an_optimal_complete_circuit(program):
    text = (EXAMPLES / "traveling-salesman.agc").read_text(encoding="utf-8")
    for matrix, cost in [
            ([[0]], 0),
            ([[0, 10, 15, 20], [10, 0, 35, 25], [15, 35, 0, 30], [20, 25, 30, 0]], 80),
            ([[0, 1, 9], [9, 0, 1], [1, 9, 0]], 3),
            ([[0, 1, 2, 2], [1, 0, 1, 2], [2, 1, 0, 100], [2, 2, 100, 0]], 7),
            ([[0, 0, 0], [0, 0, 0], [0, 0, 0]], 0),
            ([[0, 1000000000], [1000000000, 0]], 2000000000)]:
        out, code = run_text_io(program, text, compact({"distances": matrix}), max_steps=STEP_BUDGET)
        assert code is None
        data = json.loads(out)
        route = data["route"]
        assert data["cost"] == cost
        assert route[0] == 0
        assert route[-1] == 0
        assert sorted(route[:-1]) == list(range(len(matrix)))
        assert sum(matrix[source][target] for source, target in zip(route, route[1:])) == data["cost"]


def test_maze_bfs_returns_shortest_legal_paths_and_reports_unreachable_goals(program):
    text = (EXAMPLES / "maze-bfs.agc").read_text(encoding="utf-8")
    for grid, start, goal, expected_distance in [
            (["."], 0, 0, 0),
            (["...."], 3, 0, 3),
            (["...", "..."], 2, 3, 3),
            ([".#.", "..."], 0, 2, 4),
            (["...", "...", "..."], 0, 8, 4),
            ([".#.", "###", "..."], 0, 8, -1),
            (["." * 32] * 32, 0, 1023, 62)]:
        width = len(grid[0])
        out, code = run_text_io(program, text, compact({"grid": grid, "start": start, "goal": goal}),
                                max_steps=STEP_BUDGET)
        assert code is None
        data = json.loads(out)
        assert data["found"] == (expected_distance >= 0)
        assert data["distance"] == expected_distance
        path = data["path"]
        if expected_distance < 0:
            assert path == []
            continue
        assert len(path) == expected_distance + 1
        assert path[0] == start
        assert path[-1] == goal
        assert len(set(path)) == len(path)
        for square in path:
            assert type(square) is int and 0 <= square < width * len(grid)
            assert grid[square // width][square % width] == "."
        for source, target in zip(path, path[1:]):
            assert abs(source // width - target // width) + abs(source % width - target % width) == 1


@pytest.mark.parametrize("name", NON_JSON_EXAMPLES, ids=NON_JSON_EXAMPLES)
def test_algorithm_examples_reject_input_that_is_not_json(program, name):
    out, code = run_example(program, name, "not JSON", max_steps=STEP_BUDGET)
    assert code is None
    assert json.loads(out) == {"error": "invalid input"}


def test_stdio_peers_receive_flushed_replies_while_stdin_stays_open(program, adopt):
    program_path = program(
        "def main() -> Void\n"
        "  IO.inspect(IO.eof?())\n  IO.flush()\n"
        "  data = Result.unwrap!(IO.read_bytes(2))\n"
        "  IO.print(Result.unwrap!(String.from_bytes(data)))\n  IO.flush()\n"
        "  puts(IO.gets!())\nend\n\n")
    child = adopt(Child(cli() + [program_path], env=vm_environment(), stdin=True, capture_stderr=True,
                        read_stdout=False))
    # Only the first byte of the two-byte letter (U+00F1) is available. EOF peeking must not decode it.
    child.process.stdin.write(bytes([195]))
    child.process.stdin.flush()
    first = read_until(child, lambda data: data.endswith(b"\n"),
                       "initial reply was not flushed, or EOF peeking blocked on UTF-8")
    assert first == b"false\n"
    assert child.process.poll() is None
    child.process.stdin.write(bytes([177]))
    child.process.stdin.flush()
    second = read_until(child, lambda data: len(data) >= 2, "response remained buffered")
    assert second.decode("utf-8") == "\u00f1"
    assert child.process.poll() is None
    child.process.stdin.write(b"done\n")
    child.close_stdin()
    assert child.wait(WAIT_SECONDS) == 0
    assert child.process.stdout.read().decode() == "done\n"
    assert child.stderr_text() == ""


def test_rejected_fragments_fail_with_the_intended_code(program):
    assert code_of(program, '  age: Int = "25"') == "CHECK-TYPE-MISMATCH"
    assert code_of(program, '  if 1\n    puts("hello")\n  end') == "CHECK-TYPE-MISMATCH"
    assert code_of(program, "  values = []") == "CHECK-EMPTY-LIST-TYPE"
    assert code_of(program, '  puts "hello"') == "PARSE-UNEXPECTED-TOKEN"


def check_table(name):
    """The text of one function of the checker tables (compiler/check/check_tables.agc)."""
    text = (ROOT / "compiler" / "check" / "check_tables.agc").read_text(encoding="utf-8")
    start = text.index("def %s() -> " % name)
    return text[start:text.index("\nend\n", start)]


def test_every_alias_of_the_checker_tables_names_a_public_builtin():
    catalog = {builtin["name"] for builtin in json.loads(cli_run("help", "--json").stdout)}
    for target in re.findall(r'": "([A-Za-z]+\.[^"]+)"', check_table("method_aliases")):
        assert target in catalog, target
    # ruby_form.agc reads each synonym in method_aliases: a synonym that the table lacks would name nothing.
    aliases = set(re.findall(r'^    "([^"]+)": "', check_table("method_aliases"), re.MULTILINE))
    synonyms = re.findall(r'"([A-Za-z]+\.[^"]+)"', check_table("ruby_synonyms"))
    assert synonyms and set(synonyms) <= aliases
    # Two non-synonym aliases of one builtin would make its shown name depend on the sort order of the keys, and a
    # hint for a name that resolves would never be read.
    shown = [target for key, target in re.findall(r'^    "([^"]+)": "([^"]+)"', check_table("method_aliases"),
                                                  re.MULTILINE) if key not in synonyms and target != "self"]
    assert len(shown) == len(set(shown))
    hints = set(re.findall(r'^    "([^"]+)": ', check_table("foreign_kind_methods"), re.MULTILINE))
    # (`String.to_s` returns the receiver: its hint is a remark, not a refusal.)
    assert not hints & aliases - {"String.to_s"}
    # A foreign method name that stands for no builtin would answer `unknown builtin`. (No name answers with more
    # than the 8 builtins that cli_alias.agc lists, so none is dropped as too vague.)
    # A name with a hint of its own in foreign_names (`len`) answers that hint instead.
    hinted = set(re.findall(r'^    "([^"]+)": ', check_table("foreign_names"), re.MULTILINE))
    for name in re.findall(r'^    "([^"]+)": \[', check_table("foreign_methods"), re.MULTILINE):
        assert cli_run("help", name).code == (2 if name in hinted else 0), name


def test_length_and_size_run_on_every_kind(program):
    body = ('  m: Map[String, Int] = {"a": 1}\n'
            '  puts("ab".length + "ab".size + [1].length + [1].size + m.length + m.size)\n'
            '  puts(Set.new([1, 2]).length + Set.new([1, 2]).size)\n  puts((1..4).length)\n  puts((1...4).length)\n'
            '  puts((1..4).size)')
    out, code = run_text_io(program, "def main() -> Void\n%s\nend\n\n" % body)
    assert (out, code) == ("8\n4\n4\n3\n4\n", None)


SYNONYMS = [
    ("xs.collect do |x| x * 2 end", "xs.map do |x| x * 2 end"),
    ("xs.select do |x| x > 1 end", "xs.filter do |x| x > 1 end"),
    ("xs.inject(10) do |a, x| a + x end", "xs.reduce(10) do |a, x| a + x end"),
    ("xs.detect do |x| x > 1 end", "xs.find do |x| x > 1 end"),
    ("m.select do |_, v| v > 1 end", "m.filter do |_, v| v > 1 end"),
    ("m.key?(\"a\")", "m.has_key?(\"a\")"),
    ("m.include?(\"a\")", "m.has_key?(\"a\")"),
    ("m.member?(\"z\")", "m.has_key?(\"z\")"),
    ("Set.new([1]).member?(1)", "Set.new([1]).include?(1)"),
    ("(1..3).member?(2)", "(1..3).include?(2)"),
    ("xs.lazy.collect { |x| x + 1 }.select { |x| x > 2 }.to_a",
     "xs.lazy.map { |x| x + 1 }.filter { |x| x > 2 }.to_a"),
]


def test_a_ruby_synonym_runs_like_its_base_name(program):
    for synonym, base in SYNONYMS:
        outputs = []
        for expression in (synonym, base):
            source = ("def main() -> Void\n  xs = [1, 2, 3]\n  m = {\"a\": 1, \"b\": 2}\n"
                      "  _ = xs\n  _ = m\n  puts(%s)\nend\n\n" % expression)
            outputs.append(run_text_io(program, source))
        assert outputs[0] == outputs[1] and outputs[0][1] is None, synonym


def test_a_list_of_methods_leaves_out_the_synonyms(tmp_path):
    source = "def main() -> Void\n  xs: List[Int] = [1]\n  puts(xs.zzzzzzzz)\nend\n\n"
    found = check_diagnostic(source, tmp_path)
    assert found["code"] == "CHECK-UNKNOWN-METHOD"
    listed = found["help"].split(": ", 1)[1].split(", ")
    assert {"map", "select", "reduce", "find", "first", "last", "empty?"} <= set(listed)
    assert not {"collect", "inject", "detect", "filter", "length"} & set(listed)


def test_first_and_last_halt_on_an_empty_list_and_empty_asks_the_three_kinds(program):
    for method in ("first", "last"):
        # The halt is at the call, as xs[0] is, never inside the prelude.
        body = "  xs: List[Int] = []\n  puts(xs.%s)" % method
        result = cli_run("--json", program("def main() -> Void\n%s\nend\n\n" % body))
        found = json.loads([line for line in result.stderr.split("\n") if line][-1])
        assert found["code"] == "RUNTIME-INDEX-OUT-OF-RANGE"
        assert found["range"]["start"] == {"line": 3, "column": 8}
    body = ('  xs = [3, 4, 5]\n  e: List[Int] = []\n  m: Map[String, Int] = {"a": 1}\n  n: Map[String, Int] = {}\n'
            '  puts([xs.first, xs.last])\n  puts([xs.empty?, e.empty?, m.empty?, n.empty?, "".empty?, "a".empty?])')
    out, code = run_text_io(program, "def main() -> Void\n%s\nend\n\n" % body)
    assert (out, code) == ("[3, 5]\n[false, true, false, true, true, false]\n", None)


def test_the_helps_of_diagnostics_name_the_ruby_form_not_the_builtin(tmp_path):
    for expression, code, help_text in [
            ('String.trim("a")', "CHECK-UNKNOWN-NAME", "use s.strip"),
            ('"a" |> String.strip()', "CHECK-PIPE-METHOD", 'write the method: "a".strip or "a" |> strip()')]:
        source = "def main() -> Void\n  puts(%s)\nend\n\n" % expression
        found = check_diagnostic(source, tmp_path)
        assert (found["code"], found["help"]) == (code, help_text), expression
    # A call in method form counts the arguments after the receiver and names the Ruby method; the callee note keeps
    # the signature of the catalog.
    for expression, name, internal in [('"a".include?()', "string.include?", "String.include?"),
                                       ("[1].push()", "list.push", "List.append"),
                                       ('"a".strip(1)', "string.strip", "String.strip"),
                                       ("m.length(1)", "map.size", "Map.size"),
                                       ("[1].filter(1, 2)", "list.select", "List.filter"),
                                       ("[1].collect()", "list.map", "List.map"),
                                       ("m.has_key?()", "map.key?", "Map.has_key?")]:
        source = ("def main() -> Void\n  m: Map[String, Int] = {}\n  puts(%s)\nend\n\n" % expression)
        found = check_diagnostic(source, tmp_path)
        assert found["code"] == "CHECK-ARITY", expression
        assert found["message"].startswith('"%s" expects' % name), expression
        assert found["callee"].startswith(internal + "("), expression


def test_an_unknown_method_suggests_the_ruby_method(tmp_path):
    for expression, suggested in [("r.value!", "unwrap!"), ("r.ok!", "unwrap!"), ("m.len", "length"),
                                  ('"a".len', "size"), ('"a".contains("a")', "include?"),
                                  ('"a".includes("a")', "include?"), ('"a".include("a")', "include?"),
                                  ("xs.contains?(1)", "any?"), ("(1..3).drop(1)", "to_a"),
                                  ('"abc".take(2)', "join"), ('"abc".drop(1)', "join"),
                                  ('"abc".count("a")', "split")]:
        source = ("def main() -> Void\n  xs: List[Int] = [1]\n  m: Map[String, Int] = {}\n"
                  "  r: Result[Int] = ok(1)\n  puts(%s)\nend\n\n" % expression)
        found = check_diagnostic(source, tmp_path)
        assert found["code"] == "CHECK-UNKNOWN-METHOD", expression
        assert suggested in found["help"], expression


def test_count_without_a_block_points_to_size(tmp_path):
    source = "def main() -> Void\n  xs: List[Int] = [1]\n  puts(xs.count)\nend\n"
    found = check_diagnostic(source, tmp_path)
    assert found["code"] == "CHECK-ARITY" and "xs.size" in found["help"]


def test_new_diagnostics_retain_their_codes_across_the_three_printers(program):
    path = program("")
    for body, code in [
            ("  _x = List.repeat(1, -1)", "RUNTIME-INVALID-COUNT"),
            ('  r = error("bad")', "CHECK-RESULT-TYPE"),
            ("  r = try ok(1)", "CHECK-TRY-CONTEXT"),
            ("  x = JSON.encode({1: true})", "CHECK-NOT-ENCODABLE"),
            ("  large = 1.0\n  i = 0\n  while i < 40\n    large = large * 1000000000.0\n    i = i + 1\n  end\n"
             "  _x = JSON.encode(large)", "RUNTIME-JSON-ENCODE"),
            ('  r: Result[Int] = error("bad")\n  _x = Result.unwrap!(r)', "RUNTIME-UNWRAP-ERROR")]:
        path.write_text("def main() -> Void\n%s\nend\n\n" % body, encoding="utf-8")
        for style in ("plain", "--ai", "--json"):
            result = cli_run(*([] if style == "plain" else [style]), path)
            assert result.code == 1, code + " " + style
            assert result.stdout == ""
            if style == "--json":
                data = json.loads(result.stderr)
                assert data["code"] == code
                assert "range" in data
            else:
                assert code in result.stderr


# Slow tier: the full list of malformed inputs, one run each. The fast tier keeps one input per program.

@pytest.mark.slow
def test_algorithm_examples_reject_malformed_input_before_producing_a_solution(program):
    maze = (EXAMPLES / "maze-bfs.agc").read_text(encoding="utf-8")
    for grid in (["." * 33], ["."] * 33):
        out, code = run_text_io(program, maze, compact({"grid": grid, "start": 0, "goal": 0}),
                                max_steps=STEP_BUDGET)
        assert code is None
        assert json.loads(out) == {"error": "invalid input"}
    for name, *inputs in [
            ("maze-bfs.agc", "not JSON", '{"grid":[],"start":0,"goal":0}', '{"grid":[""],"start":0,"goal":0}',
             '{"grid":["..","."],"start":0,"goal":1}', '{"grid":["..",".x"],"start":0,"goal":1}',
             '{"grid":["..",false],"start":0,"goal":1}', '{"grid":[".."],"start":true,"goal":1}',
             '{"grid":[".."],"start":0,"goal":1.0}', '{"grid":[".."],"start":-1,"goal":1}',
             '{"grid":[".."],"start":0,"goal":2}', '{"grid":["#."],"start":0,"goal":1}',
             '{"grid":[".#"],"start":0,"goal":1}', '{"grid":[".."],"start":0}'),
            ("knight-tour.agc", "not JSON", '{"size":0,"start":0}', '{"size":9,"start":0}',
             '{"size":8,"start":64}', '{"size":8,"start":-1}', '{"size":true,"start":0}', '{"size":8}'),
            ("traveling-salesman.agc", "not JSON", '{"distances":[]}', '{"distances":[[0,1],[1]]}',
             '{"distances":[[1]]}', '{"distances":[[0,-1],[1,0]]}', '{"distances":[[0,1],[false,0]]}',
             '{"distances":[[0,1],[1,0.0]]}', '{"distances":[[0,1000000001],[1,0]]}')]:
        text = (EXAMPLES / name).read_text(encoding="utf-8")
        for stdin in inputs:
            out, code = run_text_io(program, text, stdin, max_steps=STEP_BUDGET)
            assert code is None, name + " " + stdin
            assert json.loads(out) == {"error": "invalid input"}, name + " " + stdin
