"""`agentica check [PATH...]` through the product CLI (issue #813): one file answers as it always did, and several
files, a folder or no path check every `.agc` file and end with a count. The cases read the JSON form and assert codes,
file names, counts and exit statuses, never message text; the text form is checked by its exit status and streams."""
import json

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import problem

LIBRARY = "export def one() -> Int\n  return 1\nend\n"
PROGRAM = 'def main() -> Void\n  puts("ok")\nend\n'
BROKEN_TYPE = 'def main() -> Void\n  x: Int = "a"\n  puts(x)\nend\n'
BROKEN_SYNTAX = "x = 1\n"


def check(*words, cwd):
    return run(cli() + ["check", *words], env=vm_environment(), cwd=cwd)


def check_json(*words, cwd):
    return run(cli() + ["--json", "check", *words], env=vm_environment(), cwd=cwd)


def lay_out(root, files):
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def document(result, status):
    """The JSON document of a run over several files, after its exit status and empty stderr."""
    assert (result.code, result.stderr) == (status, "")
    return json.loads(result.stdout)


def verdicts(report):
    """file -> the code of its diagnostic, "" for a file that passed."""
    return {entry["file"]: entry.get("diagnostic", {}).get("code", "") for entry in report["files"]}


def test_one_file_keeps_its_output(tmp_path):
    lay_out(tmp_path, {"lib.agc": LIBRARY, "bad.agc": BROKEN_TYPE})
    passed = check("lib.agc", cwd=tmp_path)
    assert (passed.code, passed.stdout, passed.stderr) == (0, "check ok\n", "")
    assert check_json("lib.agc", cwd=tmp_path).stdout == '{"ok":true}\n'
    failed = check_json("bad.agc", cwd=tmp_path)
    assert problem(failed, "CHECK-TYPE-MISMATCH", 1)["file"] == "bad.agc"


def test_several_files_check_all_and_count(tmp_path):
    lay_out(tmp_path, {"a.agc": PROGRAM, "b.agc": LIBRARY})
    result = check("a.agc", "b.agc", cwd=tmp_path)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.endswith("2 files\n")
    report = document(check_json("a.agc", "b.agc", cwd=tmp_path), 0)
    assert (report["ok"], report["checked"], report["failed"]) == (True, 2, 0)
    assert verdicts(report) == {"a.agc": "", "b.agc": ""}


def test_one_failure_among_many_does_not_stop_the_others(tmp_path):
    lay_out(tmp_path, {"a.agc": PROGRAM, "bad.agc": BROKEN_TYPE, "syntax.agc": BROKEN_SYNTAX, "z.agc": LIBRARY})
    report = document(check_json(".", cwd=tmp_path), 1)
    assert (report["ok"], report["checked"], report["failed"]) == (False, 4, 2)
    assert verdicts(report) == {
        "a.agc": "", "bad.agc": "CHECK-TYPE-MISMATCH", "syntax.agc": "PARSE-TOP-LEVEL-STATEMENT", "z.agc": ""}
    assert [entry["ok"] for entry in report["files"]] == [True, False, False, True]
    text = check(".", cwd=tmp_path)
    assert (text.code, text.stdout) == (1, "")
    assert "bad.agc" in text.stderr and "syntax.agc" in text.stderr and text.stderr.rstrip().endswith("2 of 4 files")


def test_a_folder_skips_hidden_folders_and_the_deps_of_a_project(tmp_path):
    lay_out(tmp_path, {
        "agentica.toml": 'name = "demo"\n',
        "main.agc": PROGRAM,
        "src/lib.agc": LIBRARY,
        "src/deep/more.agc": LIBRARY,
        "notes.txt": "not a source",
        "deps/pkg/broken.agc": BROKEN_SYNTAX,
        ".hidden/broken.agc": BROKEN_SYNTAX,
        "src/.cache/broken.agc": BROKEN_SYNTAX,
    })
    report = document(check_json(cwd=tmp_path), 0)
    assert sorted(verdicts(report)) == ["main.agc", "src/deep/more.agc", "src/lib.agc"]
    inside = document(check_json("src", cwd=tmp_path), 0)
    assert sorted(verdicts(inside)) == ["src/deep/more.agc", "src/lib.agc"]


def test_a_path_that_names_nothing_is_a_usage_error_and_checks_no_file(tmp_path):
    lay_out(tmp_path, {"bad.agc": BROKEN_TYPE, "empty/readme.txt": "x"})
    for words in (["bad.agc", "absent.agc"], ["empty"], ["--bogus"]):
        failed = check_json(*words, cwd=tmp_path)
        assert problem(failed, "QUERY-USAGE", 2)["file"] == "<arguments>"
    nothing = check_json(cwd=tmp_path / "empty")
    assert problem(nothing, "QUERY-USAGE", 2)["file"] == "<arguments>"


def test_stdin_stays_a_one_file_form(tmp_path):
    lay_out(tmp_path, {"lib.agc": LIBRARY})
    buffer = run(cli() + ["--json", "check", "--stdin", "lib.agc"], env=vm_environment(), cwd=tmp_path,
                 stdin=BROKEN_TYPE.encode())
    assert problem(buffer, "CHECK-TYPE-MISMATCH", 1)["file"] == "lib.agc"
    for words in (["--stdin", "a.agc", "b.agc"], ["lib.agc", "--stdin", "lib.agc"]):
        refused = check(*words, cwd=tmp_path)
        assert (refused.code, refused.stdout) == (2, "")


def test_json_may_follow_the_path(tmp_path):
    lay_out(tmp_path, {"lib.agc": LIBRARY})
    result = check("lib.agc", "--json", cwd=tmp_path)
    assert (result.code, result.stdout, result.stderr) == (0, '{"ok":true}\n', "")
