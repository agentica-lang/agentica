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
import select
import signal
import subprocess
import textwrap
import time

import pytest

from tests.agentica_test import FIXTURES, TARGET_OS, WINDOWS, cli, host_only, require, run, scaled, tool, vm_environment

MACOS = TARGET_OS == "darwin"
# The systems whose build has libffi; the others refuse native code at load, and the call cases skip there.
NATIVE = (TARGET_OS.startswith("linux") and platform.machine() == "x86_64") or \
    (WINDOWS and platform.machine() in ("AMD64", "x86_64")) or MACOS
NATIVE_CALLS = host_only(not NATIVE, "libffi is built for Linux x86_64, Windows x64 and macOS only")
# Keep native non-Linux platforms in the test body to report #616 as an open gap, not host-only.
NATIVE_STDIO_CASES = host_only(not NATIVE, "native calls are unsupported on this system")

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


def shared_library(tmp_path_factory, name, *flags, folder=None, source=None):
    """Build SOURCE (tests/fixtures/native/NAME.c by default) into a shared library (library_name) in FOLDER (a new
    one by default), with the extra compiler FLAGS, and return its absolute path."""
    folder = folder or tmp_path_factory.mktemp("native")
    out = folder / library_name(name)
    kind = ["-shared"] if WINDOWS else ["-dynamiclib"] if MACOS else ["-shared", "-fPIC"]
    subprocess.run([tool("cc"), *kind, "-O1", "-o", str(out),
                    str(source or FIXTURES / "native" / (name + ".c")), *flags], check=True)
    return out


def literal(path):
    """PATH as the text of an Agentica string literal: a Windows path has backslashes, which the literal escapes."""
    return str(path).replace("\\", "\\\\")


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    """The path of the peer library, built once for the module."""
    return shared_library(tmp_path_factory, "peer", *(["-lws2_32"] if WINDOWS else []))


def tsan_stdio_fixture_enabled():
    if TARGET_OS != "linux":
        return False
    expected = os.path.realpath("build/vm/tsan/agentica")
    return (os.path.realpath(os.environ.get("AGENTICA_VM_BINARY", "")) == expected and
            os.path.realpath(os.environ.get("AGENTICA_TEST_EXECUTABLE", "")) == expected)


def assert_tsan_finalize_race_report(report):
    assert report.count(b"WARNING:") == 1
    assert report.count(b"WARNING: ThreadSanitizer: data race") == 1
    assert b"tsan_finalize_control.c" in report
    assert b"shared_value" in report
    assert report.count(b"ThreadSanitizer: reported") == 1
    assert report.count(b"ThreadSanitizer: reported 1 warnings") == 1


def test_tsan_finalize_race_report_accepts_pid_and_thread_order_variation():
    reports = [
        b"""WARNING: ThreadSanitizer: data race (pid=101)
    Write of size 4 at tsan_finalize_control.c:11:16 (thread T1)
    Previous write of size 4 at tsan_finalize_control.c:19:18 (main thread)
    Location is global 'shared_value'
SUMMARY: ThreadSanitizer: reported 1 warnings
""",
        b"""WARNING: ThreadSanitizer: data race (pid=202)
    Write of size 4 at tsan_finalize_control.c:19:18 (main thread)
    Previous write of size 4 at tsan_finalize_control.c:11:16 (thread T1)
    Location is global 'shared_value'
SUMMARY: ThreadSanitizer: reported 1 warnings
""",
    ]
    for report in reports:
        assert_tsan_finalize_race_report(report)


@pytest.mark.parametrize("report", [
    b"SUMMARY: ThreadSanitizer: reported 1 warnings\n",
    b"WARNING: ThreadSanitizer: lock-order-inversion\n"
    b"tsan_finalize_control.c shared_value\n"
    b"SUMMARY: ThreadSanitizer: reported 1 warnings\n",
    b"WARNING: ThreadSanitizer: data race\nother_control.c shared_value\n"
    b"SUMMARY: ThreadSanitizer: reported 1 warnings\n",
    b"WARNING: ThreadSanitizer: data race\ntsan_finalize_control.c other_global\n"
    b"SUMMARY: ThreadSanitizer: reported 1 warnings\n",
    b"WARNING: ThreadSanitizer: data race\ntsan_finalize_control.c shared_value\n"
    b"SUMMARY: ThreadSanitizer: reported 2 warnings\n",
    b"WARNING: ThreadSanitizer: data race\ntsan_finalize_control.c shared_value\n"
    b"WARNING: ThreadSanitizer: another warning\n"
    b"SUMMARY: ThreadSanitizer: reported 1 warnings\n",
])
def test_tsan_finalize_race_report_rejects_unexpected_reports(report):
    with pytest.raises(AssertionError):
        assert_tsan_finalize_race_report(report)


def run_tsan_finalize_control(binary, hook, args, expected, tsan_options):
    read_fd = write_fd = None
    process = None
    try:
        env = vm_environment({"AGENTICA_TSAN_RELEASE_FD": None,
                             "AGENTICA_TSAN_RELEASE_READ_FD": None,
                             "AGENTICA_TSAN_PRIVATE_GATE_FD": None,
                             "TSAN_OPTIONS": tsan_options})
        pass_fds = ()
        if hook is not None:
            read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
            os.set_blocking(write_fd, False)
            env["AGENTICA_TSAN_RELEASE_FD"] = str(write_fd)
            preload = [str(hook)]
            if env.get("LD_PRELOAD"):
                preload.append(env["LD_PRELOAD"])
            env["LD_PRELOAD"] = os.pathsep.join(preload)
            pass_fds = (write_fd,)
        process = subprocess.Popen([str(binary), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=env, start_new_session=True, pass_fds=pass_fds)
        if write_fd is not None:
            os.close(write_fd)
            write_fd = None
        stdout, stderr = process.communicate(timeout=scaled(20))
        if expected is not None:
            assert process.returncode == expected, stdout.decode(errors="replace") + stderr.decode(errors="replace")
        if hook is not None:
            assert os.read(read_fd, 2) == b"R", "TSan did not invoke the preloaded finalization hook"
            assert os.read(read_fd, 1) == b"", "TSan finalization hook wrote more than one byte"
        return process.returncode, stdout, stderr
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        if read_fd is not None:
            os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)


@pytest.fixture(scope="module")
def tsan_stdio_support(tmp_path_factory):
    """Build test-only TSan hook/peer support once, with report and exit-status controls."""
    if not tsan_stdio_fixture_enabled():
        return None
    tsan_peer = shared_library(tmp_path_factory, "tsan_stdio_peer",
                               source=FIXTURES / "native" / "tsan_stdio_peer.c")
    hook = shared_library(tmp_path_factory, "tsan_stdio_release",
                          source=FIXTURES / "native" / "tsan_stdio_release.c")
    control_dir = tmp_path_factory.mktemp("tsan-finalize-control")
    control = control_dir / "tsan_finalize_control"
    subprocess.run([tool("clang"), "-std=c11", "-O1", "-g", "-fno-omit-frame-pointer",
                    "-fsanitize=thread", "-fno-sanitize-recover=all", "-pthread", "-o", str(control),
                    str(FIXTURES / "native" / "tsan_finalize_control.c")], check=True)
    options = "halt_on_error=0:exitcode=83"
    no_race, no_race_out, no_race_err = run_tsan_finalize_control(control, hook, [], 0, options)
    assert no_race_err == b"", no_race_err.decode(errors="replace")
    seven, seven_out, seven_err = run_tsan_finalize_control(control, hook, ["seven"], 7, options)
    assert seven_err == b"", seven_err.decode(errors="replace")
    race, race_out, race_err = run_tsan_finalize_control(control, hook, ["race"], 83, options)
    assert_tsan_finalize_race_report(race_err)
    assert no_race_out == seven_out == race_out == b""

    default_options = "halt_on_error=0"
    default_race, default_out, default_report = run_tsan_finalize_control(
        control, None, ["race"], None, default_options)
    hooked_race, hooked_out, hooked_report = run_tsan_finalize_control(
        control, hook, ["race"], None, default_options)
    assert default_race != 0, default_report.decode(errors="replace")
    assert hooked_race == default_race, hooked_report.decode(errors="replace")
    assert_tsan_finalize_race_report(default_report)
    assert_tsan_finalize_race_report(hooked_report)
    assert default_out == hooked_out == b""
    return {"peer": tsan_peer, "hook": hook}


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


def refused_at_extern(tmp_path, peer, extern_src, main, call, code):
    """A call the extern function refuses stops the run at that function with CODE and prints nothing."""
    result = agentica("--json", program(tmp_path, extern_src.format(library=literal(peer)) + main))
    declared = " def %s(" % call.split("(")[0]
    line = next(k for k, text in enumerate(extern_src.split("\n"), 1) if declared in text)
    assert diagnostic(result, 1) == (code, (line, 3))
    assert result.stdout == ""


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


INTEGER_EXTERN = """extern "{library}"
  struct PeerInts
    a: C.Int8
    b: C.UInt16
    c: C.Int16
    d: C.UInt8
    e: C.UInt32
    f: C.Long
    p: C.Pointer
  end
  def peer_i8(x: C.Int8) -> C.Int8
  def peer_i16(x: C.Int16) -> C.Int16
  def peer_u8(x: C.UInt8) -> C.UInt8
  def peer_u16(x: C.UInt16) -> C.UInt16
  def peer_u32(x: C.UInt32) -> C.UInt32
  def peer_long(x: C.Long) -> C.Long
  def peer_add(a: C.Int32, b: C.Int32) -> C.Int32
  def peer_cut_i8(x: C.Int64) -> C.Int8
  def peer_cut_i16(x: C.Int64) -> C.Int16
  def peer_cut_u8(x: C.Int64) -> C.UInt8
  def peer_cut_u16(x: C.Int64) -> C.UInt16
  def peer_cut_u32(x: C.Int64) -> C.UInt32
  def peer_long_bits() -> C.Int32
  def peer_long_max() -> C.Long
  def peer_long_min() -> C.Long
  def peer_out_ints(
    out a: C.Int8, out b: C.Int16, out c: C.UInt8, out d: C.UInt16, out e: C.UInt32, out f: C.Long,
  ) -> Void
  def peer_ints_max() -> PeerInts
  def peer_ints_text(s: PeerInts) -> C.String
  compute def ints_text_later(s: PeerInts) -> C.String = "peer_ints_text"
  def vmix_ints(kinds: C.String, ..., a: C.UInt32, b: C.Long) -> C.Double = "peer_vmix"
end

"""


# Each integer type at the ends of its range, as an argument and a result, an out parameter, a struct field (C reads
# the fields at its own offsets, which move with the size of long) and a variadic argument. A signed result is
# sign-extended and an unsigned one zero-extended, also when C leaves the register's high bits set (peer_cut_*), so a
# C.UInt32 above 2^31 is positive. An argument takes the bits of its type read as signed or unsigned, as put_int8 to
# put_int32 do: -1 and 255 are the same C.UInt8. C.Long has the platform's width, 32 bits on Windows and 64
# elsewhere, which only the Windows run checks for 32.
@NATIVE_CALLS
def test_each_integer_type_crosses_at_the_ends_of_its_range(tmp_path, peer):
    main = """def main() -> Void
  puts([peer_i8(-128), peer_i8(127), peer_i8(255), peer_i16(-32_768), peer_i16(32_767), peer_i16(65_535)])
  puts([peer_u8(0), peer_u8(255), peer_u8(-1), peer_u16(65_535), peer_u16(-32_768)])
  puts([peer_u32(0), peer_u32(2_147_483_648), peer_u32(4_294_967_295), peer_u32(-1), peer_add(2_147_483_648, 0)])
  puts([peer_cut_i8(511), peer_cut_i16(131_071), peer_cut_u8(511), peer_cut_u16(-1), peer_cut_u32(-16)])
  puts([peer_long_bits(), peer_long(peer_long_max()), peer_long(peer_long_min()), peer_long(-5), peer_long(0)])
  puts(peer_out_ints())
  m = peer_ints_max()
  puts([m.a, m.b, m.c, m.d, m.e, m.f - peer_long_max()])
  puts(peer_ints_text(m))
  puts(ints_text_later(m.with(a: -128, b: 0, c: -32_768, d: 0, e: -1, f: peer_long_min(), p: Native.null())))
  puts(vmix_ints("jn", 4_000_000_000, -5))
end
"""
    result = agentica(program(tmp_path, INTEGER_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    bits = 32 if WINDOWS else 64
    high, low = 2 ** (bits - 1) - 1, -2 ** (bits - 1)
    assert result.stdout.split("\n") == [
        "[-128, 127, -1, -32768, 32767, -1]",
        "[0, 255, 255, 65535, 32768]",
        "[0, 2147483648, 4294967295, 4294967295, -2147483648]",
        "[-1, -1, 255, 65535, 4294967280]",
        "[%d, %d, %d, -5, 0]" % (bits, high, low),
        "PeerOutInts(a: -128, b: -32768, c: 255, d: 65535, e: 4294967295, f: %d)" % low,
        "[127, 65535, 32767, 255, 4294967295, 0]",
        "a=127 b=65535 c=32767 d=255 e=4294967295 f=%d p=text" % high,
        "a=-128 b=0 c=-32768 d=0 e=4294967295 f=%d p=null" % low,
        "3999999995.0",
        "",
    ]


# An integer outside the bits of its type, read as signed or as unsigned, stops the run at the extern function before
# C runs, as an argument and as a struct field. C.Long takes any Int where long has 64 bits, and up to 2^32 - 1 on
# Windows.
@NATIVE_CALLS
@pytest.mark.parametrize("call", [
    "peer_i8(-129)", "peer_u8(256)", "peer_i16(-32_769)", "peer_u16(65_536)", "peer_u32(4_294_967_296)",
    "peer_add(-2_147_483_649, 0)", "peer_ints_text(peer_ints_max().with(b: 65_536))",
] + (["peer_long(4_294_967_296)"] if WINDOWS else []))
def test_an_integer_outside_the_bits_of_its_type_stops_the_run(tmp_path, peer, call):
    main = "def main() -> Void\n  puts(%s)\nend\n" % call
    refused_at_extern(tmp_path, peer, INTEGER_EXTERN, main, call, "RUNTIME-INTEGER-OVERFLOW")


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


def capture_stdio_ready(read_streams, process, captured):
    readable, _, _ = select.select(read_streams, [], [], 0.05)
    for stream in readable:
        name = "stdout" if stream is process.stdout else "stderr"
        chunk = os.read(stream.fileno(), 65536)
        if not chunk:
            read_streams.remove(stream)
        else:
            captured[name].extend(chunk)
    return b"done\n" in captured["stdout"]


def marker_is(path, expected):
    try:
        return path.read_bytes() == expected
    except FileNotFoundError:
        return False


def run_stdio_shutdown(source, locked_stream, lock_marker, main_marker, released_marker=None, tsan_support=None):
    diagnostic = tsan_support is not None
    owned_fds = []
    release_read = release_write = gate_read = gate_write = None
    try:
        env = vm_environment()
        spawn_options = {"start_new_session": True}
        if diagnostic:
            release_read, release_write = os.pipe2(os.O_CLOEXEC)
            owned_fds.extend((release_read, release_write))
            gate_read, gate_write = os.pipe2(os.O_CLOEXEC)
            owned_fds.extend((gate_read, gate_write))
            os.set_blocking(release_write, False)
            env["AGENTICA_TSAN_RELEASE_FD"] = str(release_write)
            env["AGENTICA_TSAN_RELEASE_READ_FD"] = str(release_read)
            env["AGENTICA_TSAN_PRIVATE_GATE_FD"] = str(gate_read)
            preload = [str(tsan_support["hook"])]
            if env.get("LD_PRELOAD"):
                preload.append(env["LD_PRELOAD"])
            env["LD_PRELOAD"] = os.pathsep.join(preload)
            spawn_options["pass_fds"] = (release_read, release_write, gate_read)
        process = subprocess.Popen(cli() + ["--schedulers", "4", str(source)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, **spawn_options)
    except BaseException:
        for fd in owned_fds:
            os.close(fd)
        raise
    if diagnostic:
        for fd in (release_read, release_write, gate_read):
            os.close(fd)
            owned_fds.remove(fd)

    captured = {"stdout": bytearray(), "stderr": bytearray()}
    stdout_done = False
    read_streams = [process.stdout, process.stderr]
    deadline = time.monotonic() + scaled(5)
    try:
        while not marker_is(lock_marker, b"locked") and process.poll() is None and time.monotonic() < deadline:
            capture_stdio_ready(read_streams, process, captured)
        assert marker_is(lock_marker, b"locked"), "native code did not acquire and mark the FILE lock"
        time.sleep(scaled(0.25))
        process.stdin.write(b"x")
        process.stdin.close()
        deadline = time.monotonic() + scaled(5)
        while not main_marker.exists() and process.poll() is None and time.monotonic() < deadline:
            stdout_done = capture_stdio_ready(read_streams, process, captured) or stdout_done
        assert main_marker.exists(), "main did not reach the file marker after puts"
        # The VM may write done and exit before this reads it, so read until done or the end of stdout, not the exit.
        deadline = time.monotonic() + scaled(3)
        while not stdout_done and process.stdout in read_streams and time.monotonic() < deadline:
            stdout_done = capture_stdio_ready(read_streams, process, captured)
        assert stdout_done, f"VM stdout did not deliver done: {bytes(captured['stdout'])!r}"
        deadline = time.monotonic() + scaled(3)
        while process.poll() is None and time.monotonic() < deadline:
            capture_stdio_ready(read_streams, process, captured)
        assert process.poll() is not None, "settlement waited for the native FILE lock"
        deadline = time.monotonic() + scaled(1)
        while read_streams and time.monotonic() < deadline:
            capture_stdio_ready(read_streams, process, captured)
        if diagnostic:
            assert released_marker is not None and marker_is(released_marker, b"released"), \
                "native lock owner did not acknowledge TSan's finalization release"
        return process.returncode, captured
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()
        for fd in owned_fds:
            os.close(fd)


@NATIVE_STDIO_CASES
@pytest.mark.parametrize("locked_stream, stream_id", [("stdout", 1), ("stderr", 2)])
@pytest.mark.parametrize("ending, code", [("", 0), ("System.exit(7)", 7)])
def test_settlement_skips_a_locked_c_standard_stream(tmp_path, peer, tsan_stdio_support,
                                                      locked_stream, stream_id, ending, code):
    free_stream = "stderr" if locked_stream == "stdout" else "stdout"
    lock_path = literal(tmp_path / "locked")
    release_path = literal(tmp_path / "released")
    if tsan_stdio_support:
        library = tsan_stdio_support["peer"]
        hold = "peer_hold_stdio_tsan"
        buffer = "peer_buffer_stdio_tsan"
        hold_signature = f"compute def {hold}(which: C.Int32, marker: C.String, release_marker: C.String) -> C.Int32"
        hold_call = f'{hold}({stream_id}, "{lock_path}", "{release_path}")'
    else:
        library = peer
        hold = "peer_hold_stdio"
        buffer = "peer_buffer_stdio"
        hold_signature = f"compute def {hold}(which: C.Int32, marker: C.String) -> C.Int32"
        hold_call = f'{hold}({stream_id}, "{lock_path}")'
    main = '''extern "{library}"
  {hold_signature}
  def {buffer}(which: C.Int32) -> C.Int32
end

def hold_stream(n: Int) -> Int
  return {hold_call}
end

def main() -> Void
  writer = Task.spawn(&hold_stream, 0)
  IO.read_bytes(1)
  {buffer}({free_stream_id})
  puts("done")
  File.write_text("{main_marker}", "after puts", 2000)
  {ending}
end
'''.format(library=literal(library), hold_signature=hold_signature, hold_call=hold_call, buffer=buffer,
           main_marker=literal(tmp_path / "main-reached"), free_stream_id=3 - stream_id, ending=ending)
    source = program(tmp_path, main)
    assert agentica("check", source).code == 0
    if not TARGET_OS.startswith("linux"):
        host = "Windows" if WINDOWS else "macOS"
        pytest.skip(f"known-issue: #616 {host} final C stdio flush remains blocking with a compute-held stream")
    result, captured = run_stdio_shutdown(source, locked_stream, tmp_path / "locked", tmp_path / "main-reached",
                                          tmp_path / "released" if tsan_stdio_support else None,
                                          tsan_stdio_support)
    assert result == code
    assert b"done\n" in captured["stdout"]
    assert b"native-free\n" in captured[free_stream]


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


# A free function whose C name starts with a capital letter (PQfinish, SSL_free) is looked up by that exact name: the
# peer counts its calls, so Native.close frees it once.
CAPITAL_FREE_EXTERN = """extern "{library}"
  resource Cap, free: PeerFree
  def peer_res_open(value: C.Int32) -> Cap
  def peer_res_get(cap: Cap) -> C.Int32
  def peer_res_frees() -> C.Int32
end

def main() -> Void
  cap = peer_res_open(5).unwrap!
  puts(peer_res_get(cap))
  puts(peer_res_frees())
  Native.close(cap)
  puts(peer_res_frees())
end
"""


@NATIVE_CALLS
def test_a_resource_with_a_capital_free_name_is_freed_by_that_function(tmp_path, peer):
    result = agentica(program(tmp_path, CAPITAL_FREE_EXTERN.format(library=literal(peer))))
    assert (result.code, result.stdout, result.stderr) == (0, "5\n0\n1\n", "")


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
# included, which becomes U+FFFD); Native.get_bytes copies bytes. NULL with length 0 is empty, as C means it.
# Native.pointer makes the pointer of an integer, which C sees as that integer, and a pointer's value makes the same
# pointer again.
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
        "[104, 195, 169, 108, 108, 111, 0, 119, 111, 114, 108, 100]", "[119, 111]", "[]", "0", "-1", "4096", "true",
        "42", "",
    ]


# A read at NULL is RUNTIME-NATIVE-NULL at the pointer, a negative offset RUNTIME-NATIVE-BOUNDS at it and a negative
# length RUNTIME-INVALID-COUNT at the length; the pointer is checked first.
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
    text = 'def main() -> Void\n  puts("started")\n  puts(Native.get_string(Native.pointer(0), 0, 0))\nend\n'
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
# count or list that runs past), and a freed one RUNTIME-NATIVE-CLOSED, also as an extern argument. A view
# (Native.offset) ends where its buffer does, is freed with it, and is not the program's to free. A C pointer has no
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
    ("Native.offset(buf, 17)", "RUNTIME-NATIVE-BOUNDS", "17"),
    ("Native.offset(buf, -1)", "RUNTIME-NATIVE-BOUNDS", "-1"),
    ("Native.get_int32(Native.offset(buf, 14), 0)", "RUNTIME-NATIVE-BOUNDS", "0)"),
    ("Native.free(Native.offset(buf, 4))", "RUNTIME-NATIVE-NOT-OWNED", "Native.offset"),
    ("Native.offset(gone, 0)", "RUNTIME-NATIVE-CLOSED", "gone"),
    ("Native.address(gone)", "RUNTIME-NATIVE-CLOSED", "gone"),
    ("Native.get_int8(gone_view, 0)", "RUNTIME-NATIVE-CLOSED", "gone_view"),
    ("peer_sum_floats(gone_view, 1)", "RUNTIME-NATIVE-CLOSED", None),
])
def test_bounds_null_and_freed_buffers_stop_the_run(tmp_path, peer, line, code, argument):
    text = "  %s" % line if line.startswith(("Native.put", "Native.free")) else "  IO.inspect(%s)" % line
    main = 'def main() -> Void\n  buf = Native.memory_pointer(16)\n  gone = Native.memory_pointer(4)\n' \
        '  gone_view = Native.offset(gone, 2)\n  Native.free(gone)\n  full = Native.memory_pointer(2)\n' \
        '  Native.put_int16(full, 0, 24_929)\n  puts("before")\n%s\nend\n' % text
    result = agentica("--json", program(tmp_path, BUFFER_EXTERN.format(library=literal(peer)) + main))
    assert result.stdout == "before\n"
    # An extern call fails at its extern function, as for a closed resource.
    where = (BUFFER_EXTERN.count("\n") + 9, text.index(argument) + 1) if argument else (3, 3)
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


# Native.offset of an owned buffer is a view of the same memory from that byte to the buffer's end: C fills and reads
# it, a view of a view counts from the buffer, and the parent's free closes it. Of a C pointer it is the plain sum.
# Native.address gives back the integer, so two pointers into one block subtract to the bytes between them.
@NATIVE_CALLS
def test_a_view_into_an_owned_buffer_and_the_address_of_a_pointer(tmp_path, peer):
    main = """def main() -> Void
  buf = Native.memory_pointer(16)
  ints = Native.offset(buf, 8)
  peer_fill_ints(ints, 2)
  puts(Native.get_array_of_int32(buf, 0, 4))
  Native.put_float32(ints, 0, 1.5)
  Native.put_float32(Native.offset(ints, 4), 0, 2.0)
  puts(peer_sum_floats(ints, 2))
  tail = Native.offset(ints, 8)
  puts([Native.address(ints) - Native.address(buf), Native.address(tail) - Native.address(buf)])
  puts(Native.get_bytes(tail, 0, 0))
  puts([Native.null?(ints), Native.closed?(ints)])
  IO.inspect(ints)
  puts(Native.get_int64(Native.offset(peer_static_int64s(), 8), 0))
  puts(Native.address(Native.offset(Native.pointer(4096), -96)))
  puts(Native.address(Native.pointer(-1)))
  Native.free(buf)
  puts(Native.closed?(ints))
end
"""
    result = agentica(program(tmp_path, BUFFER_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr, result.stdout.splitlines()) == (0, "", [
        "[0, 0, -3, -2]", "3.5", "[8, 16]", "[]", "[false, false]", "<C.Pointer>", "-9", "4000", "-1", "true",
    ])


# The block form of Native.memory_pointer yields a new buffer, frees it when the block ends and returns the block's
# value: a buffer that the block gives back is freed, and so is one when the block ends early with an error that a
# `try` returned (the block hands its buffer out over a channel to show it). A task cancelled while its block is
# parked ends, and its end frees the buffer; nested block forms free each buffer at the end of its own block. Each
# case reads a freed buffer last, which is RUNTIME-NATIVE-CLOSED.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
@pytest.mark.parametrize("tail, out", [
    ("  kept = Native.memory_pointer(8) do |buf| buf end\n", "9.5\n"),
    ("  failed = Native.memory_pointer(8) do |buf| first(buf, out) end\n  puts(failed.ok?)\n"
     "  kept = out.recv(1000).unwrap!\n", "9.5\nfalse\n"),
    ("  worker = Task.spawn(&park, out)\n  kept = out.recv(5000).unwrap!\n  Task.cancel(worker)\n"
     "  puts(Task.await(worker).ok?)\n", "9.5\nfalse\n"),
    ("  kept = Native.memory_pointer(8) do |outer|\n    Native.put_int32(outer, 0, 5)\n"
     "    inner = Native.memory_pointer(8) do |buf|\n      Native.put_int32(buf, 0, 7)\n"
     "      puts(Native.get_int32(outer, 0) + Native.get_int32(buf, 0))\n      buf\n    end\n"
     "    puts(Native.get_int32(outer, 0))\n    inner\n  end\n", "9.5\n12\n5\n"),
    ("  kept = Native.memory_pointer(8) do |outer|\n"
     "    Native.memory_pointer(8) do |buf| Native.put_int32(buf, 0, 7) end\n    outer\n  end\n", "9.5\n"),
])
def test_the_block_form_frees_its_buffer_when_the_block_ends(tmp_path, peer, schedulers, tail, out):
    main = """def first(buf: C.Pointer, out: Channel[C.Pointer]) -> Result[Int]
  try out.send(buf, 1000)
  n = try "x".to_i
  return ok(n)
end

def park(out: Channel[C.Pointer]) -> Result[Void]
  return Native.memory_pointer(8) do |buf|
    try out.send(buf, 5000)
    Task.sleep(60_000)
    ok()
  end
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


# Ownership wins over the block: a buffer that the block hands to a child with Task.spawn_owning is not freed at the
# block's end, so the child, which reads it after the block ended, sums what was written; its own end frees it.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_the_block_form_leaves_a_handed_buffer_to_its_new_owner(tmp_path, peer, schedulers):
    main = """def sum_later(buf: C.Pointer) -> Float
  Task.sleep(50)
  return peer_sum_floats(buf, 2)
end

def main() -> Void
  child = Native.memory_pointer(8) do |buf|
    Native.put_array_of_float32(buf, 0, [1.5, 2.0])
    Task.spawn_owning(&sum_later, buf)
  end
  puts(Task.await(child))
end
"""
    text = BUFFER_EXTERN.format(library=literal(peer)) + main
    result = agentica("--schedulers", schedulers, program(tmp_path, text))
    assert (result.code, result.stdout, result.stderr) == (0, "3.5\n", "")


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
# the memory goes when the call returns, so C sums what was written. The same holds for the free at the end of a block
# form, while a compute call of another task reads the buffer.
HOLD_BUFFER = """for k in 0...64
  Native.put_float32(buf, k * 4, 1.0)
end
task = Task.spawn(&sum_later, buf)
n = 0
while peer_res_holding() == 0 and n < 2000
  Task.sleep(1)
  n += 1
end
"""


@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
@pytest.mark.parametrize("form", ["free", "view", "block"])
def test_a_compute_call_keeps_its_buffer_until_it_returns(tmp_path, peer, schedulers, form):
    if form != "block":
        # A call that takes a view holds its buffer the same way.
        hold = HOLD_BUFFER.replace("(&sum_later, buf)", "(&sum_later, Native.offset(buf, 0))") \
            if form == "view" else HOLD_BUFFER
        body = "  buf = Native.memory_pointer(256)\n" + textwrap.indent(hold, "  ") + \
            "  Native.free(buf)\n  holder = task\n"
    else:
        body = "  holder = Native.memory_pointer(256) do |buf|\n" + textwrap.indent(HOLD_BUFFER, "    ") + \
            "    task\n  end\n"
    main = """def sum_later(buf: C.Pointer) -> Result[Float]
  return ok(peer_floats_hold(buf, 64, 20_000))
end

def main() -> Void
%s  peer_set_flag()
  puts(Task.await(holder))
end
""" % body
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


CLOSED_EXTERN = """extern "{library}"
  resource Res, free: peer_res_free
  def peer_res_open(value: C.Int32) -> Res
  def peer_res_get(res: Res) -> C.Int32
  compute def peer_res_hold(res: Res, limit_ms: C.Int32) -> C.Int32
  def peer_res_holding() -> C.Int32
  def peer_res_frees() -> C.Int32
  def peer_out_null(out res: Res) -> C.Int32
  def peer_ptr_static() -> C.Pointer
  def peer_set_flag() -> Void
end

def get(res: Res) -> Result[Int]
  if Native.closed?(res)
    return error("closed")
  end

  return ok(peer_res_get(res))
end

def opened(n: Int) -> Res
  return peer_res_open(n).unwrap!
end

def close(res: Res) -> Bool
  Native.close(res)
  return Native.closed?(res)
end

def hold(res: Res) -> Int
  return peer_res_hold(res, 20_000)
end

def main() -> Void
  res = peer_res_open(1).unwrap!
  puts([Native.closed?(res), Native.closed?(res)])
  IO.inspect(get(res))
  Native.close(res)
  puts(Native.closed?(res))
  IO.inspect(get(res))
  puts(Native.closed?(peer_out_null().res))
  other = peer_res_open(2).unwrap!
  puts(Task.await(Task.spawn(&close, other)))
  puts(Native.closed?(other))
  puts(Native.closed?(Task.await(Task.spawn(&opened, 3))))
  handed = peer_res_open(4).unwrap!
  IO.inspect(Task.await(Task.spawn_owning(&get, handed)))
  puts(Native.closed?(handed))
  held = peer_res_open(5).unwrap!
  holder = Task.spawn(&hold, held)
  n = 0
  while peer_res_holding() == 0 and n < 2000
    Task.sleep(1)
    n += 1
  end
  puts(Native.closed?(held))
  Native.close(held)
  puts("#{{Native.closed?(held)}} #{{peer_res_frees()}}")
  peer_set_flag()
  puts(Task.await(holder))
  buf = Native.memory_pointer(8)
  puts(Native.closed?(buf))
  Native.free(buf)
  puts([Native.closed?(buf), Native.closed?(Native.null()), Native.closed?(peer_ptr_static())])
end
"""


# Native.closed? asks what a call would refuse with RUNTIME-NATIVE-CLOSED, so a wrapper can return an error instead:
# false while the resource is live (also while a compute call in another task holds it), true after Native.close in
# this task or another, for an out resource that C left NULL, after the end of the task that owned it (Task.spawn's
# result, Task.spawn_owning's argument), and at once when it is closed while a compute call holds it, before the free
# runs. An owned buffer is closed once freed; a C.Pointer of C, NULL included, never is.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_closed_tells_a_live_resource_from_a_closed_one(tmp_path, peer, schedulers):
    result = agentica("--schedulers", schedulers, program(tmp_path, CLOSED_EXTERN.format(library=literal(peer))))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "[false, false]", "ok(1)", "true", 'error("closed")', "true", "true", "true", "true", "ok(4)", "true",
        "false", "true 4", "5", "false", "[true, false, false]", "",
    ]


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
  puts(Native.get_string(buffer, 0))
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


API_EXTERN = """# The slots of the peer's table (peer_api in peer.c), one pointer each.
ADD = 0
MIX = 1
CREATE = 2
OPEN = 3
RELEASE = 4
GET = 5
READ = 6
HALF = 7
CREATE_LATER = 8
MISSING = 9

extern "{library}"
  resource Thing, free: C.Function
  def peer_get_api_base() -> C.Pointer
  def peer_api_releases() -> C.Int32
  def peer_ptr_static() -> C.Pointer
  def peer_set_flag() -> Void
  def get_api(fn: C.Function, version: C.Int32) -> C.Pointer
  def version_string(fn: C.Function) -> C.String
  def add(fn: C.Function, a: C.Int32, b: C.Int32) -> C.Int32
  def mix(fn: C.Function, a: C.Int32, b: C.Double, c: C.Float, d: C.Int64) -> C.Double
  def create(fn: C.Function, value: C.Int32, out thing: Thing, free: C.Function) -> C.Int32
  def open(fn: C.Function, value: C.Int32, free: C.Function) -> Thing
  def get(fn: C.Function, thing: Thing) -> C.Int32
  def read(fn: C.Function, p: C.Pointer) -> C.Int32
  compute def half(fn: C.Function, x: C.Double) -> C.Double
  compute def create_later(
    fn: C.Function, value: C.Int32, limit_ms: C.Int32, out thing: Thing, free: C.Function,
  ) -> C.Int32
  def missing(fn: C.Function) -> Void
  def peer_api_thing(free: C.Function) -> Thing
end

def slot(table: C.Pointer, index: Int) -> C.Pointer
  return Native.get_pointer(table, index * 8)
end

def api() -> C.Pointer
  return get_api(slot(peer_get_api_base(), 0), 1)
end

def wait_releases(count: Int) -> Void
  n = 0
  while peer_api_releases() < count and n < 2000
    Task.sleep(1)
    n += 1
  end
end

"""


# A table of C function pointers, as onnxruntime's OrtApi: a base from a named function, a table from a call through
# its first slot, then calls through the table with each C type, an out resource and a resource result freed through
# the table's release slot (once, and never for NULL), a compute def through a pointer, and a named maker whose sole
# C.Function parameter is its free function.
@NATIVE_CALLS
def test_calls_through_a_table_of_c_function_pointers(tmp_path, peer):
    main = """def main() -> Void
  table = api()
  puts(Native.null?(get_api(slot(peer_get_api_base(), 0), 2)))
  puts(version_string(slot(peer_get_api_base(), 1)))
  puts(add(slot(table, ADD), 40, 2))
  puts(mix(slot(table, MIX), 1, 0.5, 0.25, 3_000_000_000))
  made = create(slot(table, CREATE), 7, slot(table, RELEASE))
  puts(made.result)
  puts(get(slot(table, GET), made.thing))
  Native.close(made.thing)
  Native.close(made.thing)
  puts(peer_api_releases())
  failed = create(slot(table, CREATE), -1, slot(table, RELEASE))
  puts(failed.result)
  Native.close(failed.thing)
  opened = open(slot(table, OPEN), 9, slot(table, RELEASE)).unwrap!
  puts(get(slot(table, GET), opened))
  puts(open(slot(table, OPEN), -1, slot(table, RELEASE)).message)
  Native.close(opened)
  puts(peer_api_releases())
  puts(read(slot(table, READ), peer_ptr_static()))
  puts(half(slot(table, HALF), 5.0))
  named = peer_api_thing(slot(table, RELEASE)).unwrap!
  puts(get(slot(table, GET), named))
  Native.close(named)
  puts(peer_api_releases())
end
"""
    result = agentica(program(tmp_path, API_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "true", "peer-api-1", "42", "3000000001.75", "0", "7", "1", "1", "9", "open returned NULL", "2", "42", "2.5",
        "5", "3", "",
    ]


# A NULL function pointer, to call or as a free function, and an owned buffer to call or as a free function stop the
# run at the extern function before C runs; nothing is made.
@NATIVE_CALLS
@pytest.mark.parametrize("call, code", [
    ("missing(slot(api(), MISSING))", "RUNTIME-NATIVE-NULL"),
    ("open(slot(api(), OPEN), 1, Native.null())", "RUNTIME-NATIVE-NULL"),
    ("half(Native.memory_pointer(8), 1.0)", "RUNTIME-NATIVE-BOUNDS"),
    ("open(slot(api(), OPEN), 1, Native.memory_pointer(8))", "RUNTIME-NATIVE-BOUNDS"),
])
def test_a_null_function_pointer_is_refused(tmp_path, peer, call, code):
    main = "def main() -> Void\n  %s\n  puts(peer_api_releases())\nend\n" % call
    refused_at_extern(tmp_path, peer, API_EXTERN, main, call, code)


# A resource freed through a function pointer is freed by the end of its owning task (a cancel ends it too), and the
# out resource of a cancelled compute call through a pointer is freed through its pointer once C returns.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_resource_freed_through_a_pointer_at_task_end_and_on_cancel(tmp_path, peer, schedulers):
    main = """def open_one(n: Int) -> Int
  table = api()
  return get(slot(table, GET), open(slot(table, OPEN), n, slot(table, RELEASE)).unwrap!)
end

def keep(n: Int) -> Result[Int]
  table = api()
  made = create(slot(table, CREATE), n, slot(table, RELEASE))
  Task.sleep(60_000)
  return ok(get(slot(table, GET), made.thing))
end

def later(n: Int) -> Result[Int]
  table = api()
  made = create_later(slot(table, CREATE_LATER), n, 20_000, slot(table, RELEASE))
  return ok(get(slot(table, GET), made.thing))
end

def main() -> Void
  sum = 0
  for n in 1..10
    sum += Task.await(Task.spawn(&open_one, n))
  end
  puts(sum)
  puts(peer_api_releases())
  keeper = Task.spawn(&keep, 3)
  Task.sleep(20)
  Task.cancel(keeper)
  puts(Task.await(keeper))
  wait_releases(11)
  puts(peer_api_releases())
  opener = Task.spawn(&later, 4)
  Task.sleep(20)
  Task.cancel(opener)
  puts(Task.await(opener))
  peer_set_flag()
  wait_releases(12)
  puts(peer_api_releases())
end
"""
    result = agentica("--schedulers", schedulers, program(tmp_path, API_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "55", "10", 'error("task: cancelled")', "11", 'error("task: cancelled")', "12", "",
    ]


STRUCT_EXTERN = """extern "{library}"
  struct PeerPair
    x: C.Int32
    y: C.Int32
  end
  struct PeerMixed
    n: C.Int32
    x: C.Double
  end
  struct PeerQuad
    a: C.Float
    b: C.Float
    c: C.Float = 0.5
    d: C.Float = 0.25
  end
  struct PeerParams
    n_ctx: C.Int32
    n_threads: C.Int32
    seed: C.Int64
    rope_freq_base: C.Double
    yarn_factor: C.Float
    use_mmap: C.Bool
    embeddings: C.Bool
    user_data: C.Pointer
  end
  struct PeerNested
    at: PeerPair
    mixed: PeerMixed
    flag: C.Bool
  end
  struct PeerBatch
    n_tokens: C.Int32
    token: C.Pointer
  end
  def peer_pair_make(x: C.Int32, y: C.Int32) -> PeerPair
  def peer_pair_swap(p: PeerPair) -> PeerPair
  def peer_pair_sum(p: PeerPair) -> C.Int64
  def peer_pair_swap_address() -> C.Pointer
  def swap_at(fn: C.Function, p: PeerPair) -> PeerPair
  def peer_mixed_scale(m: PeerMixed, k: C.Double) -> PeerMixed
  compute def scale_later(m: PeerMixed, k: C.Double) -> PeerMixed = "peer_mixed_scale"
  def peer_quad_add(p: PeerQuad, q: PeerQuad) -> PeerQuad
  def peer_quad_sum(q: PeerQuad) -> C.Double
  def peer_params_default() -> PeerParams
  def peer_params_text(p: PeerParams) -> C.String
  compute def params_text_later(p: PeerParams) -> C.String = "peer_params_text"
  def peer_nested_make(k: C.Int32) -> PeerNested
  def peer_nested_bump(v: PeerNested) -> PeerNested
  def peer_batch_get_one(tokens: C.Pointer, n: C.Int32) -> PeerBatch
  def peer_batch_sum(b: PeerBatch) -> C.Int64
  compute def batch_sum_later(b: PeerBatch) -> C.Int64 = "peer_batch_sum"
  compute def peer_batch_hold(b: PeerBatch, limit_ms: C.Int32) -> C.Int64
  def peer_res_holding() -> C.Int32
  def peer_set_flag() -> Void
end

"""


# C structs by value, both ways, for each class of the ABIs (peer.c): two int32, an int32 and a double, four floats
# (with field defaults), params larger than 16 bytes with bool and pointer fields, read and changed with .with and
# passed back as llama.cpp's are, a nested struct, and a batch whose pointer field is an owned buffer or C's memory;
# also through a C function pointer and in compute defs.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_c_structs_cross_by_value_both_ways(tmp_path, peer, schedulers):
    main = """def main() -> Void
  p = peer_pair_make(3, -4)
  puts(p)
  puts(peer_pair_swap(p.with(x: 2_147_483_647)))
  puts(peer_pair_sum(PeerPair(x: -2_147_483_648, y: -1)))
  puts(swap_at(peer_pair_swap_address(), p))
  m = peer_mixed_scale(PeerMixed(n: 21, x: 1.5), 3.0)
  puts(m)
  puts(scale_later(m, 0.5))
  q = peer_quad_add(PeerQuad(a: 1.5, b: 0.25), PeerQuad(a: 2.0, b: 0.5, c: 1.0, d: 2.0))
  puts(q)
  puts(peer_quad_sum(q))
  params = peer_params_default()
  puts(peer_params_text(params))
  puts([params.use_mmap, params.embeddings, Native.null?(params.user_data)])
  changed = params.with(n_ctx: 4096, seed: 9_000_000_000, use_mmap: false, embeddings: true, yarn_factor: 1.5)
  puts(peer_params_text(changed))
  puts(params_text_later(changed.with(user_data: Native.null(), n_threads: -8)))
  n = peer_nested_make(10)
  puts(n)
  puts(peer_nested_bump(n.with(at: n.at.with(y: 0))))
  buf = Native.memory_pointer(12)
  Native.put_array_of_int32(buf, 0, [1, 2, 39])
  batch = peer_batch_get_one(buf, 3)
  puts(batch.n_tokens)
  puts(peer_batch_sum(batch))
  puts(batch_sum_later(PeerBatch(n_tokens: 2, token: buf)))
  puts(peer_batch_sum(PeerBatch(n_tokens: 3, token: params.user_data)))
end
"""
    result = agentica("--schedulers", schedulers, program(tmp_path, STRUCT_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "PeerPair(x: 3, y: -4)",
        "PeerPair(x: -4, y: 2147483647)",
        "-2147483649",
        "PeerPair(x: -4, y: 3)",
        "PeerMixed(n: 42, x: 4.5)",
        "PeerMixed(n: 84, x: 2.25)",
        "PeerQuad(a: 3.5, b: 0.75, c: 1.5, d: 2.25)",
        "8.0",
        "n_ctx=512 threads=4 seed=-1 rope=10000.50 yarn=0.250 mmap=1 emb=0 data=static",
        "[true, false, false]",
        "n_ctx=4096 threads=4 seed=9000000000 rope=10000.50 yarn=1.500 mmap=0 emb=1 data=static",
        "n_ctx=4096 threads=-8 seed=9000000000 rope=10000.50 yarn=1.500 mmap=0 emb=1 data=null",
        "PeerNested(at: PeerPair(x: 10, y: 11), mixed: PeerMixed(n: 12, x: 5.0), flag: true)",
        "PeerNested(at: PeerPair(x: 11, y: 1), mixed: PeerMixed(n: 13, x: 10.0), flag: false)",
        "3", "42", "3", "18", "",
    ]


# What C cannot take in a struct field stops the run at the extern function before C runs, as for an argument: a
# C.Int32 field outside 32 bits, signed or unsigned (a nested one too) and a freed owned buffer in a C.Pointer field.
@NATIVE_CALLS
@pytest.mark.parametrize("call, code", [
    ("peer_pair_sum(PeerPair(x: 4_294_967_296, y: 0))", "RUNTIME-INTEGER-OVERFLOW"),
    ("peer_nested_bump(peer_nested_make(1).with(mixed: PeerMixed(n: -2_147_483_649, x: 0.0)))",
     "RUNTIME-INTEGER-OVERFLOW"),
    ("peer_batch_sum(PeerBatch(n_tokens: 1, token: freed))", "RUNTIME-NATIVE-CLOSED"),
])
def test_what_c_cannot_take_in_a_struct_field_stops_the_run(tmp_path, peer, call, code):
    main = "def main() -> Void\n  freed = Native.memory_pointer(4)\n  Native.free(freed)\n  %s\n  puts(1)\nend\n" % call
    refused_at_extern(tmp_path, peer, STRUCT_EXTERN, main, call, code)


# A compute call holds the owned buffer in a C.Pointer field of its struct argument, as it holds a C.Pointer argument:
# a free while C still reads the memory only marks the buffer freed.
@NATIVE_CALLS
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_compute_call_keeps_the_buffer_of_a_struct_field(tmp_path, peer, schedulers):
    main = """def sum_later(buf: C.Pointer) -> Result[Int]
  return ok(peer_batch_hold(PeerBatch(n_tokens: 64, token: buf), 20_000))
end

def main() -> Void
  buf = Native.memory_pointer(256)
  for k in 0...64
    Native.put_int32(buf, k * 4, 2)
  end
  task = Task.spawn(&sum_later, buf)
  n = 0
  while peer_res_holding() == 0 and n < 2000
    Task.sleep(1)
    n += 1
  end
  Native.free(buf)
  peer_set_flag()
  puts(Task.await(task))
end
"""
    result = agentica("--schedulers", schedulers, program(tmp_path, STRUCT_EXTERN.format(library=literal(peer)) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "ok(128)\n", "")


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
    puts(abs(4_294_967_296))
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
# test file that declares extern functions is a file error, and the other files still run, under --sandbox too. The
# runner treats every flag alike, and test_deny_native_refuses_the_program_at_load shows that each one turns on
# --deny-native, so the direct flag and the one that turns on all of them are enough here.
@NATIVE_CALLS
@pytest.mark.parametrize("flag", ["--deny-native", "--sandbox"])
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
# rows that a select reads back; bad SQL gives SQLITE_ERROR, its message, and a NULL Stmt, a closed resource. SQL of
# only a comment is SQLITE_OK with a NULL Stmt too, which Native.closed? tells apart before the step (#672). An open
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
  if Native.closed?(prepared.stmt)
    return -1
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
  puts(run(db, "-- only a comment"))
  query = sqlite3_prepare_v2(db, "select id, name from t order by id", -1)
  puts(query.result)
  while sqlite3_step(query.stmt) == SQLITE_ROW
    puts("#{sqlite3_column_int(query.stmt, 0)} #{sqlite3_column_text(query.stmt, 1)}")
  end
  Native.close(query.stmt)
  bad = sqlite3_prepare_v2(db, "select from nowhere", -1)
  puts([bad.result, sqlite3_errcode(db)])
  puts(sqlite3_errmsg(db).end_with?("syntax error"))
  puts(Native.closed?(bad.stmt))
  Native.close(bad.stmt)
  puts(Native.closed?(db))
  Native.close(db)
  puts(Native.closed?(db))
  IO.inspect(open("/no/such/dir/x.db"))
end
"""
    result = agentica(program(tmp_path, "SQLITE_OK = 0\nSQLITE_ROW = 100\n\n" + SQLITE_OUT_EXTERN + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "101", "101", "101", "-1", "0", "1 one", "2 two", "[1, 1]", "true", "true", "false", "true", "14",
        'error("sqlite open: 14")', "",
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
# message to an out pointer, which get_string reads and sqlite3_free
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
  puts(Native.get_bytes(sqlite3_column_blob(query, 0), 0, sqlite3_column_bytes(query, 0)))
  puts(Native.get_string(sqlite3_column_text(query, 1), 0, sqlite3_column_bytes(query, 1)))
  puts(Native.get_string(sqlite3_column_text(query, 1), 0))
  puts(sqlite3_step(query))
  puts([Native.null?(sqlite3_column_blob(query, 0)), Native.null?(sqlite3_column_text(query, 1))])
  Native.close(query)
  empty = sqlite3_prepare_v2(db, "select x''", -1).stmt
  puts(sqlite3_step(empty))
  blob_at = sqlite3_column_blob(empty, 0)
  puts(Native.null?(blob_at))
  puts(Native.get_bytes(blob_at, 0, sqlite3_column_bytes(empty, 0)))
  Native.close(empty)
  failed = sqlite3_exec(db, "select from nowhere", Native.null(), Native.null())
  puts(failed.result)
  puts(Native.get_string(failed.errmsg, 0).end_with?("syntax error"))
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
