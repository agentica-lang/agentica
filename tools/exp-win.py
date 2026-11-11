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


def run(command, timeout=120, piped=False, **kwargs):
    """PIPED: stdin is a pipe closed at once with nothing written, as tests/agentica_test.py run() leaves it."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=timeout, stdin=None if piped else subprocess.DEVNULL,
                              input="" if piped else None, **kwargs)
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
                tails.append((code, (out + err)[-8000:]))
    say("%s: passed=%d failed=%d (%.0f s)" % (label, passed, failed, time.monotonic() - started))
    for code, tail in tails:
        say("%s failure (exit %r):\n%s" % (label, code, tail))


STEPS = ('import BDD from "std/bdd"\n\ndef main() -> Void\n  BDD.run([\n'
         '  BDD.step("{int} is small") do |ctx, args|\n    BDD.assert(ctx, args[0].to_i! < 5, "too big")\n  end,\n  ])\nend\n')
OUTLINE = ("Feature: Outline\n\n  Scenario Outline: row\n    Then <n> is small\n\n  Examples:\n"
           "    | kind   | n |\n    | sqlite | 2 |\n    | sqlite | 9 |\n")
NOISY = 'def main() -> Void\n  puts("x" * 3000)\n  IO.warn("warned")\n  System.exit(1)\nend\n'


def lost_output_loop(label, command, minutes, cwd=None, env=None, piped=False):
    """Runs COMMAND until MINUTES pass; counts (exit code, stdout empty?, stderr empty?) and keeps the odd runs."""
    counts = {}
    deadline = time.monotonic() + minutes * 60
    while time.monotonic() < deadline:
        code, out, err = run(command, cwd=cwd, env=env, piped=piped)
        key = (code, "out" if out else "NO-out", "err" if err else "NO-err")
        counts[key] = counts.get(key, 0) + 1
    say("%s: %r" % (label, sorted(counts.items(), key=str)))


def main():
    """Round 3: does a whole output vanish under load? The front end (check, test) and a plain program that prints on
    both streams and exits 1, each in a loop of its own, all at the same time."""
    import threading
    binary = sys.argv[1]
    minutes = 20
    project = Path(tempfile.mkdtemp(prefix="exp-cc-")) / "app"
    project.mkdir()
    (project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    (project / "main.agc").write_text(BROKEN_MAIN, encoding="utf-8")
    (project / "lib.agc").write_text(LIB, encoding="utf-8")
    suite = Path(tempfile.mkdtemp(prefix="exp-bdd-"))
    (suite / "steps.agc").write_text(STEPS, encoding="utf-8")
    (suite / "outline.feature").write_text(OUTLINE, encoding="utf-8")
    noisy = suite / "noisy.agc"
    noisy.write_text(NOISY, encoding="utf-8")
    # Round 4: as the test harness runs the binary: stdin a pipe closed at once, LC_ALL and LANG C.UTF-8, and for
    # `test` a TMPDIR of its own.
    env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
    test_env = dict(env, TMPDIR=tempfile.mkdtemp(prefix="exp-bdd-tmp-"))
    feature = [str(suite / "outline.feature"), "--steps", str(suite / "steps.agc")]
    jobs = [lambda: lost_output_loop("E9 check piped", [binary, "--json", "check", "main.agc"], minutes, cwd=project,
                                     env=env, piped=True),
            lambda: lost_output_loop("E9 type-at piped", [binary, "--json", "type-at", "main.agc:4:3"], minutes,
                                     cwd=project, env=env, piped=True),
            lambda: lost_output_loop("E10 test --json piped A", [binary, "test", "--json", *feature], minutes,
                                     env=test_env, piped=True),
            lambda: lost_output_loop("E10 test --json piped B", [binary, "test", "--json", *feature], minutes,
                                     env=test_env, piped=True),
            lambda: lost_output_loop("E11 noisy program piped", [binary, str(noisy)], minutes, env=env, piped=True),
            lambda: lost_output_loop("E12 test --json devnull", [binary, "test", "--json", *feature], minutes,
                                     env=test_env),
            lambda: pytest_loop("E3 #1332 bdd failed check", "tests/test_bdd.py::test_a_failed_check_points_at_its_"
                                "step_keyword_and_outline_rows_have_their_own_names", 400, 600)]
    threads = [threading.Thread(target=job) for job in jobs]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()


if __name__ == "__main__":
    main()
