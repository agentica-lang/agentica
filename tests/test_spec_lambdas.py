"""Lambdas, `->(x) { ... }`, through `agentica --json check`: where a lambda is a function value, how its parameters get
their types, a lambda in the parentheses where a block goes, and the forms of other languages. Each case asserts
the code and the source text its range covers, never the message. The values a lambda gives at run time are the VM
golden tests/fixtures/vm/lambdas.agc, which prints what its Python and Node peers print.
"""

from tests.agentica_test import FIXTURES, PYTHON, cli, run, tool, vm_environment
from tests.spec_support import Batch, assert_rule

BATCH = Batch("program.agc")
table = BATCH.table
checked = BATCH.fixture()

HEAD = """def add(a: Int, b: Int, c: Int) -> Int = a + b + c

def last(n: Int, f: Fn[Int, Int]) -> Int = f.call(n)

def first[T](f: Fn[T, T], x: T) -> T = f.call(x)

def main() -> Void
  xs = [1, 2]
  puts(xs)
%s
end
"""

VALID = [
    # The case of #979: a closure kept in an annotated variable, its parameter types from the Fn type.
    "  c = 3\n  f: Fn[Int, Int, Int] = ->(a, b) { add(a, b, c) }\n  puts(f.call(1, 2))",
    # Annotated parameters need no expected type; no parameters, no parentheses.
    "  inc = ->(x: Int) { x + 1 }\n  answer = -> { 42 }\n  puts(inc.call(answer.call()))",
    # A body over several lines, with a return and a guard.
    '  sign = ->(x: Int) {\n    return "neg" if x < 0\n\n    "pos"\n  }\n  puts(sign.call(1))',
    # try, when the expected Fn gives the result type.
    "  half: Fn[String, Result[Int]] = ->(s) {\n    n = try s.to_i\n    ok(n / 2)\n  }\n"
    '  puts(half.call("4"))',
    # In a list, a map, a non-last argument (a generic one too) and .call, which takes no block.
    "  fs = [->(x: Int) { x }]\n  ops: Map[String, Fn[Int, Int]] = {\"id\": ->(x) { x }}\n"
    "  puts(first(->(x) { x + 1 }, 1) + fs[0].call(1) + ops[\"id\"].call(1))",
    "  g: Fn[Int, Fn[Int, Int], Int] = ->(n, f) { f.call(n) }\n  puts(g.call(1, ->(x: Int) { x * 2 }))",
    # A lambda that gives a lambda, and one in a case arm, after the arm's own ->.
    "  k: Fn[Int, Fn[Int, Int]] = ->(a) { ->(b) { a + b } }\n  puts(k.call(1).call(2))",
    "  n = xs.size\n  h = case n\n    0 -> ->(x: Int) { x }\n    _ -> ->(x: Int) { x * n }\n  end\n  puts(h.call(2))",
    # A parameter of a generic type takes no block, so a lambda is its argument: some, ok, push, put.
    "  o: Optional[Fn[Int, Int]] = some(->(x: Int) { x })\n  fs: List[Fn[Int, Int]] = []\n"
    "  fs = fs.push(->(x: Int) { x + 1 })\n  m: Map[String, Fn[Int, Int]] = {}\n  m = m.put(\"k\", ->(x: Int) { x })\n"
    "  puts(o.unwrap!.call(1) + fs[0].call(1) + m[\"k\"].call(1))",
    # A lambda given to Task.spawn with its argument is not its last argument.
    "  t = Task.spawn(->(x: Int) { x * 2 }, 21)\n  puts(Task.await(t))",
    # After an arm's -> a { is still a map literal.
    '  n = xs.size\n  m = case n\n    0 -> {"a": 1}\n    _ -> {"b": 2}\n  end\n  puts(m)',
    # Where a block goes, a lambda in the parentheses is that block, its parameter types from the expected Fn: a
    # method, a function of the program, a builtin, a pipe, a generic call and a block form of a builtin (File.open).
    "  puts(xs.map(->(x) { x * 2 }).sum)\n  puts(last(1, ->(x) { x }))\n  t = Task.spawn(-> { 1 })\n  puts(Task.await(t))",
    "  n = xs.size\n  puts(n |> last(->(x) { x }))\n  puts(xs.reduce(0, ->(acc, x) { acc + x }))",
    '  m = {"a": 1}\n  m.each(->(k, v) { puts("#{k}=#{v}") })\n  xs.each(->(x) { puts(x) })',
    '  r = File.open("in.txt", ->(_f) { ok(1) })\n  puts(r)',
    # A lambda that captures a local, and one kept in a variable, whose Fn type fits the block's.
    "  k = 10\n  f = ->(x: Int) { x + k }\n  puts(xs.map(->(x) { x + k }))\n  puts(xs.map(f))",
]


@table("body", VALID, HEAD)
def test_a_lambda_is_a_function_value(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # A parameter with neither an annotation, an expected type nor a use that names its type
    # (tests/test_spec_block_inference.py).
    ('  show = ->(x) { "#{x}" }\n  puts(show.call(1))', "CHECK-BLOCK-TYPE", "x"),
    # A lambda where something else is expected, or with the wrong number of parameters.
    ("  n: Int = -> { 1 }\n  puts(n)", "CHECK-TYPE-MISMATCH", "-> { 1 }"),
    ("  f: Fn[Int, Int] = ->(a, b) { a }\n  puts(f.call(1))", "CHECK-ARITY", "->(a, b) { a }"),
    # try needs a known Result type, and a lambda cannot name itself.
    ('  f = ->(s: String) { try s.to_i }\n  puts(f.call("1"))', "CHECK-TRY-CONTEXT", "try s.to_i"),
    ("  f = ->(n: Int) { f.call(n) }\n  puts(f.call(1))", "CHECK-UNKNOWN-NAME", "f"),
    # break and next cannot leave a lambda.
    ("  f = ->(x: Int) { next }\n  puts(f.call(1))", "CHECK-LOOP-CONTROL", "next"),
    # A lambda dropped as a statement.
    ("  ->(x: Int) { x }", "CHECK-UNUSED-VALUE", "->(x: Int) { x }"),
    # A lambda where a block goes is checked as the block: its arity, the types of its result and parameters, and a
    # do block never goes inside the parentheses.
    ("  puts(xs.map(->(x, y) { x + y }))", "CHECK-ARITY", "->(x, y) { x + y }"),
    ("  puts(xs.select(->(x) { x }))", "CHECK-TYPE-MISMATCH", "x"),
    ("  puts(last(1, ->(x: String) { 1 }))", "CHECK-TYPE-MISMATCH", "x: String"),
    ("  f = ->(x: String) { x }\n  puts(xs.map(f).size)", "CHECK-TYPE-MISMATCH", "xs"),
    ("  puts(xs.map(do |x| x end))", "PARSE-UNEXPECTED-TOKEN", "do"),
    # The forms of Ruby and other languages that the lambda replaces.
    ("  f = ->() { 1 }\n  puts(f.call())", "PARSE-UNEXPECTED-TOKEN", "("),
    ("  f = ->x { x }\n  puts(f)", "PARSE-UNEXPECTED-TOKEN", "x"),
    ("  f = ->(x: Int) do x end\n  puts(f)", "PARSE-UNEXPECTED-TOKEN", "do"),
    ("  f = lambda { |x| x }\n  puts(f)", "PARSE-UNEXPECTED-TOKEN", "lambda"),
    ("  f = lambda do |x| x end\n  puts(f)", "PARSE-UNEXPECTED-TOKEN", "do"),
    ("  f = proc do |x| x end\n  puts(f)", "PARSE-UNEXPECTED-TOKEN", "do"),
    ("  f = fn(x: Int) { x }\n  puts(f)", "PARSE-UNEXPECTED-TOKEN", "fn"),
    # The } that ends the lambda is missing.
    ("  f = ->(x: Int) { x\n  puts(f)", "LEX-UNCLOSED-DELIMITER", None),
]


@table("body, code, text", REJECTED, HEAD)
def test_lambda_rules(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)


CONSTANT = "FNS = [->(x: Int) { x }]\n\ndef main() -> Void\n  puts(FNS.size)\nend\n"


@table("program", [CONSTANT])
def test_a_lambda_is_not_constant_data(checked, program):
    assert_rule(checked(program), program, "CHECK-CONSTANT-EXPRESSION", "->(x: Int) { x }")


def test_the_fixture_prints_what_the_python_and_node_peers_print():
    result = run(cli() + [str(FIXTURES / "vm" / "lambdas.agc")], env=vm_environment())
    assert result.code == 0, result.stderr
    python = run([PYTHON, str(FIXTURES / "lambdas-peer.py")])
    node = run([tool("node"), str(FIXTURES / "lambdas-peer.js")])
    assert (python.code, node.code) == (0, 0)
    assert result.stdout == python.stdout == node.stdout
