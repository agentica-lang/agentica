"""The child-channel protocol of `--agentica-test`, driven by an independent peer."""
import json

from tests.agentica_test import FIXTURES, PYTHON, compile_agc, run, vm_binary


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
