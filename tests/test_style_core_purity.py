"""The stage folders of compiler/ are pure: they never touch the machine except through the Workspace record.

The core (syntax, modules, check, catalog, lower, bytecode, diagnostics, and packages when it exists) must not call
the builtins that read or change the outside world. io/ builds the real Workspace (modules/workspace.agc); app/ and
bdd/ are driving adapters and may do I/O. See "Pure core, one port" in references/frontend.md of the development skill.

What counts as a call: the tokens `Module` `.` `name`, found by the real lexer (compiler/syntax/lex.agc), so a string,
an interpolation inside a string, a heredoc, a comment and the builtin data rows (`"File.open"` in builtins_data.agc)
are read as what they are. `File.`, `Dir.`, `Process.`, `System.` and `FrontEnd.` are forbidden whole; `Path.` is
forbidden except `Path.join`, which is string work. `&File.open` (a function value) is a use too.

The entry programs (the text-form runners of each stage, run by tests with `agentica compiler/<folder>/<name>.agc`) are
driving adapters that live next to their stage. They may read their command line with `System.args` and nothing else.
"""
import re

import pytest

from tests.agentica_test import ROOT, cli, run

COMPILER = ROOT / "compiler"
CORE_FOLDERS = ("syntax", "modules", "check", "catalog", "lower", "bytecode", "diagnostics", "packages")
LEXER = COMPILER / "syntax" / "lex.agc"

FORBIDDEN_MODULES = {"File", "Dir", "Process", "System", "FrontEnd"}
FORBIDDEN_PATH_FUNCTIONS = {"real", "resolve", "cwd", "remove", "rename"}

# Entry programs of the core folders, and the calls each one may make.
ENTRY_PROGRAMS = {
    "compiler/syntax/lex.agc": {"System.args"},
    "compiler/syntax/parse.agc": {"System.args"},
    "compiler/modules/link.agc": {"System.args"},
    "compiler/check/check.agc": {"System.args"},
    "compiler/lower/lower.agc": {"System.args"},
    "compiler/bytecode/bytecode.agc": {"System.args"},
    "compiler/catalog/catalog.agc": {"System.args"},
}

# `kind start-end "lexeme" value`, the lexeme escaped like a string.
TOKEN = re.compile(r"(\S+) \d+:\d+:\d+-\d+:\d+:\d+ \"((?:[^\"\\]|\\.)*)\"")


def core_files():
    found = []
    for folder in CORE_FOLDERS:
        found += sorted((COMPILER / folder).rglob("*.agc"))
    return [path.relative_to(ROOT).as_posix() for path in found]


def token_kinds(paths, cwd):
    """{path: [token kind and lexeme, ...]} from the lexer of the binary, for files given relative to cwd."""
    result = run(cli() + [str(LEXER), *paths], cwd=cwd)
    assert result.code == 0, result.stderr
    sections = {}
    current = None
    for line in result.stdout.split("\n"):
        if line.startswith("== "):
            current = sections.setdefault(line[3:], [])
            continue
        assert not line.startswith("ERROR"), "the lexer rejects %s: %s" % (current, line)
        found = TOKEN.match(line)
        if found and current is not None:
            current.append((found.group(1), found.group(2)))
    return sections


def forbidden_calls(tokens):
    """The 'Module.name' of every forbidden call in a token list; Path.join and all else are left out."""
    found = []
    for at in range(len(tokens) - 2):
        (kind, module), (dot, _), (name_kind, name) = tokens[at:at + 3]
        if kind != "type-name" or dot != "dot" or name_kind != "name":
            continue
        if module in FORBIDDEN_MODULES or (module == "Path" and name in FORBIDDEN_PATH_FUNCTIONS):
            found.append("%s.%s" % (module, name))
    return found


def defines_main(tokens):
    return any(tokens[at][0] == "def" and tokens[at + 1] == ("name", "main") for at in range(len(tokens) - 1))


def offenders(sections):
    found = []
    for path, tokens in sections.items():
        allowed = ENTRY_PROGRAMS.get(path, set())
        for call in forbidden_calls(tokens):
            if call not in allowed:
                found.append("%s calls %s" % (path, call))
        if defines_main(tokens) and path not in ENTRY_PROGRAMS:
            found.append("%s defines main: add it to ENTRY_PROGRAMS or move it to app/" % path)
    return found


def test_the_core_folders_never_call_the_machine():
    files = core_files()
    assert set(ENTRY_PROGRAMS) <= set(files)
    sections = token_kinds(files, ROOT)
    assert set(sections) == set(files)
    assert offenders(sections) == [], "the core reaches the machine; use a Workspace function (io/host.agc):"


def test_the_rule_reads_real_calls_only(tmp_path):
    (tmp_path / "probe.agc").write_text(
        'def main() -> Void\n'
        '  a = "File.open and System.args"\n'
        '  # Process.spawn in a comment\n'
        '  b = Path.join(["x", "y"])\n'
        '  c = "#{System.pid()}"\n'
        '  d = <<~TEXT\n'
        '    Dir.list is text\n'
        '    here too\n'
        '  TEXT\n'
        '  e = &File.open\n'
        '  f = Path.real("x")\n'
        'end\n',
        encoding="utf-8",
    )
    sections = token_kinds(["probe.agc"], tmp_path)
    assert forbidden_calls(sections["probe.agc"]) == ["System.pid", "File.open", "Path.real"]
    assert defines_main(sections["probe.agc"])
