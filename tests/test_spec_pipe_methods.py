"""Pipes into methods, through `agentica --json check`: `xs |> map(f)` is `xs.map(f)` and `xs |> sum()` is `xs.sum` when
no function of the program has the name, which the linker decides. A function of the file, or one it imports by name,
wins over the method. Each case asserts the code and the source text its range covers, never the message. What the
forms print is the VM golden tests/fixtures/vm/lambdas.agc, which its Python and Node peers print too.
"""

from tests.spec_support import Batch, assert_rule

BATCH = Batch("main.agc")
table = BATCH.table
checked = BATCH.fixture()

HEAD = """def size_of(xs: List[Int]) -> Int = xs.size

def parse(text: String) -> Result[Int]
  n = text |> strip() |> try to_i()
  ok(n)
end

def main() -> Void
  xs = [1, 2, 3]
  puts(parse(" 4"))
%s
end
"""

VALID = [
    # Methods with lambdas, a method without arguments, and a step of the program's own between them.
    "  puts(xs |> map(->(x) { x * 2 }) |> select(->(x) { x > 2 }) |> sum())",
    "  n = xs |> map(->(x) { x + 1 }) |> size_of()\n  puts(n)",
    "  total = (\n    xs\n    |> map(->(x) { x * 2 })\n    |> reduce(0, ->(acc, x) { acc + x })\n  )\n  puts(total)",
    # A Void method as a statement, two block parameters, a do block on the last step, to_s.
    "  xs |> each(->(x) { puts(x) })\n  xs |> each() do |x| puts(x) end",
    '  m = {"a": 1}\n  m |> each(->(k, v) { puts("#{k}=#{v}") })\n  puts(xs |> to_s())',
    # In a condition, an argument, a list, an interpolation, and a case arm and its guard.
    "  if xs |> any?(->(x) { x > 2 })\n    puts(1)\n  end",
    '  puts([xs |> sum(), size_of(xs |> select(->(x) { x > 1 }))])\n  puts("#{xs |> first()}")',
    "  n = xs.size\n  case n\n    3 if xs |> all?(->(x) { x > 0 }) -> puts(xs |> max())\n    _ -> puts(0)\n  end",
]


@table("body", VALID, HEAD)
def test_a_pipe_into_a_method_checks(checked, body):
    assert checked(HEAD % body) is None


REJECTED = [
    # A method the receiver does not have, a variable that is no function, and a step without its ().
    ("  puts(xs |> frobnicate())", "CHECK-UNKNOWN-NAME", "frobnicate()"),
    ("  f = ->(x: Int) { x }\n  puts(f.call(1))\n  puts(xs |> f())", "CHECK-UNKNOWN-NAME", "f()"),
    ("  puts(xs |> sum)", "PARSE-PIPE-TARGET", "sum"),
    # The method's own rules: its arity, and the lambda's.
    ("  puts(xs |> map())", "CHECK-ARITY", "map()"),
    ("  puts(xs |> map(->(a, b) { a + b }))", "CHECK-ARITY", "->(a, b) { a + b }"),
    # A builtin written with its family is still the method form.
    ('  puts("a" |> String.upcase())', "CHECK-PIPE-METHOD", "String.upcase()"),
    # Nothing chains after the end of a do block, a pipe into a method included.
    ("  n = xs |> map() do |x| x end |> size()\n  puts(n)", "CHECK-CHAIN-AFTER-END", "end |> size()"),
]


@table("body, code, text", REJECTED, HEAD)
def test_a_pipe_into_a_method_keeps_the_rules_of_the_method(checked, body, code, text):
    program = HEAD % body
    assert_rule(checked(program), program, code, text)


UTIL = "export def sum(xs: List[Int]) -> String = \"util #{xs.size}\"\n"

CLASHES = [
    # A function of the file named as a method wins: `map` here gives a String, the method a List.
    'def map(xs: List[Int], n: Int) -> String = "mine #{xs.size + n}"\n\n'
    "def main() -> Void\n  xs = [1]\n  s: String = xs |> map(1)\n  ys: List[Int] = xs.map(->(x) { x })\n"
    "  puts(s)\n  puts(ys)\nend\n",
    # So does a function imported by name; through a module alias the name is the method.
    {"main.agc": 'import {sum} from "util"\n\ndef main() -> Void\n  s: String = [1] |> sum()\n  puts(s)\nend\n',
     "util.agc": UTIL},
    {"main.agc": 'import Util from "util"\n\ndef main() -> Void\n  n: Int = [1] |> sum()\n  puts(n)\n'
     "  puts([1] |> Util.sum())\nend\n", "util.agc": UTIL},
]


@table("program", CLASHES, lambda program: program)
def test_a_function_of_the_program_wins_over_a_method_of_the_same_name(checked, program):
    assert checked(program) is None


WRONG_CLASH = 'def map(xs: List[Int], n: Int) -> String = "mine"\n\ndef main() -> Void\n  ys: List[Int] = [1] |> map(1)\n  puts(ys)\nend\n'


@table("program", [WRONG_CLASH])
def test_the_function_that_wins_gives_its_own_type(checked, program):
    assert_rule(checked(program), program, "CHECK-TYPE-MISMATCH", "map(1)")
