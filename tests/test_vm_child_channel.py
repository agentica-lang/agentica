"""Both sides of the parent/child channel of the VM.

fixtures/child-channel.agc is the program; fixtures/child-channel-peer.py is the
independent peer: it drives the child side, and it is the child the parent side
spawns.
"""
import json

import pytest

from tests.agentica_test import FIXTURES, PYTHON, compile_agc, run, run_vm, vm_binary

PEER = FIXTURES / "child-channel-peer.py"


def lines(*items):
    return "\n".join(items) + "\n"


@pytest.fixture
def bytecode(tmp_path):
    source = FIXTURES / "child-channel.agc"
    return compile_agc(source, tmp_path / (source.stem + ".agcb"))


def test_child_side_lines_partial_lines_eof_timeouts_and_no_channel(bytecode):
    result = run([PYTHON, PEER, vm_binary(), bytecode])
    assert result.code == 0, result.stderr
    answer = json.loads(result.stdout)

    def part(name, key):
        return answer[name][key]

    assert part("serve", "exit") == 0
    assert part("serve", "replies") == ["echo:one\n", "echo:two\n", "echo:\n", 300006, "echo:café\n", "bye\n", ""]
    assert part("serve", "stdout") == lines("sent: ok()", "sent: ok()", "sent: ok()", "sent: ok()", "sent: ok()",
                                               "ended: process: end of input", "bye: ok()")
    assert part("idle", "stdout") == lines('first: error("network: operation timed out")',
                                               'second: error("process: channel is closed")',
                                               'send: error("process: channel is closed")')
    assert part("idle", "waited") is True
    bare = lines('read: error("process: no parent channel")',
                 'send: error("process: no parent channel")',
                 'zero: error("network: timeout must be positive milliseconds")')
    assert part("bare", "stdout") == bare
    assert part("bare_marker_only", "stdout") == bare
    spawned = "unset\nclosed\n\n3\nsocket\n\n"
    assert part("spawning", "stdout") == spawned
    assert part("spawning_marker_only", "stdout") == spawned
    for name in ("serve", "idle", "bare", "bare_marker_only", "spawning", "spawning_marker_only"):
        assert part(name, "exit") == 0, name
    refused = lines('read: error("process: no parent channel")',
                    'send: error("process: no parent channel")', "ready")
    pinned = answer["pinned"]
    for kind in ("file", "device", "writeonly", "fifo"):
        assert pinned[kind]["exit"] == 0, kind
    assert pinned["file"]["head"] == refused
    assert pinned["file"]["target"].endswith("/plain.txt") is True
    assert pinned["file"]["content"] == ""
    assert pinned["writeonly"]["head"] == refused
    assert pinned["device"]["head"] == refused
    assert pinned["device"]["target"] == "/dev/null"
    assert pinned["fifo"]["head"] == lines('read: ok("hello")', "ready")


def test_parent_side_send_read_available_close_timeouts_and_limits(bytecode):
    def ask(mode):
        """Run the program in `mode`; it spawns the peer as its child."""
        result = run_vm(bytecode, "--allow-run", args=[mode, PYTHON, PEER])
        assert result.code == 0, result.stderr
        return result.stdout

    assert ask("echo") == lines(
        "send: ok()", 'read: ok("HELLO")', 'printed: ok("out:hello\\n")', 'printed again: ok("")',
        "close: ok()", 'send after close: error("process: channel is closed")',
        'end: error("process: end of input")', "exit: ok(0)")
    assert ask("silent") == lines(
        'first: error("network: operation timed out")', 'second: error("process: channel is closed")',
        'send: error("process: channel is closed")', 'printed: ok("")')
    assert ask("stalled") == lines(
        'send: error("network: operation timed out")', 'after: error("process: channel is closed")')
    assert ask("long") == lines(
        'read: error("process: line exceeds 1048576 bytes")', 'again: error("process: channel is closed")')
    assert ask("loud") == lines('read: ok("done")', 'printed: ok("noise\\n")')
    assert ask("split") == lines(
        'first: ok("one")', 'printed: ok("a")', "send: ok()", 'second: ok("two")', 'printed: ok("éb\\n")')
    assert ask("gone") == lines(
        "exit: ok(0)", 'end: error("process: end of input")', "close: ok()", "close again: ok()")
    assert ask("plain") == lines(
        'read: error("process: the child has no channel")', 'send: error("process: the child has no channel")',
        'close: error("process: the child has no channel")', "exit: ok(0)",
        'printed: ok("marker=None fd3=False\\n")', 'not captured: error("process: output is not captured")')
