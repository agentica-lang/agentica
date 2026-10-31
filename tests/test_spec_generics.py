"""Generic functions (`def first_or[T](...)`) through the product CLI: the rules and their diagnostic codes and spans.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers.
A program that must check clean has no code.
"""

import time

import pytest

from tests.agentica_test import scaled
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
YES = "def yes[T](x: T) -> Bool\n  return true\nend\n\n"
ENCODES = (
    BOX
    + "def show[T](value: T) -> String\n  return JSON.encode(value)\nend\n\n"
    "def wrap[T](value: T) -> String\n  return show(Box(value: value))\nend\n\n"
    "def maybe[T](value: Optional[T]) -> String\n  return JSON.encode(value)\nend\n\n"
)


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


def declared(*lines: str, header: str = FIRST_OR) -> str:
    return header + main(*lines)


def elements(*lines: str, header: str = "") -> str:
    """A generic function `f[T](xs: List[T], m: Map[String, T])` whose body is the lines, and a main that calls it."""
    function = "def f[T](xs: List[T], m: Map[String, T]) -> Void\n" + "".join("  %s\n" % line for line in lines)
    return header + function + "end\n\n" + main("f([1], {\"a\": 1})")


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
    # A default that does not depend on T is allowed, as on a field of a generic struct; one of another type fails its
    # type check.
    "an empty list default of a type parameter's type": (
        "def f[T](x: T, xs: List[T] = []) -> Int\n  return xs.size\nend\n\n" + main("puts(f(1))"), None, None),
    "an empty map default of a type parameter's type": (
        "def f[T](x: T, m: Map[String, T] = {}) -> Int\n  return m.size\nend\n\n" + main("puts(f(1))"), None, None),
    "a none default of a type parameter's type": (
        "def f[T](x: T, y: Optional[T] = none) -> Bool\n  return y.some?\nend\n\n" + main("puts(f(1, some(2)))"),
        None, None),
    "a default of another type than T": (
        "def f[T](x: T = 1) -> Int\n  return 0\nend\n\n" + main("puts(f(2))"), "CHECK-TYPE-MISMATCH", "1"),
    "a call that gives T only through a default": (
        "def f[T](y: Optional[T] = none) -> Int\n  return 0\nend\n\n" + main("puts(f())"),
        "CHECK-ENUM-TYPE-INFERENCE", "f()"),
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
    # JSON.encode and JSON.from on a type with T are checked where a call binds T: the argument that binds it is the
    # span, and a generic caller passes the need on to its own callers.
    "JSON.encode of T": (body("z = JSON.encode(x)"), None, None),
    "JSON.from of a list of T and JSON.encode of a map of T": (
        elements("a = JSON.from(xs)", "b = JSON.encode(m)"), None, None),
    "JSON.encode of a Task of T": (body("t = Task.spawn do x end", "z = JSON.encode(t)"), "CHECK-NOT-ENCODABLE", "t"),
    "calls that bind encodable types": (
        ENCODES + ID + main("puts(show(1))", "puts(wrap([1]))", "puts(maybe(some(1)))", "g: Fn[Int, String] = &show",
                            "puts(g.call(2))"), None, None),
    "a call that binds an Fn": (ENCODES + ID + main("puts(show(&id))"), "CHECK-NOT-ENCODABLE", "&id"),
    "a call that binds Bytes": (ENCODES + main('puts(show("a".bytes))'), "CHECK-NOT-ENCODABLE", '"a".bytes'),
    "a call that binds a Task": (
        ENCODES + main("puts(show(Task.spawn do 1 end))"), "CHECK-NOT-ENCODABLE", "Task.spawn do 1 end"),
    "a generic caller passes the need on": (
        ENCODES + main('puts(wrap("a".bytes))'), "CHECK-NOT-ENCODABLE", '"a".bytes'),
    "a callee declared after its generic caller": (
        "def outer[T](value: T) -> String\n  return inner([value])\nend\n\n"
        "def inner[U](values: List[U]) -> String\n  return JSON.encode(values)\nend\n\n"
        + main('puts(outer("a".bytes))'), "CHECK-NOT-ENCODABLE", '"a".bytes'),
    "a reference that binds Bytes": (
        ENCODES + main("g: Fn[Bytes, String] = &show"), "CHECK-NOT-ENCODABLE", "&show"),
    "JSON.decode to T": (body('z = JSON.decode("{}", T)'), "CHECK-NOT-DECODABLE", "T"),
    "T as a Map key": (
        "def f[T](m: Map[T, Int]) -> Int\n  return 0\nend\n\n" + main("puts(1)"), "CHECK-MAP-KEY-TYPE", "T"),
    "T as a Set element": (
        "def f[T](s: Set[T]) -> Int\n  return 0\nend\n\n" + main("puts(1)"), "CHECK-SET-ELEMENT-TYPE", "T"),
    "T as a Map key does not become valid with Int": (
        "def f[T](m: Map[T, Int]) -> Int\n  return 0\nend\n\n" + main("puts(f({1: 2}))"), "CHECK-MAP-KEY-TYPE", "T"),
    "find and group_by on a List of T": (
        elements("a = xs.find do |a: T| true end", "g = xs.group_by do |x| \"k\" end", "puts(g.size)"), None, None),
    "the other block methods on a List of T": (
        elements("xs.each_with_index do |x, i|", "  puts(i)", "end", "puts(xs.take_while do |x| true end.size)",
                 "puts(xs.partition do |x| true end.size)", "puts(xs.min_by do |x| 1 end.ok?)",
                 "puts(xs.flat_map do |x| [x] end.size)"), None, None),
    "each and filter on a Map of T": (
        elements("m.each do |k, v|", "  puts(k)", "end", "puts(m.filter do |k, v| true end.size)"), None, None),
    "lazy filter on a List of T": (elements("l = xs.lazy.filter do |x| true end", "puts(1)"), None, None),
    "a generic function reference as the callback of filter": (
        elements("puts(xs.filter(&yes).size)", header=YES), None, None),
    "Void in a parameter type is CHECK-VOID-TYPE at the call": (
        "def hold[R](xs: List[R], f: Fn[Int, R]) -> Int\n  return xs.size\nend\n\n"
        + main("n = hold([]) do |x|", "  puts(x)", "end", "puts(n)"), "CHECK-VOID-TYPE",
        "hold([]) do |x|\n    puts(x)\n  end"),
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


CODEC = (
    "struct User\n  name: String\nend\n\n"
    "struct Bad\n  f: Fn[Int, Int]\nend\n\n"
    "def body_as[T](body: String, codec: JSON.Codec[T]) -> Result[T]\n  return codec.decode(body)\nend\n\n"
    "def show[T](codec: JSON.Codec[T], value: T) -> String\n  return codec.encode(value)\nend\n\n"
)


def with_codec(*lines: str, header: str = "") -> str:
    """The structs User and Bad, the generic functions body_as and show, and a main with `c = JSON.codec(User)`
    then the lines."""
    return header + CODEC + main("c = JSON.codec(User)", *lines)


CODEC_RULES = {
    "generic code decodes and encodes through a codec": (
        with_codec('u = body_as("{}", c).unwrap!', "puts(show(c, u))", "j: Json = c.from(u)",
                   "puts(c.decode(j).ok?)"), None, None),
    "a codec is a struct field": (
        with_codec("h = Holder(codec: c)", 'puts(h.codec.decode("{}").ok?)',
                   header="struct Holder\n  codec: JSON.Codec[User]\nend\n\n"), None, None),
    "JSON.codec of a struct that cannot be decoded": (with_codec("b = JSON.codec(Bad)"), "CHECK-NOT-DECODABLE", "Bad"),
    "JSON.codec of a value": (with_codec('b = JSON.codec("User")'), "CHECK-TYPE-MISMATCH", '"User"'),
    "JSON.codec of a type variable": (body("c = JSON.codec(T)"), "CHECK-NOT-DECODABLE", "T"),
    "decode of a source that is no text or Json": (with_codec("r = c.decode(1)"), "CHECK-TYPE-MISMATCH", "1"),
    "encode of a value of another type": (with_codec("s = c.encode(1)"), "CHECK-TYPE-MISMATCH", "1"),
    "the value and the codec of a generic call disagree": (
        with_codec("puts(show(c, 1))"), "CHECK-TYPE-MISMATCH", "1"),
    "a codec of another struct": (
        with_codec("o: JSON.Codec[Other] = c", header="struct Other\n  n: Int\nend\n\n"), "CHECK-TYPE-MISMATCH",
        "c"),
    "a codec has no to_s": (with_codec("puts(c)"), "CHECK-TYPE-MISMATCH", "c"),
    "a codec has no equality": (with_codec("puts(c == c)"), "CHECK-TYPE-MISMATCH", "=="),
    "a codec has no other method": (with_codec("puts(c.parse)"), "CHECK-UNKNOWN-METHOD", "c.parse"),
    "a codec is no ATS value": (
        with_codec("t: ATS[String, JSON.Codec[User]] = ATS.new()"), "CHECK-ATS-VALUE", "JSON.Codec[User]"),
    "a codec is no constant": ("USERS = JSON.codec(User)\n\n" + with_codec("puts(1)"), "CHECK-CONSTANT-TYPE",
                               "JSON.codec(User)"),
    "a struct with a codec cannot be encoded": (
        with_codec("puts(JSON.encode(Holder(codec: c)))", header="struct Holder\n  codec: JSON.Codec[User]\nend\n\n"),
        "CHECK-NOT-ENCODABLE", "Holder(codec: c)"),
    "JSON.Codec needs its type argument": (with_codec("d: JSON.Codec = c"), "CHECK-UNKNOWN-TYPE", "JSON.Codec"),
    "a codec cannot be inspected": (with_codec("IO.inspect(c)"), "CHECK-TYPE-MISMATCH", "c"),
    "a struct that holds a codec cannot be inspected": (
        with_codec("IO.inspect(Holder(codec: c))", header="struct Holder\n  codec: JSON.Codec[User]\nend\n\n"),
        "CHECK-TYPE-MISMATCH", "Holder(codec: c)"),
    "IO.inspect of a function field that takes a codec stays valid": (
        with_codec("IO.inspect(Hold(f: &body_as))",
                   header="struct Hold\n  f: Fn[String, JSON.Codec[User], Result[User]]\nend\n\n"), None, None),
    "the methods of a codec have no function form": (
        with_codec('r = JSON.Codec.decode(c, "{}")'), "CHECK-UNKNOWN-NAME", 'JSON.Codec.decode(c, "{}")'),
}


@pytest.mark.parametrize("name", list(RULES))
def test_generic_function_rules(agentica_check, name):
    program, code, text = RULES[name]
    assert_rule(agentica_check(program), program, code, text)


@pytest.mark.parametrize("name", list(MODULE_RULES))
def test_generic_functions_across_modules(agentica_check, name):
    program, code, text = MODULE_RULES[name]
    assert_rule(agentica_check({"m.agc": LIB, "main.agc": program}), program, code, text)


def nest(depth: int, use: str) -> str:
    """`depth` generic structs, each holding its parameter twice, one inside the other, and a function that prints or
    encodes a value of the whole nest."""
    structs = "".join("struct P%d[T]\n  a: T\n  b: T\nend\n\n" % level for level in range(1, depth + 1))
    kind = "Int"
    for level in range(depth, 0, -1):
        kind = "P%d[%s]" % (level, kind)
    action = {"puts": "puts(x)", "json": "puts(JSON.encode(x))"}[use]
    return structs + "def f(x: %s) -> Void\n  %s\nend\n\n" % (kind, action) + main("puts(1)")


@pytest.mark.parametrize("use", ["puts", "json"])
def test_a_deep_nest_of_generic_instances_checks_fast(agentica_check, use):
    # The type arguments are tested once and the fields once for each level; a test that walked the fields with the
    # arguments put in took seconds at this depth.
    started = time.monotonic()
    assert agentica_check(nest(12, use)) is None
    assert time.monotonic() - started < scaled(2)


def cluster(size: int, use: str) -> str:
    """`size` generic structs that each hold a list of every one of them, with the parameter and with Nil, and a
    function that prints or encodes the first."""
    structs = ""
    for level in range(size):
        fields = "".join(
            "  a%d: List[S%d[T]]\n  b%d: List[S%d[Nil]]\n" % (other, other, other, other) for other in range(size))
        structs += "struct S%d[T]\n  v: T\n%send\n\n" % (level, fields)
    action = {"puts": "puts(x)", "json": "puts(JSON.encode(x))"}[use]
    return structs + "def f(x: S0[Int]) -> Void\n  %s\nend\n\n" % action + main("puts(1)")


def shapes(count: int) -> str:
    """One struct of `count` parameters with a list of itself for every mix of Nil and Int arguments."""
    names = ["T%d" % index for index in range(count)]
    fields = "".join(
        "  r%d: List[W[%s]]\n" % (mix, ", ".join("Nil" if mix >> bit & 1 else "Int" for bit in range(count)))
        for mix in range(2 ** count))
    kind = "W[%s]" % ", ".join(["Int"] * count)
    return (
        "struct W[%s]\n  v: T0\n%send\n\n" % (", ".join(names), fields)
        + "def f(x: %s) -> Void\n  puts(JSON.encode(x))\nend\n\n" % kind + main("puts(1)"))


@pytest.mark.parametrize("use", ["puts", "json"])
def test_a_cluster_of_structs_that_use_one_another_checks_fast(agentica_check, use):
    # The walk keeps the structs it entered for the whole call; one that kept only the path walked the cluster once for
    # each path through it (a minute at this size).
    started = time.monotonic()
    assert agentica_check(cluster(6, use)) is None
    assert time.monotonic() - started < scaled(2)


def test_a_struct_with_every_nil_shape_of_its_arguments_checks_fast(agentica_check):
    started = time.monotonic()
    assert agentica_check(shapes(4)) is None
    assert time.monotonic() - started < scaled(2)


@pytest.mark.parametrize("name", list(CODEC_RULES))
def test_json_codec_rules(agentica_check, name):
    program, code, text = CODEC_RULES[name]
    assert_rule(agentica_check(program), program, code, text)


def test_a_codec_crosses_modules(agentica_check):
    lib = (
        "export struct User\n  name: String\nend\n\n"
        "export def users() -> JSON.Codec[User]\n  return JSON.codec(User)\nend\n\n"
        "export def show[T](codec: JSON.Codec[T], value: T) -> String\n  return codec.encode(value)\nend\n"
    )
    program = 'import M from "m"\n\n' + main('u = M.users().decode("{}").unwrap!', "puts(M.show(M.users(), u))")
    assert_rule(agentica_check({"m.agc": lib, "main.agc": program}), program, None, None)
