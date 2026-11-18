"""benchmarks/run.py: every program of benchmarks/programs/ prints its .expected, so a VM change that alters an output
is a mismatch (exit 1). `make bench` does the timing; this runs each program once on each runner."""
import sys

from tests.agentica_test import ROOT, WINDOWS, binary, host_only, run

PROGRAMS = ROOT / "benchmarks" / "programs"


@host_only(WINDOWS, "benchmarks/run.py times dist/agentica through /usr/bin/time and POSIX paths")
def test_every_program_prints_its_golden():
    binary()
    result = run([sys.executable, str(ROOT / "benchmarks" / "run.py"), "--runs", "1", "--no-startup"], timeout=300)
    assert result.code == 0, result.stdout + result.stderr
    programs = len(list(PROGRAMS.glob("*.agc")))
    assert programs == len(list(PROGRAMS.glob("*.expected")))
    assert result.stdout.count("| exe |") == programs
    assert result.stdout.count("| vm |") == programs
