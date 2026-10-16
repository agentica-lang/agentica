"""examples/*.agc, rejected fragments and the CLI exit codes (ported from examples-test.rkt).

Each case runs the CLI as a child (`cli()`), like the Racket test did in
process. The two cases that the Racket file ran both in process and as a
subprocess run once here. The algorithm examples (knight tour, traveling
salesman, maze) read JSON from stdin and are checked by their properties, not
by one fixed answer; the slow tier has the full list of malformed inputs.
"""
import json
import os
import select
import time

from tests.agentica_test import ROOT, Child, TestCase, cli, run, scaled, slow, vm_environment

EXAMPLES = ROOT / "examples"
STEP_BUDGET = "5000000"
WAIT_SECONDS = scaled(20)


def compact(value):
    return json.dumps(value, separators=(",", ":"))


class Examples(TestCase):
    def cli(self, *arguments, stdin=b""):
        """The CLI run to its end; returns Result(code, stdout, stderr)."""
        return run(cli() + [str(argument) for argument in arguments], stdin=stdin, env=vm_environment())

    def program(self, text):
        """A temp file holding the program text; returns its path."""
        path = self.make_temp_dir("agentica-example-") / "program.agc"
        path.write_text(text, encoding="utf-8")
        return path

    def run_text_io(self, text, stdin="", max_steps=None):
        """Run program text with --json; returns (stdout, None) on exit 0, else (stdout, the code of the diagnostic)."""
        arguments = ["--json"] + (["--max-steps", str(max_steps)] if max_steps else []) + [self.program(text)]
        result = self.cli(*arguments, stdin=stdin.encode("utf-8"))
        if result.code == 0:
            return result.stdout, None
        lines = [line for line in result.stderr.split("\n") if line]
        try:
            data = json.loads(lines[-1])
        except (IndexError, ValueError):
            data = None
        if not (isinstance(data, dict) and isinstance(data.get("code"), str)):
            self.fail("exit %s without a JSON diagnostic on stderr: %r" % (result.code, result.stderr))
        return result.stdout, data["code"]

    def run_example(self, name, stdin="", max_steps=None):
        return self.run_text_io((EXAMPLES / name).read_text(encoding="utf-8"), stdin, max_steps)

    def code_of(self, body):
        return self.run_text_io("def main() -> Void\n%s\nend\n\n" % body)[1]

    def test_valid_examples_run_with_the_expected_output(self):
        for name, expected in [
                ("hello.agc", "hello\n"),
                ("classify.agc", "adult\n"),
                ("result.agc", "42\nempty count\n0\n"),
                ("json.agc", '{"name":"Ana","age":25}\nhello, Ana\nmissing name\n'),
                ("tasks.agc", "Probar Agentica\n"),
                ("inventory.agc", "apple\nkiwi\n"),
                ("strings.agc", "AGENTICA, HELLO\n8\n5\nAgentica, world\n"),
                ("blocks.agc", "cocoa: 3.0\ntea: 4.0\nunits: 15\nany empty: true\n"),
                ("constants.agc", "8 | 32\n5\nfruit | drink\n3\n")]:
            output, code = self.run_example(name)
            self.assertIsNone(code, name)
            self.assertEqual(output, expected, name)

    def test_file_task_process_and_http_examples_give_their_expected_output(self):
        def example(name):
            return str(EXAMPLES / name)

        self.assertEqual(self.cli(example("concurrency.agc")), (0, "42\n14\n", ""))
        self.assertEqual(self.cli(example("file-summary.agc"), example("hello.agc")), (0, "39\n", ""))
        self.assertEqual(self.cli(example("http_server.agc")), (0, "200\nhello\n\n404\nok()\n", ""))
        tool = self.cli("--allow-run", example("process-tool.agc"))
        self.assertEqual(tool.code, 0, tool.stderr)
        self.assertEqual((tool.stdout, tool.stderr), ("hello from sh\n", ""))

    def test_echo_agc_reads_and_echoes_standard_input(self):
        output, code = self.run_example("echo.agc", "one\ntwo\n")
        self.assertIsNone(code)
        self.assertEqual(output, "one\ntwo\n")

    def test_json_examples_validate_documents_and_recover_within_streams(self):
        for name, stdin, expected in [
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
                ("json-lines.agc", '{"name":"Ana","score":101,"active":true}\n', '{"error":"invalid record"}\n')]:
            output, code = self.run_example(name, stdin)
            self.assertIsNone(code, name)
            self.assertEqual(output, expected, name)

    def test_knight_tours_cover_every_square_exactly_once_with_legal_moves(self):
        text = (EXAMPLES / "knight-tour.agc").read_text(encoding="utf-8")
        for size, start in [(1, 0), (5, 0), (8, 0), (8, 27)]:
            out, code = self.run_text_io(text, compact({"size": size, "start": start}), max_steps=STEP_BUDGET)
            self.assertIsNone(code)
            data = json.loads(out)
            self.assertIs(data["found"], True)
            path = data["path"]
            self.assertEqual(path[0], start)
            self.assertEqual(sorted(path), list(range(size * size)))
            for source, target in zip(path, path[1:]):
                dx = abs(source % size - target % size)
                dy = abs(source // size - target // size)
                self.assertEqual(sorted([dx, dy]), [1, 2])
        out, code = self.run_text_io(text, '{"size":3,"start":0}', max_steps=STEP_BUDGET)
        self.assertIsNone(code)
        self.assertEqual(json.loads(out), {"found": False, "path": []})

    def test_traveling_salesman_returns_an_optimal_complete_circuit(self):
        text = (EXAMPLES / "traveling-salesman.agc").read_text(encoding="utf-8")
        for matrix, cost in [
                ([[0]], 0),
                ([[0, 10, 15, 20], [10, 0, 35, 25], [15, 35, 0, 30], [20, 25, 30, 0]], 80),
                ([[0, 1, 9], [9, 0, 1], [1, 9, 0]], 3),
                ([[0, 1, 2, 2], [1, 0, 1, 2], [2, 1, 0, 100], [2, 2, 100, 0]], 7),
                ([[0, 0, 0], [0, 0, 0], [0, 0, 0]], 0),
                ([[0, 1000000000], [1000000000, 0]], 2000000000)]:
            out, code = self.run_text_io(text, compact({"distances": matrix}), max_steps=STEP_BUDGET)
            self.assertIsNone(code)
            data = json.loads(out)
            route = data["route"]
            self.assertEqual(data["cost"], cost)
            self.assertEqual(route[0], 0)
            self.assertEqual(route[-1], 0)
            self.assertEqual(sorted(route[:-1]), list(range(len(matrix))))
            self.assertEqual(sum(matrix[source][target] for source, target in zip(route, route[1:])), data["cost"])

    def test_maze_bfs_returns_shortest_legal_paths_and_reports_unreachable_goals(self):
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
            out, code = self.run_text_io(text, compact({"grid": grid, "start": start, "goal": goal}),
                                         max_steps=STEP_BUDGET)
            self.assertIsNone(code)
            data = json.loads(out)
            self.assertEqual(data["found"], expected_distance >= 0)
            self.assertEqual(data["distance"], expected_distance)
            path = data["path"]
            if expected_distance < 0:
                self.assertEqual(path, [])
                continue
            self.assertEqual(len(path), expected_distance + 1)
            self.assertEqual(path[0], start)
            self.assertEqual(path[-1], goal)
            self.assertEqual(len(set(path)), len(path))
            for square in path:
                self.assertTrue(type(square) is int and 0 <= square < width * len(grid))
                self.assertEqual(grid[square // width][square % width], ".")
            for source, target in zip(path, path[1:]):
                self.assertEqual(abs(source // width - target // width) + abs(source % width - target % width), 1)

    def test_algorithm_examples_reject_input_that_is_not_json(self):
        for name in ("maze-bfs.agc", "knight-tour.agc", "traveling-salesman.agc"):
            out, code = self.run_example(name, "not JSON", max_steps=STEP_BUDGET)
            self.assertIsNone(code)
            self.assertEqual(json.loads(out), {"error": "invalid input"})

    def read_until(self, child, done, what):
        """Read the child's stdout bytes one at a time until done(bytes) is true; fail after WAIT_SECONDS."""
        fd = child.process.stdout.fileno()
        data = b""
        deadline = time.monotonic() + WAIT_SECONDS
        while not done(data):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                self.fail(what)
            chunk = os.read(fd, 1)
            if not chunk:
                self.fail("stdout ended: " + what)
            data += chunk
        return data

    def test_stdio_peers_receive_flushed_replies_while_stdin_stays_open(self):
        program = self.program(
            "def main() -> Void\n"
            "  IO.inspect(IO.eof?())\n  IO.flush()\n"
            "  data = Result.unwrap!(IO.read_bytes(2))\n"
            "  IO.print(Result.unwrap!(String.from_bytes(data)))\n  IO.flush()\n"
            "  puts(IO.gets!())\nend\n\n")
        child = self.adopt(Child(cli() + [program], env=vm_environment(), stdin=True, capture_stderr=True,
                                 read_stdout=False))
        # Only the first byte of the two-byte letter (U+00F1) is available. EOF peeking must not decode it.
        child.process.stdin.write(bytes([195]))
        child.process.stdin.flush()
        first = self.read_until(child, lambda data: data.endswith(b"\n"),
                                "initial reply was not flushed, or EOF peeking blocked on UTF-8")
        self.assertEqual(first, b"false\n")
        self.assertIsNone(child.process.poll())
        child.process.stdin.write(bytes([177]))
        child.process.stdin.flush()
        second = self.read_until(child, lambda data: len(data) >= 2, "response remained buffered")
        self.assertEqual(second.decode("utf-8"), "\u00f1")
        self.assertIsNone(child.process.poll())
        child.process.stdin.write(b"done\n")
        child.close_stdin()
        self.assertEqual(child.wait(WAIT_SECONDS), 0)
        self.assertEqual(child.process.stdout.read().decode(), "done\n")
        self.assertEqual(child.stderr_text(), "")

    def test_rejected_fragments_fail_with_the_intended_code(self):
        self.assertEqual(self.code_of('  age: Int = "25"'), "CHECK-TYPE-MISMATCH")
        self.assertEqual(self.code_of('  if 1\n    puts("hello")\n  end'), "CHECK-TYPE-MISMATCH")
        self.assertEqual(self.code_of("  values = []"), "CHECK-EMPTY-LIST-TYPE")
        self.assertEqual(self.code_of('  puts "hello"'), "PARSE-UNEXPECTED-TOKEN")

    def test_help_reads_the_catalog_without_a_source_file(self):
        help_result = self.cli("help", "String.to_int", "--json")
        self.assertEqual(help_result.code, 0)
        self.assertEqual(help_result.stderr, "")
        data = json.loads(help_result.stdout)
        self.assertEqual(data["arity"], 1)
        self.assertEqual(data["result"], "Result[Int]")
        self.assertEqual(data["parameters"], [{"name": "s", "type": "String"}])
        self.assertEqual(data["effects"], [])
        self.assertEqual(self.cli("--json", "help", "String.to_int"), help_result)
        self.assertEqual(self.cli("--max-steps", "10", "help", "String.to_int", "--json"), help_result)
        get_help = self.cli("help", "Map.get", "--json")
        self.assertEqual(get_help.code, 0)
        self.assertEqual(get_help.stderr, "")
        variants = json.loads(get_help.stdout)["overloads"]
        self.assertEqual([variant["arity"] for variant in variants], [2, 3])
        self.assertEqual([variant["result"] for variant in variants], ["Result[V]", "V"])
        get_text = self.cli("help", "Map.get")
        self.assertEqual(get_text.code, 0)
        self.assertRegex(get_text.stdout, r"Map.get\(map: Map\[K, V\], key: K\) -> Result\[V\]")
        self.assertRegex(get_text.stdout, r"default: V\) -> V")
        unknown = self.cli("help", "String.to_it", "--json")
        self.assertEqual(unknown.code, 2)
        self.assertRegex(unknown.stderr, "String.to_int")

    def test_help_lists_the_subcommands_the_core_rules_and_the_builtin_namespaces(self):
        usage = self.cli("--help")
        self.assertEqual(usage.code, 0)
        for token in ("agentica check", "agentica test", "--steps FILE", "agentica help NAME", "def main() -> Void",
                      "xs = xs.push(2)", "CHECK-CAPTURED-ASSIGNMENT", "--allow-run"):
            self.assertIn(token, usage.stdout)
        overview = self.cli("help")
        self.assertEqual(overview.code, 0)
        self.assertEqual(overview.stderr, "")
        for token in ("agentica check", "agentica test", "namespaces:", "List", "Map", "String", "JSON", "Task", "puts"):
            self.assertIn(token, overview.stdout)
        self.assertNotIn("HttpWire", overview.stdout)
        self.assertEqual(self.cli("help", "List.map", "String.split").code, 2)

    def test_new_diagnostics_retain_their_codes_across_the_three_printers(self):
        path = self.program("")
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
                result = self.cli(*([] if style == "plain" else [style]), path)
                self.assertEqual(result.code, 1, code + " " + style)
                self.assertEqual(result.stdout, "")
                if style == "--json":
                    data = json.loads(result.stderr)
                    self.assertEqual(data["code"], code)
                    self.assertIn("range", data)
                else:
                    self.assertIn(code, result.stderr)

    def test_cli_budget_validation_and_checking_do_not_run_the_program(self):
        path = self.program("def main() -> Void\n  while true\n  end\nend\n\n")
        self.assertEqual(self.cli("--max-steps", "1", "check", path), (0, "check ok\n", ""))
        result = self.cli("--json", "--max-steps", "10", path)
        self.assertEqual(result.code, 1)
        self.assertEqual(json.loads(result.stderr)["code"], "RUNTIME-STEP-LIMIT")
        for value in ("0", "-1", "1.5", "abc", "#e3"):
            self.assertEqual(self.cli("--max-steps", value, path).code, 2, value)

    def test_cli_version_prints_the_version_and_exits_0(self):
        self.assertEqual(self.cli("--version"), (0, "0.3.0\n", ""))

    def test_cli_seed_repeats_random_and_rejects_bad_seeds(self):
        path = self.program("def main() -> Void\n  IO.inspect([Random.int(1, 1000000), Random.int(1, 1000000)])\nend\n\n")
        first = self.cli("--seed", "5", path)
        again = self.cli("--seed", "5", path)
        bad = self.cli("--seed", "2147483648", path)
        self.assertEqual(first.code, 0)
        self.assertEqual(first, again)
        self.assertEqual(bad.code, 2)

    def test_cli_exit_codes(self):
        hello = str(EXAMPLES / "hello.agc")
        self.assertEqual(self.cli(hello), (0, "hello\n", ""))
        self.assertEqual(self.cli("no-such-file.agc").code, 2)
        self.assertEqual(self.cli("check", hello), (0, "check ok\n", ""))
        type_error = self.program("def main() -> Void\n  x: String = 1\nend\n\n")
        checked = self.cli("check", type_error)
        ai = self.cli("--ai", "check", type_error)
        as_json = self.cli("--json", "check", type_error)
        self.assertEqual(checked.code, 1)
        self.assertEqual(checked.stdout, "")
        self.assertRegex(checked.stderr, r"error\[CHECK-")
        self.assertEqual(ai.code, 1)
        self.assertRegex(ai.stderr, r"\Acheck failed: 1 error\n\n\[CHECK-")
        self.assertEqual(as_json.code, 1)
        self.assertEqual(json.loads(as_json.stderr)["code"], "CHECK-TYPE-MISMATCH")
        self.assertEqual(as_json.stdout, "")
        self.assertEqual(self.cli("--json", "check", hello), (0, '{"ok":true}\n', ""))
        failed = self.cli(self.program("def main() -> Void\n  x = 1 / 0\nend\n\n"))
        self.assertEqual(failed.code, 1)
        self.assertRegex(failed.stderr, r"error\[RUNTIME-DIVISION-BY-ZERO\]")
        self.assertEqual(self.cli(self.program("def main() -> Void\n  System.exit(3)\nend\n\n")).code, 3)
        args_file = self.program("def main() -> Void\n  for a in System.args()\n    puts(a)\n  end\nend\n\n")
        self.assertEqual(self.cli(args_file, "x", "y", "--json"), (0, "x\ny\n--json\n", ""))

    # Slow tier: the full list of malformed inputs, one run each. The fast tier keeps one input per program.

    @slow
    def test_algorithm_examples_reject_malformed_input_before_producing_a_solution(self):
        maze = (EXAMPLES / "maze-bfs.agc").read_text(encoding="utf-8")
        for grid in (["." * 33], ["."] * 33):
            out, code = self.run_text_io(maze, compact({"grid": grid, "start": 0, "goal": 0}),
                                         max_steps=STEP_BUDGET)
            self.assertIsNone(code)
            self.assertEqual(json.loads(out), {"error": "invalid input"})
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
                out, code = self.run_text_io(text, stdin, max_steps=STEP_BUDGET)
                self.assertIsNone(code, name + " " + stdin)
                self.assertEqual(json.loads(out), {"error": "invalid input"}, name + " " + stdin)
