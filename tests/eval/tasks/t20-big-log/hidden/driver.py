import os
import subprocess
import sys
import tempfile

SERVICES = ["auth", "billing", "cart", "search", "media", "mail"]
METHODS = ["GET", "POST", "PUT", "DELETE"]
WORDS = ["users", "orders", "items", "carts", "sessions", "reports", "events", "files"]
STATUSES = [200] * 60 + [201] * 6 + [204] * 4 + [301, 304, 304, 400, 400, 404, 404, 404, 429] + [500, 500, 502, 503, 504] * 3
SMALL = (
    "1 auth GET /v1/a 500 800\n"
    "2 auth GET /v1/a 500 799\n"
    "3 auth GET /v1/a 499 5000\n"
    "4 cart POST /v1/b/c 503 12000\n"
    "5 cart POST /v1/b/c 200 99999\n"
    "bad line\n"
    "6 mail GET /v1/x 500\n"
    "7 mail GET /v1/x 500 80x\n"
    "8 mail GET /v1/x 5x0 900\n"
    "\n"
    "9 mail  GET /v1/x 500 900\n"
    "10 search GET /v1/q?x=1 502 1500\r\n"
    "x1 search GET /v1/q 502 1500\n"
    "12 search GET /v1/q 500 900 \n"
    "11 search GET /v1/q 599 800"
)


def numbers(seed):
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        yield state >> 33


def write_generated(path, count):
    rng = numbers(count)
    expected = []
    with open(path, "w", encoding="utf-8", newline="") as handle:
        for seq in range(1, count + 1):
            service = SERVICES[next(rng) % len(SERVICES)]
            method = METHODS[next(rng) % len(METHODS)]
            tail = "/".join(WORDS[next(rng) % len(WORDS)] + str(next(rng) % 1000) for _ in range(2))
            status = STATUSES[next(rng) % len(STATUSES)]
            slow = next(rng) % 100 < 14
            latency = 800 + next(rng) % 4200 if slow else 1 + next(rng) % 700
            end = "\r\n" if seq % 50021 == 0 else "\n"
            if seq % 40009 == 0:
                tail = tail + "/" + "p" * 3000
            if seq % 1999 == 0:
                handle.write("\n")
            if seq % 997 == 0:
                handle.write(f"{seq} {service} {method} {status} {latency}{end}")
                continue
            if seq % 1511 == 0:
                handle.write(f"{seq} {service} {method} /v1/{tail} {status} {latency}ms{end}")
                continue
            last = seq == count
            handle.write(f"{seq} {service} {method} /v1/{tail} {status} {latency}{'' if last else end}")
            if status >= 500 and latency >= 800:
                expected.append(f"{seq} {service} {latency}")
    return expected


def write_small(path):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(SMALL)
    return ["1 auth 800", "4 cart 12000", "10 search 1500", "11 search 800"]


def main():
    scenario = sys.stdin.read().strip()
    with tempfile.TemporaryDirectory(prefix="biglog-") as directory:
        path = os.path.join(directory, "requests.log")
        if scenario == "small":
            expected = write_small(path)
        else:
            expected = write_generated(path, {"medium": 50000, "big": 600000}[scenario])
        size = os.path.getsize(path)
        done = subprocess.run(sys.argv[1:] + [path], cwd=directory, capture_output=True, text=True, timeout=50)
    sys.stderr.write(done.stderr)
    actual = done.stdout.split("\n")
    if actual and actual[-1] == "":
        actual.pop()
    if actual == expected and done.returncode == 0:
        print(f"ok: {len(expected)} lines from a file of {size // 1000000} MB")
        return
    print(f"mismatch: expected {len(expected)} lines, got {len(actual)}, exit {done.returncode}")
    for index, (want, got) in enumerate(zip(expected, actual)):
        if want != got:
            print(f"first difference at output line {index + 1}: expected {want!r}, got {got!r}")
            break


main()
