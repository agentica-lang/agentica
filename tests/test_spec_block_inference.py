"""The type of a block or lambda parameter from its uses in the body (#1395), through `agentica --json check`: a
parameter with neither an annotation nor a type from the context takes the one type its uses leave, and is
CHECK-BLOCK-TYPE at the parameter when they leave none or several. Each case asserts the code and the source text its
range covers, never the message.
"""

from tests.spec_support import Batch, assert_rule

BATCH = Batch("program.agc")
table = BATCH.table
checked = BATCH.fixture()

HEAD = """import Actor from "std/actor"

enum Msg
  Add(Int)
  Get(Channel[Int])
end

struct Point
  left_edge: Int
  top: Int
end

struct Box
  top: Int
end

def twice(n: Int) -> Int = n * 2

def make[T](body: Fn[T, Int]) -> Int = 0

def listed[T](body: Fn[List[T], Int]) -> Int = 0

def handle(count: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Add(n) -> Actor.continue(count + n)
    Msg.Get(reply) ->
      Actor.reply(reply, count)
      Actor.continue(count)
  end
end

def zero() -> Int = 0

def main() -> Void
  actor = Actor.start(Actor.Behaviour(init: &zero, handle: &handle))
  puts(actor.address)
%s
end
"""

VALID = [
    # An operator with a literal: + takes two values of one type, and 1 is an Int.
    "  inc = ->(x) { x + 1 }\n  puts(inc.call(1))",
    # A method that only one receiver kind has, a field that only one struct has, a typed parameter.
    '  loud = ->(s) { s.upcase }\n  puts(loud.call("a"))',
    "  edge = ->(p) { p.left_edge }\n  puts(edge.call(Point(left_edge: 1, top: 2)))",
    "  double = ->(n) { twice(n) }\n  puts(double.call(2))",
    "  both = ->(a, b) { a and b }\n  puts(both.call(true, false))",
    '  wide = ->(x) {\n    y: Float = x\n    "#{y}"\n  }\n  puts(wide.call(1.5))',
    # Several uses: * allows Int or String, % only Int.
    "  f = ->(x) { x * 2 + x % 3 }\n  puts(f.call(4))",
    # The case of #1395: the variant's payload fixes R of Actor.call, which has no expected type inside puts.
    "  puts(Actor.call(actor.address, 1000) do |reply| Msg.Get(reply) end)",
    # A block of a generic call: the body fixes T.
    "  puts(make() do |x| twice(x) end)",
    # A struct field in a construction, !, a use in a nested block and in an interpolation.
    "  at = ->(n) { Point(left_edge: n, top: 0) }\n  puts(at.call(1))",
    "  flip = ->(x) { !x }\n  puts(flip.call(true))",
    "  add = ->(x) { [1].map do |n| n + twice(x) end }\n  puts(add.call(1))",
    '  show = ->(x) { "#{x + 1}" }\n  puts(show.call(1))',
    # An annotation still wins.
    "  g = ->(x: Float) { x }\n  puts(g.call(1.0))",
]


@table("body", VALID, HEAD)
def test_a_use_in_the_body_gives_the_parameter_type(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # No use names a type.
    ("  f = ->(x) { puts(x) }\n  puts(f)", "CHECK-BLOCK-TYPE", "x"),
    # size is a method of String, List, Map ...: a type that cannot be named.
    ("  f = ->(x) { x.size }\n  puts(f)", "CHECK-BLOCK-TYPE", "x"),
    # A field that two structs have.
    ("  f = ->(p) { p.top }\n  puts(f)\n  puts(Box(top: 1))", "CHECK-BLOCK-TYPE", "p"),
    # A field that builtin records have too (name: HTTP.Header, StructMember ...), alone and against a typed argument.
    ("  f = ->(p) { p.name }\n  puts(f)", "CHECK-BLOCK-TYPE", "p"),
    ("  f = ->(p) {\n    puts(p.name)\n    twice(p)\n  }\n  puts(f)", "CHECK-BLOCK-TYPE", "p"),
    # A method or field nothing has: no constraint, then the body's own error.
    ("  f = ->(x) { x.frobnicate }\n  puts(f)", "CHECK-BLOCK-TYPE", "x"),
    ("  puts(make() do |x| x.lenght end)", "CHECK-BLOCK-TYPE", "x"),
    ("  f = ->(x) {\n    puts(x + 1)\n    x.lenght\n  }\n  puts(f)", "CHECK-UNKNOWN-METHOD", "x.lenght"),
    ("  f = ->(x) { x.upcase + x.lenght }\n  puts(f)", "CHECK-UNKNOWN-METHOD", "x.lenght"),
    # Ambiguous: Int * 2 or String * 2.
    ("  f = ->(x) { x * 2 }\n  puts(f)", "CHECK-BLOCK-TYPE", "x"),
    # Uses that need different types.
    ("  f = ->(x) {\n    puts(x + 1)\n    x.upcase\n  }\n  puts(f)", "CHECK-BLOCK-TYPE", "x"),
    # The same in a block of a generic call.
    ("  puts(make() do |x| x * 2 end)", "CHECK-BLOCK-TYPE", "x"),
    # The inferred type is checked as an annotation would be: the body, then the Fn type of the call.
    ("  f = ->(s) { s.upcase + 1 }\n  puts(f)", "CHECK-TYPE-MISMATCH", "+"),
    ("  puts(listed() do |x| twice(x) end)", "CHECK-TYPE-MISMATCH", "do |x| twice(x) end"),
]


@table("body, code, text", REJECTED, HEAD)
def test_a_parameter_type_the_body_does_not_settle(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)
