#!/usr/bin/env python3
"""Peer for std/logger: vectors for Logger.time_text and a decoder for the JSON lines.

vectors DIR  writes DIR/ms.txt (the inputs) and DIR/expected.txt (datetime's answers).
check DIR    reads DIR/stdout.txt (the program's time_text lines, then its own output)
             and DIR/stderr.txt (the JSON lines) and exits 1 with a message on a mismatch.
Standard library only.
"""
import json
import random
import re
import sys
from datetime import datetime, timedelta, timezone

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
TIME = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
KEYS = ["time", "level", "msg", "fields", "task"]

FIXED = [
    0, 1, -1, 999, 1000, 86399999, 86400000,
    951696000000,       # 2000-02-28
    951782400000,       # 2000-02-29
    951868800000,       # 2000-03-01
    1709164800000,      # 2024-02-29
    4107456000000,      # 2100-02-28
    4107542400000,      # 2100-03-01
    946684799999,       # 1999-12-31T23:59:59.999
    946684800000,       # 2000-01-01
    1760523302345,
    -62135596800000,    # 0001-01-01
    -2208988800000,     # 1900-01-01
    -2203891200000,     # 1900-03-01 (1900 is not a leap year)
    253402300799999,    # 9999-12-31T23:59:59.999
    253402214400000,    # 9999-12-31
]


def text(ms):
    moment = EPOCH + timedelta(milliseconds=ms)
    return "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" % (
        moment.year, moment.month, moment.day, moment.hour, moment.minute, moment.second, moment.microsecond // 1000)


def vectors(directory):
    rng = random.Random(7)
    values = list(FIXED)
    values += [rng.randint(-62135596800000, 253402300799999) for _ in range(300)]
    values += [rng.randint(-5000000000000, 5000000000000) for _ in range(200)]
    with open(directory + "/ms.txt", "w") as out:
        out.write("".join("%d\n" % v for v in values))
    with open(directory + "/expected.txt", "w") as out:
        out.write("".join(text(v) + "\n" for v in values))


def expect(condition, message):
    if not condition:
        print("logger-peer: " + message, file=sys.stderr)
        sys.exit(1)


def check(directory):
    with open(directory + "/expected.txt") as f:
        expected = f.read().splitlines()
    with open(directory + "/stdout.txt") as f:
        printed = f.read().splitlines()
    expect(printed[:len(expected)] == expected, "time_text differs from datetime")
    expect(printed[len(expected):] == ["3"], "unexpected program output: %r" % printed[len(expected):])

    with open(directory + "/stderr.txt", encoding="utf-8") as f:
        lines = f.read().split("\n")
    expect(lines[-1] == "", "the last line has no newline")
    events = []
    for line in lines[:-1]:
        event = json.loads(line)
        expect(list(event) == KEYS, "keys are %r" % list(event))
        expect(TIME.match(event["time"]), "bad time %r" % event["time"])
        moment = datetime.strptime(event["time"], "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
        expect(abs((datetime.now(timezone.utc) - moment).total_seconds()) < 600, "time is not now")
        events.append((event["task"], event["level"], event["msg"], event["fields"]))

    main_events = [
        (1, "info", "plain", {}),
        (1, "warning", "quote \" backslash \\ newline \n tab \t", {"k": "café"}),
        (1, "error", "unicode 世界 and DEL \x7f", {}),
        (1, "debug", "fixed keys", {"level": "x", "msg": "y", "time": "z", "task": "9"}),
        (1, "info", "empty and odd fields", {"": "", "a b": "c=d", "z": "1", "a": "2"}),
    ]
    expect(events[:5] == main_events, "main events differ: %r" % events[:5])
    expect(list(events[3][3]) == ["level", "msg", "time", "task"], "field order changed")
    expect(list(events[4][3]) == ["", "a b", "z", "a"], "field order changed")
    expect(sorted(events[5:]) == [(2, "info", "from worker", {"n": "1"}), (3, "info", "from worker", {"n": "2"})],
           "worker events differ: %r" % events[5:])
    print("ok")


if __name__ == "__main__":
    {"vectors": vectors, "check": check}[sys.argv[1]](sys.argv[2])
