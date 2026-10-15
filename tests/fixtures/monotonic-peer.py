#!/usr/bin/env python3
"""Peer for Time.monotonic_ns: compares the VM's clock with Python's.

monotonic-peer.py VM BYTECODE  runs `VM -- BYTECODE`, whose program prints two
Time.monotonic_ns readings around Task.sleep(20), and exits 1 with a message on
a mismatch. On Linux both clocks are CLOCK_MONOTONIC, so the readings must lie
between two time.monotonic_ns() readings taken around the run. Standard library
only.
"""
import subprocess
import sys
import time

# The loop calls uv_update_time before it starts a timer, so a timer fires early
# by under 1 ms of truncation, plus any lag of libuv's coarse clock.
MARGIN_NS = 5_000_000
SLEEP_NS = 20_000_000


def fail(message):
    print("monotonic-peer: " + message, file=sys.stderr)
    sys.exit(1)


def main():
    if sys.platform != "linux":
        print("skip: the peer needs CLOCK_MONOTONIC (Linux)")
        return
    vm, bytecode = sys.argv[1], sys.argv[2]
    before = time.monotonic_ns()
    run = subprocess.run([vm, "--", bytecode], capture_output=True, text=True, timeout=60)
    after = time.monotonic_ns()
    if run.returncode != 0:
        fail("the VM exited %d: %s" % (run.returncode, run.stderr))
    lines = run.stdout.split()
    if len(lines) != 2 or not all(line.isdigit() for line in lines):
        fail("unexpected output: %r" % run.stdout)
    start, end = (int(line) for line in lines)
    if not (before - MARGIN_NS <= start <= end <= after + MARGIN_NS):
        fail("readings %d, %d are outside [%d, %d]" % (start, end, before, after))
    if end - start < SLEEP_NS - MARGIN_NS:
        fail("Task.sleep(20) took %d ns" % (end - start))
    print("ok")


main()
