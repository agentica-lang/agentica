import fcntl
import os
import struct
import sys
import termios
import time

BEFORE = {
    "stall": b"first\npar",
    "burst": b"one\ntwo\nthree\n",
}

PIECES = {
    "pieces": [b"alpha\r", b"\nbe", b"ta\ngamma\n\nde", b"lta"],
    "burst": [b"four\nfive\n"],
}


def queued(fd):
    return struct.unpack("i", fcntl.ioctl(fd, termios.FIONREAD, b"\0\0\0\0"))[0]


def drained(fd, seconds):
    deadline = time.monotonic() + seconds
    while queued(fd) and time.monotonic() < deadline:
        time.sleep(0.005)
    return queued(fd) == 0


def main():
    path, mode = sys.argv[1], sys.argv[2]
    os.mkfifo(path, 0o600)
    fd = os.open(path, os.O_RDWR)
    if mode in BEFORE:
        os.write(fd, BEFORE[mode])
    print("ready", flush=True)
    for piece in PIECES.get(mode, []):
        if not drained(fd, 20):
            sys.exit(1)
        os.write(fd, piece)
        time.sleep(0.05)
    if mode == "pieces":
        if not drained(fd, 20):
            sys.exit(1)
        os.close(fd)
        print("closed", flush=True)
        return
    print("holding", flush=True)
    time.sleep(30)


if __name__ == "__main__":
    main()
