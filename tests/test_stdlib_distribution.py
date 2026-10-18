"""A copied binary still imports std/ modules.

The standard library is embedded in the binary. The test copies the binary into a folder of its own, away from the
checkout, and runs a program that imports `std/queue` from another working directory. It runs on the binary of
AGENTICA_TEST_EXECUTABLE (`make test-distribution` sets it to dist/agentica); a shell wrapper cannot be moved and is
skipped. The release runs the unpacked archive too (release.yml).

The old test also rebuilt the executable from a copied source tree. That check is dropped: it only made sense for the
old executable, which step 8d removed.
"""
import shutil
from pathlib import Path

import pytest

from tests.agentica_test import cli, run, vm_environment

PROGRAM = (
    'import Queue from "std/queue"\ndef main() -> Void\n  q = Queue.push(Queue.new(), "embedded")\n'
    "  puts(Result.unwrap!(Queue.peek(q)))\nend\n\n")


def test_the_relocated_binary_imports_stdlib_without_its_build_checkout(tmp_path):
    source = Path(cli()[0]).resolve()
    with source.open("rb") as binary:
        if binary.read(2) == b"#!":
            pytest.skip(f"{source} is a script, which cannot be relocated")
    bin_directory = tmp_path / "bin"
    bin_directory.mkdir()
    relocated = bin_directory / source.name
    shutil.copy(source, relocated)
    program = tmp_path / "program.agc"
    program.write_text(PROGRAM, encoding="utf-8")
    result = run([relocated, program], cwd=tmp_path, env=vm_environment())
    assert result.stderr == ""
    assert result.stdout == "embedded\n"
    assert result.code == 0
