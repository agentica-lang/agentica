#!/usr/bin/env python3
"""Run a few chosen checks on the built binary, the steps of `make probe` (probe.yml runs it on the chosen systems).

    make probe TESTS="tests/test_vm_bits.py tests/test_process.py::test_name" [K="expr"] [TARGET="vm-test"]
               [PROGRAM=examples/hello.agc] [REPEAT=N] [SCHEDULERS=N]

The values come from the environment (make exports the variables of its command line to the recipe), never from a
shell line:

    TESTS       test modules (tests/test_<area>.py) or pytest node ids (tests/test_x.py::test_y), one pytest run
    K           a pytest -k expression for those tests
    TARGET      make targets and VAR=value words, run as `make WORD...` (letters, digits and ._/%+-,:= only)
    PROGRAM     an .agc file of the checkout, run with dist/agentica; its output goes to the log
    REPEAT      run the whole set this many times (1 to 100), stopping at the first round that fails
    SCHEDULERS  the scheduler count of every VM the checks start (AGENTICA_SCHEDULERS and
                AGENTICA_VM_TEST_MODULE_SCHEDULERS)

`probe.py --check` checks only the form of the values (probe.yml runs it before it builds anything). The JUnit files of
the tests and, on macOS, the crash reports of the run go to build/probe/, which probe.yml uploads when a check fails.
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "probe"
TEST_ITEM = re.compile(r"(tests/test_[A-Za-z0-9_]+\.py)(::\S+)?")
MAKE_WORD = re.compile(r"[A-Za-z0-9_./%+-]+|[A-Z][A-Z0-9_]*=[A-Za-z0-9_./%+,:=-]*")
# The run stops before the job's timeout-minutes in probe.yml, so the upload of build/probe/ still runs.
DEADLINE_MINUTES = float(os.environ.get("PROBE_MINUTES") or 30)


class Usage(Exception):
    pass


def settings(env, full):
    """The checked values of the environment; `full` also checks that the named files exist."""
    tests = env.get("TESTS", "").split()
    for item in tests:
        found = TEST_ITEM.fullmatch(item)
        if not found:
            raise Usage(f"TESTS: {item!r} is not tests/test_<area>.py or a node id of one")
        if found.group(1) in env.get("PROBE_ISOLATED", "").split():
            raise Usage(f"TESTS: {found.group(1)} is destructive: run make test-remove-actions in CI")
        if full and not (ROOT / found.group(1)).is_file():
            raise Usage(f"TESTS: {found.group(1)} does not exist")
    target = env.get("TARGET", "").split()
    for word in target:
        if not MAKE_WORD.fullmatch(word) or word.startswith("-"):
            raise Usage(f"TARGET: {word!r} is not a make target or VAR=value word")
    program = env.get("PROGRAM", "").strip()
    if program:
        path = (ROOT / program).resolve()
        if not program.endswith(".agc") or Path(program).is_absolute() or ROOT not in path.parents:
            raise Usage(f"PROGRAM: {program!r} is not an .agc file of the checkout")
        if full and not path.is_file():
            raise Usage(f"PROGRAM: {program} does not exist")
    repeat = env.get("REPEAT", "").strip() or "1"
    if not repeat.isdigit() or not 1 <= int(repeat) <= 100:
        raise Usage(f"REPEAT: {repeat!r} is not a number from 1 to 100")
    schedulers = env.get("SCHEDULERS", "").strip()
    if schedulers and (not schedulers.isdigit() or not 1 <= int(schedulers) <= 1024):
        raise Usage(f"SCHEDULERS: {schedulers!r} is not a number from 1 to 1024")
    if not (tests or target or program):
        raise Usage("nothing to run: give TESTS, TARGET or PROGRAM")
    return {"tests": tests, "k": env.get("K", "").strip(), "target": target, "program": program,
            "repeat": int(repeat), "schedulers": schedulers}


def pytest_runner(env):
    poetry = env.get("POETRY") or "poetry"
    if shutil.which(poetry):
        return [poetry, "run", "python", "-m", "pytest"]
    if env.get("CI"):
        raise Usage(f"{poetry} is required in CI")
    return [sys.executable, "-m", "pytest"]


def run(command, env, deadline):
    """Run one command in its own process group; kill the whole group when the deadline passes."""
    print("+ " + " ".join(command), flush=True)
    if os.name == "nt":
        child = subprocess.Popen(command, cwd=ROOT, env=env, creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
    else:
        child = subprocess.Popen(command, cwd=ROOT, env=env, start_new_session=True)
    try:
        return child.wait(timeout=max(1.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        print(f"probe: stopped after the {DEADLINE_MINUTES:g} min of PROBE_MINUTES", file=sys.stderr, flush=True)
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(child.pid)], check=False)
        else:
            os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        return 124


def crash_reports(since):
    """Copy the macOS crash reports written during the run (a VM that died of a signal) into build/probe/crash."""
    reports = Path.home() / "Library" / "Logs" / "DiagnosticReports"
    found = [p for p in reports.glob("*") if p.is_file() and p.stat().st_mtime >= since] if reports.is_dir() else []
    if found:
        (OUT / "crash").mkdir(parents=True, exist_ok=True)
        for report in found:
            shutil.copy2(report, OUT / "crash" / report.name)
        print(f"probe: {len(found)} crash report(s) in build/probe/crash: " + ", ".join(p.name for p in found))


def main(argv):
    try:
        probe = settings(os.environ, full=argv != ["--check"])
        if argv == ["--check"]:
            print("probe: the values are well formed")
            return 0
        if argv:
            raise Usage("the only option is --check")
        runner = pytest_runner(os.environ) if probe["tests"] else []
    except Usage as error:
        print(f"probe: {error}", file=sys.stderr)
        return 2

    env = dict(os.environ)
    # The fast tier, as `make test` runs it: a stray flag in the environment does not turn this into a slow run.
    env["AGENTICA_TEST_SLOW"] = ""
    if probe["schedulers"]:
        env["AGENTICA_SCHEDULERS"] = probe["schedulers"]
        env["AGENTICA_VM_TEST_MODULE_SCHEDULERS"] = probe["schedulers"]
    make = env.get("PROBE_MAKE") or "make"
    product = str(ROOT / (env.get("PROBE_PRODUCT") or "dist/agentica"))
    jobs = env.get("PROBE_JOBS") or str(os.cpu_count() or 1)
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    started, deadline = time.time(), time.monotonic() + DEADLINE_MINUTES * 60

    rows, failed = [], None
    for round_ in range(1, probe["repeat"] + 1):
        checks = []
        if probe["target"]:
            checks.append(("make " + " ".join(probe["target"]), [make, *probe["target"]]))
        if probe["tests"]:
            command = [*runner, *probe["tests"], "-v", "-rfE", f"--junitxml={OUT / f'round-{round_}.xml'}"]
            if probe["k"]:
                command += ["-k", probe["k"]]
            if jobs != "1":
                command += ["-n", jobs, "--dist", "worksteal"]
            checks.append(("pytest " + " ".join(probe["tests"]), command))
        if probe["program"]:
            checks.append(("agentica " + probe["program"], [product, probe["program"]]))
        for name, command in checks:
            print(f"::group::round {round_}/{probe['repeat']}: {name}" if env.get("GITHUB_ACTIONS") else
                  f"probe: round {round_}/{probe['repeat']}: {name}", flush=True)
            begun = time.monotonic()
            status = run(command, env, deadline)
            if env.get("GITHUB_ACTIONS"):
                print("::endgroup::", flush=True)
            rows.append((round_, name, status, time.monotonic() - begun))
            print(f"probe: round {round_}: {name}: exit {status} in {rows[-1][3]:.0f} s", flush=True)
            if status != 0 and failed is None:
                failed = round_
        if failed is not None:
            break

    crash_reports(started)
    verdict = (f"FAILED in round {failed} of {probe['repeat']}" if failed is not None
               else f"passed {probe['repeat']} round(s)")
    print(f"probe: {verdict}")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"### probe {env.get('PLATFORM', '')}: {verdict}\n\n| round | check | exit | seconds |\n"
                      "|---|---|---|---|\n")
            out.writelines(f"| {r} | `{n}` | {s} | {t:.0f} |\n" for r, n, s, t in rows)
    return 1 if failed is not None else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
