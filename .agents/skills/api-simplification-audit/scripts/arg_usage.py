#!/usr/bin/env python3
"""Pass 2 of the API simplification audit: how real calls pass each argument of
one builtin or std/ function.

Usage: arg_usage.py AGENTICA_BINARY NAME [PATH...] [--root CHECKOUT]

Runs `agentica refs NAME PATH... --json`, reads each call site, splits its
arguments at top-level commas and counts the text of each position. In method
form (`xs.take(2)`) and pipe form (`xs |> take(2)`) the receiver holds
position 0, so the first written argument is position 1. PATH defaults to the
current directory; `std/...` spans are read under CHECKOUT/stdlib, so the
binary must match the checkout. A call that goes on past its line, or has no
parentheses right after the name (`xs.map do |x|`, `f (x)`), is reported as
unparsed, not guessed; a trailing block is not counted. Standard library only.
"""

import argparse
import collections
import json
import pathlib
import subprocess
import sys


def call_arguments(line, end_column):
    """The argument texts of the call whose name ends at end_column (1-based), or None."""
    rest = line[end_column - 1 :]
    if not rest.startswith("("):
        return None
    depth, current, args, quote = 0, "", [], None
    escaped = False
    for ch in rest:
        if quote:
            current += ch
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
            if depth == 1:
                continue
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append(current.strip())
                return [a for a in args if a]
        elif ch == "," and depth == 1:
            args.append(current.strip())
            current = ""
            continue
        current += ch
    return None  # the call goes on past this line


def source_path(root, file):
    if file.startswith("std/"):
        return pathlib.Path(root) / "stdlib" / file[len("std/") :]
    return pathlib.Path(file)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("binary")
    parser.add_argument("name")
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--root", default=".", help="the checkout whose stdlib/ the std/ spans name")
    args = parser.parse_args()

    out = subprocess.run([args.binary, "refs", args.name, *args.paths, "--json"], capture_output=True, text=True)
    if out.returncode != 0:
        # refs stops at the first check error of any file it reads: pass narrower PATHs.
        sys.exit(f"refs failed: {out.stderr.strip() or out.stdout.strip()}")
    answer = json.loads(out.stdout)
    references = [r for r in answer["references"] if r["kind"] == "call"]
    skipped = answer.get("skipped") or []

    positions = collections.defaultdict(collections.Counter)
    unparsed = []
    for ref in references:
        span = ref["span"]
        path = source_path(args.root, span["file"])
        start, end = span["range"]["start"], span["range"]["end"]
        try:
            line = path.read_text().splitlines()[start["line"] - 1]
        except (OSError, IndexError):
            unparsed.append(f"{span['file']}:{start['line']} (unreadable)")
            continue
        found = call_arguments(line, end["column"])
        if found is None:
            unparsed.append(f"{span['file']}:{start['line']}")
            continue
        before = line[: start["column"] - 1].rstrip()
        method = before.endswith(".") or before.endswith("|>")
        offset = 1 if method else 0
        for at, text in enumerate(found):
            positions[at + offset][text] += 1

    print(f"{args.name}: {len(references)} calls, {len(unparsed)} unparsed")
    for at in sorted(positions):
        counts = positions[at]
        total = sum(counts.values())
        print(f"\n  argument {at} ({total} parsed):")
        for text, n in counts.most_common(8):
            print(f"    {n:4}  {100 * n // total:3}%  {text}")
    if skipped:
        print(f"\n  files refs skipped (they do not link): {len(skipped)}")
        for item in skipped[:20]:
            print(f"    {item}")
    if unparsed:
        print("\n  unparsed (read by hand):")
        for where in unparsed[:20]:
            print(f"    {where}")


if __name__ == "__main__":
    main()
