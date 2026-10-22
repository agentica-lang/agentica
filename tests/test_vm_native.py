"""Native calls (the extern blocks of docs/grammar/05-syntax.md and 06d-io-and-network.md) through the product CLI.

The peer is tests/fixtures/native/peer.c, built with the system C compiler into a shared library (a DLL on Windows, a
dylib on macOS) for each module run, so every C type crosses a real ABI; three cases also call the system SQLite
(libsqlite3.so.0 on Linux, which CI installs, and libsqlite3.dylib on macOS). Native calls exist on Linux x86_64,
Windows x64 and macOS: elsewhere a program that declares extern functions is refused at load with
RUNTIME-NATIVE-UNSUPPORTED, which test_other_systems_refuse_extern_at_load checks. Native.wait_* has no Windows port
yet (#568). Tests assert codes and spans, never messages (AGENTS.md).
"""
import ctypes
import json
import platform
import subprocess
import time

import pytest

from tests.agentica_test import (FIXTURES, TARGET_OS, WINDOWS, cli, host_only, known_issue, require, run, tool,
                                 vm_environment)

MACOS = TARGET_OS == "darwin"
# The systems whose build has libffi; the others refuse native code at load, and the call cases skip there.
NATIVE = (TARGET_OS.startswith("linux") and platform.machine() == "x86_64") or \
    (WINDOWS and platform.machine() in ("AMD64", "x86_64")) or MACOS
NATIVE_CALLS = host_only(not NATIVE, "libffi is built for Linux x86_64, Windows x64 and macOS only")
# libuv polls only sockets on Windows, and the peer's descriptors are pipes.
NATIVE_WAITS = known_issue(WINDOWS, 568, "Native.wait_* has no Windows port yet")

# The C library and the math library, found by name by the system loader. On Windows the UCRT holds both, and on
# macOS libSystem (in the dyld shared cache, not on disk).
LIBC = "ucrtbase.dll" if WINDOWS else "libSystem.B.dylib" if MACOS else "libc.so.6"
LIBM = "ucrtbase.dll" if WINDOWS else "libSystem.B.dylib" if MACOS else "libm.so.6"

PEER_EXTERN = """extern "{library}"
  def peer_add(a: C.Int, b: C.Int) -> C.Int
  def peer_mul64(a: C.Int64, b: C.Int64) -> C.Int64
  def peer_scale(x: C.Double, k: C.Double) -> C.Double
  def peer_not(b: C.Bool) -> C.Bool
  def peer_len(s: C.String) -> C.Int64
  def peer_upper(s: C.String) -> C.String
  def peer_bump() -> Void
  def peer_bumps() -> C.Int
  def peer_null() -> C.String
  def peer_bad_utf8() -> C.String
  def peer_sum9(a: C.Int, b: C.Int, c: C.Int, d: C.Int, e: C.Int, f: C.Int, g: C.Int, h: C.Int, i: C.Int64) -> C.Int64
  def peer_mix(
    a: C.Int, b: C.Double, c: C.Int64, d: C.Bool, s: C.String, e: C.Double, f: C.Double, g: C.Double, h: C.Double,
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
    return shared_library(tmp_path_factory, "peer")


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
        text = 'extern "%s"\n  def peer_add(a: C.Int, b: C.Int) -> C.Int\nend\n\n' \
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
  compute def peer_wait_flag(limit_ms: C.Int) -> C.Int
  def peer_set_flag() -> Void
  def peer_returned() -> C.Int
  compute def peer_word(n: C.Int) -> C.String
  compute def peer_half(n: C.Int64) -> C.Double
  compute def peer_bump() -> Void
  def peer_bumps() -> C.Int
  compute def peer_nap(ms: C.Int) -> C.Int
  def peer_naps() -> C.Int
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
  def peer_res_open(value: C.Int) -> Res
  def peer_res_get(res: Res) -> C.Int
  compute def peer_res_hold(res: Res, limit_ms: C.Int) -> C.Int
  compute def peer_res_open_later(value: C.Int, limit_ms: C.Int) -> Res
  def peer_res_holding() -> C.Int
  def peer_res_frees() -> C.Int
  def peer_res_busy_frees() -> C.Int
  def peer_set_flag() -> Void
  def peer_bytes_sum(bytes: C.Bytes, n: C.Int) -> C.Int
  def peer_ptr_echo(p: C.Pointer) -> C.Pointer
  def peer_ptr_static() -> C.Pointer
  def peer_ptr_read(p: C.Pointer) -> C.Int
  def peer_res_bytes(res: Res, bytes: C.Bytes, n: C.Int) -> C.Int
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
  compute def peer_word(n: C.Int) -> C.String
  def peer_res_opens() -> C.Int
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
    n: C.Int, out i: C.Int, out l: C.Int64, out d: C.Double, out b: C.Bool, out p: C.Pointer, out res: Res,
  ) -> C.Int
  def peer_out_null(out res: Res) -> C.Int
  def peer_out_untouched(out res: Res) -> C.Int
  def peer_out_twice(n: C.Int, out twice: C.Int) -> Void
  compute def peer_out_open_later(value: C.Int, limit_ms: C.Int, out res: Res) -> C.Int
  def peer_res_get(res: Res) -> C.Int
  def peer_res_frees() -> C.Int
  def peer_ptr_read(p: C.Pointer) -> C.Int
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
    program(tmp_path, 'extern "%s"\n  export def peer_out_twice(n: C.Int, out twice: C.Int) -> Void\nend\n'
            % literal(peer), "raw.agc")
    main = program(tmp_path, 'import Raw from "./raw"\n\ndef twice(made: Raw.PeerOutTwice) -> Int\n'
                   '  return made.twice\nend\n\ndef main() -> Void\n  puts(twice(Raw.peer_out_twice(4)))\nend\n')
    result = agentica(main)
    assert (result.code, result.stdout, result.stderr) == (0, "8\n", "")


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
  def peer_pipe() -> C.Int
  def peer_pipe_writer() -> C.Int
  def peer_pipe_put() -> C.Int
  def peer_pipe_take() -> C.Int
  def peer_pipe_fill() -> Void
  def peer_pipe_blocking() -> Void
  def peer_nonblocking(fd: C.Int) -> C.Int
  def peer_regular_file() -> C.Int
  def peer_open_fds() -> C.Int
  def peer_fifo(path: C.String) -> C.Int
  def peer_fifo_put() -> C.Int
  def peer_pty() -> C.Int
  def peer_pty_put() -> C.Int
end

def wait(fd: Int) -> Result[Void]
  return Native.wait_readable(fd, 20_000)
end

"""


# Two tasks wait on the pipe's read end at once. On one scheduler, main's write proves that the waiting tasks gave the
# scheduler up; the write end is writable at once.
@NATIVE_CALLS
@NATIVE_WAITS
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
    result = agentica("--schedulers", schedulers, program(tmp_path, WAIT_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "main runs\n1\nok()\nok()\n1\nok()\n", "")


# The wait polls a new open of the pipe, so the native code's descriptors keep their flags: a blocking descriptor (a
# terminal, say) stays blocking after the wait, whether it ended ready or at its timeout.
@NATIVE_CALLS
@NATIVE_WAITS
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
    result = agentica(program(tmp_path, WAIT_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, 'error("native: timed out")\nok()\n0\n0\n', "")


@NATIVE_CALLS
@NATIVE_WAITS
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
    result = agentica(program(tmp_path, WAIT_EXTERN.format(library=literal(peer)) + main))
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
@NATIVE_WAITS
def test_a_wait_on_a_named_fifo_or_a_terminal_master_waits_for_data(tmp_path, peer):
    main = """def main() -> Void
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
    result = agentica(program(tmp_path, WAIT_EXTERN.format(library=literal(peer)) + main), tmp_path / "fifo")
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        'error("native: timed out")', "1", "ok()", 'error("native: timed out")', "0", "1", "ok()", "",
    ]


# The wait polls a duplicate of the descriptor: a cancel closes the duplicate once (the count of open descriptors goes
# back), and the peer's own descriptor still works.
@NATIVE_CALLS
@NATIVE_WAITS
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
    result = agentica("--schedulers", schedulers, program(tmp_path, WAIT_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == ["1", 'error("task: cancelled")', "0", "ok()", "1", ""]


@NATIVE_CALLS
@NATIVE_WAITS
def test_the_run_ends_while_a_task_waits(tmp_path, peer):
    main = """def main() -> Void
  waiter = Task.spawn(&wait, peer_pipe())
  Task.sleep(20)
  puts("done")
end
"""
    result = agentica(program(tmp_path, WAIT_EXTERN.format(library=literal(peer)) + main), timeout=10)
    assert (result.code, result.stdout, result.stderr) == (0, "done\n", "")


# On Windows a wait is not ported yet (#568): it returns an error at once. Elsewhere stdin (a pipe) is a descriptor that
# can be polled, so the run only has to end.
@NATIVE_CALLS
def test_a_wait_on_windows_returns_an_error(tmp_path):
    result = agentica(program(tmp_path, 'def main() -> Void\n  puts(Native.wait_readable(0, 10))\nend\n'))
    assert (result.code, result.stderr) == (0, "")
    if WINDOWS:
        assert result.stdout.startswith('error("native: '), result.stdout


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
  def no_such_function_here() -> C.Int
  def abs(n: C.Int) -> C.Int
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
    text = 'extern "%s"\n  def unbound_call() -> C.Int\nend\n\n' \
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
  def abs(n: C.Int) -> C.Int
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
  def abs(n: C.Int) -> C.Int
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


# A real library, not the peer: the system SQLite of Linux or macOS. sqlite3_malloc and sqlite3_free are a resource, and
# sqlite3_msize reads the block; the full case opens a database and queries it through out parameters.
SQLITE_LIBRARY = "libsqlite3.dylib" if MACOS else "libsqlite3.so.0"

SQLITE_EXTERN = """extern "%s"
  resource Block, free: sqlite3_free
  def sqlite3_libversion_number() -> C.Int
  def sqlite3_libversion() -> C.String
  def sqlite3_complete(sql: C.String) -> C.Int
  def sqlite3_malloc(size: C.Int) -> Block
  def sqlite3_msize(block: Block) -> C.Int64
end

""" % SQLITE_LIBRARY

# libsqlite3.so.0 is a Linux system library: CI installs libsqlite3-0, and a missing library fails there and skips
# on a local run. macOS has /usr/lib/libsqlite3.dylib (in the dyld shared cache); Windows has no system SQLite.
NO_SYSTEM_SQLITE = host_only(WINDOWS, "Windows has no system SQLite library")


@pytest.fixture(scope="module")
def sqlite():
    """Skip (a failure in CI) when the system SQLite library is not installed."""
    try:
        ctypes.CDLL(SQLITE_LIBRARY)
    except OSError:
        require(False, SQLITE_LIBRARY + " is required (Debian: apt install libsqlite3-0)")


@NATIVE_CALLS
@NO_SYSTEM_SQLITE
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
@NO_SYSTEM_SQLITE
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
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int
  def sqlite3_errcode(db: Db) -> C.Int
  def sqlite3_errmsg(db: Db) -> C.String
  def sqlite3_prepare_v2(db: Db, sql: C.String, bytes: C.Int, out stmt: Stmt, out tail: C.Pointer) -> C.Int
  compute def sqlite3_step(stmt: Stmt) -> C.Int
  def sqlite3_column_int(stmt: Stmt, col: C.Int) -> C.Int
  def sqlite3_column_text(stmt: Stmt, col: C.Int) -> C.String
end

""" % SQLITE_LIBRARY


# sqlite3_open gives an out Db and sqlite3_prepare_v2 an out Stmt (and the tail as a C.Pointer). A table gets two
# rows that a select reads back; bad SQL gives SQLITE_ERROR, its message, and a NULL Stmt, a closed resource. An open
# that fails (SQLITE_CANTOPEN, 14) still gives a live handle, which the wrapper reads and closes.
@NATIVE_CALLS
@NO_SYSTEM_SQLITE
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
