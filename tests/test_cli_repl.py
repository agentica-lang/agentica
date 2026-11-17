"""`agentica repl` through the product CLI, with piped input: the names, declarations and tasks that live across
entries, redefinition, the problems that leave the session as it was, the commands and the exit statuses. The cases
read the `--json` answers (one object per entry or command) and assert values, types, codes and lines, never message
text; one case reads the plain form."""
import json

from tests.agentica_test import cli, run


def repl(tmp_path, *lines, json_style=True):
    words = [*cli(), "repl", "--json"] if json_style else [*cli(), "repl"]
    return run(words, stdin="".join(line + "\n" for line in lines), cwd=tmp_path)


def answers(got):
    return [json.loads(line) for line in got.stdout.splitlines()]


def code(answer):
    return answer["diagnostic"]["code"]


def test_a_name_keeps_its_value_and_type_across_entries(tmp_path):
    got = repl(tmp_path, "x = 1 + 2", "xs = [x, x * 10]", "xs.size + x", '"text"')
    found = answers(got)
    assert got.code == 0, got.stderr
    assert [answer["ok"] for answer in found] == [True] * 4
    assert found[0]["bound"] == {"x": "Int"} and found[1]["bound"] == {"xs": "List[Int]"}
    assert (found[2]["value"], found[2]["type"]) == ("5", "Int")
    assert (found[3]["value"], found[3]["type"]) == ('"text"', "String")
    assert [answer["line"] for answer in found] == [1, 2, 3, 4]


def test_an_effect_runs_once(tmp_path):
    got = repl(tmp_path, 'puts("once")', "n = 1", "n + 1")
    assert got.stderr.count("once") == 1
    assert answers(got)[2]["value"] == "2"


def test_a_redefined_function_is_what_an_earlier_caller_calls(tmp_path):
    got = repl(tmp_path, "def f() -> Int = 1", "def g() -> Int = f() + 1", "g()", "def f() -> Int = 10", "g()")
    found = answers(got)
    assert found[0]["declared"] == ["f"]
    assert (found[2]["value"], found[4]["value"]) == ("2", "11")


def test_a_redefined_struct_drops_the_names_of_its_old_shape(tmp_path):
    got = repl(tmp_path, "struct P\n  a: Int\nend", "p = P(a: 1)", "n = 2",
               "struct P\n  a: Int\n  b: Int\nend", "p", "P(a: n, b: 3)")
    found = answers(got)
    assert found[3]["dropped"] == ["p"]
    assert code(found[4]) == "CHECK-UNKNOWN-NAME"
    assert found[5]["value"] == "P(a: 2, b: 3)"


def test_a_task_of_one_entry_sends_to_a_later_one(tmp_path):
    got = repl(tmp_path, "ch: Channel[Int] = Channel.new(4)",
               "t = Task.spawn do\n  Task.sleep(20)\n  ch.send(41, 5000).unwrap!\nend", "ch.recv(5000).unwrap! + 1")
    found = answers(got)
    assert found[1]["bound"] == {"t": "Task[Void]"}
    assert found[2]["value"] == "42"


def test_a_constant_is_built_once_and_can_be_declared_again(tmp_path):
    got = repl(tmp_path, "LIMIT = [1, 2, 3]", "LIMIT.size", "def over() -> Int = LIMIT.size * 10", "LIMIT = [1]",
               "over() + LIMIT.size")
    found = answers(got)
    assert found[1]["value"] == "3"
    assert found[4]["value"] == "11"


def test_a_check_problem_and_a_crash_leave_the_session_as_it_was(tmp_path):
    got = repl(tmp_path, "x = 5", "x = \"text\"", "y = 1 / (x - 5)", "x + 1")
    found = answers(got)
    assert code(found[1]) == "CHECK-TYPE-MISMATCH"
    assert found[1]["diagnostic"]["range"]["start"]["line"] == 2
    assert (found[2]["ok"], code(found[2])) == (False, "RUNTIME-DIVISION-BY-ZERO")
    assert found[2]["diagnostic"]["range"]["start"] == {"line": 3, "column": 7}
    assert found[3]["value"] == "6"


def test_a_name_changes_type_only_with_a_type_written(tmp_path):
    got = repl(tmp_path, "x = 1", 'x: String = "now"', "x")
    found = answers(got)
    assert found[1]["bound"] == {"x": "String"}
    assert (found[2]["value"], found[2]["type"]) == ('"now"', "String")


def test_an_entry_goes_on_while_it_is_open_and_an_empty_line_drops_it(tmp_path):
    got = repl(tmp_path, "def f(n: Int) -> Int", "  n * 2", "end", "f(", "", "f(4)")
    found = answers(got)
    assert found[0]["declared"] == ["f"]
    assert (found[1]["value"], found[1]["line"]) == ("8", 5)


def test_the_commands(tmp_path):
    (tmp_path / "lib.agc").write_text("def helper(n: Int) -> Int = n + 100\n", encoding="utf-8")
    got = repl(tmp_path, "x = 1", ":type [x]", ":load lib.agc", "helper(x)", ":type", ":nope", ":reset", "x",
               ":quit", "x")
    found = answers(got)
    assert got.code == 0
    assert found[1] == {"ok": True, "type": "List[Int]"}
    assert found[3]["value"] == "101"
    assert [code(answer) for answer in found[4:7]] == ["REPL-USAGE", "REPL-UNKNOWN-COMMAND", "CHECK-UNKNOWN-NAME"]
    assert len(found) == 7


def test_the_exit_status(tmp_path):
    assert repl(tmp_path, "System.exit(3)").code == 3
    got = repl(tmp_path, "def f() -> Int")
    assert (got.code, code(answers(got)[0])) == (1, "REPL-INCOMPLETE")


def test_the_plain_form(tmp_path):
    got = repl(tmp_path, "x = 2", "x * 21", 'puts("hi")', "x.nope", json_style=False)
    assert got.stdout == "=> 42 : Int\nhi\n"
    assert "(repl):4:1 error[CHECK-UNKNOWN-METHOD]" in got.stderr
