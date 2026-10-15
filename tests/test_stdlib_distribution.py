"""A copied bin/ with the CLI and the VM still imports std/ modules (ported from stdlib-distribution-test.rkt).

The standard library is embedded in the executable. The test copies the executable and the VM into a folder of its own,
away from the checkout, and runs a program that imports `std/queue` from another working directory. It runs only when
AGENTICA_TEST_EXECUTABLE names a built executable (`make test-distribution` builds dist/agentica and sets it); a shell
wrapper cannot be moved and is skipped. The VM is copied next to the executable, where the Racket launcher looks for
it; the single binary ignores the copy. The release also runs the unpacked archive (release.yml).

The old test also rebuilt the executable from a copied source tree. That check is dropped: it only made sense for the
Racket executable, which step 8d removes.
"""
import os
import shutil
import unittest
from pathlib import Path

from tests.agentica_test import TestCase, run, vm_binary, vm_environment

PROGRAM = (
    'import Queue from "std/queue"\ndef main() -> Void\n  q = Queue.push(Queue.new(), "embedded")\n'
    "  puts(Result.unwrap!(Queue.peek(q)))\nend\n\n")


class StdlibDistribution(TestCase):
    def test_the_relocated_executable_imports_stdlib_without_its_build_checkout(self):
        executable = os.environ.get("AGENTICA_TEST_EXECUTABLE")
        if not executable:
            raise unittest.SkipTest("AGENTICA_TEST_EXECUTABLE names no built executable")
        source = Path(executable).resolve()
        with open(source, "rb") as binary:
            if binary.read(2) == b"#!":
                raise unittest.SkipTest("%s is a script, which cannot be relocated" % source)
        directory = self.make_temp_dir("agentica-distribution-").resolve()
        bin_directory = directory / "bin"
        bin_directory.mkdir()
        relocated = bin_directory / source.name
        shutil.copy(source, relocated)
        shutil.copy(vm_binary(), bin_directory / "agentica-vm")
        program = directory / "program.agc"
        program.write_text(PROGRAM, encoding="utf-8")
        environment = vm_environment({"AGENTICA_VM": None, "AGENTICA_VM_BINARY": None})
        result = run([relocated, program], cwd=directory, env=environment)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "embedded\n")
        self.assertEqual(result.code, 0)
