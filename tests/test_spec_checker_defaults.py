"""Default values of parameters and of struct fields (`NAME: type = expression`), through the product CLI.

A builtin row can give defaults too; `Zlib.crc32(data, seed = 0)` is the one that does, so its cases are here.

Each case writes a program (one file, or several for the import-alias rules) and runs `--json check FILE`. A rejected
program is asserted by its diagnostic code and the source text its range covers; a good one checks clean. Message and
help texts are not asserted (AGENTS.md).
"""
import pytest

from tests.spec_support import (
    assert_exact_span,
    assert_multi_file_case,
    assert_program_diagnostic,
    assert_single_file_case,
)

JOIN = 'def join(xs: List[String], sep: String = ", ") -> String\n  return xs.join(sep)\nend\n\n'

# A path, a timeout with a default and a last Fn parameter, which a block (or the last argument) fills.
EACH_LINE = ('def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void\n'
             '  f.call(path)\nend\n\n'
             'def show(line: String) -> Void\n  puts(line)\nend\n\n')


POINT = 'struct Point\n  x: Int = 0\n  y: Int\nend\n\n'


def main_with(body, helpers=""):
    return helpers + "def main() -> Void\n" + body + "end\n\n"


# (title, program, code, text the range covers): code None means the program checks clean.
SINGLE_FILE = [
    ("none is a default of an Optional field and parameter",
     'struct Conf\n  port: Optional[Int] = none\nend\n\n'
     'def f(x: Optional[Int] = none) -> Int\n  return x.unwrap_or(0)\nend\n\n'
     + main_with("  puts(Conf().port)\n  puts(f())\n"), None, None),
    ("some(...) is no default",
     'struct Conf\n  port: Optional[Int] = some(1)\nend\n\n' + main_with("  puts(Conf())\n"),
     "CHECK-DEFAULT-VALUE", "some(1)"),
    ("none() is no default",
     'struct Conf\n  port: Optional[Int] = none()\nend\n\n' + main_with("  puts(Conf())\n"),
     "CHECK-DEFAULT-VALUE", "none()"),
    ("a none default needs an Optional type",
     'struct Conf\n  port: Int = none\nend\n\n' + main_with("  puts(Conf())\n"),
     "CHECK-TYPE-MISMATCH", "none"),
    ("every constant form is a default",
     'enum Mode\n  Fast\n  Safe\nend\n\n'
     'def f(a: Int = 1, b: Int = -2, c: Float = 2.5, d: Float = -0.5, e: String = "x", g: Bool = true,'
     ' h: Bool = false, i: List[Int] = [], j: Map[String, Int] = {}, k: Mode = Mode.Safe,'
     ' l: Int = -9223372036854775808) -> Int\n'
     '  return a\nend\n\n' + main_with("  puts(f())\n"), None, None),
    ("a call may leave out 0, 1 or 2 arguments",
     'def f(a: Int, b: Int = 1, c: Int = 2) -> Int\n  return a + b + c\nend\n\n'
     + main_with("  puts(f(1))\n  puts(f(1, 2))\n  puts(f(1, 2, 3))\n"), None, None),
    ("defaults only at the end: a parameter without a default after one",
     'def f(a: Int = 1, b: Int) -> Int\n  return a + b\nend\n\n' + main_with("  puts(f(1, 2))\n"),
     "CHECK-DEFAULT-ORDER", "b: Int"),
    ("defaults only at the end: the first of several parameters without a default is the problem",
     'def f(a: Int = 1, b: Int, c: Int) -> Int\n  return a + b + c\nend\n\n' + main_with("  puts(f(1, 2, 3))\n"),
     "CHECK-DEFAULT-ORDER", "b: Int"),
    ("defaults only at the end: a last Fn parameter may stay without one",
     EACH_LINE + main_with("  each_line(\"a.txt\", 5, &show)\n"), None, None),
    ("defaults only at the end: an Fn parameter that is not the last one cannot",
     'def f(a: Int = 1, g: Fn[Int, Int], b: Int = 2) -> Int\n  return a\nend\n\n' + main_with("  puts(f(1))\n"),
     "CHECK-DEFAULT-ORDER", "g: Fn[Int, Int]"),
    ("defaults only at the end: a last parameter that is not an Fn cannot",
     'def f(a: Int = 1, b: Int) -> Int\n  return a\nend\n\n' + main_with("  puts(f(1, 2))\n"),
     "CHECK-DEFAULT-ORDER", "b: Int"),
    ("a default is a constant: a call",
     'def seed() -> Int\n  return 4\nend\n\ndef f(a: Int = seed()) -> Int\n  return a\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-DEFAULT-VALUE", "seed()"),
    ("a default may name a constant whose value is a constant form",
     'LIMIT = 10\nNEG = -2\nRATE = 0.5\nLABEL = "x"\nON = true\nMODE = Mode.Safe\n'
     'NO: Optional[Int] = none\nNONE_LIST: List[Int] = []\nNONE_MAP: Map[String, Int] = {}\n\n'
     'enum Mode\n  Fast\n  Safe\nend\n\n'
     'def f(a: Int = LIMIT, b: Int = NEG, c: Float = RATE, d: String = LABEL, e: Bool = ON, g: Mode = MODE,'
     ' h: Optional[Int] = NO, i: List[Int] = NONE_LIST, j: Map[String, Int] = NONE_MAP) -> Int\n'
     '  return a\nend\n\n' + main_with("  puts(f())\n"), None, None),
    ("a default may name an exported constant of the same file",
     'export LIMIT = 10\n\ndef f(a: Int = LIMIT) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"), None, None),
    ("a parameter default may name a constant that is a struct built with no arguments",
     'BASE = Opts()\n\nstruct Opts\n  n: Int = 1\nend\n\n'
     'def f(o: Opts = BASE) -> Int\n  return o.n\nend\n\n' + main_with("  puts(f())\n"), None, None),
    ("a default that names a constant keeps the type check: a String constant for an Int",
     'LABEL = "x"\n\ndef f(a: Int = LABEL) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", "LABEL"),
    ("a default that names a constant keeps the type check: an Int constant for a Float",
     'ONE = 1\n\ndef f(a: Float = ONE) -> Float\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", "ONE"),
    ("a default that names a constant needs a value that is a constant form: an operation",
     'SUM = 1 + 2\n\ndef f(a: Int = SUM) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "SUM"),
    ("a default that names a constant needs a value that is a constant form: a list with elements",
     'ITEMS = [1]\n\ndef f(a: List[Int] = ITEMS) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "ITEMS"),
    ("a default that names a constant needs a value that is a constant form: another constant",
     'ONE = 1\nTWO = ONE\n\ndef f(a: Int = TWO) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "TWO"),
    ("a default that names a constant is no call of a function",
     'ONE = 1\n\ndef one() -> Int\n  return ONE\nend\n\ndef f(a: Int = one()) -> Int\n  return a\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-DEFAULT-VALUE", "one()"),
    ("a default that names an unknown constant is an unknown name",
     'def f(a: Int = GONE) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-UNKNOWN-NAME", "GONE"),
    ("a default is a constant: an operation",
     'def f(a: Int = 1 + 2) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "1 + 2"),
    ("a default is a constant: a function reference",
     'def show(line: String) -> Void\nend\n\ndef f(g: Fn[String, Void] = &show) -> Void\nend\n\n'
     + main_with("  f()\n"), "CHECK-DEFAULT-VALUE", "&show"),
    ("a default is a constant: an interpolated string",
     'def f(a: String = "a#{1}b") -> String\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", '"a#{1}b"'),
    ("a default is a constant: a list with elements",
     'def f(a: List[Int] = [1]) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", "[1]"),
    ("a default is a constant: a map with entries",
     'def f(a: Map[String, Int] = {"k": 1}) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-DEFAULT-VALUE", '{"k": 1}'),
    ("a default is a constant: a struct",
     'struct Point\n  x: Int\nend\n\ndef f(p: Point = Point(x: 1)) -> Int\n  return 1\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-DEFAULT-VALUE", "Point(x: 1)"),
    ("a struct built with no arguments is a parameter default: its fields take their defaults",
     'struct Opts\n  n: Int = 1\nend\n\ndef f(o: Opts = Opts()) -> Int\n  return o.n\nend\n\n'
     + main_with("  puts(f())\n"), None, None),
    ("a struct built with no arguments needs a default on every field",
     'struct Need\n  n: Int\nend\n\ndef f(o: Need = Need()) -> Int\n  return o.n\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-MISSING-FIELD", "Need()"),
    ("a field default is not a struct, which could build its own struct again",
     'struct Opts\n  n: Int = 1\nend\n\nstruct Outer\n  o: Opts = Opts()\nend\n\n'
     + main_with("  puts(Outer().o.n)\n"), "CHECK-DEFAULT-VALUE", "Opts()"),
    ("a default is a constant: a variant with a payload",
     'enum Shape\n  Dot\n  Circle(Int)\nend\n\ndef f(s: Shape = Shape.Circle(1)) -> Int\n  return 1\nend\n\n'
     + main_with("  puts(f())\n"), "CHECK-DEFAULT-VALUE", "Shape.Circle(1)"),
    ("a default is a constant: another parameter",
     'def f(a: Int, b: Int = a) -> Int\n  return b\nend\n\n' + main_with("  puts(f(1))\n"),
     "CHECK-DEFAULT-VALUE", "a"),
    ("the type of a default is checked against the parameter",
     'def f(a: Int = "x") -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", '"x"'),
    ("[] and {} take the type of the parameter",
     'def f(a: List[String] = [], b: Map[String, Int] = {}) -> Int\n  return a.size + b.size\nend\n\n'
     + main_with("  puts(f())\n"), None, None),
    ("[] does not fit a map parameter",
     'def f(a: Map[String, Int] = []) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", "[]"),
    ("a variant of another enum does not fit the parameter",
     'enum Mode\n  Fast\nend\n\nenum Other\n  Slow\nend\n\n'
     'def f(a: Mode = Other.Slow) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-TYPE-MISMATCH", "Other.Slow"),
    ("an unknown variant is not a default",
     'enum Mode\n  Fast\nend\n\ndef f(a: Mode = Mode.Gone) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"),
     "CHECK-UNKNOWN-VARIANT", "Mode.Gone"),
    ("a builtin enum variant is a default",
     'def f(level: LogLevel = LogLevel.Info) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), None, None),
    ("a call takes between the required and the total number of arguments: too few",
     JOIN + main_with("  puts(join())\n"), "CHECK-ARITY", "join()"),
    ("a call takes between the required and the total number of arguments: too many",
     JOIN + main_with('  puts(join([], ", ", 1))\n'), "CHECK-ARITY", 'join([], ", ", 1)'),
    ("a function without defaults keeps its exact arity",
     'def two(a: Int, b: Int) -> Int\n  return a + b\nend\n\n' + main_with("  puts(two(1))\n"),
     "CHECK-ARITY", "two(1)"),
    ("arguments fill from the left: a mismatch is reported at the argument",
     JOIN + main_with("  puts(join([], 1))\n"), "CHECK-TYPE-MISMATCH", "1"),
    ("the block fills the last Fn parameter",
     EACH_LINE + main_with('  each_line("a.txt") do |line|\n    puts(line)\n  end\n'), None, None),
    ("the block fills the last Fn parameter after a given default",
     EACH_LINE + main_with('  each_line("a.txt", 50) do |line|\n    puts(line)\n  end\n'), None, None),
    ("the last argument fills the last Fn parameter",
     EACH_LINE + main_with('  each_line("a.txt", 50, &show)\n  each_line("a.txt", &show)\n'), None, None),
    ("the last argument goes to the Fn parameter, so a number there is a type error, not an arity error",
     EACH_LINE + main_with('  each_line("a.txt", 50)\n'), "CHECK-TYPE-MISMATCH", "50"),
    ("a call with only the path and no Fn is an arity error",
     EACH_LINE + main_with("  each_line()\n"), "CHECK-ARITY", "each_line()"),
    ("a piped value is the first argument and the defaults follow",
     JOIN + main_with('  puts(["a"] |> join())\n'), None, None),
    ("a function value takes every argument: the call with all of them",
     JOIN + main_with('  f = &join\n  puts(f.call(["a"], ", "))\n'), None, None),
    ("a function value takes every argument: the call with fewer is an arity error",
     JOIN + main_with('  f = &join\n  puts(f.call(["a"]))\n'), "CHECK-ARITY", 'f.call(["a"])'),
    ("a function value has the type with every parameter",
     JOIN + main_with('  f: Fn[List[String], String, String] = &join\n  puts(f.call(["a"], "-"))\n'), None, None),
    ("a builtin call may leave out the trailing parameter with a default, or give it",
     main_with('  puts(Zlib.crc32("ab".bytes).unwrap!)\n  puts(Zlib.crc32("ab".bytes, 7).unwrap!)\n'), None, None),
    ("a piped call of a builtin leaves out the default",
     main_with('  puts(("ab".bytes |> Zlib.crc32()).unwrap!)\n'), None, None),
    ("a builtin call with fewer arguments than it requires is an arity error",
     main_with("  puts(Zlib.crc32())\n"), "CHECK-ARITY", "Zlib.crc32()"),
    ("a builtin call with more arguments than it has parameters is an arity error",
     main_with('  puts(Zlib.crc32("a".bytes, 0, 1))\n'), "CHECK-ARITY", 'Zlib.crc32("a".bytes, 0, 1)'),
    ("a builtin default does not change the type of a given argument",
     main_with('  puts(Zlib.crc32("a".bytes, "x"))\n'), "CHECK-TYPE-MISMATCH", '"x"'),
    ("a filesystem builtin may leave out the timeout, and File.open the mode and the timeout",
     main_with('  puts(File.read_text("a.txt"))\n  puts(File.stat("a.txt", 50))\n  puts(Path.rename("a", "b"))\n'
               '  a = File.open("a.txt")\n  b = File.open("a.txt", "write")\n'
               '  c = File.open("a.txt", "append", 50)\n'), None, None),
    ("a filesystem builtin timeout is still an Int",
     main_with('  puts(Dir.list("d", "soon"))\n'), "CHECK-TYPE-MISMATCH", '"soon"'),
    ("a file handle call and each_line, foreach and write_lines may leave out the timeout",
     main_with('  f = File.open("a.txt").unwrap!\n  puts(File.read_line(f))\n  puts(File.write(f, "x"))\n'
               '  puts(File.close(f, 50))\n  puts(File.read_bytes(f, 4))\n  puts(File.flush(f))\n'
               '  puts(File.write_bytes(f, "a".bytes))\n  puts(File.try_lock(f))\n'
               '  File.each_line("a.txt", 4096) do |l|\n    ok()\n  end\n'
               '  File.each_line("a.txt") do |line|\n    puts(line)\n    ok()\n  end\n'
               '  puts(File.foreach("a.txt").first(1))\n  puts(File.foreach("a.txt", 4096).first(1))\n'
               '  puts(File.foreach("a.txt").write_lines("b.txt"))\n'), None, None),
    ("the process starts may leave out the timeout, and the captured ones the directory too",
     main_with('  a = Process.spawn("ls", ["-l"])\n  b = Process.spawn("ls", [], 50)\n'
               '  c = Process.spawn_captured("ls", [])\n  d = Process.spawn_captured("ls", [], "d")\n'
               '  e = Process.spawn_channel("ls", [], "d", 50)\n  f = Process.spawn_channel("ls", [])\n'), None, None),
    ("Process.spawn_captured still needs its command and arguments",
     main_with('  c = Process.spawn_captured("ls")\n'), "CHECK-ARITY", 'Process.spawn_captured("ls")'),
    ("TlsClientOptions may leave out every field, and HttpClientOptions its tls, which is none",
     main_with('  a = TLS.client_context(TlsClientOptions())\n  b = TlsClientOptions(ca_file: "ca.pem")\n'
               '  c = HttpClientOptions()\n  d: Optional[TlsContext] = c.tls\n'
               '  e = HttpClientOptions(tls: some(a.unwrap!))\n'), None, None),
    ("alpn is a list of protocol names that both options records may leave out",
     main_with('  a = TlsClientOptions(alpn: ["h2", "http/1.1"])\n'
               '  b = TlsServerOptions(cert_file: "c.pem", key_file: "k.pem")\n  c: List[String] = b.alpn\n'),
     None, None),
    ("alpn takes a list of names, not one name",
     main_with('  a = TlsClientOptions(alpn: "h2")\n'), "CHECK-TYPE-MISMATCH", '"h2"'),
    ("TlsServerOptions has no default key pair",
     main_with('  a = TlsServerOptions(cert_file: "c.pem")\n'), "CHECK-MISSING-FIELD", 'TlsServerOptions(cert_file: "c.pem")'),
    ("HttpClientOptions holds a TlsContext, so JSON cannot decode it",
     main_with('  puts(JSON.decode("{}", HttpClientOptions).ok?)\n'), "CHECK-NOT-DECODABLE", "HttpClientOptions"),
    ("File.open still needs its path",
     main_with("  puts(File.open())\n"), "CHECK-ARITY", "File.open()"),
    ("File.open with a block takes the block form, which may leave out the mode and the timeout too",
     'def size(f: FileHandle) -> Result[Int]\n  return ok((try File.read_line(f)).size)\nend\n\n'
     + main_with('  a = File.open("a.txt") do |f|\n    ok(try File.read_line(f))\n  end\n  puts(a)\n'
                 '  b: Result[List[Int]] = File.open("a.txt", "write") do |_|\n    ok([])\n  end\n  puts(b)\n'
                 '  c = File.open("a.txt", "append", 50) do |f|\n    try File.write(f, "x")\n    ok()\n  end\n'
                 '  puts(c)\n  puts(File.open("a.txt", "read", 50, &size))\n'), None, None),
    ("File.open with too many arguments and a block is an arity error, not a missing block target",
     main_with('  File.open("a.txt", "read", 10, 5) do |f|\n    ok(1)\n  end\n'), "CHECK-ARITY",
     'File.open("a.txt", "read", 10, 5) do |f|\n    ok(1)\n  end'),
    ("the block of File.open gives a Result",
     main_with('  puts(File.open("a.txt") do |_|\n    5\n  end)\n'), "CHECK-TYPE-MISMATCH", "5"),
    ("the expected type of File.open with a block is the Result its block gives",
     main_with('  r: Result[Int] = File.open("a.txt") do |_|\n    ok("s")\n  end\n  puts(r)\n'),
     "CHECK-TYPE-MISMATCH", '"s"'),
    ("the block of File.open gets a FileHandle",
     main_with('  puts(File.open("a.txt") do |f|\n    ok(File.read_text(f))\n  end)\n'), "CHECK-TYPE-MISMATCH", "f"),
    ("a builtin has no function value, defaults or not",
     main_with("  f = &Zlib.crc32\n"), "CHECK-UNKNOWN-NAME", "&Zlib.crc32"),
    ("main takes no parameters, defaults included",
     'def main(a: Int = 1) -> Void\n  puts(a)\nend\n\n', "CHECK-MAIN", None),
    ("a block parameter takes no default",
     main_with("  [1].each do |x = 1|\n    puts(x)\n  end\n"), "PARSE-UNEXPECTED-TOKEN", "="),
    ("a default needs an expression after the sign",
     'def f(a: Int =) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), "PARSE-UNEXPECTED-TOKEN", ")"),
    ("a parameter needs its type even with a default",
     'def f(a = 1) -> Int\n  return 1\nend\n\n' + main_with("  puts(f())\n"), "PARSE-UNEXPECTED-TOKEN", "="),
    ("a constructor may leave out a field with a default, or give it",
     'enum Mode\n  Fast\n  Safe\nend\n\n'
     'struct Options\n  name: String\n  a: Int = 1\n  b: Int = -2\n  c: Float = 2.5\n  d: String = "x"\n'
     '  e: Bool = true\n  f: List[Int] = []\n  g: Map[String, Int] = {}\n  h: Mode = Mode.Safe\nend\n\n'
     + main_with('  puts(Options(name: "n").inspect)\n  puts(Options(h: Mode.Fast, name: "n", a: 2).inspect)\n'),
     None, None),
    ("a struct with only defaults is built with no fields",
     'struct Box\n  w: Int = 1\n  h: Int = 2\nend\n\n' + main_with("  puts(Box().inspect)\n"), None, None),
    ("a field without a default must still be given",
     POINT + main_with("  puts(Point(x: 1).inspect)\n"), "CHECK-MISSING-FIELD", "Point(x: 1)"),
    ("a field without a default must still be given, even when every other field has one",
     POINT + main_with("  puts(Point().inspect)\n"), "CHECK-MISSING-FIELD", "Point()"),
    ("a field that has a default cannot be given twice",
     POINT + main_with("  puts(Point(x: 1, y: 2, x: 3).inspect)\n"), "CHECK-DUPLICATE-FIELD", "x: 3"),
    ("an extra field is still unknown",
     POINT + main_with("  puts(Point(y: 2, z: 3).inspect)\n"), "CHECK-UNKNOWN-FIELD", "z: 3"),
    ("a field default is a constant: a call",
     'struct S\n  a: Int = seed()\nend\n\ndef seed() -> Int\n  return 4\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "seed()"),
    ("a field default is a constant: an operation",
     'struct S\n  a: Int = 1 + 2\nend\n\n' + main_with("  puts(S().inspect)\n"), "CHECK-DEFAULT-VALUE", "1 + 2"),
    ("a field default may name a constant whose value is a constant form",
     'LIMIT = 10\nLABEL = "x"\nNONE_LIST: List[Int] = []\n\n'
     'struct S\n  a: Int = LIMIT\n  b: String = LABEL\n  c: List[Int] = NONE_LIST\nend\n\n'
     + main_with("  puts(S().inspect)\n"), None, None),
    ("a field default may name a constant in a generic struct",
     'LIMIT = 10\n\nstruct Box[T]\n  size: Int = LIMIT\n  item: T\nend\n\n'
     + main_with('  puts(Box(item: "x").inspect)\n  puts(Box(item: 1, size: 2).inspect)\n'), None, None),
    ("a field default that names a constant keeps the type check",
     'LABEL = "x"\n\nstruct S\n  a: Int = LABEL\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-TYPE-MISMATCH", "LABEL"),
    ("a field default that names a constant needs a value that is a constant form",
     'SUM = 1 + 2\n\nstruct S\n  a: Int = SUM\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "SUM"),
    ("a field default is not a constant that is a struct, which could build its own struct again",
     'BASE = Opts()\n\nstruct Opts\n  n: Int = 1\nend\n\nstruct Outer\n  o: Opts = BASE\nend\n\n'
     + main_with("  puts(Outer().o.n)\n"), "CHECK-DEFAULT-VALUE", "BASE"),
    ("a field default is a constant: a list with elements",
     'struct S\n  a: List[Int] = [1]\nend\n\n' + main_with("  puts(S().inspect)\n"), "CHECK-DEFAULT-VALUE", "[1]"),
    ("a field default is a constant: a struct",
     POINT + 'struct S\n  p: Point = Point(y: 1)\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "Point(y: 1)"),
    ("a field default is a constant: another field",
     'struct S\n  a: Int = 1\n  b: Int = a\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-DEFAULT-VALUE", "a"),
    ("the type of a field default is checked against the field",
     'struct S\n  a: Int = "x"\nend\n\n' + main_with("  puts(S().inspect)\n"), "CHECK-TYPE-MISMATCH", '"x"'),
    ("[] does not fit a map field",
     'struct S\n  a: Map[String, Int] = []\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-TYPE-MISMATCH", "[]"),
    ("an unknown variant is not a field default",
     'enum Mode\n  Fast\nend\n\nstruct S\n  a: Mode = Mode.Gone\nend\n\n' + main_with("  puts(S().inspect)\n"),
     "CHECK-UNKNOWN-VARIANT", "Mode.Gone"),
    ("a field default needs an expression after the sign",
     'struct S\n  a: Int =\nend\n\n' + main_with("  puts(S().inspect)\n"), "PARSE-UNEXPECTED-TOKEN", "\n"),
    ("a field default of a struct that is never built is still checked",
     'struct S\n  a: Int = 1 + 1\nend\n\n' + main_with("  puts(1)\n"), "CHECK-DEFAULT-VALUE", "1 + 1"),
    ("with changes a field and leaves the others, defaults included",
     POINT + main_with("  puts(Point(y: 1).with(x: 5).inspect)\n"), None, None),
    ("a builtin record with catalog defaults may leave every field out",
     main_with("  c = HttpClientOptions()\n  s = HttpServerOptions(max_connections: 1)\n  puts(c.timeout_ms)\n"),
     None, None),
    ("a field of a builtin record without a catalog default must still be given",
     main_with('  h = Header(name: "a")\n  puts(h.name)\n'), "CHECK-MISSING-FIELD", 'Header(name: "a")'),
]

# Several files: (title, files, code, file of the diagnostic, text the range covers).
MODULES = [
    ("a call through an import alias leaves out the defaults",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import Util from "util"\n\n'
                  + main_with('  puts(Util.join(["a"]))\n  puts(Util.join(["a"], "-"))\n')},
     None, None, None),
    ("an alias call without parentheses fills every default",
     {"util.agc": 'export def connect(host: String = "localhost", port: Int = 8080) -> String\n'
                  '  return "#{host}:#{port}"\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  x = Util.connect\n  puts(x)\n")},
     None, None, None),
    ("an alias call without parentheses and a required parameter is an arity error",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import Util from "util"\n\n' + main_with("  x = Util.join\n  puts(x)\n")},
     "CHECK-ARITY", "root.agc", "Util.join"),
    ("an alias call with too many arguments is an arity error",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import Util from "util"\n\n' + main_with('  puts(Util.join([], ",", 1))\n')},
     "CHECK-ARITY", "root.agc", 'Util.join([], ",", 1)'),
    ("a default that names a variant through an import alias is resolved in the declaring module",
     {"models.agc": "export enum Level\n  Info\n  Warn\nend\n\n",
      "util.agc": 'import Models from "models"\n\n'
                  'export def pick(level: Models.Level = Models.Level.Warn) -> Models.Level\n  return level\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  x = Util.pick()\n  puts(x)\n")},
     None, None, None),
    ("a default that names a private enum of its module can be left out by another module",
     {"util.agc": 'enum Mode\n  Fast\n  Safe\nend\n\n'
                  'export def pick(mode: Mode = Mode.Safe) -> String\n  return "#{mode}"\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  puts(Util.pick())\n")},
     None, None, None),
    ("a default may name a constant through an import alias or an imported name",
     {"limits.agc": "export LIMIT = 10\nexport LABEL = \"x\"\nexport NEG = -1\n",
      "root.agc": 'import Limits from "limits"\nimport {LIMIT as CAP, NEG} from "limits"\n\n'
                  'struct Conf\n  a: Int = Limits.LIMIT\n  b: Int = CAP\n  c: Int = NEG\nend\n\n'
                  'def f(a: Int = Limits.LIMIT, b: String = Limits.LABEL, c: Int = CAP, d: Int = NEG) -> Int\n'
                  '  return a\nend\n\n' + main_with("  puts(f())\n  puts(Conf().inspect)\n")},
     None, None, None),
    ("a default that names an imported constant is resolved in the declaring module",
     {"limits.agc": "LIMIT = 10\n\nexport struct Conf\n  a: Int = LIMIT\nend\n\n"
                    "export def f(a: Int = LIMIT) -> Int\n  return a\nend\n\n",
      "root.agc": 'import Limits from "limits"\n\n' + main_with("  puts(Limits.f())\n  puts(Limits.Conf().inspect)\n")},
     None, None, None),
    ("a default that names an imported constant needs a value that is a constant form",
     {"limits.agc": "export SUM = 1 + 2\n",
      "root.agc": 'import Limits from "limits"\n\n'
                  'def f(a: Int = Limits.SUM) -> Int\n  return a\nend\n\n' + main_with("  puts(f())\n")},
     "CHECK-DEFAULT-VALUE", "root.agc", "SUM"),
    ("two modules may declare a constant of one name: a default is judged by the module it names",
     {"first.agc": "export LIMIT = 10\n",
      "second.agc": "export LIMIT = 1 + 2\n",
      "root.agc": 'import {LIMIT as CAP} from "first"\nimport Second from "second"\n\n'
                  'def f(a: Int = CAP) -> Int\n  return a\nend\n\n'
                  'def g(a: Int = Second.LIMIT) -> Int\n  return a\nend\n\n' + main_with("  puts(f() + g())\n")},
     "CHECK-DEFAULT-VALUE", "root.agc", "LIMIT"),
    ("a default that names an imported constant keeps the type check",
     {"limits.agc": "export LABEL = \"x\"\n",
      "root.agc": 'import {LABEL} from "limits"\n\n'
                  'struct S\n  a: Int = LABEL\nend\n\n' + main_with("  puts(S().inspect)\n")},
     "CHECK-TYPE-MISMATCH", "root.agc", "LABEL"),
    ("a bad default in an imported file is reported in that file",
     {"util.agc": 'export def pick(n: Int = 1 + 1) -> Int\n  return n\nend\n\n',
      "root.agc": 'import Util from "util"\n\n' + main_with("  puts(Util.pick())\n")},
     "CHECK-DEFAULT-VALUE", "util.agc", "1 + 1"),
    ("a named import of a function with defaults leaves them out",
     {"util.agc": "export " + JOIN,
      "root.agc": 'import {join} from "util"\n\n' + main_with('  puts(join(["a"]))\n')},
     None, None, None),
    ("a struct with defaults, exported, is built by another file that leaves them out",
     {"models.agc": 'export enum Level\n  Info\n  Warn\nend\n\n'
                    'export struct Options\n  name: String\n  level: Level = Level.Warn\n  retries: Int = 3\nend\n\n',
      "root.agc": 'import Models from "models"\n\n'
                  + main_with('  puts(Models.Options(name: "a").inspect)\n'
                              '  puts(Models.Options(name: "a", retries: 1).inspect)\n')},
     None, None, None),
    ("a field default that names a private enum of its module can be left out by another module",
     {"models.agc": 'enum Mode\n  Fast\n  Safe\nend\n\nexport struct S\n  mode: Mode = Mode.Safe\nend\n\n',
      "root.agc": 'import Models from "models"\n\n' + main_with("  puts(Models.S().inspect)\n")},
     None, None, None),
    ("a field of an imported struct without a default must still be given",
     {"models.agc": 'export struct S\n  a: Int\n  b: Int = 1\nend\n\n',
      "root.agc": 'import Models from "models"\n\n' + main_with("  puts(Models.S(b: 2).inspect)\n")},
     "CHECK-MISSING-FIELD", "root.agc", "Models.S(b: 2)"),
    ("a bad field default in an imported file is reported in that file",
     {"models.agc": 'export struct S\n  a: Int = 1 + 1\nend\n\n',
      "root.agc": 'import Models from "models"\n\n' + main_with("  puts(Models.S().inspect)\n")},
     "CHECK-DEFAULT-VALUE", "models.agc", "1 + 1"),
]


@pytest.mark.parametrize(
    ("title", "program", "code", "text"),
    SINGLE_FILE,
    ids=[case[0] for case in SINGLE_FILE],
)
def test_single_file_programs(title, program, code, text, agentica_check):
    assert_single_file_case(agentica_check, program, code, text, assert_exact_span)


@pytest.mark.parametrize(
    ("title", "files", "code", "file", "text"),
    MODULES,
    ids=[case[0] for case in MODULES],
)
def test_programs_of_several_files(title, files, code, file, text, agentica_check):
    assert_multi_file_case(agentica_check, files, code, file, text, assert_exact_span)


# The forms before contexts, and a context where its Optional goes, carry a help: (title, program, code, text the range
# covers). Only the presence of the help is asserted, not its text.
HELPED = [
    ("a TlsContext where HttpClientOptions takes its Optional",
     main_with('  c = TLS.client_context(TlsClientOptions()).unwrap!\n  a = HttpClientOptions(tls: c)\n'),
     "CHECK-TYPE-MISMATCH", "c"),
    ("a CA file where HttpClientOptions takes an Optional[TlsContext]",
     main_with('  a = HttpClientOptions(tls: "ca.pem")\n'), "CHECK-TYPE-MISMATCH", '"ca.pem"'),
    ("a CA file where TLS.connect takes a TlsContext",
     main_with('  a = TLS.connect("h", 1, "", 50)\n'), "CHECK-TYPE-MISMATCH", '""'),
    ("TLS.listen with the PEM paths",
     main_with('  a = TLS.listen("h", 0, "c.pem", "k.pem")\n'), "CHECK-ARITY", 'TLS.listen("h", 0, "c.pem", "k.pem")'),
]


@pytest.mark.parametrize(("title", "program", "code", "text"), HELPED, ids=[case[0] for case in HELPED])
def test_old_tls_forms_have_a_help(title, program, code, text, agentica_check):
    found = assert_program_diagnostic(agentica_check, program, code)
    assert_exact_span(program, found["range"], text)
    assert found.get("help"), found
