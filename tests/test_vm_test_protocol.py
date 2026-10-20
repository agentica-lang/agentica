"""The child-channel protocol of `--agentica-test`, driven by an independent peer."""
import json

from tests.agentica_test import FIXTURES, PYTHON, WINDOWS, compile_agc, known_issue, run, vm_binary


# The Windows channel is two pipes at descriptors 3 and 4, which this Python peer cannot give to the VM (issue 432);
# `agentica test` (tests/test_bdd.py) runs the same protocol end to end on Windows.
@known_issue(WINDOWS, 432, "the Windows channel is two pipes, which the Python peer cannot pass to the VM")
def test_peer_drives_a_test_file_over_the_child_channel(tmp_path):
    """Check indexes, records, free stdin and stdout."""
    bytecode = compile_agc(FIXTURES / "test-protocol-peer.agc", tmp_path / "test-protocol-peer.agcb")
    result = run([PYTHON, FIXTURES / "test-protocol-peer.py", vm_binary(), bytecode])
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
