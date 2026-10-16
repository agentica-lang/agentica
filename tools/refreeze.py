#!/usr/bin/env python3
"""Rewrite the frozen goldens of the Agentica front end from what the Agentica stages print, and show what changed.

The goldens in tests/fixtures/frontend/frozen/ (manifests of hashes and small `.expected` files) and the goldens next to
the fixtures (tests/fixtures/frontend/{lexer,parser,modules,check,lower,catalog}/) were first written from the Racket front
end. A change of a compiler/ stage that changes its output on purpose is frozen with this tool (`make goldens` runs it
with --fast-only):

    python3 tools/refreeze.py                  # every stage, fast and slow tier
    python3 tools/refreeze.py --stage lower    # one stage (repeat or comma-separate for several)
    python3 tools/refreeze.py --fast-only      # only the fast tier (the manifests of the slow tier stay as they are)

It runs the unittest modules tests/test_frontend_<stage>.py with AGENTICA_REFREEZE=1. In that mode a comparison with a
golden rewrites the golden from the Agentica output instead of failing (tests/frontend_support.py), and logs what changed.
The tool prints the log as a summary: for a manifest, each entry whose output hash, size or input hash changed, was added
or was removed; for a text golden, a unified diff. Then read `git diff` before committing: the tool freezes whatever the
stages print, so a regression is frozen the same way as a fix. Every other assertion of the tests (the shape checks
such as "this input is a too-deep error") still runs and still fails the stage.

The tier follows the tests: the slow cases are the ones marked @slow, which run only with AGENTICA_TEST_SLOW=1 (set here
unless --fast-only is given). The tool needs only the Python standard library and the product CLI the tests already use.
"""
import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STAGES = ["lexer", "parser", "modules", "check", "lower", "catalog", "bytecode"]

# One stage with the whole slow tier can take many minutes; a stage that runs longer than this is stopped.
STAGE_TIMEOUT = 3600


def run_stage(stage, fast_only):
    """Run one stage in refreeze mode. Gives (return code, tail of the output, list of logged records)."""
    with tempfile.TemporaryDirectory(prefix="agentica-refreeze-") as directory:
        log = Path(directory) / "log.jsonl"
        env = dict(os.environ, AGENTICA_REFREEZE="1", AGENTICA_REFREEZE_LOG=str(log), TMPDIR=directory)
        if fast_only:
            env.pop("AGENTICA_TEST_SLOW", None)
        else:
            env["AGENTICA_TEST_SLOW"] = "1"
        try:
            result = subprocess.run([sys.executable, "-m", "unittest", "tests.test_frontend_" + stage],
                                    cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                    timeout=STAGE_TIMEOUT)
            code, output = result.returncode, result.stdout
        except subprocess.TimeoutExpired as expired:
            code, output = 1, "stopped after %d seconds\n%s" % (STAGE_TIMEOUT, expired.stdout or "")
        records = []
        if log.exists():
            records = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines() if line]
    return code, output, records


def count_skips(output):
    """(tests run, tests skipped) from the end of a unittest run, or (0, 0) when the summary is not there."""
    ran = re.search(r"^Ran (\d+) tests? in ", output, re.MULTILINE)
    skipped = re.search(r"^(?:OK|FAILED) \(.*\bskipped=(\d+)", output, re.MULTILINE)
    return (int(ran.group(1)) if ran else 0, int(skipped.group(1)) if skipped else 0)


def describe_entry(entry):
    old, new = entry["old"], entry["new"]
    parts = []
    if old[0] != new[0]:
        parts.append("%d -> %d bytes" % (old[0], new[0]))
    if old[1] != new[1]:
        parts.append("output %s -> %s" % (old[1], new[1]))
    if old[2] != new[2]:
        parts.append("input %s -> %s" % (old[2], new[2]))
    return "  changed %s: %s" % (entry["key"], ", ".join(parts))


def summarize(record, diff_lines):
    """The lines that tell what a record of the log changed."""
    name = record["file"]
    if record.get("removed") is True:
        return ["%s: removed (no input is left for it)" % name]
    if "diff" in record:
        old, new = record["diff"]
        body = list(difflib.unified_diff(old.splitlines(), new.splitlines(), "before", "after", lineterm="", n=2))
        lines = ["%s: %d lines before, %d after" % (name, len(old.splitlines()), len(new.splitlines()))]
        shown = body[:diff_lines]
        lines += ["  " + line for line in shown]
        if len(body) > len(shown):
            lines.append("  ... %d more diff lines (git diff shows them)" % (len(body) - len(shown)))
        return lines
    lines = ["%s: %d changed, %d added, %d removed"
             % (name, len(record["changed"]), len(record["added"]), len(record["removed"]))]
    lines += [describe_entry(entry) for entry in record["changed"]]
    lines += ["  added " + key for key in record["added"]]
    lines += ["  removed " + key for key in record["removed"]]
    return lines


def parse_stages(values):
    stages = []
    for value in values or [",".join(STAGES)]:
        for stage in value.split(","):
            if stage not in STAGES:
                raise SystemExit("unknown stage %r; the stages are %s" % (stage, ", ".join(STAGES)))
            if stage not in stages:
                stages.append(stage)
    return stages


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--stage", action="append", help="a stage or a comma-separated list (default: all)")
    parser.add_argument("--fast-only", action="store_true", help="do not run the slow tier")
    parser.add_argument("--jobs", type=int, default=1, help="stages to run at a time")
    parser.add_argument("--diff-lines", type=int, default=40, help="most diff lines shown for one text golden")
    options = parser.parse_args(arguments)
    stages = parse_stages(options.stage)

    with ThreadPoolExecutor(max_workers=max(1, options.jobs)) as pool:
        results = list(pool.map(lambda stage: run_stage(stage, options.fast_only), stages))

    failed = False
    changed_files = 0
    for stage, (code, output, records) in zip(stages, results):
        print("== %s" % stage)
        for record in records:
            changed_files += 1
            print("\n".join(summarize(record, options.diff_lines)))
        ran, skipped = count_skips(output)
        if skipped:
            print("%d of %d tests were skipped (a tool the tests need is missing?); their goldens were not checked or "
                  "rewritten" % (skipped, ran))
        if ran and skipped == ran:
            # An empty log would read as "nothing changed" while nothing ran, so this is a failure, not a clean stage.
            failed = True
            print("every test of %s was skipped, so this stage froze nothing" % stage)
        elif not records:
            print("nothing changed")
        if code != 0:
            failed = True
            print("the tests of %s failed for another reason than a golden; the end of their output:" % stage)
            print("".join(output.splitlines(keepends=True)[-40:]))
    if failed:
        print("Some stages failed: the goldens they did reach were rewritten, the rest were not touched.")
        return 1
    print("%d golden file(s) rewritten. Read `git diff` before you commit." % changed_files)
    return 0


if __name__ == "__main__":
    sys.exit(main())
