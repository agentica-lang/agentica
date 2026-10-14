import fcntl
import os
import struct
import sys
import termios
import time

PIECES = {
    "pieces": [b"alpha\r", b"\nbe", b"ta\ngamma\n\nde", b"lta"],
    "stall": [b"first\npar"],
    "idle": [],
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
    print("ready", flush=True)
    for piece in PIECES[mode]:
        os.write(fd, piece)
        if not drained(fd, 20):
            sys.exit(1)
        time.sleep(0.05)
    if mode == "pieces":
        os.close(fd)
        print("closed", flush=True)
        return
    print("holding", flush=True)
    time.sleep(30)


if __name__ == "__main__":
    main()
