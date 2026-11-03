"""std/option_parser through the program of tests/fixtures/option_parser/tool.agc, as a user runs it.

Python's argparse is the independent peer for the values of valid command lines and for the exit code of the wrong
ones. The help text is a golden file (help.expected). A getter that reads a value the wrong way halts.
"""
import argparse
import contextlib
import io

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

FIXTURE = FIXTURES / "option_parser"


@pytest.fixture(scope="module")
def tool(tmp_path_factory):
    return compile_agc(FIXTURE / "tool.agc", tmp_path_factory.mktemp("agentica-option-parser-") / "tool.agcb")


@pytest.fixture(scope="module")
def bug(tmp_path_factory):
    return compile_agc(FIXTURE / "bug.agc", tmp_path_factory.mktemp("agentica-option-parser-") / "bug.agcb")


def peer():
    parser = argparse.ArgumentParser(prog="tool", add_help=False, allow_abbrev=False)
    parser.add_argument("file")
    parser.add_argument("-p", "--port", type=int, default=8080)
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("-q", "--quiet", action="store_true")
    parser.add_argument("-u", "--user")
    return parser


def peer_line(args):
    got = peer().parse_args(args)
    return f"file={got.file} port={got.port} verbose={str(got.verbose).lower()} quiet={str(got.quiet).lower()} user={got.user or 'none'}"


VALID = [
    ["f"],
    ["-p", "3000", "f"],
    ["--port", "3000", "f"],
    ["--port=3000", "f"],
    ["-p3000", "f"],
    ["f", "-v"],
    ["-v", "--user", "ana", "f"],
    ["--user=ana", "-p", "7", "-v", "f"],
    ["--port", "1", "--port", "2", "f"],
    ["-p", "-5", "f"],
    ["--", "-f"],
    ["-v", "--", "f"],
    ["-vq", "f"],
    ["-vqp3000", "f"],
    ["-qvp", "3000", "f"],
    ["-p=3000", "f"],
    ["--port=-1", "f"],
    ["-5"],
    ["--user=--x", "f"],
    ["-u--x", "f"],
    ["-u=ana", "f"],
]


@pytest.mark.parametrize("args", VALID, ids=lambda args: " ".join(args))
def test_valid_command_lines_give_the_values_of_argparse(tool, args):
    result = run_vm(tool, args=args)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == peer_line(args) + "\n"


# (words, what the message says): each one is also an error of argparse, which exits with 2.
WRONG = [
    (["--bogus", "f"], "unknown option --bogus"),
    (["-x", "f"], "unknown option -x"),
    (["f", "--port"], "option --port needs a value"),
    (["--port", "abc", "f"], "invalid value for --port: 'abc' is not an Int"),
    (["--verbose=1", "f"], "option --verbose does not take a value"),
    (["--port", "--verbose", "f"], "option --port needs a value"),
    (["f", "-u", "-v"], "option --user needs a value"),
    (["-p", "-x", "f"], "option --port needs a value"),
    ([], "missing argument <file>"),
    (["f", "g"], "unexpected argument 'g'"),
]


@pytest.mark.parametrize("args,message", WRONG, ids=lambda value: " ".join(value) if isinstance(value, list) else "")
def test_a_wrong_command_line_prints_the_error_to_stderr_and_exits_2(tool, args, message):
    result = run_vm(tool, args=args)
    assert result.code == 2
    assert result.stdout == ""
    assert result.stderr.splitlines() == [f"tool: {message}", "Try 'tool --help' for more information"]
    with contextlib.redirect_stderr(io.StringIO()), pytest.raises(SystemExit) as peer_exit:
        peer().parse_args(args)
    assert peer_exit.value.code == 2


@pytest.mark.parametrize("flag", ["--help", "-h"])
def test_help_prints_the_usage_to_stdout_and_exits_0(tool, flag):
    result = run_vm(tool, args=["--port", "3000", flag, "--bogus"])
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == (FIXTURE / "help.expected").read_text(encoding="utf-8")


@pytest.mark.parametrize("mode,message", [
    ("undeclared", "no option or argument is named 'prot'"),
    ("kind", "'port' is declared as int but read as string"),
    ("absent", "'user' has no default and was not given: read it with optional_string"),
])
def test_a_getter_that_reads_the_wrong_way_halts_and_names_the_call(bug, mode, message):
    result = run_vm(bug, args=[mode])
    assert result.code == 1
    assert "RUNTIME-UNWRAP-ERROR" in result.stderr
    assert message in result.stderr
    assert "main at" in result.stderr
    assert run_vm(bug, args=["fine"]).stdout == "80\n"
