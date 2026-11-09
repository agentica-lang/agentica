"""A child for tests/test_process.py that reports what it was given, with the standard library only.

Modes: args (argv as one JSON line), env (the AGENTICA_* and PROBE_* variables as JSON), cwd (the working directory),
hold (prints its pid and waits; tests/test_process_lifecycle.py uses it), streams N (N bytes "o" on stdout, then
"err\n" on stderr, as bytes), family [stubborn] (starts a Python child that sleeps, ignoring SIGTERM if stubborn, prints its pid and waits).
"""
import json
import os
import subprocess
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
    elif mode == "family":
        # The grandchild prints a line once it is set up, so the pid printed here is of a process that already ignores
        # SIGTERM when "stubborn" is given.
        ignore = "signal.signal(signal.SIGTERM, signal.SIG_IGN); " if sys.argv[2:] == ["stubborn"] else ""
        code = "import signal, time; %sprint(flush=True); time.sleep(120)" % ignore
        child = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE)
        child.stdout.readline()
        print(child.pid, flush=True)
        child.wait()
    elif mode == "streams":
        sys.stdout.buffer.write(b"o" * int(sys.argv[2]))
        sys.stdout.buffer.flush()
        sys.stderr.buffer.write(b"err\n")
        sys.stderr.buffer.flush()
    else:
        sys.exit(2)


main()
