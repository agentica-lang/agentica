"""`std/analysis` (issue #524): the library answers the questions of `check`, `outline` and `type-at`, and the command
line runs the same code, so the answers are the same bytes. The cases run a driver program (tests/fixtures/analysis/
driver.agc) that calls the library, and the CLI with `--json` on the same files, and compare both streams. The driver is
compiled once for the module (it compiles the core of the front end with it); each case is a run of its bytecode. That
cost bounds the breadth: thirteen questions of the spec tests of `outline` and `type-at` stand for them, not every one."""
import json

import pytest

from tests.agentica_test import ROOT, cli, compile_agc, run, run_vm, vm_environment, write_files
from tests.test_spec_type_at import MODELS, ORDERS, where

DRIVER = "tests/fixtures/analysis/driver.agc"
UTIL = "export def twice(n: Int) -> Int\n  return n * 2\nend\n"
# `twice` is gone, so MAIN no longer checks against this one.
UTIL_RENAMED = "export def doubled(n: Int) -> Int\n  return n * 2\nend\n"
MAIN = 'import Util from "util"\n\ndef run() -> Int\n  return Util.twice(2)\nend\n'
EXTRA = "export def three() -> Int\n  return 3\nend\n"
USES_EXTRA = 'import Extra from "extra"\n\ndef run() -> Int\n  return Extra.three()\nend\n'
PARSE_ERROR = "def broken(\n"
TYPE_ERROR = 'def main() -> Void\n  x: Int = "a"\n  puts(x)\nend\n'
USES_BAD = 'import Bad from "bad_util"\n\ndef run() -> Int\n  return Bad.twice(2)\nend\n'
MISSING_IMPORT = 'import Nowhere from "nowhere"\n\ndef main() -> Void\n  puts("x")\nend\n'


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    work = tmp_path_factory.mktemp("agentica-analysis-")
    return compile_agc(DRIVER, work / "driver.agcb")


@pytest.fixture
def project(tmp_path):
    write_files(tmp_path, {
        "util.agc": UTIL, "main.agc": MAIN, "models.agc": MODELS, "orders.agc": ORDERS, "parse_error.agc": PARSE_ERROR,
        "type_error.agc": TYPE_ERROR, "missing_import.agc": MISSING_IMPORT, "uses_extra.agc": USES_EXTRA,
        "bad_util.agc": "export def twice(n: Int) -> Int\n  return \"a\"\nend\n", "uses_bad.agc": USES_BAD,
    })
    return tmp_path


def library(driver, project, *words, flags=()):
    """The driver's (stdout, stderr) for `words`."""
    result = run_vm(driver, *flags, args=words, cwd=project, env=vm_environment())
    assert result.code == 0, result.stderr
    return result.stdout, result.stderr


def command_line(project, *words, stdin=None):
    result = run(cli() + ["--json", *words], cwd=project, env=vm_environment(), stdin=stdin)
    return result.stdout, result.stderr


def position(file, source, needle, inside=0):
    line, column = where(source, needle, inside)
    return file, str(line), str(column)


def asked(project, command, file, *rest):
    """The command line's answer to the question that the driver asks with the same words."""
    if command == "type-at":
        return command_line(project, command, ":".join([file, *rest]))
    return command_line(project, command, file)


PARITY = [
    ("check", "main.agc"),
    ("check", "type_error.agc"),
    ("check", "parse_error.agc"),
    ("check", "missing_import.agc"),
    ("check", "uses_bad.agc"),
    ("outline", "models.agc"),
    ("outline", "orders.agc"),
    ("outline", "parse_error.agc"),
    ("type-at", *position("orders.agc", ORDERS, "user.age", 5)),
    ("type-at", *position("orders.agc", ORDERS, "name.upcase", 6)),
    ("type-at", *position("orders.agc", ORDERS, "Models.make", 8)),
    ("type-at", *position("orders.agc", ORDERS, "1\nend")),
    ("type-at", "orders.agc", "1", "1"),
    ("type-at", *position("type_error.agc", TYPE_ERROR, "x: Int")),
]


@pytest.mark.parametrize("question", PARITY, ids=[" ".join(question) for question in PARITY])
def test_the_library_answers_with_the_bytes_the_command_line_prints(driver, project, question):
    command, file, *rest = question
    got = library(driver, project, command, file, *rest)
    expected = asked(project, command, file, *rest)
    assert got == expected
    assert got != ("", "")


def test_an_unreadable_file_or_a_bad_position_is_a_query_usage_diagnostic_in_that_file(driver, project):
    for words in [("outline", "nope.agc"), ("type-at", "nope.agc", "1", "1"), ("type-at", "main.agc", "0", "3")]:
        stdout, stderr = library(driver, project, *words)
        found = json.loads(stderr)
        assert (stdout, found["code"], found["file"]) == ("", "QUERY-USAGE", words[1])
    # `check` does not stop at a missing file: it answers that the program does not pass.
    stdout, stderr = library(driver, project, "check", "nope.agc")
    assert (stdout, json.loads(stderr)["code"]) == ("", "QUERY-USAGE")


def test_a_diagnostic_with_every_note_reads_back_to_the_same_bytes(driver, project):
    every_note = {
        "code": "CHECK-TYPE-MISMATCH", "message": "m", "file": "a.agc", "key_path": "package.name",
        "range": {"start": {"line": 2, "column": 3}, "end": {"line": 2, "column": 9}},
        "expected": "Int", "actual": "String", "callee": "f(n: Int) -> Int", "function": "g() -> Void", "help": "h",
        "labels": [
            {"range": {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 2}}, "text": "this is Int"},
            {"range": {"start": {"line": 4, "column": 5}, "end": {"line": 5, "column": 1}}, "text": "and this"},
        ],
    }
    (project / "note.json").write_text(json.dumps(every_note), encoding="utf-8")
    canonical = json.dumps(every_note, sort_keys=True, separators=(",", ":")) + "\n"
    assert library(driver, project, "diagnostic", "note.json") == (canonical, "")


def test_tasks_ask_one_session_at_once_on_four_schedulers(driver, project):
    files = ["main.agc", "type_error.agc", "parse_error.agc", "missing_import.agc", "main.agc", "type_error.agc"]
    expected = ""
    for file in files:
        out, err = command_line(project, "check", file)
        expected += out or err
    got = library(driver, project, "update", "main.agc", "main.agc", "check-all", *files, flags=("--schedulers", "4"))
    assert got == (expected, "")


def test_a_buffer_gives_the_answers_that_stdin_gives_and_close_gives_the_disk_back(driver, project):
    write_files(project, {"unsaved.agc": TYPE_ERROR})
    stdin_forms = {
        "check": lambda file, rest: ["check", "--stdin", file],
        "outline": lambda file, rest: ["outline", "--stdin", file],
        "type-at": lambda file, rest: ["type-at", "--stdin", ":".join([file, *rest])],
    }
    for question in [("check", "main.agc"), ("outline", "main.agc"), ("type-at", "main.agc", "2", "12")]:
        command, file, *rest = question
        expected = command_line(project, *stdin_forms[command](file, rest), stdin=TYPE_ERROR)
        assert expected != ("", "")
        # The buffer is in the workspace the session opens with, or is put in later: the same answer.
        assert library(driver, project, "buffer", file, "unsaved.agc", *question) == expected
        assert library(driver, project, "update", file, "unsaved.agc", *question) == expected
    # What `update` stored, a later question reads back, and `close` gives the file back to the disk.
    assert library(driver, project, "update", "main.agc", "unsaved.agc", "check", "main.agc")[1] != ""
    closed = library(driver, project, "update", "main.agc", "unsaved.agc", "close", "main.agc", "check", "main.agc")
    assert closed == ('{"ok":true}\n', "")


def test_several_buffers_are_one_program_as_if_the_disk_held_them(driver, project):
    write_files(project, {"util_renamed.agc": UTIL_RENAMED, "util_original.agc": UTIL, "extra_text.agc": EXTRA})
    # The disk holds the old util.agc and has no extra.agc: the buffers are the edit of an imported module and a new one.
    got = library(
        driver, project, "update", "util.agc", "util_renamed.agc", "update", "extra.agc", "extra_text.agc",
        "check", "main.agc", "check", "uses_extra.agc",
    )
    write_files(project, {"util.agc": UTIL_RENAMED, "extra.agc": EXTRA})
    expected = [command_line(project, "check", file) for file in ("main.agc", "uses_extra.agc")]
    assert got == ("".join(out for out, _ in expected), "".join(err for _, err in expected))
    assert json.loads(got[1])["code"].startswith("CHECK-")
    # A later update of one file replaces the buffer, whichever way the file is spelled.
    again = library(driver, project, "update", "util.agc", "util_renamed.agc", "update", "./util.agc", "util_original.agc",
                    "check", "main.agc")
    write_files(project, {"util.agc": UTIL})
    assert again == command_line(project, "check", "main.agc") == ('{"ok":true}\n', "")


def test_outline_and_doc_refuse_the_private_core_as_they_refuse_a_missing_module(project):
    for command in ("outline", "doc"):
        refused = run(cli() + [command, "std/internal/compiler/syntax/ast"], cwd=project, env=vm_environment())
        missing = run(cli() + [command, "std/internal/compiler/syntax/nothing"], cwd=project, env=vm_environment())
        assert (refused.code, refused.stdout) == (missing.code, missing.stdout) != (0, "")
        assert run(cli() + [command, "std/queue"], cwd=project, env=vm_environment()).code == 0


def test_a_run_with_stdlib_reads_the_private_core_from_the_compiler_folder(project):
    """The bootstrap stages read std/ from a folder (`--stdlib`): std/internal/compiler/X is the file compiler/X."""
    uses = 'import Analysis from "std/analysis"\n\ndef main() -> Void\n  puts(Analysis.workspace().version)\nend\n'
    write_files(project, {"uses.agc": uses})
    stage = [str(ROOT / "compiler/modules/link.agc"), "--stdlib=" + str(ROOT / "stdlib"), "--ids", "uses.agc"]
    linked = run(cli() + stage, cwd=project, env=vm_environment())
    assert (linked.code, linked.stderr) == (0, "")
    modules = [line.split('"')[1] for line in linked.stdout.splitlines() if line.startswith("module ")]
    names = (ROOT / "stdlib" / "CORE").read_text(encoding="utf-8").split()
    assert modules[:2] == ["uses.agc", "std/analysis.agc"]
    core = [name for name in modules if name.startswith("std/internal/compiler/")]
    assert sorted(core) == sorted("std/internal/compiler/" + name for name in names)
