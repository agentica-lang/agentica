"""The children of the process cases of tests/test_vm_multicore.py: one program for every system, standard library
only.

    quiet          sleeps 60 s and prints nothing
    sleep          prints its process id, then sleeps 60 s
    cat            prints its process id, then copies each line of standard input to standard output
    watch PID      waits until process PID has ended (process_alive of tests/agentica_test.py), then prints "gone"
    channel        reads one byte of the child channel, prints "started", then sleeps 60 s
    record DIR     creates DIR/<its process id>, then sleeps for ever

The process id is os.getpid(): on Windows a venv's python.exe starts the real interpreter as its own child, inside a
job that ends it with the launcher, so the id printed is the one that must be gone when the VM kills its child.
The channel is the descriptor that AGENTICA_CHANNEL names first: "3" (a socket) on POSIX, "3,4" (the read pipe, then
the write pipe) on Windows.
"""
import os
import sys
import time


def main(mode, *rest):
    if mode == "quiet":
        time.sleep(60)
    elif mode == "sleep":
        print(os.getpid(), flush=True)
        time.sleep(60)
    elif mode == "cat":
        print(os.getpid(), flush=True)
        for line in sys.stdin:
            sys.stdout.write(line)
            sys.stdout.flush()
    elif mode == "watch":
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
        from tests.agentica_test import process_alive
        while process_alive(rest[0]):
            time.sleep(0.02)
        print("gone", flush=True)
    elif mode == "channel":
        os.read(int(os.environ["AGENTICA_CHANNEL"].split(",")[0]), 1)
        print("started", flush=True)
        time.sleep(60)
    elif mode == "record":
        open(os.path.join(rest[0], str(os.getpid())), "w").close()
        while True:
            time.sleep(0.1)
    else:
        sys.exit("unknown mode: " + mode)


if __name__ == "__main__":
    main(*sys.argv[1:])
