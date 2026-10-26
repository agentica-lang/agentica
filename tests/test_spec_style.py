"""The optional style rule `[style] blank_line_after_end` of agentica.toml, through the CLI.

With the key on, a line whose code is only `end` needs an empty line after it (CHECK-BLANK-LINE-AFTER-END, at the
`end`). The cases run `--json check` and assert the code and the span, never the message (AGENTS.md).
"""
import json

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, vm_environment
from tests.package_support import Workspace, dependency
from tests.spec_support import check_diagnostic

ON = "[style]\nblank_line_after_end = true\n"

# A program with the `end` of an `if` at line 4, column 3, followed by code.
BARE = "def main() -> Void\n  if true\n    puts(\"a\")\n  end\n  puts(\"b\")\nend\n"
BARE_END = (4, 3)


def check(tmp_path, program, manifest=ON):
    """The problem `--json check` reports for program, or None when it checks clean."""
    if manifest is not None:
        (tmp_path / "agentica.toml").write_text(manifest, encoding="utf-8")
    return check_diagnostic(program, tmp_path)


def start(problem):
    return problem["range"]["start"]["line"], problem["range"]["start"]["column"]


def test_the_rule_is_off_without_the_key(tmp_path):
    assert check(tmp_path, BARE, manifest=None) is None
    assert check(tmp_path, BARE, manifest="[style]\nmax_line_width = 119\n") is None
    assert check(tmp_path, BARE, manifest="[style]\nblank_line_after_end = false\n") is None


def test_a_bare_end_needs_an_empty_line_after_it(tmp_path):
    problem = check(tmp_path, BARE)
    assert (problem["code"], start(problem)) == ("CHECK-BLANK-LINE-AFTER-END", BARE_END)
    assert problem["range"]["end"]["column"] == 6
    assert problem["file"].endswith("program.agc")
    assert check(tmp_path, BARE.replace("  end\n", "  end\n\n")) is None


def test_the_first_missing_line_is_reported_and_a_type_error_comes_first(tmp_path):
    two = "def f() -> Void\n  if true\n  end\n  if true\n  end\n  puts(\"b\")\nend\n\ndef main() -> Void\nend\n"
    assert start(check(tmp_path, two)) == (3, 3)
    wrong = BARE.replace('puts("b")', "puts(1 + \"b\")")
    assert check(tmp_path, wrong)["code"] != "CHECK-BLANK-LINE-AFTER-END"


# (what, program, the problem is at (line, column), or None when the program is clean)
CASES = [
    ("a trailing comment on the end", BARE.replace("  end\n", "  end # the if\n"), BARE_END),
    ("a comment line is not an empty line", BARE.replace("  end\n", "  end\n  # next\n"), BARE_END),
    ("spaces and tabs are an empty line", BARE.replace("  end\n", "  end\n \t \n"), None),
    ("the next end", "def main() -> Void\n  if true\n    if true\n    end\n  end\nend\n", None),
    ("else", "def main() -> Void\n  if true\n    if true\n    end\n  else\n  end\nend\n", None),
    ("elsif", "def main() -> Void\n  if true\n    if true\n    end\n  elsif true\n  end\nend\n", None),
    ("a closing paren", "def main() -> Void\n  puts(\n    [1].map do |i|\n      i\n    end\n  )\nend\n", None),
    ("a closing bracket",
     "def main() -> Void\n  xs = [\n    [1].map do |i|\n      i\n    end\n  ]\n  puts(xs)\nend\n", None),
    ("a closing brace",
     "def main() -> Void\n  m = {\n    \"a\": [1].map do |i|\n      i\n    end\n  }\n  puts(m)\nend\n", None),
    ("a leading dot", "def main() -> Void\n  v = [1].map do |i|\n    i\n  end\n  .size\n  puts(v)\nend\n", None),
    ("a leading dot after a comment line",
     "def main() -> Void\n  v = [1].map do |i|\n    i\n  end\n  # more\n  .size\n  puts(v)\nend\n", None),
    ("the last end with no final line break", "def main() -> Void\nend", None),
    ("the last end with one final line break", "def main() -> Void\nend\n", None),
    ("the last end with an extra empty line", "def main() -> Void\nend\n\n", None),
    ("the last end with empty lines of spaces", "def main() -> Void\nend\n  \n\t\n", None),
    ("an end with more on its line", "def main() -> Void\n  v = [1].map do |i| i end.size\n  puts(v)\nend\n", None),
    ("an end that closes a call", "def main() -> Void\n  puts([1].map do |i| i end)\n  puts(1)\nend\n", None),
    ("an end inside a comment line", "def main() -> Void\n  # end\n  puts(1)\nend\n", None),
    ("a comment line before a closing end", BARE.replace("  puts(\"b\")\n", "  # tail\n"), BARE_END),
    ("a comment line after the last end", "def main() -> Void\nend\n# tail\n", (2, 1)),
    ("CRLF line breaks", BARE.replace("\n", "\r\n"), BARE_END),
    ("CRLF line breaks and an empty line", BARE.replace("  end\n", "  end\n\n").replace("\n", "\r\n"), None),
    ("CRLF line breaks and a line of spaces", BARE.replace("  end\n", "  end\n  \n").replace("\n", "\r\n"), None),
    ("tabs", BARE.replace("  ", "\t"), (4, 2)),
    ("tabs and an empty line of tabs", BARE.replace("  ", "\t").replace("\tend\n", "\tend\n\t\t\n"), None),
    ("the arm of a case after an end",
     "def main() -> Void\n  case 1\n    1 ->\n      if true\n      end\n    _ -> puts(1)\n  end\nend\n",
     (5, 7)),
    ("the arm of a case after an end and an empty line",
     "def main() -> Void\n  case 1\n    1 ->\n      if true\n      end\n\n    _ -> puts(1)\n  end\nend\n",
     None),
    ("an end in a string", 'def main() -> Void\n  puts("end")\n  puts("a\\nend")\nend\n', None),
    ("an end line in a heredoc",
     "def main() -> Void\n  text = <<~T\n    one\n    end\n    two\n  T\n  puts(text)\nend\n", None),
    ("an end in an interpolation of a heredoc",
     "def main() -> Void\n  text = <<~T\n    #{[1].map do |i| i end.size}\n    end\n  T\n  puts(text)\nend\n", None),
    ("a bare end after a heredoc",
     "def main() -> Void\n  if true\n    text = <<~T\n      one\n      two\n    T\n    puts(text)\n  end\n  puts(1)\nend\n",
     (8, 3)),
]


@pytest.mark.parametrize("what, program, expected", CASES, ids=[case[0] for case in CASES])
def test_the_rule_and_its_exceptions(tmp_path, what, program, expected):
    problem = check(tmp_path, program)
    if expected is None:
        assert problem is None
    else:
        assert (problem["code"], start(problem)) == ("CHECK-BLANK-LINE-AFTER-END", expected)


def test_the_rule_covers_the_files_an_import_reads_and_not_std(tmp_path):
    (tmp_path / "util.agc").write_text("export def one() -> Int\n  if true\n    return 1\n  end\n  return 2\nend\n",
                                       encoding="utf-8")
    program = 'import Util from "util"\nimport Queue from "std/queue"\n\ndef main() -> Void\n  puts(Util.one())\nend\n'
    problem = check(tmp_path, program)
    assert (problem["code"], start(problem)) == ("CHECK-BLANK-LINE-AFTER-END", (4, 3))
    assert problem["file"].endswith("util.agc")


@pytest.mark.parametrize("tail", ["", "\n", "\n\n"], ids=["no line break", "one line break", "an extra empty line"])
def test_the_last_end_of_a_module_file_needs_nothing_after_it(tmp_path, tail):
    (tmp_path / "util.agc").write_text("export def one() -> Int\n  return 1\nend" + tail, encoding="utf-8")
    program = 'import Util from "util"\n\ndef main() -> Void\n  puts(Util.one())\nend\n'
    assert check(tmp_path, program) is None


@pytest.mark.parametrize("value", ['"yes"', "1", "[true]"])
def test_a_key_that_is_not_a_boolean_is_a_manifest_error(tmp_path, value):
    problem = check(tmp_path, BARE, manifest="[style]\nblank_line_after_end = %s\n" % value)
    assert problem["code"] == "PKG-MANIFEST-INVALID"
    assert problem["key_path"] == "style.blank_line_after_end"
    assert problem["file"].endswith("agentica.toml")


def test_a_query_command_reports_the_rule_and_its_partial_answer_lists_it(tmp_path):
    (tmp_path / "agentica.toml").write_text(ON, encoding="utf-8")
    (tmp_path / "program.agc").write_text(BARE, encoding="utf-8")
    spot = "%s:5:3" % (tmp_path / "program.agc")
    whole = run(cli() + ["--json", "type-at", spot], cwd=tmp_path, env=vm_environment())
    assert (whole.code, json.loads(whole.stderr)["code"]) == (1, "CHECK-BLANK-LINE-AFTER-END")
    partial = run(cli() + ["--json", "type-at", "--partial", spot], cwd=tmp_path, env=vm_environment())
    assert partial.code == 0, partial.stderr
    report = json.loads(partial.stdout)
    assert (report["partial"], [found["code"] for found in report["diagnostics"]]) == (
        True, ["CHECK-BLANK-LINE-AFTER-END"])
    (tmp_path / "agentica.toml").write_text("", encoding="utf-8")
    clean = run(cli() + ["--json", "type-at", "--partial", spot], cwd=tmp_path, env=vm_environment())
    assert clean.code == 0 and "diagnostics" not in json.loads(clean.stdout)


def test_a_manifest_toggled_on_and_off_is_seen_by_the_next_check(tmp_path):
    assert check(tmp_path, BARE, manifest="[style]\nblank_line_after_end = false\n") is None
    assert check(tmp_path, BARE)["code"] == "CHECK-BLANK-LINE-AFTER-END"
    assert check(tmp_path, BARE, manifest="[style]\nblank_line_after_end = false\n") is None


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


# A module with a bare end that has no empty line after it, and a program that imports it by the path given.
BROKEN = "export def one() -> Int\n  if true\n    return 1\n  end\n  return 2\nend\n"
FIXED = "export def one() -> Int\n  if true\n    return 1\n  end\n\n  return 2\nend\n"


def importing(path):
    return 'import Util from "%s"\n\ndef main() -> Void\n  puts(Util.one())\nend\n' % path


def run_check(root, **variables):
    result = run(cli() + ["--json", "check", str(root)], env=vm_environment(variables))
    return json.loads(result.stderr) if result.code else None


def test_a_file_outside_the_folder_of_the_manifest_is_not_checked(tmp_path):
    # The shared folder has no manifest. The root manifest governs the files below its folder only.
    write(tmp_path / "shared" / "util.agc", BROKEN)
    write(tmp_path / "app" / "agentica.toml", ON)
    write(tmp_path / "app" / "main.agc", importing("../shared/util"))
    assert run_check(tmp_path / "app" / "main.agc") is None
    # The same module below the folder of the manifest is checked.
    write(tmp_path / "app" / "lib" / "util.agc", BROKEN)
    write(tmp_path / "app" / "main.agc", importing("lib/util"))
    problem = run_check(tmp_path / "app" / "main.agc")
    assert (problem["code"], start(problem)) == ("CHECK-BLANK-LINE-AFTER-END", (4, 3))
    assert problem["file"].endswith("util.agc")


def test_a_file_in_a_folder_with_its_own_manifest_is_not_checked_by_the_root(tmp_path):
    write(tmp_path / "agentica.toml", ON)
    write(tmp_path / "sub" / "agentica.toml", "")
    write(tmp_path / "sub" / "deep" / "util.agc", BROKEN)
    write(tmp_path / "main.agc", importing("sub/deep/util"))
    assert run_check(tmp_path / "main.agc") is None
    # The key of the nested manifest is not honored either: only the manifest of the root file counts.
    write(tmp_path / "sub" / "agentica.toml", ON)
    assert run_check(tmp_path / "main.agc") is None
    write(tmp_path / "agentica.toml", "")
    write(tmp_path / "sub" / "deep" / "util.agc", BROKEN)
    assert run_check(tmp_path / "main.agc") is None
    # A file of the folder that has no manifest of its own below is checked.
    write(tmp_path / "agentica.toml", ON)
    write(tmp_path / "plain" / "util.agc", BROKEN)
    write(tmp_path / "main.agc", importing("plain/util"))
    assert run_check(tmp_path / "main.agc")["code"] == "CHECK-BLANK-LINE-AFTER-END"
    write(tmp_path / "plain" / "util.agc", FIXED)
    assert run_check(tmp_path / "main.agc") is None


def test_a_file_of_a_package_is_not_checked(tmp_path):
    git = "https://github.com/owner/greeter.git"
    ws = Workspace(tmp_path)
    ws.add_package("greeter", git, {"greet.agc": BROKEN})
    ws.write_manifest({"greeter": dependency(git, tag="v1.0.0")}, extra=ON)
    ws.write_lock()
    program = 'import Greet from "pkg/greeter/greet"\n\ndef main() -> Void\n  puts(Greet.one())\nend\n'
    write(ws.project / "main.agc", program)
    environment = vm_environment({"AGENTICA_PATH": "", **ws.cache_variables})
    result = run(cli() + ["--json", "check", str(ws.project / "main.agc")], cwd=ws.base, env=environment)
    assert (result.code, result.stdout) == (0, '{"ok":true}\n'), result.stderr
    # The files of the project itself are still checked.
    write(ws.project / "main.agc", program.replace("def main() -> Void\n", "def main() -> Void\n  if true\n  end\n"))
    result = run(cli() + ["--json", "check", str(ws.project / "main.agc")], cwd=ws.base, env=environment)
    assert json.loads(result.stderr)["code"] == "CHECK-BLANK-LINE-AFTER-END"


def test_a_library_is_not_checked_even_when_its_folder_is_inside_the_project(tmp_path):
    # vendor/ is a pkg/ root in the project folder. a.agc is a library and so is b.agc, which it imports.
    write(tmp_path / "app" / "agentica.toml", ON)
    write(tmp_path / "app" / "vendor" / "a.agc", 'import B from "b"\n\n' + BROKEN.replace("1", "B.one()", 1))
    write(tmp_path / "app" / "vendor" / "b.agc", BROKEN)
    write(tmp_path / "app" / "main.agc", importing("pkg/a").replace("Util", "A"))
    roots = {"AGENTICA_PATH": str(tmp_path / "app" / "vendor")}
    assert run_check(tmp_path / "app" / "main.agc", **roots) is None
    # The same module imported by a relative path is a file of the project.
    write(tmp_path / "app" / "main.agc", importing("vendor/b"))
    problem = run_check(tmp_path / "app" / "main.agc", **roots)
    assert (problem["code"], start(problem)) == ("CHECK-BLANK-LINE-AFTER-END", (4, 3))


def test_a_file_of_agc_libs_is_not_checked(tmp_path):
    write(tmp_path / "agentica.toml", ON)
    write(tmp_path / "agc_libs" / "a.agc", 'import B from "b"\n\n' + BROKEN.replace("1", "B.one()", 1))
    write(tmp_path / "agc_libs" / "b.agc", BROKEN)
    write(tmp_path / "main.agc", importing("pkg/a").replace("Util", "A"))
    roots = {"AGENTICA_PATH": ""}
    assert run_check(tmp_path / "main.agc", **roots) is None
    write(tmp_path / "main.agc", importing("agc_libs/b"))
    assert run_check(tmp_path / "main.agc", **roots) is None


@host_only(WINDOWS, "a symbolic link needs a privilege on Windows")
def test_a_file_is_checked_where_its_real_path_is(tmp_path):
    write(tmp_path / "shared" / "util.agc", BROKEN)
    write(tmp_path / "app" / "agentica.toml", ON)
    (tmp_path / "app" / "out.agc").symlink_to(tmp_path / "shared" / "util.agc")
    write(tmp_path / "app" / "main.agc", importing("out"))
    assert run_check(tmp_path / "app" / "main.agc") is None
    # A link to a file inside the folder is that file.
    write(tmp_path / "app" / "lib" / "util.agc", BROKEN)
    (tmp_path / "app" / "in.agc").symlink_to(tmp_path / "app" / "lib" / "util.agc")
    write(tmp_path / "app" / "main.agc", importing("in"))
    assert run_check(tmp_path / "app" / "main.agc")["code"] == "CHECK-BLANK-LINE-AFTER-END"
