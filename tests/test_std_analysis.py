"""`std/analysis` (issue #524): the library answers the questions of `check`, `outline`, `type-at`, `symbol` and `refs`,
and the command line runs the same code, so the answers are the same bytes. The cases run a driver program (tests/
fixtures/analysis/driver.agc) that calls the library, and the CLI with `--json` on the same files, and compare both
streams. The driver is compiled once for the module (it compiles the core of the front end with it); each case is a run
of its bytecode. That cost bounds the breadth: a few questions of the spec tests of each command stand for them."""
import json
import shutil
from pathlib import Path

import pytest

from tests.agentica_test import ROOT, cli, compile_agc, run, run_vm, vm_environment, write_files
from tests.test_spec_partial import APP, BAD_DECLARATIONS, FIXED, MODELS as PARTIAL_MODELS
from tests.test_spec_type_at import MODELS, ORDERS, where

DRIVER = "tests/fixtures/analysis/driver.agc"
UTIL = "export def twice(n: Int) -> Int\n  return n * 2\nend\n"
# `twice` is gone, so MAIN no longer checks against this one.
UTIL_RENAMED = "export def doubled(n: Int) -> Int\n  return n * 2\nend\n"
MAIN = 'import Util from "util"\n\ndef run() -> Int\n  return Util.twice(2)\nend\n'
# Another body for `twice`: the same exports, another text.
UTIL_CHANGED = "export def twice(n: Int) -> Int\n  return n + n\nend\n"
EXTRA = "export def three() -> Int\n  return 3\nend\n"
USES_EXTRA = 'import Extra from "extra"\n\ndef run() -> Int\n  return Extra.three()\nend\n'
PARSE_ERROR = "def broken(\n"
TYPE_ERROR = 'def main() -> Void\n  x: Int = "a"\n  puts(x)\nend\n'
USES_BAD = 'import Bad from "bad_util"\n\ndef run() -> Int\n  return Bad.twice(2)\nend\n'
# Errors whose diagnostic carries what a round trip may lose: two labels, quotes in the help and a backslash; and a
# quote with a character outside ASCII in the message.
LABELLED = 'def main() -> Void\n  puts("tab\\there \\\\")\n  puts(1 + "a")\nend\n'
NON_ASCII = 'def main() -> Void\n  puts(\u00f1and\u00fa)\nend\n'
# Unsaved text that `symbol` and `refs` read in place of (or beside) the disk: a module the disk lacks, and a main.agc
# that calls `twice` twice.
FRESH = "export def fresh(n: Int) -> Int\n  return n\nend\n"
TWICE_TWICE = 'import Util from "util"\n\ndef run() -> Int\n  return Util.twice(2) + Util.twice(3)\nend\n'
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
    if command in ("type-at", "refs"):
        return command_line(project, command, ":".join([file, *rest]))
    if command == "symbol":
        return command_line(project, command, file, *rest)
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
    ("type-at", *position("orders.agc", ORDERS, "Models.User) -> Int", 2)),
    ("type-at", *position("orders.agc", ORDERS, "List[String]", 1)),
    ("type-at", "orders.agc", "1", "1"),
    ("type-at", *position("type_error.agc", TYPE_ERROR, "x: Int")),
    ("symbol", "make", "models.agc", "orders.agc"),
    ("symbol", "User", "models.agc"),
    ("symbol", "twice"),
    ("symbol", "make", "models.agc", "parse_error.agc"),
    ("symbol", "nothing", "models.agc"),
    ("symbol", "File.read", "models.agc"),
    ("refs", *position("orders.agc", ORDERS, "Models.make", 8)),
    ("refs", *position("orders.agc", ORDERS, "user.age", 5)),
    ("refs", "orders.agc", "1", "1"),
    ("refs", "parse_error.agc", "1", "1"),
]


@pytest.mark.parametrize("question", PARITY, ids=[" ".join(question) for question in PARITY])
def test_the_library_answers_with_the_bytes_the_command_line_prints(driver, project, question):
    command, file, *rest = question
    got = library(driver, project, command, file, *rest)
    expected = asked(project, command, file, *rest)
    assert got == expected
    assert got != ("", "")


def test_an_unreadable_file_or_a_bad_position_is_a_query_usage_diagnostic_in_that_file(driver, project):
    bad = [("outline", "nope.agc"), ("type-at", "nope.agc", "1", "1"), ("type-at", "main.agc", "0", "3")]
    bad += [("refs", "nope.agc", "1", "1"), ("refs", "main.agc", "3", "0")]
    for words in bad:
        stdout, stderr = library(driver, project, *words)
        found = json.loads(stderr)
        assert (stdout, found["code"], found["file"]) == ("", "QUERY-USAGE", words[1])
    # A symbol query with a bad name or path names no file, and the library gives no usage help.
    for words in [("symbol", "make", "nope.agc"), ("symbol", "", "models.agc")]:
        stdout, stderr = library(driver, project, *words)
        assert (stdout, json.loads(stderr)["code"], json.loads(stderr)["file"]) == ("", "QUERY-USAGE", "<arguments>")
    # `check` does not stop at a missing file: it answers that the program does not pass.
    stdout, stderr = library(driver, project, "check", "nope.agc")
    assert (stdout, json.loads(stderr)["code"]) == ("", "QUERY-USAGE")


def test_a_diagnostic_with_every_note_reads_back_to_the_same_bytes(driver, project):
    every_note = {
        "code": "CHECK-TYPE-MISMATCH", "message": "quote \" backslash \\ newline \n \u00f1", "file": "a.agc",
        "key_path": "package.name",
        "range": {"start": {"line": 2, "column": 3}, "end": {"line": 2, "column": 9}},
        "expected": "Int", "actual": "String", "callee": "f(n: Int) -> Int", "function": "g() -> Void", "help": "h",
        "labels": [
            {"range": {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 2}}, "text": "this is Int"},
            {"range": {"start": {"line": 4, "column": 5}, "end": {"line": 5, "column": 1}}, "text": "and this"},
        ],
    }
    (project / "note.json").write_text(json.dumps(every_note), encoding="utf-8")
    canonical = json.dumps(every_note, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
    assert library(driver, project, "diagnostic", "note.json") == (canonical, "")


ROUND_TRIPS = [("labelled.agc", LABELLED, '"labels":['), ("non_ascii.agc", NON_ASCII, "\u00f1")]


@pytest.mark.parametrize("name, text, note", ROUND_TRIPS, ids=[name for name, _text, _note in ROUND_TRIPS])
def test_a_diagnostic_of_check_written_as_json_and_read_again_is_the_same_value(driver, project, name, text, note):
    """struct -> JSON -> struct: the other direction of the test above, on a diagnostic that `check` returned."""
    write_files(project, {name: text})
    assert note in command_line(project, "check", name)[1]
    assert library(driver, project, "roundtrip", name) == ("true\n", "")


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


def test_symbol_and_refs_read_the_buffers_as_stdin_does(driver, project):
    (project / "fresh.agc").write_text(FRESH, encoding="utf-8")
    (project / "twice_twice.agc").write_text(TWICE_TWICE, encoding="utf-8")
    # A buffer of a module the disk lacks is searched first, with the paths or with `.`.
    for paths in [("models.agc",), ()]:
        expected = command_line(project, "symbol", "fresh", *paths, "--stdin", "fresh_buffer.agc", stdin=FRESH)
        assert json.loads(expected[0])["matches"][0]["module"] == "fresh_buffer.agc"
        got = library(driver, project, "buffer", "fresh_buffer.agc", "fresh.agc", "symbol", "fresh", *paths)
        assert got == expected
        later = library(driver, project, "update", "fresh_buffer.agc", "fresh.agc", "symbol", "fresh", *paths)
        assert later == expected
    # A position of an unsaved file: the buffer is the file whose imports are followed.
    file, line, column = position("main.agc", TWICE_TWICE, "Util.twice", 5)
    expected = command_line(project, "refs", "--stdin", f"{file}:{line}:{column}", stdin=TWICE_TWICE)
    assert len(json.loads(expected[0])["references"]) == 2
    assert library(driver, project, "buffer", file, "twice_twice.agc", "refs", file, line, column) == expected
    # `close` gives the disk back, which has one call of `twice`.
    closed = library(driver, project, "update", file, "twice_twice.agc", "close", file, "refs", file, line, column)
    assert closed == command_line(project, "refs", f"{file}:{line}:{column}")
    assert closed != expected


def test_symbol_searches_the_buffers_in_the_order_of_their_paths_not_of_their_updates(driver, project):
    (project / "dup.agc").write_text("export def dup() -> Int\n  return 1\nend\n", encoding="utf-8")
    first = ("buffer", "a.agc", "dup.agc", "buffer", "b.agc", "dup.agc")
    before = library(driver, project, *first, "symbol", "dup", "models.agc")
    modules = [found["module"] for found in json.loads(before[0])["matches"]]
    assert modules == ["a.agc", "b.agc"]
    # `update` of the first buffer must not move it behind the second, and the order the buffers were opened in is not
    # the order of the answer either.
    assert library(driver, project, *first, "update", "a.agc", "dup.agc", "symbol", "dup", "models.agc") == before
    swapped = ("buffer", "b.agc", "dup.agc", "buffer", "a.agc", "dup.agc")
    assert library(driver, project, *swapped, "symbol", "dup", "models.agc") == before
    # A folder that only buffers make (the disk has no newdir) is not listed.
    stdout, stderr = library(driver, project, "buffer", "newdir/new.agc", "dup.agc", "symbol", "dup", "newdir")
    assert (stdout, json.loads(stderr)["code"]) == ("", "QUERY-USAGE")


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


def test_a_std_module_of_a_stdlib_folder_may_not_leave_std_with_dots(project):
    """`..` in a relative import of a std module is allowed only while the path stays in std/ (Paths.inside_std)."""
    stdlib = project / "lib"
    stdlib.mkdir()
    write_files(stdlib, {"a.agc": 'import X from "../x"\n\nexport def f() -> Int\n  return 1\nend\n'})
    write_files(project, {"uses.agc": 'import A from "std/a"\n\ndef main() -> Void\nend\n'})
    stage = [str(ROOT / "compiler/modules/link.agc"), "--stdlib=" + str(stdlib), "--ids", "uses.agc"]
    linked = run(cli() + stage, cwd=project, env=vm_environment())
    assert (linked.code, linked.stderr) == (0, "")
    assert 'ERROR CHECK-IMPORT-PATH 0:1:1-21:2:1 "invalid library path" - file="std/a.agc"' in linked.stdout


def stats_of(stdout):
    """The `stats` lines of a driver run, as dicts of ints."""
    return [
        {key: int(value) for key, value in (pair.split("=") for pair in line.split())}
        for line in stdout.splitlines() if line.startswith("roots=")
    ]


def counted(stdout, *keys):
    """For each `stats` line, the values of `keys`."""
    return [tuple(line[key] for key in keys) for line in stats_of(stdout)]


REFRESHED = [
    ("check", "main.agc"),
    ("check", "type_error.agc"),
    ("check", "parse_error.agc"),
    ("check", "missing_import.agc"),
    ("check", "uses_bad.agc"),
    ("type-at", *position("orders.agc", ORDERS, "user.age", 5)),
    ("type-at", *position("orders.agc", ORDERS, "Models.make", 8)),
]


@pytest.mark.parametrize("question", REFRESHED, ids=[" ".join(question) for question in REFRESHED])
def test_a_refresh_before_a_question_gives_the_answer_without_it_and_the_command_lines(driver, project, question):
    """A file that does not link (a parse error, a missing import) leaves the cache as it was; the question says why."""
    command, file, *rest = question
    got = library(driver, project, "refresh", file, command, file, *rest)
    assert got == asked(project, command, file, *rest)
    assert got == library(driver, project, command, file, *rest) != ("", "")


def test_symbol_and_refs_after_a_refresh_give_the_answers_of_the_command_line(driver, project):
    where_make = position("orders.agc", ORDERS, "Models.make", 8)
    got = library(driver, project, "refresh", "orders.agc", "refresh", "models.agc", "refs", *where_make)
    assert got == command_line(project, "refs", ":".join(where_make)) != ("", "")
    got = library(driver, project, "refresh", "orders.agc", "refresh", "models.agc", "symbol", "make", "models.agc", "orders.agc")
    assert got == command_line(project, "symbol", "make", "models.agc", "orders.agc") != ("", "")


def test_a_buffer_edit_and_a_close_check_a_root_again_and_a_root_that_does_not_reach_the_file_keeps_its_check(
    driver, project,
):
    write_files(project, {"util_changed.agc": UTIL_CHANGED})
    out, err = library(
        driver, project,
        "refresh", "main.agc", "stats",
        "refresh", "main.agc", "stats",
        "refresh", "models.agc", "stats",
        "update", "util.agc", "util_changed.agc", "refresh", "models.agc", "stats",
        "refresh", "main.agc", "stats",
        "close", "util.agc", "refresh", "main.agc", "stats",
        "refresh", "main.agc", "check", "main.agc",
    )
    assert (err, out.splitlines()[-1]) == ("", '{"ok":true}')
    # main.agc and util.agc are two files; models.agc is one. A second refresh walks and reuses everything; the buffer
    # of util.agc is one parse and one check again, and so is its close, with main.agc itself never parsed again.
    expected = [(1, 1, 2), (1, 1, 2), (2, 2, 3), (2, 2, 3), (2, 3, 4), (2, 4, 5)]
    assert counted(out, "roots", "checks", "parsed") == expected


def test_a_disk_edit_a_new_file_and_a_removed_file_are_seen_by_the_next_refresh_and_question(driver, project):
    write_files(project, {"util_changed.agc": UTIL_CHANGED, "extra_text.agc": EXTRA})
    out, err = library(
        driver, project,
        "refresh", "main.agc", "stats",
        "write", "util.agc", "util_changed.agc", "refresh", "main.agc", "stats",
        "refresh", "uses_extra.agc", "stats",
        "write", "extra.agc", "extra_text.agc", "refresh", "uses_extra.agc", "stats",
        "remove", "extra.agc", "check", "uses_extra.agc", "compare", "uses_extra.agc",
    )
    # The edit of util.agc is one parse and one check. uses_extra.agc has no extra.agc yet: the walk fails and the cache
    # stays as it was; once the file exists it is two parses and one check.
    assert counted(out, "roots", "checks", "parsed") == [(1, 1, 2), (1, 2, 3), (1, 2, 3), (2, 3, 5)]
    # The cached root of uses_extra.agc is not used once extra.agc is gone: the question reads the files again.
    assert json.loads(err)["code"] == "CHECK-IMPORT-IO"
    assert out.splitlines()[-1] == "same 0"


def test_a_manifest_that_appears_is_seen_by_the_next_question_though_the_root_is_cached(driver, project):
    write_files(project, {"bad.toml": 'name = "x"\n[dependencies\n'})
    out, err = library(
        driver, project, "refresh", "main.agc", "write", "agentica.toml", "bad.toml", "check", "main.agc", "stats",
        "compare", "main.agc",
    )
    assert json.loads(err)["code"] == "PKG-MANIFEST-INVALID"
    assert out.splitlines()[-1] == "same 0"
    assert counted(out, "roots", "checks") == [(1, 1)]


def test_two_spellings_of_one_file_keep_their_own_name_in_a_cached_diagnostic(driver, project):
    """real.agc and its link have one key; a root cached under one spelling must not answer for the other."""
    (project / "link.agc").symlink_to(project / "type_error.agc")
    for first, second in [("link.agc", "type_error.agc"), ("type_error.agc", "link.agc")]:
        cached = library(driver, project, "refresh", first, "check", second)
        assert cached == library(driver, project, "check", second) == command_line(project, "check", second)
        assert json.loads(cached[1])["file"] != ""


def test_at_most_sixteen_roots_are_kept_the_least_recently_refreshed_leaving_first(driver, project):
    names = [f"r{number}.agc" for number in range(18)]
    write_files(project, {name: f"def f{at}() -> Int\n  return {at}\nend\n" for at, name in enumerate(names)})
    words = [word for name in names for word in ("refresh", name)] + ["stats"]
    # r17 is the latest, so it stays; r0 left long ago and is checked again, which pushes r2 out; r2 is checked again.
    for name in ["r17.agc", "r0.agc", "r2.agc", "r17.agc"]:
        words += ["refresh", name, "stats"]
    out, err = library(driver, project, *words)
    assert err == ""
    # The parsed files are the sixteen of the roots kept.
    expected = [(16, 18, 16), (16, 18, 16), (16, 19, 16), (16, 20, 16), (16, 20, 16)]
    assert counted(out, "roots", "checks", "kept") == expected


def positions(source, *needles):
    return [str(number) for needle, inside in needles for number in where(source, needle, inside)]


def test_cached_answers_equal_uncached_answers_when_the_modules_move_in_the_id_space(driver, project):
    """Every edit of a buffer gives its file new ids above the others, so the files leave their order of ids; the
    answers must not notice, and the ids are numbered again from 0 when the gaps pass half of them."""
    extra = "\nexport def extra() -> Int\n  return 1\nend\n"
    write_files(project, {"models_a.agc": "# one\n" + MODELS, "models_b.agc": MODELS + extra})
    words = ["refresh", "orders.agc", "stats"]
    for text in ["models_a.agc", "models_b.agc"] * 5:
        words += ["update", "models.agc", text, "refresh", "orders.agc", "stats"]
    asked_at = positions(
        ORDERS, ("user.age", 5), ("name.upcase", 6), ("Models.make", 8), ("1\nend", 0), ("Queue.new", 7),
        ("LIMIT. to_s", 2),
    )
    out, err = library(driver, project, *words, "compare", "orders.agc", *asked_at)
    assert (err, out.splitlines()[-1]) == ("", "same 6")
    lines = stats_of(out)
    # A program that checks again each time: one check for each refresh. The three files are parsed once, then models.agc
    # for each edit, and all three again when the ids pass twice the live ones.
    assert [line["checks"] for line in lines] == list(range(1, 12))
    assert lines[-1]["parsed"] > 3 + 10
    assert all(line["top"] <= 2 * line["live"] for line in lines)
    tops = [line["top"] for line in lines]
    assert any(after < before for before, after in zip(tops, tops[1:])), tops
    assert tops != sorted(tops)


# Three modules in a chain: REPORT imports SIZES, which imports SHAPES. SIZES has a constant read with a method, whose
# receiver gets an id past the ids of the parser.
SHAPES = "export def scale(n: Int) -> Int\n  return n * 2\nend\n"
SIZES = 'import Shapes from "shapes"\n\nLIMIT = 5\n\nexport def area(n: Int) -> Int\n  return Shapes.scale(n) + LIMIT.to_s.length\nend\n'
REPORT = 'import Sizes from "sizes"\n\ndef report() -> Int\n  return Sizes.area(3)\nend\n'
# `scale` takes another argument: SIZES, whose text did not change, no longer checks.
SHAPES_WIDER = "export def scale(n: Int, by: Int) -> Int\n  return n * by\nend\n"


def test_a_refresh_after_an_edit_checks_only_the_modules_that_changed_or_import_one_and_answers_as_a_cold_check(
    driver, project,
):
    """The modules that did not change, with all they import, are not checked again; the others are, so an edit of
    an imported module still changes the diagnostic of the module that uses it."""
    edited = "# An edit.\n" + REPORT
    write_files(project, {
        "shapes.agc": SHAPES, "sizes.agc": SIZES, "report.agc": REPORT, "report_edit.agc": edited,
        "sizes_edit.agc": "# An edit.\n" + SIZES, "shapes_wider.agc": SHAPES_WIDER,
    })
    asked_at = positions(edited, ("Sizes.area", 6), ("(3)", 1))
    out, err = library(
        driver, project,
        "refresh", "report.agc", "stats",
        # Only the root changed: the two modules under it are taken.
        "update", "report.agc", "report_edit.agc", "refresh", "report.agc", "stats",
        # A module in the middle: the root imports it, so only SHAPES is taken.
        "update", "sizes.agc", "sizes_edit.agc", "refresh", "report.agc", "stats",
        # The leaf: every module imports it, directly or not, so none is taken, and SIZES does not check.
        "update", "shapes.agc", "shapes_wider.agc", "refresh", "report.agc", "stats",
        "check", "report.agc",
        # Back to the texts of the last program that checked: modules whose ids are still the ones of that program are
        # taken, though the root was not checked (the ids moved when the files were parsed again, so how many depends on
        # them).
        "update", "shapes.agc", "shapes.agc", "refresh", "report.agc", "stats",
        "compare", "report.agc", *asked_at,
    )
    lines = stats_of(out)
    assert [line["reused"] for line in lines[:4]] == [0, 2, 3, 3]
    assert lines[4]["reused"] > lines[3]["reused"]
    assert [line["checks"] for line in lines] == [1, 2, 3, 4, 5]
    wider = json.loads(err)
    assert (wider["code"], Path(wider["file"])) == ("CHECK-ARITY", project / "sizes.agc")
    assert out.splitlines()[-1] == "same 2"


# A fourth module that the edits below do not touch, so it is taken from the last good program.
NAMES = 'export def label() -> String\n  return "r"\nend\n'
REPORT_NAMED = (
    'import Names from "names"\nimport Sizes from "sizes"\n\n'
    "def report() -> Int\n  return Sizes.area(3) + Names.label().length\nend\n"
)


def test_a_question_without_a_refresh_and_the_partial_answers_take_the_unchanged_modules_and_equal_the_command_line(
    driver, project,
):
    """SIZES does not change, but the leaf it imports does, so SIZES no longer checks: the first problem is in a module
    that was not edited. NAMES is the module that is taken from the last program that checked."""
    write_files(project, {
        "shapes.agc": SHAPES, "sizes.agc": SIZES, "names.agc": NAMES, "report.agc": REPORT_NAMED,
        "shapes_wider.agc": SHAPES_WIDER,
    })
    line, column = positions(REPORT_NAMED, ("Sizes.area", 6))
    wider = ("update", "shapes.agc", "shapes_wider.agc")
    # A plain check with no refresh after the edit (the cache misses): it takes NAMES all the same.
    plain_out, plain_err = library(driver, project, "refresh", "report.agc", *wider, "check", "report.agc")
    # The cache after the refresh of the program that does not check: NAMES is taken, and the partial questions use it.
    answers = {}
    for command in ("type-at-partial", "refs-partial"):
        out, err = library(
            driver, project, "refresh", "report.agc", *wider, "refresh", "report.agc", "stats",
            command, "report.agc", line, column,
        )
        assert err == ""
        first, answers[command] = out.split("\n", 1)
        assert stats_of(first)[0]["reused"] == 1
    write_files(project, {"shapes.agc": SHAPES_WIDER})
    assert (plain_out, plain_err) == command_line(project, "check", "report.agc")
    assert json.loads(plain_err)["code"] == "CHECK-ARITY"
    for command, partial in (("type-at-partial", "type-at"), ("refs-partial", "refs")):
        cold = partial_cli(project, partial, "report.agc", line, column)
        assert (answers[command], "") == cold
        found = json.loads(answers[command])
        assert (found["partial"], found["diagnostics"][0]["code"]) == (True, "CHECK-ARITY")


def test_a_refreshed_session_is_asked_by_tasks_on_four_schedulers_with_the_answers_of_the_command_line(driver, project):
    files = ["main.agc", "type_error.agc", "orders.agc", "missing_import.agc", "main.agc"]
    expected = ""
    for file in files:
        out, err = command_line(project, "check", file)
        expected += out or err
    got = library(
        driver, project, "refresh", "main.agc", "refresh", "orders.agc", "refresh", "type_error.agc",
        "check-all", *files, flags=("--schedulers", "4"),
    )
    assert got == (expected, "")


def edited_front_end(project):
    """A copy of compiler/ in `project`, and the text of two of its modules with a line added (edits that stay valid)."""
    shutil.copytree(ROOT / "compiler", project / "compiler")
    for name in ("syntax/source_file", "app/front_end_cli"):
        original = (ROOT / "compiler" / (name + ".agc")).read_text(encoding="utf-8")
        write_files(project, {name.replace("/", "_") + "_edit.agc": "## An edit.\n" + original})


@pytest.mark.slow
def test_cached_answers_equal_uncached_answers_over_the_front_end_with_modules_moved(driver, project):
    """compiler/front_end.agc is about a hundred modules; a check of it takes seconds, and the uncached side of the
    comparison runs it three times."""
    edited_front_end(project)
    source = (ROOT / "compiler/front_end.agc").read_text(encoding="utf-8")
    asked_at = positions(source, ("Inputs.read(", 7), ("Cli.run(settings", 4))
    out, err = library(
        driver, project,
        "refresh", "compiler/front_end.agc", "stats",
        "update", "compiler/syntax/source_file.agc", "syntax_source_file_edit.agc",
        "refresh", "compiler/front_end.agc", "stats",
        "update", "compiler/app/front_end_cli.agc", "app_front_end_cli_edit.agc",
        "refresh", "compiler/front_end.agc", "stats",
        "compare", "compiler/front_end.agc", *asked_at,
    )
    assert (err, out.splitlines()[-1]) == ("", "same 2")
    lines = stats_of(out)
    assert [line["checks"] for line in lines] == [1, 2, 3]
    # The second refresh parses only the module that changed.
    assert [after["parsed"] - before["parsed"] for before, after in zip(lines, lines[1:])] == [1, 1]
    # Modules that do not import an edited one are not checked again.
    reused = [after["reused"] - before["reused"] for before, after in zip(lines, lines[1:])]
    assert all(count > 0 for count in reused), reused


def partial_positions(source):
    """The (line, column) strings of names in `APP`: in a function that checks, in `broken`, and a declared function."""
    return [
        position("app.agc", source, needle, inside)[1:]
        for needle, inside in [("user.age + helper", 5), ("helper(2)", 0), ("count = user", 0), ('helper("no")', 0),
                               ("made = ", 0), ("user.age\n", 5)]
    ]


def partial_cli(project, command, file, line, column, *, stdin=None):
    words = [command, "--partial"] + (["--stdin"] if stdin is not None else []) + [f"{file}:{line}:{column}"]
    return command_line(project, *words, stdin=stdin)


@pytest.fixture
def partial_project(project):
    write_files(project, {"models.agc": PARTIAL_MODELS, "app.agc": APP, "fixed.agc": FIXED})
    write_files(project, {name: text for name, (text, _) in BAD_DECLARATIONS.items()})
    return project


def test_the_partial_answers_equal_the_command_line_while_the_plain_ones_fail(driver, partial_project):
    for line, column in partial_positions(APP):
        for command, partial in [("type-at", "type-at-partial"), ("refs", "refs-partial")]:
            got = library(driver, partial_project, partial, "app.agc", line, column)
            assert got == partial_cli(partial_project, command, "app.agc", line, column)
            assert got != ("", "")
            # The plain question still fails with the error of the function that does not check.
            plain = library(driver, partial_project, command, "app.agc", line, column)
            assert (plain[0], json.loads(plain[1])["code"]) == ("", "CHECK-TYPE-MISMATCH")
    good = library(driver, partial_project, "type-at-partial", "app.agc", *partial_positions(APP)[1])
    assert (json.loads(good[0])["partial"], len(json.loads(good[0])["diagnostics"])) == (True, 1)
    # A field of `broken` needs the types of every function: the first problem, as for the command line.
    field = library(driver, partial_project, "refs-partial", "app.agc", *partial_positions(APP)[5])
    assert (field[0], json.loads(field[1])["code"]) == ("", "CHECK-TYPE-MISMATCH")


def test_a_declaration_that_does_not_check_is_still_an_error_of_the_partial_answers(driver, partial_project):
    for name, (_text, code) in BAD_DECLARATIONS.items():
        for command, partial in [("type-at", "type-at-partial"), ("refs", "refs-partial")]:
            got = library(driver, partial_project, partial, name, "5", "5")
            assert got == partial_cli(partial_project, command, name, "5", "5")
            assert (got[0], json.loads(got[1])["code"]) == ("", code)
    nowhere = library(driver, partial_project, "type-at-partial", "nope.agc", "1", "1")
    assert (nowhere[0], json.loads(nowhere[1])["code"]) == ("", "QUERY-USAGE")


def test_a_refreshed_session_gives_the_partial_answers_of_one_with_no_cache_also_after_edits(driver, partial_project):
    asked_at = partial_positions(APP)
    # The cache holds the program of `app.agc` as failed, and of `fixed.agc` as checked: both are used.
    for file in ["app.agc", "fixed.agc"]:
        for line, column in asked_at:
            for command, partial in [("type-at", "type-at-partial"), ("refs", "refs-partial")]:
                got = library(driver, partial_project, "refresh", file, partial, file, line, column)
                assert got == partial_cli(partial_project, command, file, line, column)
    # A buffer that fixes `app.agc`, refreshed, then a buffer that breaks it again: the stale cache is not used.
    for command, partial in [("type-at", "type-at-partial"), ("refs", "refs-partial")]:
        line, column = asked_at[3]
        edits = ("buffer", "app.agc", "fixed.agc", "refresh", "app.agc")
        got = library(driver, partial_project, *edits, partial, "app.agc", line, column)
        assert got == partial_cli(partial_project, command, "app.agc", line, column, stdin=FIXED)
        assert "partial" not in json.loads(got[0])
        broken = (*edits, "update", "app.agc", "app.agc")
        again = library(driver, partial_project, *broken, partial, "app.agc", line, column)
        assert again == partial_cli(partial_project, command, "app.agc", line, column, stdin=APP)
        assert json.loads(again[0])["partial"] is True
