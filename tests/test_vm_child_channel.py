"""Both sides of the parent/child channel of the VM.

fixtures/child-channel.agc is the program; fixtures/child-channel-peer.py is the
independent peer: it drives the child side, and it is the child the parent side
spawns.
"""
import json

from tests.agentica_test import FIXTURES, PYTHON, TestCase, run, run_vm, vm_binary

PEER = FIXTURES / "child-channel-peer.py"


def lines(*items):
    return "\n".join(items) + "\n"


class ChildChannel(TestCase):
    def setUp(self):
        self.bytecode = self.compile_fixture(FIXTURES / "child-channel.agc")

    def test_child_side_lines_partial_lines_eof_timeouts_and_no_channel(self):
        result = run([PYTHON, PEER, vm_binary(), self.bytecode])
        self.assertEqual(result.code, 0, result.stderr)
        answer = json.loads(result.stdout)

        def part(name, key):
            return answer[name][key]

        self.assertEqual(part("serve", "exit"), 0)
        self.assertEqual(part("serve", "replies"),
                         ["echo:one\n", "echo:two\n", "echo:\n", 300006, "echo:café\n", "bye\n", ""])
        self.assertEqual(part("serve", "stdout"),
                         lines("sent: ok()", "sent: ok()", "sent: ok()", "sent: ok()", "sent: ok()",
                               "ended: process: end of input", "bye: ok()"))
        self.assertEqual(part("idle", "stdout"),
                         lines('first: error("network: operation timed out")',
                               'second: error("process: channel is closed")',
                               'send: error("process: channel is closed")'))
        self.assertIs(part("idle", "waited"), True)
        bare = lines('read: error("process: no parent channel")',
                     'send: error("process: no parent channel")',
                     'zero: error("network: timeout must be positive milliseconds")')
        self.assertEqual(part("bare", "stdout"), bare)
        self.assertEqual(part("bare_marker_only", "stdout"), bare)
        spawned = "unset\nclosed\n\n3\nsocket\n\n"
        self.assertEqual(part("spawning", "stdout"), spawned)
        self.assertEqual(part("spawning_marker_only", "stdout"), spawned)
        for name in ("serve", "idle", "bare", "bare_marker_only", "spawning", "spawning_marker_only"):
            self.assertEqual(part(name, "exit"), 0, name)
        refused = lines('read: error("process: no parent channel")',
                        'send: error("process: no parent channel")', "ready")
        pinned = answer["pinned"]
        for kind in ("file", "device", "writeonly", "fifo"):
            self.assertEqual(pinned[kind]["exit"], 0, kind)
        self.assertEqual(pinned["file"]["head"], refused)
        self.assertIs(pinned["file"]["target"].endswith("/plain.txt"), True)
        self.assertEqual(pinned["file"]["content"], "")
        self.assertEqual(pinned["writeonly"]["head"], refused)
        self.assertEqual(pinned["device"]["head"], refused)
        self.assertEqual(pinned["device"]["target"], "/dev/null")
        self.assertEqual(pinned["fifo"]["head"], lines('read: ok("hello")', "ready"))

    def ask(self, mode):
        """Run the program in `mode`; it spawns the peer as its child."""
        result = run_vm(self.bytecode, "--allow-run", args=[mode, PYTHON, PEER])
        self.assertEqual(result.code, 0, result.stderr)
        return result.stdout

    def test_parent_side_send_read_available_close_timeouts_and_limits(self):
        self.assertEqual(self.ask("echo"), lines(
            "send: ok()", 'read: ok("HELLO")', 'printed: ok("out:hello\\n")', 'printed again: ok("")',
            "close: ok()", 'send after close: error("process: channel is closed")',
            'end: error("process: end of input")', "exit: ok(0)"))
        self.assertEqual(self.ask("silent"), lines(
            'first: error("network: operation timed out")', 'second: error("process: channel is closed")',
            'send: error("process: channel is closed")', 'printed: ok("")'))
        self.assertEqual(self.ask("stalled"), lines(
            'send: error("network: operation timed out")', 'after: error("process: channel is closed")'))
        self.assertEqual(self.ask("long"), lines(
            'read: error("process: line exceeds 1048576 bytes")', 'again: error("process: channel is closed")'))
        self.assertEqual(self.ask("loud"), lines('read: ok("done")', 'printed: ok("noise\\n")'))
        self.assertEqual(self.ask("split"), lines(
            'first: ok("one")', 'printed: ok("a")', "send: ok()", 'second: ok("two")', 'printed: ok("éb\\n")'))
        self.assertEqual(self.ask("gone"), lines(
            "exit: ok(0)", 'end: error("process: end of input")', "close: ok()", "close again: ok()"))
        self.assertEqual(self.ask("plain"), lines(
            'read: error("process: the child has no channel")', 'send: error("process: the child has no channel")',
            'close: error("process: the child has no channel")', "exit: ok(0)",
            'printed: ok("marker=None fd3=False\\n")', 'not captured: error("process: output is not captured")'))
