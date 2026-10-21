"""The entry point `main`, through the product CLI.

`agentica check` does not need a `main`, so a library file checks clean, but a `main` that is declared must be
`main() -> Void`. A run and `agentica compile` still report CHECK-MAIN for a file with no `main`. A test asserts the
code and the span, never the message (AGENTS.md).
"""
import json

from tests.agentica_test import cli, run

LIBRARY = "def double(x: Int) -> Int\n  return x * 2\nend\n"


def source(tmp_path, text):
    path = tmp_path / "program.agc"
    path.write_text(text, encoding="utf-8")
    return str(path)


def problem_of(result):
    assert result.code == 1, result.stdout + result.stderr
    return json.loads(result.stderr.strip().split("\n")[-1])


def start_of(problem):
    return problem["range"]["start"]["line"], problem["range"]["start"]["column"]


def test_check_accepts_a_file_with_no_main(tmp_path):
    result = run(cli() + ["--json", "check", source(tmp_path, LIBRARY)])
    assert (result.code, result.stdout) == (0, '{"ok":true}\n')


def test_check_still_checks_the_bodies_of_a_file_with_no_main(tmp_path):
    result = run(cli() + ["--json", "check", source(tmp_path, 'def f() -> Int\n  return "a"\nend\n')])
    assert problem_of(result)["code"] != "CHECK-MAIN"


def test_check_rejects_a_main_with_a_wrong_signature(tmp_path):
    for text in ("def main(x: Int) -> Void\nend\n", "def main() -> Int\n  return 1\nend\n"):
        problem = problem_of(run(cli() + ["--json", "check", source(tmp_path, LIBRARY + "\n" + text)]))
        assert (problem["code"], start_of(problem)) == ("CHECK-MAIN", (5, 1)), text


def test_a_run_reports_the_missing_main(tmp_path):
    problem = problem_of(run(cli() + ["--json", source(tmp_path, LIBRARY)]))
    assert (problem["code"], start_of(problem)) == ("CHECK-MAIN", (1, 1))


def test_compile_reports_the_missing_main(tmp_path):
    output = tmp_path / "program.agcb"
    problem = problem_of(run(cli() + ["--json", "compile", source(tmp_path, LIBRARY), "-o", str(output)]))
    assert (problem["code"], start_of(problem)) == ("CHECK-MAIN", (1, 1))
    assert not output.exists()


def test_check_stdin_accepts_a_buffer_with_no_main(tmp_path):
    result = run(cli() + ["--json", "check", "--stdin", "buffer.agc"], stdin=LIBRARY, cwd=tmp_path)
    assert (result.code, result.stdout) == (0, '{"ok":true}\n')
