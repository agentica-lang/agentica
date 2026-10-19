"""When a child process must be gone: the owner ends, the run is stopped, the driver of a VM dies.

On Linux, macOS and Windows, with the Python peer (fixtures/process-peer.py) as the child and process_alive to see
that it is gone. Windows ends a stopped run with Ctrl+Break and ends the direct children of a killed VM through libuv's
job object (docs/vm/10-io-processes.md, 10.4); a VM that is killed outright leaves its children running on Linux and
macOS, which is why the last case kills the driver of a VM, not the VM.
"""
import os
import signal
import subprocess

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, compile_agc, kill_process, process_alive, scaled, start_vm, vm_binary,
                                 wait_until)

PEER = FIXTURES / "process-peer.py"
NEW_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
WAIT = scaled(20)

# The python path and the peer reach the programs as arguments, so no path is written in the source.
OWNER_PROGRAM = """\
def owner(args: List[String]) -> String
  p = Result.unwrap!(Process.spawn(args[0], [args[1], "hold"], 5000))
  return Result.unwrap!(Process.read_line(p, 5000))
end

def main() -> Void
  puts(Task.await(Task.spawn(&owner, System.args())))
  IO.flush()
  Task.sleep(60000)
end
"""

HOLD_PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.spawn(args[0], [args[1], "hold"], 5000))
  puts(Result.unwrap!(Process.read_line(p, 5000)))
  IO.flush()
  Task.sleep(60000)
end
"""

# The child VM of the driver: prints its own pid, then the pid of the peer it starts.
CHILD_VM_PROGRAM = """\
def main() -> Void
  args = System.args()
  puts(System.pid())
  p = Result.unwrap!(Process.spawn(args[0], [args[1], "hold"], 5000))
  puts(Result.unwrap!(Process.read_line(p, 5000)))
  IO.flush()
  Task.sleep(60000)
end
"""

# A VM started with --driver-pid reads only a private file (owner only), which create_private makes.
DRIVER_PROGRAM = """\
def copy_private(source: String, target: String) -> Void
  input = Result.unwrap!(File.open(source, "read", 5000))
  out = Result.unwrap!(File.open(target, "create_private", 5000))
  bytes = Result.unwrap!(File.read_bytes(input, 1048576, 5000))
  Result.unwrap!(File.write_bytes(out, bytes, 5000))
  Result.unwrap!(File.close(input, 5000))
  Result.unwrap!(File.close(out, 5000))
end

def main() -> Void
  args = System.args()
  copy_private(args[1], args[2] + "/child.agcb")
  words = ["run", "--allow-run", "--driver-pid", String.from_int(System.pid()), "--", args[2] + "/child.agcb", args[3], args[4]]
  p = Result.unwrap!(Process.spawn_captured(args[0], words, ".", 5000))
  puts(Result.unwrap!(Process.read_line(p, 20000)))
  puts(Result.unwrap!(Process.read_line(p, 20000)))
  IO.flush()
  Task.sleep(60000)
end
"""


def bytecode(text, tmp_path, name):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, tmp_path / (name + ".agcb"))


def gone(pid):
    return wait_until(lambda: not process_alive(pid), WAIT, 0.1)


def test_a_child_is_closed_when_the_task_that_owns_it_ends(adopt, request, tmp_path):
    vm = adopt(start_vm(bytecode(OWNER_PROGRAM, tmp_path, "owner"), PYTHON, PEER, flags=["--allow-run"]))
    pid = vm.next_line(WAIT).strip()
    request.addfinalizer(lambda: kill_process(pid))
    assert gone(pid)
    assert vm.process.poll() is None  # the run goes on: only the child was closed


def test_a_stop_signal_ends_the_run_and_its_children(adopt, request, tmp_path):
    vm = adopt(start_vm(bytecode(HOLD_PROGRAM, tmp_path, "hold"), PYTHON, PEER, flags=["--allow-run"],
                        creationflags=NEW_GROUP))
    pid = vm.next_line(WAIT).strip()
    request.addfinalizer(lambda: kill_process(pid))
    assert process_alive(pid)
    if os.name == "nt":
        vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    else:
        os.kill(vm.process.pid, signal.SIGTERM)
    vm.wait(WAIT)
    assert gone(pid)


def test_a_vm_and_its_child_end_when_their_driver_is_killed(adopt, request, tmp_path):
    child = bytecode(CHILD_VM_PROGRAM, tmp_path, "child")
    (tmp_path / "private").mkdir()
    driver = adopt(start_vm(bytecode(DRIVER_PROGRAM, tmp_path, "driver"), vm_binary(), child, tmp_path / "private",
                            PYTHON, PEER, flags=["--allow-run"]))
    vm_pid = driver.next_line(WAIT).strip()
    request.addfinalizer(lambda: kill_process(vm_pid))
    peer_pid = driver.next_line(WAIT).strip()
    request.addfinalizer(lambda: kill_process(peer_pid))
    assert process_alive(vm_pid) and process_alive(peer_pid)
    driver.process.kill()
    driver.wait(WAIT)
    assert gone(vm_pid), "the VM outlived its driver"
    assert gone(peer_pid), "the child of that VM outlived it"
