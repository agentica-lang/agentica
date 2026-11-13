"""DEBUG #1529: a stop signal after a task crash, at one and four schedulers (to be removed before a PR)."""
import os
import signal
import subprocess
import sys
import time

import pytest

from tests.agentica_test import compile_agc, start_vm

PROGRAM = """\
def worker(how: String) -> Void
  case how
    "crash" -> _ = [1][5]
    "warn" -> IO.warn("a line on stderr")
    _ -> nil
  end

end

def main() -> Void
  how = System.args()[0]
  downs: Channel[String] = Channel.new(1)
  t = Task.spawn do worker(how) end
  Task.monitor(t, downs) do |down| down.reason.to_s end
  downs.recv(5000).unwrap!
  puts("ready")
  IO.flush()
  Task.sleep(60000)
end
"""


def ps(pid):
    if sys.platform != "darwin":
        return ""
    out = subprocess.run(["ps", "-M", "-o", "pid,tid,sig,sigmask,sigcatch,sigignore", "-p", str(pid)],
                         capture_output=True, text=True)
    out2 = subprocess.run(["ps", "-o", "pid,pending,blocked,caught,ignored", "-p", str(pid)],
                          capture_output=True, text=True)
    return out.stdout + out.stderr + out2.stdout + out2.stderr


@pytest.mark.parametrize("schedulers", [1, 4])
@pytest.mark.parametrize("how", ["crash", "warn", "none"])
def test_term_after(tmp_path, adopt, how, schedulers):
    source = tmp_path / "program.agc"
    source.write_text(PROGRAM, encoding="utf-8")
    code = compile_agc(source, tmp_path / "program.agcb")
    vm = adopt(start_vm(code, how, flags=("--schedulers", str(schedulers)), env={"AGENTICA_VM_TRACE": "sched,io"}))
    assert vm.next_line(20) == "ready"
    report = ["before: " + ps(vm.process.pid)]
    os.kill(vm.process.pid, signal.SIGTERM)
    try:
        result = vm.process.wait(5)
    except subprocess.TimeoutExpired:
        report.append("hung: " + ps(vm.process.pid))
        if sys.platform == "darwin":
            report.append(subprocess.run(["sample", str(vm.process.pid), "1"], capture_output=True, text=True).stdout[:6000])
        os.kill(vm.process.pid, signal.SIGUSR1)
        time.sleep(1)
        report.append("after USR1: %s" % vm.process.poll())
        vm.process.kill()
        vm.process.wait()
        time.sleep(0.5)
        print("\n".join(report))
        print(vm.stderr_text()[-8000:])
        raise AssertionError("hung: %s at %d" % (how, schedulers))
    time.sleep(0.3)
    print("\n".join(report))
    print(vm.stderr_text()[-3000:])
    assert result == -signal.SIGTERM
