"""The Bytes type through the product CLI: where it may be written, its operators, and the rules that keep it out of
ATS keys, JSON and generic equality. A case is `(program, code, covered text)`: the code of the diagnostic and the
source text its range covers; a program that must check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule

MAIN = "def main() -> Void\n"

CLEAN = [
    # The type in every position: a parameter, a result, a field, an item, a Result, a Map value, a Set element.
    (
        "struct Frame\n  payload: Bytes\nend\n\n"
        "def pass(data: Bytes, parts: List[Bytes], index: Map[String, Bytes]) -> Result[Bytes]\n"
        "  return ok(data)\nend\n\n"
        + MAIN
        + '  frame = Frame(payload: "ab".bytes)\n'
        "  seen: Set[Bytes] = Set.new([frame.payload])\n"
        "  data: Bytes = frame.payload\n"
        "  puts(seen.size)\n"
        "  puts(data.length)\nend\n",
        None,
        None,
    ),
    # The methods, the operators and the loops.
    (
        MAIN + '  b = "abc".bytes\n'
        "  n: Int = b[0] + b.at(1) + b.length + b.size\n"
        "  e: Bool = b.empty? or b == b or b != b\n"
        "  c: Bytes = b + b.slice(0, 1) + b.take(1) + b.drop(1) + Bytes.concat([b, b])\n"
        "  l: List[Int] = b.to_a\n"
        "  r: Result[Bytes] = Bytes.from_list(l)\n"
        "  for byte in b\n    n += byte\n  end\n"
        "  b.each do |byte| puts(byte) end\n"
        "  puts(\"#{b} #{b.inspect} #{n} #{e} #{c.length} #{r.ok?}\")\nend\n",
        None,
        None,
    ),
    # A Map key, a Set item and Test.eq take Bytes.
    (
        MAIN + '  m: Map[Bytes, Int] = {"a".bytes: 1}\n'
        '  s = Set.new(["a".bytes])\n'
        '  puts(m["a".bytes] + s.size)\n'
        '  Test.eq("a".bytes, "a".bytes)\nend\n',
        None,
        None,
    ),
]

REFUSED = [
    # Bytes is a reserved name: no declaration or import alias may take it.
    ("struct Bytes\n  size: Int\nend\n\n" + MAIN + "end\n", "CHECK-REDEFINED-NAME", "struct Bytes\n  size: Int\nend\n"),
    ("enum Bytes\n  A\nend\n\n" + MAIN + "end\n", "CHECK-REDEFINED-NAME", "enum Bytes\n  A\nend\n"),
    ("type Bytes = List[Int]\n\n" + MAIN + "end\n", "CHECK-REDEFINED-NAME", "Bytes"),
    ('import Bytes from "other"\n\n' + MAIN + "end\n", "CHECK-REDEFINED-NAME", 'import Bytes from "other"\n'),
    # An ATS hashes Int and String keys only.
    (MAIN + "  t: ATS[Bytes, Int] = ATS.new()\nend\n", "CHECK-MAP-KEY-TYPE", "Bytes"),
    # JSON has no byte type.
    (MAIN + '  puts(JSON.encode("a".bytes))\nend\n', "CHECK-NOT-ENCODABLE", '"a".bytes'),
    (MAIN + "  m: Map[Bytes, Int] = {}\n  puts(JSON.encode(m))\nend\n", "CHECK-NOT-ENCODABLE", "m"),
    (
        "struct Frame\n  payload: Bytes\nend\n\n" + MAIN + '  puts(JSON.decode("{}", Frame).ok?)\nend\n',
        "CHECK-NOT-DECODABLE",
        "Frame",
    ),
    # An HttpResponse has a Bytes body, so JSON neither writes nor builds it.
    (
        MAIN + '  r = HttpResponse(status: 200, headers: [], body: "a".bytes)\n  puts(JSON.encode(r))\nend\n',
        "CHECK-NOT-ENCODABLE",
        "r",
    ),
    (MAIN + '  puts(JSON.decode("{}", HttpResponse).ok?)\nend\n', "CHECK-NOT-DECODABLE", "HttpResponse"),
    # The help walk for a type with no Bytes ends: the code is the same as for a type that has one.
    (MAIN + "  puts(JSON.encode(1..2))\nend\n", "CHECK-NOT-ENCODABLE", "1..2"),
    (MAIN + '  puts(JSON.decode("{}", Int).ok?)\nend\n', "CHECK-NOT-DECODABLE", "Int"),
    (MAIN + '  puts(JSON.decode("\\"x\\"", Bytes).ok?)\nend\n', "CHECK-NOT-DECODABLE", "Bytes"),
    # Operators take two Bytes, and only == and != compare.
    (MAIN + '  c = "a".bytes + "b"\nend\n', "CHECK-TYPE-MISMATCH", "+"),
    (MAIN + '  c = "a".bytes == "a"\nend\n', "CHECK-TYPE-MISMATCH", "=="),
    (MAIN + '  c = "a".bytes < "b".bytes\nend\n', "CHECK-TYPE-MISMATCH", "<"),
    (MAIN + '  c = "a".bytes[0] + "b".bytes\nend\n', "CHECK-TYPE-MISMATCH", "+"),
    # A list of Bytes has no equality either.
    (
        MAIN + '  a = ["x".bytes]\n  puts(a == ["x".bytes])\nend\n',
        "CHECK-TYPE-MISMATCH",
        "==",
    ),
    # A type variable has no equality, so a Bytes cannot reach EQ through generic code.
    ("def same[T](a: T, b: T) -> Bool\n  return a == b\nend\n\n" + MAIN + "end\n", "CHECK-TYPE-MISMATCH", "=="),
    # Indexing stays off String, and for takes a collection.
    (MAIN + '  c = "abc"[0]\nend\n', "CHECK-NOT-INDEXABLE", '"abc"[0]'),
    (MAIN + "  for byte in 5\n  end\nend\n", "CHECK-NOT-A-LIST", "for byte in 5\n  end\n"),
    # Bytes is immutable and has no List methods.
    (MAIN + '  b = "abc".bytes\n  c = b.map do |x| x end\nend\n', "CHECK-UNKNOWN-METHOD", "b.map do |x| x end"),
    (MAIN + '  b: Bytes = "abc"\nend\n', "CHECK-TYPE-MISMATCH", '"abc"'),
    (MAIN + "  b: Bytes = Bytes.from_list([1])\nend\n", "CHECK-TYPE-MISMATCH", "Bytes.from_list([1])"),
]


@pytest.mark.parametrize(("program", "code", "text"), CLEAN + REFUSED)
def test_bytes_rules(agentica_check, program, code, text):
    assert_rule(agentica_check(program), program, code, text)
