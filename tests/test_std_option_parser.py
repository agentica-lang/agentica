"""std/option_parser through the program of tests/fixtures/option_parser/tool.agc, as a user runs it.

Python's argparse is the independent peer for the values of valid command lines and for the exit code of the wrong
ones. The help text is a golden file (help.expected). A getter that reads a value the wrong way halts.
"""
import argparse
import contextlib
import io

import pytest

from tests.agentica_test import FIXTURES, cli, compile_agc, run, run_vm

FIXTURE = FIXTURES / "option_parser"


@pytest.fixture(scope="module")
def tool(tmp_path_factory):
    return compile_agc(FIXTURE / "tool.agc", tmp_path_factory.mktemp("agentica-option-parser-") / "tool.agcb")


@pytest.fixture(scope="module")
def limits(tmp_path_factory):
    return compile_agc(FIXTURE / "limits.agc", tmp_path_factory.mktemp("agentica-option-parser-") / "limits.agcb")


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


@pytest.mark.parametrize("args,line", [
    ([], "port=8080 threads=1 ctx=0 stats=false dir=none"),
    (["--port", "0", "--threads=1"], "port=0 threads=1 ctx=0 stats=false dir=none"),
    (["-p", "65535", "--stats", "on", "--ctx", "-1"], "port=65535 threads=1 ctx=-1 stats=true dir=none"),
])
def test_int_limits_accept_their_edges_and_on_off_is_a_choice(limits, args, line):
    result = run_vm(limits, args=args)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == line + "\n"


@pytest.mark.parametrize("args,message", [
    (["--port", "65536"], "invalid value for --port: '65536' is above the maximum 65535"),
    (["-p", "-1"], "invalid value for --port: '-1' is below the minimum 0"),
    (["--port", "99999999999999999999"], "invalid value for --port: '99999999999999999999' does not fit an Int"),
    (["--threads", "0"], "invalid value for --threads: '0' is below the minimum 1"),
    (["--temp", "2.5"], "invalid value for --temp: '2.5' is above the maximum 2.0"),
    (["--temp", "-1"], "invalid value for --temp: '-1' is below the minimum 0.0"),
    (["--stats", "maybe"], "invalid value for --stats: 'maybe' is not one of on, off"),
])
def test_a_value_outside_its_limit_or_choices_is_refused_with_exit_2(limits, args, message):
    result = run_vm(limits, args=args)
    assert result.code == 2
    assert result.stdout == ""
    assert result.stderr.splitlines() == [f"serve: {message}", "Try 'serve --help' for more information"]


def test_help_shows_limits_in_brackets_and_the_default_value_names(limits):
    result = run_vm(limits, args=["--help"])
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == (FIXTURE / "limits_help.expected").read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def rest(tmp_path_factory):
    return compile_agc(FIXTURE / "rest.agc", tmp_path_factory.mktemp("agentica-option-parser-") / "rest.agcb")


def rest_peer_lines(args):
    """argparse's intermixed parse with a `nargs="*"` argument gives the rest. argparse does not tell which words came
    after `--`, so that half is written here by hand: the words of the rest that come after the first `--` are the
    flags, and the words before them are the files."""
    parser = argparse.ArgumentParser(prog="check", add_help=False, allow_abbrev=False)
    parser.add_argument("src")
    parser.add_argument("files", nargs="*")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("-o", "--out")
    got = parser.parse_intermixed_args(args)
    after = args[args.index("--") + 1:] if "--" in args else []
    count = min(len(after), len(got.files))
    files, flags = got.files[:len(got.files) - count], got.files[len(got.files) - count:]
    return [f"src={got.src} files={','.join(files)} flags={','.join(flags)}",
            f"v={str(got.verbose).lower()} out={got.out or 'none'}"]


@pytest.mark.parametrize("args", [
    ["s"],
    ["s", "a.c", "b.c"],
    ["s", "a.c", "-v", "b.c", "-o", "r.txt", "c.c"],
    ["s", "a.c", "--", "-Iinclude", "-DX=1"],
    ["-v", "s", "--", "-x"],
    ["--", "s", "-x", "y"],
    ["s", "a.c", "-", "-5", "--"],
    ["s", ""],
    ["s", "--", "--"],
], ids=lambda args: repr(args))
def test_the_rest_of_the_words_and_those_after_dashes_match_argparse(rest, args):
    result = run_vm(rest, args=args)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.splitlines() == rest_peer_lines(args)


def test_the_usage_line_names_the_rest(rest):
    assert run_vm(rest, args=["--help"]).stdout.splitlines()[0] == "Usage: check [options] <src> [FILE...]"


@pytest.mark.parametrize("args,message", [
    ([], "missing argument <src>"),
    (["--"], "missing argument <src>"),
    (["s", "a.c", "-x"], "unknown option -x"),
])
def test_a_parser_with_a_rest_still_wants_its_arguments_and_knows_its_options(rest, args, message):
    result = run_vm(rest, args=args)
    assert result.code == 2
    assert result.stderr.splitlines() == [f"check: {message}", "Try 'check --help' for more information"]


def test_a_rest_name_with_a_space_is_an_invalid_specification(tmp_path):
    program = tmp_path / "spec.agc"
    program.write_text(
        'import OP from "std/option_parser"\n\n'
        "def main() -> Void\n"
        '  puts(OP.parse(OP.new("t", "", [], [], "MY FILE"), []).message)\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(program)])
    assert (result.code, result.stdout) == (0, "t: invalid specification: 'MY FILE' is not a valid name for the rest\n")
