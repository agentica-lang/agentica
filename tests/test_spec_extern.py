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

  def labs(n: C.Int64) -> C.Int64
end

extern "/opt/peer/libpeer.so"
  def peer(a: C.Int, b: C.Bool, s: C.String) -> Void
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
    ("def f(x: Float) -> C.Int", (2, 12), (2, 17)),
    ("def f(x: C.Int) -> Int", (2, 22), (2, 25)),
    ("def f(x: C.Float) -> Void", (2, 12), (2, 19)),
    ("def f(x: C.Int) -> C.Bytes", (2, 22), (2, 29)),
    ("def f(x: Void) -> Void", (2, 12), (2, 16)),
    ("def f(x: List[C.Int]) -> Void", (2, 12), (2, 23)),
])
def test_only_c_types_cross_an_extern_signature(tmp_path, signature, start, stop):
    text = 'extern "libc.so.6"\n  %s\nend\n' % signature
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-TYPE", start, stop)


def test_an_extern_function_has_a_c_name(tmp_path):
    text = 'extern "libc.so.6"\n  def ready?() -> C.Bool\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-EXTERN-NAME", (2, 7))


def test_an_extern_parameter_has_no_default(tmp_path):
    text = 'extern "libc.so.6"\n  def abs(n: C.Int = 1) -> C.Int\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-EXTERN-DEFAULT", (2, 11))


@pytest.mark.parametrize("text, start", [
    ('extern "libc.so.6"\n  def abs(n: C.Int) -> C.Int\n    return 1\n  end\nend\n', (3, 5)),
    ('extern "libc.so.6"\n  struct S\n  end\nend\n', (2, 3)),
    ('extern "libc.so.6"\n  def abs(n: C.Int) -> C.Int\n', (3, 1)),
    ('extern "libc.so.6" def abs(n: C.Int) -> C.Int\nend\n', (1, 20)),
    ('extern <<~A\n  a\n  b\nA\n  def abs(n: C.Int) -> C.Int\nend\n', (1, 8)),
    ('extern "libc.so.6"\n  compute export def abs(n: C.Int) -> C.Int\nend\n', (2, 3)),
    ('extern "libc.so.6"\n  compute abs(n: C.Int) -> C.Int\nend\n', (2, 3)),
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
    text = 'extern %s\n  def abs(n: C.Int) -> C.Int\nend\n' % library
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-LIBRARY", (1, 8), (1, stop))


def test_an_extern_function_takes_at_most_64_parameters(tmp_path):
    params = ", ".join("p%d: C.Int" % k for k in range(64))
    ok = 'extern "libc.so.6"\n  def f(%s) -> Void\nend\n' % params
    assert check(source(tmp_path, ok)).code == 0
    over = 'extern "libc.so.6"\n  def f(%s, extra: C.Int) -> Void\nend\n' % params
    start = len("  def f(%s, " % params) + 1
    assert at(problem_of(check(source(tmp_path, over)))) == (
        "PARSE-EXTERN-ARITY", (2, start), (2, start + len("extra: C.Int")))


def test_an_extern_block_follows_the_blank_line_rule(tmp_path):
    text = 'def main() -> Void\nend\nextern "libc.so.6"\n  def abs(n: C.Int) -> C.Int\nend\n'
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
  def db_exec(db: Db, sql: C.String, blob: C.Bytes, n: C.Int) -> C.Int
  compute def db_wait(db: Db) -> C.Int
  def db_handle(db: Db) -> C.Pointer
  def raw_len(p: C.Pointer) -> C.Int64
end

def use(db: Db) -> Int
  return db_wait(db)
end

def main() -> Void
  db = db_open("x.db").unwrap!
  pool = Pool(db: db)
  puts(db_exec(pool.db, "select 1", [0, 255], 2))
  raw: C.Pointer = db_handle(db)
  puts(Native.null?(raw) or Native.null?(Native.null()))
  puts(raw_len(raw))
  IO.inspect(db)
  puts(Task.await(Task.spawn_owning(&use, db)))
  Native.close(db)
end
"""


# A resource is a type of its own: a function declared -> Db gives Result[Db], a parameter takes the resource, C.Bytes
# is a List[Int], and C.Pointer is a type any code may name. Task.spawn_owning takes a resource.
def test_resources_pointers_and_bytes_check(tmp_path):
    result = check(source(tmp_path, RESOURCES))
    assert (result.code, result.stdout) == (0, '{"ok":true}\n')


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
@pytest.mark.parametrize("body, code, start, stop", [
    ("  db: Db = db_open()", "CHECK-TYPE-MISMATCH", (8, 12), (8, 21)),
    ("  p: C.Pointer = db_open().unwrap!", "CHECK-TYPE-MISMATCH", (8, 18), (8, 27)),
    ("  puts(db_handle(Native.null()))", "CHECK-TYPE-MISMATCH", (8, 18), (8, 31)),
    ("  Native.close(Native.null())", "CHECK-TYPE-MISMATCH", (8, 16), (8, 29)),
    ("  puts(Native.null() == Native.null())", "CHECK-TYPE-MISMATCH", (8, 22), (8, 24)),
    ("  puts(db_open().unwrap!)", "CHECK-TYPE-MISMATCH", (8, 8), (8, 25)),
    ("  puts(JSON.encode(db_open().unwrap!))", "CHECK-NOT-ENCODABLE", (8, 20), (8, 37)),
])
def test_resources_and_pointers_are_opaque(tmp_path, body, code, start, stop):
    assert at(problem_of(check(source(tmp_path, OPENER % body)))) == (code, start, stop)


# The block's free function is the VM's to call: a def of it, before or after the resource, is PARSE-EXTERN-FREE at
# the later of the two names.
@pytest.mark.parametrize("members, start, stop", [
    ("  resource Db, free: db_close\n  def db_close(db: Db) -> Void", (3, 7), (3, 15)),
    ("  def db_close(p: C.Pointer) -> Void\n  resource Db, free: db_close", (3, 22), (3, 30)),
])
def test_the_free_function_is_not_a_def_of_the_block(tmp_path, members, start, stop):
    text = 'extern "/opt/libdb.so"\n%s\nend\n' % members
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-FREE", start, stop)


@pytest.mark.parametrize("members, code, start", [
    ("  def db_open() -> Db\n  resource Db, free: db_close", "PARSE-EXTERN-TYPE", (2, 20)),
    ('  resource Db, free: db_close\nend\n\nextern "/opt/libdb.so"\n  def db_use(db: Db) -> C.Int', "PARSE-EXTERN-TYPE",
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
       '  export def db_open(name: C.String, out db: Db, out code: C.Int64) -> C.Int\n' \
       '  def db_fill(out n: C.Int, out x: C.Double, out on: C.Bool, out p: C.Pointer) -> Void\n' \
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
    ('extern "libc.so.6"\n  def f(out s: C.String) -> C.Int\nend\n', (2, 16), (2, 24)),
    ('extern "libc.so.6"\n  def f(out b: C.Bytes) -> Void\nend\n', (2, 16), (2, 23)),
    ('extern "libc.so.6"\n  def f(out result: C.Int) -> C.Int\nend\n', (2, 13), (2, 19)),
    ('extern "libc.so.6"\n  def _2(out n: C.Int) -> C.Int\nend\n', (2, 7), (2, 9)),
    ('def f(out n: Int) -> Int\n  return n\nend\n', (1, 7), (1, 10)),
    ('extern "libm.so.6"\n  def frexp(x: C.Double, out x: C.Int) -> C.Double\nend\n', (2, 30), (2, 31)),
    ('extern "libm.so.6"\n  def f(out x: C.Int, x: C.Double) -> C.Double\nend\n', (2, 23), (2, 24)),
])
def test_an_out_parameter_is_a_c_value_of_an_extern_function(tmp_path, text, start, stop):
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-OUT", start, stop)


def test_out_is_still_a_name_and_result_is_an_out_of_a_void_function(tmp_path):
    text = 'extern "libc.so.6"\n  def f(out result: C.Int) -> Void\nend\n\n' \
           'def g(out: Int) -> Int\n  return out\nend\n\ndef main() -> Void\n  puts(f().result + g(1))\nend\n'
    assert check(source(tmp_path, text)).code == 0


# The record is a type name of the file: a struct of that name is CHECK-REDEFINED-NAME at the extern function, two out
# parameters of one name are that code at the second (a field of the record twice), and the extern block may still
# come after the functions of the file.
def test_the_record_takes_its_name_and_follows_the_function(tmp_path):
    clash = 'struct DbOpen\n  x: Int\nend\n\n' + OUTS % ""
    assert at(problem_of(check(source(tmp_path, clash))))[:2] == ("CHECK-REDEFINED-NAME", (7, 3))
    twice = 'extern "libc.so.6"\n  def f(out x: C.Int, out x: C.Int) -> C.Int\nend\n'
    assert at(problem_of(check(source(tmp_path, twice)))) == ("CHECK-REDEFINED-NAME", (2, 23), (2, 35))
    late = 'def main() -> Void\n  puts(db_open().db)\nend\n\n' \
           'extern "libc.so.6"\n  def db_open(out db: C.Int) -> Void\nend\n'
    assert check(source(tmp_path, late)).code == 0
