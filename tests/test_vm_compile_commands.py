"""`make compile-commands`: the compilation database of the VM, which clangd, clang-tidy and analyzers read."""

import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

import pytest

from tests.agentica_test import ROOT, tool

pytestmark = pytest.mark.skipif(os.name != "posix", reason="the build of the host runs make with a POSIX shell")


def syntax_check(clang, entry):
    """The entry's compile with clang and -fsyntax-only: the file, and the stderr when it fails."""
    arguments = entry["arguments"]
    at = arguments.index("-c")
    command = [clang, *arguments[1:at], "-fsyntax-only", arguments[at + 1]]
    result = subprocess.run(command, cwd=entry["directory"], capture_output=True, text=True, check=False)
    return entry["file"], result.returncode, result.stderr


def test_every_vm_file_compiles_from_the_database(tmp_path):
    clang = tool("clang")
    out = tmp_path / "compile_commands.json"
    made = subprocess.run(
        ["make", "--no-print-directory", "-s", "compile-commands", f"COMPILE_COMMANDS={out}"],
        cwd=ROOT, check=False, stdin=subprocess.DEVNULL, capture_output=True, text=True,
    )
    assert made.returncode == 0, made.stderr
    entries = json.loads(out.read_text())

    # Every C file of vm/ but the libFuzzer driver, which only the LIBFUZZ=1 mode compiles.
    expected = {str(p.relative_to(ROOT)) for p in (ROOT / "vm").glob("**/*.c") if "third_party" not in p.parts}
    expected.discard("vm/fuzz_libfuzzer.c")
    assert {e["file"] for e in entries} == expected

    # The quotes of the version define reach the compiler: loader.c uses it as a string literal.
    version = (ROOT / "VERSION").read_text().strip()
    assert all(f'-DAGC_VERSION="{version}"' in e["arguments"] for e in entries)

    with ThreadPoolExecutor(int(os.environ.get("JOBS", "4"))) as pool:
        failed = [(f, err) for f, rc, err in pool.map(lambda e: syntax_check(clang, e), entries) if rc]
    assert failed == []
