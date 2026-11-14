#!/usr/bin/env python3
"""The systems of the CI matrices: one table that platforms.yml and probe.yml both pick from.

    ci_systems.py platforms     the systems of a Platforms run: all five when ALL is true in the environment, else none
    ci_systems.py probe SPEC    the systems of a probe: SPEC is a comma or space separated list of platform names
                                and the shorthands linux, windows, macos and all; an unknown name exits 2

Each prints `matrix=<json>`, `count=N` and `all=true|false`, the lines a step appends to $GITHUB_OUTPUT, and the
names it picked on stderr.
"""
import json
import os
import re
import sys

SYSTEMS = [
    {"platform": "linux-x86_64", "runner": "ubuntu-latest", "make": "make", "python": "python3", "shell": "bash"},
    {"platform": "linux-arm64", "runner": "ubuntu-24.04-arm", "make": "make", "python": "python3", "shell": "bash"},
    {"platform": "windows-x86_64", "runner": "windows-2025", "make": "make", "python": "python", "shell": "msys2 {0}"},
    {"platform": "macos-x86_64", "runner": "macos-15-intel", "make": "gmake", "python": "python3", "shell": "bash"},
    {"platform": "macos-arm64", "runner": "macos-latest", "make": "gmake", "python": "python3", "shell": "bash"},
]
NAMES = [s["platform"] for s in SYSTEMS]


def platforms(all_systems):
    """The systems of a Platforms run: all five or none (tools/ci_changes.py decides for a pull request)."""
    return list(SYSTEMS) if all_systems else []


def probe(spec):
    """The systems a probe names, in table order; raises ValueError on an unknown name or an empty list."""
    wanted = set()
    for word in re.split(r"[\s,]+", spec.strip()):
        if not word:
            continue
        if word == "all":
            wanted.update(NAMES)
        elif word in ("linux", "windows", "macos"):
            wanted.update(n for n in NAMES if n.startswith(word + "-"))
        elif word in NAMES:
            wanted.add(word)
        else:
            raise ValueError(f"unknown system {word!r}: use {', '.join(NAMES)}, linux, windows, macos or all")
    if not wanted:
        raise ValueError("no system named")
    return [s for s in SYSTEMS if s["platform"] in wanted]


def output_lines(systems):
    return [f"matrix={json.dumps({'include': systems})}", f"count={len(systems)}",
            f"all={'true' if len(systems) == len(SYSTEMS) else 'false'}"]


def main(argv):
    if argv[:1] == ["platforms"] and len(argv) == 1:
        systems = platforms(os.environ.get("ALL") == "true")
    elif argv[:1] == ["probe"] and len(argv) == 2:
        try:
            systems = probe(argv[1])
        except ValueError as error:
            print(f"ci_systems.py: {error}", file=sys.stderr)
            return 2
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print("\n".join(output_lines(systems)))
    print("systems:", ", ".join(s["platform"] for s in systems) or "none", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
