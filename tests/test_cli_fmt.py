"""`agentica fmt` through the product CLI (docs/future/47-formatter.md, 47.2): write mode, `--check`, `-` for standard
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
