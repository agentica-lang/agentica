"""The child-channel protocol of `--agentica-test`, driven by an independent peer."""
import json

import pytest

from tests.agentica_test import FIXTURES, UNDER_WINE, channel_peer, compile_agc, run, vm_binary


@pytest.mark.skipif(UNDER_WINE, reason="Wine runs the Windows binary, which a Linux peer cannot give two pipes")
def test_peer_drives_a_test_file_over_the_child_channel(tmp_path):
    """Check indexes, records, free stdin and stdout.

    The peer is Python where the channel is a socket pair, and Node on Windows, where it is two pipes at descriptors 3
    and 4 that Python cannot give to a child (tests/fixtures/child_channel.js)."""
    bytecode = compile_agc(FIXTURES / "test-protocol-peer.agc", tmp_path / "test-protocol-peer.agcb")
    result = run([*channel_peer("test-protocol-peer"), vm_binary(), bytecode])
    assert result.code == 0, result.stderr
    answer = json.loads(result.stdout)
    names = answer["names"]
    assert names[:3] == ["stdin is the test's own", "a record-shaped line is output", "a partial line is output"]
    assert [len(name) for name in names[3:]] == [1000000]
    assert (answer["list_exit"], answer["run_exit"]) == (0, 0)
    assert (answer["list_stdout"], answer["run_stdout"]) == ("", "")
    assert answer["results"] == [
        ["pass", None, ""],
        ["fail", "RUNTIME-TEST-ASSERTION", "{\"event\":\"pass\"}\n\x1eagentica-bdd {\"event\":\"pass\"}\n"],
        ["pass", None, "partial"],
        ["pass", None, ""],
    ]
    assert (answer["bare_exit"], answer["bare_code"], answer["bare_stdout"]) == (
        1,
        "RUNTIME-TEST-RUN",
        "",
    )
