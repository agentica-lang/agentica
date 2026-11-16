"""The session child of `agentica repl`: `agentica run --session -` and FrontEnd.serve_session (vm/session.c).

The test is the parent: it writes the first program on the child's stdin and drives the parent channel at
descriptors 3 and 4 (marker "3,4") as the front end does. The functions of PROGRAM are lowered in the order they are
declared, so the entry lines name them by that number. vm/tests/loader_test.c checks agc_load_session on programs
that grow. POSIX only: a Python launcher moves the descriptors to 3 and 4.
"""
import json
import os
import subprocess

import pytest

from tests.agentica_test import FIXTURES, PYTHON, compile_agc, run, scaled, vm_binary, vm_environment

pytestmark = pytest.mark.skipif(os.name != "posix", reason="the test moves the channel to descriptors 3 and 4 (dup2)")

WAIT = scaled(30)
FRONT = FIXTURES / "single-binary" / "front.agc"

# Puts the channel at descriptors 3 and 4 and runs the rest of the arguments.
MOVE = ("import os, sys; os.dup2(int(sys.argv[1]), 3); os.dup2(int(sys.argv[2]), 4); "
        "os.execv(sys.argv[3], sys.argv[3:])")

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


class Child:
    def __init__(self, program, *flags):
        to_child, self.writer = os.pipe()
        self.reader, from_child = os.pipe()
        self.process = subprocess.Popen(
            [PYTHON, "-c", MOVE, str(to_child), str(from_child), str(vm_binary()), "run", "--session", *flags, "-"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(to_child, from_child),
            env=vm_environment({"AGENTICA_CHANNEL": "3,4"}), start_new_session=True)
        os.close(to_child)
        os.close(from_child)
        self.process.stdin.write(program)
        self.process.stdin.close()
        self.answers = os.fdopen(self.reader, "r", encoding="utf-8")
        self.requests = os.fdopen(self.writer, "w", encoding="utf-8")

    def ask(self, line):
        self.requests.write(line + "\n")
        self.requests.flush()
        answer = self.answers.readline()
        assert answer, self.process.stderr.read().decode()
        return json.loads(answer)

    def entry(self, function, reads="-", writes="-"):
        return self.ask("entry %d %s %s" % (function, reads, writes))

    def load(self, program):
        hex_text = program.hex()
        for start in range(0, len(hex_text), 4096):
            self.requests.write("chunk %s\n" % hex_text[start:start + 4096])

    def end(self):
        self.requests.close()
        code = self.process.wait(timeout=WAIT)
        self.answers.close()
        return code, self.process.stdout.read().decode(), self.process.stderr.read().decode()


@pytest.fixture(scope="module")
def front(tmp_path_factory):
    return compile_agc(FRONT, tmp_path_factory.mktemp("front") / "front.agcb")


@pytest.fixture
def program(tmp_path):
    source = tmp_path / "session.agc"
    source.write_text(PROGRAM, encoding="utf-8")
    return compile_agc(source, tmp_path / "session.agcb").read_bytes()


def test_entries_keep_their_values_in_the_slots_and_tasks_live_on(program):
    child = Child(program)
    assert child.entry(SHOW) == {"ok": True, "value": "hello"}
    assert child.entry(KEEP, writes="0") == {"ok": True, "value": "kept it"}
    assert child.entry(READ_BACK, reads="0") == {"ok": True, "value": "kept!"}
    started = child.entry(START, writes="1")
    assert started["ok"] is True
    assert child.entry(FINISH, reads="1") == {"ok": True, "value": "from a task"}
    assert child.entry(LOUD) == {"ok": True, "value": "after"}
    assert child.end() == (0, "printed\n", "")


def test_a_crash_is_the_answer_and_the_session_goes_on(program):
    child = Child(program, "--json")
    answer = child.entry(CRASH)
    assert answer["ok"] is False
    assert answer["diagnostic"]["code"] == "RUNTIME-INVALID-NUMBER"
    assert answer["diagnostic"]["range"]["start"]["line"] == 14
    assert json.loads(answer["text"])["code"] == "RUNTIME-INVALID-NUMBER"
    assert child.entry(SHOW) == {"ok": True, "value": "hello"}
    assert child.end() == (0, "", "")


def test_bad_requests_are_refused_and_the_session_goes_on(program):
    child = Child(program)
    for line in ["hello", "entry 0 - - x", "entry x - -", "entry 0 5 -", "entry 999999 - -", "entry 2 - -",
                 "entry 1 - 0,", "chunk 0g\nentry 0 - -", "chunk abc\nentry 0 - -"]:
        answer = child.ask(line)
        assert answer["ok"] is False and "refused" in answer, line
    assert child.entry(SHOW) == {"ok": True, "value": "hello"}
    assert child.end()[0] == 0


def test_a_program_that_extends_the_session_loads_and_one_that_does_not_is_refused(program, tmp_path):
    shifted = tmp_path / "shifted.agc"
    shifted.write_text(SHIFTED, encoding="utf-8")
    other = compile_agc(shifted, tmp_path / "shifted.agcb").read_bytes()
    child = Child(program)
    assert child.entry(KEEP, writes="0") == {"ok": True, "value": "kept it"}
    child.load(program)
    assert child.entry(READ_BACK, reads="0") == {"ok": True, "value": "kept!"}
    child.load(other)
    refused = child.entry(SHOW)
    assert refused["ok"] is False and "session" in refused["refused"]
    child.load(b"AGCB not a program")
    assert child.entry(SHOW)["ok"] is False
    assert child.entry(SHOW) == {"ok": True, "value": "hello"}
    assert child.end()[0] == 0


def front_end(bytecode, *words, stdin=None):
    """The test front end of tests/test_single_binary.py (fixtures/single-binary/front.agc), run with WORDS."""
    return run([str(vm_binary()), "--front-end", str(bytecode), *words], env=vm_environment(), timeout=WAIT,
               stdin=stdin)


def test_the_front_end_starts_the_child_and_its_output_comes_before_the_answer(front, program, tmp_path):
    bytecode = tmp_path / "session.agcb"
    lines = ["entry %d - -" % LOUD, "entry %d - -" % SHOW]
    plain = front_end(front, "session", str(vm_binary()), str(bytecode), "plain", *lines)
    assert plain.code == 0, plain.stderr
    assert plain.stdout.splitlines() == ["printed", '{"ok":true,"value":"after"}', '{"ok":true,"value":"hello"}',
                                         "exit 0"]
    json_mode = front_end(front, "session", str(vm_binary()), str(bytecode), "json", *lines)
    assert json_mode.code == 0, json_mode.stderr
    assert json_mode.stdout.splitlines() == ['{"ok":true,"value":"after"}', '{"ok":true,"value":"hello"}', "exit 0"]
    assert json_mode.stderr == "printed\n"


def test_the_front_end_reads_lines_with_gets(front):
    got = front_end(front, "lines", stdin="one\ntwo\n")
    assert (got.code, got.stdout) == (0, "line one\nline two\n"), got.stderr


def test_serve_session_runs_only_in_the_session_child_and_the_session_takes_stdin(program, tmp_path):
    bytecode = tmp_path / "session.agcb"
    plain = run([str(vm_binary()), "run", "--json", "--", str(bytecode)], env=vm_environment(), timeout=WAIT)
    assert plain.code == 1
    assert json.loads(plain.stderr.splitlines()[-1])["code"] == "RUNTIME-FRONT-END-ONLY"
    for flags in (["--session", "--", str(bytecode)], ["--session", "--coverage", "c.info", "-"]):
        refused = run([str(vm_binary()), "run", *flags], env=vm_environment(), timeout=WAIT, stdin="")
        assert refused.code == 2 and "--session" in refused.stderr, flags
