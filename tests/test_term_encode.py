"""Term.encode against an independent CBOR peer (tests/fixtures/term_peer.py, written from RFC 8949 and tested against
its appendix A by tests/test_term_peer.py).

tests/fixtures/vm/term-encode.agc prints the hex of each value; the CBOR that the peer writes for the same value, in the
same order, must be those bytes, and the peer's strict decoder must read them back as that value. Edge values only:
the heads at each size boundary, the largest and smallest Int and UInt64, Float and Float32 bits (-0.0, the infinities,
a NaN with a payload, subnormals), strings and Bytes at the sizes of each head, Maps in insertion order. The limits of
tests/fixtures/vm/term-limits.agc are computed here from the rules of the format.
"""
import pytest

from tests.agentica_test import FIXTURES, compile_agc, compile_text, run_vm
from tests.fixtures.term_peer import CborMap, F32, F64, decode, encode

CANONICAL_NAN64 = 0x7FF8000000000000
CANONICAL_NAN32 = 0x7FC00000
INT_MAX = 2**63 - 1
SIZES = [0, 1, 23, 24, 255, 256, 65535, 65536]


def entry(id_, hits, names, raw, tag, nothing=None):
    return CborMap([("id", id_), ("hits", CborMap(hits)), ("names", CborMap(names)), ("raw", raw), ("tag", tag),
                    ("nothing", nothing)])


def cases():
    """(name, item) in the order of the program."""
    out = []
    for n in [0, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296, INT_MAX]:
        out.append((f"int {n}", n))
    for n in [-1, -24, -25, -256, -257, -65536, -65537, -4294967296, -4294967297, -INT_MAX]:
        out.append((f"int {n}", n))
    out.append(("int min", -(2**63)))
    for n in [0, 24, 256, 65536, 4294967296, INT_MAX]:
        out.append((f"uint64 {n}", n))
    out += [("uint64 2^63", 2**63), ("uint64 max", 2**64 - 1), ("uint8 200", 200), ("int8 -128", -128)]
    for bits in [0, 1, 4607182418800017408, 4609434218613702656, 4608083138725491507, 9218868437227405312]:
        out.append((f"float {bits}", F64(bits)))
    out += [("float -0.0", F64(0x8000000000000000)), ("float -inf", F64(0xFFF0000000000000)),
            ("float nan payload", F64(CANONICAL_NAN64)), ("float nan negative", F64(CANONICAL_NAN64)),
            ("float max", F64(0x7FEFFFFFFFFFFFFF)), ("float min subnormal", F64(1))]
    for bits in [0, 1, 1065353216, 1203982336, 2139095039, 2139095040, 2143289344, 2143289345]:
        out.append((f"float32 {bits}", F32(CANONICAL_NAN32 if bits in (2143289344, 2143289345) else bits)))
    out += [("float32 -0.0", F32(0x80000000)), ("float32 -inf", F32(0xFF800000))]
    for size in SIZES:
        out.append((f"string {size}", "a" * size))
        out.append((f"bytes {size}", bytes([7]) * size))
    out += [("string ü", "ü"), ("string water", "水"), ("string quote", '"\\')]
    out += [("nil", None), ("true", True), ("false", False), ("list empty", [])]
    for size in [1, 23, 24, 255, 256, 65536]:
        out.append((f"list {size}", [1] * size))
    out += [("list nested", [[1], [2, 3], []]), ("optional none", None), ("optional some", 5),
            ("optional list", [1, None]), ("map int order", CborMap([(3, 4), (1, 2)])),
            ("map int negative", CborMap([(-1, 1), (0, 2), (1, 3)])),
            ("map string order", CborMap([("b", [1]), ("a", [2, 3])])), ("map empty", CborMap()),
            ("map reinserted", CborMap([("y", 2), ("x", 3)]))]
    absent = entry(-7, [], [], b"", None)
    out += [("struct", entry(7, [(2, 1), (1, 5)], [("k", 9)], bytes([1, 2]), "t")), ("struct empty", absent),
            ("struct list", [absent, absent]), ("generic", CborMap([("value", [1, 2])])),
            ("generic nested", CborMap([("value", CborMap([("value", "x")]))])),
            ("enum circle", ["Circle", [F64.of(1.5)]]), ("enum rect", ["Rect", [2, -3]]), ("enum empty", ["Empty", []]),
            ("enum list", [["Empty", []], ["Rect", [1, 2]]])]
    return out


@pytest.fixture(scope="module")
def printed(tmp_path_factory):
    bytecode = compile_agc(FIXTURES / "vm" / "term-encode.agc", tmp_path_factory.mktemp("term") / "encode.agcb")
    result = run_vm(bytecode)
    assert result.code == 0, result.stderr
    lines = [line.rsplit(" ", 1) for line in result.stdout.splitlines()]
    return dict(lines), [name for name, _ in lines]


def test_the_program_prints_the_cases_in_order(printed):
    assert printed[1] == [name for name, _ in cases()]


@pytest.mark.parametrize("name,item", cases(), ids=[name for name, _ in cases()])
def test_term_encode_is_the_cbor_that_the_peer_writes(printed, name, item):
    assert printed[0][name] == encode(item).hex()
    assert decode(bytes.fromhex(printed[0][name])) == item


def shorten(text):
    return text if len(text) <= 100 else text[:20] + "..." + text[-60:]


def test_the_limits_of_depth_and_of_values_name_the_path_of_the_value_past_them(tmp_path):
    bytecode = compile_agc(FIXTURES / "vm" / "term-limits.agc", tmp_path / "limits.agcb")
    result = run_vm(bytecode)
    assert result.code == 0, result.stderr
    deep = ".".join(["next"] * 10000) + ": nested deeper than 10000 levels"
    items = ": more than 4000000 values"
    map_path = 'by_name["k\\"q"][3999996]'
    enum_path = "items[0].values[0][3999996]"
    # A level is the map head and its one field name, "next", and the innermost level is followed by null.
    expected = [
        f"depth 10000 ok {10000 * 6 + 1}",
        f"depth 10001 term.encode {len(deep)} {shorten(deep)}",
        "list below ok 4000004",
        f"list at term.encode {len('[3999999]' + items)} [3999999]{items}",
        # The struct, the Map, its key and its List are four values; each item after them is one more.
        f"struct map list term.encode {len(map_path + items)} {map_path}{items}",
        f"list enum term.encode {len(enum_path + items)} {enum_path}{items}",
    ]
    assert result.stdout.splitlines() == expected


@pytest.mark.slow
@pytest.mark.parametrize("size,ok", [(67108859, True), (67108860, False)])
def test_the_size_limit_of_64_mib_is_the_last_byte_of_the_output(tmp_path, size, ok):
    program = f"""def main() -> Void
  case Term.encode("a" * {size})
    ok(data) -> puts("ok #{{data.size}}")
    error(e) -> puts(e.message)
  end
end
"""
    result = run_vm(compile_text(program, "size", tmp_path))
    assert result.code == 0, result.stderr
    assert result.stdout == ("ok 67108864\n" if ok else "$: larger than 67108864 bytes\n")
