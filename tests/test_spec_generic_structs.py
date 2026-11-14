"""Generic structs (`struct Box[T]`) through the product CLI: the rules and their diagnostic codes and spans.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers.
A program that must check clean has no code.
"""

import json
import urllib.parse

import pytest

from tests.agentica_test import cli, output_lines, run, vm_environment
from tests.spec_support import assert_rule, check_many

BOX = "struct Box[T]\n  value: T\nend\n\n"
BOTH = "struct Both[T]\n  value: T\n  items: List[T]\nend\n\n"
PAIR = "struct Pair[T]\n  a: T\n  b: T\nend\n\n"
INC = "def inc(x: Int) -> Int\n  return x + 1\nend\n\n"


NIL_WALK = "struct W[T]\n  f: JSON.Field[T]\n  rest: List[W[Nil]]\nend\n\n"
NIL_VALUES = ("inner = W(f: JSON.Field.Value(nil), rest: [])", "outer = W(f: JSON.Field.Value(1), rest: [inner])")


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


def declared(*lines: str, header: str = BOX) -> str:
    return header + main(*lines)


RULES = {
    "construction infers T from the value": (declared("b = Box(value: 1)", "_x: Int = b.value"), None, None),
    "T comes from a type annotation for an empty list": (
        declared("b: Box[List[Int]] = Box(value: [])", "puts(b.value.size)"), None, None),
    "T comes from a parameter, a return type and a field": (
        BOX
        + "struct Holder\n  b: Box[List[Int]]\nend\n\n"
        + "def size(b: Box[List[Int]]) -> Int\n  return b.value.size\nend\n\n"
        + "def empty() -> Box[Map[String, Int]]\n  return Box(value: {})\nend\n\n"
        + main("puts(size(Box(value: [])))", "puts(Holder(b: Box(value: [])).b.value.size)", "puts(empty().value.size)"),
        None, None),
    "field access substitutes T": (
        declared("b = Box(value: 1)", 'x: String = b.value'), "CHECK-TYPE-MISMATCH", "b.value"),
    "with keeps T": (declared("b = Box(value: 1)", "puts(b.with(value: 2).value + 1)"), None, None),
    "with checks the new value against T": (
        declared("b = Box(value: 1)", 'c = b.with(value: "x")'), "CHECK-TYPE-MISMATCH", '"x"'),
    "a nested generic struct and a recursive one": (
        "struct Tree[T]\n  value: T\n  kids: List[Tree[T]]\nend\n\n"
        + main("t = Tree(value: 1, kids: [Tree(value: 2, kids: [])])", "puts(t.kids[0].value + 1)"),
        None, None),
    "a repeated type parameter": (
        "struct Box[T, T]\n  value: T\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME",
        "struct Box[T, T]\n  value: T\nend\n"),
    "a reserved type parameter": (
        "struct Box[Int]\n  value: Int\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME",
        "struct Box[Int]\n  value: Int\nend\n"),
    "a field named with of a type parameter": (
        "struct Box[T]\n  with: T\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME", "with: T\n"),
    "a field named with of another type is allowed": (
        "struct Box[T]\n  with: Int\n  value: T\nend\n\n" + main("puts(Box(with: 1, value: 2).with)"), None, None),
    "a type parameter as a Map key": (
        "struct Index[K, V]\n  items: Map[K, V]\nend\n\n" + main("puts(1)"), "CHECK-MAP-KEY-TYPE", "K"),
    "a bare generic struct in a type": (
        BOX + "def f(b: Box) -> Void\n  puts(1)\nend\n\n" + main("puts(1)"), "CHECK-UNKNOWN-TYPE", "Box"),
    "a wrong number of type arguments": (
        BOX + "def f(b: Box[Int, Int]) -> Void\n  puts(1)\nend\n\n" + main("puts(1)"), "CHECK-UNKNOWN-TYPE",
        "Box[Int, Int]"),
    "a type argument must be a type": (
        BOX + "def f(b: Box[Nope]) -> Void\n  puts(1)\nend\n\n" + main("puts(1)"), "CHECK-UNKNOWN-TYPE", "Nope"),
    "Void is not a type argument": (
        BOX + "def f(b: Box[Void]) -> Void\n  puts(1)\nend\n\n" + main("puts(1)"), "CHECK-VOID-TYPE", "Void"),
    "an empty list needs an expected type": (
        declared("b = Box(value: [])"), "CHECK-ENUM-TYPE-INFERENCE", "[]"),
    "a parameter no field mentions cannot be inferred": (
        "struct Tag[T]\n  name: String\nend\n\n" + main('t = Tag(name: "x")'), "CHECK-ENUM-TYPE-INFERENCE",
        'Tag(name: "x")'),
    "a parameter no field mentions comes from the expected type": (
        "struct Tag[T]\n  name: String\nend\n\n" + main('t: Tag[Int] = Tag(name: "x")', "puts(t.name)"), None, None),
    "conflicting field values": (
        declared('p = Pair(a: 1, b: "x")', header=PAIR), "CHECK-TYPE-MISMATCH", '"x"'),
    "the expected type fixes T": (
        declared('b: Box[String] = Box(value: 1)'), "CHECK-TYPE-MISMATCH", "1"),
    "data types print": (declared("puts(Box(value: 1))", "puts(Box(value: 1).inspect)"), None, None),
    "a Fn type argument does not print": (
        declared("puts(Box(value: &inc))", header=BOX + INC), "CHECK-TYPE-MISMATCH", "Box(value: &inc)"),
    "a Fn type argument may be called": (
        declared("b = Box(value: &inc)", "puts(b.value.call(1))", header=BOX + INC), None, None),
    "JSON.encode takes a generic instance": (
        declared("puts(JSON.encode(Box(value: [1])))", "puts(JSON.from(Box(value: 1)).inspect)"), None, None),
    "JSON.encode needs encodable fields after substitution": (
        declared("puts(JSON.encode(Box(value: &inc)))", header=BOX + INC), "CHECK-NOT-ENCODABLE",
        "Box(value: &inc)"),
    "JSON.encode checks the arguments of a nested generic instance": (
        declared("puts(JSON.encode(Box(value: Box(value: &inc))))", header=BOX + INC), "CHECK-NOT-ENCODABLE",
        "Box(value: Box(value: &inc))"),
    "JSON.from checks the arguments of a nested generic instance": (
        declared("puts(JSON.from(Box(value: Box(value: &inc))).inspect)", header=BOX + INC), "CHECK-NOT-ENCODABLE",
        "Box(value: Box(value: &inc))"),
    "JSON.encode checks a Set inside a nested generic instance": (
        declared("puts(JSON.encode(Box(value: Box(value: Set.new([1])))))"), "CHECK-NOT-ENCODABLE",
        "Box(value: Box(value: Set.new([1])))"),
    "JSON.encode checks a generic instance inside the fields of its own struct": (
        "struct Bad[T]\n  v: T\n  rest: List[Bad[Fn[Int, Int]]]\nend\n\n"
        + main("puts(JSON.encode(Bad(v: 1, rest: [])))"), "CHECK-NOT-ENCODABLE", "Bad(v: 1, rest: [])"),
    "JSON.encode ends on a recursion that changes its type argument": (
        "struct Deep[T]\n  v: T\n  rest: List[Deep[List[T]]]\nend\n\n"
        + main("puts(JSON.encode(Deep(v: 1, rest: [])))"), None, None),
    "JSON.encode finds a JSON.Field of Nil behind a struct already on the walk": (
        NIL_WALK + main(*NIL_VALUES, "puts(JSON.encode(outer))"), "CHECK-NOT-ENCODABLE", "outer"),
    "JSON.from finds a JSON.Field of Nil behind a struct already on the walk": (
        NIL_WALK + main(*NIL_VALUES, "puts(JSON.from(outer).inspect)"), "CHECK-NOT-ENCODABLE", "outer"),
    "JSON.encode takes the same recursion without a Nil argument": (
        NIL_WALK.replace("W[Nil]", "W[Int]")
        + main("inner = W(f: JSON.Field.Value(2), rest: [])", "puts(JSON.encode(W(f: JSON.Field.Value(1), rest: [inner])))"),
        None, None),
    "a JSON.Field argument is a direct field after substitution": (
        declared("b: Box[JSON.Field[Int]] = Box(value: JSON.Field.Absent)", "puts(JSON.encode(b))", "puts(JSON.from(b))"),
        None, None),
    "a JSON.Field argument is direct in the inner Box of a nest": (
        declared("b: Box[Box[JSON.Field[Int]]] = Box(value: Box(value: JSON.Field.Null))", "puts(JSON.encode(b))"),
        None, None),
    "a JSON.Field argument is direct in the Box of another generic field": (
        declared("w: Wrap[JSON.Field[Int]] = Wrap(inner: Box(value: JSON.Field.Value(1)))", "puts(JSON.encode(w))",
                   header=BOX + "struct Wrap[T]\n  inner: Box[T]\nend\n\n"),
        None, None),
    "a JSON.Field argument that is a list item after substitution": (
        declared("b: Both[JSON.Field[Int]] = Both(value: JSON.Field.Absent, items: [])", "puts(JSON.encode(b))",
                 header=BOTH),
        "CHECK-JSON-FIELD-PLACE", "b"),
    "a JSON.Field argument that is a list item in the Box of another generic field": (
        declared("b: Outer[JSON.Field[Int]] = Outer(inner: Both(value: JSON.Field.Absent, items: []))", "puts(JSON.from(b).inspect)",
                 header=BOTH + "struct Outer[T]\n  inner: Both[T]\nend\n\n"),
        "CHECK-JSON-FIELD-PLACE", "b"),
    "a JSON.Field argument inside a JSON.Field field": (
        declared("b: Nested[JSON.Field[Int]] = Nested(f: JSON.Field.Absent)", "puts(JSON.encode(b))",
                 header="struct Nested[T]\n  f: JSON.Field[T]\nend\n\n"),
        "CHECK-JSON-FIELD-PLACE", "b"),
    "a JSON.Field argument inside a JSON.Field argument": (
        declared("b: Box[JSON.Field[JSON.Field[Int]]] = Box(value: JSON.Field.Absent)", "puts(JSON.encode(b))"),
        "CHECK-JSON-FIELD-PLACE", "b"),
    "a JSON.Field argument under a list argument": (
        declared("b: Box[List[JSON.Field[Int]]] = Box(value: [])", "puts(JSON.encode(b))"),
        "CHECK-JSON-FIELD-PLACE", "b"),
    "a JSON.Field argument is no whole JSON.from argument": (
        declared("puts(JSON.from(JSON.Field.Value(1)).inspect)"), "CHECK-JSON-FIELD-PLACE", "JSON.Field.Value(1)"),
    "a generic instance with a JSON.Field argument is decodable": (
        declared('r = JSON.decode("{}", Wrapper)', "puts(r.ok?)",
                 header=BOX + "struct Wrapper\n  b: Box[JSON.Field[Int]]\nend\n\n"),
        None, None),
    "a generic instance is a JSON.decode target": (
        declared('r: Result[Box[Int]] = JSON.decode("{}", Box[Int])', "puts(r.ok?)"), None, None),
    "a generic instance whose JSON.Field argument becomes a list item": (
        declared('puts(JSON.decode("{}", Both[JSON.Field[Int]]).ok?)', header=BOTH), "CHECK-JSON-FIELD-PLACE",
        "Both[JSON.Field[Int]]"),
    "a generic instance that would need instances without end": (
        declared('puts(JSON.decode("{}", Grow[Int]).ok?)',
                 header="struct Grow[T]\n  next: Optional[Grow[List[T]]]\nend\n\n"),
        "CHECK-NOT-DECODABLE", "Grow[Int]"),
    "a generic enum in a generic instance is not decodable": (
        declared('puts(JSON.decode("{}", Box[Maybe[Int]]).ok?)',
                 header=BOX + "enum Maybe[T]\n  Just(T)\n  Nothing\nend\n\n"),
        "CHECK-NOT-DECODABLE", "Box[Maybe[Int]]"),
    "JSON.decode rejects a bare generic struct": (
        declared('r = JSON.decode("{}", Box)'), "CHECK-UNKNOWN-TYPE", "Box"),
    "JSON.schema rejects a bare generic struct": (declared("r = JSON.schema(Box)"), "CHECK-UNKNOWN-TYPE", "Box"),
    "JSON.decode takes a generic instance in a field of the target": (
        declared('r = JSON.decode("{}", Wrapper)', "puts(r.ok?)",
                 header=BOX + "struct Wrapper\n  b: Box[Int]\nend\n\n"),
        None, None),
    "JSON.schema takes an alias of a generic instance": (
        declared("puts(JSON.schema(IntBox))", header=BOX + "type IntBox = Box[Int]\n\n"), None, None),
    "a generic struct has members": (declared("puts(Box.members)"), None, None),
    "a C struct takes no type parameters": (
        'extern "c"\n  struct Point[T]\n    x: C.Int32\n  end\nend\n\n' + main("puts(1)"), "PARSE-UNEXPECTED-TOKEN", "["),
}

MODULE = (
    ("struct Box[T]\n  value: T\n  items: List[T] = []\nend\n\n"
     "def make(n: Int) -> Box[Int]\n  return Box(value: n)\nend\n")
)

MODULE_RULES = {
    "an imported generic struct, by alias and by name": (
        'import M from "m"\nimport {Box} from "m"\n\n'
        + main("a: M.Box[Int] = M.Box(value: 1)", 'b: Box[String] = Box(value: "s")', "puts(a.value + b.items.size)",
               "puts(M.make(2).with(value: 3).value)"),
        None, None),
    "the type parameter does not take the module prefix": (
        'import M from "m"\n\nstruct W[T]\n  b: M.Box[T]\nend\n\n'
        + main("w = W(b: M.make(3))", "puts(w.b.value + 1)"),
        None, None),
    "an imported bare generic struct": (
        'import M from "m"\n\ndef f(b: M.Box) -> Void\n  puts(1)\nend\n\n' + main("puts(1)"), "CHECK-UNKNOWN-TYPE",
        "M.Box"),
    "an imported generic instance as a JSON.decode target": (
        'import M from "m"\n\n' + main('puts(JSON.decode("{}", M.Box[Int]).ok?)'), None, None),
    "an imported generic instance whose JSON.Field argument becomes a list item": (
        'import M from "m"\n\n' + main('puts(JSON.decode("{}", M.Box[JSON.Field[Int]]).ok?)'),
        "CHECK-JSON-FIELD-PLACE", "M.Box[JSON.Field[Int]]"),
    "an imported generic instance of the wrong type": (
        'import M from "m"\n\n' + main("b: M.Box[String] = M.make(1)"), "CHECK-TYPE-MISMATCH", "M.make(1)"),
}


@pytest.fixture(scope="module")
def batch(tmp_path_factory):
    """The programs of the rule tables, checked by one `check` call."""
    programs = [rule[0] for rule in RULES.values()]
    programs += [{"m.agc": MODULE, "main.agc": rule[0]} for rule in MODULE_RULES.values()]
    return check_many(programs, tmp_path_factory.mktemp("generic-structs"))


@pytest.mark.parametrize("name", list(RULES))
def test_generic_struct_rules(batch, name):
    program, code, text = RULES[name]
    assert_rule(batch(program), program, code, text)


@pytest.mark.parametrize("name", list(MODULE_RULES))
def test_generic_structs_across_modules(batch, name):
    program, code, text = MODULE_RULES[name]
    assert_rule(batch({"m.agc": MODULE, "main.agc": program}), program, code, text)


def test_a_generic_struct_of_another_module_stays_private_to_update(agentica_check):
    private = ("def make(n: Int) -> Box[Int]\n  return Box(value: n)\nend\n\n"
               "private\n\n"
               "struct Box[T]\n  value: T\nend\n")
    program = 'import M from "m"\n\n' + main("puts(M.make(1).with(value: 5).value)")
    found = agentica_check({"m.agc": private, "main.agc": program})
    assert found["code"] == "CHECK-IMPORT-NAME"


def test_generic_structs_run_and_print(tmp_path):
    program = (
        BOX
        + "struct Pair[A, B]\n  first: A\n  second: B\n  tags: List[A] = []\nend\n\n"
        + main(
            "pair = Pair(first: 1, second: \"x\")",
            "puts(pair)",
            "puts(Box(value: Box(value: 2.5)).value.value * 2.0)",
            "puts(Box(value: 1).with(value: 7).value)",
            "puts(JSON.encode(pair))",
            "puts(Box.members)",
        )
    )
    path = tmp_path / "main.agc"
    path.write_text(program, encoding="utf-8")
    result = run(cli() + [str(path)], env=vm_environment())
    assert result.code == 0, result.stderr
    assert output_lines(result.stdout) == [
        'Pair(first: 1, second: "x", tags: [])',
        "5.0",
        "7",
        '{"first":1,"second":"x","tags":[]}',
        '[StructMember(name: "value", type: "T")]',
    ]


BOX_A = "struct Box[T]\n  value: T\nend\n"
BOX_C = "struct Box[T]\n  name: String\n  count: T\nend\n"
BOX_D = "struct Box[T]\n  work: Channel[T]\nend\n"


def test_two_modules_with_a_box_each_decode_their_own_struct(tmp_path):
    program = (
        'import LibA from "liba"\nimport LibC from "libc"\n\n'
        "struct Both\n  a: LibA.Box[Int]\n  c: LibC.Box[Int]\nend\n\n"
        + main(
            'puts(JSON.decode("{\\"a\\":{\\"value\\":1},\\"c\\":{\\"value\\":2}}", Both).ok?)',
            'both = JSON.decode("{\\"a\\":{\\"value\\":1},\\"c\\":{\\"name\\":\\"n\\",\\"count\\":2}}", Both).unwrap!',
            "puts(both.c.name)",
            "puts(both.c.count + both.a.value)",
            "puts(JSON.schema(Both))",
        )
    )
    for name, text in (("liba.agc", BOX_A), ("libc.agc", BOX_C), ("main.agc", program)):
        (tmp_path / name).write_text(text, encoding="utf-8")
    result = run(cli() + [str(tmp_path / "main.agc")], env=vm_environment())
    assert result.code == 0, result.stderr
    lines = output_lines(result.stdout)
    assert lines[:3] == ["false", "n", "3"]
    schema = json.loads(lines[3])
    refs = [schema["properties"][field]["$ref"] for field in ("a", "c")]
    assert len(set(refs)) == 2
    for ref in refs:
        assert ref.startswith("#/$defs/") and not set(ref) & set("[] ")
        key = urllib.parse.unquote(ref[len("#/$defs/"):])
        assert key in schema["$defs"]
    assert sorted(schema["$defs"][urllib.parse.unquote(refs[1][8:])]["required"]) == ["count", "name"]


def test_a_box_of_another_module_with_a_channel_is_not_decodable(agentica_check):
    program = (
        'import LibA from "liba"\nimport LibD from "libd"\n\n'
        "struct Both\n  a: LibA.Box[Int]\n  d: LibD.Box[Int]\nend\n\n"
        + main('puts(JSON.decode("{}", Both).ok?)')
    )
    found = agentica_check({"liba.agc": BOX_A, "libd.agc": BOX_D, "main.agc": program})
    assert found["code"] == "CHECK-NOT-DECODABLE"
