"""Term.decode against the independent CBOR peer (tests/fixtures/term_peer.py).

The peer writes the bytes of each value of tests/test_term_encode.py (heads at every size boundary, the edges of every
number type, strings and Bytes, Maps, structs, enums, Optional), each inside a struct of one field; the program decodes
them and writes the value back with Term.encode, which must be the same bytes. Then the errors, with the path of the
first bad value, the limits, and a seeded mutation of valid bytes that must never crash and must never be accepted
when the peer's strict reader refuses them.
"""
import random

import pytest

from tests.agentica_test import FIXTURES, compile_agc, compile_text, run_vm
from tests.fixtures.term_peer import CborMap, F64, PeerError, decode, encode
from tests.test_term_encode import cases, shorten

ENCODE_PROGRAM = (FIXTURES / "vm" / "term-encode.agc").read_text(encoding="utf-8")
TYPES = ENCODE_PROGRAM[ENCODE_PROGRAM.index("struct Entry"):ENCODE_PROGRAM.index("def hex")]

EXTRA_TYPES = """struct Fields
  a: JSON.Field[Int]
  b: JSON.Field[Int]
  c: JSON.Field[Int]
end

struct Pair
  x: Int
  y: String
end

struct Pairs
  items: List[Pair]
end

struct Small
  n: UInt8
end

struct Real
  f: Float
end

struct Real32
  f: Float32
end

struct Lists
  v: List[Int]
end

struct Index
  m: Map[String, Int]
end

struct Hits
  h: Map[Int, Int]
end

struct Tagged
  tag: Optional[String]
end

"""

HELPERS = """def hex(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

def same(name: String, input: Bytes, output: Result[Bytes]) -> Void
  puts("#{name} #{output.unwrap! == input}")
end

def report[T](name: String, decoded: Result[T]) -> Void
  case decoded
    ok(_) -> puts("#{name} ok")
    error(e) -> puts("#{name} #{e.kind} #{e.message}")
  end
end

"""


def field_type(name):
    """The type of the field that holds the case NAME of tests/test_term_encode.py."""
    exact = {"nil": "Nil", "true": "Bool", "false": "Bool", "list nested": "List[List[Int]]",
             "optional none": "Optional[Int]", "optional some": "Optional[Int]", "optional list": "List[Optional[Int]]",
             "map int order": "Map[Int, Int]", "map int negative": "Map[Int, Int]",
             "map string order": "Map[String, List[Int]]", "map empty": "Map[String, Int]",
             "map reinserted": "Map[String, Int]", "struct": "Entry", "struct empty": "Entry",
             "struct list": "List[Entry]", "generic": "Box[List[Int]]", "generic nested": "Box[Box[String]]",
             "enum circle": "Shape", "enum rect": "Shape", "enum empty": "Shape", "enum list": "List[Shape]",
             "uint8 200": "UInt8", "int8 -128": "Int8", "list empty": "List[Int]", "int min": "Int"}
    if name in exact:
        return exact[name]
    prefixes = [("int ", "Int"), ("uint64 ", "UInt64"), ("float32 ", "Float32"), ("float ", "Float"),
                ("string ", "String"), ("bytes ", "Bytes"), ("list ", "List[Int]")]
    return next(kind for prefix, kind in prefixes if name.startswith(prefix))


def wrapped(item):
    return encode(CborMap([("v", item)]))


def read_back_cases():
    """(name, struct or enum to decode, its declaration or "", the bytes, the bytes that Term.encode writes back)."""
    out = []
    for index, (name, item) in enumerate(cases()):
        data = wrapped(item)
        out.append((name, f"W{index}", f"struct W{index}\n  v: {field_type(name)}\nend\n\n", data, data))
    canonical = encode(CborMap([("x", 1), ("y", "s")]))
    out += [
        ("fields", "Fields", "", encode(CborMap([("a", ["Absent", []]), ("b", ["Null", []]), ("c", ["Value", [3]])])),
         None),
        ("root enum circle", "Shape", "", encode(["Circle", [F64.of(1.5)]]), None),
        ("root enum rect", "Shape", "", encode(["Rect", [2, -3]]), None),
        ("root enum empty", "Shape", "", encode(["Empty", []]), None),
        ("keys in another order", "Pair", "", encode(CborMap([("y", "s"), ("x", 1)])), canonical),
        ("extra keys are ignored", "Pair", "",
         encode(CborMap([("z", [1, CborMap([("k", [None, True, F64.of(1.5), b"b", "t"])])]), ("x", 1), ("y", "s"),
                         ("w", CborMap())])), canonical),
    ]
    return [(name, root, decl, data, data if back is None else back) for name, root, decl, data, back in out]


def read_back_program(table):
    out = [TYPES, EXTRA_TYPES, "".join(decl for _, _, decl, _, _ in table), HELPERS]
    parts = [table[at:at + 20] for at in range(0, len(table), 20)]
    for number, part in enumerate(parts):
        out.append(f"def part{number}() -> Void\n")
        for name, root, _, data, back in part:
            wanted = "input" if back == data else f'hex("{back.hex()}")'
            out.append(
                f'  input = hex("{data.hex()}")\n'
                f"  case Term.decode(input, {root})\n"
                f'    ok(value) -> same("{name}", {wanted}, Term.encode(value))\n'
                f'    error(e) -> puts("{name} error #{{e.message}}")\n'
                f"  end\n\n")
        out.append("end\n\n")
    out.append("def main() -> Void\n" + "".join(f"  part{n}()\n" for n in range(len(parts))) + "end\n")
    return "".join(out)


def test_term_decode_reads_what_the_peer_writes_and_writes_it_back(tmp_path):
    table = read_back_cases()
    result = run_vm(compile_text(read_back_program(table), "read_back", tmp_path))
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [f"{name} true" for name, *_ in table]


# (name, the type, the bytes, the message of the error): the path is the first bad value.
ERRORS = [
    ("empty", "Pair", b"", "$: unexpected end of data"),
    ("trailing", "Pair", encode(CborMap([("x", 1), ("y", "s")])) + b"\x00", "$: trailing bytes after the value"),
    ("not a map", "Pair", encode([1]), "$: expected struct Pair"),
    ("wrong field type", "Pair", encode(CborMap([("x", "a"), ("y", "s")])), "x: expected signed 64-bit Int"),
    ("missing field", "Pair", encode(CborMap([("x", 1)])), '$: missing field "y"'),
    ("duplicate field", "Pair", encode(CborMap([("x", 1), ("x", 2), ("y", "s")])), '$: duplicate field "x"'),
    ("key that is not text", "Pair", encode(CborMap([(1, 1)])), "$: expected String key"),
    ("head longer than needed", "Pair", b"\xa2\x61x\x18\x01\x61y\x61s", "x: head is not the shortest form"),
    ("indefinite array", "Lists", b"\xa1\x61v\x9f\x01\xff", "v: indefinite lengths are not allowed"),
    ("tag", "Pair", b"\xa2\x61x\xc1\x01\x61y\x61s", "x: tags are not allowed"),
    ("Int past 2^63", "Pair", b"\xa2\x61x\x1b\x80\x00\x00\x00\x00\x00\x00\x00\x61y\x61s", "x: expected signed 64-bit Int"),
    ("UInt8 256", "Small", encode(CborMap([("n", 256)])), "n: expected UInt8 from 0 to 255"),
    ("Float from a Float32", "Real", b"\xa1\x61f\xfa\x3f\xc0\x00\x00", "f: expected Float"),
    ("Float32 from a Float", "Real32", encode(CborMap([("f", F64.of(1.5))])), "f: expected Float32"),
    ("NaN with a payload", "Real", b"\xa1\x61f\xfb\x7f\xf8\x00\x00\x00\x00\x00\x01", "f: NaN is not the canonical one"),
    ("text that is not UTF-8", "Pair", b"\xa2\x61x\x01\x61y\x62\xc3\x28", "y: invalid UTF-8"),
    ("text past the data", "Pair", b"\xa2\x61x\x01\x61y\x78\xff", "y: unexpected end of data"),
    ("duplicate Map key", "Index", b"\xa1\x61m\xa2\x61a\x01\x61a\x02", 'm["a"]: duplicate key'),
    ("String key for an Int Map", "Hits", encode(CborMap([("h", CborMap([("a", 1)]))])), "h: expected signed 64-bit Int"),
    ("unknown tag", "Shape", encode(["Triangle", []]), '$: unknown tag "Triangle"'),
    ("variant with too few values", "Shape", encode(["Rect", [1]]), "$: expected 2 values"),
    ("payload of the wrong type", "Shape", encode(["Circle", ["x"]]), "values[0]: expected Float"),
    ("enum array of one", "Shape", encode(["Empty"]), "$: expected array of 2 items"),
    ("enum that is not an array", "Shape", encode(CborMap()), "$: expected enum Shape"),
    ("path through a list", "Pairs", encode(CborMap([("items", [CborMap([("x", 1), ("y", "s")]),
                                                              CborMap([("x", 1), ("y", 2)])])])), "items[1].y: expected String"),
    ("Optional", "Tagged", encode(CborMap([("tag", 5)])), "tag: expected String or nil"),
    ("bad value of an ignored key", "Pair", b"\xa3\x61x\x01\x61y\x61s\x61z\x9f\xff", '["z"]: indefinite lengths are not allowed'),
]


def error_program(table):
    out = [TYPES, EXTRA_TYPES, HELPERS, "def main() -> Void\n"]
    out += [f'  report("{name}", Term.decode(hex("{data.hex()}"), {root}))\n' for name, root, data, _ in table]
    return "".join(out) + "end\n"


def test_term_decode_errors_name_the_path_of_the_first_bad_value(tmp_path):
    table = ERRORS
    result = run_vm(compile_text(error_program(table), "errors", tmp_path))
    assert result.code == 0, result.stderr
    got = result.stdout.splitlines()
    assert got == [f"{name} term.decode {message}" for name, _, _, message in table]


def test_the_limits_of_depth_and_of_values_name_the_path_of_the_value_past_them(tmp_path):
    result = run_vm(compile_agc(FIXTURES / "term" / "decode-limits.agc", tmp_path / "limits.agcb"))
    assert result.code == 0, result.stderr
    deep = ".".join(["next"] * 10000) + ": nested deeper than 10000 levels"
    items = "values[3999998]: more than 4000000 values"
    assert result.stdout.splitlines() == [
        "depth 10000 ok true",
        f"depth 10001 term.decode {len(deep)} {shorten(deep)}",
        "values below ok 3999998",
        f"values at term.decode {len(items)} {shorten(items)}",
    ]


SIZE_PROGRAM = """struct Numbers
  values: List[Int]
end

def repeat(unit: Bytes, times: Int) -> Bytes
  out = Bytes.from_list([]).unwrap!
  piece = unit
  left = times
  while left > 0
    if left % 2 == 1
      out = Bytes.concat(out, piece)
    end

    piece = Bytes.concat(piece, piece)
    left = left / 2
  end

  out
end

def main() -> Void
  zeros = repeat(OpenSSL.Digest.hexdecode("00").unwrap!, SIZE)
  case Term.decode(zeros, Numbers)
    ok(_) -> puts("ok")
    error(e) -> puts(e.message)
  end
end
"""


@pytest.mark.slow
def test_input_past_64_mib_is_refused_before_it_is_read(tmp_path):
    result = run_vm(compile_text(SIZE_PROGRAM.replace("SIZE", str(2**26 + 1)), "size", tmp_path))
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == ["$: larger than 67108864 bytes"]


FUZZ_TYPE = "Entry"
FUZZ_SEEDS = [
    CborMap([("id", 7), ("hits", CborMap([(2, 1), (1, 5)])), ("names", CborMap([("k", 9)])), ("raw", bytes([1, 2])),
             ("score", F64.of(1.5)), ("ratio", None), ("big", 2**63), ("tag", "t"), ("nothing", None)]),
    CborMap([("id", -7), ("hits", CborMap()), ("names", CborMap()), ("raw", b""), ("score", F64.of(-0.0)),
             ("ratio", None), ("big", 0), ("tag", None), ("nothing", None)]),
]
FUZZ_PROGRAM_TYPES = """struct Entry
  id: Int
  hits: Map[Int, Int]
  names: Map[String, UInt8]
  raw: Bytes
  score: Float
  ratio: Nil
  big: UInt64
  tag: Optional[String]
  nothing: Nil
end

"""


def mutate(data, rng):
    data = bytearray(data)
    for _ in range(rng.choice([1, 1, 2, 3])):
        kind = rng.choice(["flip", "set", "drop", "insert", "cut"])
        at = rng.randrange(len(data)) if data else 0
        if kind == "flip" and data:
            data[at] ^= 1 << rng.randrange(8)
        elif kind == "set" and data:
            data[at] = rng.choice([0x00, 0x18, 0x1F, 0x7F, 0x9F, 0xA0, 0xBF, 0xC0, 0xF6, 0xF9, 0xFA, 0xFB, 0xFF])
        elif kind == "drop" and data:
            del data[at]
        elif kind == "insert":
            data.insert(at, rng.randrange(256))
        elif kind == "cut" and data:
            del data[at:]
    return bytes(data)


def test_a_mutation_of_valid_bytes_never_crashes_and_never_passes_what_the_peer_refuses(tmp_path):
    rng = random.Random(994)
    inputs = [encode(seed) for seed in FUZZ_SEEDS]
    inputs += [mutate(rng.choice(inputs[:2]), rng) for _ in range(400)]
    program = FUZZ_PROGRAM_TYPES + HELPERS + """def try_line(line: String) -> Void
  case Term.decode(hex(line.trim), Entry)
    ok(value) -> puts("ok #{OpenSSL.Digest.hexencode(Term.encode(value).unwrap!)}")
    error(_) -> puts("error")
  end
end

def main() -> Void
  while true
    case IO.gets
      ok(line) -> try_line(line)
      error(_) -> return
    end
  end
end
"""
    stdin = "".join(data.hex() + "\n" for data in inputs).encode()
    result = run_vm(compile_text(program, "fuzz", tmp_path), stdin=stdin)
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert len(lines) == len(inputs)
    accepted = 0
    for data, line in zip(inputs, lines):
        if line == "error":
            continue
        accepted += 1
        try:
            decode(data)
        except PeerError:
            pytest.fail(f"the VM accepted {data.hex()}, which the peer refuses")
        assert line == "ok " + data.hex() or decode(bytes.fromhex(line[3:])) is not None
    assert accepted >= 2
