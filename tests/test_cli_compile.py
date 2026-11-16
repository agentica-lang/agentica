"""`agentica compile [FILE...]`, which fills the bytecode cache ahead, and the notice of a run that compiles its program
when stderr is a terminal (issue #1735), through the CLI."""
import json
import os

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, vm_environment

OK = 'def main() -> Void\n  puts("ok")\nend\n'
BROKEN = 'def main() -> Void\n  x: Int = "a"\nend\n'


def agentica(folder, *words, **streams):
    environment = vm_environment({"AGENTICA_BUILD_DIR": None})
    return run(cli() + list(words), cwd=folder, env=environment, **streams)


def write(folder, files):
    for name, text in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def entries(folder):
    found = folder / "_build" / "bytecode"
    return sorted(found.glob("*.agcb")) if found.is_dir() else []


def test_compile_without_a_file_fills_the_cache_for_each_main_and_a_run_then_hits(tmp_path):
    write(tmp_path, {"agentica.toml": "", "app/main.agc": OK, "tool/main.agc": OK, "tool/helper.agc": OK,
                     "deps/pkg/main.agc": OK, ".hidden/main.agc": OK, "tests/main.agc": BROKEN,
                     "app/fixtures/bad/main.agc": BROKEN})
    first = agentica(tmp_path, "compile")
    assert (first.code, first.stdout, first.stderr) == (0, "compiled app/main.agc\ncompiled tool/main.agc\n", "")
    written = {entry: entry.stat().st_mtime_ns for entry in entries(tmp_path)}
    assert len(written) == 2

    again = agentica(tmp_path, "compile", "tool/main.agc", "tool/helper.agc")
    assert (again.code, again.stdout) == (0, "fresh tool/main.agc\ncompiled tool/helper.agc\n")
    ran = agentica(tmp_path, "app/main.agc")
    assert (ran.code, ran.stdout) == (0, "ok\n")
    assert {entry: entry.stat().st_mtime_ns for entry in entries(tmp_path) if entry in written} == written


def test_compile_reports_a_program_that_does_not_compile_and_goes_on(tmp_path):
    write(tmp_path, {"a/main.agc": BROKEN, "b/main.agc": OK})
    failed = agentica(tmp_path, "--json", "compile")
    assert (failed.code, '"CHECK-TYPE-MISMATCH"' in failed.stderr) == (1, True)
    assert [json.loads(line) for line in failed.stdout.splitlines()] == [{"file": "b/main.agc", "state": "compiled"}]
    assert len(list(tmp_path.glob("*/_build/bytecode/*.agcb"))) == 1
    assert agentica(tmp_path, "--no-cache", "compile", "b/main.agc").code == 2


@pytest.mark.parametrize("files", [{}, {"lib.agc": OK}])
def test_a_folder_with_no_main_is_one_short_line(tmp_path, files):
    write(tmp_path, files)
    found = agentica(tmp_path, "compile")
    assert (found.code, found.stdout, len(found.stderr.splitlines())) == (2, "", 1)


def test_a_compile_under_a_deny_flag_fills_the_entry_that_a_run_under_it_reads(tmp_path):
    write(tmp_path, {"ok.agc": OK})
    assert agentica(tmp_path, "--deny-net", "compile", "ok.agc").stdout == "compiled ok.agc\n"
    written = {entry: entry.stat().st_mtime_ns for entry in entries(tmp_path)}
    ran = agentica(tmp_path, "--deny-net", "ok.agc")
    assert (ran.code, ran.stdout) == (0, "ok\n")
    assert {entry: entry.stat().st_mtime_ns for entry in entries(tmp_path)} == written


def on_a_terminal(folder, *words):
    """Runs with stderr on a pseudo-terminal: the exit code, stdout and what stderr showed. The terminal side stays
    open while the output is read: macOS drops what is unread once it closes."""
    import pty
    import select

    main, side = pty.openpty()
    try:
        terminal = os.fdopen(side, "wb", buffering=0, closefd=False)
        result = agentica(folder, *words, stderr_to=terminal)
        shown = b""
        while select.select([main], [], [], 0.5)[0]:
            chunk = os.read(main, 4096)
            if not chunk:
                break
            shown += chunk
    finally:
        os.close(side)
        os.close(main)
    return result.code, result.stdout, shown.decode("utf-8").replace("\r\n", "\n")


@host_only(WINDOWS, "the notice is checked through a POSIX pseudo-terminal")
def test_a_run_that_compiles_says_so_on_a_terminal_and_nowhere_else(tmp_path):
    write(tmp_path, {"main.agc": 'import Util from "util"\n\ndef main() -> Void\n  puts(Util.word())\nend\n',
                     "util.agc": 'def word() -> String = "ok"\n'})
    code, out, shown = on_a_terminal(tmp_path, "main.agc")
    lines = shown.splitlines()
    assert (code, out, len(lines), lines[0]) == (0, "ok\n", 2, "Compiling main.agc…"), shown
    assert lines[1].startswith("Compiled main.agc (2 modules) in ") and lines[1].endswith("s"), shown
    assert on_a_terminal(tmp_path, "main.agc") == (0, "ok\n", "")
    assert on_a_terminal(tmp_path, "--no-cache", "--json", "main.agc") == (0, "ok\n", "")
    assert on_a_terminal(tmp_path, "--no-cache", "compile", "main.agc", "-o", "out.agcb") == (0, "", "")
    missing = on_a_terminal(tmp_path, "nope.agc")
    assert (missing[0], "Compiling" in missing[2]) == (2, False)
    piped = agentica(tmp_path, "--no-cache", "main.agc")
    assert (piped.code, piped.stdout, piped.stderr) == (0, "ok\n", "")
