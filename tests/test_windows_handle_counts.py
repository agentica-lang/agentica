r"""Handles of the VM on Windows: no path reaches the pipes it owns, and a finished file call frees its handle.

The POSIX cases list /proc/self/fd (/dev/fd on macOS) from inside the program; Windows has no such folder. Here the
test reads from outside what a folder would show: the named pipes of the process (the uv\<address>-<pid> pipes that
libuv makes for a child's standard streams, listed in \\.\pipe\) and its handle count (GetProcessHandleCount).
"""
import os

import pytest

from tests.agentica_test import PYTHON, compile_agc, output_lines, scaled, start_vm
from tests.windows_support import process_handle_count

pytestmark = pytest.mark.skipif(os.name != "nt", reason="host-only: named pipes and handle counts exist on Windows only")

WAIT = scaled(20)
PIPE_FOLDER = "\\\\.\\pipe"

# Holds a child with piped standard streams (three libuv pipes), waits for the list of their names, tries to read and
# to open each one as a file in three spellings, then spawns once more: a file call that had taken hold of one of the
# VM's pipes would leave this spawn or the first child without an answer.
PIPES_PROGRAM = r"""def wait_for(path: String) -> Bool
  tries = 0
  while tries < 1500
    if File.read_text(path, 1000).ok?
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def main() -> Void
  args = System.args()
  hold = Process.spawn(args[1], ["-c", "import time; time.sleep(3)"], 1000).unwrap!
  puts("ready")
  IO.inspect(wait_for(args[0]))
  for path in File.read_text(args[0], 100000).unwrap!.split("\n")
    if path != ""
      IO.inspect([File.read_text(path, 100).ok?, File.open(path, "append", 100).ok?])
    end
  end
  IO.inspect(Process.wait(hold, 10000))
  next_one = Process.spawn(args[1], ["-c", "pass"], 1000).unwrap!
  IO.inspect(Process.wait(next_one, 10000))
end
"""

# Runs File.each_line over and over (warm first, so threads and caches already exist), and stops at two gates that
# the test opens with a file, so that it can read the handle count between them.
COUNT_PROGRAM = r"""def wait_for(path: String) -> Bool
  tries = 0
  while tries < 1500
    if File.read_text(path, 1000).ok?
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def scan(path: String) -> Result[Void]
  return File.each_line(path, 1024, 5000) do |line|
    if line == "stop"
      return error("stopped")
    end
    ok()
  end
end

def repeat(path: String, times: Int) -> Void
  count = 0
  while count < times
    scan(path)
    count = count + 1
  end
end

def main() -> Void
  args = System.args()
  repeat(args[1], 5)
  puts("warm")
  IO.inspect(wait_for(args[0] + "/go1"))
  repeat(args[1], 100)
  puts("done")
  IO.inspect(wait_for(args[0] + "/go2"))
end
"""


def vm_pipe_names(pid):
    r"""The names below \\.\pipe\ of the pipes that libuv made in the process `pid`: uv\<address>-<pid>."""
    return sorted(name for name in os.listdir(PIPE_FOLDER) if name.startswith("uv\\") and name.endswith("-%d" % pid))


def test_file_calls_cannot_name_the_vms_own_pipes_so_a_later_spawn_does_not_deadlock(tmp_path):
    source = tmp_path / "pipes.agc"
    source.write_text(PIPES_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "pipes.agcb")
    names_file = tmp_path / "names.txt"
    vm = start_vm(bytecode, names_file, PYTHON, flags=("--allow-run",))
    try:
        assert vm.next_line(WAIT) == "ready"
        names = vm_pipe_names(vm.process.pid)
        assert names, "the child's standard streams are pipes of the VM: %s" % os.listdir(PIPE_FOLDER)
        paths = []
        for name in names:
            paths += ["\\\\.\\pipe\\" + name, "//./pipe/" + name.replace("\\", "/"), "\\\\?\\pipe\\" + name]
        partial = tmp_path / "names.tmp"
        partial.write_text("\n".join(paths) + "\n", encoding="utf-8")
        os.replace(partial, names_file)
        assert vm.wait(WAIT) == 0, vm.stderr_text()
        lines = output_lines(vm.stdout_text())
    finally:
        vm.stop()
    assert lines[0] == "true"
    assert lines[1:-2] == ["[false, false]"] * len(paths), "every spelling of every pipe is refused"
    assert lines[-2:] == ["ok(0)", "ok(0)"], "the child that held the pipes and the next spawn both end"


@pytest.mark.parametrize("data", (b"a\nb\n", b"a\nstop\nc\n"), ids=("clean", "block-error"))
def test_each_line_frees_its_handle_on_every_return_path(tmp_path, data):
    source = tmp_path / "count.agc"
    source.write_text(COUNT_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "count.agcb")
    target = tmp_path / "case.txt"
    target.write_bytes(data)
    gates = tmp_path / "gates"
    gates.mkdir()
    vm = start_vm(bytecode, gates, target)
    try:
        assert vm.next_line(WAIT) == "warm"
        before = process_handle_count(vm.process.pid)
        (gates / "go1").write_text("go")
        assert vm.next_line(WAIT) == "true"
        assert vm.next_line(WAIT) == "done"
        after = process_handle_count(vm.process.pid)
        (gates / "go2").write_text("go")
        assert vm.next_line(WAIT) == "true"
        assert vm.wait(WAIT) == 0, vm.stderr_text()
    finally:
        vm.stop()
    # A call that kept its file would leave one more handle for each of the 100 calls; a few handles may come and go
    # (a pool thread starting), so the bound is far below that.
    assert after - before <= 10, "%d handles before the 100 calls, %d after" % (before, after)
