#!/usr/bin/env python3
"""Guard the code layout of the `--jit off` hot loop (`make layout-check`).

Any growth of `run_compiled` in vm/interp.c moves `plain_turn`, the turn loop of `--jit off`, and a move of 128 bytes
with identical instructions once slowed the `lists` benchmark by up to 12% (PRs #733, #735, #739, #742). This tool
builds the base commit next to the current tree and compares the two first binaries (`build/vm/<mode>/bootstrap/
agentica`: it has the text of dist/agentica, only the embedded data differs) function by function.

  layout_check.py prepare BASE TREE        make a worktree of BASE at TREE; exit 3 when no VM input differs from BASE
  layout_check.py compare TREE BIN OBJ     compare TREE/BIN and BIN, TREE/OBJ and OBJ (interp.o); exit 1 on a violation
  layout_check.py clean TREE               remove the worktree

BASE is a Git revision; empty means `git merge-base origin/master HEAD`.

What fails (the `--jit off` loop is `plain_turn`):
  1. its instructions changed, compared after removing what depends on where things sit: addresses, branch targets
     outside the function, rip-relative displacements and padding nops;
  2. it sits at another place of vm/interp.c's text. That position is what the PR itself decides (an edit of a function
     above it moves it), and a move of 128 bytes with the same instructions was enough to cost 12%.
What is only reported: where the other objects put interp.o (a PR that grows builtins.c moves every later function, and
the author cannot undo that), and any change of `jit_turn` or `agc_run_turn`.
"""

from __future__ import annotations

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
# Paths whose change can move the loop: the VM sources, and the build flags and link order.
INPUTS = ("vm", "Makefile", "mk")
CACHE_LINE = 64
PAGE = 4096
EXIT_NOTHING_TO_COMPARE = 3


def run(command: list[str], *, cwd: Path = REPOSITORY, check: bool = True) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        sys.exit(f"layout-check: {' '.join(command)} failed:\n{result.stderr.strip()}")
    return result.stdout


def resolve_base(base: str) -> str:
    if not base:
        base = run(["git", "merge-base", "origin/master", "HEAD"]).strip()
    return run(["git", "rev-parse", "--verify", base + "^{commit}"]).strip()


def prepare(base: str, tree: Path) -> int:
    sha = resolve_base(base)
    # `git diff REV -- paths` compares the working tree too, so a local run sees uncommitted edits.
    if subprocess.run(["git", "diff", "--quiet", sha, "--", *INPUTS], cwd=REPOSITORY).returncode == 0:
        print(f"layout-check: no change under {', '.join(INPUTS)} since {sha[:10]}: nothing to compare")
        return EXIT_NOTHING_TO_COMPARE
    run(["git", "worktree", "add", "--detach", "--force", str(tree), sha])
    # The third-party sources are copied, not fetched: they come after every VM object in the link, so they cannot move
    # the loop, and the base build then needs no network.
    shutil.copytree(REPOSITORY / "vm" / "third_party", tree / "vm" / "third_party", symlinks=True, dirs_exist_ok=True)
    print(f"layout-check: base {sha[:10]} in {tree}")
    return 0


def clean(tree: Path) -> int:
    subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=REPOSITORY, check=False, capture_output=True)
    shutil.rmtree(tree, ignore_errors=True)
    subprocess.run(["git", "worktree", "prune"], cwd=REPOSITORY, check=False)
    return 0


@dataclass
class Place:
    address: int
    size: int
    local: int  # offset in the .text of interp.o; None-like -1 when the object has no such symbol


def symbols(binary: Path) -> dict[str, tuple[int, int]]:
    """Name -> (address or section offset, size) of the defined text symbols, from `nm -S`."""
    table: dict[str, tuple[int, int]] = {}
    for line in run(["nm", "-S", "--defined-only", str(binary)]).splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] in ("t", "T"):
            table[parts[3]] = (int(parts[0], 16), int(parts[1], 16))
    return table


def places(binary: Path, interp_o: Path) -> dict[str, Place]:
    linked = symbols(binary)
    local = symbols(interp_o)
    return {
        name: Place(linked[name][0], linked[name][1], local[name][0] if name in local else -1)
        for name in WATCHED
        if name in linked
    }


NOP = re.compile(r"^(?:(?:cs|ds|data16)\s+)*(?:nop\w*|xchg\s+%ax,%ax)\b")
TARGET = re.compile(r"\b[0-9a-f]+ <([^>+]+)(\+0x[0-9a-f]+)?>")
RIP = re.compile(r"-?0x[0-9a-f]+\(%rip\)")
RIP_NOTE = re.compile(r"#\s*[0-9a-f]+(?: <([^>+]+)(\+0x[0-9a-f]+)?>)?")


def normalized(binary: Path, name: str) -> list[str]:
    """The instructions of one function without what depends on its address.

    Dropped: addresses, padding nops (their length follows the address), the displacement of a rip-relative operand, the
    offset in a target outside the function, and the symbol of a rip-relative target that is not at the start of one
    (a jump table in .rodata is named after whatever symbol comes before it). A branch inside the function keeps its
    offset from the function start, so a moved branch shows."""
    text = run(["objdump", "-d", "--no-show-raw-insn", "-w", f"--disassemble={name}", str(binary)])
    lines: list[str] = []
    for raw in text.splitlines():
        match = re.match(r"^\s*[0-9a-f]+:\t(.*)$", raw)
        if not match:
            continue
        insn = match.group(1).strip()
        if NOP.match(insn):
            continue

        def note(m: re.Match[str]) -> str:
            return "# <%s>" % (m.group(1) if m.group(1) and not m.group(2) else "?")

        def target(m: re.Match[str]) -> str:
            symbol, offset = m.group(1), m.group(2) or ""
            return f"<{symbol}{offset}>" if symbol == name else f"<{symbol}>"

        insn = RIP_NOTE.sub(note, insn)
        insn = RIP.sub("X(%rip)", insn)
        insn = TARGET.sub(target, insn)
        lines.append(re.sub(r"\s+", " ", insn))
    return lines


def first_difference(base: list[str], head: list[str]) -> str:
    for index, (a, b) in enumerate(zip(base, head)):
        if a != b:
            return f"first difference at instruction {index}:\n    base: {a}\n    head: {b}"
    return f"one side ends at instruction {min(len(base), len(head))} ({len(base)} vs {len(head)} instructions)"


def compare(tree: Path, binary: str, interp_o: str) -> int:
    base = places(tree / binary, tree / interp_o)
    head = places(REPOSITORY / binary, REPOSITORY / interp_o)
    failures: list[str] = []
    notes: list[str] = []

    print("layout-check: entry address, cache-line offset (% 64), page offset (% 4096), size, and the offset in interp.o")
    print(f"  {'function':14} {'':5} {'address':>9} {'%64':>4} {'%4096':>6} {'size':>7} {'in interp.o':>12}")
    for name in WATCHED:
        if name not in head:
            failures.append(f"{name} is not a symbol of the new binary: rename it in tools/layout_check.py")
            continue
        if name not in base:
            notes.append(f"{name} is new: the base binary has no such function")
            continue
        for label, place in (("base", base[name]), ("head", head[name])):
            print(
                f"  {name:14} {label:5} {place.address:#9x} {place.address % CACHE_LINE:4d} {place.address % PAGE:6d}"
                f" {place.size:#7x} {place.local:#12x}"
            )
        moved = head[name].address - base[name].address
        own = head[name].local - base[name].local
        if moved:
            notes.append(
                f"{name} moved {moved:+d} bytes ({own:+d} from interp.o itself, {moved - own:+d} from the objects"
                f" linked before it); alignment {base[name].address % CACHE_LINE} -> {head[name].address % CACHE_LINE}"
                f" (% 64), {base[name].address % PAGE} -> {head[name].address % PAGE} (% 4096)"
            )

        same = normalized(tree / binary, name) == normalized(REPOSITORY / binary, name)
        if name == HOT:
            if not same:
                failures.append(
                    f"{name}: the instructions changed\n  "
                    + first_difference(normalized(tree / binary, name), normalized(REPOSITORY / binary, name))
                )
            if head[name].local != base[name].local:
                failures.append(
                    f"{name} sits {own:+d} bytes from where it did in vm/interp.c's text (a function above it grew or"
                    " shrank, or the compiler laid it out differently)"
                )
        elif not same:
            notes.append(f"{name}: the instructions changed")

    for note in notes:
        print(f"note: {note}")
        if os.environ.get("GITHUB_ACTIONS") == "true" and note.startswith(HOT + " moved"):
            print(f"::warning title=layout-check::{note}")
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        print(
            "layout-check FAILED: the loop of `--jit off` changed. Measure `--jit off` on a pinned core"
            " (taskset; the lists, case and arithmetic benchmarks) against the base; keep new JIT exit handling in out-of-line"
            " noinline helpers so run_compiled does not grow. If the change is intended and measured, label the pull request"
            " `layout-change` and say the numbers in it (references/ci.md of the development skill)."
        )
        return 1
    print("layout-check passed: the instructions of " + HOT + " are the same and it sits where it did in interp.o")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] == "prepare":
        return prepare(argv[2], Path(argv[3]).resolve())
    if len(argv) == 5 and argv[1] == "compare":
        return compare(Path(argv[2]).resolve(), argv[3], argv[4])
    if len(argv) == 3 and argv[1] == "clean":
        return clean(Path(argv[2]).resolve())
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
