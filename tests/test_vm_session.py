"""The session child of `agentica repl`: `agentica run --session -` and the FrontEnd session builtins (vm/session.c).

The test front end of tests/test_single_binary.py (fixtures/single-binary/front.agc) is the parent: it starts the child
with FrontEnd.spawn_session, writes the first program on its stdin, sends each request line on the parent channel and
prints the answers. The functions of PROGRAM are lowered in the order they are declared, so the entry lines name them
by that number. vm/tests/loader_test.c checks agc_load_session on programs that grow.
"""
import json

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run, scaled, vm_binary, vm_environment

WAIT = scaled(30)
FRONT = FIXTURES / "single-binary" / "front.agc"

PROGRAM = """\
def show() -> List[String]
  ["hello"]
end

def keep() -> List[String]
  ["kept it", "kept"]
end

def read_back(x: String) -> List[String]
  [x + "!"]
end

def crash() -> List[String]
  _ = "x".to_i!
  ["never"]
end

def start() -> List[Task[String]]
  t = Task.spawn do
    Task.sleep(50)
    "from a task"
  end
  [t, t]
end

def finish(t: Task[String]) -> List[String]
  [Task.await(t)]
end

def loud() -> List[String]
  puts("printed")
  IO.flush()
  ["after"]
end

def main() -> Void
  FrontEnd.serve_session()
end
"""
SHOW, KEEP, READ_BACK, CRASH, START, FINISH, LOUD = range(7)

# A function before the others moves every index, so the program does not extend PROGRAM.
SHIFTED = "def first() -> List[String]\n  [\"first\"]\nend\n\n" + PROGRAM


@pytest.fixture(scope="module")
def front(tmp_path_factory):
    return compile_agc(FRONT, tmp_path_factory.mktemp("front") / "front.agcb")


@pytest.fixture
def program(tmp_path):
    source = tmp_path / "session.agc"
    source.write_text(PROGRAM, encoding="utf-8")
    return compile_agc(source, tmp_path / "session.agcb")


def front_end(front, *words, stdin=None):
    return run([str(vm_binary()), "--front-end", str(front), *words], env=vm_environment(), timeout=WAIT,
               stdin=stdin)


def session(front, program, *lines, json_mode=False):
    """The answers of the child to LINES, its exit status line, and the front end's stderr."""
    got = front_end(front, "session", str(vm_binary()), str(program), "json" if json_mode else "plain", *lines)
    assert got.code == 0, got.stderr
    printed = got.stdout.splitlines()
    return [json.loads(line) if line.startswith("{") else line for line in printed], got.stderr


def entry(function, reads="-", writes="-"):
    return "entry %d %s %s" % (function, reads, writes)


def test_entries_keep_their_values_in_the_slots_and_tasks_live_on(front, program):
    answers, err = session(front, program, entry(SHOW), entry(KEEP, writes="0"), entry(READ_BACK, reads="0"),
                           entry(START, writes="1"), entry(FINISH, reads="1"))
    assert answers[:3] == [{"ok": True, "value": "hello"}, {"ok": True, "value": "kept it"},
                           {"ok": True, "value": "kept!"}]
    assert answers[3]["ok"] is True
    assert answers[4:] == [{"ok": True, "value": "from a task"}, "exit 0"]
    assert err == ""


def test_the_output_of_an_entry_comes_before_its_answer(front, program):
    answers, err = session(front, program, entry(LOUD), entry(SHOW))
    assert answers == ["printed", {"ok": True, "value": "after"}, {"ok": True, "value": "hello"}, "exit 0"]
    assert err == ""
    answers, err = session(front, program, entry(LOUD), entry(SHOW), json_mode=True)
    assert answers == [{"ok": True, "value": "after"}, {"ok": True, "value": "hello"}, "exit 0"]
    assert err == "printed\n"


def test_a_crash_is_the_answer_and_the_session_goes_on(front, program):
    answers, err = session(front, program, entry(CRASH), entry(SHOW), json_mode=True)
    crash = answers[0]
    assert crash["ok"] is False
    assert crash["diagnostic"]["code"] == "RUNTIME-INVALID-NUMBER"
    assert crash["diagnostic"]["range"]["start"]["line"] == 14
    assert json.loads(crash["text"])["code"] == "RUNTIME-INVALID-NUMBER"
    assert answers[1:] == [{"ok": True, "value": "hello"}, "exit 0"]
    assert err == ""


def test_bad_requests_are_refused_and_the_session_goes_on(front, program):
    bad = ["hello", "entry 0 - - x", "entry x - -", "entry 0 5 -", "entry 999999 - -", "entry 2 - -", "entry 1 - 0,",
           "entry 1 - 70000", "chunk 0g", "entry 0 - -", "chunk abc", "entry 0 - -"]
    answers, _ = session(front, program, *bad, entry(SHOW))
    refused = answers[:10]
    assert all(a["ok"] is False and "refused" in a for a in refused), refused
    assert answers[10:] == [{"ok": True, "value": "hello"}, "exit 0"]


def test_a_program_that_extends_the_session_loads_and_one_that_does_not_is_refused(front, program, tmp_path):
    shifted = tmp_path / "shifted.agc"
    shifted.write_text(SHIFTED, encoding="utf-8")
    other = compile_agc(shifted, tmp_path / "shifted.agcb")
    junk = tmp_path / "junk.agcb"
    junk.write_bytes(b"AGCB not a program")
    answers, _ = session(front, program, entry(KEEP, writes="0"), "@%s" % program, entry(READ_BACK, reads="0"),
                         "@%s" % other, entry(SHOW), "@%s" % junk, entry(SHOW), entry(SHOW))
    assert answers[:2] == [{"ok": True, "value": "kept it"}, {"ok": True, "value": "kept!"}]
    assert answers[2]["ok"] is False and "session" in answers[2]["refused"]
    assert answers[3]["ok"] is False and "refused" in answers[3]
    assert answers[4:] == [{"ok": True, "value": "hello"}, "exit 0"]


def test_the_front_end_reads_lines_with_gets(front):
    got = front_end(front, "lines", stdin="one\ntwo\n")
    assert (got.code, got.stdout) == (0, "line one\nline two\n"), got.stderr


def test_serve_session_runs_only_in_the_session_child_and_the_session_takes_stdin(program):
    plain = run([str(vm_binary()), "run", "--json", "--", str(program)], env=vm_environment(), timeout=WAIT)
    assert plain.code == 1
    assert json.loads(plain.stderr.splitlines()[-1])["code"] == "RUNTIME-FRONT-END-ONLY"
    for flags in (["--session", "--", str(program)], ["--session", "--coverage", "c.info", "-"]):
        refused = run([str(vm_binary()), "run", *flags], env=vm_environment(), timeout=WAIT, stdin="")
        assert refused.code == 2 and "--session" in refused.stderr, flags
