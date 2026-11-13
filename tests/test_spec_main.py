"""The entry point `main`, through the product CLI.

`agentica check` does not need a `main`, so a library file checks clean, but a `main` that is declared must be
`main() -> Void`. A run and `agentica compile` still report CHECK-MAIN for a file with no `main`. A `*_test.agc` file
with no `main` has its top-level `test_*` functions as its tests (issue #983); `agentica check` and `agentica test` read
it as a test file by its name, and in a file of another name `test_*` functions are ordinary. A test asserts the code
and the span, never the message (AGENTS.md).
"""
import json

import pytest

from tests.agentica_test import cli, run

LIBRARY = "def double(x: Int) -> Int\n  return x * 2\nend\n"
TEST_PASSING = "def test_adds() -> Result[Void]\n  return Test.eq(1 + 1, 2)\nend\n"
MAIN = "\ndef main() -> Void\n  puts(\"main\")\nend\n"


def source(tmp_path, text, name="program.agc"):
    path = tmp_path / name
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


def sample_test_file(tmp_path, text):
    return source(tmp_path, text, name="sample_test.agc")


def check(path):
    return run(cli() + ["--json", "check", path])


def test_check_accepts_a_test_file_with_test_functions_and_no_main(tmp_path):
    helper = "def twice(n: Int) -> Int\n  return n * 2\nend\n\n"
    exported = "def test_exported() -> Result[Void]\n  return Test.eq(twice(2), 4)\nend\n\n"
    result = check(sample_test_file(tmp_path, exported + helper + TEST_PASSING))
    assert (result.code, result.stdout) == (0, '{"ok":true}\n'), result.stderr


@pytest.mark.parametrize("text", [
    "def test_takes(n: Int) -> Result[Void]\n  return ok()\nend\n",
    "def test_counts() -> Result[Int]\n  return ok(1)\nend\n",
    "def test_nothing() -> Void\nend\n",
    "def test_generic[T]() -> Result[Void]\n  return ok()\nend\n",
])
def test_a_test_function_takes_nothing_and_returns_result_void(tmp_path, text):
    problem = problem_of(check(sample_test_file(tmp_path, TEST_PASSING + "\n" + text)))
    assert (problem["code"], start_of(problem)) == ("CHECK-TEST-SIGNATURE", (5, 1))


def test_a_test_function_writes_result_void_and_not_an_alias_of_it(tmp_path):
    text = "type Outcome = Result[Void]\n\ndef test_aliased() -> Outcome\n  return ok()\nend\n"
    problem = problem_of(check(sample_test_file(tmp_path, text)))
    assert (problem["code"], start_of(problem)) == ("CHECK-TEST-SIGNATURE", (3, 1))


def test_a_test_function_needs_a_name_after_the_prefix(tmp_path):
    problem = problem_of(check(sample_test_file(tmp_path, TEST_PASSING + "\ndef test_() -> Result[Void]\n  return ok()\nend\n")))
    assert (problem["code"], start_of(problem)) == ("CHECK-TEST-NAME", (5, 1))


def test_a_test_file_with_test_functions_must_not_declare_main(tmp_path):
    problem = problem_of(check(sample_test_file(tmp_path, TEST_PASSING + MAIN)))
    assert (problem["code"], start_of(problem)) == ("CHECK-TEST-MAIN", (5, 1))
    # With a `main`, a `test_*` helper of the `Test.run` form is not checked as a test: the mix is the problem.
    helper = "def test_helper(x: Int) -> Int\n  return x\nend\n"
    problem = problem_of(check(sample_test_file(tmp_path, helper + MAIN)))
    assert (problem["code"], start_of(problem)) == ("CHECK-TEST-MAIN", (5, 1))


def test_main_and_test_functions_are_plain_functions_outside_a_test_file(tmp_path):
    path = source(tmp_path, "def test_adds() -> Int\n  return 1\nend\n" + MAIN, name="program.agc")
    assert check(path).code == 0
    result = run(cli() + [path])
    assert (result.code, result.stdout) == (0, "main\n"), result.stderr


def test_a_test_file_with_main_and_no_test_functions_keeps_its_main(tmp_path):
    text = 'def main() -> Void\n  Test.run([Test.test("adds") do Test.eq(1 + 1, 2) end])\nend\n'
    assert check(sample_test_file(tmp_path, text)).code == 0


def test_a_run_of_a_test_file_with_no_main_reports_the_missing_main(tmp_path):
    problem = problem_of(run(cli() + ["--json", sample_test_file(tmp_path, TEST_PASSING)]))
    assert (problem["code"], start_of(problem)) == ("CHECK-MAIN", (1, 1))
