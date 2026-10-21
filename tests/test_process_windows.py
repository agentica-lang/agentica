"""What libuv reports when the VM stops a child on native Windows.

There is no SIGTERM there: libuv ends the child with TerminateProcess (raw exit code 1) and remembers the signal that
was asked for, and `exited` in vm/process.c records 128 plus it. A program cannot read the status of a child it has
closed, so the `proc` trace line (raw status and signal) is the observation. The other systems skip the module with a host-only reason.
"""
import os
import re

import pytest

from tests.agentica_test import FIXTURES, compile_agc, scaled, start_vm, tool

pytestmark = pytest.mark.skipif(os.name != "nt", reason="host-only: libuv's Windows job object and handle codes exist on Windows only")

PEER = FIXTURES / "process-peer.js"

# The node path and the peer reach the program as arguments, so no path is written in the source.
PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.%s(args[0], [args[1], "hold"]%s, 5000))
  Process.read_line(p, 5000)
  Process.close(p)
  Task.sleep(1500)
end
"""


def exit_line(tmp_path, spawn, extra):
    source = tmp_path / "stop.agc"
    source.write_text(PROGRAM % (spawn, extra), encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / "stop.agcb")
    trace = tmp_path / "trace.txt"
    env = {"AGENTICA_VM_TRACE": "proc", "AGENTICA_VM_TRACE_FILE": trace}
    vm = start_vm(bytecode, tool("node"), PEER, env=env)
    try:
        assert vm.wait(scaled(30)) == 0
    finally:
        vm.stop()
    found = re.findall(r"exit pid=\d+ status=(-?\d+) signal=(\d+)", trace.read_text(encoding="utf-8"))
    assert len(found) == 1, trace.read_text(encoding="utf-8")
    return tuple(int(n) for n in found[0])


def test_a_plain_child_stopped_by_close_reports_raw_status_1_and_sigkill(tmp_path):
    assert exit_line(tmp_path, "spawn", "") == (1, 9)


def test_a_captured_child_stopped_by_close_reports_raw_status_1_and_sigterm(tmp_path):
    assert exit_line(tmp_path, "spawn_captured", ', "."') == (1, 15)
