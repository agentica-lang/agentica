"""std/binary on the VM (ported from std-binary-test.rkt).

Two fixture programs print their own checks: std-binary.agc ends with a fixed
summary, and std-binary-vectors.agc reads the Python-made vectors of its
sidecar from stdin and counts them.
"""
from tests.agentica_test import FIXTURES, TestCase, run_vm

VM_FIXTURES = FIXTURES / "vm"


class StdBinary(TestCase):
    def run_fixture(self, name, stdin=None):
        """Compile a fixture, run it on the VM, and return its stdout split on \\n (a final "" stays)."""
        bytecode = self.compile_fixture(VM_FIXTURES / (name + ".agc"))
        result = run_vm(bytecode, stdin=stdin)
        self.assertEqual(result.code, 0, name + "\n" + result.stderr)
        self.assertEqual(result.stderr, "", name)
        return result.stdout.split("\n")

    def test_std_binary_prints_no_mismatch_and_ends_with_the_fixed_summary(self):
        lines = self.run_fixture("std-binary")
        self.assertFalse(any(line.startswith("mismatch") for line in lines))
        self.assertEqual(lines[-2:], ["all checks ok", ""])
        self.assertIn("frames: 0 mismatches", lines)
        self.assertIn("error(u64 at offset 0 does not fit in Int)", lines)
        self.assertIn("error(frame limit -1 is negative)", lines)

    def test_std_binary_vectors_checks_every_vector_of_its_sidecar_and_prints_no_mismatch(self):
        stdin = (VM_FIXTURES / "std-binary-vectors.stdin").read_bytes()
        text = stdin.decode("utf-8")
        vectors = len([line for line in text.split("\n") if line]) - 1
        self.assertTrue(text.startswith("# std-binary-vectors.stdin: made by python3"))
        self.assertEqual(self.run_fixture("std-binary-vectors", stdin), ["%d vectors ok" % vectors, ""])
