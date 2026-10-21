"""`agentica check --stdin FILE` (issue #346, step 1b): the text of FILE comes from standard input, so an editor can
check a buffer that is not saved. Imports, agentica.toml and agc_libs/ resolve from the folder of FILE; every other
file is read from the disk. The cases run the binary and read the `--json` form: the code, the file and the span."""
import json
import os
import signal
import subprocess
import time

import pytest

from tests.agentica_test import (POSIX_PYTHON, TARGET_OS, WINDOWS, binary, host_only, run, scaled, vm_environment,
                                 write_files)

CLEAN = 'def main() -> Void\n  puts("ok")\nend\n'
# The error is on line 2, columns 12 to 15.
TYPE_ERROR = 'def main() -> Void\n  x: Int = "a"\n  puts(x)\nend\n'
UTIL = "export def twice(n: Int) -> Int\n  return n * 2\nend\n"
USES_UTIL = 'import Util from "util"\n\ndef main() -> Void\n  puts(Util.twice(2).to_s)\nend\n'
STDIN_CAP = 16 * 1024 * 1024


def check(work, buffer, *words, style="--json"):
    """Runs `agentica [STYLE] check --stdin WORDS...` in `work` with `buffer` on standard input."""
    command = [binary()] + ([style] if style else []) + ["check", "--stdin", *words]
    return run(command, stdin=buffer, cwd=work, env=vm_environment())


def problem(result):
    """The one diagnostic of a failed check, from its JSON on stderr."""
    assert (result.code, result.stdout) == (1, "")
    return json.loads(result.stderr)


def span(diagnostic):
    start, stop = diagnostic["range"]["start"], diagnostic["range"]["end"]
    return (start["line"], start["column"], stop["line"], stop["column"])


def test_a_buffer_with_an_error_gives_its_diagnostic_with_the_file_and_the_span(tmp_path):
    diagnostic = problem(check(tmp_path, TYPE_ERROR, "new.agc"))
    assert diagnostic["code"] == "CHECK-TYPE-MISMATCH"
    assert diagnostic["file"] == "new.agc"
    assert span(diagnostic) == (2, 12, 2, 15)
    # A file typed with a folder is named as typed, and the other styles show the line of the buffer.
    assert problem(check(tmp_path, TYPE_ERROR, "./sub/../new.agc"))["file"] == "./sub/../new.agc"
    plain = check(tmp_path, TYPE_ERROR, "new.agc", style="")
    assert plain.code == 1
    assert '2 |   x: Int = "a"' in plain.stderr


def test_a_clean_buffer_succeeds_in_every_style(tmp_path):
    json_style = check(tmp_path, CLEAN, "new.agc")
    assert (json_style.code, json_style.stdout, json_style.stderr) == (0, '{"ok":true}\n', "")
    plain = check(tmp_path, CLEAN, "new.agc", style="")
    assert (plain.code, plain.stdout, plain.stderr) == (0, "check ok\n", "")


def test_the_buffer_wins_over_the_file_on_the_disk(tmp_path):
    write_files(tmp_path, {"main.agc": TYPE_ERROR})
    assert check(tmp_path, CLEAN, "main.agc").code == 0
    write_files(tmp_path, {"main.agc": CLEAN})
    assert problem(check(tmp_path, TYPE_ERROR, "main.agc"))["code"] == "CHECK-TYPE-MISMATCH"
    # Nothing is written to the disk.
    assert (tmp_path / "main.agc").read_text() == CLEAN


def test_a_file_that_is_not_on_the_disk_works_and_its_folder_is_the_base_of_the_imports(tmp_path):
    (tmp_path / "sub").mkdir()
    write_files(tmp_path / "sub", {"util.agc": UTIL})
    write_files(tmp_path, {"util.agc": "this is not a module\n"})
    assert check(tmp_path, USES_UTIL, "sub/new.agc").code == 0
    # The folder of the cwd has another util.agc: the one beside FILE is the one that is read.
    assert problem(check(tmp_path, USES_UTIL, "new.agc"))["code"].startswith("PARSE-")
    # An absolute path works as well, from any working folder.
    elsewhere = tmp_path / "sub" / ".."
    assert check(elsewhere, USES_UTIL, str(tmp_path / "sub" / "new.agc")).code == 0
    if TARGET_OS == "windows":
        # Path.resolve gives backslashes there; the folder of the file is still found.
        assert check(tmp_path, USES_UTIL, "sub\\new.agc").code == 0


def test_an_import_that_is_not_there_and_an_error_in_an_imported_file_are_reported(tmp_path):
    assert problem(check(tmp_path, USES_UTIL, "new.agc"))["code"] == "CHECK-IMPORT-IO"
    write_files(tmp_path, {"util.agc": 'export def twice(n: Int) -> Int\n  return "no"\nend\n'})
    diagnostic = problem(check(tmp_path, USES_UTIL, "new.agc"))
    assert diagnostic["code"] == "CHECK-TYPE-MISMATCH"
    assert diagnostic["file"].replace("\\", "/").endswith("util.agc")
    assert span(diagnostic) == (2, 10, 2, 14)


def test_agc_libs_and_the_manifest_are_found_from_the_folder_of_the_file(tmp_path):
    (tmp_path / "app" / "agc_libs").mkdir(parents=True)
    write_files(tmp_path / "app" / "agc_libs", {"helper.agc": 'export def name() -> String\n  return "h"\nend\n'})
    buffer = 'import Helper from "pkg/helper"\n\ndef main() -> Void\n  puts(Helper.name())\nend\n'
    assert check(tmp_path, buffer, "app/new.agc").code == 0
    write_files(tmp_path, {"agentica.toml": "[package\n"})
    diagnostic = problem(check(tmp_path, buffer, "app/new.agc"))
    assert diagnostic["code"] == "PKG-MANIFEST-INVALID"
    assert diagnostic["file"].replace("\\", "/").endswith("agentica.toml")


def test_a_buffer_that_is_not_utf8_is_the_diagnostic_of_a_file_that_is_not_utf8(tmp_path):
    data = b'def main() -> Void\n  puts("a\xff\xe2\x82b")\nend\n'
    (tmp_path / "disk.agc").write_bytes(data)
    from_disk = problem(run([binary(), "--json", "check", "disk.agc"], cwd=tmp_path, env=vm_environment()))
    diagnostic = problem(check(tmp_path, data, "new.agc"))
    assert diagnostic["code"] == "LEX-INVALID-UTF8"
    assert diagnostic["file"] == "new.agc"
    assert span(diagnostic) == span(from_disk) == (2, 10, 2, 11)
    # The line of the message shows U+FFFD in place of the bad byte, as for a file.
    assert "�" in check(tmp_path, data, "new.agc", style="").stderr


def test_standard_input_over_the_cap_is_a_usage_failure(tmp_path):
    got = check(tmp_path, b"#" * (STDIN_CAP + 1), "new.agc")
    assert (got.code, got.stdout) == (2, "")
    assert got.stderr.startswith("agentica: ")


def start_check(work, stdin, **options):
    """Starts `agentica check --stdin new.agc` in `work` with the descriptor `stdin` as its standard input."""
    return subprocess.Popen([binary(), "check", "--stdin", "new.agc"], stdin=stdin, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=work, env=vm_environment(), **options)


def default_sigint():
    """A shell that starts a job in the background makes it ignore SIGINT, and the VM keeps an ignored stop signal
    ignored: the case wants the default, whoever started pytest."""
    signal.signal(signal.SIGINT, signal.SIG_DFL)


def finish(process):
    """The exit code and the text of both streams, or a failure (and the process killed) when it does not end."""
    try:
        out, err = process.communicate(timeout=scaled(30))
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise AssertionError("agentica check --stdin did not end")
    return process.returncode, out.decode(errors="replace"), err.decode(errors="replace")


def test_a_pipe_whose_writer_is_late_is_read_to_its_end(tmp_path):
    """The read waits on the loop (the reader thread on Windows), and a pipe that is non-blocking, as a parent may
    leave it, still gives its data once the writer sends it."""
    read_end, write_end = os.pipe()
    if POSIX_PYTHON:
        os.set_blocking(read_end, False)
    try:
        process = start_check(tmp_path, read_end)
    finally:
        os.close(read_end)
    try:
        time.sleep(0.5)
        os.write(write_end, CLEAN[:10].encode())
        time.sleep(0.2)
        os.write(write_end, CLEAN[10:].encode())
    finally:
        os.close(write_end)
    assert finish(process) == (0, "check ok\n", "")


@host_only(WINDOWS, "SIGINT; test_ctrl_c_ends_check_stdin_while_it_waits_for_input in test_windows_console_stop.py "
                    "presses Ctrl+C on a console")
def test_a_stop_signal_while_the_input_is_pending_ends_the_run_as_a_stop(tmp_path):
    read_end, write_end = os.pipe()
    try:
        process = start_check(tmp_path, read_end, preexec_fn=default_sigint)
    finally:
        os.close(read_end)
    try:
        time.sleep(1)
        process.send_signal(signal.SIGINT)
        code, out, err = finish(process)
    finally:
        os.close(write_end)
    # The VM dies by the signal, as any run does, and says nothing about the input.
    assert (code, out, err) == (-signal.SIGINT, "", "")


@pytest.mark.parametrize("words", (
    ["check", "--stdin"],
    ["check", "--stdin", "a.agc", "b.agc"],
    ["check", "--stdin", ""],
    ["check", "--stdin", "--json"],
    ["check", "a.agc", "--stdin"],
    ["compile", "--stdin", "a.agc", "-o", "a.agcb"],
))
def test_stdin_with_anything_but_check_and_one_file_is_a_usage_error(tmp_path, words):
    write_files(tmp_path, {"a.agc": CLEAN})
    got = run([binary(), *words], stdin=CLEAN, cwd=tmp_path, env=vm_environment())
    assert (got.code, got.stdout) == (2, "")
    assert got.stderr.startswith("usage: agentica")
