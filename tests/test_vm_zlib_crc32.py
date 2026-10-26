"""Zlib.crc32 against Python's binascii, on every system.

The checksum is the zlib CRC32 (RFC 1952, the ZIP polynomial): a pure
function of its byte list and seed, with no handle and no shared state.
The peer hashes what it reads on stdin with the seed of argv[0] ("none" leaves the seed out, so the default of 0
applies), so the
empty input, NUL bytes, binary bytes and 1 MiB inputs all go through the
same path as the fixed check vector ("123456789" from seed 0 is
3421780262). Incremental calls chain the previous result as the next seed;
empty input returns the seed unchanged, even 0xFFFFFFFF (zlib would reset
an empty call to zero, so the VM never hands it one).

The refusals are the call's error Result (bad bytes, a seed outside
0..4294967295, more than 1 MiB of input), while a wrong type or arity is
a checker diagnostic: the tests assert the code and the span, never the
message.
"""
import binascii
import json
import random

import pytest

from tests.agentica_test import cli, compile_agc, run, run_vm, vm_environment
from tests.spec_support import check_diagnostic as problem

# The peer of every value case: argv[0] is the seed, stdin is the bytes.
CRC_PEER = (
    "def main() -> Void\n"
    "  seed_text = System.args()[0]\n"
    "  data: List[Int] = []\n"
    "  chunk = IO.read_bytes(1048576).unwrap!\n"
    "  while chunk.size > 0\n"
    "    data = data.concat(chunk)\n"
    "    chunk = IO.read_bytes(1048576).unwrap!\n"
    "  end\n"
    "  if seed_text == \"none\"\n"
    "    puts(Zlib.crc32(data).unwrap!)\n"
    "  else\n"
    "    puts(Zlib.crc32(data, seed_text.to_i!).unwrap!)\n"
    "  end\n"
    "end\n"
)

CAP_1MIB = 1048576
MAX_SEED = 4294967295


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    source = tmp_path_factory.mktemp("zlib-crc32") / "peer.agc"
    source.write_text(CRC_PEER, encoding="utf-8")
    return compile_agc(source, source.with_suffix(".agcb"))


def crc_of(peer, data, seed):
    result = run_vm(peer, args=[str(seed)], stdin=data)
    assert result.code == 0, result.stderr
    return int(result.stdout.strip())


def test_crc32_without_a_seed_starts_from_zero(peer):
    data = bytes(range(256)) * 3
    assert crc_of(peer, data, "none") == binascii.crc32(data)
    assert crc_of(peer, b"", "none") == 0


def test_crc32_of_the_check_vector(peer):
    assert crc_of(peer, b"123456789", 0) == 3421780262


@pytest.mark.parametrize("size", [0, 1, 2, 3, 7, 55, 64, 65, 1000, 65537, CAP_1MIB])
def test_crc32_matches_binascii(peer, size):
    data = random.Random(size).randbytes(size)
    assert crc_of(peer, data, 0) == binascii.crc32(data, 0) & 0xFFFFFFFF


@pytest.mark.parametrize("seed", [0, 1, 12345, 3421780262, MAX_SEED])
def test_crc32_matches_binascii_at_many_seeds(peer, seed):
    data = random.Random(seed).randbytes(1000)
    assert crc_of(peer, data, seed) == binascii.crc32(data, seed) & 0xFFFFFFFF


@pytest.mark.parametrize("seed", [0, 1, 12345, MAX_SEED])
def test_crc32_of_empty_input_returns_the_seed(peer, seed):
    assert crc_of(peer, b"", seed) == seed


def test_crc32_chains_across_calls(peer):
    data = random.Random(99).randbytes(1000)
    first = crc_of(peer, data[:333], 0)
    assert first == binascii.crc32(data[:333], 0) & 0xFFFFFFFF
    second = crc_of(peer, data[333:700], first)
    assert second == binascii.crc32(data[333:700], first) & 0xFFFFFFFF
    assert crc_of(peer, data[700:], second) == binascii.crc32(data, 0) & 0xFFFFFFFF


def test_crc32_of_an_empty_middle_chunk_keeps_the_chain(peer):
    data = random.Random(7).randbytes(100)
    middle = crc_of(peer, b"", crc_of(peer, data[:50], 0))
    assert crc_of(peer, data[50:], middle) == binascii.crc32(data, 0) & 0xFFFFFFFF


def run_body(tmp_path, name, body):
    source = tmp_path / name
    source.write_text(body, encoding="utf-8")
    return run(cli() + [str(source)], env=vm_environment())


def test_crc32_rejects_a_seed_outside_0_to_2_to_the_32(tmp_path):
    for seed in ("-1", "4294967296", "99999999999"):
        result = run_body(tmp_path, "seed-%s.agc" % seed,
                          "def main() -> Void\n  puts(Zlib.crc32([1, 2, 3], %s))\nend\n" % seed)
        assert result.code == 0, result.stderr
        assert result.stdout == 'error("zlib: seed must be between 0 and 4294967295")\n', result.stdout


def test_crc32_rejects_bytes_outside_0_to_255(tmp_path):
    for bad in ("256", "-1"):
        result = run_body(tmp_path, "byte-%s.agc" % bad,
                          "def main() -> Void\n  puts(Zlib.crc32([1, %s, 3], 0))\nend\n" % bad)
        assert result.code == 0, result.stderr
        assert result.stdout == 'error("zlib: bytes must be between 0 and 255")\n', result.stdout


def test_crc32_rejects_more_than_1_mib_of_input(tmp_path):
    body = ("def main() -> Void\n"
            "  data = List.concat(List.repeat(0, 600000), List.repeat(0, 448577))\n"
            "  puts(Zlib.crc32(data, 0))\n"
            "end\n")
    result = run_body(tmp_path, "huge.agc", body)
    assert result.code == 0, result.stderr
    assert result.stdout == 'error("zlib: input exceeds 1048576 bytes")\n', result.stdout


def test_crc32_accepts_exactly_1_mib_of_input(peer):
    assert crc_of(peer, bytes(CAP_1MIB), 0) == binascii.crc32(bytes(CAP_1MIB), 0) & 0xFFFFFFFF


def test_crc32_accepts_the_seed_corners(peer):
    assert crc_of(peer, b"abc", 0) == binascii.crc32(b"abc", 0) & 0xFFFFFFFF
    assert crc_of(peer, b"abc", MAX_SEED) == binascii.crc32(b"abc", MAX_SEED) & 0xFFFFFFFF


def check_code(text, code, tmp_path):
    found = problem(text, tmp_path)
    assert found is not None, "expected %s for:\n%s" % (code, text)
    assert found["code"] == code, text
    return found


def test_crc32_checks_the_types_of_both_arguments(tmp_path):
    found = check_code("def main() -> Void\n  puts(Zlib.crc32(\"abc\", 0))\nend\n", "CHECK-TYPE-MISMATCH",
                       tmp_path)
    assert (found["range"]["start"]["line"], found["range"]["start"]["column"]) == (2, 19), found
    found = check_code("def main() -> Void\n  puts(Zlib.crc32([1], 0.5))\nend\n", "CHECK-TYPE-MISMATCH",
                       tmp_path)
    assert (found["range"]["start"]["line"], found["range"]["start"]["column"]) == (2, 24), found


def test_crc32_checks_the_arity(tmp_path):
    found = check_code("def main() -> Void\n  puts(Zlib.crc32())\nend\n", "CHECK-ARITY", tmp_path)
    assert (found["range"]["start"]["line"], found["range"]["start"]["column"]) == (2, 8), found
    found = check_code("def main() -> Void\n  puts(Zlib.crc32([1], 0, 0))\nend\n", "CHECK-ARITY", tmp_path)
    assert (found["range"]["start"]["line"], found["range"]["start"]["column"]) == (2, 8), found


def test_crc32_has_the_catalog_signature():
    result = run(cli() + ["help", "Zlib.crc32", "--json"], env=vm_environment())
    assert result.code == 0, result.stderr
    entry = json.loads(result.stdout)
    assert entry["name"] == "Zlib.crc32"
    assert entry["signature"] == "Zlib.crc32(data: List[Int], seed: Int = 0) -> Result[Int]", entry
    assert entry["arity"] == 2
    assert entry["parameters"] == [
        {"name": "data", "type": "List[Int]"},
        {"name": "seed", "type": "Int", "default": "0"},
    ], entry
