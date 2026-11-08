"""Time.monotonic_ns against Python's clock, and short timeouts measured with it, on every system."""
import pytest

from tests.agentica_test import FIXTURES, PYTHON, compile_agc, run, run_vm, vm_binary, vm_environment


def test_monotonic_ns_reads_the_same_clock_as_python(tmp_path):
    bytecode = compile_agc(FIXTURES / "monotonic-peer.agc", tmp_path / "monotonic-peer.agcb")
    result = run([PYTHON, FIXTURES / "monotonic-peer.py", vm_binary(), bytecode])
    assert result.code == 0, result.stderr
    assert result.stdout.strip() == "ok"


@pytest.mark.parametrize("coarse", ["1", "0"])
@pytest.mark.parametrize("schedulers", ["1", "2"])
def test_short_timeouts_never_end_before_their_time_on_a_busy_scheduler(tmp_path, schedulers, coarse):
    # On Linux the event loop's clock is the coarse one (a tick behind) where an exact read is a system call;
    # AGENTICA_VM_TEST_COARSE_CLOCK forces either mode on any host (elsewhere the clock is always exact). A job timer
    # without its tick of padding fails here at one scheduler in the coarse mode.
    bytecode = compile_agc(FIXTURES / "timeouts-not-early.agc", tmp_path / "timeouts-not-early.agcb")
    env = vm_environment({"AGENTICA_VM_TEST_COARSE_CLOCK": coarse})
    result = run_vm(bytecode, "--schedulers", schedulers, env=env)
    assert result.code == 0, result.stderr
    assert result.stdout.strip() == "ok"
