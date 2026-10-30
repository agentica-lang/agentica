"""The extern blocks of docs/grammar/05-syntax.md through `agentica --json check`: what the parser accepts, the
PARSE-EXTERN-* codes and their spans, and the checker's view of an extern function as an ordinary one with Agentica
types. `check` loads no library, so these cases hold on every system. Tests assert codes and spans, never messages.
"""
import json

import pytest

from tests.agentica_test import cli, run

VALID = """extern "libm.so.6"
  ## The cosine of x.
  export def cos(x: C.Double) -> C.Double
  ## Runs on the compute pool.
  export compute def crunch(n: C.Int64) -> C.Double

  def labs(n: C.Long) -> C.Long
end

extern "/opt/peer/libpeer.so"
  def peer(a: C.Int32, b: C.Bool, s: C.String) -> Void
  compute def tick() -> Void
end

def main() -> Void
  peer(labs(-1), cos(0.0) > 0.5, "x")
  tick()
  puts(crunch(3) + 0.5)
end
"""


def source(tmp_path, text, name="program.agc"):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return str(path)


def check(path):
    return run(cli() + ["--json", "check", path])


def problem_of(result):
    assert result.code == 1, result.stdout + result.stderr
    return json.loads(result.stderr.strip().split("\n")[-1])


def at(problem):
    start, end = problem["range"]["start"], problem["range"]["end"]
    return problem["code"], (start["line"], start["column"]), (end["line"], end["column"])


def assert_checks(result, code, start, stop):
    """A check RESULT is ok when CODE is None, else the diagnostic CODE from START to STOP."""
    if code is None:
        assert (result.code, result.stdout) == (0, '{"ok":true}\n')
    else:
        assert at(problem_of(result)) == (code, start, stop)


def test_an_extern_block_declares_functions_that_check_like_any_other(tmp_path):
    result = check(source(tmp_path, VALID))
    assert (result.code, result.stdout) == (0, '{"ok":true}\n')


def test_an_exported_extern_function_is_imported_with_its_agentica_types(tmp_path):
    source(tmp_path, 'extern "libm.so.6"\n  export def cos(x: C.Double) -> C.Double\nend\n', "raw.agc")
    good = 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.cos(1.0) + 1.5)\nend\n'
    assert check(source(tmp_path, good)).code == 0
    bad = 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.cos("x"))\nend\n'
    assert at(problem_of(check(source(tmp_path, bad))))[0] == "CHECK-TYPE-MISMATCH"


def test_a_private_extern_function_is_not_exported(tmp_path):
    source(tmp_path, 'extern "libm.so.6"\n  def cos(x: C.Double) -> C.Double\nend\n', "raw.agc")
    text = 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.cos(1.0))\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[0].startswith("CHECK-")


@pytest.mark.parametrize("signature, start, stop", [
    ("def f(x: Float) -> C.Int32", (2, 12), (2, 17)),
    ("def f(x: C.Int32) -> Int", (2, 24), (2, 27)),
    ("def f(x: C.Char) -> Void", (2, 12), (2, 18)),
    ("def f(x: C.Int32) -> C.Bytes", (2, 24), (2, 31)),
    ("def f(x: Void) -> Void", (2, 12), (2, 16)),
    ("def f(x: List[C.Int32]) -> Void", (2, 12), (2, 25)),
    ("def f(x: C.Int) -> Void", (2, 12), (2, 17)),
    ("def f(x: C.Int32) -> C.Int", (2, 24), (2, 29)),
])
def test_only_c_types_cross_an_extern_signature(tmp_path, signature, start, stop):
    text = 'extern "libc.so.6"\n  %s\nend\n' % signature
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-TYPE", start, stop)


FLOATS = """extern "/opt/libpeer.so"
  def scalef(x: C.Float, k: C.Float) -> C.Float
  def half(x: C.Float, out half: C.Float) -> Void
end

def main() -> Void
%s
end
"""


# C.Float is a 32-bit float in C and a Float to the checker, as a parameter, a result and an out parameter.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  x: Float = scalef(1.5, 2.0) + half(3.0).half\n  puts(x)", None, None, None),
    ("  puts(scalef(1, 2.0))", "CHECK-TYPE-MISMATCH", (7, 15), (7, 16)),
    ("  n: Int = scalef(1.0, 2.0)", "CHECK-TYPE-MISMATCH", (7, 12), (7, 28)),
])
def test_c_float_is_a_float_to_the_checker(tmp_path, body, code, start, stop):
    result = check(source(tmp_path, FLOATS % body))
    if code is None:
        assert (result.code, result.stdout) == (0, '{"ok":true}\n')
    else:
        assert at(problem_of(result)) == (code, start, stop)


INTEGERS = """extern "/opt/libpeer.so"
  struct Packet
    tag: C.Int8
    flags: C.UInt8
    kind: C.Int16
    port: C.UInt16
    oid: C.UInt32
    length: C.Long
  end
  def narrow(a: C.Int8, b: C.Int16, c: C.UInt8, d: C.UInt16, e: C.UInt32, f: C.Long) -> C.UInt32
  def read_header(h: Packet, out size: C.Long, out code: C.UInt8) -> Packet
  def wide(n: C.Long) -> C.Int8
  def vsum(n: C.Int32, ..., a: C.UInt32, b: C.Long) -> C.Long
end

def main() -> Void
%s
end
"""


# The integer types C.Int8, C.Int16, C.UInt8, C.UInt16, C.UInt32 and C.Long are Int to the checker as parameters,
# results, out parameters, struct fields and (C.UInt32 and C.Long, which C does not promote) variadic parameters.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  h = read_header(Packet(tag: -1, flags: 255, kind: 2, port: 80, oid: 4_000_000_000, length: 9))\n"
     "  n: Int = narrow(1, 2, 3, 4, 5, 6) + h.result.oid + h.size + h.code + wide(7) + vsum(2, 3, 4)\n  puts(n)",
     None, None, None),
    ("  puts(narrow(1, 2, 3, 4, 5.0, 6))", "CHECK-TYPE-MISMATCH", (17, 27), (17, 30)),
    ("  s: String = wide(1)", "CHECK-TYPE-MISMATCH", (17, 15), (17, 22)),
])
def test_the_integer_types_are_int_to_the_checker(tmp_path, body, code, start, stop):
    assert_checks(check(source(tmp_path, INTEGERS % body)), code, start, stop)


# An integer type narrower than an int is promoted by C after ..., so it is refused there as C.Bool is; C has no
# unsigned 64-bit or unsigned long type here: C.Int64 and C.Long carry the same bits, and the help says so.
@pytest.mark.parametrize("signature, code, start, stop", [
    ("def f(a: C.Int32, ..., b: C.Int8) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (2, 29), (2, 35)),
    ("def f(a: C.Int32, ..., b: C.Int16) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (2, 29), (2, 36)),
    ("def f(a: C.Int32, ..., b: C.UInt8) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (2, 29), (2, 36)),
    ("def f(a: C.Int32, ..., b: C.UInt16) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (2, 29), (2, 37)),
    ("def f(a: C.UInt64) -> Void", "PARSE-EXTERN-TYPE", (2, 12), (2, 20)),
    ("def f() -> C.ULong", "PARSE-EXTERN-TYPE", (2, 14), (2, 21)),
])
def test_promoted_and_missing_integer_types_are_refused(tmp_path, signature, code, start, stop):
    problem = problem_of(check(source(tmp_path, 'extern "libc.so.6"\n  %s\nend\n' % signature)))
    assert at(problem) == (code, start, stop)


MEMORY = """extern "/opt/libpeer.so"
  def fill(out: C.Pointer, n: C.Int32) -> Void
end

def fill_two(buf: C.Pointer) -> Void
  fill(buf, 2)
end

def main() -> Void
%s
end
"""


# An owned buffer is a C.Pointer: it goes where a C.Pointer parameter is, Task.spawn_owning hands it over, and the
# typed reads and writes take any C.Pointer with an Int offset, giving Int, Float, C.Pointer or a list of Int or Float.
# The block form yields a C.Pointer and has the type of the block's value (a Result from a `try` in it included); the
# block or function must take one C.Pointer. Native.from_string takes a String in place of the size, and
# text.bytesize is an Int.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  buf = Native.memory_pointer(16)\n  fill(buf, 4)\n  xs: List[Float] = Native.get_array_of_float32(buf, 0, 4)\n"
     "  n: Int = Native.get_uint8(buf, 0) + Native.get_int64(buf, 8)\n  p: C.Pointer = Native.get_pointer(buf, 8)\n"
     "  Native.put_array_of_int64(buf, 0, [1, 2])\n  Native.put_float32(buf, 0, 1.5)\n  Native.put_pointer(buf, 8, p)\n"
     "  Native.put_string(buf, 0, \"x\")\n  Native.free(buf)\n  puts(xs.size + n)", None, None, None),
    ("  Task.await(Task.spawn_owning(&fill_two, Native.memory_pointer(8)))", None, None, None),
    ("  Task.await(Task.spawn_owning(&fill_two, 8))", "CHECK-TYPE-MISMATCH", (10, 43), (10, 44)),
    ("  Native.put_array_of_float32(Native.memory_pointer(8), 0, [1, 2])", "CHECK-TYPE-MISMATCH", (10, 61), (10, 62)),
    ("  Native.put_int32(Native.memory_pointer(4), 0, 1.5)", "CHECK-TYPE-MISMATCH", (10, 49), (10, 52)),
    ("  n: Int = Native.get_float64(Native.null(), 0)", "CHECK-TYPE-MISMATCH", (10, 12), (10, 48)),
    ('  total: Float = Native.memory_pointer(16) do |buf|\n    fill(buf, 4)\n    Native.get_float32(buf, 0)\n  end\n'
     '  r: Result[Int] = Native.memory_pointer(4) do |buf|\n    n = try "3".to_i\n'
     '    ok(n + Native.get_int32(buf, 0))\n  end\n  Native.memory_pointer(8, &fill_two)\n  puts(total)\n'
     '  puts(r.ok?)', None, None, None),
    ("  s: String = Native.memory_pointer(8) do |buf| Native.get_int8(buf, 0) end", "CHECK-TYPE-MISMATCH", (10, 49),
     (10, 72)),
    ("  n = Native.memory_pointer(8) do |buf: Int| buf end", "CHECK-TYPE-MISMATCH", (10, 36), (10, 44)),
    ("  Native.memory_pointer(8, &main)", "CHECK-TYPE-MISMATCH", (10, 28), (10, 33)),
    ("  n = Native.memory_pointer(8.5) do |buf| 1 end", "CHECK-TYPE-MISMATCH", (10, 29), (10, 32)),
    ('  buf: C.Pointer = Native.from_string("ab")\n  fill(buf, 0)\n'
     '  n: Int = Native.from_string("é") do |s| Native.get_uint8(s, 0) + "é".bytesize end\n  puts(n)',
     None, None, None),
    ("  n = Native.from_string(3) do |buf| 1 end", "CHECK-TYPE-MISMATCH", (10, 26), (10, 27)),
    ('  n = Native.memory_pointer("x") do |buf| 1 end', "CHECK-TYPE-MISMATCH", (10, 29), (10, 32)),
    ('  s: String = "ab".bytesize', "CHECK-TYPE-MISMATCH", (10, 15), (10, 28)),
])
def test_owned_buffers_and_typed_memory_check_as_c_pointers(tmp_path, body, code, start, stop):
    assert_checks(check(source(tmp_path, MEMORY % body)), code, start, stop)


def test_c_int_is_refused_with_the_widths_to_write(tmp_path):
    result = check(source(tmp_path, 'extern "libc.so.6"\n  def abs(n: C.Int) -> C.Int32\nend\n'))
    problem = problem_of(result)
    assert at(problem) == ("PARSE-EXTERN-TYPE", (2, 14), (2, 19))
    assert "C.Int32" in json.dumps(problem["help"])


def test_an_extern_function_has_a_c_name(tmp_path):
    text = 'extern "libc.so.6"\n  def ready?() -> C.Bool\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-EXTERN-NAME", (2, 7))


def test_an_extern_parameter_has_no_default(tmp_path):
    text = 'extern "libc.so.6"\n  def abs(n: C.Int32 = 1) -> C.Int32\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-EXTERN-DEFAULT", (2, 11))


@pytest.mark.parametrize("text, start", [
    ('extern "libc.so.6"\n  def abs(n: C.Int32) -> C.Int32\n    return 1\n  end\nend\n', (3, 5)),
    ('extern "libc.so.6"\n  def abs(n: C.Int32) -> C.Int32\n', (3, 1)),
    ('extern "libc.so.6" def abs(n: C.Int32) -> C.Int32\nend\n', (1, 20)),
    ('extern <<~A\n  a\n  b\nA\n  def abs(n: C.Int32) -> C.Int32\nend\n', (1, 8)),
    ('extern "libc.so.6"\n  compute export def abs(n: C.Int32) -> C.Int32\nend\n', (2, 3)),
    ('extern "libc.so.6"\n  compute abs(n: C.Int32) -> C.Int32\nend\n', (2, 3)),
])
def test_an_extern_block_holds_only_signatures(tmp_path, text, start):
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-UNEXPECTED-TOKEN", start)


@pytest.mark.parametrize("library, stop", [
    ('""', 10),
    ('"./libpeer.so"', 22),
    ('"lib/peer.so"', 21),
    ('"lib#{1}.so"', 20),
])
def test_a_library_is_a_system_name_or_an_absolute_path(tmp_path, library, stop):
    text = 'extern %s\n  def abs(n: C.Int32) -> C.Int32\nend\n' % library
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-LIBRARY", (1, 8), (1, stop))


# The library of Native.load is a string literal with the rule of an extern library, so the front end can resolve it
# like one; anything else (a variable or a constant too) is CHECK-NATIVE-LOAD at the argument.
@pytest.mark.parametrize("before, local, library, code", [
    ("", "", '"libm.so.6"', None),
    ("", "", '""', "CHECK-NATIVE-LOAD"),
    ("", '  name = "libm.so.6"\n', "name", "CHECK-NATIVE-LOAD"),
    ('LIB = "libm.so.6"\n\n', "", "LIB", "CHECK-NATIVE-LOAD"),
    ("", "", '"lib/m.so"', "CHECK-NATIVE-LOAD"),
    ("", "", '"m#{1}"', "CHECK-NATIVE-LOAD"),
])
def test_native_load_takes_a_library_literal(tmp_path, before, local, library, code):
    text = "%sdef main() -> Void\n%s  puts(Native.load(%s).ok?)\nend\n" % (before, local, library)
    line = next(k for k, row in enumerate(text.split("\n"), 1) if "Native.load" in row)
    assert_checks(check(source(tmp_path, text)), code, (line, 20), (line, 20 + len(library)))


def test_an_extern_function_takes_at_most_64_parameters(tmp_path):
    params = ", ".join("p%d: C.Int32" % k for k in range(64))
    ok = 'extern "libc.so.6"\n  def f(%s) -> Void\nend\n' % params
    assert check(source(tmp_path, ok)).code == 0
    over = 'extern "libc.so.6"\n  def f(%s, extra: C.Int32) -> Void\nend\n' % params
    start = len("  def f(%s, " % params) + 1
    assert at(problem_of(check(source(tmp_path, over)))) == (
        "PARSE-EXTERN-ARITY", (2, start), (2, start + len("extra: C.Int32")))


VARIADIC = """extern "libc.so.6"
  resource Stream, free: fclose
  def open(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32
  def fcntl_flags(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  def fcntl_get(fd: C.Int32, cmd: C.Int32, ...,) -> C.Int32 = "fcntl"
  compute def fprintf(stream: Stream, format: C.String, ..., a: C.Int64, b: C.Double, c: C.Bytes) -> C.Int32
  def frexp_into(x: C.Double, out exponent: C.Int32, ..., p: C.Pointer, s: Stream) -> C.Double = "frexp"
end

def main() -> Void
  puts(open("x", 0, 420) + fcntl_flags(3, 2, 1) + fcntl_get(3, 1))
end

def write(s: Stream) -> Int
  return frexp_into(1.0, Native.null(), s).exponent + fprintf(s, "%d %f", 1, 2.0, "x".bytes)
end
"""


# `...` starts the variadic part, whose parameters are ordinary typed parameters for the checker; `= "symbol"` names
# the C function, so one C function can be declared in several shapes.
def test_a_variadic_extern_function_checks_like_any_other(tmp_path):
    assert check(source(tmp_path, VARIADIC)).code == 0
    bad = VARIADIC.replace('fcntl_flags(3, 2, 1)', 'fcntl_flags(3, 2, "1")')
    assert at(problem_of(check(source(tmp_path, bad))))[:2] == ("CHECK-TYPE-MISMATCH", (11, 46))


@pytest.mark.parametrize("signature, code, start, stop", [
    ("def f(...) -> Void", "PARSE-EXTERN-VARIADIC-FIXED", (2, 9), (2, 12)),
    ("def f(a: C.Int32, ..., ...) -> Void", "PARSE-EXTERN-VARIADIC", (2, 26), (2, 29)),
    ("def f(a: C.Int32, ..., b: C.Int32, ...) -> Void", "PARSE-EXTERN-VARIADIC", (2, 38), (2, 41)),
    ("def f(a: C.Int32, ..., b: C.Bool) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (2, 29), (2, 35)),
    ("def f(a: C.Int32, ..., out b: C.Int32) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (2, 26), (2, 40)),
    ("def f(a: C.Int32, ..., b: C.Float) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (2, 29), (2, 36)),
    ("def f(a: C.Int32, ..., b: C.Char) -> Void", "PARSE-EXTERN-TYPE", (2, 29), (2, 35)),
    ('def f(a: C.Int32) -> Void = "a b"', "PARSE-EXTERN-SYMBOL", (2, 31), (2, 36)),
    ('def f(a: C.Int32) -> Void = "1a"', "PARSE-EXTERN-SYMBOL", (2, 31), (2, 35)),
    ('def f(a: C.Int32) -> Void = ""', "PARSE-EXTERN-SYMBOL", (2, 31), (2, 33)),
    ('def f(a: C.Int32) -> Void = "f?"', "PARSE-EXTERN-SYMBOL", (2, 31), (2, 35)),
    ('def f(a: C.Int32) -> Void = "x#{1}"', "PARSE-EXTERN-SYMBOL", (2, 31), (2, 38)),
    ("def f(a: C.Int32) -> Void = fcntl", "PARSE-UNEXPECTED-TOKEN", (2, 31), (2, 36)),
    ("def f(a: C.Int32 ...) -> Void", "PARSE-UNEXPECTED-TOKEN", (2, 20), (2, 23)),
])
def test_the_variadic_part_and_the_c_name_have_rules(tmp_path, signature, code, start, stop):
    text = 'extern "libc.so.6"\n  %s\nend\n' % signature
    assert at(problem_of(check(source(tmp_path, text)))) == (code, start, stop)


def test_a_variadic_part_belongs_to_an_extern_function(tmp_path):
    text = "def f(a: Int, ...) -> Void\nend\n"
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-VARIADIC", (1, 15), (1, 18))


def test_the_c_name_of_a_def_may_not_be_a_free_function(tmp_path):
    text = 'extern "libc.so.6"\n  resource Stream, free: fclose\n  def done(s: Stream) -> C.Int32 = "fclose"\nend\n'
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-FREE", (3, 36), (3, 44))


def test_the_variadic_part_counts_toward_64_parameters(tmp_path):
    params = ", ".join("p%d: C.Int32" % k for k in range(63))
    ok = 'extern "libc.so.6"\n  def f(first: C.Int32, ..., %s) -> Void\nend\n' % params
    assert check(source(tmp_path, ok)).code == 0
    over = 'extern "libc.so.6"\n  def f(first: C.Int32, ..., %s, extra: C.Int32) -> Void\nend\n' % params
    assert at(problem_of(check(source(tmp_path, over))))[0] == "PARSE-EXTERN-ARITY"


def test_an_extern_block_follows_the_blank_line_rule(tmp_path):
    text = 'def main() -> Void\nend\nextern "libc.so.6"\n  def abs(n: C.Int32) -> C.Int32\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-MISSING-BLANK-LINE", (3, 1))


def test_a_compute_def_belongs_in_an_extern_block(tmp_path):
    text = 'compute def abs(n: Int) -> Int\n  return n\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-TOP-LEVEL-STATEMENT", (1, 1))


def test_extern_and_compute_are_still_names_elsewhere(tmp_path):
    text = 'def compute(n: Int) -> Int\n  return n\nend\n\n' \
           'def main() -> Void\n  extern = 1\n  puts(compute(extern))\nend\n'
    assert check(source(tmp_path, text)).code == 0


WAIT = """def connect(fd: Int) -> Result[Void]
  try Native.wait_readable(fd, 5_000)
  return Native.wait_writable(fd, 5_000)
end

def main() -> Void
  puts(connect(3))
end
"""


# Native.wait_readable and wait_writable take an Int descriptor and an Int timeout and give a Result[Void]. Native is
# not a reserved name: an import alias of that name hides the builtins.
def test_the_waits_take_int_arguments_and_give_a_result(tmp_path):
    assert check(source(tmp_path, WAIT)).code == 0
    bad = 'def main() -> Void\n  puts(Native.wait_readable("3", 5_000))\nend\n'
    assert at(problem_of(check(source(tmp_path, bad)))) == ("CHECK-TYPE-MISMATCH", (2, 29), (2, 32))
    source(tmp_path, "export def wait_readable(fd: Int) -> Int\n  return fd\nend\n", "native.agc")
    shadow = 'import Native from "./native"\n\ndef main() -> Void\n  puts(Native.wait_readable(1) + 1)\nend\n'
    assert check(source(tmp_path, shadow)).code == 0


RESOURCES = """struct Pool
  db: Db
end

extern "/opt/peer/libpeer.so"
  ## An open database.
  export resource Db, free: db_close
  export def db_open(path: C.String) -> Db
  def db_exec(db: Db, sql: C.String, blob: C.Bytes, n: C.Int32) -> C.Int32
  compute def db_wait(db: Db) -> C.Int32
  def db_handle(db: Db) -> C.Pointer
  def raw_len(p: C.Pointer) -> C.Int64
end

def use(db: Db) -> Int
  return db_wait(db)
end

def main() -> Void
  db = db_open("x.db").unwrap!
  pool = Pool(db: db)
  puts(db_exec(pool.db, "select 1", Bytes.from_list([0, 255]).unwrap!, 2))
  raw: C.Pointer = db_handle(db)
  puts(Native.null?(raw) or Native.null?(Native.null()))
  puts(Native.closed?(db) or Native.closed?(raw))
  puts(raw_len(raw))
  IO.inspect(db)
  puts(Task.await(Task.spawn_owning(&use, db)))
  Native.close(db)
end
"""


# A resource is a type of its own: a function declared -> Db gives Result[Db], a parameter takes the resource, C.Bytes
# is a Bytes, and C.Pointer is a type any code may name. Task.spawn_owning takes a resource.
def test_resources_pointers_and_bytes_check(tmp_path):
    result = check(source(tmp_path, RESOURCES))
    assert (result.code, result.stdout) == (0, '{"ok":true}\n')


# A C.Bytes parameter takes a Bytes only: a List[Int], a list literal or a String is CHECK-TYPE-MISMATCH at the
# argument.
@pytest.mark.parametrize("argument", ["[0, 255]", "list", '"ab"'])
def test_a_c_bytes_parameter_takes_bytes_not_a_list(tmp_path, argument):
    line = "  puts(blob_sum(%s, 2))" % argument
    text = 'extern "/opt/libblob.so"\n  def blob_sum(blob: C.Bytes, n: C.Int32) -> C.Int32\nend\n\n' \
        "def main() -> Void\n  list: List[Int] = [0, 255]\n%s\nend\n" % line
    start = line.index(argument) + 1
    assert at(problem_of(check(source(tmp_path, text)))) == (
        "CHECK-TYPE-MISMATCH", (7, start), (7, start + len(argument)))


def test_an_exported_resource_is_imported_like_a_type(tmp_path):
    raw = 'extern "/opt/libdb.so"\n  export resource Db, free: db_close\n  export def db_open() -> Db\nend\n'
    source(tmp_path, raw, "raw.agc")
    good = 'import Raw from "./raw"\n\ndef shut(db: Raw.Db) -> Void\n  Native.close(db)\nend\n\n' \
           'def main() -> Void\n  shut(Raw.db_open().unwrap!)\nend\n'
    assert check(source(tmp_path, good)).code == 0
    private = raw.replace("export resource", "resource")
    source(tmp_path, private, "raw.agc")
    assert at(problem_of(check(source(tmp_path, good))))[0] == "CHECK-IMPORT-NAME"


OPENER = 'extern "/opt/libdb.so"\n  resource Db, free: db_close\n  def db_open() -> Db\n  ' \
         'def db_handle(db: Db) -> C.Pointer\nend\n\ndef main() -> Void\n%s\nend\n'


# The checker keeps resources, pointers and Results apart, and pointers and resources have no ==, to_s or JSON.
# Native.close takes a resource; Native.closed? a resource or a C.Pointer, and gives a Bool.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  db: Db = db_open()", "CHECK-TYPE-MISMATCH", (8, 12), (8, 21)),
    ("  p: C.Pointer = db_open().unwrap!", "CHECK-TYPE-MISMATCH", (8, 18), (8, 27)),
    ("  puts(db_handle(Native.null()))", "CHECK-TYPE-MISMATCH", (8, 18), (8, 31)),
    ("  Native.close(Native.null())", "CHECK-TYPE-MISMATCH", (8, 16), (8, 29)),
    ('  puts(Native.closed?("db"))', "CHECK-TYPE-MISMATCH", (8, 23), (8, 27)),
    ("  n: Int = Native.closed?(db_open().unwrap!)", "CHECK-TYPE-MISMATCH", (8, 12), (8, 45)),
    ("  puts(Native.null() == Native.null())", "CHECK-TYPE-MISMATCH", (8, 22), (8, 24)),
    ("  puts(db_open().unwrap!)", "CHECK-TYPE-MISMATCH", (8, 8), (8, 25)),
    ("  puts(JSON.encode(db_open().unwrap!))", "CHECK-NOT-ENCODABLE", (8, 20), (8, 37)),
])
def test_resources_and_pointers_are_opaque(tmp_path, body, code, start, stop):
    assert at(problem_of(check(source(tmp_path, OPENER % body)))) == (code, start, stop)


# Native.get_string and get_bytes read memory at a C.Pointer (not a resource) with an Int offset and length, get_bytes
# gives and put_bytes writes a Bytes (a List[Int] is CHECK-TYPE-MISMATCH), and Native.pointer makes a C.Pointer of an Int; a wrong argument is CHECK-TYPE-MISMATCH at it,
# and a wrong count CHECK-ARITY. The old names string_at and bytes_at are CHECK-UNKNOWN-NAME, with a help that gives
# the call with offset 0.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  s: String = Native.get_string(db_handle(db_open().unwrap!), 1, 3)\n"
     "  b: Bytes = Native.get_bytes(Native.pointer(-1), 0, 0)\n"
     "  Native.put_bytes(Native.pointer(1), 0, b)\n"
     "  puts(s + Native.get_string(Native.null(), 0) + b.size.to_s)", None, None, None),
    ("  puts(Native.string_at(Native.null(), 3))", "CHECK-UNKNOWN-NAME", (8, 8), (8, 42)),
    ("  puts(Native.bytes_at(Native.null(), 3).size)", "CHECK-UNKNOWN-NAME", (8, 8), (8, 41)),
    ('  puts(Native.get_string("x", 0))', "CHECK-TYPE-MISMATCH", (8, 26), (8, 29)),
    ("  db = db_open().unwrap!\n  puts(Native.get_string(db, 0))", "CHECK-TYPE-MISMATCH", (9, 26), (9, 28)),
    ('  puts(Native.get_string(Native.null(), "3"))', "CHECK-TYPE-MISMATCH", (8, 41), (8, 44)),
    ("  puts(Native.get_string(Native.null()))", "CHECK-ARITY", (8, 8), (8, 40)),
    ("  puts(Native.get_bytes(Native.pointer(1), 0, [3]))", "CHECK-TYPE-MISMATCH", (8, 47), (8, 50)),
    ("  puts(Native.get_bytes(Native.null(), 0))", "CHECK-ARITY", (8, 8), (8, 42)),
    ("  Native.put_bytes(Native.null(), 0, [1, 2])", "CHECK-TYPE-MISMATCH", (8, 38), (8, 44)),
    ("  b: List[Int] = Native.get_bytes(Native.null(), 0, 0)", "CHECK-TYPE-MISMATCH", (8, 18), (8, 55)),
    ('  Native.put_bytes(Native.null(), 0, "ab")', "CHECK-TYPE-MISMATCH", (8, 38), (8, 42)),
    ("  puts(Native.pointer(1.5))", "CHECK-TYPE-MISMATCH", (8, 23), (8, 26)),
    ("  n: Int = Native.pointer(1)", "CHECK-TYPE-MISMATCH", (8, 12), (8, 29)),
])
def test_the_memory_builtins_take_a_pointer_and_a_length(tmp_path, body, code, start, stop):
    assert_checks(check(source(tmp_path, OPENER % body)), code, start, stop)


# The old names carry the help that gives the new call (its presence, not its text).
@pytest.mark.parametrize("call", ["Native.string_at(Native.null(), 3)", "Native.bytes_at(Native.null(), 3).size"])
def test_the_old_memory_names_have_a_help(tmp_path, call):
    assert problem_of(check(source(tmp_path, OPENER % ("  puts(%s)" % call)))).get("help")


# The block's free function is the VM's to call: a def of it, before or after the resource, is PARSE-EXTERN-FREE at
# the later of the two names.
@pytest.mark.parametrize("members, start, stop", [
    ("  resource Db, free: db_close\n  def db_close(db: Db) -> Void", (3, 7), (3, 15)),
    ("  def db_close(p: C.Pointer) -> Void\n  resource Db, free: db_close", (3, 22), (3, 30)),
])
def test_the_free_function_is_not_a_def_of_the_block(tmp_path, members, start, stop):
    text = 'extern "/opt/libdb.so"\n%s\nend\n' % members
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-FREE", start, stop)


# free_ref: names a C function that takes the address of the handle, checked as a free: name is. A resource has
# one free function: free: with free_ref:, in either order, is PARSE-EXTERN-FREE at the second word.
@pytest.mark.parametrize("members, code, start, stop", [
    ("  resource Db, free_ref: db_close\n  def db_open() -> Db", None, None, None),
    ("  resource Db, free: db_close, free_ref: db_free", "PARSE-EXTERN-FREE", (2, 32), (2, 40)),
    ("  resource Db, free_ref: db_close, free: db_free", "PARSE-EXTERN-FREE", (2, 36), (2, 40)),
    ("  resource Db, free: C.Function, free_ref: db_free", "PARSE-EXTERN-FREE", (2, 34), (2, 42)),
    ("  resource Db, free_ref: db_close\n  def db_close(db: Db) -> Void", "PARSE-EXTERN-FREE", (3, 7), (3, 15)),
    ("  def db_close(p: C.Pointer) -> Void\n  resource Db, free_ref: db_close", "PARSE-EXTERN-FREE", (3, 26), (3, 34)),
    ("  resource Db, free_ref: C.Function", "PARSE-EXTERN-FUNCTION", (2, 26), (2, 36)),
    ("  resource Db, free_ref: db_close?", "PARSE-EXTERN-NAME", (2, 26), (2, 35)),
])
def test_a_resource_may_be_freed_through_a_reference_to_its_handle(tmp_path, members, code, start, stop):
    text = 'extern "/opt/libdb.so"\n%s\nend\n' % members
    assert_checks(check(source(tmp_path, text)), code, start, stop)


@pytest.mark.parametrize("members, code, start", [
    ("  def db_open() -> Db\n  resource Db, free: db_close", "PARSE-EXTERN-TYPE", (2, 20)),
    ('  resource Db, free: db_close\nend\n\nextern "/opt/libdb.so"\n  def db_use(db: Db) -> C.Int32', "PARSE-EXTERN-TYPE",
     (6, 18)),
    ("  resource Db, free: db_close?", "PARSE-EXTERN-NAME", (2, 22)),
    ("  resource Db free: db_close", "PARSE-UNEXPECTED-TOKEN", (2, 15)),
    ("  compute resource Db, free: db_close", "PARSE-UNEXPECTED-TOKEN", (2, 3)),
])
def test_a_resource_is_declared_before_use_with_a_c_free_function(tmp_path, members, code, start):
    text = 'extern "/opt/libdb.so"\n%s\nend\n' % members
    assert at(problem_of(check(source(tmp_path, text))))[:2] == (code, start)


# A resource is a type name of the file: a second resource, a struct or a reserved type of that name is
# CHECK-REDEFINED-NAME at the later declaration.
@pytest.mark.parametrize("text, start", [
    ('extern "/opt/libdb.so"\n  resource Db, free: db_close\n  resource Db, free: db_free\nend\n', (3, 3)),
    ('struct Db\n  x: Int\nend\n\nextern "/opt/libdb.so"\n  resource Db, free: db_close\nend\n', (6, 3)),
    ('extern "/opt/libdb.so"\n  resource Socket, free: db_close\nend\n', (2, 3)),
])
def test_a_resource_name_is_not_taken_twice(tmp_path, text, start):
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("CHECK-REDEFINED-NAME", start)


# C.Pointer is a type of every file, not only of one with an extern block.
def test_c_pointer_is_a_type_without_an_extern_block(tmp_path):
    text = "def empty?(p: C.Pointer) -> Bool\n  return Native.null?(p)\nend\n"
    assert check(source(tmp_path, text)).code == 0


def test_resource_is_still_a_name_elsewhere(tmp_path):
    text = 'def main() -> Void\n  resource = 1\n  puts(resource)\nend\n'
    assert check(source(tmp_path, text)).code == 0


OUTS = 'extern "/opt/libdb.so"\n  resource Db, free: db_close\n' \
       '  export def db_open(name: C.String, out db: Db, out code: C.Int64) -> C.Int32\n' \
       '  def db_fill(out n: C.Int32, out x: C.Double, out on: C.Bool, out p: C.Pointer) -> Void\n' \
       'end\n\ndef main() -> Void\n%s\nend\n'


# An out parameter is not an argument: the call gives the function's record, DbOpen, with `result` (absent for Void)
# and one field per out parameter, of its Agentica type (a resource itself, not a Result). A wrong field or a wrong use
# of one is the checker's usual code.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  opened: DbOpen = db_open(\"x\")\n  Native.close(opened.db)\n  puts(opened.result + opened.code)\n"
     "  filled = db_fill()\n  x: Float = filled.x\n  puts(filled.n + 1)\n  puts(filled.on)\n"
     "  puts(Native.null?(filled.p))", None, None, None),
    ("  puts(db_open(\"x\", 1))", "CHECK-ARITY", (8, 8), (8, 23)),
    ("  puts(db_open(\"x\").missing)", "CHECK-UNKNOWN-FIELD", (8, 8), (8, 28)),
    ("  puts(db_fill().result)", "CHECK-UNKNOWN-FIELD", (8, 8), (8, 24)),
    ("  n: Int = db_open(\"x\")", "CHECK-TYPE-MISMATCH", (8, 12), (8, 24)),
    ("  puts(db_open(\"x\").db)", "CHECK-TYPE-MISMATCH", (8, 8), (8, 23)),
])
def test_out_parameters_are_fields_of_the_record_of_the_call(tmp_path, body, code, start, stop):
    result = check(source(tmp_path, OUTS % body))
    if code is None:
        assert (result.code, result.stdout) == (0, '{"ok":true}\n')
    else:
        assert at(problem_of(result)) == (code, start, stop)


# The record is exported with its function, so an importer can name it.
def test_the_record_of_an_exported_extern_function_is_imported(tmp_path):
    source(tmp_path, (OUTS % "").split("\n\ndef main")[0] + "\n", "raw.agc")
    text = 'import Raw from "./raw"\n\ndef code(opened: Raw.DbOpen) -> Int\n  return opened.code\nend\n\n' \
           'def main() -> Void\n  puts(code(Raw.db_open("x")))\nend\n'
    assert check(source(tmp_path, text)).code == 0


# PARSE-EXTERN-OUT: at the type of an out C.String or C.Bytes (who frees what C writes is not known), at an out
# parameter named result when the function has a C result, at a C name with no letter for the record's name, at the
# word out outside an extern block, and at the later of an in and an out parameter of one name. `out` is still a
# parameter name.
@pytest.mark.parametrize("text, start, stop", [
    ('extern "libc.so.6"\n  def f(out s: C.String) -> C.Int32\nend\n', (2, 16), (2, 24)),
    ('extern "libc.so.6"\n  def f(out b: C.Bytes) -> Void\nend\n', (2, 16), (2, 23)),
    ('extern "libc.so.6"\n  def f(out result: C.Int32) -> C.Int32\nend\n', (2, 13), (2, 19)),
    ('extern "libc.so.6"\n  def _2(out n: C.Int32) -> C.Int32\nend\n', (2, 7), (2, 9)),
    ('def f(out n: Int) -> Int\n  return n\nend\n', (1, 7), (1, 10)),
    ('extern "libm.so.6"\n  def frexp(x: C.Double, out x: C.Int32) -> C.Double\nend\n', (2, 30), (2, 31)),
    ('extern "libm.so.6"\n  def f(out x: C.Int32, x: C.Double) -> C.Double\nend\n', (2, 25), (2, 26)),
])
def test_an_out_parameter_is_a_c_value_of_an_extern_function(tmp_path, text, start, stop):
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-OUT", start, stop)


def test_out_is_still_a_name_and_result_is_an_out_of_a_void_function(tmp_path):
    text = 'extern "libc.so.6"\n  def f(out result: C.Int32) -> Void\nend\n\n' \
           'def g(out: Int) -> Int\n  return out\nend\n\ndef main() -> Void\n  puts(f().result + g(1))\nend\n'
    assert check(source(tmp_path, text)).code == 0


# The record is a type name of the file: a struct of that name is CHECK-REDEFINED-NAME at the extern function, two out
# parameters of one name are that code at the second (a field of the record twice), and the extern block may still
# come after the functions of the file.
def test_the_record_takes_its_name_and_follows_the_function(tmp_path):
    clash = 'struct DbOpen\n  x: Int\nend\n\n' + OUTS % ""
    assert at(problem_of(check(source(tmp_path, clash))))[:2] == ("CHECK-REDEFINED-NAME", (7, 3))
    twice = 'extern "libc.so.6"\n  def f(out x: C.Int32, out x: C.Int32) -> C.Int32\nend\n'
    assert at(problem_of(check(source(tmp_path, twice)))) == ("CHECK-REDEFINED-NAME", (2, 25), (2, 39))
    late = 'def main() -> Void\n  puts(db_open().db)\nend\n\n' \
           'extern "libc.so.6"\n  def db_open(out db: C.Int32) -> Void\nend\n'
    assert check(source(tmp_path, late)).code == 0


POINTERS = """extern "/opt/libort.so"
  resource Session, free: C.Function
  def ort_get_api_base() -> C.Pointer = "OrtGetApiBase"
  def get_api(fn: C.Function, version: C.Int32) -> C.Pointer
  compute def run(fn: C.Function, session: Session, x: C.Double) -> C.Pointer
  def create_session(fn: C.Function, path: C.String, out session: Session, free: C.Function) -> C.Pointer
  def open_session(path: C.String, free: C.Function) -> Session
  def printf_at(fn: C.Function, format: C.String, ..., n: C.Int32) -> C.Int32
end

def main() -> Void
  api = get_api(Native.get_pointer(ort_get_api_base(), 0), 16)
  made = create_session(Native.get_pointer(api, 8), "model.onnx", Native.get_pointer(api, 16))
  status: C.Pointer = run(Native.get_pointer(api, 24), made.session, 1.5)
  opened: Result[Session] = open_session("other.onnx", Native.get_pointer(api, 16))
  puts(printf_at(Native.get_pointer(api, 32), "%d", 1) + 1)
end
"""


# A C.Function parameter is a C.Pointer to the checker: first, the function the def calls; last, the free function of
# the resource of a free: C.Function kind that the call makes.
def test_function_pointers_check_as_c_pointers(tmp_path):
    assert check(source(tmp_path, POINTERS)).code == 0
    bad = POINTERS.replace("get_api(Native.get_pointer(ort_get_api_base(), 0), 16)", "get_api(0, 16)")
    assert at(problem_of(check(source(tmp_path, bad))))[0] == "CHECK-TYPE-MISMATCH"


@pytest.mark.parametrize("signature, code, start, stop", [
    ("def f(a: C.Int32, fn: C.Function, b: C.Int32) -> Void", "PARSE-EXTERN-FUNCTION", (3, 25), (3, 35)),
    ("def f(fn: C.Function, g: C.Function) -> Void", "PARSE-EXTERN-FUNCTION", (3, 28), (3, 38)),
    ("def f(a: C.Int32, free: C.Function) -> Void", "PARSE-EXTERN-FUNCTION", (3, 27), (3, 37)),
    ('def f(fn: C.Function, a: C.Int32) -> Void = "g"', "PARSE-EXTERN-FUNCTION", (3, 47), (3, 50)),
    ("def f(fn: C.Function, a: C.Int32) -> Thing", "PARSE-EXTERN-FUNCTION", (3, 40), (3, 45)),
    ("def f(fn: C.Pointer, out t: Thing) -> Void", "PARSE-EXTERN-FUNCTION", (3, 31), (3, 36)),
    ("def f(a: C.Int32, out t: Thing, out u: Thing, free: C.Function) -> Void", "PARSE-EXTERN-FUNCTION", (3, 42),
     (3, 47)),
    ("def f(fn: C.Function) -> C.Function", "PARSE-EXTERN-TYPE", (3, 28), (3, 38)),
    ("def f(fn: C.Function, out g: C.Function) -> Void", "PARSE-EXTERN-OUT", (3, 32), (3, 42)),
    ("def f(fn: C.Function, ...) -> Void", "PARSE-EXTERN-VARIADIC-FIXED", (3, 25), (3, 28)),
    ("def f(free: C.Function, ...) -> Thing", "PARSE-EXTERN-VARIADIC-FIXED", (3, 27), (3, 30)),
    ("def f(fn: C.Function, free: C.Function, ...) -> Thing", "PARSE-EXTERN-VARIADIC-FIXED", (3, 43), (3, 46)),
    ("def f(fn: C.Function, a: C.Int32, ..., g: C.Function) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (3, 45), (3, 55)),
])
def test_a_c_function_is_the_function_to_call_or_a_free_function(tmp_path, signature, code, start, stop):
    text = 'extern "/opt/libx.so"\n  resource Thing, free: C.Function\n  %s\nend\n' % signature
    assert at(problem_of(check(source(tmp_path, text)))) == (code, start, stop)


# A free word that starts with a capital letter is a C name (libpq, OpenSSL), also one that is a type of the program;
# only the dotted C.Function is the type.
@pytest.mark.parametrize("free", ["PQfinish", "SSL_free", "XFree", "Thing", "C"])
def test_a_resource_may_be_freed_by_a_c_name_with_a_capital(tmp_path, free):
    text = 'struct Thing\n  x: Int\nend\n\nextern "/opt/libx.so"\n  resource Handle, free: %s\n' \
           '  def make() -> Handle\nend\n' % free
    assert check(source(tmp_path, text)).code == 0


@pytest.mark.parametrize("members, code, start", [
    ('  resource Handle, free: PQfinish\n  def pq_finish(h: Handle) -> Void = "PQfinish"', "PARSE-EXTERN-FREE", (3, 38)),
    ("  resource Handle, free: PQfinish?", "LEX-UNEXPECTED-CHAR", (2, 34)),
    ("  resource Handle, free: PQfinish extra", "PARSE-UNEXPECTED-TOKEN", (2, 35)),
    ("  resource Handle, free: C.Pointer", "PARSE-EXTERN-FUNCTION", (2, 26)),
])
def test_a_capital_free_name_is_checked_like_any_c_name(tmp_path, members, code, start):
    text = 'extern "/opt/libx.so"\n%s\nend\n' % members
    assert at(problem_of(check(source(tmp_path, text))))[:2] == (code, start)


@pytest.mark.parametrize("free, stop", [("C.Pointer", (2, 34)), ("C.Function[Int]", (2, 40))])
def test_a_resource_is_freed_by_a_c_name_or_a_c_function(tmp_path, free, stop):
    text = 'extern "/opt/libx.so"\n  resource Thing, free: %s\nend\n' % free
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-FUNCTION", (2, 25), stop)


# A call through a pointer has no C name, so a def of the name of a free function of the block is not one.
def test_a_call_through_a_pointer_may_take_the_name_of_a_free_function(tmp_path):
    text = 'extern "/opt/libdb.so"\n  resource Db, free: db_close\n  def db_close(fn: C.Function, db: Db) -> Void\n' \
           '  resource Other, free: db_close\nend\n'
    assert check(source(tmp_path, text)).code == 0


# A sole C.Function parameter of a def that makes a resource of a free: C.Function kind is its free function, not the
# function to call: the def calls its C function by name (void *thing_new(void)), so = "symbol" is allowed.
@pytest.mark.parametrize("signature", [
    "def thing_new(free: C.Function) -> Thing",
    'def new_thing(free: C.Function) -> Thing = "thing_new"',
    "def thing_at(fn: C.Function, free: C.Function) -> Thing",
])
def test_a_sole_c_function_of_a_maker_is_its_free_function(tmp_path, signature):
    name = signature.split("(")[0].split()[-1]
    text = 'extern "/opt/libx.so"\n  resource Thing, free: C.Function\n  %s\nend\n\n' \
           'def make(f: C.Pointer) -> Result[Thing]\n  return %s(%sf)\nend\n' \
           % (signature, name, "f, " if "fn:" in signature else "")
    assert check(source(tmp_path, text)).code == 0


STRUCTS = """extern "/opt/libllama.so"
  ## The params of a model.
  export struct ModelParams
    n_gpu_layers: C.Int32 = 0
    use_mmap: C.Bool
    progress: C.Pointer
  end
  struct Inner
    x: C.Float
    n: C.Int64
  end
  struct Outer
    inner: Inner
    scale: C.Double
  end
  resource Model, free: llama_model_free
  export def llama_model_default_params() -> ModelParams
  compute def llama_model_load_from_file(path: C.String, params: ModelParams) -> Model
  def outer_twice(fn: C.Function, o: Outer) -> Outer
  def make_outer(out n: C.Int32) -> Outer
end

def main() -> Void
%s
end
"""


# A struct of an extern block is a record with the Agentica types of its C fields (Int, Float, Bool, C.Pointer, a
# nested struct): construction, field defaults, .with and field access check as for any struct, and extern functions
# take and return it by value, also through a function pointer, in a compute def and as the result of a record.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  params = llama_model_default_params().with(n_gpu_layers: 99)\n"
     "  model: Result[Model] = llama_model_load_from_file(\"m.gguf\", params)\n"
     "  o = outer_twice(Native.null(), Outer(inner: Inner(x: 1.5, n: 2), scale: 0.5))\n"
     "  made = make_outer()\n  n: Int = made.result.inner.n + made.n\n"
     "  p = ModelParams(use_mmap: true, progress: Native.null())\n  puts(o.inner.x + (p.n_gpu_layers + n).to_f)",
     None, None, None),
    ("  p = ModelParams(n_gpu_layers: 1.5, use_mmap: true, progress: Native.null())",
     "CHECK-TYPE-MISMATCH", (24, 33), (24, 36)),
    ("  o = outer_twice(Native.null(), Inner(x: 1.5, n: 2))", "CHECK-TYPE-MISMATCH", (24, 34), (24, 53)),
    ("  s: String = llama_model_default_params().progress", "CHECK-TYPE-MISMATCH", (24, 15), (24, 52)),
])
def test_a_struct_of_an_extern_block_is_a_record_passed_by_value(tmp_path, body, code, start, stop):
    assert_checks(check(source(tmp_path, STRUCTS % body)), code, start, stop)


def test_an_exported_extern_struct_is_imported_like_a_struct(tmp_path):
    source(tmp_path, STRUCTS % "  puts(1)", "raw.agc")
    text = 'import Raw from "./raw"\n\ndef main() -> Void\n' \
           '  p = Raw.llama_model_default_params().with(n_gpu_layers: 2)\n' \
           '  puts(Raw.ModelParams(use_mmap: p.use_mmap, progress: p.progress).n_gpu_layers)\nend\n'
    assert check(source(tmp_path, text)).code == 0


# Native.size_of(T) is an Int, Native.get_struct(p, offset, T) a T and Native.put_struct(p, offset, value) Void, for a
# struct of an extern block, also through a type alias or from another module; a struct of the program, a resource, a
# value in place of the type or a type name in place of the value is CHECK-TYPE-MISMATCH at it.
@pytest.mark.parametrize("body, code, start, stop", [
    ("  buf = Native.memory_pointer(2 * Native.size_of(Outer))\n"
     "  Native.put_struct(buf, Native.size_of(OuterAlias), Outer(inner: Inner(x: 1.5, n: 2), scale: 0.5))\n"
     "  o: Outer = Native.get_struct(buf, 0, OuterAlias)\n  puts(o.inner.n)", None, None, None),
    ("  buf = Native.memory_pointer(Native.size_of(Raw.ModelParams))\n"
     "  p: Raw.ModelParams = Native.get_struct(buf, 0, Raw.ModelParams)\n  Native.put_struct(buf, 0, p)",
     None, None, None),
    ("  puts(Native.size_of(Plain))", "CHECK-TYPE-MISMATCH", (32, 23), (32, 28)),
    ("  puts(Native.get_struct(Native.null(), 0, Plain))", "CHECK-TYPE-MISMATCH", (32, 44), (32, 49)),
    ("  Native.put_struct(Native.null(), 0, Plain(x: 1))", "CHECK-TYPE-MISMATCH", (32, 39), (32, 50)),
    ("  Native.put_struct(Native.null(), 0, Outer)", "CHECK-TYPE-MISMATCH", (32, 39), (32, 44)),
    ("  puts(Native.size_of(Model))", "CHECK-TYPE-MISMATCH", (32, 23), (32, 28)),
    ("  puts(Native.size_of(3))", "CHECK-TYPE-MISMATCH", (32, 23), (32, 24)),
    ("  s: String = Native.get_struct(Native.null(), 0, Inner)", "CHECK-TYPE-MISMATCH", (32, 15), (32, 57)),
])
def test_structs_through_pointers_take_a_struct_of_an_extern_block(tmp_path, body, code, start, stop):
    source(tmp_path, STRUCTS % "  puts(1)", "raw.agc")
    text = 'import Raw from "./raw"\n\nstruct Plain\n  x: Int\nend\n\ntype OuterAlias = Outer\n\n' + STRUCTS % body
    assert_checks(check(source(tmp_path, text)), code, start, stop)


# A field of a C struct is a C integer type, C.Double, C.Float, C.Bool, C.Pointer or a struct declared above in the
# block: a C.String, C.Bytes, C.Function or resource field (whose lifetime the VM cannot follow), an Agentica type, a
# struct declared below and C.Int are PARSE-EXTERN-TYPE at the type.
@pytest.mark.parametrize("field, start, stop", [
    ("name: C.String", (4, 11), (4, 19)),
    ("data: C.Bytes", (4, 11), (4, 18)),
    ("fn: C.Function", (4, 9), (4, 19)),
    ("thing: Thing", (4, 12), (4, 17)),
    ("n: Int", (4, 8), (4, 11)),
    ("xs: List[C.Int32]", (4, 9), (4, 22)),
    ("later: Later", (4, 12), (4, 17)),
    ("n: C.Int", (4, 8), (4, 13)),
    ("n: C.UInt64", (4, 8), (4, 16)),
])
def test_a_c_struct_field_has_a_c_value_type(tmp_path, field, start, stop):
    text = 'extern "/opt/libx.so"\n  resource Thing, free: thing_free\n  struct S\n    %s\n  end\n' \
           '  struct Later\n    n: C.Int32\n  end\nend\n' % field
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-TYPE", start, stop)


# A struct is a type of the block after it is declared; it is not an out parameter (C would fill memory the program
# gives: a C.Pointer to an owned buffer) or a variadic one.
@pytest.mark.parametrize("signature, code, start, stop", [
    ("def f(p: Later) -> Void", "PARSE-EXTERN-TYPE", (2, 12), (2, 17)),
    ("def f() -> Later", "PARSE-EXTERN-TYPE", (2, 14), (2, 19)),
    ("def f(out p: Pair) -> Void", "PARSE-EXTERN-OUT", (6, 16), (6, 20)),
    ("def f(n: C.Int32, ..., p: Pair) -> Void", "PARSE-EXTERN-VARIADIC-TYPE", (6, 29), (6, 33)),
])
def test_a_c_struct_is_passed_in_or_returned_after_its_declaration(tmp_path, signature, code, start, stop):
    if code == "PARSE-EXTERN-TYPE":
        text = 'extern "/opt/libx.so"\n  %s\n  struct Later\n    n: C.Int32\n  end\nend\n' % signature
    else:
        text = 'extern "/opt/libx.so"\n  struct Pair\n    x: C.Int32\n    y: C.Int32\n  end\n  %s\nend\n' % signature
    assert at(problem_of(check(source(tmp_path, text)))) == (code, start, stop)


# C has no empty struct (PARSE-EXTERN-TYPE at the name), and the VM takes at most 1024 fields and 16 levels in one
# struct, nested ones counted (PARSE-EXTERN-ARITY at the name of the struct that goes over).
def test_a_c_struct_has_fields_within_the_limits(tmp_path):
    empty = 'extern "/opt/libx.so"\n  struct Empty\n  end\nend\n'
    assert at(problem_of(check(source(tmp_path, empty)))) == ("PARSE-EXTERN-TYPE", (2, 10), (2, 15))
    fields = "".join("    f%d: C.Int32\n" % k for k in range(513))
    wide = 'extern "/opt/libx.so"\n  struct Half\n%s  end\n  struct Wide\n    a: Half\n    b: Half\n  end\nend\n' \
        % fields
    assert at(problem_of(check(source(tmp_path, wide)))) == ("PARSE-EXTERN-ARITY", (517, 10), (517, 14))
    assert check(source(tmp_path, wide.replace("    b: Half\n", ""))).code == 0
    levels = 'extern "/opt/libx.so"\n  struct L0\n    n: C.Int32\n  end\n' + "".join(
        "  struct L%d\n    inner: L%d\n  end\n" % (k, k - 1) for k in range(1, 17)) + "end\n"
    assert at(problem_of(check(source(tmp_path, levels)))) == ("PARSE-EXTERN-ARITY", (50, 10), (50, 13))
    assert check(source(tmp_path, levels.replace("  struct L16\n    inner: L15\n  end\n", ""))).code == 0


# An extern block that declares a struct goes with the types in the declaration order, as one with a resource does.
def test_an_extern_block_with_a_struct_goes_with_the_types(tmp_path):
    block = 'extern "/opt/libx.so"\n  struct Pair\n    x: C.Int32\n  end\n  def pair() -> Pair\nend\n'
    assert check(source(tmp_path, block + '\ndef main() -> Void\n  puts(pair().x)\nend\n')).code == 0
    late = 'def main() -> Void\n  puts(pair().x)\nend\n\n' + block
    assert at(problem_of(check(source(tmp_path, late))))[:2] == ("CHECK-DECL-ORDER", (6, 3))
