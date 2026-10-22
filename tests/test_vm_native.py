"""Native calls (the extern blocks of docs/grammar/05-syntax.md and 06d-io-and-network.md) through the product CLI.

The peer is tests/fixtures/native/peer.c, built with the system C compiler into a shared library for each module run,
so every C type crosses a real ABI. Native calls exist on Linux x86_64 only for now: elsewhere a program that declares
extern functions is refused at load with RUNTIME-NATIVE-UNSUPPORTED, which test_other_systems_refuse_extern_at_load
checks, and the call cases skip with the port issue (#548). Tests assert codes and spans, never messages (AGENTS.md).
"""
import json
import platform
import subprocess

import pytest

from tests.agentica_test import FIXTURES, TARGET_OS, cli, known_issue, run, tool, vm_environment

NATIVE = TARGET_OS.startswith("linux") and platform.machine() == "x86_64"
ON_LINUX_ONLY = known_issue(not NATIVE, 548, "native calls are built on Linux x86_64 only")

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


def shared_library(tmp_path_factory, name):
    """Build tests/fixtures/native/NAME.c into a shared library and return its absolute path."""
    out = tmp_path_factory.mktemp("native") / ("lib%s.so" % name)
    subprocess.run([tool("cc"), "-shared", "-fPIC", "-O1", "-o", str(out), str(FIXTURES / "native" / (name + ".c"))],
                   check=True)
    return out


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    """The path of the peer library, built once for the module."""
    return shared_library(tmp_path_factory, "peer")


def program(tmp_path, text, name="program.agc"):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def agentica(*words, **options):
    return run(cli() + [str(word) for word in words], env=vm_environment(), **options)


def diagnostic(result, status):
    """The code and the start (line, column) of the JSON diagnostic of a run that ended with STATUS."""
    assert result.code == status, result.stdout + result.stderr
    found = json.loads(result.stderr.strip().split("\n")[-1])
    return found["code"], (found["range"]["start"]["line"], found["range"]["start"]["column"])


@ON_LINUX_ONLY
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
    result = agentica(program(tmp_path, PEER_EXTERN.format(library=peer) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == [
        "42", "-2147483648", "9000000000", "-3.0", "true", "false", "6", "ABC", "2", "0", "a�b", "9000000036",
        "1015.5", "FN", "",
    ]


@ON_LINUX_ONLY
def test_an_extern_function_is_exported_and_imported_like_any_function(tmp_path, peer):
    raw = PEER_EXTERN.format(library=peer).replace("  def peer_add(", "  export def peer_add(")
    program(tmp_path, raw.rstrip("\n") + "\n", "raw.agc")
    main = program(tmp_path, 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.peer_add(1, 2))\nend\n')
    result = agentica(main)
    assert (result.code, result.stdout, result.stderr) == (0, "3\n", "")


@ON_LINUX_ONLY
def test_a_system_library_is_found_by_its_name(tmp_path):
    text = 'extern "libm.so.6"\n  def pow(x: C.Double, y: C.Double) -> C.Double\nend\n\n' \
           'def main() -> Void\n  puts(pow(2.0, 10.0))\nend\n'
    result = agentica(program(tmp_path, text))
    assert (result.code, result.stdout) == (0, "1024.0\n")


@ON_LINUX_ONLY
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
    result = agentica("--schedulers", "4", program(tmp_path, PEER_EXTERN.format(library=peer) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "1600\n", "")


COMPUTE_EXTERN = """extern "{library}"
  compute def peer_wait_flag(limit_ms: C.Int) -> C.Int
  def peer_set_flag() -> Void
  def peer_returned() -> C.Int
  compute def peer_word(n: C.Int) -> C.String
  compute def peer_half(n: C.Int64) -> C.Double
  compute def peer_bump() -> Void
  def peer_bumps() -> C.Int
end

"""


# The compute call returns 1 only once main's fast call has set the flag. On one scheduler that proves the waiting task
# gave the scheduler to main; a call that held it would return 0 after 20 seconds.
@ON_LINUX_ONLY
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
    result = agentica("--schedulers", schedulers, program(tmp_path, COMPUTE_EXTERN.format(library=peer) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "1\n1\nccc\n2.5\n", "")


# A cancelled task stops waiting at once; its call runs on to its end, and the result is dropped.
@ON_LINUX_ONLY
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
  while peer_returned() == 0
    Task.sleep(1)
  end
  Task.sleep(20)
  puts(peer_word(3))
end
"""
    result = agentica("--schedulers", schedulers, program(tmp_path, COMPUTE_EXTERN.format(library=peer) + main))
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.split("\n") == ['error("task: cancelled")', "0", "ddd", ""]


@ON_LINUX_ONLY
def test_many_compute_calls_at_once(tmp_path, peer):
    main = """def work(n: Int) -> Float
  return peer_half(n) + peer_word(n).size.to_f
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
    result = agentica("--schedulers", "4", program(tmp_path, COMPUTE_EXTERN.format(library=peer) + main))
    assert (result.code, result.stdout, result.stderr) == (0, "10650.0\n", "")


@ON_LINUX_ONLY
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

extern "libc.so.6"
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
    assert diagnostic(agentica("--json", program(tmp_path, text), case), 1) == (code, (line, 3))


@ON_LINUX_ONLY
def test_a_library_with_an_unbound_symbol_is_a_load_error_and_keeps_earlier_output(tmp_path, tmp_path_factory):
    library = shared_library(tmp_path_factory, "unbound")
    text = 'extern "%s"\n  def unbound_call() -> C.Int\nend\n\n' \
           'def main() -> Void\n  puts("before")\n  puts(unbound_call())\nend\n' % library
    result = agentica("--json", program(tmp_path, text))
    assert result.stdout == "before\n"
    assert diagnostic(result, 1) == ("RUNTIME-NATIVE-LOAD", (2, 3))


EXTERN_FIRST = """def main() -> Void
  puts("started")
  puts(abs(-1))
end

extern "libc.so.6"
  def abs(n: C.Int) -> C.Int
end
"""


# Native code could start programs itself, so any --deny-* flag turns on --deny-native.
@ON_LINUX_ONLY
@pytest.mark.parametrize("flag", ["--deny-native", "--deny-run"])
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


@pytest.mark.parametrize("flag", ["--deny-native", "--deny-run"])
def test_test_refuses_deny_native(tmp_path, flag):
    # In front of `test` or after it, the same refusal: no report, exit 2.
    for words in ([flag, "test"], ["test", flag], ["--json", "test", flag]):
        result = agentica(*words, cwd=tmp_path)
        assert (result.code, result.stdout) == (2, ""), words
