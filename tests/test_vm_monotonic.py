"""Time.monotonic_ns against Python's clock."""
from tests.agentica_test import FIXTURES, PYTHON, TestCase, run, vm_binary


class MonotonicPeer(TestCase):
    def test_monotonic_ns_reads_the_same_clock_as_python(self):
        bytecode = self.compile_fixture(FIXTURES / "monotonic-peer.agc")
        result = run([PYTHON, FIXTURES / "monotonic-peer.py", vm_binary(), bytecode])
        self.assertEqual(result.code, 0, result.stderr)
        self.assertRegex(result.stdout, r"\A(ok|skip: .*)\n\Z")
