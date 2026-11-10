"""The std/archive driver shared by tests/test_std_archive.py and tests/test_std_archive_zip.py.

tests/fixtures/archive/driver.agc is compiled once per module: compiling std/archive for every case was most of the
time of these modules. Each JSON case on stdin is one extraction, and the driver prints one line for it.
"""
import json

from tests.agentica_test import FIXTURES, compile_agc, run_vm, vm_environment


def compile_driver(tmp_path_factory):
    return compile_agc(FIXTURES / "archive" / "driver.agc",
                       tmp_path_factory.mktemp("agentica-archive-") / "driver.agcb")


def limits(timeout=30000, max_out=268435456):
    """The `Archive.Options` of a case; a case with None leaves the argument to its default."""
    return {"timeout_ms": timeout, "max_output_bytes": max_out}


def extract(driver, work, kind, calls):
    """Run each (label, src, members, dest, options) call of `Archive.extract_<kind>` in WORK, in one process.

    Returns the stdout lines, `<label> ok <counts>` or `<label> error <message>` (newlines as ` | `), then "".
    The kind "defaults" prints `<label> <timeout_ms> <max_output_bytes>` of `Archive.Options()` instead.
    """
    cases = [{"label": label, "kind": kind, "src": src, "members": members, "dest": dest, "options": options}
             for label, src, members, dest, options in calls]
    stdin = "".join(json.dumps(case) + "\n" for case in cases).encode("utf-8")
    result = run_vm(driver, stdin=stdin, cwd=work, env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stderr == ""
    return result.stdout.split("\n")
