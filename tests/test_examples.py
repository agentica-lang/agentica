"""examples/*.agc, rejected fragments and the CLI exit codes.

Each case runs the CLI as a child (`cli()`), like the original test did in
process. The two cases that the original file ran both in process and as a
subprocess run once here. The algorithm examples (knight tour, traveling
salesman, maze) read JSON from stdin and are checked by their properties, not
by one fixed answer; the slow tier has the full list of malformed inputs.
"""
import itertools
import json
import os
import re
import select
import time

import pytest

from tests.agentica_test import ROOT, Child, adopt, agentica_version, cli, run, scaled, vm_environment

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
    ("inventory.agc", "apple\nkiwi\n"),
    ("strings.agc", "AGENTICA, HELLO\n8\n5\nAgentica, world\n"),
    ("blocks.agc", "cocoa: 3.0\ntea: 4.0\nunits: 15\nany empty: true\n"),
    ("constants.agc", "8 | 32\n5\nfruit | drink\n3\n"),
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
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
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
    tool = cli_run("--allow-run", example("process-tool.agc"))
    assert tool.code == 0, tool.stderr
    assert (tool.stdout, tool.stderr) == ("hello from sh\n", "")


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


def test_help_reads_the_catalog_without_a_source_file():
    help_result = cli_run("help", "String.to_int", "--json")
    assert help_result.code == 0
    assert help_result.stderr == ""
    data = json.loads(help_result.stdout)
    assert data["arity"] == 1
    assert data["result"] == "Result[Int]"
    assert data["parameters"] == [{"name": "s", "type": "String"}]
    assert data["effects"] == []
    assert cli_run("--json", "help", "String.to_int") == help_result
    assert cli_run("--max-steps", "10", "help", "String.to_int", "--json") == help_result
    get_help = cli_run("help", "Map.get", "--json")
    assert get_help.code == 0
    assert get_help.stderr == ""
    variants = json.loads(get_help.stdout)["overloads"]
    assert [variant["arity"] for variant in variants] == [2, 3]
    assert [variant["result"] for variant in variants] == ["Result[V]", "V"]
    get_text = cli_run("help", "Map.get")
    assert get_text.code == 0
    assert re.search(r"Map.get\(map: Map\[K, V\], key: K\) -> Result\[V\]", get_text.stdout)
    assert re.search(r"default: V\) -> V", get_text.stdout)
    unknown = cli_run("help", "String.to_it", "--json")
    assert unknown.code == 2
    assert re.search("String.to_int", unknown.stderr)


def test_help_lists_the_subcommands_the_core_rules_and_the_builtin_namespaces():
    usage = cli_run("--help")
    assert usage.code == 0
    for token in ("agentica check", "agentica test", "--steps FILE", "agentica help NAME", "def main() -> Void",
                  "xs = xs.push(2)", "CHECK-CAPTURED-ASSIGNMENT", "--allow-run"):
        assert token in usage.stdout
    overview = cli_run("help")
    assert overview.code == 0
    assert overview.stderr == ""
    for token in ("agentica check", "agentica test", "namespaces:", "List", "Map", "String", "JSON", "Task", "puts"):
        assert token in overview.stdout
    assert "HttpWire" not in overview.stdout
    assert cli_run("help", "List.map", "String.split").code == 2


def test_new_diagnostics_retain_their_codes_across_the_three_printers(program):
    path = program("")
    for body, code in [
            ("  x = List.repeat(1, -1)", "RUNTIME-INVALID-COUNT"),
            ('  r = error("bad")', "CHECK-RESULT-TYPE"),
            ("  r = try ok(1)", "CHECK-TRY-CONTEXT"),
            ("  x = JSON.encode({1: true})", "CHECK-NOT-ENCODABLE"),
            ("  large = 1.0\n  i = 0\n  while i < 40\n    large = large * 1000000000.0\n    i = i + 1\n  end\n"
             "  x = JSON.encode(large)", "RUNTIME-JSON-ENCODE"),
            ('  r: Result[Int] = error("bad")\n  x = Result.unwrap!(r)', "RUNTIME-UNWRAP-ERROR")]:
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


def test_cli_budget_validation_and_checking_do_not_run_the_program(program):
    path = program("def main() -> Void\n  while true\n  end\nend\n\n")
    assert cli_run("--max-steps", "1", "check", path) == (0, "check ok\n", "")
    result = cli_run("--json", "--max-steps", "10", path)
    assert result.code == 1
    assert json.loads(result.stderr)["code"] == "RUNTIME-STEP-LIMIT"
    for value in ("0", "-1", "1.5", "abc", "#e3"):
        assert cli_run("--max-steps", value, path).code == 2, value


def test_cli_version_prints_the_version_and_exits_0():
    assert cli_run("--version") == (0, agentica_version() + "\n", "")


def test_cli_seed_repeats_random_and_rejects_bad_seeds(program):
    path = program("def main() -> Void\n  IO.inspect([Random.int(1, 1000000), Random.int(1, 1000000)])\nend\n\n")
    first = cli_run("--seed", "5", path)
    again = cli_run("--seed", "5", path)
    bad = cli_run("--seed", "2147483648", path)
    assert first.code == 0
    assert first == again
    assert bad.code == 2


def test_cli_exit_codes(program):
    hello = str(EXAMPLES / "hello.agc")
    assert cli_run(hello) == (0, "hello\n", "")
    assert cli_run("no-such-file.agc").code == 2
    assert cli_run("check", hello) == (0, "check ok\n", "")
    type_error = program("def main() -> Void\n  x: String = 1\nend\n\n")
    checked = cli_run("check", type_error)
    ai = cli_run("--ai", "check", type_error)
    as_json = cli_run("--json", "check", type_error)
    assert checked.code == 1
    assert checked.stdout == ""
    assert re.search(r"error\[CHECK-", checked.stderr)
    assert ai.code == 1
    assert re.search(r"\Acheck failed: 1 error\n\n\[CHECK-", ai.stderr)
    assert as_json.code == 1
    assert json.loads(as_json.stderr)["code"] == "CHECK-TYPE-MISMATCH"
    assert as_json.stdout == ""
    assert cli_run("--json", "check", hello) == (0, '{"ok":true}\n', "")
    failed = cli_run(program("def main() -> Void\n  x = 1 / 0\nend\n\n"))
    assert failed.code == 1
    assert re.search(r"error\[RUNTIME-DIVISION-BY-ZERO\]", failed.stderr)
    assert cli_run(program("def main() -> Void\n  System.exit(3)\nend\n\n")).code == 3
    args_file = program("def main() -> Void\n  for a in System.args()\n    puts(a)\n  end\nend\n\n")
    assert cli_run(args_file, "x", "y", "--json") == (0, "x\ny\n--json\n", "")


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
