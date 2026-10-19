"""A child for tests/test_process.py that reports what it was given, with the standard library only.

Modes: args (argv as one JSON line), env (the AGENTICA_* and PROBE_* variables as JSON), cwd (the working directory),
hold (prints its pid and waits; tests/test_process_lifecycle.py uses it).
"""
import json
import os
import sys
import time

# UTF-8 and LF whatever the console code page, so the VM reads exactly what is written.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def hold():
    print(os.getpid(), flush=True)
    time.sleep(120)


def main():
    mode = sys.argv[1]
    if mode == "args":
        print(json.dumps(sys.argv[2:], ensure_ascii=False), flush=True)
    elif mode == "env":
        shown = {k: v for k, v in os.environ.items() if k.upper().startswith(("AGENTICA", "PROBE_"))}
        print(json.dumps(shown, ensure_ascii=False, sort_keys=True), flush=True)
    elif mode == "cwd":
        print(os.getcwd(), flush=True)
    elif mode == "hold":
        hold()
    else:
        sys.exit(2)


main()
