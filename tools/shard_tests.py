#!/usr/bin/env python3
"""Pick the test modules of one shard (`make test SHARD=I/N`, references/ci.md of the development skill).

    shard_tests.py [--weights NAME] I/N MODULE...   print the modules of shard I of N, separated by spaces
    shard_tests.py --valid I/N                      exit 0 when I/N is a shard (1 <= I <= N), else 2

NAME is a column of tests/shard_weights.txt: fast (the default), slow, sanitize or tsan.

The split is deterministic: the modules go longest first (the seconds of that column) to the shard with the least load
so far, and ties go to the lower shard. Every module lands in exactly one
shard, so the shards together run what the unsharded run runs. A module the file does not list counts as UNLISTED
seconds, so a new module still runs and only the balance is off until the file is refreshed.
"""
import re
import sys
from pathlib import Path

WEIGHTS = Path(__file__).resolve().parent.parent / "tests" / "shard_weights.txt"
UNLISTED = 1.0
# A module that is listed with 0 s still costs the start of a pytest process.
FLOOR = 0.2


def parse_shard(text):
    """Return (index, count) of "I/N", or None when it is not a shard."""
    found = re.fullmatch(r"([0-9]+)/([0-9]+)", text)
    if not found:
        return None
    index, count = int(found.group(1)), int(found.group(2))
    return (index, count) if 1 <= index <= count else None


COLUMNS = ("fast", "slow", "sanitize", "tsan")


def load_weights(path, column):
    """The seconds of each listed module in one column of the weights file."""
    weights = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, *seconds = line.split()
        weights[name] = max(float(seconds[COLUMNS.index(column)]), FLOOR)
    return weights


def split(modules, count, weights):
    """Greedy longest-first balancing: a list of `count` lists of modules, each in the order of the input."""
    loads = [0.0] * count
    shards = [[] for _ in range(count)]
    order = sorted(set(modules), key=lambda m: (-weights.get(m, UNLISTED), m))
    for module in order:
        target = min(range(count), key=lambda k: (loads[k], k))
        shards[target].append(module)
        loads[target] += weights.get(module, UNLISTED)
    return [sorted(shard) for shard in shards]


def main(argv):
    arguments = list(argv)
    column = "fast"
    if "--weights" in arguments:
        at = arguments.index("--weights")
        column = arguments[at + 1] if at + 1 < len(arguments) else ""
        del arguments[at:at + 2]
    valid_only = "--valid" in arguments
    arguments = [a for a in arguments if a != "--valid"]
    if column not in COLUMNS:
        print(f"--weights must be one of {', '.join(COLUMNS)}", file=sys.stderr)
        return 2
    shard = parse_shard(arguments[0]) if arguments else None
    if shard is None:
        print("SHARD must be I/N with 1 <= I <= N, for example 2/3", file=sys.stderr)
        return 2
    if valid_only:
        return 0
    index, count = shard
    print(" ".join(split(arguments[1:], count, load_weights(WEIGHTS, column))[index - 1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
