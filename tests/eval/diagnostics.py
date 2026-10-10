#!/usr/bin/env python3
"""Summarize the Agentica diagnostics that agents saw during evaluation runs."""

import argparse
import json
import re
import sys
from collections import Counter
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"
RUN_NAME = re.compile(r"^(?P<task>t\d+-[a-z0-9-]+)-(?P<arm>skill|grammar|binary|python)-\d+$")
HEADER = re.compile(
    r'(?:error\[|^\[|"code"\s*:\s*")(?P<code>(?:LEX|PARSE|CHECK|RUNTIME)-[A-Z0-9-]+)',
    re.MULTILINE,
)
MESSAGES = (
    re.compile(r"\A[A-Z0-9-]+\][ \t]*\n(?P<message>\S[^\n]*)"),
    re.compile(r"^\s*message: (?P<message>[^\n]+)", re.MULTILINE),
    re.compile(r'"message"\s*:\s*"(?P<message>(?:[^"\\]|\\.)*)"'),
)
SOURCES = (
    re.compile(r"^\s*\d+\s*\|\s?(?P<line>.*\S.*)$", re.MULTILINE),
    re.compile(r"^\s*source: (?P<line>[^\n]+)", re.MULTILINE),
)

@dataclass
class Hit:
    """One diagnostic shown by one Agentica invocation."""

    run: str
    task: str
    arm: str
    code: str
    message: str
    source: str


@dataclass
class CodeStats:
    """Totals for one diagnostic code."""

    hits: int = 0
    repeats: int = 0
    runs: set[str] = field(default_factory=set)
    messages: Counter[str] = field(default_factory=Counter)
    sources: Counter[str] = field(default_factory=Counter)


def is_agentica_call(command: str) -> bool:
    """Tell whether a shell command ran the Agentica binary or a program."""
    return "agentica" in command or ".agc" in command or "main.rkt" in command


def first_diagnostic(output: str) -> tuple[str, str, str] | None:
    """Return the first diagnostic code, its message and source line."""
    found = HEADER.search(output)
    if not found:
        return None
    rest = output[found.start("code") :]
    message = next((m["message"] for m in (p.search(rest) for p in MESSAGES) if m), "")
    source = next((m["line"] for m in (p.search(rest) for p in SOURCES) if m), "")
    return found["code"], message.strip(), source.strip()


def agentica_outputs(log: Path) -> Iterator[str]:
    """Yield the output of each Agentica invocation in one agent log, in order."""
    commands: dict[str, str] = {}
    with log.open(encoding="utf-8") as lines:
        for line in lines:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("toolName") != "bash":
                continue
            call = event.get("toolCallId", "")
            if event.get("type") == "tool_execution_start":
                commands[call] = event.get("args", {}).get("command", "")
            elif event.get("type") == "tool_execution_end":
                if not is_agentica_call(commands.pop(call, "")):
                    continue
                parts = event.get("result", {}).get("content", [])
                yield "".join(part.get("text", "") for part in parts)


def run_hits(log: Path) -> tuple[list[Hit | None], str, str] | None:
    """Return one entry per Agentica invocation (None when it was clean)."""
    named = RUN_NAME.match(log.parent.name)
    if not named:
        return None
    run = f"{log.parent.parent.name}/{log.parent.name}"
    hits: list[Hit | None] = []
    for output in agentica_outputs(log):
        found = first_diagnostic(output)
        hits.append(Hit(run, named["task"], named["arm"], *found) if found else None)
    return hits, named["task"], named["arm"]


def collect(roots: Iterable[Path], arms: set[str]) -> tuple[dict[str, CodeStats], int, int]:
    """Gather per-code statistics over every agent log under the given roots."""
    stats: dict[str, CodeStats] = {}
    runs = 0
    calls = 0
    for root in roots:
        for log in sorted(root.glob("*/agent.jsonl")):
            found = run_hits(log)
            if found is None or found[2] not in arms:
                continue
            hits = found[0]
            runs += 1
            calls += len(hits)
            for index, hit in enumerate(hits):
                if hit is None:
                    continue
                entry = stats.setdefault(hit.code, CodeStats())
                entry.hits += 1
                entry.runs.add(hit.run)
                entry.messages[hit.message] += 1
                if hit.source:
                    entry.sources[hit.source] += 1
                following = hits[index + 1] if index + 1 < len(hits) else None
                if following is not None and following.code == hit.code:
                    entry.repeats += 1
    return stats, runs, calls


def report(stats: dict[str, CodeStats], runs: int, calls: int, examples: int) -> str:
    """Render the statistics as Markdown."""
    lines = [
        f"Runs: {runs}. Agentica invocations: {calls}. "
        f"Invocations with a diagnostic: {sum(s.hits for s in stats.values())}.",
        "",
        "| code | hits | runs | repeated next call |",
        "|---|---|---|---|",
    ]
    ordered = sorted(stats.items(), key=lambda item: (-item[1].hits, item[0]))
    for code, entry in ordered:
        lines.append(f"| `{code}` | {entry.hits} | {len(entry.runs)} | {entry.repeats} |")
    for code, entry in ordered:
        lines += ["", f"## {code}", ""]
        for message, count in entry.messages.most_common(examples):
            lines.append(f"- {count}× {message or '(no message found)'}")
        for source, count in entry.sources.most_common(examples):
            lines.append(f"- {count}× source: `{source}`")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    """Parse arguments and print the report."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "roots",
        nargs="*",
        type=Path,
        help="result directories (default: every valid run under tests/eval/results)",
    )
    parser.add_argument(
        "--arms",
        default="skill,grammar,binary",
        help="comma-separated arms to include (default: skill,grammar,binary)",
    )
    parser.add_argument("--examples", type=int, default=5, help="messages shown per code")
    args = parser.parse_args(argv)
    roots = args.roots or [
        path for path in sorted(RESULTS.iterdir()) if path.is_dir() and not path.name.endswith("INVALID")
    ]
    stats, runs, calls = collect(roots, set(args.arms.split(",")))
    sys.stdout.write(report(stats, runs, calls, args.examples))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
