"""`agentica repl` through the product CLI, with piped input: the names, declarations and tasks that live across
entries, redefinition, the problems that leave the session as it was, the commands and the exit statuses. The cases
read the `--json` answers (one object per entry or command) and assert values, types, codes and lines, never message
text; one case reads the plain form."""
import json
import queue
import statistics
import subprocess
import threading
import time

import pytest

from tests.agentica_test import cli, run

LIB = """\
struct P
  x: Int
end

def make() -> P = P(x: 1)

def secret() -> Secret = Secret(v: 2)

private

struct Secret
  v: Int
end
"""


def repl(tmp_path, *lines, json_style=True):
    words = [*cli(), "repl", "--json"] if json_style else [*cli(), "repl"]
    return run(words, stdin="".join(line + "\n" for line in lines), cwd=tmp_path)


class Interactive:
    """`agentica repl --json` fed one entry at a time; each answer is read within a timeout."""

    def __init__(self, tmp_path):
        self.child = subprocess.Popen([*cli(), "repl", "--json"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      text=True, cwd=tmp_path)
        self.lines = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.child.stdout:
            self.lines.put(line)

    def ask(self, entry):
        self.child.stdin.write(entry + "\n")
        self.child.stdin.flush()
        return json.loads(self.lines.get(timeout=30))

    def close(self):
        try:
            self.child.stdin.close()
        except OSError:
            pass
        return self.child.wait(timeout=60)


def answers(got):
    return [json.loads(line) for line in got.stdout.splitlines()]


def code(answer):
    return answer["diagnostic"]["code"]


def start(answer):
    return answer["diagnostic"]["range"]["start"]


def place(answer):
    found = answer["diagnostic"]["range"]
    return found["start"]["line"], found["start"]["column"], found["end"]["line"], found["end"]["column"]


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
    got = repl(tmp_path, "def f(n: Int) -> Int", "  n * 2", "end", "f(", "", "f(4)", "## doc", "def g() -> Int = 1",
               "g()", "  1 +* 2")
    found = answers(got)
    assert found[0]["declared"] == ["f"]
    assert found[1] == {"entry": 2, "line": 4, "ok": True, "discarded": True}
    assert (found[2]["value"], found[2]["line"]) == ("8", 5)
    assert (found[3]["declared"], found[3]["line"]) == (["g"], 6)
    assert found[4]["value"] == "1"
    assert (code(found[5]), start(found[5])) == ("PARSE-UNEXPECTED-TOKEN", {"line": 9, "column": 6})


def test_the_commands(tmp_path):
    (tmp_path / "lib.agc").write_text("def helper(n: Int) -> Int = n + 100\n", encoding="utf-8")
    got = repl(tmp_path, "x = 1", ":type [x]", ":load lib.agc", "helper(x)", ":type", ":nope", ":help", ":reset", "x",
               ":quit", "x")
    found = answers(got)
    assert got.code == 0
    assert found[1] == {"entry": 2, "line": 2, "ok": True, "type": "List[Int]"}
    assert found[3]["value"] == "101"
    assert [code(answer) for answer in found[4:6]] == ["REPL-USAGE", "REPL-UNKNOWN-COMMAND"]
    assert [place(answer) for answer in found[4:6]] == [(6, 1, 6, 6), (7, 1, 7, 6)]
    assert [item["command"] for item in found[6]["commands"]] == [":type EXPR", ":load FILE", ":reset", ":quit", ":help"]
    assert found[7] == {"entry": 8, "line": 9, "ok": True, "reset": True}
    assert (found[8]["entry"], found[8]["line"], code(found[8])) == (1, 1, "CHECK-UNKNOWN-NAME")
    assert len(found) == 9


def test_load_enters_a_file_with_its_private_part_and_its_imports(tmp_path):
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "lib.agc").write_text(LIB, encoding="utf-8")
    (tmp_path / "sub" / "main.agc").write_text(
        'import L from "lib"\n\ndef twice(n: Int) -> Int = helper(n) * 2\n\nprivate\n\n'
        "def helper(n: Int) -> Int = n + L.make().x\n", encoding="utf-8")
    (tmp_path / "sub" / "bad.agc").write_text('def one() -> Int = 1\n\ndef broken() -> Int = "s"\n', encoding="utf-8")
    got = repl(tmp_path, ":load sub/main.agc", "twice(3)", ":load sub/bad.agc", ":load sub/nope.agc", "one()")
    found = answers(got)
    assert found[0]["declared"] == ["twice", "helper"]
    assert found[1]["value"] == "8"
    assert code(found[2]) == "CHECK-TYPE-MISMATCH"
    assert (found[2]["diagnostic"]["file"], start(found[2])) == ("sub/bad.agc", {"line": 3, "column": 23})
    assert code(found[3]) == "QUERY-USAGE"
    assert code(found[4]) == "CHECK-UNKNOWN-NAME"


def test_an_imported_file_edited_on_disk_is_read_again(tmp_path):
    (tmp_path / "m.agc").write_text("def g() -> Int = 1\n", encoding="utf-8")
    session = Interactive(tmp_path)
    try:
        first = [session.ask('import M from "./m"'), session.ask("M.g()")]
        (tmp_path / "m.agc").write_text("\n\n\n\ndef g() -> Int = 2\n\ndef h() -> Int = g() + 1\n", encoding="utf-8")
        later = [session.ask("M.g()"), session.ask("M.h()"), session.ask("1 + 1")]
    finally:
        assert session.close() == 0
    assert first[1]["value"] == "1", first
    assert [answer.get("value") for answer in later] == ["2", "3", "2"], later


def test_a_type_declared_again_the_same_drops_no_name(tmp_path):
    (tmp_path / "field.agc").write_text("struct P\n  x: Int\nend\n\nputs(p.nope)\n", encoding="utf-8")
    (tmp_path / "retype.agc").write_text("struct P\n  x: Int\nend\n\np = 5\n", encoding="utf-8")
    (tmp_path / "generic.agc").write_text("struct P[T]\n  x: T\nend\n\nputs(p.x)\n", encoding="utf-8")
    got = repl(tmp_path, "struct P\n  x: Int\nend", "p = P(x: 1)", "p = 5", ":load field.agc", ":load retype.agc",
               "p.x", ":load generic.agc", "P(x: 2).x")
    found = answers(got)
    assert [code(answer) for answer in found[2:5]] == ["CHECK-TYPE-MISMATCH", "CHECK-UNKNOWN-FIELD",
                                                       "CHECK-TYPE-MISMATCH"]
    assert found[5]["value"] == "1"
    assert code(found[6]) == "CHECK-UNKNOWN-NAME"
    assert found[7]["value"] == "2"


def test_load_takes_an_import_the_session_has_by_its_file(tmp_path):
    (tmp_path / "lib").mkdir()
    (tmp_path / "sub").mkdir()
    (tmp_path / "lib" / "m.agc").write_text(LIB, encoding="utf-8")
    (tmp_path / "sub" / "s.agc").write_text(
        'import M from "../lib/m"\n\ndef twice() -> Int = M.make().x * 2\n\n'
        "def words() -> String\n  <<~TEXT\n    private\n    two\n  TEXT\nend\n", encoding="utf-8")
    got = repl(tmp_path, 'import M from "./lib/m"', ":load sub/s.agc", "twice() + M.make().x", "words()",
               ":load sub/nope.agc")
    found = answers(got)
    assert found[1]["declared"] == ["twice", "words"]
    assert (found[2]["value"], found[3]["value"]) == ("3", '"private\\ntwo\\n"')
    plain = repl(tmp_path, ":load sub/nope.agc", json_style=False)
    assert "error[QUERY-USAGE]" in plain.stderr and "|" not in plain.stderr and "help" not in plain.stderr


def test_a_session_whose_child_ends_answers_the_entry(tmp_path):
    entries = "x = 1\nwhile true\nend\nx\n"
    got = run([*cli(), "--max-steps", "100000", "repl", "--json"], stdin=entries, cwd=tmp_path)
    found = answers(got)
    assert got.code == 1
    assert (code(found[1]), found[1]["entry"], found[1]["line"]) == ("REPL-SESSION-LOST", 2, 2)
    assert (found[1]["cause"]["code"], found[1]["cause"]["range"]["start"]["line"]) == ("RUNTIME-STEP-LIMIT", 2)
    assert len(found) == 2
    plain = run([*cli(), "--max-steps", "100000", "repl"], stdin=entries, cwd=tmp_path)
    assert plain.code == 1
    assert "error[RUNTIME-STEP-LIMIT]" in plain.stderr and "error[REPL-SESSION-LOST]" in plain.stderr
    for text in (got.stdout + got.stderr, plain.stdout + plain.stderr):
        assert "repl_entry" not in text and "serve" not in text


def test_an_entry_takes_the_names_it_names(tmp_path):
    got = repl(tmp_path, "n = 1", 's = "a"', "if true\n  n += 1\nend", '"#{s}-#{n}"', "f = ->(k: Int) { k + n }",
               "[1].map(f).first", "def g() -> Int = 3", "n")
    found = answers(got)
    assert [answer["ok"] for answer in found] == [True] * 8
    assert (found[3]["value"], found[5]["value"], found[7]["value"]) == ('"a-2"', "3", "2")


def test_names_the_session_writes_are_refused(tmp_path):
    got = repl(tmp_path, "repl_shown_ = 1", "[1,\n  ReplEntry3]", "def repl_entry_1() -> Int = 1")
    found = answers(got)
    assert [code(answer) for answer in found] == ["REPL-RESERVED-NAME"] * 3
    assert [place(answer) for answer in found] == [(1, 1, 1, 12), (3, 3, 3, 13), (4, 5, 4, 17)]


def test_every_answer_has_its_entry_and_line_and_hides_the_code_around_the_entry(tmp_path):
    (tmp_path / "run.agc").write_text("z = 2\nxs[9]\n", encoding="utf-8")
    got = repl(tmp_path, "xs = [1]", "xs[5]", ":load run.agc", "def f(n: Int) -> Int = n / 0", "f(1)",
               "Task.cancel(Task.current)", "z")
    found = answers(got)
    assert [(answer["entry"], answer["line"]) for answer in found] == [(1, 1), (2, 2), (3, 3), (4, 6), (5, 7), (6, 8),
                                                                       (7, 9)]
    assert (found[2]["ok"], found[2]["bound"], code(found[2])) == (False, {}, "RUNTIME-INDEX-OUT-OF-RANGE")
    assert [frame["function"] for frame in found[4]["diagnostic"]["stack"]] == ["f"]
    assert (code(found[5]), code(found[6])) == ("RUNTIME-TASK-CANCELLED", "CHECK-UNKNOWN-NAME")
    assert "repl_entry" not in got.stdout and "serve" not in got.stdout
    plain = repl(tmp_path, "xs = [1]", "xs[5]", "def f(n: Int) -> Int = n / 0", "f(1)", "f(", json_style=False)
    assert "repl_entry" not in plain.stderr and "serve" not in plain.stderr
    assert "f at (repl):3:" in plain.stderr


def test_a_type_declared_again_drops_every_name_that_holds_it(tmp_path):
    got = repl(tmp_path, "struct P\n  x: Int\nend", "struct Q\n  p: P\nend", "enum E\n  A\nend",
               "struct S\n  e: E\nend", "q = Q(p: P(x: 7))", "s = S(e: E.A)", "n = 1", "struct  P\n  x:   Int\nend",
               "struct P\n  s: String\n  x: Int\nend", "enum E\n  A\n  B\nend", "q", 'Q(p: P(s: "a", x: n)).p.x',
               "S(e: E.B)")
    found = answers(got)
    assert [answer["dropped"] for answer in found[7:10]] == [[], ["q"], ["s"]]
    assert code(found[10]) == "CHECK-UNKNOWN-NAME"
    assert (found[11]["value"], found[12]["value"]) == ("1", "S(e: E.B)")


def test_a_type_of_an_imported_file_is_its_own(tmp_path):
    (tmp_path / "lib.agc").write_text(LIB, encoding="utf-8")
    got = repl(tmp_path, 'import M from "lib"', "a = M.make()", "struct P\n  y: String\nend", "a.x",
               "b = M.secret()", "M.secret()", "b")
    found = answers(got)
    assert found[2]["dropped"] == []
    assert found[3]["value"] == "1"
    assert (found[4]["ok"], found[4]["bound"], found[4]["skipped"]) == (True, {}, ["b"])
    assert found[5]["value"] == "Secret(v: 2)"
    assert code(found[6]) == "CHECK-UNKNOWN-NAME"


def test_json_decode_builds_the_current_type_of_a_name(tmp_path):
    got = repl(tmp_path, "struct P\n  x: Int\nend", "p = P(x: 1)", 'p == JSON.decode("{\\"x\\": 1}", P).unwrap!',
               "struct P\n  x: Int\n  y: Int = 3\nend", 'JSON.decode("{\\"x\\": 1}", P).unwrap!',
               "struct Box[T]\n  v: T\nend", 'JSON.decode("{\\"v\\": {\\"x\\": 4}}", Box[P]).unwrap!',
               "struct Box[T]\n  w: T\nend", 'JSON.decode("{\\"w\\": 2}", Box[Int]).unwrap!',
               "enum P\n  A\nend")
    found = answers(got)
    assert [found[index]["value"] for index in (2, 4, 6, 8)] == ["true", "P(x: 1, y: 3)", "Box(v: P(x: 4, y: 3))",
                                                                 "Box(w: 2)"]
    assert found[3]["dropped"] == ["p"]
    assert (code(found[9]), start(found[9])) == ("REPL-KIND-CHANGE", {"line": 19, "column": 1})


OLD_TYPES = """\
struct P
  x: Int
end

enum E
  A
  B
end

struct Box[T]
  v: T
end

def p_of(s: String) -> String = JSON.decode(s, P).unwrap!.inspect

def e_of(s: String) -> String = JSON.decode(s, E).unwrap!.inspect

def box_of(s: String) -> String = JSON.decode(s, Box[Int]).unwrap!.inspect
"""

NEW_TYPES = """\
struct P
  x: Int
  label: String = "new"
end

enum E
  A
  B
  C
end

struct Box[T]
  v: T
  w: Int = 7
end

def p_of(s: String) -> String = JSON.decode(s, P).unwrap!.inspect

def e_of(s: String) -> String = JSON.decode(s, E).unwrap!.inspect

def box_of(s: String) -> String = JSON.decode(s, Box[Int]).unwrap!.inspect
"""

DECODES = 'p_of("{\\"x\\": 5}") + " " + e_of("{\\"tag\\": \\"B\\", \\"values\\": []}") + " " + box_of("{\\"v\\": 1}")'


def test_code_of_a_type_declared_again_decodes_the_type_it_was_compiled_with(tmp_path):
    (tmp_path / "old.agc").write_text(OLD_TYPES, encoding="utf-8")
    (tmp_path / "new.agc").write_text(NEW_TYPES, encoding="utf-8")
    got = repl(tmp_path, ":load old.agc", "ch: Channel[Int] = Channel.new(1)",
               f"t = Task.spawn do\n  ch.recv(10000).unwrap!\n  {DECODES}\nend", ":load new.agc",
               "ch.send(1, 10000).unwrap!", "Task.await(t)", DECODES, "JSON.schema(P).to_s.include?(\"label\")")
    found = answers(got)
    assert got.code == 0, got.stderr
    assert [answer["ok"] for answer in found] == [True] * 8
    assert found[5]["value"] == '"P(x: 5) E.B Box(v: 1)"'
    assert found[6]["value"] == '"P(x: 5, label: \\"new\\") E.B Box(v: 1, w: 7)"'
    assert found[7]["value"] == "true"


# The same declarations and steps as a session and as one file: each value the session shows is the line the file
# prints for it.
DECLARATIONS = [
    "struct Item\n  name: String\n  tags: List[String] = []\nend",
    "enum Shape\n  Circle(Float)\n  Square(Float)\nend",
    "def area(shape: Shape) -> Float\n  case shape\n    Shape.Circle(r) -> 3.0 * r * r\n"
    "    Shape.Square(a) -> a * a\n  end\nend",
]
STEPS = [
    ("items", '[Item(name: "a"), Item(name: "b", tags: ["x"])]'),
    (None, "items.map { |item| item.name }"),
    (None, "items[1]"),
    ("total", "area(Shape.Square(2.0)) + area(Shape.Circle(1.0))"),
    (None, "total * 2.0"),
    (None, 'items[0] == JSON.decode("{\\"name\\": \\"a\\"}", Item).unwrap!'),
    (None, '{"k": items.size}'),
    (None, '"#{items[0].name}-#{total}"'),
]


def test_a_session_gives_the_values_that_one_file_gives(tmp_path):
    lines = [f"{name} = {value}" if name else value for name, value in STEPS]
    found = answers(repl(tmp_path, *DECLARATIONS, *lines))
    shown = [answer["value"] for answer in found[len(DECLARATIONS):] if "value" in answer]
    body = [f"  {name} = {value}" if name else f"  puts(({value}).inspect)" for name, value in STEPS]
    source = tmp_path / "whole.agc"
    source.write_text("\n\n".join(DECLARATIONS) + "\n\ndef main() -> Void\n" + "\n".join(body) + "\nend\n",
                      encoding="utf-8")
    whole = run([*cli(), str(source)], cwd=tmp_path)
    assert whole.code == 0, whole.stderr
    assert shown == whole.stdout.splitlines()
    assert len(shown) == 6


def test_an_exit_between_entries_is_the_answer_of_the_next(tmp_path):
    session = Interactive(tmp_path)
    try:
        assert session.ask("t = Task.spawn do\n  Task.sleep(100)\n  System.exit(5)\nend")["ok"]
        for tries in range(100):
            found = session.ask("1")
            if "exited" in found:
                break
            time.sleep(0.05)
        assert found == {"entry": tries + 2, "exited": 5, "line": tries + 5, "ok": True}
    finally:
        assert session.close() == 5


def test_an_unknown_name_is_checked_with_every_name(tmp_path):
    got = repl(tmp_path, "total = 1", "totl + 1")
    assert '"total"' in answers(got)[1]["diagnostic"]["help"]


def test_a_statement_takes_the_lines_of_its_heredocs(tmp_path):
    (tmp_path / "doc.agc").write_text("w = <<~TEXT\n  three\n  TEXT  \n  four\nTEXT\n", encoding="utf-8")
    got = repl(tmp_path, "t = <<~TEXT\n  one\n  two\nTEXT", "u = [<<~A, <<~B]\n  a\n  b\nA\n  c\n  d\nB",
               ":load doc.agc", "t + u[1] + w")
    found = answers(got)
    assert [answer["ok"] for answer in found] == [True] * 4
    assert (found[1]["line"], found[2]["line"], found[3]["line"]) == (5, 12, 18)
    assert found[3]["value"] == '"one\\ntwo\\nc\\nd\\nthree\\nTEXT  \\nfour\\n"'


def test_the_exit_status(tmp_path):
    got = repl(tmp_path, "x = 1", "System.exit(3)", "x")
    assert got.code == 3
    assert answers(got)[1:] == [{"entry": 2, "exited": 3, "line": 2, "ok": True}]
    quiet = repl(tmp_path, "System.exit(0)", "1", json_style=False)
    assert (quiet.code, quiet.stdout, quiet.stderr) == (0, "", "")
    got = repl(tmp_path, "def f() -> Int")
    assert (got.code, code(answers(got)[0])) == (1, "REPL-INCOMPLETE")


def test_the_plain_form(tmp_path):
    got = repl(tmp_path, "x = 2", "x * 21", 'puts("hi")', "x.nope", json_style=False)
    assert got.stdout == "=> 42 : Int\nhi\n"
    assert "(repl):4:1 error[CHECK-UNKNOWN-METHOD]" in got.stderr


@pytest.mark.slow
def test_the_cost_of_an_entry_does_not_grow_with_the_session(tmp_path):
    # Each entry binds a name: the medians of the first and of the last 50 answers stay close. An entry that compiled
    # and wrote the whole session again took 25 times longer at the end, and one whose child loaded the whole program
    # again twice as long.
    session = Interactive(tmp_path)
    times = []
    try:
        for k in range(800):
            begun = time.perf_counter()
            assert session.ask(f"x{k} = {k}")["ok"]
            times.append(time.perf_counter() - begun)
    finally:
        session.close()
    assert statistics.median(times[-50:]) < 1.6 * statistics.median(times[:50])


def test_a_builtin_record_that_only_a_later_entry_uses_is_built(tmp_path):
    # The VM finds the structs of the Time records again when a later entry grows the program (vm/session.c).
    got = repl(tmp_path, "x = 1", "d = Time.Date.new(2024, 2, 29).unwrap!", "d.day")
    found = answers(got)
    assert got.code == 0, got.stderr
    assert [answer["ok"] for answer in found] == [True] * 3
    assert found[2]["value"] == "29"
