"""Language rules of the bytecode writer, through the CLI (rescued from the deleted tests/bytecode-test.rkt).

Each case is a program whose behaviour the rule fixes: what it prints, or the diagnostic code of a run that fails. The
shape the writer makes (opcodes, table entries, slot numbers) is not pinned here; the .agcb bytes frozen from the Racket
writer, checked by tests/test_frontend_bytecode.py, cover it. The CLI is cli() of tests/agentica_test.py, so
AGENTICA_TEST_EXECUTABLE runs the same cases on the single binary.
"""
import json

from tests.agentica_test import TestCase, cli, run, vm_environment

MAP_ENTRIES = ", ".join("%d: %d" % (key, key) for key in range(257))
# Close to the parser's nesting limit, so the type is deep but still parses.
DEEP_TYPE_DEPTH = 990


def deep_struct(depth):
    return "struct Deep\n  xs: %sInt%s\nend\n\n" % ("List[" * depth, "]" * depth)


class BytecodeRules(TestCase):
    def run_program(self, text, *flags):
        source = self.make_temp_dir() / "program.agc"
        source.write_text(text, encoding="utf-8")
        return run(cli() + list(flags) + [str(source)], env=vm_environment())

    def assert_prints(self, text, expected):
        result = self.run_program(text)
        self.assertEqual((result.code, result.stdout), (0, expected), result.stderr)

    def assert_fails(self, text, code):
        """A run that stops with a diagnostic: its code in the --json form on stderr, and what was printed before it."""
        result = self.run_program(text, "--json")
        self.assertEqual(result.code, 1, result.stdout + result.stderr)
        try:
            diagnostic = json.loads(result.stderr)
        except ValueError:
            self.fail("stderr is not a --json diagnostic: %r" % result.stderr)
        self.assertEqual(diagnostic.get("code") if isinstance(diagnostic, dict) else None, code, result.stderr)
        return result.stdout

    def test_task_await_takes_the_result_entry_only_for_a_result(self):
        self.assert_prints(
            "def f(n: Int) -> Result[Int]\n  return ok(n + 1)\nend\n\n"
            "def g(n: Int) -> Int\n  return n + 1\nend\n\n"
            "def main() -> Void\n"
            "  puts(Task.await(Task.spawn(&f, 1)))\n"
            "  puts(Task.await(Task.spawn(&f, 2), 10))\n"
            "  puts(Task.await(Task.spawn(&g, 3)) + 1)\n"
            "end\n",
            "ok(2)\nAwait.Done(ok(3))\n5\n")

    def test_a_returned_call_is_a_tail_call_and_a_nested_call_is_not(self):
        loop = ("def loop(n: Int, acc: Int) -> Int\n  if n == 0\n    return acc\n  end\n"
                "  return loop(n - 1, acc + 1)\nend\n\n")
        self.assert_prints(loop + "def main() -> Void\n  puts(loop(1000000, 0))\nend\n", "1000000\n")
        nested = ("def sum(n: Int) -> Int\n  if n == 0\n    return 0\n  end\n"
                  "  return 1 + sum(n - 1)\nend\n\ndef main() -> Void\n  puts(sum(20000))\nend\n")
        self.assertEqual(self.assert_fails(nested, "RUNTIME-STACK-OVERFLOW"), "")

    def test_a_returned_try_passes_the_inner_result_up(self):
        self.assert_prints(
            "def h(n: Int) -> Result[Result[Int]]\n  return ok(ok(n))\nend\n\n"
            "def g(n: Int) -> Result[Int]\n  return try h(n)\nend\n\n"
            "def main() -> Void\n  puts(g(2))\nend\n",
            "ok(2)\n")

    def test_a_map_literal_above_255_entries_holds_every_entry(self):
        self.assert_prints(
            "def main() -> Void\n  m = {%s}\n  puts(m.size)\n  puts(m[256])\n  puts(m[0])\nend\n" % MAP_ENTRIES,
            "257\n256\n0\n")

    def test_a_block_sees_its_parameters_and_its_captures(self):
        self.assert_prints(
            "def ap(f: Fn[Int, Int]) -> Int\n  return f.call(2)\nend\n\n"
            "def main() -> Void\n  n = 1\n  m = 2\n"
            "  xs = [1].map do |x| x + m + n end\n  puts(ap(&ap2))\n  puts(xs)\nend\n\n"
            "def ap2(x: Int) -> Int\n  return x\nend\n",
            "2\n[4]\n")

    def test_for_counts_over_a_range_literal_and_over_a_range_value(self):
        self.assert_prints(
            "def main() -> Void\n  for i in 0...3\n    puts(i)\n  end\n"
            "  r = 1..2\n  for j in r\n    puts(j)\n  end\nend\n",
            "0\n1\n2\n1\n2\n")

    def test_struct_updates_chain_and_leave_the_old_values(self):
        self.assert_prints(
            "struct P\n  a: Int\n  b: Int\n  c: Int\nend\n\n"
            "def main() -> Void\n  p = P(a: 1, b: 2, c: 3)\n  q = p.with(c: 4, a: 5)\n"
            "  r = q.with(a: 6, c: 7)\n  s = r.with(b: 8)\n"
            "  puts(\"#{s.a} #{s.b} #{s.c}\")\n  puts(\"#{p.a} #{p.b} #{p.c}\")\n"
            "  puts(\"#{q.a} #{q.b} #{q.c}\")\nend\n",
            "6 8 7\n1 2 3\n5 2 4\n")

    def test_module_constants_are_built_in_dependency_order(self):
        self.assert_prints(
            "SIZE = 4\nTABLE = {\"a\": SIZE}\nSQUARES = [1, 2].map do |n| n * SIZE end\nLATE = SQUARES.size\n"
            "UNUSED = [9]\n\n"
            "def main() -> Void\n  puts(TABLE[\"a\"])\n  puts(SIZE)\n  puts(LATE)\n  [1].each do |n|\n"
            "    puts(n + LATE)\n  end\nend\n\n"
            "def unreachable() -> Int\n  return UNUSED.size\nend\n",
            "4\n4\n2\n3\n")

    def test_literal_constants_read_in_a_string(self):
        self.assert_prints(
            "SIZE = 4\nNAME = \"x\"\n\ndef main() -> Void\n  puts(\"#{NAME}#{SIZE}\")\nend\n",
            "x4\n")

    def test_a_constant_that_nothing_reachable_reads_never_runs(self):
        self.assert_prints(
            "BAD = [1][5]\n\ndef main() -> Void\n  puts(1)\nend\n\ndef never() -> Int\n  return BAD\nend\n",
            "1\n")

    def test_a_failing_constant_stops_the_program_before_main_prints(self):
        printed = self.assert_fails("BAD = [1][5]\n\ndef main() -> Void\n  puts(1)\n  puts(BAD)\nend\n",
                                    "RUNTIME-INDEX-OUT-OF-RANGE")
        self.assertEqual(printed, "")

    def test_deep_json_field_types_still_compile_and_run(self):
        result = self.run_program(deep_struct(DEEP_TYPE_DEPTH)
                                  + "def main() -> Void\n  puts(JSON.schema(Deep).to_s)\nend\n")
        self.assertEqual(result.code, 0, result.stderr)
        schema = json.loads(result.stdout)
        self.assertEqual((schema["type"], schema["required"]), ("object", ["xs"]), result.stdout[:200])
        self.assertEqual(schema["properties"]["xs"]["type"], "array")
