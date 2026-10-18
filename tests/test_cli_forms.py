"""The command line of dist/agentica: the options and their mistakes, the three forms of a diagnostic, program runs,
compile and help, against a golden of the whole output.

This is a CLI output golden, like the VM goldens of tests/fixtures/vm/: it compares exit code, stdout and stderr byte
for byte, message and help texts included. AGENTS.md's "never message text" applies to hand-written assertions, not to
a golden that `make goldens` rewrites (so a change of wording is one command and a reviewed diff).

The cases ran through both command lines (the original front end, the development oracle, and the binary) until
that front end went; they agreed on every byte of the exit code, stdout and stderr. tests/fixtures/cli/forms.json
keeps that output. A change of the command line on purpose rewrites it with `make goldens` (or
`poetry run python -m tests.test_cli_forms freeze`), and the diff of the file is the review. The temp folder and the version are written as <work> and <version>.
A file that `compile` writes is only noted as written or not (its bytes carry the version)."""
import json
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from tests.agentica_test import FIXTURES, agentica_version, binary, run, vm_environment

FROZEN = FIXTURES / "cli" / "forms.json"
JOBS = 6

FILES = {
    "ok.agc": 'def main() -> Void\n  puts("ok")\nend\n',
    "args.agc": (
        'def main() -> Void\n  puts(System.args().join("|"))\n  IO.warn("to stderr")\n  name = IO.gets()\n'
        '  if name.ok?\n    puts("hello #{name.unwrap!}")\n  end\n  print("rest=#{IO.read()}")\n'
        '  System.exit(3)\nend\n'),
    "loop.agc": "def main() -> Void\n  while true\n  end\nend\n",
    "divide.agc": "def main() -> Void\n  puts(1 / 0)\nend\n",
    "lex.agc": 'def main() -> Void\n  puts("unterminated)\nend\n',
    "parse.agc": 'def main() -> Void\n  puts "hello"\nend\n',
    "tab.agc": 'def main() -> Void\n\tx: Int = "a"\n\tputs(x)\nend\n',
    "crlf.agc": 'def main() -> Void\r\n  x: Int = "a"\r\n  puts(x)\r\nend\r\n',
    "unicode.agc": 'def main() -> Void\n  puts("héllo")\n  x: Int = "éé"\nend\n',
    "multiline.agc": 'def main() -> Void\n  x = [1, 2,\n    3] + "s"\nend\n',
    "labels.agc": (
        "def add(a: Int, b: Int) -> Int\n  return a + b\nend\n\ndef main() -> Void\n  x = add(1, \"two\")\n"
        "  puts(x)\nend\n"),
    "twice.agc": "def main() -> Void\n  puts(\"x\")\nend\n\ndef main() -> Void\nend\n",
    "helped.agc": "def main() -> Void\n  values = []\nend\n",
    "missing_import.agc": 'import Nothing from "nothing"\n\ndef main() -> Void\n  puts("x")\nend\n',
    "std_error.agc": 'import Queue from "std/queue"\n\ndef main() -> Void\n  puts(Queue.nope())\nend\n',
    "lib/util.agc": (
        "export def boom(n: Int) -> Int\n  return n / 0\nend\n\nexport def bad() -> Int\n  return \"s\"\nend\n"),
    "sub/boom.agc": (
        'import Util from "../lib/util"\n\ndef main() -> Void\n  puts("start")\n  puts(Util.boom(1))\nend\n'),
    "sub/bad.agc": 'import Util from "../lib/util"\n\ndef main() -> Void\n  puts(Util.bad())\nend\n',
}

# Written as bytes: a file that is not UTF-8.
BINARY_FILES = {"invalid.agc": b'def main() -> Void\n  puts("a\xff\xe2\x82b")\nend\n'}

# What the stages and the runtime can say about a program, run in the three forms of a diagnostic.
PROGRAMS = ["ok.agc", "lex.agc", "parse.agc", "tab.agc", "crlf.agc", "unicode.agc", "multiline.agc", "labels.agc",
            "twice.agc", "helped.agc", "missing_import.agc", "std_error.agc", "sub/bad.agc", "sub/boom.agc",
            "invalid.agc", "divide.agc", "absent.agc"]

BUILTINS = ["String.split", "ok", "Task.await", "Map.get", "List.group_by", "String.compare"]

# Arguments with no file: the options, their mistakes and the help.
OPTIONS = [
    ["--version"], ["-h"], ["--help"], ["-hx"], ["-xh"], ["-ab", "c"], ["--foo"], ["+x"], ["-"], ["+"], [],
    ["check"], ["compile"], ["help"], ["--json", "help"], ["help", "--json"], ["help", "Nope"],
    ["help", "Strin.split"],
    ["help", "a", "b", "c"], ["help", "HttpWire.client"], ["help", "__fail_arg"],
    ["--max-steps"], ["--max-steps", "x", "ok.agc"], ["--max-steps", "0", "ok.agc"], ["--max-steps", "007", "ok.agc"],
    ["--max-steps=5", "ok.agc"], ["--seed", "2147483648", "ok.agc"], ["--seed", "007", "ok.agc"],
    ["--seed", "--json", "ok.agc"], ["--seed", "1", "--seed"], ["--seed", "5", "--seed", "6", "ok.agc"],
    ["--ai", "--ai", "check", "ok.agc"], ["--allow-run", "--allow-run", "ok.agc"], ["--steps"],
    ["--flush-timeout"], ["--flush-timeout", "x", "ok.agc"], ["--flush-timeout", "100", "ok.agc"],
    ["--version", "--foo"], ["--foo", "--version"], ["--", "ok.agc"], ["ok.agc", "--version"],
    ["check", "--json", "ok.agc"], ["compile", "ok.agc"], ["--dump", "compile", "ok.agc", "-o", "out.agcb"],
    ["--max-steps", "1", "check", "ok.agc"], ["--json", "check", "ok.agc"], ["--ai", "check", "ok.agc"],
    ["check", "nope.agc"], ["nope.agc"], ["check", "."],
    ["--max-steps", "5", "--seed", "1", "--json", "--allow-run", "--flush-timeout", "10", "ok.agc"],
]


class Workspace:
    """A folder with the programs of FILES, and the way to run the binary in it and write down what it did."""

    def __init__(self, work):
        self.work = Path(work).resolve()
        for name, text in FILES.items():
            path = self.work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        for name, data in BINARY_FILES.items():
            (self.work / name).write_bytes(data)

    def plain(self, text):
        return text.replace(str(self.work), "<work>").replace(agentica_version(), "<version>")

    def key(self, arguments, options):
        return json.dumps([[self.plain(str(argument)) for argument in arguments], options], sort_keys=True)

    def observe(self, arguments, stdin="", cwd=None, outputs=()):
        """What the binary does for the arguments: exit code, stdout, stderr, and which of `outputs` it wrote.

        `outputs` are files the command writes (relative to cwd); they are removed before and after the run, so a
        file of an earlier case is never taken for this one's."""
        folder = self.work / cwd if cwd and not Path(cwd).is_absolute() else Path(cwd or self.work)
        for name in outputs:
            (folder / name).unlink(missing_ok=True)
        result = run([binary()] + [str(argument) for argument in arguments], stdin=stdin.encode(), cwd=folder,
                     env=vm_environment())
        written = []
        for name in outputs:
            path = folder / name
            written.append(path.exists())
            path.unlink(missing_ok=True)
        return {"code": result.code, "stdout": self.plain(result.stdout), "stderr": self.plain(result.stderr),
                "written": written}


def groups(work):
    """Every case as {group: [(arguments, options)]}; options are the keyword arguments of Workspace.observe."""
    forms = ([], ["--ai"], ["--json"])
    diagnostics = [(style + ["check", program], {}) for style in forms for program in PROGRAMS]
    # A runtime problem is the VM's; a path typed in full names the root file as typed.
    diagnostics += [(["--max-steps", "100000", program], {}) for program in ("ok.agc", "divide.agc", "sub/boom.agc")]
    diagnostics += [(["--json", "check", str(work / program)], {}) for program in ("tab.agc", "sub/bad.agc")]
    runs = [
        (["args.agc", "a", "b c", "--json", ""], {"stdin": "World\nline2\nline3"}),
        (["args.agc"], {}),
        (["--seed", "3", "args.agc", "x"], {"stdin": "Zed"}),
        (["--max-steps", "1000", "--json", "loop.agc"], {}),
        (["--ai", "--max-steps", "1000", "loop.agc"], {}),
        (["sub/boom.agc"], {}),
        (["--json", "sub/boom.agc"], {}),
        (["main.agc"], {"cwd": "sub"}),
        ([str(work / "sub" / "boom.agc")], {"cwd": "/"}),
    ]
    compiles = [
        (["compile", "args.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
        (["compile", "sub/boom.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
        (["compile", "tab.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
        (["--json", "compile", "labels.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
        (["compile", "ok.agc", "-o", "/nonexistent/folder/out.agcb"], {}),
    ]
    helps = [(["help", name] + flag, {}) for name in BUILTINS for flag in ([], ["--json"])]
    return {"options": [(arguments, {}) for arguments in OPTIONS], "diagnostics": diagnostics, "runs": runs,
            "compiles": compiles, "helps": helps}


def freeze():
    with tempfile.TemporaryDirectory(prefix="agentica-cli-forms-") as directory:
        workspace = Workspace(directory)
        frozen = {}
        for cases in groups(workspace.work).values():
            # The compile cases write the same name: one at a time.
            for arguments, options in cases:
                frozen[workspace.key(arguments, options)] = workspace.observe(arguments, **options)
        FROZEN.parent.mkdir(parents=True, exist_ok=True)
        FROZEN.write_text(json.dumps(frozen, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
        print("%d cases written to %s" % (len(frozen), FROZEN))


@pytest.fixture(scope="module")
def workspace(tmp_path_factory):
    return Workspace(tmp_path_factory.mktemp("agentica-cli-forms-"))


@pytest.fixture(scope="module")
def case_groups(workspace):
    return groups(workspace.work)


@pytest.fixture(scope="module")
def frozen():
    return json.loads(FROZEN.read_text(encoding="utf-8"))


def differences(workspace, frozen, cases, parallel=True):
    """The cases whose output is not the frozen one, as a message ('' when none differs)."""
    def compare(case):
        arguments, options = case
        expected = frozen.get(workspace.key(arguments, options))
        if expected is None:
            return "%s: no frozen output (python3 -m tests.test_cli_forms freeze)" % (arguments,)
        found = workspace.observe(arguments, **options)
        return None if found == expected else "%s\n  frozen: %r\n  found:  %r" % (arguments, expected, found)

    if parallel:
        with ThreadPoolExecutor(JOBS) as pool:
            found = list(pool.map(compare, cases))
    else:
        found = [compare(case) for case in cases]
    return "\n".join(line for line in found if line)


def test_every_frozen_case_is_still_a_case(workspace, case_groups, frozen):
    keys = {workspace.key(arguments, options)
            for cases in case_groups.values() for arguments, options in cases}
    assert sorted(set(frozen) - keys) == []


def test_options_commands_and_their_mistakes(workspace, case_groups, frozen):
    assert differences(workspace, frozen, case_groups["options"]) == ""


def test_every_diagnostic_form_of_every_stage(workspace, case_groups, frozen):
    assert differences(workspace, frozen, case_groups["diagnostics"]) == ""


def test_running_a_program_passes_arguments_standard_streams_and_the_exit_status(workspace, case_groups, frozen):
    assert differences(workspace, frozen, case_groups["runs"]) == ""


def test_compile_writes_a_file_or_says_why_not(workspace, case_groups, frozen):
    # The cases write the same name one after the other: one at a time.
    assert differences(workspace, frozen, case_groups["compiles"], parallel=False) == ""


def test_help_for_a_few_builtins_in_both_forms(workspace, case_groups, frozen):
    assert differences(workspace, frozen, case_groups["helps"]) == ""


if __name__ == "__main__":
    if sys.argv[1:] == ["freeze"]:
        freeze()
    else:
        raise SystemExit("usage: poetry run python -m tests.test_cli_forms freeze")
