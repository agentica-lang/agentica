"""The children of the process cases of tests/test_vm_multicore.py: one program for every system, standard library
only, which imports nothing of the tests.

    quiet          sleeps 60 s and prints nothing
    sleep          prints its process id, then sleeps 60 s
    cat            prints its process id, then copies each line of standard input to standard output
    watch PID      waits until process PID has ended, then prints "gone"
    channel        reads one byte of the child channel, prints "started", then sleeps 60 s
    record DIR     writes a count that grows every 50 ms to DIR/<its process id>, for ever

The tests run it on the base interpreter, never a venv's launcher, so os.getpid() is the id of the VM's child.
The channel is the descriptor that AGENTICA_CHANNEL names first: "3" (a socket) on POSIX, "3,4" (the read pipe, then
the write pipe) on Windows.
"""
import os
import sys
import time


def alive(pid):
    """True while process PID exists. POSIX: kill -0, so a zombie still counts as alive until its parent (the VM, whose
    libuv reaps its children) reaps it, as the sh watcher's `kill -0` did. Windows: the wait on the process handle,
    as process_alive in tests/agentica_test.py does."""
    if os.name != "nt":
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            pass  # it exists and belongs to someone else
        return True
    import ctypes
    from ctypes import wintypes

    api = ctypes.WinDLL("kernel32", use_last_error=True)
    open_process = api.OpenProcess
    open_process.restype = wintypes.HANDLE
    open_process.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    wait = api.WaitForSingleObject
    wait.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    api.CloseHandle.argtypes = (wintypes.HANDLE,)
    synchronize, query_limited, access_denied, wait_timeout = 0x00100000, 0x1000, 5, 0x102
    # A process that ended can still be opened while someone holds a handle to it, so the wait (signaled at its end)
    # tells whether it is alive, not the open.
    process = open_process(synchronize | query_limited, False, pid)
    if not process:
        return ctypes.get_last_error() == access_denied  # it exists and belongs to someone else
    try:
        return wait(process, 0) == wait_timeout
    finally:
        api.CloseHandle(process)


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
        pid = int(rest[0])
        while alive(pid):
            time.sleep(0.02)
        print("gone", flush=True)
    elif mode == "channel":
        os.read(int(os.environ["AGENTICA_CHANNEL"].split(",")[0]), 1)
        print("started", flush=True)
        time.sleep(60)
    elif mode == "record":
        path = os.path.join(rest[0], str(os.getpid()))
        beat = 0
        while True:
            with open(path, "w") as record:
                record.write(str(beat))
            beat += 1
            time.sleep(0.05)
    else:
        sys.exit("unknown mode: " + mode)


if __name__ == "__main__":
    main(*sys.argv[1:])
