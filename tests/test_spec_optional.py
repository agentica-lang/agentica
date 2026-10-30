"""Optional[T] (§6, "Optional values") through the product CLI: `--json check FILE`, asserting the code and the
source text the range covers, never the message. Runtime behavior is in the VM goldens optionals and
optional-unwrap-none.
"""
import pytest

from tests.spec_support import check_diagnostic, covered

CASE_HEAD = "def main() -> Void\n  age: Optional[Int] = some(1)\n  case age\n"

# (name, program, code, covered text or None). A program that checks clean has the code None.
CASES = [
    (
        "constructors, case, methods and == check",
        """struct User
  age: Optional[Int]
end

def first[T](items: List[T]) -> Optional[T]
  if items.size == 0
    return none
  end
  return some(items[0])
end

def main() -> Void
  user = User(age: none)
  ages: List[Optional[Int]] = [some(1), none]
  nested: Optional[Optional[String]] = some(none)
  case user.age
    some(n) -> puts(n)
    none -> puts("none")
  end
  n: Int = user.age.unwrap_or(0) + first([1]).unwrap!
  doubled: Optional[Int] = user.age.map do |x| x * 2 end
  text: Optional[String] = user.age.map do |x| x.to_s end
  flags: List[Bool] = [user.age.some?, user.age.none?, user.age == none, ages[0] != some(2)]
  r: Result[Int] = user.age.to_result("no age")
  puts("#{nested} #{ages} #{n} #{doubled} #{text} #{flags} #{r}")
end
""",
        None,
        None,
    ),
    ("a none with no expected type", "def main() -> Void\n  age = none\nend\n", "CHECK-OPTIONAL-TYPE", "none"),
    (
        "a none where another type is expected",
        "def main() -> Void\n  age: Int = none\nend\n",
        "CHECK-TYPE-MISMATCH",
        "none",
    ),
    (
        "some of the wrong item type",
        'def main() -> Void\n  age: Optional[Int] = some("ten")\nend\n',
        "CHECK-TYPE-MISMATCH",
        '"ten"',
    ),
    (
        "an Optional of another item type",
        "def main() -> Void\n  a: Optional[Int] = some(1)\n  b: Optional[String] = a\nend\n",
        "CHECK-TYPE-MISMATCH",
        "a",
    ),
    (
        "a case without the none arm",
        "def main() -> Void\n  age: Optional[Int] = some(1)\n  case age\n    some(n) -> puts(n)\n  end\nend\n",
        "CHECK-NON-EXHAUSTIVE-CASE",
        None,
    ),
    (
        "a pattern of a Result on an Optional",
        CASE_HEAD + "    ok(n) -> puts(n)\n    _ -> puts(0)\n  end\nend\n",
        "CHECK-PATTERN-TYPE",
        "ok(n)",
    ),
    (
        "an Optional pattern is some(x) or none, never Optional.Some",
        CASE_HEAD + "    Optional.Some(n) -> puts(n)\n    _ -> puts(0)\n  end\nend\n",
        "PARSE-UNEXPECTED-TOKEN",
        "Optional",
    ),
    (
        "an Optional value is some(x), never Optional.Some(x)",
        "def main() -> Void\n  age = Optional.Some(1)\nend\n",
        "CHECK-UNKNOWN-TYPE",
        None,
    ),
    (
        "Optional is a reserved type name",
        "enum Optional\n  Here\nend\n\ndef main() -> Void\nend\n",
        "CHECK-REDEFINED-NAME",
        None,
    ),
    ("none is not a variable name", "def main() -> Void\n  none = 1\nend\n", "CHECK-REDEFINED-NAME", None),
    (
        "some is not a parameter name",
        "def f(some: Int) -> Int\n  return some\nend\n\ndef main() -> Void\n  puts(f(1))\nend\n",
        "CHECK-REDEFINED-NAME",
        None,
    ),
    (
        "Optional[Void] is no type",
        "def f(x: Optional[Void]) -> Void\nend\n\ndef main() -> Void\nend\n",
        "CHECK-VOID-TYPE",
        "Void",
    ),
    (
        "unwrap_or takes a default of the item type",
        'def main() -> Void\n  age: Optional[Int] = none\n  puts(age.unwrap_or("none"))\nend\n',
        "CHECK-TYPE-MISMATCH",
        '"none"',
    ),
    (
        "unwrap! gives the item type",
        "def main() -> Void\n  age: Optional[Int] = some(1)\n  name: String = age.unwrap!\nend\n",
        "CHECK-TYPE-MISMATCH",
        "age.unwrap!",
    ),
    (
        "map gives an Optional of the block's type",
        "def main() -> Void\n  age: Optional[Int] = some(1)\n  n: Optional[Int] = age.map do |x| x.to_s end\nend\n",
        "CHECK-TYPE-MISMATCH",
        None,
    ),
    (
        "to_result takes a String message",
        "def main() -> Void\n  age: Optional[Int] = some(1)\n  r = age.to_result(404)\nend\n",
        "CHECK-TYPE-MISMATCH",
        "404",
    ),
    (
        "== needs items with equality",
        "def main() -> Void\n  xs: Optional[List[Int]] = some([1])\n  puts(xs == none)\nend\n",
        "CHECK-TYPE-MISMATCH",
        None,
    ),
    (
        "JSON takes Optional fields, items, map values, nesting and a top-level Optional",
        """struct Address
  city: String
  zip: Optional[String] = none
end

struct User
  age: Optional[Int]
  home: Optional[Address]
  tags: List[Optional[String]]
  limits: Map[String, Optional[Float]]
  deep: Optional[Optional[Int]]
  nicks: Optional[List[String]]
  note: JsonField[String]
end

def main() -> Void
  age: Optional[Int] = none
  user = JSON.decode("{}", User).unwrap!
  codec = JSON.codec(User)
  puts("#{JSON.encode(user)} #{JSON.from(user)} #{JSON.encode(age)} #{JSON.schema(User)} #{codec.encode(user)}")
end
""",
        None,
        None,
    ),
    (
        "Map.get and String.index_of give an Optional",
        'def main() -> Void\n  m = {"a": 1}\n  n: Optional[Int] = m.get("a")\n  i: Optional[Int] = "ab".index_of("b")\n'
        "  puts(n.unwrap_or(0) + i.unwrap_or(0) + m.get(\"a\", 0))\nend\n",
        None,
        None,
    ),
    (
        "try on Map.get needs to_result",
        'def f() -> Result[Int]\n  m = {"a": 1}\n  n = try m.get("a")\n  return ok(n)\nend\n\ndef main() -> Void\nend\n',
        "CHECK-TYPE-MISMATCH",
        'm.get("a")',
    ),
    (
        "an ok arm on String.index_of",
        'def main() -> Void\n  case "ab".index_of("b")\n    ok(i) -> puts(i)\n    _ -> puts(0)\n  end\nend\n',
        "CHECK-PATTERN-TYPE",
        "ok(i)",
    ),
    (
        "ok? on Map.get",
        'def main() -> Void\n  m = {"a": 1}\n  puts(m.get("a").ok?)\nend\n',
        "CHECK-UNKNOWN-METHOD",
        'm.get("a").ok?',
    ),
    (
        "Optional[JsonField[T]] is no JSON field",
        "struct P\n  age: Optional[JsonField[Int]]\nend\n\ndef main() -> Void\n  puts(JSON.encode(P(age: none)))\nend\n",
        "CHECK-JSON-FIELD-PLACE",
        "P(age: none)",
    ),
    (
        "a JsonField inside an Optional list item is no JSON field",
        "struct P\n  ages: List[Optional[JsonField[Int]]]\nend\n\ndef main() -> Void\n  puts(JSON.schema(P))\nend\n",
        "CHECK-JSON-FIELD-PLACE",
        "P",
    ),
    (
        "JsonField[Optional[T]] cannot be encoded",
        "struct P\n  age: JsonField[Optional[Int]]\nend\n\n"
        "def main() -> Void\n  puts(JSON.encode(P(age: JsonField.Absent)))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "P(age: JsonField.Absent)",
    ),
    (
        "JsonField[Optional[T]] cannot be decoded",
        'struct P\n  age: JsonField[Optional[Int]]\nend\n\ndef main() -> Void\n  puts(JSON.decode("{}", P))\nend\n',
        "CHECK-NOT-DECODABLE",
        "P",
    ),
    (
        "Optional[Nil] cannot be encoded",
        "def main() -> Void\n  x: Optional[Nil] = none\n  puts(JSON.encode(x))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "x",
    ),
    (
        "an Optional of a type JSON cannot write cannot be encoded",
        "def main() -> Void\n  x: Optional[Set[Int]] = none\n  puts(JSON.encode(x))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "x",
    ),
]


@pytest.mark.parametrize("name, program, code, covers", CASES, ids=[case[0] for case in CASES])
def test_optional_rules(name, program, code, covers, tmp_path):
    found = check_diagnostic(program, tmp_path)
    assert (found and found["code"]) == code, program
    if covers is not None:
        assert covered(program, found["range"]) == covers, program
