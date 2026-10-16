"""A copied binary still imports std/ modules.

The standard library is embedded in the binary. The test copies the binary into a folder of its own, away from the
checkout, and runs a program that imports `std/queue` from another working directory. It runs on the binary of
AGENTICA_TEST_EXECUTABLE (`make test-distribution` sets it to dist/agentica); a shell wrapper cannot be moved and is
skipped. The release runs the unpacked archive too (release.yml).

The old test also rebuilt the executable from a copied source tree. That check is dropped: it only made sense for the
old executable, which step 8d removed.
"""
import shutil
import unittest
from pathlib import Path

from tests.agentica_test import TestCase, cli, run, vm_environment

PROGRAM = (
    'import Queue from "std/queue"\ndef main() -> Void\n  q = Queue.push(Queue.new(), "embedded")\n'
    "  puts(Result.unwrap!(Queue.peek(q)))\nend\n\n")


class StdlibDistribution(TestCase):
    def test_the_relocated_binary_imports_stdlib_without_its_build_checkout(self):
        source = Path(cli()[0]).resolve()
        with open(source, "rb") as binary:
            if binary.read(2) == b"#!":
                raise unittest.SkipTest("%s is a script, which cannot be relocated" % source)
        directory = self.make_temp_dir("agentica-distribution-").resolve()
        bin_directory = directory / "bin"
        bin_directory.mkdir()
        relocated = bin_directory / source.name
        shutil.copy(source, relocated)
        program = directory / "program.agc"
        program.write_text(PROGRAM, encoding="utf-8")
        result = run([relocated, program], cwd=directory, env=vm_environment())
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "embedded\n")
        self.assertEqual(result.code, 0)
