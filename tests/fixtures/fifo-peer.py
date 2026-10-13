import os
import sys
import time


def main():
    path, mode, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
    os.mkfifo(path, 0o600)
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    print("ready", flush=True)
    got = 0
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            time.sleep(0.001)
            continue
        if not data and got:
            break
        got += len(data)
        if mode == "close" and got >= limit:
            break
        time.sleep(0.001)
    os.close(fd)
    print(got, flush=True)


if __name__ == "__main__":
    main()
