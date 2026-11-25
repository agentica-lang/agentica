"""The peer of the Term tests (tests/fixtures/term_peer.py) against the examples of RFC 8949 appendix A, before it
checks the VM: an encoder and a decoder that agree with the RFC on every example of the subset, and a decoder that
refuses what the subset leaves out."""
import pytest

from tests.fixtures.term_peer import CborMap, F32, F64, PeerError, decode, encode

# (hex of the RFC, the item), for the examples of appendix A whose form the subset writes.
EXAMPLES = [
    ("00", 0), ("01", 1), ("0a", 10), ("17", 23), ("1818", 24), ("1819", 25), ("1864", 100), ("1903e8", 1000),
    ("1a000f4240", 1000000), ("1b000000e8d4a51000", 1000000000000), ("1bffffffffffffffff", 2**64 - 1),
    ("3bffffffffffffffff", -(2**64)), ("20", -1), ("29", -10), ("3863", -100), ("3903e7", -1000),
    ("fb3ff199999999999a", F64.of(1.1)), ("fb7e37e43c8800759c", F64.of(1.0e300)), ("fbc010666666666666", F64.of(-4.1)),
    ("fa47c35000", F32.of(100000.0)), ("fa7f7fffff", F32.of(3.4028234663852886e38)),
    ("fa7f800000", F32.of(float("inf"))), ("faff800000", F32.of(float("-inf"))), ("fa7fc00000", F32(0x7fc00000)),
    ("fb7ff0000000000000", F64.of(float("inf"))), ("fbfff0000000000000", F64.of(float("-inf"))),
    ("fb7ff8000000000000", F64(0x7ff8000000000000)),
    ("f4", False), ("f5", True), ("f6", None),
    ("40", b""), ("4401020304", bytes([1, 2, 3, 4])),
    ("60", ""), ("6161", "a"), ("6449455446", "IETF"), ("62225c", '"\\'), ("62c3bc", "ü"), ("63e6b0b4", "水"),
    ("64f0908591", "\U00010151"),
    ("80", []), ("83010203", [1, 2, 3]), ("8301820203820405", [1, [2, 3], [4, 5]]),
    ("98190102030405060708090a0b0c0d0e0f101112131415161718181819", list(range(1, 26))),
    ("a0", CborMap()), ("a201020304", CborMap([(1, 2), (3, 4)])),
    ("a26161016162820203", CborMap([("a", 1), ("b", [2, 3])])),
    ("826161a161626163", ["a", CborMap([("b", "c")])]),
    ("a56161614161626142616361436164614461656145", CborMap([(k, k.upper()) for k in "abcde"])),
]

# Examples of appendix A, and heads written longer than needed, that the strict decoder refuses.
REFUSED = [
    "f90000",  # a half float
    "c11a514b67b0",  # a tag
    "5f42010243030405ff",  # an indefinite byte string
    "9f018202039f0405ffff",  # an indefinite array
    "bf61610161629f0203ffff",  # an indefinite map
    "f0", "f8ff",  # other simple values
    "1800", "190000", "1a00000000", "1b0000000000000000", "1900ff", "1a0000ffff", "1b00000000ffffffff",  # long heads
    "6161ff", "62c328",  # trailing bytes, text that is not UTF-8
    "83010203ff", "8301", "a1", "61",  # cut short or too many items
]


@pytest.mark.parametrize("text,item", EXAMPLES)
def test_the_peer_writes_and_reads_the_examples_of_the_rfc(text, item):
    assert encode(item).hex() == text
    assert decode(bytes.fromhex(text)) == item


@pytest.mark.parametrize("text", REFUSED)
def test_the_peer_refuses_what_the_subset_leaves_out(text):
    with pytest.raises(PeerError):
        decode(bytes.fromhex(text))
