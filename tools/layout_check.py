#!/usr/bin/env python3
"""Guard the code layout of the `--jit off` hot loop (`make layout-check`).

Any growth of `run_compiled` in vm/interp.c moves `plain_turn`, the turn loop of `--jit off`, and a move of 128 bytes
with identical instructions once slowed the `arithmetic` benchmark by 13% (PRs #733, #735, #739, #742). This tool
builds the base commit next to the current tree and compares the first binaries (`build/vm/<mode>/bootstrap/agentica`:
it has the text of dist/agentica, only the embedded data differs) function by function.

  layout_check.py prepare BASE TREE        make a worktree of BASE at TREE; exit 3 when no VM input differs from BASE
  layout_check.py compare TREE BIN OBJ     compare TREE/BIN and BIN, TREE/OBJ and OBJ (interp.o)
  layout_check.py clean TREE               remove the worktree

BASE is a Git revision; empty means `git merge-base origin/master HEAD`. Exit codes: 0 the same loop, 4 the loop
changed (compare only), 3 nothing to compare (prepare only), 2 the tool could not do its work.

What changes the verdict (the `--jit off` loop is `plain_turn`):
  1. its instructions changed, compared after removing what depends on where things sit: addresses, branch targets
     outside the function, rip-relative displacements, memory displacements (a field added to a struct moves every
     offset) and padding nops;
  2. it sits at another place of vm/interp.c's text. That position is what the PR itself decides, and a move of 128
     bytes with the same instructions was enough to cost 13%.
What is only reported: where the other objects put interp.o (a PR that grows builtins.c moves every later function, and
the author cannot undo that), and any change of `jit_turn` or `agc_run_turn`.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
HOT = "plain_turn"
WATCHED = ("plain_turn", "jit_turn", "agc_run_turn")
# What can move the loop: the VM sources (not vm/tests), and the build flags and link order.
INPUTS = (":(glob)vm/*.c", ":(glob)vm/*.h", "vm/jit", "Makefile", "mk")
CACHE_LINE = 64
PAGE = 4096
EXIT_OK = 0
EXIT_FAILED = 2
EXIT_NOTHING_TO_COMPARE = 3
EXIT_CHANGED = 4


class LayoutError(Exception):
    """The tool could not do its work (a command failed, a symbol is missing), as opposed to a changed loop."""


@dataclass
class Function:
    address: int
    size: int
    local: int | None  # offset in the .text of interp.o; None when the object has no such symbol
    code: list[str]  # the normalized instructions


def run(command: list[str], *, cwd: Path = REPOSITORY) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise LayoutError(f"{' '.join(command)} failed:\n{result.stderr.strip()}")
    return result.stdout


def resolve_base(repo: Path, base: str) -> str:
    if not base:
        base = run(["git", "merge-base", "origin/master", "HEAD"], cwd=repo).strip()
    return run(["git", "rev-parse", "--verify", base + "^{commit}"], cwd=repo).strip()


def clean(repo: Path, tree: Path) -> None:
    subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=repo, check=False, capture_output=True)
    shutil.rmtree(tree, ignore_errors=True)
    subprocess.run(["git", "worktree", "prune"], cwd=repo, check=False, capture_output=True)


def prepare(repo: Path, base: str, tree: Path) -> int:
    sha = resolve_base(repo, base)
    # `git diff REV -- paths` compares the working tree too, so a local run sees uncommitted edits.
    if subprocess.run(["git", "diff", "--quiet", sha, "--", *INPUTS], cwd=repo, check=False).returncode == 0:
        print(f"layout-check: no VM input changed since {sha[:10]}: nothing to compare")
        return EXIT_NOTHING_TO_COMPARE
    clean(repo, tree)  # a tree left by an interrupted run
    run(["git", "worktree", "add", "--detach", "--force", str(tree), sha], cwd=repo)
    # The third-party sources are linked, not fetched: they come after every VM object in the link, so they cannot move
    # the loop, and the base build needs no network. The worktree has them as empty folders of the submodules.
    third_party = tree / "vm" / "third_party"
    shutil.rmtree(third_party, ignore_errors=True)
    third_party.symlink_to(repo / "vm" / "third_party")
    print(f"layout-check: base {sha[:10]} in {tree}")
    return EXIT_OK


def text_symbols(binary: Path) -> dict[str, tuple[int, int]]:
    """Name -> (address or section offset, size) of the defined text symbols, from `nm -S`."""
    table: dict[str, tuple[int, int]] = {}
    for line in run(["nm", "-S", "--defined-only", str(binary)]).splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] in ("t", "T"):
            table[parts[3]] = (int(parts[0], 16), int(parts[1], 16))
    return table


NOP = re.compile(r"^(?:(?:cs|ds|data16)\s+)*(?:nop\w*|xchg\s+%ax,%ax)\b")
TARGET = re.compile(r"\b[0-9a-f]+ <([^>+]+)(\+0x[0-9a-f]+)?>")
RIP = re.compile(r"-?0x[0-9a-f]+\(%rip\)")
RIP_NOTE = re.compile(r"#\s*[0-9a-f]+(?: <([^>+]+)(\+0x[0-9a-f]+)?>)?")
DISPLACEMENT = re.compile(r"(?<![\w$%])-?(?:0x[0-9a-f]+)?(\((?!%rip)(?:%[a-z0-9]+)?(?:,%[a-z0-9]+(?:,[1248])?)?\))")


def rip_target(match: re.Match[str]) -> str:
    """`# 7b0e0 <jt+0x20>` -> `# <?>`; the symbol stays only when the target is at its start."""
    return "# <%s>" % (match.group(1) if match.group(1) and not match.group(2) else "?")


def branch_target(match: re.Match[str], name: str, start: int, index_at: dict[int, int]) -> str:
    """A target outside the function keeps its symbol; one inside becomes the number of the instruction it reaches, so
    a longer encoding (an 8-bit displacement grown to 32) does not move the branches of the instructions after it."""
    symbol, offset = match.group(1), match.group(2)
    if symbol != name:
        return f"<{symbol}>"
    address = start + (int(offset, 16) if offset else 0)
    return f"<@{index_at[address]}>" if address in index_at else f"<{symbol}{offset or ''}>"


def normalized(text: str, name: str) -> list[str]:
    """The instructions of one function in `objdump -d` text, without what depends on its address.

    Dropped: addresses, padding nops (their length follows the address), the displacement of a rip-relative operand,
    the displacement of any other memory operand, even a zero one (a struct field added elsewhere shifts it), the offset in a target
    outside the function, and the symbol of a rip-relative target that is not at the start of one (a jump table in
    .rodata is named after whatever symbol comes before it). A branch inside the function keeps the number of the
    instruction it reaches, so a moved branch shows but a longer instruction does not."""
    listing: list[tuple[int, str]] = []
    for raw in text.splitlines():
        match = re.match(r"^\s*([0-9a-f]+):\t(.*)$", raw)
        if match:
            listing.append((int(match.group(1), 16), match.group(2).strip()))
    if not listing:
        return []
    start = listing[0][0]
    index_at: dict[int, int] = {}  # address -> number of the first instruction kept from there on
    kept: list[str] = []
    for address, insn in listing:
        index_at[address] = len(kept)
        if not NOP.match(insn):
            kept.append(insn)
    lines: list[str] = []
    for insn in kept:
        insn = RIP_NOTE.sub(rip_target, insn)
        insn = RIP.sub("X(%rip)", insn)
        insn = DISPLACEMENT.sub(r"D\1", insn)
        insn = TARGET.sub(lambda m: branch_target(m, name, start, index_at), insn)
        lines.append(re.sub(r"\s+", " ", insn))
    return lines


def load(binary: Path, interp_o: Path) -> dict[str, Function]:
    """The watched functions of a build: place in the binary, place in interp.o, instructions."""
    linked = text_symbols(binary)
    local = text_symbols(interp_o)
    functions: dict[str, Function] = {}
    for name in WATCHED:
        if name not in linked:
            continue
        text = run(["objdump", "-d", "--no-show-raw-insn", "-w", f"--disassemble={name}", str(binary)])
        address, size = linked[name]
        functions[name] = Function(address, size, local[name][0] if name in local else None, normalized(text, name))
    return functions


def first_difference(base: list[str], head: list[str]) -> str:
    for index, (a, b) in enumerate(zip(base, head)):
        if a != b:
            return f"first difference at instruction {index}:\n    base: {a}\n    head: {b}"
    return f"one side ends at instruction {min(len(base), len(head))} ({len(base)} vs {len(head)} instructions)"


def report_row(name: str, label: str, f: Function) -> str:
    local = "?" if f.local is None else f"{f.local:#x}"
    return (
        f"  {name:14} {label:5} {f.address:#9x} {f.address % CACHE_LINE:4d} {f.address % PAGE:6d}"
        f" {f.size:#7x} {local:>12}"
    )


def compare(base: dict[str, Function], head: dict[str, Function]) -> int:
    """Print the report and return EXIT_OK or EXIT_CHANGED. Raises LayoutError when the hot loop is missing."""
    if HOT not in head:
        raise LayoutError(f"{HOT} is not a symbol of the new binary: rename it in tools/layout_check.py")
    failures: list[str] = []
    notes: list[str] = []

    print("layout-check: address, cache-line offset (% 64), page offset (% 4096), size, offset in interp.o")
    print(f"  {'function':14} {'':5} {'address':>9} {'%64':>4} {'%4096':>6} {'size':>7} {'in interp.o':>12}")
    for name in WATCHED:
        if name not in head:
            notes.append(f"{name} is not a symbol of the new binary")
            continue
        if name not in base:
            notes.append(f"{name} is new: the base binary has no such function")
            continue
        old, new = base[name], head[name]
        print(report_row(name, "base", old))
        print(report_row(name, "head", new))
        moved = new.address - old.address
        own = None if old.local is None or new.local is None else new.local - old.local
        if moved:
            where = "" if own is None else f" ({own:+d} in interp.o itself, {moved - own:+d} from the objects before)"
            notes.append(
                f"{name} moved {moved:+d} bytes{where}; % 64: {old.address % CACHE_LINE} -> {new.address % CACHE_LINE},"
                f" % 4096: {old.address % PAGE} -> {new.address % PAGE}"
            )
        if name != HOT:
            if old.code != new.code:
                notes.append(f"{name}: the instructions changed")
            continue
        if old.code != new.code:
            failures.append(f"{name}: the instructions changed\n  " + first_difference(old.code, new.code))
        if own:
            failures.append(
                f"{name} sits {own:+d} bytes from where it did in vm/interp.c's text (a function above it grew or"
                " shrank, or the compiler laid it out differently)"
            )

    for note in notes:
        print(f"note: {note}")
        if os.environ.get("GITHUB_ACTIONS") == "true" and note.startswith(HOT + " moved"):
            print(f"::warning title=layout-check::{note}")
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        print(
            "layout-check: the loop of `--jit off` changed. Measure `--jit off` on a pinned core (taskset; the"
            " arithmetic, case and lists benchmarks) against the base. If the change is intended and measured,"
            " label the pull request `layout-change`, put the numbers in it and re-run the job"
            " (references/ci.md of the development skill)."
        )
        return EXIT_CHANGED
    print("layout-check passed: the instructions of " + HOT + " are the same and it sits where it did in interp.o")
    return EXIT_OK


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="make a worktree of BASE")
    prepare_parser.add_argument("base")
    prepare_parser.add_argument("tree", type=Path)
    compare_parser = commands.add_parser("compare", help="compare the base tree's binary with this tree's")
    compare_parser.add_argument("tree", type=Path)
    compare_parser.add_argument("binary", type=Path)
    compare_parser.add_argument("interp_o", type=Path)
    clean_parser = commands.add_parser("clean", help="remove the worktree")
    clean_parser.add_argument("tree", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_arguments(argv)
    try:
        if args.command == "prepare":
            return prepare(REPOSITORY, args.base, args.tree.resolve())
        if args.command == "compare":
            base = load(args.tree.resolve() / args.binary, args.tree.resolve() / args.interp_o)
            return compare(base, load(REPOSITORY / args.binary, REPOSITORY / args.interp_o))
        clean(REPOSITORY, args.tree.resolve())
        return EXIT_OK
    except LayoutError as error:
        print(f"layout-check: {error}", file=sys.stderr)
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
