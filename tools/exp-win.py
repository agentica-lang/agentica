"""Windows flake experiment (never merged): repeats the cases of #1335, #1098 and #1332 and counts what each saw.

usage: python tools/exp-win.py BIN   (run from the repository root, under `poetry run`)
"""
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CYGWIN_LINE = re.compile(r"^ *\d+ \[[^\]\n]*\] \S+ \(?\d+\)? ", re.M)


def run(command, timeout=120, **kwargs):
    try:
        done = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=timeout, stdin=subprocess.DEVNULL, **kwargs)
        return done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as expired:
        return "timeout", str(expired.stdout or ""), str(expired.stderr or "")


def say(text):
    print(text, flush=True)


def e1_process_close_crash(binary, reps):
    """#1335: process-close-crash.agc under --max-steps 20..115 (the golden takes 114); stderr lines a killed MSYS2 child wrote."""
    work = Path(tempfile.mkdtemp(prefix="exp-pcc-"))
    program = work / "pcc.agcb"
    code, _, err = run([binary, "compile", str(ROOT / "tests/fixtures/vm/process-close-crash.agc"), "-o", str(program)])
    assert code == 0, err
    counts = {"runs": 0, "step_limit": 0, "finished": 0, "other": 0, "cygwin_noise": 0}
    samples = []
    for _ in range(reps):
        for limit in range(20, 116):
            code, out, err = run([binary, "run", "--json", "--max-steps", str(limit), "--", str(program)], timeout=60)
            counts["runs"] += 1
            if "RUNTIME-STEP-LIMIT" in err:
                counts["step_limit"] += 1
            elif code == 0:
                counts["finished"] += 1
            else:
                counts["other"] += 1
                if len(samples) < 5:
                    samples.append((limit, code, err[-400:]))
            if CYGWIN_LINE.search(err):
                counts["cygwin_noise"] += 1
                if len(samples) < 5:
                    samples.append((limit, code, err[-400:]))
    say("E1 #1335 process-close-crash: %r" % counts)
    for sample in samples:
        say("E1 sample: %r" % (sample,))


BROKEN_MAIN = 'import {nothing_here} from "lib"\n\ndef main() -> Void\n  puts(1)\nend\n'
LIB = 'export def something() -> Int = 1\n'


def e2_lost_diagnostic(binary, reps):
    """#1098 (first case): a check, type-at or outline that exits 1 with an empty stderr."""
    project = Path(tempfile.mkdtemp(prefix="exp-cc-")) / "app"
    project.mkdir()
    (project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    (project / "main.agc").write_text(BROKEN_MAIN, encoding="utf-8")
    (project / "lib.agc").write_text(LIB, encoding="utf-8")
    for flags in ([], ["--no-cache"]):
        counts = {}
        samples = []
        for _ in range(reps):
            for words in (["check", "main.agc"], ["type-at", "main.agc:4:3"], ["outline", "main.agc"]):
                code, out, err = run([binary, "--json", *flags, *words], cwd=project)
                key = (words[0], code, "stderr" if err.strip() else "EMPTY-stderr")
                counts[key] = counts.get(key, 0) + 1
                if code == 1 and not err.strip() and len(samples) < 5:
                    samples.append((words, code, out[-300:]))
        say("E2 #1098 lost diagnostic %s: %r" % (flags or ["cache"], sorted(counts.items(), key=str)))
        for sample in samples:
            say("E2 sample: %r" % (sample,))


def pytest_loop(label, node, reps, timeout):
    """Runs one pytest node REPS times; prints the pass/fail count and the tail of the first failures."""
    passed = failed = 0
    tails = []
    started = time.monotonic()
    for _ in range(reps):
        code, out, err = run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-x", node],
                             timeout=timeout, cwd=ROOT)
        if code == 0:
            passed += 1
        else:
            failed += 1
            if len(tails) < 3:
                tails.append((code, (out + err)[-3000:]))
    say("%s: passed=%d failed=%d (%.0f s)" % (label, passed, failed, time.monotonic() - started))
    for code, tail in tails:
        say("%s failure (exit %r):\n%s" % (label, code, tail))


def main():
    """Round 2: the cases at the same time, so each one runs under the load of the others, as in the CI suite."""
    import threading
    binary = sys.argv[1]
    bdd = "tests/test_bdd.py::test_a_failed_check_points_at_its_step_keyword_and_outline_rows_have_their_own_names"
    kill = ("tests/test_bdd_integration.py::test_killing_the_driver_stops_the_runner_the_scenario_vm_and_the_program"
            "_and_a_later_run_removes_its_folder")
    jobs = [lambda: e1_process_close_crash(binary, 15), lambda: e1_process_close_crash(binary, 15),
            lambda: pytest_loop("E3 #1332 bdd failed check A", bdd, 150, 600),
            lambda: pytest_loop("E3 #1332 bdd failed check B", bdd, 150, 600),
            lambda: pytest_loop("E4 #1098 kill the driver", kill, 40, 600),
            lambda: pytest_loop("E5 #1098 check cache module", "tests/test_check_cache.py", 10, 1200)]
    threads = [threading.Thread(target=job) for job in jobs]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    e2_lost_diagnostic(binary, 100)


if __name__ == "__main__":
    main()
