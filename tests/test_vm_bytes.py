"""Bytes against Python's bytes, on generated inputs.

tests/fixtures/bytes-peer.agc answers one case a line: from_list, to_a, at, slice, take, drop, +, Bytes.concat, `==` and
`!=`, and how many keys a Set and a Map keep (the hash and the key equality). The expected answers come from Python's
bytes and set. The inputs cover the empty value, one byte, every byte value, equal values that are separate objects, and
values that differ in one byte, in the length or in the last byte only.
"""
import random

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

SEED = 805
SIZES = [0, 1, 2, 3, 31, 32, 33, 255, 256, 1000]


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    return compile_agc(FIXTURES / "bytes-peer.agc", tmp_path_factory.mktemp("bytes") / "bytes-peer.agcb")


def answers(peer, lines):
    result = run_vm(peer, stdin="".join(line + "\n" for line in lines))
    assert result.code == 0, result.stderr
    found = result.stdout.split("\n")
    assert found.pop() == ""
    assert len(found) == len(lines)
    return found


def values(rng):
    """Byte strings of the sizes above, with every byte value among them, then near copies of the first ones."""
    made = [rng.randbytes(size) for size in SIZES]
    made.append(bytes(range(256)))
    made.append(bytes([0, 255]) * 3)
    for source in made[3:7]:
        flipped = bytearray(source)
        flipped[-1] ^= 1
        made.append(bytes(flipped))
        made.append(source[:-1])
        made.append(source + b"\x00")
    return made


def test_builders_and_cuts_match_python(peer):
    rng = random.Random(SEED)
    data = values(rng)
    lines = []
    expected = []
    for left in data:
        right = rng.choice(data)
        third = rng.choice(data)
        lines += [f"plus,{left.hex()},{right.hex()}", f"concat,{left.hex()},{right.hex()},{third.hex()}"]
        expected += [(left + right).hex(), (left + right + third).hex()]
        start = rng.randint(0, len(left))
        length = rng.randint(0, len(left) - start)
        count = rng.randint(0, len(left) + 3)
        lines += [f"slice,{left.hex()},{start},{length}", f"take,{left.hex()},{count}", f"drop,{left.hex()},{count}"]
        expected += [left[start:start + length].hex(), left[:count].hex(), left[count:].hex()]
        lines.append(f"to_a,{left.hex()}")
        expected.append(" ".join(str(byte) for byte in left))
        if left:
            index = rng.randrange(len(left))
            lines.append(f"at,{left.hex()},{index}")
            expected.append(f"{left[index]} {left[index]}")
    assert answers(peer, lines) == expected


def test_equality_and_keys_match_python(peer):
    rng = random.Random(SEED + 1)
    data = values(rng)
    lines = []
    expected = []
    for left in data:
        # A copy is a separate object with the same bytes; the others usually differ.
        for right in (bytes(bytearray(left)), rng.choice(data)):
            lines.append(f"equal,{left.hex()},{right.hex()}")
            expected.append(f"{str(left == right).lower()} {str(left != right).lower()}")
        group = [left, bytes(bytearray(left)), rng.choice(data), rng.choice(data)]
        lines.append("items," + ",".join(item.hex() for item in group))
        expected.append(f"{len(set(group))} {len(set(group))}")
    assert answers(peer, lines) == expected


def test_from_list_accepts_only_bytes(peer):
    rng = random.Random(SEED + 2)
    lines = ["from_list"]
    expected = [""]
    for size in SIZES[1:]:
        good = [rng.randrange(256) for _ in range(size)]
        lines.append("from_list," + ",".join(map(str, good)))
        expected.append(bytes(good).hex())
        for bad in (256, -1, 1 << 40):
            mixed = list(good)
            mixed[rng.randrange(size)] = bad
            lines.append("from_list," + ",".join(map(str, mixed)))
            expected.append("error")
    assert answers(peer, lines) == expected
