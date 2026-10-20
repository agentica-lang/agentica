"""Time.monotonic_ns against Python's clock, on every system."""
from tests.agentica_test import FIXTURES, PYTHON, compile_agc, run, vm_binary


def test_monotonic_ns_reads_the_same_clock_as_python(tmp_path):
    bytecode = compile_agc(FIXTURES / "monotonic-peer.agc", tmp_path / "monotonic-peer.agcb")
    result = run([PYTHON, FIXTURES / "monotonic-peer.py", vm_binary(), bytecode])
    assert result.code == 0, result.stderr
    assert result.stdout.strip() == "ok"
