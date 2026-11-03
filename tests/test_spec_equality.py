"""== and != through the product CLI: which types have equality (structs, lists, maps, sets, Results, Optionals and
enums made of data, recursive and generic ones too) and which do not (functions, tasks, channels, handles, Json and
anything that holds one), and that both sides have one type. A case is `(program, code, covered text)`: the code of
the diagnostic and the source text its range covers; a program that must check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule

TYPES = """\
struct User
  name: String
  tags: List[String]
end

struct Box[T]
  item: T
end

struct Node
  label: String
  children: List[Node]
end

struct Hook
  name: String
  run: Fn[Int, Int]
end

struct Holder
  hooks: List[Hook]
end

enum Shape
  Circle(Float)
  Dot
end

enum Action
  Call(Fn[Int, Int])
  Skip
end

enum Maybe[T]
  Just(T)
  Nothing
end

struct Ring
  next: List[Link]
end

struct Link
  ring: Optional[Ring]
  run: Fn[Int, Int]
end

def inc(x: Int) -> Int
  return x + 1
end

"""


def main(body):
    return TYPES + "def main() -> Void\n" + body + "end\n"


CLEAN = [
    (main('  u = User(name: "a", tags: [])\n  puts(u == u.with(tags: ["x"]))\n'), None, None),
    (main("  puts([[1], [2]] != [[1]])\n  xs: List[Int] = [1]\n  puts(xs == [])\n"), None, None),
    (main('  m = {"a": 1}\n  puts(m == {})\n  puts(Set.new([1]) == Set.new([1, 1]))\n'), None, None),
    (main("  r: Result[Int] = ok(1)\n  v: Result[Void] = ok()\n  puts(r == error(\"x\") or v == ok())\n"), None, None),
    (main("  puts(Shape.Circle(1.0) == Shape.Dot)\n  puts(some(Shape.Dot) == none)\n"), None, None),
    (main('  puts(Box(item: [1]) == Box(item: [2]))\n  puts(Maybe.Just("a") != Maybe.Nothing)\n'), None, None),
    (main('  n = Node(label: "a", children: [])\n  puts(n == n.with(children: [n]))\n'), None, None),
    (main('  puts(["a".bytes] == ["b".bytes])\n  puts(Box(item: 1..2) == Box(item: 1..3))\n'), None, None),
]

REFUSED = [
    # A struct, an enum or a container that holds a function has no equality, at any depth.
    (main('  h = Hook(name: "a", run: &inc)\n  puts(h == h)\n'), "CHECK-TYPE-MISMATCH", "=="),
    (main("  h = Holder(hooks: [])\n  puts(h != h)\n"), "CHECK-TYPE-MISMATCH", "!="),
    (main("  a = Action.Skip\n  puts(a == Action.Skip)\n"), "CHECK-TYPE-MISMATCH", "=="),
    (main("  fs = [&inc]\n  puts(fs == fs)\n"), "CHECK-TYPE-MISMATCH", "=="),
    (main("  b = Box(item: &inc)\n  puts(b == b)\n"), "CHECK-TYPE-MISMATCH", "=="),
    (main("  m: Maybe[Fn[Int, Int]] = Maybe.Nothing\n  puts(m == m)\n"), "CHECK-TYPE-MISMATCH", "=="),
    (main("  f: Fn[Int, Int] = &inc\n  puts(f == f)\n"), "CHECK-TYPE-MISMATCH", "=="),
    # A group of types that hold one another has no equality when one of them holds a function.
    (main("  r = Ring(next: [])\n  puts(r == r)\n"), "CHECK-TYPE-MISMATCH", "=="),
    # Json, tasks, channels and handles have no equality either.
    (main('  j = JSON.parse("1").unwrap!\n  puts([j] == [j])\n'), "CHECK-TYPE-MISMATCH", "=="),
    (main("  t = Task.spawn do 1 end\n  puts(t == t)\n"), "CHECK-TYPE-MISMATCH", "=="),
    (main("  c: Channel[Int] = Channel.new(1)\n  puts(c == c)\n"), "CHECK-TYPE-MISMATCH", "=="),
    (
        TYPES + "def same(p: Process, q: Process) -> Bool\n  return p == q\nend\n\ndef main() -> Void\nend\n",
        "CHECK-TYPE-MISMATCH",
        "==",
    ),
    # A type variable could stand for a function, so a generic function cannot compare its values.
    (
        TYPES + "def same[T](a: T, b: T) -> Bool\n  return a == b\nend\n\ndef main() -> Void\nend\n",
        "CHECK-TYPE-MISMATCH",
        "==",
    ),
    # Both sides have one type; a struct, a list or an enum gives its type to the right side.
    (main('  puts(User(name: "a", tags: []) == Box(item: 1))\n'), "CHECK-TYPE-MISMATCH", "Box(item: 1)"),
    (main('  puts([1] == ["a"])\n'), "CHECK-TYPE-MISMATCH", '"a"'),
    (main("  puts(Box(item: 1) == Box(item: 1.5))\n"), "CHECK-TYPE-MISMATCH", "1.5"),
    (main("  puts(1 == [1])\n"), "CHECK-TYPE-MISMATCH", "=="),
    # Equality does not order: < stays for numbers.
    (main('  puts(User(name: "a", tags: []) < User(name: "b", tags: []))\n'), "CHECK-TYPE-MISMATCH", "<"),
]


@pytest.mark.parametrize(("program", "code", "text"), CLEAN + REFUSED)
def test_equality_rules(agentica_check, program, code, text):
    assert_rule(agentica_check(program), program, code, text)

