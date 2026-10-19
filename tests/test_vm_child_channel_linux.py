"""The Linux-only side of the child channel: descriptors pinned to a file, a device, a FIFO, and a shell child.

fixtures/child-channel.agc is the program; fixtures/child-channel-peer.py drives its child side. They need fcntl,
mkfifo, /proc and sh, so the module runs on Linux only; test_vm_child_channel.py has the cases of every system.
"""
import json
import sys

import pytest

from tests.agentica_test import FIXTURES, PYTHON, compile_agc, run, vm_binary

PEER = FIXTURES / "child-channel-peer.py"
# CI lists the module on Linux only; this keeps a developer run of the whole suite on another system clean.
pytestmark = pytest.mark.skipif(sys.platform != "linux", reason="needs /proc, mkfifo and sh")


def lines(*items):
    return "\n".join(items) + "\n"


@pytest.fixture
def bytecode(tmp_path):
    source = FIXTURES / "child-channel.agc"
    return compile_agc(source, tmp_path / (source.stem + ".agcb"))


def test_a_pinned_descriptor_is_refused_unless_it_is_a_channel_and_a_shell_child_gets_none(bytecode):
    result = run([PYTHON, PEER, vm_binary(), bytecode])
    assert result.code == 0, result.stderr
    answer = json.loads(result.stdout)
    spawned = "unset\nclosed\n\n3\nsocket\n\n"
    assert answer["spawning"]["stdout"] == spawned
    assert answer["spawning_marker_only"]["stdout"] == spawned
    assert answer["spawning"]["exit"] == 0
    assert answer["spawning_marker_only"]["exit"] == 0
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
