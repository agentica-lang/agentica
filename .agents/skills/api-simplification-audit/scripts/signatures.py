#!/usr/bin/env python3
"""Pass 1 of the API simplification audit: dump every builtin and exported std/
function parameter, with its type and default, and summarize the candidates.

Usage: signatures.py AGENTICA_BINARY [--root CHECKOUT] [--tsv OUT.tsv]

AGENTICA_BINARY must be a current build (a worktree's dist/agentica or a
release binary); CHECKOUT (default: the current directory) holds the
stdlib/MODULES list that matches it. Standard library only.
"""

import argparse
import collections
import json
import pathlib
import subprocess
import sys

# Parameter names that usually hold a tuning value with a common answer.
TUNING = (
    "timeout", "max_", "limit", "size", "count", "padding", "sep", "options", "flags", "mode", "level",
    "offset", "buffer", "dir", "args", "headers", "body", "ca_file",
)


def run_json(binary, *args, required=True):
    out = subprocess.run([binary, *args], capture_output=True, text=True)
    if out.returncode != 0:
        message = f"{binary} {' '.join(args)} failed: {out.stderr.strip()}"
        if required:
            sys.exit(message)
        # A module the binary does not carry: the binary is older than the checkout.
        print(f"skipped: {message}", file=sys.stderr)
        return None
    return json.loads(out.stdout)


def std_modules(root):
    listing = pathlib.Path(root) / "stdlib" / "MODULES"
    if not listing.exists():
        sys.exit(f"no stdlib/MODULES under {root}: run from a checkout or pass --root")
    for line in listing.read_text().split():
        if line.endswith(".agc") and not line.startswith(("internal/", "prelude/", "test/", "bdd/")):
            yield "std/" + line[: -len(".agc")]


def rows(binary, root):
    for entry in run_json(binary, "help", "--json"):
        if "parameters" not in entry:
            # A builtin with overloads (Task.await, Map.get...): never a default candidate by rule.
            yield ("overloads", entry["name"], 0, "", "", None, "")
            continue
        for at, p in enumerate(entry["parameters"]):
            yield ("builtin", entry["name"], at, p["name"], p["type"], p.get("default"), entry["signature"])
    for module in std_modules(root):
        doc = run_json(binary, "doc", module, "--json", required=False)
        if doc is None:
            continue
        for item in doc["items"]:
            if item["kind"] == "function":
                for at, p in enumerate(item.get("parameters", [])):
                    name = f"{module}.{item['name']}"
                    yield ("std", name, at, p["name"], p["type"], p.get("default"), item["signature"])
            elif item["kind"] == "struct":
                for at, f in enumerate(item.get("fields", [])):
                    name = f"{module}.{item['name']}"
                    yield ("std-field", name, at, f["name"], f["type"], f.get("default"), item["signature"])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("binary")
    parser.add_argument("--root", default=".", help="the checkout with stdlib/MODULES")
    parser.add_argument("--tsv", help="write every parameter as a TSV file")
    args = parser.parse_args()

    table = list(rows(args.binary, args.root))
    if args.tsv:
        with open(args.tsv, "w") as out:
            out.write("kind\tfunction\tposition\tparameter\ttype\tdefault\tsignature\n")
            for r in table:
                out.write("\t".join("" if v is None else str(v) for v in r) + "\n")

    overloaded = [r[1] for r in table if r[0] == "overloads"]
    table = [r for r in table if r[0] != "overloads"]
    functions = {(r[0], r[1]) for r in table}
    with_default = [r for r in table if r[5] is not None]
    print(
        f"{len(functions)} functions or structs, {len(table)} parameters or fields, "
        f"{len(with_default)} with a default"
    )

    names = collections.Counter(r[3] for r in table if r[5] is None)
    print("\nmost repeated parameters without a default:")
    for name, n in names.most_common(15):
        print(f"  {n:4} {name}")

    print("\ntuning-like parameters without a default (candidates):")
    for r in table:
        if r[5] is None and any(word in r[3] for word in TUNING):
            print(f"  {r[0]:9} {r[1]}  {r[3]}: {r[4]}")

    print(f"\nbuiltins with overloads, not candidates (read by hand): {', '.join(overloaded)}")

    print("\nexisting defaults (precedents):")
    for r in with_default:
        print(f"  {r[0]:9} {r[1]}  {r[3]}: {r[4]} = {r[5]}")


if __name__ == "__main__":
    main()
