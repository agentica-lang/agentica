"""`agentica fmt --check [PATH...]` and `agentica fmt --tree FILE` through the product CLI (docs/future/47-formatter.md,
phase 47b). The cases assert exit statuses, the listed paths and diagnostic codes, never message text."""
import json

from tests.agentica_test import cli, run, vm_environment

FORMATTED = 'def main() -> Void\n  puts("ok")\nend\n'
UNFORMATTED = 'def main() -> Void\n    puts( "ok" )\nend\n'
BROKEN = "def main(\n"


def fmt(*words, cwd, json_style=False):
    style = ["--json"] if json_style else []
    return run(cli() + style + ["fmt", *words], env=vm_environment(), cwd=cwd)


def lay_out(root, files):
    for name, data in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode("utf-8"))


def test_check_lists_the_files_that_would_change_and_fails(tmp_path):
    lay_out(tmp_path, {"src/good.agc": FORMATTED, "src/bad.agc": UNFORMATTED,
                       "src/crlf.agc": FORMATTED.replace("\n", "\r\n")})
    result = fmt("--check", "src", cwd=tmp_path)
    assert (result.code, result.stderr) == (1, "")
    assert sorted(result.stdout.split()) == ["src/bad.agc", "src/crlf.agc"]
    passed = fmt("--check", "src/good.agc", cwd=tmp_path)
    assert (passed.code, passed.stdout, passed.stderr) == (0, "", "")


def test_check_refuses_a_file_that_does_not_parse(tmp_path):
    lay_out(tmp_path, {"broken.agc": BROKEN, "good.agc": FORMATTED})
    result = fmt("--check", "broken.agc", "good.agc", cwd=tmp_path, json_style=True)
    assert (result.code, result.stdout) == (1, "")
    assert json.loads(result.stderr)["code"] == "LEX-UNCLOSED-DELIMITER"


def test_tree_is_the_same_before_and_after_formatting(tmp_path):
    lay_out(tmp_path, {"bad.agc": UNFORMATTED, "good.agc": FORMATTED})
    before = fmt("--tree", "bad.agc", cwd=tmp_path)
    after = fmt("--tree", "good.agc", cwd=tmp_path)
    assert (before.code, before.stderr, after.code) == (0, "", 0)
    assert before.stdout == after.stdout


def test_a_wrong_call_is_a_usage_error(tmp_path):
    assert fmt(cwd=tmp_path).code == 2
    assert fmt("--tree", cwd=tmp_path).code == 2
    missing = fmt("--check", "missing.agc", cwd=tmp_path, json_style=True)
    assert missing.code == 2
    assert json.loads(missing.stderr)["code"] == "QUERY-USAGE"
