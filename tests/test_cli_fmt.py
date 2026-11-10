"""`agentica fmt` through the product CLI: write mode, `--check`, `-` for standard
input, `--tree`, the `[style]` of the nearest agentica.toml and the exit codes. The cases assert exit statuses, the
files, the listed paths and diagnostic codes, never message text."""
import json
import os
import stat

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, vm_environment

FORMATTED = 'def main() -> Void\n  puts("ok")\nend\n'
UNFORMATTED = 'def main() -> Void\n    puts( "ok" )\nend\n'
BROKEN = "def main(\n"
# A call that fits in 119 columns, but not in 40.
WIDE = 'def main() -> Void\n  puts(some_function_name(first_argument, second_argument))\nend\n'
WIDE_AT_40 = ('def main() -> Void\n  puts(\n    some_function_name(\n      first_argument,\n      second_argument,\n'
              '    ),\n  )\nend\n')
# The printer breaks the one-line `do ... end`, and the `end` it makes needs the empty line after it, as the `if` does.
ENDS = ('def main() -> Void\n  xs = [1, 2, 3]\n  xs.each do |x| puts(x + 1000000000) end\n  if true\n    puts("a")\n'
        '  end\n  puts(1)\nend\n')
ENDS_BLANK = ('def main() -> Void\n  xs = [1, 2, 3]\n  xs.each do |x|\n    puts(x + 1000000000)\n  end\n\n  if true\n'
              '    puts("a")\n  end\n\n  puts(1)\nend\n')
# Two or more `|>` go one stage per line and close with a `)` alone, a wrapped statement is followed by an empty line,
# a single `|>` stays on its line, and the last statement of a block gets no empty line after it.
PIPES_HEAD = 'def twice(n: Int) -> Int\n  return n * 2\nend\n\ndef main() -> Void\n'
PIPES = (PIPES_HEAD + '  n = 3\n  total = n |> twice() |> twice()\n  one = n |> twice()\n  puts(total + one)\nend\n')
PIPES_LAID_OUT = (PIPES_HEAD + '  n = 3\n  total = (\n    n\n    |> twice()\n    |> twice()\n  )\n\n'
                  '  one = n |> twice()\n  puts(total + one)\nend\n')
# Comments between the stages of a chain, after a stage and after the first operand stay on their stage; the file used
# to be refused with FMT-INTERNAL.
PIPE_COMMENTS = (PIPES_HEAD + '  n = 3\n  total = (n # first\n    # between\n    |> twice() # after one\n    |> twice())\n'
                 '  puts(total)\nend\n')
PIPE_COMMENTS_LAID_OUT = (PIPES_HEAD + '  n = 3\n  total = (\n    n # first\n    # between\n    |> twice() # after one\n'
                          '    |> twice()\n  )\n\n  puts(total)\nend\n')


def fmt(*words, cwd, json_style=False, stdin=None):
    style = ["--json"] if json_style else []
    return run(cli() + style + ["fmt", *words], env=vm_environment(), cwd=cwd, stdin=stdin)


def lay_out(root, files):
    for name, data in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode("utf-8"))


def text(root, name):
    return (root / name).read_bytes().decode("utf-8")


def test_check_lists_the_files_that_would_change_and_fails(tmp_path):
    lay_out(tmp_path, {"src/good.agc": FORMATTED, "src/bad.agc": UNFORMATTED,
                       "src/crlf.agc": FORMATTED.replace("\n", "\r\n")})
    result = fmt("--check", "src", cwd=tmp_path)
    assert (result.code, result.stderr) == (1, "")
    assert sorted(result.stdout.split()) == ["src/bad.agc", "src/crlf.agc"]
    assert text(tmp_path, "src/bad.agc") == UNFORMATTED
    passed = fmt("--check", "src/good.agc", cwd=tmp_path)
    assert (passed.code, passed.stdout, passed.stderr) == (0, "", "")


def test_write_mode_rewrites_the_files_of_the_current_folder_and_skips_agc_libs(tmp_path):
    lay_out(tmp_path, {"src/bad.agc": UNFORMATTED, "src/crlf.agc": FORMATTED.replace("\n", "\r\n"),
                       "good.agc": FORMATTED, "agc_libs/lib/vendored.agc": UNFORMATTED})
    result = fmt(cwd=tmp_path)
    assert (result.code, result.stdout, result.stderr) == (0, "", "")
    assert [text(tmp_path, name) for name in ("src/bad.agc", "src/crlf.agc", "good.agc")] == [FORMATTED] * 3
    assert text(tmp_path, "agc_libs/lib/vendored.agc") == UNFORMATTED
    assert fmt("--check", cwd=tmp_path).code == 0


@host_only(WINDOWS, "file modes and links")
def test_write_mode_keeps_the_permission_bits_and_writes_through_a_symbolic_link(tmp_path):
    lay_out(tmp_path, {"tool.agc": UNFORMATTED, "frozen.agc": UNFORMATTED, "real/target.agc": UNFORMATTED})
    (tmp_path / "tool.agc").chmod(0o755)
    (tmp_path / "frozen.agc").chmod(0o444)
    os.symlink("real/target.agc", tmp_path / "link.agc")
    result = fmt("tool.agc", "frozen.agc", "link.agc", cwd=tmp_path)
    assert (result.code, result.stdout, result.stderr) == (0, "", "")
    modes = [stat.S_IMODE((tmp_path / name).stat().st_mode) for name in ("tool.agc", "frozen.agc")]
    assert modes == [0o755, 0o444]
    assert [text(tmp_path, name) for name in ("tool.agc", "frozen.agc", "real/target.agc")] == [FORMATTED] * 3
    assert os.readlink(tmp_path / "link.agc") == "real/target.agc"


def test_a_file_that_does_not_parse_is_refused_and_left_as_it_is(tmp_path):
    lay_out(tmp_path, {"broken.agc": BROKEN, "bad.agc": UNFORMATTED})
    checked = fmt("--check", "broken.agc", cwd=tmp_path, json_style=True)
    assert (checked.code, checked.stdout) == (1, "")
    assert json.loads(checked.stderr)["code"] == "LEX-UNCLOSED-DELIMITER"
    written = fmt("broken.agc", "bad.agc", cwd=tmp_path, json_style=True)
    assert written.code == 1
    assert json.loads(written.stderr)["code"] == "LEX-UNCLOSED-DELIMITER"
    assert (text(tmp_path, "broken.agc"), text(tmp_path, "bad.agc")) == (BROKEN, FORMATTED)


def test_the_style_of_the_nearest_manifest_sets_the_width_and_the_empty_line_after_end(tmp_path):
    style = "[style]\nmax_line_width = 40\nblank_line_after_end = true\n"
    lay_out(tmp_path, {"agentica.toml": style, "a/wide.agc": WIDE, "a/ends.agc": ENDS,
                       "inner/agentica.toml": 'name = "inner"\n', "inner/wide.agc": WIDE})
    assert fmt(cwd=tmp_path).code == 0
    assert (text(tmp_path, "a/wide.agc"), text(tmp_path, "a/ends.agc")) == (WIDE_AT_40, ENDS_BLANK)
    # A nearer manifest with no [style] is another project: the default width, no empty line added.
    assert text(tmp_path, "inner/wide.agc") == WIDE
    # The output follows the rule that `agentica check` enforces.
    checked = run(cli() + ["check", "a/ends.agc"], env=vm_environment(), cwd=tmp_path)
    assert checked.code == 0, checked.stderr


def test_a_chain_of_two_pipes_and_a_wrapped_statement_are_laid_out_and_pass_check(tmp_path):
    style = "[style]\nblank_line_after_end = true\n"
    lay_out(tmp_path, {"agentica.toml": style, "pipes.agc": PIPES})
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "pipes.agc") == PIPES_LAID_OUT
    # fmt twice is fmt once, and the lone `)` and the empty lines are what `check` asks for.
    assert fmt("--check", cwd=tmp_path).stdout == ""
    checked = run(cli() + ["check", "pipes.agc"], env=vm_environment(), cwd=tmp_path)
    assert checked.code == 0, checked.stderr


def test_comments_inside_a_pipe_chain_stay_on_their_stage_and_keep_the_tree(tmp_path):
    lay_out(tmp_path, {"chain.agc": PIPE_COMMENTS})
    before = fmt("--tree", "chain.agc", cwd=tmp_path)
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "chain.agc") == PIPE_COMMENTS_LAID_OUT
    assert fmt("--check", cwd=tmp_path).stdout == ""
    after = fmt("--tree", "chain.agc", cwd=tmp_path)
    assert (before.code, after.code, before.stdout) == (0, 0, after.stdout)


def test_a_bad_style_value_is_a_manifest_error(tmp_path):
    lay_out(tmp_path, {"agentica.toml": "[style]\nmax_line_width = 0\n", "bad.agc": UNFORMATTED})
    result = fmt("bad.agc", cwd=tmp_path, json_style=True)
    assert result.code == 1
    assert json.loads(result.stderr)["code"] == "PKG-MANIFEST-INVALID"
    assert text(tmp_path, "bad.agc") == UNFORMATTED


def test_a_dash_formats_the_standard_input_to_the_standard_output(tmp_path):
    lay_out(tmp_path, {"agentica.toml": "[style]\nmax_line_width = 40\n"})
    result = fmt("-", cwd=tmp_path, stdin=WIDE)
    assert (result.code, result.stdout, result.stderr) == (0, WIDE_AT_40, "")
    same = fmt("-", cwd=tmp_path, stdin=WIDE_AT_40)
    assert (same.code, same.stdout) == (0, WIDE_AT_40)
    broken = fmt("-", cwd=tmp_path, stdin=BROKEN, json_style=True)
    assert (broken.code, broken.stdout) == (1, "")
    assert json.loads(broken.stderr)["code"] == "LEX-UNCLOSED-DELIMITER"


def test_a_guard_is_written_back_as_a_guard_with_the_same_tree(tmp_path):
    guards = ('def f(xs: List[Int]) -> Int\n  for x in xs\n    next  if x < 0 # skip\n    # big ones end it\n'
              '    break if x > 9\n  end\n\n  return  0 if xs.any? do |x| x == 5 end\n'
              '  xs.each do |x| return if x == 1 end\n  case xs.size\n    1 -> return 2 if xs[0] == 2\n    _ -> puts(1)\n'
              '  end\n\n  return 1\nend\n')
    laid_out = guards.replace("next  if", "next if").replace("return  0", "return 0")
    lay_out(tmp_path, {"guards.agc": guards})
    before = fmt("--tree", "guards.agc", cwd=tmp_path)
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "guards.agc") == laid_out
    after = fmt("--tree", "guards.agc", cwd=tmp_path)
    assert (before.code, after.code, before.stdout) == (0, 0, after.stdout)


def test_a_guard_too_long_for_its_line_is_written_as_the_if_it_stands_for(tmp_path):
    message = "x" * 90
    long = 'def f(text: String) -> Result[Int]\n  return error("%s") if text.empty?\n  return ok(1)\nend\n' % message
    spelled = ('def f(text: String) -> Result[Int]\n  if text.empty?\n    return error("%s")\n  end\n  return ok(1)\nend\n'
               % message)
    lay_out(tmp_path, {"long.agc": long})
    before = fmt("--tree", "long.agc", cwd=tmp_path)
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "long.agc") == spelled
    # Formatting again changes nothing, and the normal form leaves out the guard mark, so the check of the output passes.
    assert fmt("--check", cwd=tmp_path).stdout == ""
    assert fmt("--tree", "long.agc", cwd=tmp_path).stdout == before.stdout


def test_a_guard_that_spans_lines_is_written_as_the_if_it_stands_for(tmp_path):
    # A heredoc value takes the lines below its guard, which is one line, so it becomes the `if` even though it fits.
    lay_out(tmp_path, {"doc.agc": 'def f(x: Int) -> String\n  return <<~A if x > 0\n    a\n    b\n  A\n  return ""\nend\n'})
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "doc.agc") == (
        'def f(x: Int) -> String\n  if x > 0\n    return <<~A\n    a\n    b\n  A\n  end\n  return ""\nend\n')
    assert fmt("--check", cwd=tmp_path).stdout == ""


# An `if` with one `return`, `break` or `next` becomes a guard, also in a loop, a `case` arm, a block and another `if`.
# Each `if` after the first is kept: a comment on its `if` line, inside it or on its `end` line, an `else`, a second
# statement, a statement of several lines (a heredoc).
SPELLED = """def f(xs: List[Int], text: String) -> Int
  if text == ""
    return 0
  end

  for x in xs
    if x < 0
      next
    end

    if x > 9
      break
    end

    if x == 5
      if x == 5
        return 5
      end
    end
  end

  case text.size
    1 ->
      if xs.size == 0
        return 6
      end
    _ -> puts(2)
  end

  xs.each do |x|
    if x == 1
      return
    end
  end

  if text == "a" # on the if line
    return 1
  end

  if text == "b"
    # inside
    return 2
  end

  if text == "c"
    return 3
  end # on the end line
  if text == "d"
    return 3
  else
    puts(1)
  end

  if text == "e"
    puts(4)
    return 4
  end

  if text == "f"
    return <<~A.size
    one
    two
  A
  end
  return 8
end
"""
GUARDED = """def f(xs: List[Int], text: String) -> Int
  return 0 if text == ""

  for x in xs
    next if x < 0

    break if x > 9

    if x == 5
      return 5 if x == 5
    end
  end

  case text.size
    1 -> return 6 if xs.size == 0
    _ -> puts(2)
  end

  xs.each do |x| return if x == 1 end

""" + SPELLED[SPELLED.index("  if text == \"a\""):]


def test_an_if_with_one_return_break_or_next_becomes_a_guard_unless_something_keeps_it(tmp_path):
    lay_out(tmp_path, {"spelled.agc": SPELLED})
    before = fmt("--tree", "spelled.agc", cwd=tmp_path)
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "spelled.agc") == GUARDED
    # Formatting again changes nothing, and the tree is the same.
    assert fmt("--check", cwd=tmp_path).stdout == ""
    assert fmt("--tree", "spelled.agc", cwd=tmp_path).stdout == before.stdout


def test_an_if_whose_statement_fmt_writes_on_one_line_is_a_guard_on_the_first_run(tmp_path):
    # The block takes three lines in the source and one in the output: the guard comes at once, so a second run of
    # `fmt` finds nothing to change.
    source = ("def f(n: Int) -> Fn[Int, Int]\n  if n > 0\n    return keep() do |x: Int|\n      x + n\n    end\n  end\n"
              "  return keep() do |x: Int| x end\nend\n")
    lay_out(tmp_path, {"block.agc": source})
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "block.agc") == ("def f(n: Int) -> Fn[Int, Int]\n  return keep() do |x: Int| x + n end if n > 0\n"
                                           "  return keep() do |x: Int| x end\nend\n")
    assert fmt("--check", cwd=tmp_path).stdout == ""


# A pipe chain of two or more `|>` breaks as the value of a `return`, so it keeps the `if`, and a guard with one becomes
# the `if`. A method chain with leading dots joins when it fits, as in a body, so it becomes a guard; when it does not
# fit, the `if` keeps it broken. Comments on the lines around the `if` stay where they are, and a call that the source
# spreads over lines but that fits is joined into the guard.
VALUES = """def f(xs: List[Int], c: Bool) -> List[Int]
  if c
    return xs |> twice() |> twice()
  end

  return xs |> twice() |> twice() if not c
end

def g(xs: List[Int], c: Bool) -> List[Int]
  if c
    return xs
      .map(inc)
      .select(odd)
  end

  if xs.size > 1
    return xs
      .map(increment_every_item_of_the_list_by_one)
      .select(keep_only_the_odd_items_of_the_list_and_drop_the_rest)
  end

  # before the if
  if not c
    return f(
      xs,
      c,
    )
  end
  # after the end
  return xs
end
"""
VALUES_FORMATTED = """def f(xs: List[Int], c: Bool) -> List[Int]
  if c
    return (
      xs
      |> twice()
      |> twice()
    )
  end

  if not c
    return (
      xs
      |> twice()
      |> twice()
    )
  end
end

def g(xs: List[Int], c: Bool) -> List[Int]
  return xs.map(inc).select(odd) if c

  if xs.size > 1
    return xs.map(increment_every_item_of_the_list_by_one)
      .select(keep_only_the_odd_items_of_the_list_and_drop_the_rest)
  end

  # before the if
  return f(xs, c) if not c
  # after the end
  return xs
end
"""


def test_a_guard_value_is_laid_out_as_in_a_body(tmp_path):
    lay_out(tmp_path, {"values.agc": VALUES})
    before = fmt("--tree", "values.agc", cwd=tmp_path)
    assert fmt(cwd=tmp_path).code == 0
    assert text(tmp_path, "values.agc") == VALUES_FORMATTED
    assert fmt("--check", cwd=tmp_path).stdout == ""
    assert fmt("--tree", "values.agc", cwd=tmp_path).stdout == before.stdout


@pytest.mark.parametrize("size, guarded", [(95, True), (96, False)])
def test_the_guard_and_the_if_meet_at_the_same_width(tmp_path, size, guarded):
    # `  return 0 if text == "..."` is 24 characters plus the text: 119, the width, for 95, and 120 for 96. Both forms of
    # the source give the guard at 119 and the `if` at 120.
    value = "x" * size
    guard = 'def f(text: String) -> Int\n  return 0 if text == "%s"\n  return 1\nend\n' % value
    spelled = 'def f(text: String) -> Int\n  if text == "%s"\n    return 0\n  end\n  return 1\nend\n' % value
    assert len('  return 0 if text == "%s"' % value) == 24 + size
    lay_out(tmp_path, {"guard.agc": guard, "spelled.agc": spelled})
    assert fmt(cwd=tmp_path).code == 0
    expected = guard if guarded else spelled
    assert (text(tmp_path, "guard.agc"), text(tmp_path, "spelled.agc")) == (expected, expected)


def test_tree_is_the_same_before_and_after_formatting(tmp_path):
    lay_out(tmp_path, {"bad.agc": UNFORMATTED, "good.agc": FORMATTED})
    before = fmt("--tree", "bad.agc", cwd=tmp_path)
    after = fmt("--tree", "good.agc", cwd=tmp_path)
    assert (before.code, before.stderr, after.code) == (0, "", 0)
    assert before.stdout == after.stdout


def test_a_wrong_call_is_fmt_usage_with_status_2(tmp_path):
    lay_out(tmp_path, {"good.agc": FORMATTED})
    calls = [["--bogus"], ["--check", "--bogus"], ["--tree"], ["--tree", "a.agc", "b.agc"], ["-", "good.agc"],
             ["missing.agc"], ["--check", "missing.agc"], ["--tree", "missing.agc"]]
    for words in calls:
        result = fmt(*words, cwd=tmp_path, json_style=True)
        assert (result.code, json.loads(result.stderr)["code"]) == (2, "FMT-USAGE"), words
    assert text(tmp_path, "good.agc") == FORMATTED
