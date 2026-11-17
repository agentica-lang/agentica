"""The session child of `agentica repl`: `agentica run --session -` and the FrontEnd session builtins (vm/session.c).

The test front end of tests/test_single_binary.py (fixtures/single-binary/front.agc) is the parent: it starts the child
with FrontEnd.spawn_session, writes the first program on its stdin, sends each request line on the parent channel and
prints the answers. The functions of PROGRAM are lowered in the order they are declared, so the entry lines name them
by that number. vm/tests/loader_test.c checks agc_load_session on programs that grow.
"""
import json
import re
import struct
import subprocess

import pytest

from tests.agentica_test import (FIXTURES, ROOT, Pid, compile_agc, kill_process, process_alive, run, scaled, vm_binary,
                                 vm_environment, wait_until)

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

def hang() -> List[String]
  puts(System.pid().to_s)
  IO.flush()
  Task.sleep(600000)
  ["never"]
end

def leave() -> List[String]
  System.exit(4)
  ["never"]
end

def main() -> Void
  FrontEnd.serve_session()
end
"""
SHOW, KEEP, READ_BACK, CRASH, START, FINISH, LOUD, HANG, EXIT = range(9)

# Another whole program, which is not a session file over PROGRAM (one that has only what it adds).
SHIFTED = "def first() -> List[String]\n  [\"first\"]\nend\n\n" + PROGRAM

# Hand-built programs (the layout of vm/loader.c, as vm/tests/loader_test.c writes it): the compiler gives a slot only
# to a constant that main reaches, and its init function runs main, so it cannot write a session's grown program.
HEADER = (ROOT / "vm" / "value.h").read_text(encoding="utf-8")
OPCODES = [name for name in re.findall(r"\bAGC_OP_([A-Z_]+)\b", HEADER) if name != "COUNT"]
OP = {name: number for number, name in enumerate(OPCODES)}
FORMAT = int(re.search(r"#define AGC_FORMAT_VERSION (\d+)", HEADER).group(1))
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
BUILT_MAIN, BUILT_SHOW, BUILT_INIT, BUILT_USE = range(4)


def u32(number):
    return struct.pack("<I", number)


def text(value):
    data = value.encode()
    return u32(len(data)) + data


def built(divisor=None, sets=True):
    """main and show; with DIVISOR, the session file over them, which has only what it adds (vm/loader.c): an init
    function that sets slot 0 to 42 / DIVISOR (unless not SETS), and use, which shows it."""
    void, hello = b"\x00", b"\x06" + text("hello")
    text_added, spans, constants = "session\n", [(0, 1, 1, 1, 8)], [hello, void]
    globals, builtins, entry = 0, 1, BUILT_MAIN
    functions = [
        ("main", 1, [("STEP", 1, 0, 0), ("CALL_BUILTIN", 0, 0, 0), ("CONST", 0, 1, 0), ("RETURN", 0, 0, 0)]),
        ("show", 2, [("STEP", 1, 0, 0), ("CONST", 0, 0, 0), ("LIST", 1, 0, 1), ("RETURN", 1, 0, 0)]),
    ]
    if divisor is not None:
        text_added, spans, globals, builtins, entry = "", [], 1, 0, BUILT_INIT
        constants = [b"\x04" + struct.pack("<q", 42), b"\x04" + struct.pack("<q", divisor)]
        functions = [
            ("init", 2, [("STEP", 1, 0, 0), ("CONST", 0, 2, 0), ("CONST", 1, 3, 0), ("DIV_I", 0, 0, 1),
                         ("GLOBAL_SET" if sets else "MOVE", 0, 0, 0), ("CONST", 0, 1, 0), ("RETURN", 0, 0, 0)]),
            ("use", 2, [("STEP", 1, 0, 0), ("GLOBAL", 0, 0, 0), ("LIST", 1, 0, 1), ("RETURN", 1, 0, 0)]),
        ]
    out = b"AGCB" + u32(FORMAT) + text(VERSION) + u32(1) + text("session.agc") + text(text_added)
    out += u32(len(spans)) + b"".join(struct.pack("<5I", *span) for span in spans)
    out += u32(len(constants)) + b"".join(constants)
    out += u32(0) * 5 + u32(globals)
    out += u32(builtins) + (text("FrontEnd.serve_session") + u32(0)) * builtins
    out += u32(len(functions))
    for name, registers, code in functions:
        out += text(name) + u32(0) + u32(0) + u32(registers) + u32(0) + u32(0) + u32(len(code))
        out += b"".join(struct.pack("<4H", OP[op], a, b, c) for op, a, b, c in code) + u32(0) * len(code)
    return out + u32(entry)


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


def test_a_file_that_is_not_a_session_file_is_refused_and_the_session_goes_on(front, program, tmp_path):
    shifted = tmp_path / "shifted.agc"
    shifted.write_text(SHIFTED, encoding="utf-8")
    other = compile_agc(shifted, tmp_path / "shifted.agcb")
    junk = tmp_path / "junk.agcb"
    junk.write_bytes(b"AGCB not a program")
    answers, _ = session(front, program, entry(KEEP, writes="0"), "@%s" % other, entry(SHOW), "@%s" % junk,
                         entry(SHOW), entry(READ_BACK, reads="0"))
    assert answers[0] == {"ok": True, "value": "kept it"}
    assert answers[1]["ok"] is False and "session" in answers[1]["refused"]
    assert answers[2]["ok"] is False and "refused" in answers[2]
    assert answers[3:] == [{"ok": True, "value": "kept!"}, "exit 0"]


def test_an_init_that_crashes_leaves_its_program_loaded_and_its_slot_failed(front, tmp_path):
    files = {}
    for name, data in (("base", built()), ("good", built(divisor=1)), ("bad", built(divisor=0))):
        files[name] = tmp_path / (name + ".agcb")
        files[name].write_bytes(data)
    answers, err = session(front, files["base"], entry(BUILT_SHOW), "@%s" % files["good"], entry(BUILT_USE))
    assert answers == [{"ok": True, "value": "hello"}, {"loaded": True, "ok": True, "value": "42"}, "exit 0"], err
    answers, err = session(front, files["base"], "@%s" % files["bad"], entry(BUILT_SHOW), entry(BUILT_USE),
                           entry(BUILT_SHOW), json_mode=True)
    crashed, failed = answers[0], answers[1]
    assert (crashed["ok"], crashed["loaded"]) == (False, True)
    assert crashed["diagnostic"]["code"] == "RUNTIME-DIVISION-BY-ZERO"
    assert failed["ok"] is False and "loaded" not in failed
    assert failed["diagnostic"]["code"] == "RUNTIME-NO-VALUE"
    assert answers[2:] == [{"ok": True, "value": "hello"}, "exit 0"]
    assert err == ""


def test_a_slot_that_no_crash_left_unset_is_a_broken_program(front, tmp_path):
    base, unset = tmp_path / "base.agcb", tmp_path / "unset.agcb"
    base.write_bytes(built())
    unset.write_bytes(built(divisor=1, sets=False))
    got = front_end(front, "session", str(vm_binary()), str(base), "json", "@%s" % unset, entry(BUILT_USE))
    printed = got.stdout.splitlines()
    lost = json.loads(printed[0])
    assert (lost["lost"], lost["ok"], lost["diagnostic"]["code"]) == (True, False, "RUNTIME-INTERNAL")
    assert (printed[1:], got.stderr) == (["exit 1"], "")


def test_an_exit_answers_with_its_status(front, program):
    answers, err = session(front, program, entry(EXIT))
    assert (answers, err) == ([{"exited": 4}, "exit 4"], "")


def test_the_child_ends_when_the_front_end_is_killed(front, program):
    words = ["session", str(vm_binary()), str(program), "plain", entry(HANG)]
    parent = subprocess.Popen([str(vm_binary()), "--front-end", str(front), *words], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, env=vm_environment(), text=True)
    child = None
    try:
        child = Pid(parent.stdout.readline().strip())
        assert process_alive(child)
        parent.kill()
        parent.wait(timeout=WAIT)
        assert wait_until(lambda: not process_alive(child), timeout=WAIT)
    finally:
        parent.kill()
        parent.stdout.close()
        if child is not None:
            kill_process(child)


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
    # A session's program is never a source file, so the run names no source file to run instead.
    garbled = run([str(vm_binary()), "run", "--session", "-"], env=vm_environment(), timeout=WAIT, stdin="def main")
    assert garbled.code == 2 and len(garbled.stderr.splitlines()) == 1, garbled.stderr
