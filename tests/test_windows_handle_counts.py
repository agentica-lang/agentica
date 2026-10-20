r"""Handles of the VM on Windows: no path reaches the pipes it owns, and a finished file call frees its handle.

The POSIX cases list /proc/self/fd (/dev/fd on macOS) from inside the program; Windows has no such folder. Here the
test reads from outside what a folder would show: the named pipes of the process (the uv\<address>-<pid> pipes that
libuv makes for a child's standard streams, listed in \\.\pipe\) and its handle count (GetProcessHandleCount).

Several layers refuse a path that names such a pipe: the device-namespace check of every file call (path_string in
vm/files.c, a contract error), the regular-file check, and the pipe itself (all its instances are busy). The pipe case
pins the first one by the text of its error, for the spellings that begin with \\.\ and \\?\ (without that check those
calls would still fail, one layer later, and a test of the outcome alone would pass). The other spellings (\\localhost\,
\\127.0.0.1\ and \??\) reach the later layers and are checked only by the fact that they fail.

A pipe that a test makes (NamedPipeServer) stands where POSIX tests have a FIFO. The VM does not stream a pipe as a file
on Windows: probe() in vm/files.c refuses every file that is not regular, a block device or a directory. The pipe
case below opens such a pipe by each call that waits on the loop for a FIFO, and checks that every call fails at once
(never as a timeout) and that the VM holds no handle of the pipe afterwards, which a FIFO test checks by the count of
descriptors.
"""
import errno
import os
from contextlib import ExitStack

import pytest

from tests.agentica_test import PYTHON, compile_agc, output_lines, scaled, start_vm
from tests.windows_support import NamedPipeServer, process_handle_count

pytestmark = pytest.mark.skipif(os.name != "nt",
                                reason="host-only: named pipes and handle counts exist on Windows only")

WAIT = scaled(20)
PIPE_FOLDER = "\\\\.\\pipe"
# The error of path_string (vm/files.c): the same contract text as every other bad path.
GUARD_ERROR = 'error("path->complete-path: contract violation'

# A gate for a program: true when the file `path` can be read, false after about 15 s.
WAIT_FOR = r"""def wait_for(path: String) -> Bool
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
"""

# Holds a child with piped standard streams (three libuv pipes) that waits for the end of its input, so the pipes live
# until the test says so. It waits for the list of their names, tries to read and to open each one as a file, prints
# both answers, and waits for a second gate before it ends the child and spawns once more: a file call that had taken
# hold of one of the VM's pipes would leave the first child or this spawn without an answer.
PIPES_PROGRAM = WAIT_FOR + r"""
def main() -> Void
  args = System.args()
  hold = Process.spawn(args[1], ["-c", "import sys; sys.stdin.read()"], 1000).unwrap!
  puts("ready")
  IO.inspect(wait_for(args[0]))
  for path in File.read_text(args[0], 100000).unwrap!.split("\n")
    if path != ""
      IO.inspect(File.read_text(path, 100))
      IO.inspect(File.open(path, "append", 100))
    end
  end
  puts("refused")
  IO.inspect(wait_for(args[2]))
  IO.inspect(Process.close_stdin(hold, 5000))
  IO.inspect(Process.wait(hold, 10000))
  next_one = Process.spawn(args[1], ["-c", "pass"], 1000).unwrap!
  IO.inspect(Process.wait(next_one, 10000))
end
"""

# Runs File.each_line over and over (warm first, so threads and caches already exist), and stops at two gates that
# the test opens with a file, so that it can read the handle count between them.
COUNT_PROGRAM = WAIT_FOR + r"""
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

# Opens each pipe that the test made with one call of the kind its argument names ("kind|path"; the calls that a FIFO
# parks on the loop), prints the answer of each, and waits for a gate so that the test can ask each pipe, while the VM is
# alive, whether the VM still holds it. A call that waited for the pipe would answer with a timeout after 5 s.
PIPE_FILE_PROGRAM = WAIT_FOR + r"""
def attempt(kind: String, path: String) -> Void
  if kind == "open-read"
    IO.inspect(File.open(path, "read", 5000))
  elsif kind == "open-write"
    IO.inspect(File.open(path, "write", 5000))
  else
    IO.inspect(File.read_text(path, 5000))
  end
end

def main() -> Void
  args = System.args()
  for item in args.drop(1)
    parts = item.split("|")
    attempt(parts[0], parts[1])
  end
  puts("refused")
  IO.inspect(wait_for(args[0]))
end
"""

# The two ways into probe(): a handle call opens in the pool (work_open), a whole-file call opens, then waits on the loop
# (on_loop). Reading and writing take different paths to the open.
PIPE_FILE_KINDS = ("open-read", "open-write", "read-text")
# The roots other than \\.\ and \\?\ (which path_string refuses) under which a path can name a pipe.
OTHER_ROOTS = ("\\\\localhost\\pipe\\", "\\\\127.0.0.1\\pipe\\", "\\??\\pipe\\")
# The two of them that go through Windows' file sharing and reach a pipe that a test made. The VM completes a \??\ path
# against the drive of the working directory (C:/??/pipe/...), so only this process reaches a pipe by it.
LOOPBACK_ROOTS = OTHER_ROOTS[:2]


def vm_pipe_names(pid):
    r"""The names below \\.\pipe\ of the pipes that libuv made in the process `pid`: uv\<address>-<pid>."""
    return sorted(name for name in os.listdir(PIPE_FOLDER) if name.startswith("uv\\") and name.endswith("-%d" % pid))


def spellings(name):
    """(guarded, others): the paths that name the pipe `name` ("uv\\<address>-<pid>") below the device namespace, which
    path_string refuses, and below the other roots a path can use to reach a pipe, which later layers refuse."""
    slashed = name.replace("\\", "/")
    guarded = ["\\\\.\\pipe\\" + name, "//./pipe/" + slashed, "\\\\?\\pipe\\" + name]
    others = [root + name for root in OTHER_ROOTS]
    return guarded, others


def python_reaches(root):
    """True when this process can open a pipe below `root` (the loopback spellings need Windows' file sharing)."""
    with NamedPipeServer() as pipe:
        try:
            with open(pipe.path(root), "r+b", buffering=0):
                return True
        except OSError:
            return False


def test_file_calls_cannot_name_the_vms_own_pipes_so_a_later_spawn_does_not_deadlock(tmp_path):
    source = tmp_path / "pipes.agc"
    source.write_text(PIPES_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "pipes.agcb")
    names_file = tmp_path / "names.txt"
    release = tmp_path / "release"
    vm = start_vm(bytecode, names_file, PYTHON, release, flags=("--allow-run",))
    try:
        assert vm.next_line(WAIT) == "ready"
        names = vm_pipe_names(vm.process.pid)
        assert names, "the child's standard streams are pipes of the VM: %s" % os.listdir(PIPE_FOLDER)
        guarded, others = [], []
        for name in names:
            one, two = spellings(name)
            guarded += one
            others += two
        partial = tmp_path / "names.tmp"
        partial.write_text("\n".join(guarded + others) + "\n", encoding="utf-8")
        os.replace(partial, names_file)
        assert vm.next_line(WAIT) == "true"
        answers = [vm.next_line(WAIT) for _ in range(2 * (len(guarded) + len(others)))]
        assert vm.next_line(WAIT) == "refused"
        # The child is still running, so its pipes are still there after every refusal.
        assert set(names) <= set(vm_pipe_names(vm.process.pid)), "the pipes outlive the refused calls"
        release.write_text("go")
        assert vm.wait(WAIT) == 0, vm.stderr_text()
        lines = output_lines(vm.stdout_text())
    finally:
        vm.stop()
    asked = guarded + others
    for number, path in enumerate(asked):
        read, opened = answers[2 * number], answers[2 * number + 1]
        if number < len(guarded):
            assert read.startswith(GUARD_ERROR) and opened.startswith(GUARD_ERROR), (path, read, opened)
        else:
            assert read.startswith("error(") and opened.startswith("error("), (path, read, opened)
    assert lines == ["true", "ok()", "ok(0)", "ok(0)"], "the child that held the pipes and the next spawn both end"


def test_a_named_pipe_is_refused_as_a_file_at_once_and_the_vm_holds_no_handle_of_it(tmp_path):
    source = tmp_path / "pipe-file.agc"
    source.write_text(PIPE_FILE_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "pipe-file.agcb")
    gate = tmp_path / "gate"
    # The first spelling that this process reaches; a machine without file sharing checks the refusal only.
    root = next((root for root in LOOPBACK_ROOTS if python_reaches(root)), None)
    if os.environ.get("CI"):
        assert root, "the runner serves no loopback pipe path, so the case would check only the refusal"
    reached = root is not None
    root = root or LOOPBACK_ROOTS[0]
    with ExitStack() as stack:
        cases = [(kind, root, stack.enter_context(NamedPipeServer())) for kind in PIPE_FILE_KINDS]
        vm = start_vm(bytecode, gate, *["%s|%s" % (kind, pipe.path(root)) for kind, root, pipe in cases])
        try:
            answers = [vm.next_line(WAIT) for _ in cases]
            assert vm.next_line(WAIT) == "refused"
            # Asked while the VM is alive: a handle that a call kept would show as a client that is still connected.
            states = [pipe.clients() for _, _, pipe in cases]
            gate.write_text("go")
            assert vm.next_line(WAIT) == "true"
            assert vm.wait(WAIT) == 0, vm.stderr_text()
        finally:
            vm.stop()
    for (kind, root, _), answer, state in zip(cases, answers, states):
        where = "%s below %s" % (kind, root)
        assert answer.startswith("error(") and "timed out" not in answer, (where, answer)
        assert "connected" not in state, "%s: the VM kept the pipe: %s" % (where, state)
        if reached:
            # The stat of the call takes one instance and the open another, which gets to probe() and its close: the
            # error is the ENOTSUP of probe (a busy pipe would say EBUSY), and both instances are let go.
            assert "errno=%d" % errno.ENOTSUP in answer, (where, answer)
            assert state.count("gone") >= 2, "%s: the VM reached the pipe and let go of it: %s" % (where, state)


@pytest.mark.parametrize("data", (b"a\nb\n", b"a\nstop\nc\n", b"a\n\xff\nb\n", b"a" * 2000 + b"\nshort\n"),
                         ids=("clean", "block-error", "invalid-utf8", "overlong-line"))
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
