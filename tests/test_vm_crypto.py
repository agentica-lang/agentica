"""Crypto.sha256 against Python's hashlib, on every system.

The peer program (tests/fixtures/crypto-peer.agc) hashes all of its stdin; the
inputs cover the SHA-256 padding boundaries (55, 56 and 64 bytes), inputs of
several blocks and 1 MiB. The bad-input cases check the code and the span of the
diagnostic.
"""
import hashlib
import json
import random

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

SIZES = [0, 1, 3, 55, 56, 63, 64, 65, 119, 120, 128, 1000, 4096 + 7, 1024 * 1024]


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    return compile_agc(FIXTURES / "crypto-peer.agc", tmp_path_factory.mktemp("crypto") / "crypto-peer.agcb")


@pytest.mark.parametrize("size", SIZES)
def test_sha256_matches_hashlib(peer, size):
    # Every byte value appears in the larger inputs; the seed keeps a failure reproducible.
    data = random.Random(size).randbytes(size)
    result = run_vm(peer, stdin=data)
    assert result.code == 0, result.stderr
    assert json.loads(result.stdout) == list(hashlib.sha256(data).digest())


@pytest.mark.parametrize("bad", ["256", "-1", "1048576"])
def test_sha256_rejects_a_value_that_is_not_a_byte(tmp_path, bad):
    source = tmp_path / "bad.agc"
    source.write_text("def main() -> Void\n  puts(Crypto.sha256([1, %s, 3]))\nend\n" % bad)
    result = run_vm(compile_agc(source, tmp_path / "bad.agcb"), "--json")
    assert result.code == 1
    diagnostic = json.loads(result.stderr.strip().split("\n")[-1])
    assert diagnostic["code"] == "RUNTIME-INVALID-NUMBER"
    span = diagnostic["range"]
    # The span is the list argument, from "[" to past "]".
    assert (span["start"]["line"], span["start"]["column"]) == (2, 22)
    assert (span["end"]["line"], span["end"]["column"]) == (2, 22 + len("[1, %s, 3]" % bad))
