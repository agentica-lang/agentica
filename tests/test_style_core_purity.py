"""The stage folders of compiler/ are pure: they never touch the machine except through the Workspace record.

The core is every folder of compiler/ except the adapters (io/, app/, bdd/) and embedded/, so a new folder is checked
by default. embedded/ holds the two programs the binary embeds for `agentica test` (they import std/test/runner and
std/bdd, which run processes and read files); they are not front-end stages. Files at the root of compiler/
(front_end.agc) are adapters too. io/ builds the real Workspace (modules/workspace.agc); app/ and bdd/ are driving
adapters and may do I/O. See "Pure core, one port" in references/frontend.md of the development skill.

Two rules, both read from the tokens of the real lexer (compiler/syntax/lex.agc), so a string, an interpolation inside
a string, a heredoc, a comment and the builtin data rows (`"File.open"` in builtins_data.agc) are read as what they are:

- Calls: a core file may not use a builtin module that reads or changes the outside world (`File`, `Dir`, `Process`,
  `System`, `FrontEnd`, `IO`, `TCP`, `TLS`, `HttpWire`, `Time`, `Random`, `Task`, `Channel`, `Profile`, `LogRegistry`),
  and may not call the bare `puts`. The only `Path` function it may use is `Path.join`, which is string work; every
  other `Path` function (present or future) is forbidden. `&File.open` (a function value) is a use too.
- Imports: a core file may not import from `io/`, `app/` or `bdd/`, nor from a `std/` module that is not on
  PURE_STD_MODULES. A new std module is forbidden until someone reads it and lists it. A file of
  `syntax/` may not import a later stage (LATER_THAN_SYNTAX); it may import `diagnostics/`, the shared diagnostic data.
  A file of `diagnostics/` may import only its own folder and `syntax/source` (DIAGNOSTICS_MAY_IMPORT).

The entry programs (the text-form runners of each stage, run by tests with `agentica compiler/<folder>/<name>.agc`) are
driving adapters that live next to their stage. They may read their command line with `System.args`, print with `puts`,
and import the io/ adapters that read and write files (`io/host`, `io/source_reader`, `io/save_file`; bytecode.agc
writes its output through SaveFile). They may not import app/, bdd/ or an impure std module.
"""
import posixpath
import re

import pytest

from tests.agentica_test import ROOT, cli, run

COMPILER = ROOT / "compiler"
# Adapters and embedded programs; every other folder of compiler/ is core.
NOT_CORE_FOLDERS = {"io", "app", "bdd", "embedded"}
IO_FOLDERS = {"io"}
APP_FOLDERS = {"app", "bdd"}
LEXER = COMPILER / "syntax" / "lex.agc"
# The stages after syntax/. The first stage cannot take a later one as input (syntax/ast once imported check/types; the
# Type enum now lives in syntax/types.agc). diagnostics/ is shared data, not a stage, so syntax/ may import it.
LATER_THAN_SYNTAX = {"modules", "packages", "check", "catalog", "lower", "bytecode"}
# diagnostics/ is data that every stage reads (it once imported check/check_failure; the packed Problem now lives in
# diagnostics/problem.agc). It may import its own folder and the one syntax file that holds the Span it points with,
# which imports nothing, so no import cycle exists.
DIAGNOSTICS_MAY_IMPORT = {"compiler/syntax/source"}

OUTSIDE = "an adapter (io/ is for entry programs only, app/ and bdd/ never) or a file outside compiler/"
FORBIDDEN_MODULES = {
    "File", "Dir", "Process", "System", "FrontEnd", "IO", "TCP", "TLS", "HttpWire", "Time", "Random", "Task", "Channel",
    "Profile", "LogRegistry",
}
# The one Path function that is string work. `resolve` needs the working directory, so it is not.
PURE_PATH_FUNCTIONS = {"join"}
# Bare builtins that print.
FORBIDDEN_BARE = {"puts"}

# The std/ modules a core file may import: pure text and byte work, no files, sockets, processes or logging.
# std/prelude/ holds the List, Map and Lazy methods written in Agentica.
PURE_STD_MODULES = {"std/binary", "std/queue", "std/toml"}
PURE_STD_PREFIXES = ("std/prelude/",)

# Entry programs of the core folders, and the calls each one may make. Besides these calls they may print with `puts`
# and import io/ (see the module docstring).
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


def core_folders():
    return sorted(path.name for path in COMPILER.iterdir() if path.is_dir() and path.name not in NOT_CORE_FOLDERS)


def core_files():
    found = []
    for folder in core_folders():
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
    """The 'Module.name' of every forbidden call and bare `puts` in a token list; Path.join is left out."""
    found = []
    for at, (kind, lexeme) in enumerate(tokens):
        if kind == "name" and lexeme in FORBIDDEN_BARE and (at == 0 or tokens[at - 1][0] not in ("dot", "def")):
            found.append(lexeme)
        if at + 2 >= len(tokens):
            continue
        (dot, _), (name_kind, name) = tokens[at + 1:at + 3]
        if kind != "type-name" or dot != "dot" or name_kind != "name":
            continue
        if lexeme in FORBIDDEN_MODULES or (lexeme == "Path" and name not in PURE_PATH_FUNCTIONS):
            found.append("%s.%s" % (lexeme, name))
    return found


def imported_paths(tokens):
    """The path string of every `import ... from "path"` of a token list (an interpolated path has none)."""
    found = []
    at = 0
    while at < len(tokens):
        if tokens[at][0] != "import":
            at += 1
            continue
        at += 1
        while at < len(tokens) and tokens[at][0] not in ("string", "NL", "interp-start"):
            at += 1
        if at < len(tokens) and tokens[at][0] == "string":
            # The lexeme is the source text, escaped like a string: \"path\".
            found.append(tokens[at][1][2:-2])
    return found


def forbidden_imports(path, tokens, entry):
    """Why each import of a core file is not allowed: it reaches io/, app/, bdd/ or an impure std/ module."""
    found = []
    for target in imported_paths(tokens):
        if target.startswith("std/"):
            if target not in PURE_STD_MODULES and not target.startswith(PURE_STD_PREFIXES):
                found.append("%s imports %s, a std module not on PURE_STD_MODULES" % (path, target))
            continue
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
        parts = resolved.split("/")
        folder = parts[1] if len(parts) > 2 and parts[0] == "compiler" else None
        if folder in IO_FOLDERS and entry:
            continue
        if folder in IO_FOLDERS | APP_FOLDERS or folder is None:
            found.append("%s imports %s, %s" % (path, target, OUTSIDE))
        elif path.startswith("compiler/syntax/") and folder in LATER_THAN_SYNTAX:
            found.append("%s imports %s, a later stage" % (path, target))
        elif (
            path.startswith("compiler/diagnostics/")
            and folder != "diagnostics"
            and resolved not in DIAGNOSTICS_MAY_IMPORT
        ):
            found.append("%s imports %s, a stage (diagnostics/ is shared data)" % (path, target))
    return found


def defines_main(tokens):
    return any(tokens[at][0] == "def" and tokens[at + 1] == ("name", "main") for at in range(len(tokens) - 1))


def offenders(sections):
    found = []
    for path, tokens in sections.items():
        allowed = ENTRY_PROGRAMS.get(path, set())
        entry = path in ENTRY_PROGRAMS
        for call in forbidden_calls(tokens):
            if call not in allowed and not (entry and call == "puts"):
                found.append("%s calls %s" % (path, call))
        found += forbidden_imports(path, tokens, entry)
        if defines_main(tokens) and path not in ENTRY_PROGRAMS:
            found.append("%s defines main: add it to ENTRY_PROGRAMS or move it to app/" % path)
    return found


def test_the_core_folders_never_call_the_machine():
    files = core_files()
    assert {"syntax", "modules", "check", "catalog", "lower", "bytecode", "diagnostics"} <= set(core_folders())
    assert not NOT_CORE_FOLDERS & set(core_folders())
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
        '  g = Path.exists("x")\n'
        '  puts("loud")\n'
        '  h = log.puts(1)\n'
        '  i = Time.now_ms()\n'
        'end\n',
        encoding="utf-8",
    )
    sections = token_kinds(["probe.agc"], tmp_path)
    assert forbidden_calls(sections["probe.agc"]) == [
        "System.pid", "File.open", "Path.real", "Path.exists", "puts", "Time.now_ms",
    ]
    assert defines_main(sections["probe.agc"])


def test_the_rule_reads_imports(tmp_path):
    (tmp_path / "probe.agc").write_text(
        'import Host from "../io/host"\n'
        'import {run} from "../app/pipeline"\n'
        'import Driver from "../bdd/bdd_driver"\n'
        'import Http from "std/http"\n'
        'import Queue from "std/queue"\n'
        'import List from "std/prelude/list"\n'
        'import Local from "lexer"\n'
        'import Sibling from "../syntax/types"\n'
        'import Later from "../check/checker"\n'
        '# import Quiet from "../io/host"\n'
        'x = "import Quiet from \\"../io/host\\""\n',
        encoding="utf-8",
    )
    sections = token_kinds(["probe.agc"], tmp_path)
    tokens = sections["probe.agc"]
    assert imported_paths(tokens) == [
        "../io/host", "../app/pipeline", "../bdd/bdd_driver", "std/http", "std/queue", "std/prelude/list", "lexer",
        "../syntax/types", "../check/checker",
    ]
    core = "compiler/check/probe.agc"
    assert offenders({core: tokens}) == [
        "%s imports ../io/host, %s" % (core, OUTSIDE),
        "%s imports ../app/pipeline, %s" % (core, OUTSIDE),
        "%s imports ../bdd/bdd_driver, %s" % (core, OUTSIDE),
        "%s imports std/http, a std module not on PURE_STD_MODULES" % core,
    ]
    # An entry program may import the io/ adapters, and nothing else of that list.
    entry = "compiler/syntax/lex.agc"
    assert [line.split(" imports ")[1].split(",")[0] for line in offenders({entry: tokens})] == [
        "../app/pipeline", "../bdd/bdd_driver", "std/http", "../check/checker",
    ]


def test_diagnostics_imports_no_stage(tmp_path):
    (tmp_path / "probe.agc").write_text(
        'import Diag from "diagnostic"\n'
        'import Source from "../syntax/source"\n'
        'import Types from "../syntax/types"\n'
        'import Problems from "../check/check_failure"\n',
        encoding="utf-8",
    )
    tokens = token_kinds(["probe.agc"], tmp_path)["probe.agc"]
    path = "compiler/diagnostics/probe.agc"
    assert offenders({path: tokens}) == [
        "%s imports ../syntax/types, a stage (diagnostics/ is shared data)" % path,
        "%s imports ../check/check_failure, a stage (diagnostics/ is shared data)" % path,
    ]
