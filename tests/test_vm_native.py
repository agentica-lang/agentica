"""Native calls (the extern blocks of docs/grammar/05-syntax.md and 06d-io-and-network.md) through the product CLI.

The peer is tests/fixtures/native/peer.c, built with the system C compiler into a shared library (a DLL on Windows, a
dylib on macOS) for each module run, so every C type crosses a real ABI; four cases also call the system SQLite
(libsqlite3.so.0 on Linux, which CI installs; libsqlite3.dylib on macOS; winsqlite3.dll on Windows). Native calls
exist on Linux x86_64, Windows x64 and macOS: elsewhere a program that declares extern functions is refused at load
with RUNTIME-NATIVE-UNSUPPORTED, which test_other_systems_refuse_extern_at_load checks. On Windows Native.wait_* polls
only sockets, so the peer's "pipe" is a loopback TCP pair there. Tests assert codes and spans, never messages
(AGENTS.md).
"""
import ctypes
import json
import os
import platform
import subprocess
import time

import pytest

from tests.agentica_test import FIXTURES, TARGET_OS, WINDOWS, cli, host_only, require, run, tool, vm_environment

MACOS = TARGET_OS == "darwin"
# The systems whose build has libffi; the others refuse native code at load, and the call cases skip there.
NATIVE = (TARGET_OS.startswith("linux") and platform.machine() == "x86_64") or \
    (WINDOWS and platform.machine() in ("AMD64", "x86_64")) or MACOS
NATIVE_CALLS = host_only(not NATIVE, "libffi is built for Linux x86_64, Windows x64 and macOS only")

# The C library and the math library, found by name by the system loader. On Windows the UCRT holds both, and on
# macOS libSystem (in the dyld shared cache, not on disk).
LIBC = "ucrtbase.dll" if WINDOWS else "libSystem.B.dylib" if MACOS else "libc.so.6"
LIBM = "ucrtbase.dll" if WINDOWS else "libSystem.B.dylib" if MACOS else "libm.so.6"

PEER_EXTERN = """extern "{library}"
  def peer_add(a: C.Int32, b: C.Int32) -> C.Int32
  def peer_mul64(a: C.Int64, b: C.Int64) -> C.Int64
  def peer_scale(x: C.Double, k: C.Double) -> C.Double
  def peer_not(b: C.Bool) -> C.Bool
  def peer_len(s: C.String) -> C.Int64
  def peer_upper(s: C.String) -> C.String
  def peer_bump() -> Void
  def peer_bumps() -> C.Int32
  def peer_null() -> C.String
  def peer_bad_utf8() -> C.String
  def peer_sum9(a: C.Int32, b: C.Int32, c: C.Int32, d: C.Int32, e: C.Int32, f: C.Int32, g: C.Int32, h: C.Int32, i: C.Int64) -> C.Int64
  def peer_mix(
    a: C.Int32, b: C.Double, c: C.Int64, d: C.Bool, s: C.String, e: C.Double, f: C.Double, g: C.Double, h: C.Double,
    i: C.Double, j: C.Double, k: C.Double, l: C.Double,
  ) -> C.Double
end

"""


def library_name(name):
    """The file name of the shared library NAME: libNAME.so, NAME.dll on Windows, libNAME.dylib on macOS."""
    return name + ".dll" if WINDOWS else "lib%s.dylib" % name if MACOS else "lib%s.so" % name


def shared_library(tmp_path_factory, name, *flags, folder=None):
    """Build tests/fixtures/native/NAME.c into a shared library (library_name) in FOLDER (a new one by default), with
    the extra compiler FLAGS, and return its absolute path."""
    folder = folder or tmp_path_factory.mktemp("native")
    out = folder / library_name(name)
    kind = ["-shared"] if WINDOWS else ["-dynamiclib"] if MACOS else ["-shared", "-fPIC"]
    subprocess.run([tool("cc"), *kind, "-O1", "-o", str(out), str(FIXTURES / "native" / (name + ".c")), *flags],
                   check=True)
    return out


def literal(path):
    """PATH as the text of an Agentica string literal: a Windows path has backslashes, which the literal escapes."""
    return str(path).replace("\\", "\\\\")


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    """The path of the peer library, built once for the module."""
    return shared_library(tmp_path_factory, "peer", *(["-lws2_32"] if WINDOWS else []))


def program(tmp_path, text, name="program.agc"):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def agentica(*words, env=None, **options):
    """Run the CLI with WORDS; ENV adds to (or, with None values, removes from) the VM's environment."""
    return run(cli() + [str(word) for word in words], env=vm_environment(env), **options)


def diagnostic(result, status):
    """The code and the start (line, column) of the JSON diagnostic of a run that ended with STATUS."""
    assert result.code == status, result.stdout + result.stderr
    found = json.loads(result.stderr.strip().split("\n")[-1])
    return found["code"], (found["range"]["start"]["line"], found["range"]["start"]["column"])


@NATIVE_CALLS
def test_each_c_type_crosses_to_the_peer_and_back(tmp_path, peer):
    main = """def main() -> Void
  puts(peer_add(40, 2))
  puts(peer_add(-2_147_483_648, 0))
  puts(peer_mul64(3_000_000_000, 3))
  puts(peer_scale(1.5, -2.0))
  puts(peer_not(false))
  puts(peer_not(true))
  puts(peer_len("héllo"))
  puts(peer_upper("abc"))
  peer_bump()
  peer_bump()
  puts(peer_bumps())
  puts(peer_null().size)
  puts(peer_bad_utf8())
  puts(peer_sum9(1, 2, 3, 4, 5, 6, 7, 8, 9_000_000_000))
  puts(peer_mix(1, 0.5, 2, true, "four", 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0))
  shout = &peer_upper
  puts(shout.call("fn"))
end
"""
    result = agentica(program(tmp_path, PEER_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "42", "-2147483648", "9000000000", "-3.0", "true", "false", "6", "ABC", "2", "0", "a�b", "9000000036",
        "1015.5", "FN", "",
    ]


@NATIVE_CALLS
def test_an_extern_function_is_exported_and_imported_like_any_function(tmp_path, peer):
    raw = PEER_EXTERN.format(library=literal(peer)).replace("  def peer_add(", "  export def peer_add(")
    program(tmp_path, raw.rstrip("\n") + "\n", "raw.agc")
    main = program(tmp_path, 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.peer_add(1, 2))\nend\n')
    result = agentica(main)
    assert (result.code, result.stdout, result.stderr) == (0, "3\n", "")


@NATIVE_CALLS
def test_a_system_library_is_found_by_its_name(tmp_path):
    text = 'extern "%s"\n  def pow(x: C.Double, y: C.Double) -> C.Double\nend\n\n' \
           'def main() -> Void\n  puts(pow(2.0, 10.0))\nend\n' % LIBM
    result = agentica(program(tmp_path, text))
    assert (result.code, result.stdout) == (0, "1024.0\n")


# A bare name is searched in the system's folders only, never in the working directory (dlopen's rule on Linux; on
# Windows and macOS the loader's own search would take it). A relative path resolves against the working directory too,
# so it is refused: the front end refuses "lib/x.so", and on Windows the loader refuses "lib\x.dll" and "C:x.dll", which
# the front end cannot tell from a name.
@NATIVE_CALLS
def test_a_library_is_not_searched_in_the_working_directory(tmp_path, peer):
    here = library_name("agentica_peer_here")
    (tmp_path / "lib").mkdir()
    for folder in (tmp_path, tmp_path / "lib"):
        (folder / here).write_bytes(peer.read_bytes())
    names = [here] + (["lib\\\\" + here, tmp_path.drive + here] if WINDOWS else [])
    for name in names:
        text = 'extern "%s"\n  def peer_add(a: C.Int32, b: C.Int32) -> C.Int32\nend\n\n' \
               'def main() -> Void\n  puts(peer_add(1, 2))\nend\n' % name
        result = agentica("--json", program(tmp_path, text), cwd=tmp_path,
                          env={"LD_LIBRARY_PATH": None, "DYLD_LIBRARY_PATH": None})
        assert diagnostic(result, 1) == ("RUNTIME-NATIVE-LOAD", (2, 3)), name


@NATIVE_CALLS
def test_calls_from_tasks_on_several_schedulers(tmp_path, peer):
    main = """def work(n: Int) -> Int
  total = 0
  for k in 1..200
    total = peer_add(total, peer_len(peer_upper("ab")) - 1)
  end
  return total + n * 0
end

def main() -> Void
  tasks: List[Task[Int]] = []
  for n in 1..8
    tasks = tasks.push(Task.spawn(&work, n))
  end
  sum = 0
  for task in tasks
    sum += Task.await(task)
  end
  puts(sum)
end
"""
    result = agentica("--schedulers", "4", program(tmp_path, PEER_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "1600\n", "")


COMPUTE_EXTERN = """extern "{library}"
  compute def peer_wait_flag(limit_ms: C.Int32) -> C.Int32
  def peer_set_flag() -> Void
  def peer_returned() -> C.Int32
  compute def peer_word(n: C.Int32) -> C.String
  compute def peer_half(n: C.Int64) -> C.Double
  compute def peer_bump() -> Void
  def peer_bumps() -> C.Int32
  compute def peer_nap(ms: C.Int32) -> C.Int32
  def peer_naps() -> C.Int32
end

"""


# The compute call returns 1 only once main's fast call has set the flag. On one scheduler that proves the waiting task
# gave the scheduler to main; a call that held it would return 0 after 20 seconds.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_compute_call_waits_while_other_tasks_run(tmp_path, peer, schedulers):
    main = """def main() -> Void
  waiter = Task.spawn(&peer_wait_flag, 20_000)
  Task.sleep(20)
  peer_set_flag()
  puts(Task.await(waiter))
  peer_bump()
  puts(peer_bumps())
  puts(peer_word(2))
  puts(peer_half(5))
end
"""
    source = program(tmp_path, COMPUTE_EXTERN.format(library=literal(peer)) + main)
    result = agentica("--schedulers", schedulers, source)
    assert (result.code, result.stdout, result.stderr) == (0, "1\n1\nccc\n2.5\n", "")


# A cancelled task stops waiting at once; its call runs on to its end, and the result is dropped.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_cancel_drops_the_result_of_a_compute_call(tmp_path, peer, schedulers):
    main = """def wait_flag(limit: Int) -> Result[Int]
  return ok(peer_wait_flag(limit))
end

def main() -> Void
  waiter = Task.spawn(&wait_flag, 20_000)
  Task.sleep(20)
  Task.cancel(waiter)
  puts(Task.await(waiter))
  puts(peer_returned())
  peer_set_flag()
  n = 0
  while peer_returned() == 0 and n < 2000
    Task.sleep(1)
    n += 1
  end
  Task.sleep(20)
  puts(peer_word(3))
end
"""
    source = program(tmp_path, COMPUTE_EXTERN.format(library=literal(peer)) + main)
    result = agentica("--schedulers", schedulers, source)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == ['error("task: cancelled")', "0", "ddd", ""]


@NATIVE_CALLS
def test_many_compute_calls_at_once(tmp_path, peer):
    main = """def work(n: Int) -> Float
  letter = String.from_code(97 + n % 26)
  if peer_word(n) != letter + letter + letter
    return -1000.0
  end
  return peer_half(n) + 3.0
end

def main() -> Void
  tasks: List[Task[Float]] = []
  for n in 1..200
    tasks = tasks.push(Task.spawn(&work, n))
  end
  sum = 0.0
  for task in tasks
    sum += Task.await(task)
  end
  puts(sum)
end
"""
    result = agentica("--schedulers", "4", program(tmp_path, COMPUTE_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "10650.0\n", "")


# The run ends (main returns, or System.exit) while a compute call naps for 3 seconds on a pool thread: the VM does not
# wait for the call, so the run takes far less than the nap.
@NATIVE_CALLS
@pytest.mark.parametrize("ending, code", [("puts(\"done\")", 0), ("System.exit(3)", 3)])
def test_the_run_ends_while_a_compute_call_runs(tmp_path, peer, ending, code):
    main = """def nap(ms: Int) -> Int
  return peer_nap(ms)
end

def main() -> Void
  napper = Task.spawn(&nap, 3_000)
  Task.sleep(50)
  %s
end
""" % ending
    source = program(tmp_path, COMPUTE_EXTERN.format(library=literal(peer)) + main)
    start = time.monotonic()
    result = agentica(source, timeout=20)
    assert (result.code, result.stderr) == (code, "")
    assert result.stdout == ("done\n" if code == 0 else "")
    assert time.monotonic() - start < 2.0


# The run ends while a compute call waits inside fwrite to a full pipe, holding the lock of that C stream (one other
# than stdout or stderr, which the end of the run flushes itself: #616). On Windows exit() flushes every C stream
# while the call runs, and ExitProcess (behind exit and _exit) kills the call's thread and then runs the DLLs' detach
# code, where the C library may flush again and wait for the dead thread's lock (Wine's does). The VM ends the process
# with TerminateProcess, which runs neither, as _exit does on Linux and macOS. main prints 1 once the writes began.
@NATIVE_CALLS
@pytest.mark.parametrize("ending, code", [("", 0), ("System.exit(4)", 4)])
def test_the_run_ends_while_a_compute_call_holds_a_c_stream(tmp_path, peer, ending, code):
    main = """extern "%s"
  compute def peer_write_stalled() -> C.Int32
  def peer_write_started() -> C.Int32
end

def write(times: Int) -> Int
  return peer_write_stalled() * times
end

def main() -> Void
  writer = Task.spawn(&write, 1)
  n = 0
  while peer_write_started() == 0 and n < 2000
    Task.sleep(1)
    n += 1
  end
  Task.sleep(100)
  puts(peer_write_started())
  %s
end
""" % (literal(peer), ending)
    result = agentica(program(tmp_path, main), timeout=20)
    assert (result.code, result.stdout, result.stderr) == (code, "1\n", "")


# One pool thread (one scheduler) runs the first call while the other 49 wait in its queue. Once their tasks are
# cancelled, the waiting calls are never made: only the first nap is counted, even after a second nap would have ended.
@NATIVE_CALLS
def test_a_cancel_skips_a_compute_call_that_has_not_started(tmp_path, peer):
    main = """def nap(ms: Int) -> Result[Int]
  return ok(peer_nap(ms))
end

def main() -> Void
  tasks: List[Task[Result[Int]]] = []
  for k in 1..50
    tasks = tasks.push(Task.spawn(&nap, 100))
  end
  Task.sleep(20)
  for task in tasks
    Task.cancel(task)
  end
  n = 0
  while peer_naps() == 0 and n < 2000
    Task.sleep(1)
    n += 1
  end
  Task.sleep(250)
  puts(peer_naps())
end
"""
    result = agentica("--schedulers", "1", program(tmp_path, COMPUTE_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "1\n", "")


RESOURCE_EXTERN = """extern "{library}"
  resource Res, free: peer_res_free
  def peer_res_open(value: C.Int32) -> Res
  def peer_res_get(res: Res) -> C.Int32
  compute def peer_res_hold(res: Res, limit_ms: C.Int32) -> C.Int32
  compute def peer_res_open_later(value: C.Int32, limit_ms: C.Int32) -> Res
  def peer_res_holding() -> C.Int32
  def peer_res_frees() -> C.Int32
  def peer_res_busy_frees() -> C.Int32
  def peer_set_flag() -> Void
  def peer_bytes_sum(bytes: C.Bytes, n: C.Int32) -> C.Int32
  def peer_ptr_echo(p: C.Pointer) -> C.Pointer
  def peer_ptr_static() -> C.Pointer
  def peer_ptr_read(p: C.Pointer) -> C.Int32
  def peer_res_bytes(res: Res, bytes: C.Bytes, n: C.Int32) -> C.Int32
end

def get(res: Res) -> Int
  return peer_res_get(res)
end

def open_one(n: Int) -> Int
  res = peer_res_open(n).unwrap!
  return peer_res_get(res)
end

def hold(res: Res) -> Result[Int]
  return ok(peer_res_hold(res, 20_000))
end

def wait_for(frees: Int) -> Void
  n = 0
  while peer_res_frees() < frees and n < 2000
    Task.sleep(1)
    n += 1
  end
end

def wait_holding() -> Void
  n = 0
  while peer_res_holding() == 0 and n < 2000
    Task.sleep(1)
    n += 1
  end
end

"""


# Native.close frees once and a second close does nothing; a NULL result is an error value; C.Bytes and C.Pointer
# cross. The peer counts each free, and frees the memory, so a double free would also crash the run.
@NATIVE_CALLS
def test_a_resource_is_freed_once_and_null_is_an_error(tmp_path, peer):
    main = """def main() -> Void
  res = peer_res_open(7).unwrap!
  IO.inspect(res)
  puts(peer_res_get(res))
  Native.close(res)
  Native.close(res)
  puts(peer_res_frees())
  IO.inspect(peer_res_open(-1))
  puts(peer_bytes_sum([1, 2, 255], 3))
  puts(peer_bytes_sum([], 0))
  puts(Native.null?(peer_ptr_echo(Native.null())))
  p = peer_ptr_static()
  puts(Native.null?(p))
  puts(peer_ptr_read(peer_ptr_echo(p)))
  IO.inspect(p)
end
"""
    result = agentica(program(tmp_path, RESOURCE_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "<Res>", "7", "1", 'error("peer_res_open returned NULL")', "258", "0", "true", "false", "42", "<C.Pointer>", "",
    ]


# A call with a closed resource and a C.Bytes item that is not a byte stop the run at the extern function, before
# the call; a closed resource is found first, even with a bad byte. Task.spawn_owning of a closed resource is
# RUNTIME-HANDLE-NOT-OWNED.
@NATIVE_CALLS
@pytest.mark.parametrize("case, code, line", [
    ("closed", "RUNTIME-NATIVE-CLOSED", 4),
    ("owned", "RUNTIME-NATIVE-CLOSED", 4),
    ("handed", "RUNTIME-HANDLE-NOT-OWNED", RESOURCE_EXTERN.count("\n") + 10),
    ("byte", "RUNTIME-INVALID-NUMBER", 11),
    ("both", "RUNTIME-NATIVE-CLOSED", 15),
])
def test_a_closed_resource_and_a_bad_byte_stop_the_call(tmp_path, peer, case, code, line):
    main = """def main() -> Void
  res = peer_res_open(3).unwrap!
  arg = System.args()[0]
  if arg == "closed"
    Native.close(res)
  elsif arg == "owned"
    puts(Task.await(Task.spawn_owning(&get, res)))
  elsif arg == "handed"
    Native.close(res)
    Task.await(Task.spawn_owning(&get, res))
  elsif arg == "both"
    Native.close(res)
    puts(peer_res_bytes(res, [1, 256], 2))
  else
    puts(peer_bytes_sum([1, 256], 2))
  end
  puts(peer_res_get(res))
end
"""
    result = agentica("--json", program(tmp_path, RESOURCE_EXTERN.format(library=literal(peer)) + main), case)
    assert (diagnostic(result, 1)[0], diagnostic(result, 1)[1][0]) == (code, line)
    assert result.stdout == ("3\n" if case == "owned" else "")


MEMORY_EXTERN = """extern "{library}"
  def peer_text() -> C.Pointer
  def peer_ptr_static() -> C.Pointer
  def peer_ptr_read(p: C.Pointer) -> C.Int32
  def peer_ptr_value(p: C.Pointer) -> C.Int64
end

"""


# Native.get_string reads from an offset up to the NUL, or exactly the length given (the NUL and a cut character
# included, which becomes U+FFFD); Native.get_bytes copies bytes. NULL with length 0 is empty, as C means it. The old
# names string_at and bytes_at read the same at offset 0. Native.pointer makes the pointer of an integer, which C sees
# as that integer, and a pointer's value makes the same pointer again.
@NATIVE_CALLS
def test_memory_that_c_returns_is_read_as_text_or_bytes(tmp_path, peer):
    main = """def main() -> Void
  p = peer_text()
  puts(Native.get_string(p, 0))
  puts(Native.get_string(p, 7))
  IO.inspect(Native.get_string(p, 0, 12))
  puts(Native.get_string(p, 0, 2))
  puts(Native.get_string(p, 3, 0).size)
  puts(Native.get_bytes(p, 0, 12))
  puts(Native.get_bytes(p, 7, 2))
  puts(Native.get_bytes(Native.null(), 0, 0))
  puts(Native.get_string(Native.null(), 0, 0).size)
  puts(Native.string_at(p) == Native.get_string(p, 0) and Native.string_at(p, 12) == Native.get_string(p, 0, 12))
  puts(Native.bytes_at(p, 12).inspect == Native.get_bytes(p, 0, 12).inspect)
  puts(peer_ptr_value(Native.pointer(-1)))
  puts(peer_ptr_value(Native.pointer(4096)))
  puts(Native.null?(Native.pointer(0)))
  puts(peer_ptr_read(Native.pointer(peer_ptr_value(peer_ptr_static()))))
end
"""
    result = agentica(program(tmp_path, MEMORY_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "héllo", "world", '"héllo\\u0000world"', "h\ufffd", "0",
        "[104, 195, 169, 108, 108, 111, 0, 119, 111, 114, 108, 100]", "[119, 111]", "[]", "0", "true", "true", "-1",
        "4096", "true", "42", "",
    ]


# A read at NULL is RUNTIME-NATIVE-NULL at the pointer, a negative offset RUNTIME-NATIVE-BOUNDS at it and a negative
# length RUNTIME-INVALID-COUNT at the length; the pointer is checked first. The old names fail the same way.
@NATIVE_CALLS
@pytest.mark.parametrize("call, code, argument", [
    ("Native.get_string(Native.null(), 0)", "RUNTIME-NATIVE-NULL", "Native.null()"),
    ("Native.get_string(Native.null(), 0, 1)", "RUNTIME-NATIVE-NULL", "Native.null()"),
    ("Native.get_bytes(Native.pointer(0), 0, 1)", "RUNTIME-NATIVE-NULL", "Native.pointer(0)"),
    ("Native.get_bytes(Native.null(), 0, -1)", "RUNTIME-NATIVE-NULL", "Native.null()"),
    ("Native.get_string(peer_text(), 0, -1)", "RUNTIME-INVALID-COUNT", "-1"),
    ("Native.get_bytes(peer_text(), 0, -1)", "RUNTIME-INVALID-COUNT", "-1"),
    ("Native.get_string(peer_text(), -1)", "RUNTIME-NATIVE-BOUNDS", "-1"),
    ("Native.get_bytes(peer_text(), -2, 1)", "RUNTIME-NATIVE-BOUNDS", "-2"),
    ("Native.string_at(Native.null())", "RUNTIME-NATIVE-NULL", "Native.null()"),
    ("Native.bytes_at(peer_text(), -1)", "RUNTIME-INVALID-COUNT", "-1"),
])
def test_a_read_at_null_or_with_a_negative_length_stops_the_run(tmp_path, peer, call, code, argument):
    line = "  IO.inspect(%s)" % call
    main = 'def main() -> Void\n  puts("before")\n%s\nend\n' % line
    result = agentica("--json", program(tmp_path, MEMORY_EXTERN.format(library=literal(peer)) + main))
    assert result.stdout == "before\n"
    assert diagnostic(result, 1) == (code, (MEMORY_EXTERN.count("\n") + 3, line.index(argument) + 1))


# The memory builtins are native code too: a program that calls only them is refused at load like one with extern
# functions.
def test_deny_native_refuses_the_memory_builtins(tmp_path):
    text = 'def main() -> Void\n  puts("started")\n  puts(Native.string_at(Native.pointer(0), 0))\nend\n'
    result = agentica("--json", "--deny-native", program(tmp_path, text))
    assert result.stdout == ""
    assert diagnostic(result, 2)[0] == ("RUNTIME-NATIVE-DENIED" if NATIVE else "RUNTIME-NATIVE-UNSUPPORTED")


FLOAT_EXTERN = """extern "{library}"
  def peer_scalef(x: C.Float, k: C.Float) -> C.Float
  def peer_fmix(
    a: C.Int32, b: C.Float, c: C.Double, d: C.Float, e: C.Int64, f: C.Float, g: C.Float, h: C.Float, i: C.Float,
    j: C.Float, k: C.Float, l: C.Float, m: C.Float,
  ) -> C.Double
  def peer_out_half(x: C.Float, out half: C.Float) -> Void
end

"""


# C.Float crosses as a 32-bit float: the result is the float widened (0.1 is not exact), floats mixed with integers
# and doubles past the registers take their places, an out C.Float is written by C, and a Float outside the range of a
# float becomes an infinity.
@NATIVE_CALLS
def test_c_float_crosses_to_the_peer_and_back(tmp_path, peer):
    main = """def main() -> Void
  puts(peer_scalef(1.5, -3.0))
  puts(peer_scalef(0.1, 1.0))
  puts(peer_fmix(1, 0.5, 2.0, 0.25, 3, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.5))
  puts(peer_out_half(5.0).half)
  puts(peer_scalef(1_000_000_000_000_000_000_000_000_000_000_000_000_000.0, 1.0))
end
"""
    result = agentica(program(tmp_path, FLOAT_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == ["-4.5", "0.10000000149011612", "15.25", "2.5", "+inf.0", ""]


BUFFER_EXTERN = """extern "{library}"
  def peer_fill_floats(out: C.Pointer, n: C.Int32) -> Void
  def peer_sum_floats(xs: C.Pointer, n: C.Int32) -> C.Double
  def peer_fill_ints(out: C.Pointer, n: C.Int32) -> Void
  def peer_sum_int64s(xs: C.Pointer, n: C.Int32) -> C.Int64
  def peer_strs_len(strs: C.Pointer, n: C.Int32) -> C.Int64
  def peer_static_floats() -> C.Pointer
  def peer_static_int64s() -> C.Pointer
  compute def peer_floats_hold(xs: C.Pointer, n: C.Int32, limit_ms: C.Int32) -> C.Double
  def peer_res_holding() -> C.Int32
  def peer_set_flag() -> Void
end

"""


def stopped_buffer_program(tmp_path, peer, schedulers, main, out):
    """Run MAIN after BUFFER_EXTERN on SCHEDULERS schedulers; it must print OUT and stop. Its diagnostic's code and
    start."""
    text = BUFFER_EXTERN.format(library=literal(peer)) + main
    result = agentica("--json", "--schedulers", schedulers, program(tmp_path, text))
    assert result.stdout == out
    return diagnostic(result, 1)


# An owned buffer is a C.Pointer that C fills and reads: typed reads and writes at byte offsets, signed and unsigned,
# bulk reads and writes of Int and Float lists, a pointer array of owned C strings, and a free that runs once. The
# typed reads take a C.Pointer that C returns too, as Native.get_string does; a NULL one with count 0 is empty.
@NATIVE_CALLS
def test_c_fills_and_reads_an_owned_buffer(tmp_path, peer):
    main = """def main() -> Void
  buf = Native.memory_pointer(16)
  puts(Native.get_array_of_int32(buf, 0, 4))
  peer_fill_floats(buf, 4)
  puts(Native.get_array_of_float32(buf, 0, 4))
  puts(Native.get_float32(buf, 12))
  Native.put_array_of_float32(buf, 4, [2.0, 3.5, 4.0])
  puts(peer_sum_floats(buf, 4))
  peer_fill_ints(buf, 4)
  puts(Native.get_array_of_int32(buf, 0, 4))
  puts([Native.get_int8(buf, 0), Native.get_uint8(buf, 0), Native.get_int16(buf, 0), Native.get_uint16(buf, 0)])
  puts([Native.get_int32(buf, 0), Native.get_uint32(buf, 0), Native.get_int32(buf, 9)])
  Native.put_int8(buf, 0, 255)
  Native.put_int16(buf, 2, -2)
  Native.put_int32(buf, 4, 4_294_967_295)
  puts([Native.get_int8(buf, 0), Native.get_uint16(buf, 2), Native.get_int32(buf, 4)])
  wide = Native.memory_pointer(24)
  Native.put_array_of_int64(wide, 0, [1, -2, 3_000_000_000])
  puts(peer_sum_int64s(wide, 3))
  Native.put_int64(wide, 16, -5)
  Native.put_float64(wide, 8, 2.5)
  Native.put_float32(wide, 0, 0.1)
  puts([Native.get_float64(wide, 8), Native.get_float32(wide, 0)])
  puts(Native.get_int64(wide, 16))
  puts(Native.get_array_of_float64(wide, 8, 1))
  puts(Native.get_array_of_int64(wide, 16, 1))
  Native.put_array_of_float64(wide, 0, [0.5, 1.5])
  puts(Native.get_array_of_float64(wide, 0, 2))
  a = Native.memory_pointer(4)
  b = Native.memory_pointer(6)
  Native.put_string(a, 0, "abc")
  Native.put_string(b, 0, "hello")
  names = Native.memory_pointer(16)
  Native.put_pointer(names, 0, a)
  Native.put_pointer(names, 8, b)
  puts(peer_strs_len(names, 2))
  puts(Native.get_string(Native.get_pointer(names, 8), 0))
  puts(Native.get_string(a, 0))
  puts(Native.get_bytes(a, 0, 4))
  puts(Native.get_string(b, 1, 2))
  IO.inspect(a)
  puts(Native.null?(a))
  Native.free(a)
  Native.free(a)
  puts(Native.null?(a))
  puts(Native.get_array_of_int32(Native.memory_pointer(0), 0, 0))
  floats = peer_static_floats()
  puts(Native.get_array_of_float32(floats, 0, 3))
  puts(Native.get_float32(floats, 4))
  puts(Native.get_array_of_int64(peer_static_int64s(), 0, 2))
  puts(Native.get_int64(peer_static_int64s(), 8))
  puts(Native.get_array_of_float64(Native.null(), 0, 0))
end
"""
    result = agentica(program(tmp_path, BUFFER_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "[0, 0, 0, 0]", "[0.0, 0.5, 1.0, 1.5]", "1.5", "9.5", "[-3, -2, 1, 6]", "[-3, 253, -3, 65533]",
        "[-3, 4294967293, 100663296]", "[-1, 65534, -1]", "2999999999", "[2.5, 0.10000000149011612]", "-5",
        "[2.5]", "[-5]", "[0.5, 1.5]", "8", "hello", "abc", "[97, 98, 99, 0]", "el", "<C.Pointer>", "false", "false",
        "[]", "[1.5, -2.25, 1.0000000150474662e+30]", "-2.25", "[7, -9]", "-9", "[]", "",
    ]


# An owned buffer knows its size: a read or write before or past it is RUNTIME-NATIVE-BOUNDS (at the offset, or at the
# count or list that runs past), and a freed one RUNTIME-NATIVE-CLOSED, also as an extern argument. A C pointer has no
# size, but NULL and a negative offset are refused; a value that does not fit is RUNTIME-INTEGER-OVERFLOW, a NUL in a
# C string RUNTIME-INVALID-CHARACTER, and Native.free of a pointer that C gave RUNTIME-NATIVE-NOT-OWNED.
@NATIVE_CALLS
@pytest.mark.parametrize("line, code, argument", [
    ("Native.get_int32(buf, 13)", "RUNTIME-NATIVE-BOUNDS", "13"),
    ("Native.get_int8(buf, 16)", "RUNTIME-NATIVE-BOUNDS", "16"),
    ("Native.get_int64(buf, 17)", "RUNTIME-NATIVE-BOUNDS", "17"),
    ("Native.get_int8(buf, -1)", "RUNTIME-NATIVE-BOUNDS", "-1"),
    ("Native.get_array_of_float32(buf, 4, 4)", "RUNTIME-NATIVE-BOUNDS", "4)"),
    ("Native.get_array_of_int64(buf, 0, 4_611_686_018_427_387_904)", "RUNTIME-NATIVE-BOUNDS", "4_6"),
    ("Native.get_array_of_int32(buf, 0, -1)", "RUNTIME-INVALID-COUNT", "-1"),
    ("Native.put_array_of_int64(buf, 8, [1, 2])", "RUNTIME-NATIVE-BOUNDS", "[1"),
    ("Native.put_string(buf, 0, \"0123456789abcdef\")", "RUNTIME-NATIVE-BOUNDS", "\"0"),
    ("Native.get_string(full, 0)", "RUNTIME-NATIVE-BOUNDS", "full"),
    ("Native.get_string(full, 2)", "RUNTIME-NATIVE-BOUNDS", "full"),
    ("Native.get_string(buf, 17)", "RUNTIME-NATIVE-BOUNDS", "17"),
    ("Native.get_bytes(buf, 0, 17)", "RUNTIME-NATIVE-BOUNDS", "17"),
    ("Native.get_bytes(buf, 8, 9)", "RUNTIME-NATIVE-BOUNDS", "9"),
    ("Native.put_bytes(buf, 14, [1, 2, 3])", "RUNTIME-NATIVE-BOUNDS", "[1"),
    ("Native.put_bytes(buf, -1, [1])", "RUNTIME-NATIVE-BOUNDS", "-1"),
    ("Native.put_bytes(buf, 0, [1, 256])", "RUNTIME-INTEGER-OVERFLOW", "[1"),
    ("Native.put_bytes(buf, 0, [-1])", "RUNTIME-INTEGER-OVERFLOW", "[-1"),
    ("Native.get_bytes(gone, 0, 1)", "RUNTIME-NATIVE-CLOSED", "gone"),
    ("Native.get_int32(Native.null(), 0)", "RUNTIME-NATIVE-NULL", "Native.null()"),
    ("Native.put_float64(Native.null(), 8, 1.0)", "RUNTIME-NATIVE-NULL", "Native.null()"),
    ("Native.get_int32(peer_static_int64s(), -4)", "RUNTIME-NATIVE-BOUNDS", "-4"),
    ("Native.put_int8(buf, 0, 256)", "RUNTIME-INTEGER-OVERFLOW", "256"),
    ("Native.put_int32(buf, 0, -2_147_483_649)", "RUNTIME-INTEGER-OVERFLOW", "-2_"),
    ("Native.put_array_of_int32(buf, 0, [1, 4_294_967_296])", "RUNTIME-INTEGER-OVERFLOW", "[1"),
    ("Native.put_string(buf, 0, \"a\" + String.from_code(0))", "RUNTIME-INVALID-CHARACTER", "\"a"),
    ("Native.free(peer_static_floats())", "RUNTIME-NATIVE-NOT-OWNED", "peer_static_floats()"),
    ("Native.memory_pointer(-1)", "RUNTIME-INVALID-COUNT", "-1"),
    ("Native.memory_pointer(4_611_686_018_427_387_904)", "RUNTIME-INVALID-COUNT", "4_6"),
    ("Native.get_int8(gone, 0)", "RUNTIME-NATIVE-CLOSED", "gone"),
    ("Native.put_pointer(buf, 0, gone)", "RUNTIME-NATIVE-CLOSED", "gone"),
    ("peer_sum_floats(gone, 1)", "RUNTIME-NATIVE-CLOSED", None),
])
def test_bounds_null_and_freed_buffers_stop_the_run(tmp_path, peer, line, code, argument):
    text = "  %s" % line if line.startswith(("Native.put", "Native.free")) else "  IO.inspect(%s)" % line
    main = 'def main() -> Void\n  buf = Native.memory_pointer(16)\n  gone = Native.memory_pointer(4)\n' \
        '  Native.free(gone)\n  full = Native.memory_pointer(2)\n  Native.put_int16(full, 0, 24_929)\n' \
        '  puts("before")\n%s\nend\n' % text
    result = agentica("--json", program(tmp_path, BUFFER_EXTERN.format(library=literal(peer)) + main))
    assert result.stdout == "before\n"
    # An extern call fails at its extern function, as for a closed resource.
    where = (BUFFER_EXTERN.count("\n") + 8, text.index(argument) + 1) if argument else (3, 3)
    assert diagnostic(result, 1) == (code, where)


# Native.put_bytes writes a List of bytes that C reads (two little-endian int64s here: every target with native calls
# is little-endian) and that Native.get_bytes gives back unchanged.
@NATIVE_CALLS
def test_put_bytes_writes_what_get_bytes_reads_back(tmp_path, peer):
    main = """def main() -> Void
  buf = Native.memory_pointer(16)
  Native.put_bytes(buf, 0, [1, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0])
  puts(peer_sum_int64s(buf, 2))
  copy = Native.memory_pointer(16)
  Native.put_bytes(copy, 0, Native.get_bytes(buf, 0, 16))
  puts(Native.get_bytes(copy, 0, 16).inspect == Native.get_bytes(buf, 0, 16).inspect)
  Native.put_bytes(copy, 15, [])
  Native.put_bytes(copy, 16, [])
  puts(Native.get_bytes(copy, 7, 3))
end
"""
    result = agentica(program(tmp_path, BUFFER_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "256\ntrue\n[0, 255, 0]\n", "")


# The block form of Native.memory_pointer yields a new buffer, frees it when the block ends and returns the block's
# value: a buffer that the block gives back is freed, and so is one when the block ends early with an error that a
# `try` returned (the block hands its buffer out over a channel to show it).
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
@pytest.mark.parametrize("tail, out", [
    ("  kept = Native.memory_pointer(8) do |buf| buf end\n", "9.5\n"),
    ("  failed = Native.memory_pointer(8) do |buf| first(buf, out) end\n  puts(failed.ok?)\n"
     "  kept = out.recv(1000).unwrap!\n", "9.5\nfalse\n"),
])
def test_the_block_form_frees_its_buffer_when_the_block_ends(tmp_path, peer, schedulers, tail, out):
    main = """def first(buf: C.Pointer, out: Channel[C.Pointer]) -> Result[Int]
  try out.send(buf, 1000)
  n = try "x".to_i
  return ok(n)
end

def main() -> Void
  out: Channel[C.Pointer] = Channel.new(1)
  sum = Native.memory_pointer(16) do |buf|
    Native.put_array_of_float32(buf, 4, [2.0, 3.5, 4.0])
    peer_sum_floats(buf, 4)
  end
  puts(sum)
%s  puts(Native.get_int8(kept, 0))
end
""" % tail
    where = (BUFFER_EXTERN.count("\n") + main.count("\n") - 1, 24)
    assert stopped_buffer_program(tmp_path, peer, schedulers, main, out) == ("RUNTIME-NATIVE-CLOSED", where)


# Task.spawn_owning hands an owned buffer to the new task, which uses it and whose end frees it; a pointer that C gave
# is not the caller's to hand over.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
@pytest.mark.parametrize("handed, out, code", [
    ("buf", "3.5\n", "RUNTIME-NATIVE-CLOSED"),
    ("peer_static_floats()", "", "RUNTIME-HANDLE-NOT-OWNED"),
])
def test_task_spawn_owning_hands_an_owned_buffer_over(tmp_path, peer, schedulers, handed, out, code):
    main = """def sum(buf: C.Pointer) -> Float
  return peer_sum_floats(buf, 2)
end

def main() -> Void
  buf = Native.memory_pointer(8)
  Native.put_array_of_float32(buf, 0, [1.5, 2.0])
  puts(Task.await(Task.spawn_owning(&sum, %s)))
  puts(Native.get_int8(buf, 0))
end
""" % handed
    assert stopped_buffer_program(tmp_path, peer, schedulers, main, out)[0] == code


# A compute call holds its buffer arguments: a free while C still reads the memory only marks the buffer freed, and
# the memory goes when the call returns, so C sums what was written.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_compute_call_keeps_its_buffer_until_it_returns(tmp_path, peer, schedulers):
    main = """def sum_later(buf: C.Pointer) -> Result[Float]
  return ok(peer_floats_hold(buf, 64, 20_000))
end

def main() -> Void
  buf = Native.memory_pointer(256)
  for k in 0...64
    Native.put_float32(buf, k * 4, 1.0)
  end
  holder = Task.spawn(&sum_later, buf)
  n = 0
  while peer_res_holding() == 0 and n < 2000
    Task.sleep(1)
    n += 1
  end
  Native.free(buf)
  peer_set_flag()
  puts(Task.await(holder))
end
"""
    result = agentica("--schedulers", schedulers, program(tmp_path, BUFFER_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "ok(64.0)\n", "")


# The task that opened a resource owns it: its end frees what it did not close, and Task.spawn_owning hands it on.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_the_end_of_the_owning_task_frees_a_resource(tmp_path, peer, schedulers):
    main = """def main() -> Void
  sum = 0
  for n in 1..20
    sum += Task.await(Task.spawn(&open_one, n))
  end
  puts(sum)
  puts(peer_res_frees())
  res = peer_res_open(5).unwrap!
  puts(Task.await(Task.spawn_owning(&get, res)))
  puts(peer_res_frees())
end
"""
    result = agentica("--schedulers", schedulers, program(tmp_path, RESOURCE_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "210\n20\n5\n21\n", "")


# A compute call holds its resource until C returns: a close by another task, or a cancel that ends the owning task,
# marks it closed, and the free runs only when the call ends, never while the pool thread still uses the pointer.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
@pytest.mark.parametrize("spawn, stop, awaited", [
    ("Task.spawn_owning", "Task.cancel(holder)", 'error("task: cancelled")'),
    ("Task.spawn", "Native.close(res)", "ok(9)"),
])
def test_a_compute_call_keeps_its_resource_until_it_returns(tmp_path, peer, schedulers, spawn, stop, awaited):
    main = """def main() -> Void
  res = peer_res_open(9).unwrap!
  holder = %s(&hold, res)
  wait_holding()
  %s
  puts(peer_res_frees())
  peer_set_flag()
  puts(Task.await(holder))
  wait_for(1)
  puts(peer_res_frees())
  puts(peer_res_busy_frees())
end
""" % (spawn, stop)
    result = agentica("--schedulers", schedulers, program(tmp_path, RESOURCE_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == ["0", awaited, "1", "0", ""]


# The resource that a cancelled compute call returns is dropped with its result, and so freed: nothing leaks.
@NATIVE_CALLS
def test_a_dropped_compute_result_frees_its_resource(tmp_path, peer):
    main = """def later(n: Int) -> Result[Int]
  res = try peer_res_open_later(n, 20_000)
  return ok(peer_res_get(res))
end

def main() -> Void
  opener = Task.spawn(&later, 3)
  Task.sleep(20)
  Task.cancel(opener)
  puts(Task.await(opener))
  peer_set_flag()
  wait_for(1)
  puts(peer_res_frees())
end
"""
    result = agentica("--schedulers", "2", program(tmp_path, RESOURCE_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, 'error("task: cancelled")\n1\n', "")


# Calls queued behind busy pool threads (one per scheduler) and cancelled there are never made, so their `done` builds
# no result: no resource is made from a pointer C never returned (its free would get garbage, which ASan catches) and
# no C.String is read. Every resource opened is freed once, and none while C uses it.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_cancelled_compute_call_that_never_ran_gives_no_result(tmp_path, peer, schedulers):
    main = """extern "{library}"
  compute def peer_word(n: C.Int32) -> C.String
  def peer_res_opens() -> C.Int32
end

def later(n: Int) -> Result[Int]
  res = try peer_res_open_later(n, 0)
  return ok(peer_res_get(res))
end

def word(n: Int) -> Result[String]
  return ok(peer_word(n))
end

def main() -> Void
  res = peer_res_open(1).unwrap!
  holders: List[Task[Result[Int]]] = []
  for k in 1..SCHEDULERS
    holders = holders.push(Task.spawn(&hold, res))
  end
  n = 0
  while peer_res_holding() < SCHEDULERS and n < 2000
    Task.sleep(1)
    n += 1
  end
  openers: List[Task[Result[Int]]] = []
  words: List[Task[Result[String]]] = []
  for k in 1..20
    openers = openers.push(Task.spawn(&later, k))
    words = words.push(Task.spawn(&word, k))
  end
  Task.sleep(50)
  for task in openers
    Task.cancel(task)
  end
  for task in words
    Task.cancel(task)
  end
  peer_set_flag()
  for task in holders
    Task.await(task)
  end
  Native.close(res)
  Task.sleep(50)
  puts(peer_res_opens() - peer_res_frees())
  puts(peer_res_busy_frees())
end
""".replace("SCHEDULERS", schedulers).replace("{library}", literal(peer))
    result = agentica("--schedulers", schedulers, program(tmp_path, RESOURCE_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "0\n0\n", "")


OUT_EXTERN = """extern "{library}"
  resource Res, free: peer_res_free
  def peer_out_all(
    n: C.Int32, out i: C.Int32, out l: C.Int64, out d: C.Double, out b: C.Bool, out p: C.Pointer, out res: Res,
  ) -> C.Int32
  def peer_out_null(out res: Res) -> C.Int32
  def peer_out_untouched(out res: Res) -> C.Int32
  def peer_out_twice(n: C.Int32, out twice: C.Int32) -> Void
  compute def peer_out_open_later(value: C.Int32, limit_ms: C.Int32, out res: Res) -> C.Int32
  def peer_res_get(res: Res) -> C.Int32
  def peer_res_frees() -> C.Int32
  def peer_ptr_read(p: C.Pointer) -> C.Int32
  def peer_set_flag() -> Void
end

def wait_for(frees: Int) -> Void
  n = 0
  while peer_res_frees() < frees and n < 2000
    Task.sleep(1)
    n += 1
  end
end

"""


# The out values come back as the fields of the call's record, after the C result. A NULL out resource, written by C
# or left in the zeroed slot, is a closed resource: a close does nothing, nothing frees it (the peer would crash on a
# NULL free), and a call with it is RUNTIME-NATIVE-CLOSED.
@NATIVE_CALLS
def test_out_parameters_are_the_fields_of_the_result(tmp_path, peer):
    main = """def main() -> Void
  all = peer_out_all(5)
  puts([all.result, all.i, all.l, peer_ptr_read(all.p), peer_res_get(all.res)])
  puts(all.d)
  puts(all.b)
  Native.close(all.res)
  missing = peer_out_null()
  puts(missing.result)
  Native.close(missing.res)
  Native.close(peer_out_untouched().res)
  puts(peer_out_twice(21).twice)
  puts(peer_res_frees())
  puts(peer_res_get(missing.res))
end
"""
    result = agentica("--json", program(tmp_path, OUT_EXTERN.format(library=literal(peer)) + main))
    assert diagnostic(result, 1) == ("RUNTIME-NATIVE-CLOSED", (10, 3))
    assert result.stdout.split("\n") == ["[10, 6, 15000000000, 42, 5]", "1.25", "true", "-1", "42", "1", ""]


# The record of an exported extern function is exported with it: another file names its type and reads its fields.
@NATIVE_CALLS
def test_the_record_of_an_out_call_crosses_an_import(tmp_path, peer):
    program(tmp_path, 'extern "%s"\n  export def peer_out_twice(n: C.Int32, out twice: C.Int32) -> Void\nend\n'
            % literal(peer), "raw.agc")
    main = program(tmp_path, 'import Raw from "./raw"\n\ndef twice(made: Raw.PeerOutTwice) -> Int\n'
                   '  return made.twice\nend\n\ndef main() -> Void\n  puts(twice(Raw.peer_out_twice(4)))\nend\n')
    result = agentica(main)
    assert (result.code, result.stdout, result.stderr) == (0, "8\n", "")


VARIADIC_EXTERN = """extern "{library}"
  def vmix_ints(kinds: C.String, ..., a: C.Int32, b: C.Int64, c: C.Int32) -> C.Double = "peer_vmix"
  def vmix_doubles(kinds: C.String, ..., a: C.Double, b: C.Double) -> C.Double = "peer_vmix"
  def vmix_none(kinds: C.String, ...) -> C.Double = "peer_vmix"
  def vmix_wide(
    kinds: C.String, ..., a: C.Int32, b: C.Double, c: C.Int64, d: C.String, e: C.Bytes, f: C.Pointer, g: C.Double,
    h: C.Double, i: C.Double, j: C.Double, k: C.Double, l: C.Double, m: C.Double, n: C.Double, o: C.Double,
    p: C.Int64, q: C.Int32,
  ) -> C.Double = "peer_vmix"
  compute def vmix_pool(kinds: C.String, ..., a: C.Double, b: C.Int32) -> C.Double = "peer_vmix"
  def vmix_out(out count: C.Int32, kinds: C.String, ..., a: C.Double, b: C.Int32) -> C.Double = "peer_vmix_out"
end

"""


# One variadic C function declared in five shapes with `= "peer_vmix"`: ints, doubles, none, a mix with more
# arguments than registers (so some go on the stack on every ABI), and a compute def; and a sixth with an out
# parameter before `...`, which counts in the fixed part. Only Apple arm64, where every variadic argument goes on the
# stack, tells a variadic call from a fixed one: on x86-64 and Windows x64 libffi makes the two calls the same, so CI
# on those systems does not test the fixed count.
@NATIVE_CALLS
def test_a_variadic_function_gets_the_arguments_of_its_declared_shape(tmp_path, peer):
    main = """def main() -> Void
  puts(vmix_ints("ili", 40, 9_000_000_000, -2))
  puts(vmix_doubles("dd", 0.25, 1.5))
  puts(vmix_none(""))
  puts(
    vmix_wide(
      "idlsypdddddddddli", 1, 0.5, 2, "four", [200, 0], Native.pointer(64), 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
      1.0, 3_000_000_000, -7,
    ),
  )
  puts(vmix_pool("di", 0.5, 8))
  counted = vmix_out("di", 0.5, 8)
  puts(counted.result)
  puts(counted.count)
end
"""
    result = agentica(program(tmp_path, VARIADIC_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    wide = 1 + 0.5 + 2 + 4 + 200 + 64 + 9 * 1.0 + 3_000_000_000 - 7
    assert result.stdout.split("\n") == ["9000000038.0", "1.75", "0.0", repr(float(wide)), "8.5", "8.5", "2", ""]


# The C library's own variadic functions: open with O_CREAT and a mode (the mode is the variadic argument), and
# snprintf with an int, a double, a string and C.Bytes after the format. The buffer is malloc'd, as C.Bytes is a copy
# that C cannot write back. Windows has these as _open in the UCRT and _snprintf in msvcrt.dll (the UCRT's snprintf is
# a header inline, not an export), and a mode of _S_IREAD alone makes the file read-only there. The flag values are
# the target's, not this Python's, which may be Linux under Wine.
@NATIVE_CALLS
def test_libc_variadic_functions_open_a_file_with_a_mode_and_format_text(tmp_path):
    made = tmp_path / "made.txt"
    umask = os.umask(0o22)
    os.umask(umask)
    if WINDOWS:
        library, opened, closed, printed, flags, mode = LIBC, "_open", "_close", "_snprintf", 0x0100 | 0x0001, 0x0100
        text = 'extern "msvcrt.dll"\n  def snprintf(buffer: C.Pointer, size: C.Int64, format: C.String, ..., ' \
               'a: C.Int32, b: C.Double, c: C.String, d: C.Bytes) -> C.Int32 = "%s"\nend\n\n' % printed
    else:
        library, opened, closed, flags, mode = LIBC, "open", "close", (0x200 if MACOS else 0o100) | 0o1, 0o640
        text = 'extern "%s"\n  def snprintf(buffer: C.Pointer, size: C.Int64, format: C.String, ..., ' \
               'a: C.Int32, b: C.Double, c: C.String, d: C.Bytes) -> C.Int32\nend\n\n' % library
    text += """extern "%s"
  def open_file(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32 = "%s"
  def close_file(fd: C.Int32) -> C.Int32 = "%s"
  def malloc(size: C.Int64) -> C.Pointer
  def free(block: C.Pointer) -> Void
end

def main() -> Void
  fd = open_file("%s", %d, %d)
  puts(fd >= 0)
  puts(close_file(fd))
  buffer = malloc(64)
  puts(snprintf(buffer, 64, "%%d %%.2f %%s %%s", 42, 2.5, "hi", [121, 111, 0]))
  puts(Native.string_at(buffer))
  free(buffer)
end
""" % (library, opened, closed, literal(made), flags, mode)
    try:
        result = agentica(program(tmp_path, text))
        assert (result.code, result.stderr) == (0, "")
        assert result.stdout.split("\n") == ["true", "0", "13", "42 2.50 hi yo", ""]
        if WINDOWS:
            assert made.stat().st_mode & 0o200 == 0
        else:
            assert made.stat().st_mode & 0o777 == 0o640 & ~umask
    finally:
        if made.exists():
            made.chmod(0o600)


# fcntl in two shapes of one C function (= "fcntl"): F_GETFD and F_GETFL take no variadic argument, F_SETFD takes an
# int. The constants are the same on Linux and macOS. On Linux x86_64 syscall(SYS_getpid = 39) gives the process id.
@NATIVE_CALLS
@host_only(WINDOWS, "Windows has no fcntl or syscall")
def test_fcntl_in_two_shapes_and_syscall(tmp_path):
    made = tmp_path / "flags.txt"
    flags = (0x200 if MACOS else 0o100) | 0o1
    main = """extern "%s"
  def open_file(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32 = "open"
  def close(fd: C.Int32) -> C.Int32
  def fcntl_get(fd: C.Int32, cmd: C.Int32, ...) -> C.Int32 = "fcntl"
  def fcntl_set(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  def syscall(number: C.Int64, ...) -> C.Int64
end

def main() -> Void
  fd = open_file("%s", %d, 384)
  puts(fcntl_get(fd, 1))
  puts(fcntl_set(fd, 2, 1))
  puts(fcntl_get(fd, 1))
  puts(fcntl_get(fd, 3) %% 4)
  puts(close(fd))
  if System.os == "linux"
    puts(syscall(39) == System.pid)
  else
    puts(true)
  end
end
""" % (LIBC, literal(made), flags)
    result = agentica(program(tmp_path, main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == ["0", "0", "1", "1", "0", "true", ""]


# A compute call fills its out slots on the pool thread. Its task gets a resource that it owns (its end frees it); a
# cancel while C runs drops the result, and the out resource is freed once, when the call returns.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_compute_call_gives_its_out_resource_or_frees_it_when_cancelled(tmp_path, peer, schedulers):
    main = """def later(n: Int) -> Result[Int]
  opened = peer_out_open_later(n, 20_000)
  return ok(peer_res_get(opened.res))
end

def main() -> Void
  opener = Task.spawn(&later, 3)
  Task.sleep(20)
  Task.cancel(opener)
  puts(Task.await(opener))
  peer_set_flag()
  wait_for(1)
  puts(peer_res_frees())
  puts(Task.await(Task.spawn(&later, 4)))
  wait_for(2)
  puts(peer_res_frees())
end
"""
    result = agentica("--schedulers", schedulers, program(tmp_path, OUT_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, 'error("task: cancelled")\n1\nok(4)\n2\n', "")


WAIT_EXTERN = """extern "{library}"
  def peer_pipe() -> C.Int32
  def peer_pipe_writer() -> C.Int32
  def peer_pipe_put() -> C.Int32
  def peer_pipe_take() -> C.Int32
  def peer_pipe_fill() -> Void
  def peer_pipe_blocking() -> Void
  def peer_nonblocking(fd: C.Int32) -> C.Int32
  def peer_regular_file() -> C.Int32
  def peer_open_fds() -> C.Int32
end

def wait(fd: Int) -> Result[Void]
  return Native.wait_readable(fd, 20_000)
end

"""


def run_wait(tmp_path, peer, main, *args, **kwargs):
    """Runs MAIN after WAIT_EXTERN; ARGS go before the program on the command line."""
    return agentica(*args, program(tmp_path, WAIT_EXTERN.format(library=literal(peer)) + main), **kwargs)


# Two tasks wait on the pipe's read end at once. On one scheduler, main's write proves that the waiting tasks gave the
# scheduler up; the write end is writable at once.
@NATIVE_CALLS
@host_only(WINDOWS, "one Windows socket takes one wait at a time (test_a_second_wait_on_one_descriptor)")
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_wait_parks_the_task_until_the_descriptor_is_ready(tmp_path, peer, schedulers):
    main = """def main() -> Void
  fd = peer_pipe()
  first = Task.spawn(&wait, fd)
  second = Task.spawn(&wait, fd)
  Task.sleep(20)
  puts("main runs")
  puts(peer_pipe_put())
  puts(Task.await(first))
  puts(Task.await(second))
  puts(peer_pipe_take())
  puts(Native.wait_writable(peer_pipe_writer(), 1_000))
end
"""
    result = run_wait(tmp_path, peer, main, "--schedulers", schedulers)
    assert (result.code, result.stdout, result.stderr) == (0, "main runs\n1\nok()\nok()\n1\nok()\n", "")


# On Windows one socket takes one wait at a time: two polls of one socket would cancel each other in a busy loop in
# libuv. While a task waits (its duplicate is open; on one scheduler main runs, so the task parked), a second wait is an
# error at once; once the wait has ended ready, and again after a timeout, the socket can be waited on again. Elsewhere
# the second wait waits too and times out, so the case runs on every system.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_second_wait_on_one_descriptor(tmp_path, peer, schedulers):
    main = """def main() -> Void
  fd = peer_pipe()
  base = peer_open_fds()
  first = Task.spawn(&wait, fd)
  n = 0
  while peer_open_fds() == base and n < 5000
    Task.sleep(1)
    n += 1
  end
  puts(Native.wait_readable(fd, 30))
  puts(peer_pipe_put())
  puts(Task.await(first))
  puts(peer_pipe_take())
  puts(Native.wait_readable(fd, 30))
  puts(peer_pipe_put())
  puts(Native.wait_readable(fd, 1_000))
  puts(peer_pipe_take())
end
"""
    result = run_wait(tmp_path, peer, main, "--schedulers", schedulers)
    assert (result.code, result.stderr) == (0, "")
    lines = result.stdout.split("\n")
    second = 'error("native: cannot wait on the descriptor' if WINDOWS else 'error("native: timed out")'
    assert lines[0].startswith(second), result.stdout
    assert lines[1:] == ["1", "ok()", "1", 'error("native: timed out")', "1", "ok()", "1", ""], result.stdout


# The wait polls a new open of the pipe, so the native code's descriptors keep their flags: a blocking descriptor (a
# terminal, say) stays blocking after the wait, whether it ended ready or at its timeout.
@NATIVE_CALLS
@host_only(WINDOWS, "a pipe opened again keeps its own flags; Windows waits only on sockets, whose duplicate shares the "
                    "non-blocking mode, and Winsock cannot read that mode back")
def test_a_wait_leaves_the_flags_of_the_descriptor_alone(tmp_path, peer):
    main = """def main() -> Void
  fd = peer_pipe()
  peer_pipe_blocking()
  puts(Native.wait_readable(fd, 30))
  puts(Native.wait_writable(peer_pipe_writer(), 1_000))
  puts(peer_nonblocking(fd))
  puts(peer_nonblocking(peer_pipe_writer()))
end
"""
    result = run_wait(tmp_path, peer, main)
    assert (result.code, result.stdout, result.stderr) == (0, 'error("native: timed out")\nok()\n0\n0\n', "")


@NATIVE_CALLS
def test_a_wait_times_out_and_refuses_what_it_cannot_poll(tmp_path, peer):
    main = """def first_line(result: Result[Void]) -> String
  return result.message.split("\\n")[0]
end

def main() -> Void
  fd = peer_pipe()
  puts(Native.wait_readable(fd, 30))
  peer_pipe_fill()
  puts(Native.wait_writable(peer_pipe_writer(), 30))
  puts(Native.wait_readable(fd, 0))
  puts(Native.wait_readable(-1, 30))
  puts(first_line(Native.wait_readable(1_000_000, 30)))
  puts(first_line(Native.wait_writable(peer_regular_file(), 30)))
end
"""
    result = run_wait(tmp_path, peer, main)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        'error("native: timed out")', 'error("native: timed out")',
        'error("native: timeout must be positive milliseconds")', 'error("native: invalid descriptor")',
        "native: cannot wait on the descriptor", "native: cannot wait on the descriptor", "",
    ]


# With no data, a named FIFO and a terminal master wait until the timeout, and they are ready once data comes. On macOS
# the wait polls a FIFO with poll(2) and does not take the end-of-file probe of a file stream for readiness; a terminal
# master is polled through a duplicate, since opening its path again (/dev/ptmx) makes a new terminal, and it stays
# blocking after the wait.
@NATIVE_CALLS
@host_only(WINDOWS, "Windows waits only on sockets")
def test_a_wait_on_a_named_fifo_or_a_terminal_master_waits_for_data(tmp_path, peer):
    main = """extern "{library}"
  def peer_fifo(path: C.String) -> C.Int32
  def peer_fifo_put() -> C.Int32
  def peer_pty() -> C.Int32
  def peer_pty_put() -> C.Int32
end

def main() -> Void
  fifo = peer_fifo(System.args()[0])
  puts(Native.wait_readable(fifo, 30))
  puts(peer_fifo_put())
  puts(Native.wait_readable(fifo, 1_000))
  master = peer_pty()
  puts(Native.wait_readable(master, 30))
  puts(peer_nonblocking(master))
  puts(peer_pty_put())
  puts(Native.wait_readable(master, 1_000))
end
"""
    text = WAIT_EXTERN.format(library=literal(peer)) + main.replace("{library}", literal(peer))
    result = agentica(program(tmp_path, text), tmp_path / "fifo")
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        'error("native: timed out")', "1", "ok()", 'error("native: timed out")', "0", "1", "ok()", "",
    ]


# The wait polls a duplicate of the descriptor: a cancel closes the duplicate once (the count of open descriptors goes
# back), and the peer's own descriptor still works.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_cancel_stops_a_wait_and_closes_its_duplicate(tmp_path, peer, schedulers):
    main = """def main() -> Void
  fd = peer_pipe()
  base = peer_open_fds()
  waiter = Task.spawn(&wait, fd)
  n = 0
  while peer_open_fds() == base and n < 2000
    Task.sleep(1)
    n += 1
  end
  Task.sleep(20)
  puts(peer_open_fds() - base)
  Task.cancel(waiter)
  puts(Task.await(waiter))
  n = 0
  while peer_open_fds() != base and n < 2000
    Task.sleep(1)
    n += 1
  end
  puts(peer_open_fds() - base)
  peer_pipe_put()
  puts(Native.wait_readable(fd, 1_000))
  puts(peer_pipe_take())
end
"""
    result = run_wait(tmp_path, peer, main, "--schedulers", schedulers)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == ["1", 'error("task: cancelled")', "0", "ok()", "1", ""]


@NATIVE_CALLS
def test_the_run_ends_while_a_task_waits(tmp_path, peer):
    main = """def main() -> Void
  waiter = Task.spawn(&wait, peer_pipe())
  Task.sleep(20)
  puts("done")
end
"""
    result = run_wait(tmp_path, peer, main, timeout=10)
    assert (result.code, result.stdout, result.stderr) == (0, "done\n", "")


# On Windows a wait takes only a socket: a C runtime descriptor (stdin, 0) and a file handle are errors at once.
# Elsewhere stdin (a pipe) can be polled and a regular file cannot, so the run only has to end.
@NATIVE_CALLS
def test_a_wait_on_windows_refuses_a_value_that_is_not_a_socket(tmp_path, peer):
    main = """def main() -> Void
  puts(Native.wait_readable(0, 10))
  puts(Native.wait_writable(peer_regular_file(), 10))
end
"""
    result = run_wait(tmp_path, peer, main)
    assert (result.code, result.stderr) == (0, "")
    if WINDOWS:
        lines = result.stdout.split("\n")
        assert len(lines) == 3 and lines[2] == "", result.stdout
        assert all(line.startswith('error("native: cannot wait on the descriptor') for line in lines[:2]), result.stdout


WAIT_ONLY = """def main() -> Void
  puts("started")
  puts(Native.wait_writable(1, 1_000))
end
"""


# A wait needs a descriptor of native code and changes it (non-blocking mode), so --deny-native refuses a program
# that waits, with no extern block, at load; other systems refuse it at load too.
@pytest.mark.parametrize("flag", ["--deny-native", "--sandbox"])
def test_a_program_that_waits_is_native_code(tmp_path, flag):
    result = agentica("--json", flag, program(tmp_path, WAIT_ONLY))
    assert result.stdout == ""
    assert diagnostic(result, 2) == ("RUNTIME-NATIVE-DENIED" if NATIVE else "RUNTIME-NATIVE-UNSUPPORTED", (1, 1))


@NATIVE_CALLS
@pytest.mark.parametrize("case, code, line", [
    ("lib", "RUNTIME-NATIVE-LOAD", 2),
    ("sym", "RUNTIME-NATIVE-LOAD", 6),
    ("int", "RUNTIME-INTEGER-OVERFLOW", 7),
    ("nul", "RUNTIME-INVALID-CHARACTER", 8),
])
def test_what_c_cannot_take_stops_the_run_at_the_extern_function(tmp_path, case, code, line):
    text = """extern "libnot_there_at_all.so"
  def gone() -> Void
end

extern "LIBC"
  def no_such_function_here() -> C.Int32
  def abs(n: C.Int32) -> C.Int32
  def strlen(s: C.String) -> C.Int64
end

def main() -> Void
  arg = System.args()[0]
  if arg == "lib"
    gone()
  elsif arg == "sym"
    puts(no_such_function_here())
  elsif arg == "int"
    puts(abs(2_147_483_648))
  else
    puts(strlen("a" + String.from_code(0)))
  end
end
"""
    text = text.replace("LIBC", LIBC)
    assert diagnostic(agentica("--json", program(tmp_path, text), case), 1) == (code, (line, 3))


# On Windows a DLL cannot be linked with an undefined symbol, so unbound.dll imports it from nowhere.dll. With the
# symbol the call runs, which proves that the folder of an absolute path is searched for its DLLs; nowhere.dll is then
# built again without it, and the missing function stops the load.
@NATIVE_CALLS
def test_a_library_with_an_unbound_symbol_is_a_load_error_and_keeps_earlier_output(tmp_path, tmp_path_factory):
    text = 'extern "%s"\n  def unbound_call() -> C.Int32\nend\n\n' \
           'def main() -> Void\n  puts("before")\n  puts(unbound_call())\nend\n'
    if WINDOWS:
        folder = tmp_path_factory.mktemp("native")
        nowhere = shared_library(tmp_path_factory, "nowhere", "-DAGENTICA_TEST_DEFINE_NOWHERE", folder=folder)
        library = shared_library(tmp_path_factory, "unbound", str(nowhere), folder=folder)
        result = agentica(program(tmp_path, text % literal(library)))
        assert (result.code, result.stdout, result.stderr) == (0, "before\n1\n", "")
        shared_library(tmp_path_factory, "nowhere", folder=folder)
    else:
        # A macOS dylib must name the library of each symbol unless the symbol is looked up at load.
        library = shared_library(tmp_path_factory, "unbound", *(["-Wl,-undefined,dynamic_lookup"] if MACOS else []))
    result = agentica("--json", program(tmp_path, text % literal(library)))
    assert result.stdout == "before\n"
    assert diagnostic(result, 1) == ("RUNTIME-NATIVE-LOAD", (2, 3))


EXTERN_FIRST = """def main() -> Void
  puts("started")
  puts(abs(-1))
end

extern "%s"
  def abs(n: C.Int32) -> C.Int32
end
""" % LIBC


# Every --deny-* flag and --sandbox.
DENY_FLAGS = ["--deny-native", "--deny-run", "--deny-net", "--deny-fs", "--deny-env", "--sandbox"]


# Native code could do what any other flag turns off, so every --deny-* flag turns on --deny-native.
@NATIVE_CALLS
@pytest.mark.parametrize("flag", DENY_FLAGS)
def test_deny_native_refuses_the_program_at_load(tmp_path, flag):
    source = program(tmp_path, EXTERN_FIRST)
    assert diagnostic(agentica("--json", flag, source), 2) == ("RUNTIME-NATIVE-DENIED", (7, 3))
    bytecode = tmp_path / "program.agcb"
    assert agentica("compile", source, "-o", bytecode).code == 0
    result = agentica("run", "--json", flag, "--", bytecode)
    assert result.stdout == ""
    assert diagnostic(result, 2) == ("RUNTIME-NATIVE-DENIED", (7, 3))
    result = agentica("run", "--", bytecode)
    assert (result.code, result.stdout) == (0, "started\n1\n")


def test_deny_native_lets_a_program_without_extern_functions_run(tmp_path):
    result = agentica("--deny-native", program(tmp_path, 'def main() -> Void\n  puts("ok")\nend\n'))
    assert (result.code, result.stdout, result.stderr) == (0, "ok\n", "")


def test_other_systems_refuse_extern_at_load(tmp_path):
    result = agentica("--json", program(tmp_path, EXTERN_FIRST))
    if NATIVE:
        assert (result.code, result.stdout) == (0, "started\n1\n")
    else:
        assert result.stdout == ""
        assert diagnostic(result, 2) == ("RUNTIME-NATIVE-UNSUPPORTED", (7, 3))


EXTERN_TEST = """extern "%s"
  def abs(n: C.Int32) -> C.Int32
end

def main() -> Void
  Test.run([Test.test("abs") do Test.eq(abs(-1), 1) end])
end
""" % LIBC


# `agentica test` gives the flags to the VMs of the test files, not to the runner: in front of `test` or after it, a
# test file that declares extern functions is a file error, and the other files still run, under --sandbox too.
@NATIVE_CALLS
@pytest.mark.parametrize("flag", DENY_FLAGS)
def test_test_refuses_a_test_file_with_extern_functions(tmp_path, flag):
    (tmp_path / "test").mkdir()
    program(tmp_path / "test", EXTERN_TEST, "native_test.agc")
    program(tmp_path / "test", 'def main() -> Void\n  Test.run([Test.test("adds") do Test.eq(1 + 1, 2) end])\nend\n',
            "plain_test.agc")
    for words in ([flag, "test", "--json"], ["test", "--json", flag]):
        result = agentica(*words, cwd=tmp_path)
        assert (result.code, result.stderr) == (1, ""), words
        report = json.loads(result.stdout)
        errors = {file["path"].rsplit("/", 1)[-1]: file["error"] and file["error"]["code"] for file in report["files"]}
        assert errors == {"native_test.agc": "RUNTIME-NATIVE-DENIED", "plain_test.agc": None}, words
        assert (report["passed"], report["failed"]) == (1, 0), words
    assert agentica("test", cwd=tmp_path).code == 0


# A real library, not the peer: the system SQLite. sqlite3_malloc and sqlite3_free are a resource, and sqlite3_msize
# reads the block; the full case opens a database and queries it through out parameters. Windows 10 and later ship
# winsqlite3.dll in System32 with the same sqlite3_* C API (a bare name, which the VM loads from the system folders).
# macOS has /usr/lib/libsqlite3.dylib (in the dyld shared cache).
SQLITE_LIBRARY = "winsqlite3.dll" if WINDOWS else "libsqlite3.dylib" if MACOS else "libsqlite3.so.0"

SQLITE_EXTERN = """extern "%s"
  resource Block, free: sqlite3_free
  def sqlite3_libversion_number() -> C.Int32
  def sqlite3_libversion() -> C.String
  def sqlite3_complete(sql: C.String) -> C.Int32
  def sqlite3_malloc(size: C.Int32) -> Block
  def sqlite3_msize(block: Block) -> C.Int64
end

""" % SQLITE_LIBRARY


@pytest.fixture(scope="module")
def sqlite():
    """Skip (a failure in CI) when the system SQLite library is not installed."""
    hint = ""
    if TARGET_OS.startswith("linux"):
        hint = " (Debian: apt install libsqlite3-0)"
    try:
        ctypes.CDLL(SQLITE_LIBRARY)
    except OSError:
        require(False, SQLITE_LIBRARY + " is required" + hint)


@NATIVE_CALLS
def test_the_system_sqlite_answers_its_version_and_whether_a_statement_is_complete(tmp_path, sqlite):
    main = """def main() -> Void
  puts(sqlite3_libversion_number() >= 3_000_000)
  puts(sqlite3_libversion().start_with?("3."))
  puts(sqlite3_complete("select 1;"))
  puts(sqlite3_complete("select"))
end
"""
    result = agentica(program(tmp_path, SQLITE_EXTERN + main))
    assert (result.code, result.stdout, result.stderr) == (0, "true\ntrue\n1\n0\n", "")


@NATIVE_CALLS
def test_a_block_of_sqlite_malloc_is_a_resource_that_close_frees(tmp_path, sqlite):
    main = """def main() -> Void
  block = sqlite3_malloc(64).unwrap!
  puts(sqlite3_msize(block) >= 64)
  Native.close(block)
  Native.close(block)
  puts(sqlite3_msize(block))
end
"""
    result = agentica("--json", program(tmp_path, SQLITE_EXTERN + main))
    assert diagnostic(result, 1)[0] == "RUNTIME-NATIVE-CLOSED"
    assert result.stdout == "true\n"


SQLITE_OUT_EXTERN = """extern "%s"
  resource Db, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  def sqlite3_errcode(db: Db) -> C.Int32
  def sqlite3_errmsg(db: Db) -> C.String
  def sqlite3_prepare_v2(db: Db, sql: C.String, bytes: C.Int32, out stmt: Stmt, out tail: C.Pointer) -> C.Int32
  compute def sqlite3_step(stmt: Stmt) -> C.Int32
  def sqlite3_column_int(stmt: Stmt, col: C.Int32) -> C.Int32
  def sqlite3_column_text(stmt: Stmt, col: C.Int32) -> C.String
end

""" % SQLITE_LIBRARY


# sqlite3_open gives an out Db and sqlite3_prepare_v2 an out Stmt (and the tail as a C.Pointer). A table gets two
# rows that a select reads back; bad SQL gives SQLITE_ERROR, its message, and a NULL Stmt, a closed resource. An open
# that fails (SQLITE_CANTOPEN, 14) still gives a live handle, which the wrapper reads and closes.
@NATIVE_CALLS
def test_the_system_sqlite_opens_a_database_and_queries_it_through_out_parameters(tmp_path, sqlite):
    main = """def open(path: String) -> Result[Db]
  opened = sqlite3_open(path)
  if opened.result != SQLITE_OK
    puts(sqlite3_errcode(opened.db))
    Native.close(opened.db)
    return error("sqlite open: #{opened.result}")
  end
  return ok(opened.db)
end

def run(db: Db, sql: String) -> Int
  prepared = sqlite3_prepare_v2(db, sql, -1)
  if prepared.result != SQLITE_OK
    return prepared.result
  end
  code = sqlite3_step(prepared.stmt)
  Native.close(prepared.stmt)
  return code
end

def main() -> Void
  db = open(":memory:").unwrap!
  puts(run(db, "create table t (id integer, name text)"))
  puts(run(db, "insert into t values (1, 'one')"))
  puts(run(db, "insert into t values (2, 'two')"))
  query = sqlite3_prepare_v2(db, "select id, name from t order by id", -1)
  puts(query.result)
  while sqlite3_step(query.stmt) == SQLITE_ROW
    puts("#{sqlite3_column_int(query.stmt, 0)} #{sqlite3_column_text(query.stmt, 1)}")
  end
  Native.close(query.stmt)
  bad = sqlite3_prepare_v2(db, "select from nowhere", -1)
  puts([bad.result, sqlite3_errcode(db)])
  puts(sqlite3_errmsg(db).end_with?("syntax error"))
  Native.close(bad.stmt)
  Native.close(db)
  IO.inspect(open("/no/such/dir/x.db"))
end
"""
    result = agentica(program(tmp_path, "SQLITE_OK = 0\nSQLITE_ROW = 100\n\n" + SQLITE_OUT_EXTERN + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "101", "101", "101", "0", "1 one", "2 two", "[1, 1]", "true", "14", 'error("sqlite open: 14")', "",
    ]


# The memory that SQLite returns (#592): the extern block above with sqlite3_column_text as a C.Pointer, which is NULL
# for SQL NULL, and the functions that take or give memory.
SQLITE_MEMORY_EXTERN = SQLITE_OUT_EXTERN.replace("  def sqlite3_column_text(stmt: Stmt, col: C.Int32) -> C.String\n", """\
  def sqlite3_column_text(stmt: Stmt, col: C.Int32) -> C.Pointer
  def sqlite3_column_blob(stmt: Stmt, col: C.Int32) -> C.Pointer
  def sqlite3_column_bytes(stmt: Stmt, col: C.Int32) -> C.Int32
  def sqlite3_bind_text(stmt: Stmt, index: C.Int32, text: C.String, bytes: C.Int32, destructor: C.Pointer) -> C.Int32
  def sqlite3_bind_blob(stmt: Stmt, index: C.Int32, blob: C.Bytes, bytes: C.Int32, destructor: C.Pointer) -> C.Int32
  def sqlite3_exec(db: Db, sql: C.String, callback: C.Pointer, arg: C.Pointer, out errmsg: C.Pointer) -> C.Int32
  def sqlite3_free(p: C.Pointer) -> Void
""")


# A blob and a text bound with SQLITE_TRANSIENT (SQLite copies them: the C.String and C.Bytes copies live only during
# the call) come back through sqlite3_column_blob and sqlite3_column_text with their lengths; a row of SQL NULLs gives
# NULL pointers, and an empty blob a NULL pointer with length 0, which reads as []. sqlite3_exec writes its error
# message to an out pointer, which string_at reads and sqlite3_free
# frees; a statement that works leaves it NULL.
@NATIVE_CALLS
def test_the_system_sqlite_gives_blobs_null_text_and_error_messages_as_memory(tmp_path, sqlite):
    main = """def main() -> Void
  transient = Native.pointer(-1)
  db = sqlite3_open(":memory:").db
  puts(sqlite3_exec(db, "create table t (id integer, b blob, s text)", Native.null(), Native.null()).result)
  insert = sqlite3_prepare_v2(db, "insert into t values (1, ?, ?)", -1).stmt
  blob = [0, 1, 127, 128, 255]
  puts([sqlite3_bind_blob(insert, 1, blob, blob.size, transient), sqlite3_bind_text(insert, 2, "héllo", -1, transient)])
  puts(sqlite3_step(insert))
  Native.close(insert)
  puts(sqlite3_exec(db, "insert into t values (2, null, null)", Native.null(), Native.null()).result)
  query = sqlite3_prepare_v2(db, "select b, s from t order by id", -1).stmt
  puts(sqlite3_step(query))
  puts(Native.bytes_at(sqlite3_column_blob(query, 0), sqlite3_column_bytes(query, 0)))
  puts(Native.string_at(sqlite3_column_text(query, 1), sqlite3_column_bytes(query, 1)))
  puts(Native.string_at(sqlite3_column_text(query, 1)))
  puts(sqlite3_step(query))
  puts([Native.null?(sqlite3_column_blob(query, 0)), Native.null?(sqlite3_column_text(query, 1))])
  Native.close(query)
  empty = sqlite3_prepare_v2(db, "select x''", -1).stmt
  puts(sqlite3_step(empty))
  blob_at = sqlite3_column_blob(empty, 0)
  puts(Native.null?(blob_at))
  puts(Native.bytes_at(blob_at, sqlite3_column_bytes(empty, 0)))
  Native.close(empty)
  failed = sqlite3_exec(db, "select from nowhere", Native.null(), Native.null())
  puts(failed.result)
  puts(Native.string_at(failed.errmsg).end_with?("syntax error"))
  sqlite3_free(failed.errmsg)
  puts(Native.null?(sqlite3_exec(db, "select 1", Native.null(), Native.null()).errmsg))
  Native.close(db)
end
"""
    result = agentica(program(tmp_path, SQLITE_MEMORY_EXTERN + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "0", "[0, 0]", "101", "0", "100", "[0, 1, 127, 128, 255]", "héllo", "héllo", "100", "[true, true]", "100",
        "true", "[]", "1", "true", "true", "",
    ]
