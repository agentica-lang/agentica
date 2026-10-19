"""Both sides of the parent/child channel of the VM, on every system.

fixtures/child-channel.agc is the program; fixtures/child-channel-peer.js is the independent peer (Node): it drives
the child side, and it is the child the parent side spawns. The peer opens the channel the way the system does, one
socket pair at descriptor 3, or one pipe per direction at 3 and 4 on Windows. The cases that need a shell, /proc or a
FIFO are in test_vm_child_channel_posix.py.
"""
import json

import pytest

from tests.agentica_test import (FIXTURES, compile_agc, kill_process, process_alive, run, run_vm, scaled, start_vm, vm_binary,
                                 wait_until)

PEER = FIXTURES / "child-channel-peer.js"
WAIT = scaled(20)

# The VM is the parent of a child that reads its channel until the end and reports its pid.
PARENT_PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.spawn_channel(args[0], [args[1], "child", "watch"], ".", 5000))
  puts(Result.unwrap!(Process.read_line(p, 5000)))
  IO.flush()
  Task.sleep(60000)
end
"""


def lines(*items):
    return "\n".join(items) + "\n"


@pytest.fixture
def bytecode(tmp_path):
    source = FIXTURES / "child-channel.agc"
    return compile_agc(source, tmp_path / (source.stem + ".agcb"))


def test_child_side_lines_partial_lines_eof_timeouts_and_no_channel(bytecode, node):
    result = run([node, PEER, vm_binary(), bytecode], timeout=scaled(120))
    assert result.code == 0, result.stderr
    answer = json.loads(result.stdout)

    assert answer["serve"]["exit"] == 0
    assert answer["serve"]["replies"] == ["echo:one\n", "echo:two\n", "echo:\n", 300006, "echo:café\n", "bye\n", ""]
    assert answer["serve"]["stdout"] == lines("sent: ok()", "sent: ok()", "sent: ok()", "sent: ok()", "sent: ok()",
                                              "ended: process: end of input", "bye: ok()")
    assert answer["idle"]["stdout"] == lines('first: error("network: operation timed out")',
                                             'second: error("process: channel is closed")',
                                             'send: error("process: channel is closed")')
    assert answer["idle"]["waited"] is True
    bare = lines('read: error("process: no parent channel")',
                 'send: error("process: no parent channel")',
                 'zero: error("network: timeout must be positive milliseconds")')
    for name in ("bare", "bare_marker_only", "bare_marker_pair_only"):
        assert answer[name]["stdout"] == bare, name
    for name in ("serve", "idle", "bare", "bare_marker_only", "bare_marker_pair_only"):
        assert answer[name]["exit"] == 0, name


def test_parent_side_send_read_available_close_timeouts_and_limits(bytecode, node):
    def ask(mode):
        """Run the program in `mode`; it spawns the peer as its child."""
        result = run_vm(bytecode, "--allow-run", args=[mode, node, PEER])
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
        'printed: ok("marker=None\\n")', 'not captured: error("process: output is not captured")')


def test_a_child_ends_when_its_parent_is_killed(tmp_path, request, adopt, node):
    """Linux and macOS: the child reads the end of input; Windows: libuv's job object ends it with the VM."""
    source = tmp_path / "parent.agc"
    source.write_text(PARENT_PROGRAM, encoding="utf-8")
    vm = adopt(start_vm(compile_agc(source, tmp_path / "parent.agcb"), node, PEER, flags=["--allow-run"]))
    pid = vm.next_line(WAIT).strip()
    request.addfinalizer(lambda: kill_process(pid))
    assert process_alive(pid)
    vm.process.kill()
    vm.wait(WAIT)
    assert wait_until(lambda: not process_alive(pid), WAIT, 0.1), "the child outlived its parent"
