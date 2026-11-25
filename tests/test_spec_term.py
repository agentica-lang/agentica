"""Term.encode through the product CLI: which types it writes, and the rules and diagnostic codes that refuse the rest.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers.
A program that must check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule, check_many


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


SHAPES = """struct Entry
  id: Int
  hits: Map[Int, Int]
  names: Map[String, UInt8]
  raw: Bytes
  score: Float
  ratio: Float32
  big: UInt64
  tag: Optional[String]
  nothing: Nil
end

struct Box[T]
  value: T
end

enum Shape
  Circle(Float)
  Rect(Int, Int)
  Empty
end

"""

GENERIC = """struct Box[T]
  value: Optional[T]
end

enum Maybe[T]
  Just(Optional[T])
  Nothing
end

"""

# A struct of another module with a private field: a Term writes every field, so only its module may encode it.
LIB = "struct Conn\n  id: Int\n\n  private\n\n  secret: String\nend\n\ndef open(id: Int) -> Conn = Conn(id: id, secret: \"s\")\n"
MODULE = 'import L from "lib"\n\n' + main("c = L.open(1)", "puts(Term.encode(c))")

RULES = {
    "a struct of every kind of field": (
        SHAPES + main('e = Entry(id: 1, hits: {1: 2}, names: {}, raw: "a".bytes, score: 1.5, ratio: 0.5, big: 7, '
                      'tag: none, nothing: nil)', "puts(Term.encode(e).unwrap!.size)"), None, None),
    "enums, generic instances and lists": (
        SHAPES + main("puts(Term.encode([Shape.Circle(1.0), Shape.Empty]).unwrap!.size)",
                      "puts(Term.encode(Box(value: [1, 2])).unwrap!.size)", "puts(Term.encode(nil).unwrap!.size)"),
        None, None),
    "a sized integer": (main("a: UInt8 = 200", "puts(Term.encode(a).unwrap!.size)"), None, None),
    "the result is a Result of Bytes": (main("b: Bytes = Term.encode(1).unwrap!", "puts(b.size)"), None, None),
    "a function cannot be encoded": (main("f = &Int.abs", "puts(Term.encode(f))"), "CHECK-NOT-ENCODABLE", "f"),
    "a Set cannot be encoded": (main("puts(Term.encode(Set.new([1])))"), "CHECK-NOT-ENCODABLE", "Set.new([1])"),
    "a Result cannot be encoded": (main("puts(Term.encode(ok(1)))"), "CHECK-NOT-ENCODABLE", "ok(1)"),
    "a Json cannot be encoded": (main("puts(Term.encode(JSON.null()))"), "CHECK-NOT-ENCODABLE", "JSON.null()"),
    "a time cannot be encoded": (
        main("puts(Term.encode(Time.Date.new(2026, 1, 2).unwrap!))"), "CHECK-NOT-ENCODABLE",
        "Time.Date.new(2026, 1, 2).unwrap!"),
    "a Map key must be Int or String": (
        main("m: Map[UInt8, Int] = {}", "puts(Term.encode(m))"), "CHECK-NOT-ENCODABLE", "m"),
    "an Optional of Nil is refused": (
        main("x: Optional[Nil] = none", "puts(Term.encode(x))"), "CHECK-NOT-ENCODABLE", "x"),
    "an Optional of an Optional is refused": (
        main("x: Optional[Optional[Int]] = none", "puts(Term.encode(x))"), "CHECK-NOT-ENCODABLE", "x"),
    "a field that cannot be encoded refuses the struct": (
        "struct Held\n  items: Set[Int]\nend\n\n" + main("puts(Term.encode(Held(items: Set.new([]))))"),
        "CHECK-NOT-ENCODABLE", "Held(items: Set.new([]))"),
    "a type variable is refused": (
        "def dump[T](value: T) -> Result[Bytes] = Term.encode(value)\n\n" + main("puts(dump(1))"),
        "CHECK-NOT-ENCODABLE", "value"),
    "a JSON.Field is refused for now": (
        "struct P\n  age: JSON.Field[Int]\nend\n\n" + main("puts(Term.encode(P(age: JSON.Field.Absent)))"),
        "CHECK-NOT-ENCODABLE", "P(age: JSON.Field.Absent)"),
    "a recursive type is written": (
        "struct Tree\n  children: List[Tree]\nend\n\n" + main("puts(Term.encode(Tree(children: [])).unwrap!.size)"),
        None, None),
    "a generic struct and enum with an argument that is not an Optional": (
        GENERIC + main("c: Box[Int] = Box(value: none)", "d: Maybe[String] = Maybe.Nothing",
                       "puts(Term.encode(c).unwrap!.size + Term.encode(d).unwrap!.size)"), None, None),
    "a Map key that is Bytes is refused": (
        main("m: Map[Bytes, Int] = {}", "puts(Term.encode(m))"), "CHECK-NOT-ENCODABLE", "m"),
    "a Map key that is a sized integer is refused in a struct": (
        "struct H\n  m: Map[UInt8, Int]\nend\n\n" + main("puts(Term.encode(H(m: {})))"), "CHECK-NOT-ENCODABLE",
        "H(m: {})"),
    "an Optional of an Optional through a type argument": (
        GENERIC + main("x: Box[Optional[Int]] = Box(value: none)", "puts(Term.encode(x))"), "CHECK-NOT-ENCODABLE", "x"),
    "an Optional of Nil through a type argument": (
        GENERIC + main("x: Box[Nil] = Box(value: none)", "puts(Term.encode(x))"), "CHECK-NOT-ENCODABLE", "x"),
    "an Optional of an Optional through the type argument of an enum": (
        GENERIC + main("x: Maybe[Optional[Int]] = Maybe.Nothing", "puts(Term.encode(x))"), "CHECK-NOT-ENCODABLE", "x"),
    "a generic struct that a Nil argument makes refuse an Optional nested in a list": (
        GENERIC + main("x: Box[Nil] = Box(value: none)", "puts(Term.encode([x]))"), "CHECK-NOT-ENCODABLE", "[x]"),
    "Term.encode takes one argument": (main("puts(Term.encode(1, 2))"), "CHECK-ARITY", "Term.encode(1, 2)"),
    "Term cannot name a struct": ("struct Term\n  n: Int\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME",
                                  "struct Term\n  n: Int\nend\n"),
    "Term cannot name an enum": ("enum Term\n  A\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME",
                                 "enum Term\n  A\nend\n"),
}


@pytest.fixture(scope="module")
def batch(tmp_path_factory):
    """The programs of the table, and the module case, checked by one `check` call."""
    programs = [rule[0] for rule in RULES.values()] + [{"lib.agc": LIB, "main.agc": MODULE}]
    return check_many(programs, tmp_path_factory.mktemp("term"))


@pytest.mark.parametrize("name", list(RULES))
def test_term_encode_rules(batch, name):
    program, code, text = RULES[name]
    assert_rule(batch(program), program, code, text)


def test_term_encode_refuses_the_private_field_of_another_module(batch):
    assert_rule(batch({"lib.agc": LIB, "main.agc": MODULE}), MODULE, "CHECK-PRIVATE-FIELD", "c")
