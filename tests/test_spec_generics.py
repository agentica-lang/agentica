"""Generic functions (`def first_or[T](...)`) through the product CLI: the rules and their diagnostic codes and spans.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers.
A program that must check clean has no code.
"""

import pytest

from tests.agentica_test import cli, output_lines, run, vm_environment
from tests.spec_support import assert_rule

FIRST_OR = (
    "def first_or[T](xs: List[T], fallback: T) -> T\n"
    "  if xs.length == 0\n"
    "    return fallback\n"
    "  end\n\n"
    "  return xs[0]\n"
    "end\n\n"
)
MAX_BY = (
    "def max_by[T](xs: List[T], key: Fn[T, Int]) -> Result[T]\n"
    "  if xs.length == 0\n"
    '    return error("empty list")\n'
    "  end\n\n"
    "  best = xs[0]\n"
    "  best_key = key.call(best)\n"
    "  for x in xs\n"
    "    k = key.call(x)\n"
    "    if k > best_key\n"
    "      best = x\n"
    "      best_key = k\n"
    "    end\n"
    "  end\n\n"
    "  return ok(best)\n"
    "end\n\n"
)
WITH = (
    "struct Pool[T]\n  items: List[T]\nend\n\n"
    "def with[T, R](pool: Pool[T], body: Fn[T, Result[R]]) -> Result[R]\n"
    "  if pool.items.length == 0\n"
    '    return error("empty pool")\n'
    "  end\n\n"
    "  return body.call(pool.items[0])\n"
    "end\n\n"
)
EMPTY_OF = "def empty_of[T]() -> List[T]\n  return []\nend\n\n"
ID = "def id(x: Int) -> Int\n  return x\nend\n\n"
BOX = "struct Box[T]\n  value: T\nend\n\n"


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


def declared(*lines: str, header: str = FIRST_OR) -> str:
    return header + main(*lines)


def body(*lines: str, header: str = "") -> str:
    """A generic function `f[T](x: T, y: T)` whose body is the lines, and a main that does not call it."""
    function = "def f[T](x: T, y: T) -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"
    return header + function + main("puts(1)")


RULES = {
    "T comes from the arguments, left to right": (
        declared('names = ["ana", "ben"]', 's: String = first_or(names, "none")', "puts(s)"), None, None),
    "an empty list is checked last": (declared("n: Int = first_or([], 0)", "puts(n)"), None, None),
    "an empty map is checked last": (
        "def pick[T](m: Map[String, T], fallback: T) -> T\n  return fallback\nend\n\n"
        + main("n: Int = pick({}, 1)", "puts(n)"), None, None),
    "error(...) is checked last": (
        "def settle[T](r: Result[T], fallback: T) -> T\n  return fallback\nend\n\n"
        + main('n: Int = settle(error("no"), 1)', "puts(n)"), None, None),
    "a list that holds an empty list is checked last": (
        "def flat[T](xss: List[List[T]], fallback: T) -> T\n  return fallback\nend\n\n"
        + main("n: Int = flat([[], [1]], 2)", "puts(n)"), None, None),
    "the block is the last argument": (
        declared('words = ["pear", "fig"]', "r = max_by(words) do |w|", "  w.length", "end", 'puts(r.unwrap_or("none"))',
                 header=MAX_BY), None, None),
    "the block result binds R": (
        declared("db = Pool(items: [3, 4])", "r = with(db) do |conn|", "  ok(conn * 2)", "end", "puts(r.unwrap_or(0))",
                 header=WITH), None, None),
    "an annotation in the block binds T": (
        "def run[T](x: T, body: Fn[T, Int]) -> Int\n  return body.call(x)\nend\n\n"
        + main("n = run(1) do |x: Int|", "  x + 1", "end", "puts(n)"), None, None),
    "an open block parameter bound by its annotation": (
        "def make[T](body: Fn[T, Int]) -> Int\n  return 0\nend\n\n"
        + main("n = make() do |x: String|", "  x.length", "end", "puts(n)"), None, None),
    "the expected type gives a type that only the result has": (
        declared("xs: List[Int] = empty_of()", "puts(xs.size)", header=EMPTY_OF), None, None),
    "the expected type is a parameter, a field and a return type": (
        "struct Holder\n  xs: List[String]\nend\n\n"
        + EMPTY_OF
        + "def size(xs: List[Int]) -> Int\n  return xs.size\nend\n\n"
        + "def fresh() -> List[Float]\n  return empty_of()\nend\n\n"
        + main("puts(size(empty_of()))", "puts(Holder(xs: empty_of()).xs.size)", "puts(fresh().size)"), None, None),
    "the arguments win over the expected type": (
        declared("xs: Int = first_or([1], 2)", "puts(xs)"), None, None),
    "a conflict between arguments": (declared('puts(first_or([1], "x"))'), "CHECK-TYPE-MISMATCH", '"x"'),
    "the expected type fixes a result-only variable": (
        declared("xs: List[Int] = empty_of()", 'ys: List[String] = empty_of()', 'zs: List[Int] = ys',
                 header=EMPTY_OF), "CHECK-TYPE-MISMATCH", "ys"),
    "recursion, mutual recursion and a generic that calls another": (
        "def count[T](xs: List[T]) -> Int\n  if xs.size == 0\n    return 0\n  end\n\n  return 1 + count(xs.drop(1))\nend\n\n"
        + "def ping[T](x: T, n: Int) -> T\n  if n == 0\n    return x\n  end\n\n  return pong(x, n - 1)\nend\n\n"
        + "def pong[T](x: T, n: Int) -> T\n  return ping(x, n)\nend\n\n"
        + "def twice[T](xs: List[T]) -> T\n  return first_or(xs, xs[0])\nend\n\n"
        + FIRST_OR
        + main("puts(count([1, 2, 3]))", 'puts(ping("a", 2))', "puts(twice([4]))"), None, None),
    "polymorphic recursion": (
        "def nest[T](x: T, n: Int) -> Int\n  if n == 0\n    return 0\n  end\n\n  return nest([x], n - 1)\nend\n\n"
        + main("puts(nest(1, 3))"), None, None),
    "a T value is stored, returned and captured": (
        "def keep[T](x: T) -> Map[String, List[Result[T]]]\n"
        "  rs = [1, 2].map do |i|\n"
        "    ok(x)\n"
        "  end\n"
        '  return {"a": rs}\n'
        "end\n\n" + main("puts(keep(1).size)"), None, None),
    "a T value in a struct and an enum payload": (
        BOX + "enum Maybe[T]\n  Some(T)\n  None\nend\n\n"
        "def wrap[T](x: T) -> Maybe[Box[T]]\n  return Maybe.Some(Box(value: x))\nend\n\n"
        + main("puts(1)"), None, None),
    "try gives T from a Result of T": (
        "def unwrap_all[T](r: Result[T]) -> Result[T]\n  v = try r\n  return ok(v)\nend\n\n"
        + main("puts(unwrap_all(ok(1)).unwrap_or(0))"), None, None),
    "try of a generic call": (
        MAX_BY + "def top(xs: List[Int]) -> Result[Int]\n  best = try max_by(xs) do |x|\n    x\n  end\n  return ok(best)\nend\n\n"
        + main("puts(top([1, 2]).unwrap_or(0))"), None, None),
    "ok() binds R to Void": (
        "def finish[R](r: Result[R]) -> Result[R]\n  return r\nend\n\n" + main("r = finish(ok())", "puts(r.ok?)"), None, None),
    "a Void block result binds R": (
        "def run[R](f: Fn[Int, R]) -> R\n  return f.call(1)\nend\n\n"
        + main("run() do |x|", "  puts(x)", "end"), None, None),
    "Void as a list item is CHECK-VOID-TYPE at the call": (
        "def lift[R](f: Fn[Int, R]) -> List[R]\n  return []\nend\n\n"
        + main("xs = lift() do |x|", "  puts(x)", "end", "puts(xs.size)"), "CHECK-VOID-TYPE",
        "lift() do |x|\n    puts(x)\n  end"),
    "a block parameter still open is CHECK-BLOCK-TYPE": (
        "def make[T](body: Fn[T, Int]) -> Int\n  return 0\nend\n\n"
        + main("n = make() do |x|", "  1", "end"), "CHECK-BLOCK-TYPE", "x"),
    "a block result that does not fit": (
        declared('words = ["pear"]', "r = max_by(words) do |w|", "  w", "end", header=MAX_BY),
        "CHECK-TYPE-MISMATCH", "w"),
    "a parameter that stays open is CHECK-ENUM-TYPE-INFERENCE at the call": (
        declared("xs = empty_of()", header=EMPTY_OF), "CHECK-ENUM-TYPE-INFERENCE", "empty_of()"),
    "two empty literals leave T open": (
        declared("x = first_or([], [])"), "CHECK-ENUM-TYPE-INFERENCE", "first_or([], [])"),
    "a type parameter that nothing mentions": (
        "def tag[T](n: Int) -> Int\n  return n\nend\n\n" + main("puts(1)"), "CHECK-ENUM-TYPE-INFERENCE", "T"),
    "a repeated type parameter": (
        "def f[T, T](x: T) -> T\n  return x\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME", "T"),
    "a reserved type parameter": (
        "def f[Int](x: Int) -> Int\n  return x\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME", "Int"),
    "a type parameter that hides a struct": (
        "struct Item\n  n: Int\nend\n\ndef f[Item](x: Item) -> Item\n  return x\nend\n\n" + main("puts(1)"),
        "CHECK-REDEFINED-NAME", "Item"),
    "a type parameter that hides an enum and an alias": (
        "type Names = List[String]\n\ndef f[Names](x: Names) -> Names\n  return x\nend\n\n" + main("puts(1)"),
        "CHECK-REDEFINED-NAME", "Names"),
    "an enum may take the name of a struct today": (
        "struct Item\n  n: Int\nend\n\nenum Holder[Item]\n  Full(Item)\nend\n\n" + main("puts(1)"), None, None),
    "empty type parameters": ("def f[](x: Int) -> Int\n  return x\nend\n\n" + main("puts(1)"), "PARSE-UNEXPECTED-TOKEN", "]"),
    "main takes no type parameters": (
        "def main[T]() -> Void\n  puts(1)\nend\n\n", "CHECK-MAIN", "def main[T]() -> Void\n  puts(1)\nend\n"),
    "an extern function takes no type parameters": (
        'extern "c"\n  def abs[T](n: C.Int32) -> C.Int32\n  end\nend\n\n' + main("puts(1)"), "PARSE-UNEXPECTED-TOKEN",
        "["),
    "a call takes no type arguments": (declared("puts(first_or[Int]([1], 2))"), "PARSE-UNEXPECTED-TOKEN", "("),
    "a default value of a type parameter's type": (
        "def f[T](xs: List[T] = []) -> Int\n  return xs.size\nend\n\n" + main("puts(1)"), "CHECK-DEFAULT-VALUE", "[]"),
    "a default value of another type is allowed": (
        "def f[T](x: T, n: Int = 1) -> T\n  return x\nend\n\n" + main("puts(f(1))"), None, None),
    "== on T": (body("z = x == y"), "CHECK-TYPE-MISMATCH", "=="),
    "!= on T": (body("z = x != y"), "CHECK-TYPE-MISMATCH", "!="),
    "arithmetic on T": (body("z = x + y"), "CHECK-TYPE-MISMATCH", "+"),
    "ordering on T": (body("z = x < y"), "CHECK-TYPE-MISMATCH", "<"),
    "to_s on T": (body("z = x.to_s"), "CHECK-UNKNOWN-METHOD", "x.to_s"),
    "inspect on T": (body("z = x.inspect"), "CHECK-UNKNOWN-METHOD", "x.inspect"),
    "interpolation of T": (body('z = "#{x}"'), "CHECK-TYPE-MISMATCH", "x"),
    "puts of T": (body("puts(x)"), "CHECK-TYPE-MISMATCH", "x"),
    "puts of a list of T": (body("puts([x])"), "CHECK-TYPE-MISMATCH", "[x]"),
    "a field of T": (body("z = x.name"), "CHECK-UNKNOWN-METHOD", "x.name"),
    "a method of T": (body("z = x.with(a: 1)"), "CHECK-UNKNOWN-METHOD", "x.with(a: 1)"),
    "call on T": (body("z = x.call(1)"), "CHECK-TYPE-MISMATCH", "x.call(1)"),
    "a literal arm on T": (
        body("case x", "  1 -> puts(1)", "  _ -> puts(2)", "end"), "CHECK-PATTERN-TYPE", "1"),
    "a variant arm on T": (
        body("case x", "  Maybe.None -> puts(1)", "  _ -> puts(2)", "end", header="enum Maybe\n  None\nend\n\n"),
        "CHECK-PATTERN-TYPE", "Maybe.None"),
    "JSON.encode of T": (body("z = JSON.encode(x)"), "CHECK-NOT-ENCODABLE", "x"),
    "JSON.decode to T": (body('z = JSON.decode("{}", T)'), "CHECK-NOT-DECODABLE", "T"),
    "T as a Map key": (
        "def f[T](m: Map[T, Int]) -> Int\n  return 0\nend\n\n" + main("puts(1)"), "CHECK-MAP-KEY-TYPE", "T"),
    "T as a Set element": (
        "def f[T](s: Set[T]) -> Int\n  return 0\nend\n\n" + main("puts(1)"), "CHECK-SET-ELEMENT-TYPE", "T"),
    "T as a Map key does not become valid with Int": (
        "def f[T](m: Map[T, Int]) -> Int\n  return 0\nend\n\n" + main("puts(f({1: 2}))"), "CHECK-MAP-KEY-TYPE", "T"),
    "a T annotation in the body": (
        body("z: T = x", "w: List[T] = []", "puts(w.size)"), None, None),
    "a block parameter annotated with T": (
        "def apply[T](x: T, f: Fn[T, T]) -> T\n  return f.call(x)\nend\n\n"
        "def twice[T](x: T) -> T\n  return apply(x) do |y: T|\n    y\n  end\nend\n\n" + main("puts(twice(3))"),
        None, None),
    "the data type rule is judged on the type argument": (
        declared("fns = [&id]", "puts(first_or(fns, &id))", header=FIRST_OR + ID), "CHECK-TYPE-MISMATCH",
        "first_or(fns, &id)"),
    "a call is no constant expression": (
        "export LIMIT = first_or([1], 2)\n\n" + FIRST_OR + main("puts(1)"), "CHECK-CONSTANT-EXPRESSION",
        "first_or([1], 2)"),
    "a function reference where the Fn type is known": (
        declared("f: Fn[List[Int], Int, Int] = &first_or", "puts(f.call([], 3))"), None, None),
    "a function reference to a call with a known parameter": (
        "def apply[T](f: Fn[T, T], x: T) -> T\n  return f.call(x)\nend\n\n"
        "def keep[T](x: T) -> T\n  return x\nend\n\n" + main("puts(apply(&keep, 3))"), None, None),
    "a function reference where T is the enclosing T": (
        "def keep[T](x: T) -> T\n  return x\nend\n\n"
        "def f[T](x: T) -> T\n  g: Fn[T, T] = &keep\n  return g.call(x)\nend\n\n" + main("puts(f(1))"), None, None),
    "a function reference without a type": (
        declared("f = &first_or"), "CHECK-ENUM-TYPE-INFERENCE", "&first_or"),
    "a function reference of another type": (
        declared("f: Fn[List[Int], String, Int] = &first_or"), "CHECK-TYPE-MISMATCH", "&first_or"),
    "a bare generic function name": (declared("f = first_or"), "CHECK-UNKNOWN-NAME", "first_or"),
    "the wrong number of arguments": (declared("puts(first_or([1]))"), "CHECK-ARITY", "first_or([1])"),
}

LIB = (
    "export struct Pool[T]\n  items: List[T]\nend\n\n"
    "export def first_or[T](xs: List[T], fallback: T) -> T\n"
    "  if xs.length == 0\n    return fallback\n  end\n\n  return xs[0]\n"
    "end\n\n"
    "export def new[T](items: List[T]) -> Pool[T]\n  return Pool(items: items)\nend\n\n"
    "export def with[T, R](pool: Pool[T], body: Fn[T, Result[R]]) -> Result[R]\n"
    '  if pool.items.length == 0\n    return error("empty pool")\n  end\n\n  return body.call(pool.items[0])\n'
    "end\n"
)

MODULE_RULES = {
    "an exported generic function through the alias and by name": (
        'import M from "m"\nimport {first_or} from "m"\n\n'
        + main("a: Int = M.first_or([], 1)", 'b: String = first_or(["x"], "y")', "puts(a + b.size)"), None, None),
    "a generic function that returns a generic struct of the module": (
        'import Pool from "m"\n\n'
        + main("db = Pool.new([3, 4])", "r = Pool.with(db) do |conn|", "  ok(conn * 2)", "end", "puts(r.unwrap_or(0))"),
        None, None),
    "a type parameter that is the name of a type of the module is a local name": (
        'import M from "m"\n\nstruct Item\n  n: Int\nend\n\n' + main("puts(M.first_or([1], 2))"), None, None),
    "a conflict through the alias": (
        'import M from "m"\n\n' + main('puts(M.first_or([1], "x"))'), "CHECK-TYPE-MISMATCH", '"x"'),
    "a type parameter that hides an imported name": (
        'import {Pool} from "m"\n\ndef f[Pool](x: Pool) -> Pool\n  return x\nend\n\n' + main("puts(1)"),
        "CHECK-REDEFINED-NAME", "Pool"),
}


@pytest.mark.parametrize("name", list(RULES))
def test_generic_function_rules(agentica_check, name):
    program, code, text = RULES[name]
    assert_rule(agentica_check(program), program, code, text)


@pytest.mark.parametrize("name", list(MODULE_RULES))
def test_generic_functions_across_modules(agentica_check, name):
    program, code, text = MODULE_RULES[name]
    assert_rule(agentica_check({"m.agc": LIB, "main.agc": program}), program, code, text)
