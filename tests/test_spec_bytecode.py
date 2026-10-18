"""Language rules of the bytecode writer, through the CLI.

Each case is a program whose behaviour the rule fixes: what it prints, or the diagnostic code of a run that fails. The
shape the writer makes (opcodes, table entries, slot numbers) is not pinned here; the .agcb bytes frozen from the
original writer, checked by tests/test_frontend_bytecode.py, cover it. The CLI is cli() of tests/agentica_test.py, so
AGENTICA_TEST_EXECUTABLE runs the same cases on the single binary.
"""
import json
import textwrap

from tests.agentica_test import cli, run, vm_environment

MAP_ENTRIES = ", ".join("%d: %d" % (key, key) for key in range(257))
# Close to the parser's nesting limit, so the type is deep but still parses.
DEEP_TYPE_DEPTH = 990


def source(text):
    """Normalize a readable, indented Agentica source literal."""
    return textwrap.dedent(text).lstrip("\n")


def deep_struct(depth):
    return "struct Deep\n  xs: %sInt%s\nend\n\n" % ("List[" * depth, "]" * depth)


def run_program(text, tmp_path, *flags):
    program = tmp_path / "program.agc"
    program.write_text(text, encoding="utf-8")
    return run(cli() + list(flags) + [str(program)], env=vm_environment())


def assert_prints(text, expected, tmp_path):
    result = run_program(text, tmp_path)
    assert (result.code, result.stdout) == (0, expected), result.stderr


def assert_fails(text, code, tmp_path):
    """Assert a JSON diagnostic and return what the program printed before it."""
    result = run_program(text, tmp_path, "--json")
    assert result.code == 1, result.stdout + result.stderr
    diagnostic = json.loads(result.stderr)
    assert diagnostic.get("code") == code, result.stderr
    return result.stdout


def test_task_await_takes_the_result_entry_only_for_a_result(tmp_path):
    assert_prints(
        source("""
            def f(n: Int) -> Result[Int]
              return ok(n + 1)
            end

            def g(n: Int) -> Int
              return n + 1
            end

            def main() -> Void
              puts(Task.await(Task.spawn(&f, 1)))
              puts(Task.await(Task.spawn(&f, 2), 10))
              puts(Task.await(Task.spawn(&g, 3)) + 1)
            end
        """),
        "ok(2)\nAwait.Done(ok(3))\n5\n",
        tmp_path,
    )


def test_a_returned_call_is_a_tail_call_and_a_nested_call_is_not(tmp_path):
    loop = source("""
        def loop(n: Int, acc: Int) -> Int
          if n == 0
            return acc
          end
          return loop(n - 1, acc + 1)
        end

        def main() -> Void
          puts(loop(1000000, 0))
        end
    """)
    assert_prints(loop, "1000000\n", tmp_path)

    nested = source("""
        def sum(n: Int) -> Int
          if n == 0
            return 0
          end
          return 1 + sum(n - 1)
        end

        def main() -> Void
          puts(sum(20000))
        end
    """)
    assert assert_fails(nested, "RUNTIME-STACK-OVERFLOW", tmp_path) == ""


def test_a_returned_try_passes_the_inner_result_up(tmp_path):
    assert_prints(
        source("""
            def h(n: Int) -> Result[Result[Int]]
              return ok(ok(n))
            end

            def g(n: Int) -> Result[Int]
              return try h(n)
            end

            def main() -> Void
              puts(g(2))
            end
        """),
        "ok(2)\n",
        tmp_path,
    )


def test_a_map_literal_above_255_entries_holds_every_entry(tmp_path):
    text = source("""
        def main() -> Void
          m = {%s}
          puts(m.size)
          puts(m[256])
          puts(m[0])
        end
    """) % MAP_ENTRIES
    assert_prints(text, "257\n256\n0\n", tmp_path)


def test_a_block_sees_its_parameters_and_its_captures(tmp_path):
    assert_prints(
        source("""
            def ap(f: Fn[Int, Int]) -> Int
              return f.call(2)
            end

            def main() -> Void
              n = 1
              m = 2
              xs = [1].map do |x| x + m + n end
              puts(ap(&ap2))
              puts(xs)
            end

            def ap2(x: Int) -> Int
              return x
            end
        """),
        "2\n[4]\n",
        tmp_path,
    )


def test_for_counts_over_a_range_literal_and_over_a_range_value(tmp_path):
    assert_prints(
        source("""
            def main() -> Void
              for i in 0...3
                puts(i)
              end
              r = 1..2
              for j in r
                puts(j)
              end
            end
        """),
        "0\n1\n2\n1\n2\n",
        tmp_path,
    )


def test_struct_updates_chain_and_leave_the_old_values(tmp_path):
    assert_prints(
        source("""
            struct P
              a: Int
              b: Int
              c: Int
            end

            def main() -> Void
              p = P(a: 1, b: 2, c: 3)
              q = p.with(c: 4, a: 5)
              r = q.with(a: 6, c: 7)
              s = r.with(b: 8)
              puts("#{s.a} #{s.b} #{s.c}")
              puts("#{p.a} #{p.b} #{p.c}")
              puts("#{q.a} #{q.b} #{q.c}")
            end
        """),
        "6 8 7\n1 2 3\n5 2 4\n",
        tmp_path,
    )


def test_module_constants_are_built_in_dependency_order(tmp_path):
    assert_prints(
        source("""
            SIZE = 4
            TABLE = {"a": SIZE}
            SQUARES = [1, 2].map do |n| n * SIZE end
            LATE = SQUARES.size
            UNUSED = [9]

            def main() -> Void
              puts(TABLE["a"])
              puts(SIZE)
              puts(LATE)
              [1].each do |n|
                puts(n + LATE)
              end
            end

            def unreachable() -> Int
              return UNUSED.size
            end
        """),
        "4\n4\n2\n3\n",
        tmp_path,
    )


def test_literal_constants_read_in_a_string(tmp_path):
    assert_prints(
        source("""
            SIZE = 4
            NAME = "x"

            def main() -> Void
              puts("#{NAME}#{SIZE}")
            end
        """),
        "x4\n",
        tmp_path,
    )


def test_a_constant_that_nothing_reachable_reads_never_runs(tmp_path):
    assert_prints(
        source("""
            BAD = [1][5]

            def main() -> Void
              puts(1)
            end

            def never() -> Int
              return BAD
            end
        """),
        "1\n",
        tmp_path,
    )


def test_a_failing_constant_stops_the_program_before_main_prints(tmp_path):
    printed = assert_fails(
        source("""
            BAD = [1][5]

            def main() -> Void
              puts(1)
              puts(BAD)
            end
        """),
        "RUNTIME-INDEX-OUT-OF-RANGE",
        tmp_path,
    )
    assert printed == ""


def test_deep_json_field_types_still_compile_and_run(tmp_path):
    program = deep_struct(DEEP_TYPE_DEPTH) + source("""
        def main() -> Void
          puts(JSON.schema(Deep).to_s)
        end
    """)
    result = run_program(program, tmp_path)
    assert result.code == 0, result.stderr
    schema = json.loads(result.stdout)
    assert (schema["type"], schema["required"]) == ("object", ["xs"]), result.stdout[:200]
    assert schema["properties"]["xs"]["type"] == "array"
