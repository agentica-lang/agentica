"""JSON for enums (docs/grammar/06b-builtins.md, "JSON for enums") through the product CLI: `--json check FILE`,
asserting the code and the source text the range covers, never the message. The run-time forms are in the VM goldens
json-enum and json-enum-vectors.
"""
import pytest

from tests.spec_support import check_diagnostic, covered

SHAPE = """enum Shape
  Circle(Float)
  Rect(Float, Float)
  Empty
end

"""

# (name, program, code, covered text or None). A program that checks clean has the code None.
CASES = [
    (
        "encode, decode, schema, from and a codec take a plain enum, alone or in a struct, list, map or Optional",
        SHAPE
        + """struct Drawing
  main: Shape
  shapes: List[Shape]
  by_name: Map[String, Shape]
  spare: Optional[Shape]
end

enum Tree
  Leaf(Int)
  Node(List[Tree])
end

def main() -> Void
  tree = Tree.Node([Tree.Leaf(1)])
  puts(JSON.encode(Shape.Empty))
  puts(JSON.from(tree))
  puts(JSON.decode("{}", Shape))
  puts(JSON.decode("{}", Drawing))
  puts(JSON.decode("{}", Tree))
  puts(JSON.schema(Shape))
  puts(Tree.codec.encode(tree))
end
""",
        None,
        None,
    ),
    (
        "encode takes a generic enum instance, also in a generic function",
        """enum Maybe[T]
  Just(T)
  Nothing
end

def to_json[T](value: T) -> String
  return JSON.encode(value)
end

def main() -> Void
  found: Maybe[List[Int]] = Maybe.Just([1])
  puts(JSON.encode(found))
  puts(to_json(found))
end
""",
        None,
        None,
    ),
    (
        "encode refuses a payload JSON cannot write",
        "enum E\n  A(Set[Int])\nend\n\ndef main() -> Void\n  puts(JSON.encode(E.A(Set.new([1]))))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "E.A(Set.new([1]))",
    ),
    (
        "encode refuses a Result in a payload",
        "enum E\n  A(Result[Int])\nend\n\ndef main() -> Void\n  puts(JSON.encode(E.A(ok(1))))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "E.A(ok(1))",
    ),
    (
        "encode refuses a generic enum instance with an argument JSON cannot write",
        "enum Maybe[T]\n  Just(T)\n  Nothing\nend\n\n"
        "def main() -> Void\n  x: Maybe[Set[Int]] = Maybe.Nothing\n  puts(JSON.encode(x))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "x",
    ),
    (
        "encode refuses a builtin enum",
        "def main() -> Void\n  puts(JSON.encode(TaskExit.Ok))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "TaskExit.Ok",
    ),
    (
        "decode refuses an enum with a payload that cannot be decoded",
        "enum E\n  A(Map[Int, Int])\nend\n\ndef main() -> Void\n  puts(JSON.decode(\"{}\", E))\nend\n",
        "CHECK-NOT-DECODABLE",
        "E",
    ),
    (
        "decode refuses a struct with a generic enum instance",
        "enum Maybe[T]\n  Just(T)\n  Nothing\nend\n\nstruct P\n  x: Maybe[Int]\nend\n\n"
        'def main() -> Void\n  puts(JSON.decode("{}", P))\nend\n',
        "CHECK-NOT-DECODABLE",
        "P",
    ),
    (
        "schema refuses an enum that decode refuses",
        "enum E\n  A(Set[Int])\nend\n\ndef main() -> Void\n  puts(JSON.schema(E))\nend\n",
        "CHECK-NOT-DECODABLE",
        "E",
    ),
    (
        "a generic enum has no bare name to decode",
        'enum Maybe[T]\n  Just(T)\n  Nothing\nend\n\ndef main() -> Void\n  puts(JSON.decode("{}", Maybe))\nend\n',
        "CHECK-UNKNOWN-TYPE",
        "Maybe",
    ),
    (
        "a JsonField in a payload is no JSON field (decode)",
        'enum E\n  A(JsonField[Int])\nend\n\ndef main() -> Void\n  puts(JSON.decode("{}", E))\nend\n',
        "CHECK-JSON-FIELD-PLACE",
        "E",
    ),
    (
        "a JsonField in a payload is no JSON field (encode)",
        "enum E\n  A(JsonField[Int])\nend\n\ndef main() -> Void\n  puts(JSON.encode(E.A(JsonField.Null)))\nend\n",
        "CHECK-JSON-FIELD-PLACE",
        "E.A(JsonField.Null)",
    ),
    (
        "a JsonField in a list in a payload is no JSON field",
        "enum E\n  A(List[JsonField[Int]])\nend\n\n"
        "struct P\n  e: E\nend\n\ndef main() -> Void\n  puts(JSON.schema(P))\nend\n",
        "CHECK-JSON-FIELD-PLACE",
        "P",
    ),
    (
        "a JsonField as the argument of a generic enum is no JSON field",
        "enum Maybe[T]\n  Just(T)\n  Nothing\nend\n\nstruct P\n  x: Maybe[JsonField[Int]]\nend\n\n"
        "def main() -> Void\n  puts(JSON.encode(P(x: Maybe.Nothing)))\nend\n",
        "CHECK-JSON-FIELD-PLACE",
        "P(x: Maybe.Nothing)",
    ),
]


@pytest.mark.parametrize("name, program, code, covers", CASES, ids=[case[0] for case in CASES])
def test_json_enum_rules(name, program, code, covers, tmp_path):
    found = check_diagnostic(program, tmp_path)
    assert (found and found["code"]) == code, program
    if covers is not None:
        assert covered(program, found["range"]) == covers, program
