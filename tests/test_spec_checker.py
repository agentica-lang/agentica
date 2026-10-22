"""Checker rules through the product CLI: where diagnostics point, pipes, the nesting limit and the `_` discard.

These are the cases of the old checker test about the spans of diagnostics, the pipe rules and the nesting
limit. The other cases are in tests/test_spec_checker_rest.py.

Each program is written to a file and checked with `--json check FILE`. A test asserts the diagnostic code and its
range (the 1-based line and column of the start and of the end, which is exclusive). Message and help texts are not
asserted (AGENTS.md). The programs are also in the frozen corpus (tests/fixtures/frontend/frozen/corpus/), which the
Agentica checker is compared with, except the `_` discard programs at the end.
"""
from tests.agentica_test import cli, run
from tests.spec_support import check_diagnostic as problem, covered


def main_with(body):
    return "def main() -> Void\n%s\nend\n\n" % body


def links(count):
    return " + x" * count


def nested_chains(levels, length):
    """`levels` chains of `length` links, each inside the right operand of the first link of the next."""
    text = "x"
    for _ in range(levels):
        text = "x + (" + text + ")" + links(length)
    return text


def position(point):
    return point["line"], point["column"]


PIPE_HELPERS = ("def add(a: Int, b: Int) -> Int\n  return a + b\nend\n\n"
                "def parse(text: String) -> Result[Int]\n  return text.to_i\nend\n\n"
                "def load(path: String) -> Result[Int]\n"
                "  text = path |> try File.read_text(1000)\n"
                "  return text |> parse()\n"
                "end\n\n")

METHOD_PIPE_HELPERS = ("def f(n: Int) -> Int\n  return n\nend\n\n"
                       "def g(n: Int) -> Result[Int]\n  return ok(n)\nend\n\n")


def assert_clean(text, tmp_path):
    assert problem(text, tmp_path) is None, text


def assert_code(text, code, tmp_path):
    found = problem(text, tmp_path)
    assert found is not None, f"{code} expected for:\n{text}"
    assert found["code"] == code, text
    return found


def expect(text, code, start, tmp_path, covers=None):
    """Assert a diagnostic code, start position, and optional covered source text."""
    found = assert_code(text, code, tmp_path)
    assert position(found["range"]["start"]) == start, text
    if covers is not None:
        assert covered(text, found["range"]) == covers, text
    return found


def test_diagnostics_point_at_the_offending_source(tmp_path):
    cases = [
        (main_with('  x: Int = "s"'), "CHECK-TYPE-MISMATCH", (2, 12), '"s"'),
        (main_with("  x = missing"), "CHECK-UNKNOWN-NAME", (2, 7), "missing"),
        (main_with('  x = 1 + "a"'), "CHECK-TYPE-MISMATCH", (2, 9), "+"),
    ]
    for text, code, start, covers in cases:
        expect(text, code, start, tmp_path, covers)


def test_a_field_named_with_cannot_hold_a_function(tmp_path):
    expect("struct Hooks\n  with: Fn[Int, Int]\nend\n\ndef main() -> Void\nend\n\n",
           "CHECK-REDEFINED-NAME", (2, 3), tmp_path, "with: Fn[Int, Int]\n")
    assert_clean("struct Hooks\n  with: Int\n  run: Fn[Int, Int]\nend\n\ndef main() -> Void\nend\n\n", tmp_path)


def test_pipe_calls_user_functions_and_builtins(tmp_path):
    bodies = (
        "  n: Int = 1 |> add(2) |> add(3)\n  puts(n)",
        '  r: Result[Int] = " 4 ".trim |> parse()\n  puts(r.unwrap!)',
    )
    for body in bodies:
        assert_clean(PIPE_HELPERS + main_with(body), tmp_path)
    expect(PIPE_HELPERS + main_with('  n = "a" |> add(1)'),
           "CHECK-TYPE-MISMATCH", (15, 7), tmp_path, '"a"')
    for body, code in (("  n = 1 |> add()\n  puts(n)", "CHECK-ARITY"),
                       ("  n = 1 |> missing()", "CHECK-UNKNOWN-NAME")):
        assert_code(PIPE_HELPERS + main_with(body), code, tmp_path)


def test_pipe_into_a_builtin_with_a_method_form_is_pipe_method(tmp_path):
    expect(main_with('  s = " a "\n  t = s |> String.trim()\n  puts(t)'),
           "CHECK-PIPE-METHOD", (3, 12), tmp_path, "String.trim()")
    tried = (METHOD_PIPE_HELPERS + "def h() -> Result[String]\n  z = 1 |> try g() |> String.from_int()\n"
             "  return ok(z)\nend\n\n")
    cases = [
        main_with('  s = "a,b"\n  xs = s.trim |> String.split(",")\n  puts(xs.size)'),
        main_with('  n = "a" + "b" |> String.length()'),
        METHOD_PIPE_HELPERS + main_with("  z = 1 |> f() |> String.from_int()"),
        tried + main_with("  puts(1)"),
        METHOD_PIPE_HELPERS + main_with("  xs = [1, 2]\n  ys = xs |> List.map() do |v: Int| v |> f() end"),
        main_with("  xs = [1, 2]\n  ys = (xs |> List.map()) do |v: Int| v end"),
    ]
    for text in cases:
        assert_code(text, "CHECK-PIPE-METHOD", tmp_path)


def test_length_and_size_are_both_methods_of_string_list_map_set_and_range(tmp_path):
    body = ('  m: Map[String, Int] = {}\n  xs: List[Int] = [1]\n  s = Set.new([1])\n'
            '  puts("ab".length + "ab".size + xs.length + xs.size + m.length + m.size + s.length + s.size)\n'
            '  puts((1..3).length + (1..3).size)')
    assert_clean(main_with(body), tmp_path)
    assert_code(main_with("  puts(1.length)"), "CHECK-UNKNOWN-METHOD", tmp_path)


def test_helps_show_the_ruby_form_of_a_builtin(tmp_path):
    piped = assert_code(main_with('  s = " a "\n  t = s |> String.trim()\n  puts(t)'), "CHECK-PIPE-METHOD", tmp_path)
    assert "strip" in piped["help"] and "trim" not in piped["help"]
    unknown = assert_code(main_with('  puts(String.strip("a"))'), "CHECK-UNKNOWN-NAME", tmp_path)
    assert "s.strip" in unknown["help"] and "String.trim" not in unknown["help"]
    typo = assert_code(main_with('  puts("a".len)'), "CHECK-UNKNOWN-METHOD", tmp_path)
    assert "length" in typo["help"] and "size" in typo["help"]
    listed = assert_code(main_with('  puts("a".frobnicate)'), "CHECK-UNKNOWN-METHOD", tmp_path)
    assert "strip" in listed["help"] and "trim" not in listed["help"]


def test_expressions_and_statements_nest_at_most_1000_levels(tmp_path):
    for count in (997, 998):
        assert_clean(main_with("  x = 1\n  y = x" + links(count) + "\n  puts(y)"), tmp_path)
    deep = main_with("  x = 1\n  y = " + nested_chains(3, 500) + "\n  puts(y)")
    found = expect(deep, "CHECK-TOO-DEEP", (3, 12), tmp_path)
    assert covered(deep, found["range"]).startswith("x "), deep
    nested_ifs = ("".join("  if x == 1\n" for _ in range(300)) + "  y = " + nested_chains(2, 500) + "\n"
                  + "".join("  end\n" for _ in range(300)))
    expect(main_with("  x = 1\n" + nested_ifs), "CHECK-TOO-DEEP", (303, 12), tmp_path)


DISCARD_HELPERS = "def f(x: Int) -> Int\n  return x\nend\n\n"


def discard_program(body, helpers=DISCARD_HELPERS):
    return helpers + main_with(body)


def test_reading_a_discard_is_an_unknown_name(tmp_path):
    cases = [
        ("  _ = f(1)\n  puts(_)", "CHECK-UNKNOWN-NAME", (7, 8), "_"),
        ("  for _ in [1]\n    puts(_)\n  end", "CHECK-UNKNOWN-NAME", (7, 10), "_"),
        ("  _ = 1\n  _ += 1", "CHECK-UNKNOWN-NAME", (7, 3), "_"),
        ('  _ = puts("x")', "CHECK-VOID-VALUE", (6, 7), 'puts("x")'),
    ]
    for body, code, start, covers in cases:
        expect(discard_program(body), code, start, tmp_path, covers)


def test_a_discard_checks_and_runs_wherever_a_name_is_bound(tmp_path):
    g = "def g(_: Int, _: Int) -> Int\n  return 7\nend\n\n"
    programs = [
        (discard_program("  total = 0\n  for _ in 0...3\n    _ = f(1)\n    total += 1\n  end\n  puts(total)"),
         ["3"]),
        (discard_program("  total = 0\n  for _ in [5, 6]\n    _ = f(1)\n    total += 1\n  end\n  puts(total)"),
         ["2"]),
        (discard_program("  [1, 2].each do |_|\n    _ = f(1)\n    _ = \"text\"\n  end\n"
                         "  {\"a\": 1}.each do |_, _|\n    puts(\"pair\")\n  end\n"
                         "  for _ in [1]\n    for _ in [2]\n      puts(\"inner\")\n    end\n  end"),
         ["pair", "inner"]),
        (discard_program("  _ = f(1)\n  [1].each do |x|\n    _ = f(x)\n  end\n  puts(\"done\")"), ["done"]),
        (discard_program("  puts(g(1, 2))", g), ["7"]),
    ]
    for text, lines in programs:
        assert_clean(text, tmp_path)
        path = tmp_path / "run.agc"
        path.write_text(text, encoding="utf-8")
        result = run(cli() + [str(path)])
        assert (result.code, result.stdout.splitlines()) == (0, lines), (text, result.stderr)
