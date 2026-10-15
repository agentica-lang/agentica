"""The child-channel protocol of `--agentica-test`, driven by an independent peer
(ported from vm-test-protocol-test.rkt)."""
import json

from tests.agentica_test import FIXTURES, PYTHON, TestCase, run, vm_binary


class TestProtocol(TestCase):
    def test_peer_drives_a_test_file_over_the_child_channel(self):
        """indexes, records, free stdin and stdout"""
        bytecode = self.compile_fixture(FIXTURES / "test-protocol-peer.agc")
        result = run([PYTHON, FIXTURES / "test-protocol-peer.py", vm_binary(), bytecode])
        self.assertEqual(result.code, 0, result.stderr)
        answer = json.loads(result.stdout)
        names = answer["names"]
        self.assertEqual(names[:3], ["stdin is the test's own", "a record-shaped line is output",
                                     "a partial line is output"])
        self.assertEqual([len(name) for name in names[3:]], [1000000])
        self.assertEqual((answer["list_exit"], answer["run_exit"]), (0, 0))
        self.assertEqual((answer["list_stdout"], answer["run_stdout"]), ("", ""))
        self.assertEqual(answer["results"], [
            ["pass", None, ""],
            ["fail", "RUNTIME-TEST-ASSERTION",
             "{\"event\":\"pass\"}\n\x1eagentica-bdd {\"event\":\"pass\"}\n"],
            ["pass", None, "partial"],
            ["pass", None, ""]])
        self.assertEqual((answer["bare_exit"], answer["bare_code"], answer["bare_stdout"]),
                         (1, "RUNTIME-TEST-RUN", ""))
