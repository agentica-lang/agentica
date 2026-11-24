"""A child for tests/test_process.py that reports what it was given, with the standard library only.

Modes: args (argv as one JSON line), env (the AGENTICA_* and PROBE_* variables as JSON), cwd (the working directory),
hold (prints its pid and waits; tests/test_process_lifecycle.py uses it), streams N (N bytes "o" on stdout, then
"err\n" on stderr, as bytes), family [stubborn | slow MARKER] (starts a Python child that sleeps, prints its pid and waits; see below).
For a child on a pty (tests/test_process_pty.py): tty (whether fds 0-2 are terminals, the size, whether /dev/tty
opens, the open fds above 2 and the blocked signals, as JSON), fds (the open fds above 2), winch (prints "ready",
waits for a line, then whether SIGWINCH came and runs `stty size`), password (getpass with echo off, then "got" and
the password).
"""
import getpass
import json
import os
import signal
import subprocess
import sys
import time

# UTF-8 and LF whatever the console code page, so the VM reads exactly what is written.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def hold():
    print(os.getpid(), flush=True)
    time.sleep(120)


def open_fds():
    found = []
    for fd in range(3, 256):
        try:
            os.fstat(fd)
            found.append(fd)
        except OSError:
            pass
    return found


def on_pty(mode):
    if mode == "tty":
        try:
            os.close(os.open("/dev/tty", os.O_RDWR))
            ctty = True
        except OSError:
            ctty = False
        size = os.get_terminal_size(0)
        print(json.dumps({"tty": [os.isatty(fd) for fd in range(3)], "size": [size.lines, size.columns],
                          "ctty": ctty, "fds": open_fds(),
                          "blocked": sorted(signal.pthread_sigmask(signal.SIG_BLOCK, []))}), flush=True)
    elif mode == "winch":
        came = []
        signal.signal(signal.SIGWINCH, lambda *_: came.append(1))
        print("ready", flush=True)
        input()
        print("winch", bool(came), flush=True)
        subprocess.run(["stty", "size"], check=True)
    elif mode == "password":
        print("got", getpass.getpass("password: "), flush=True)


def main():
    mode = sys.argv[1]
    if mode in ("tty", "winch", "password"):
        on_pty(mode)
        return
    if mode == "fds":
        print(json.dumps(open_fds()), flush=True)
        return
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
        # stubborn: the grandchild ignores SIGTERM. slow MARKER: on SIGTERM it works 100 ms, writes MARKER and exits.
        handler = ""
        if sys.argv[2:3] == ["stubborn"]:
            handler = "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        elif sys.argv[2:3] == ["slow"]:
            handler = ("def done(*_):\n    time.sleep(0.1)\n    open(%r, 'w').write('done')\n    sys.exit(0)\n"
                       "signal.signal(signal.SIGTERM, done)\n" % sys.argv[3])
        code = "import signal, sys, time\n%sprint(flush=True)\ntime.sleep(120)\n" % handler
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
