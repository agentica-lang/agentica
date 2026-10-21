import argparse
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROGRAMS = ROOT / "benchmarks" / "programs"
PYTHON = ROOT / "benchmarks" / "python"
EXE = ROOT / "dist" / "agentica"
HELLO = ROOT / "examples" / "hello.agc"
GHERKIN = ROOT / "stdlib" / "bdd" / "gherkin.agc"
PARSER = ROOT / "compiler" / "syntax" / "parser.agc"
FRONT_END = ROOT / "compiler" / "front_end.agc"
TIME = Path("/usr/bin/time")
NAMES = [
    "knight-tour",
    "maze-bfs",
    "traveling-salesman",
    "arithmetic",
    "strings",
    "lists",
    "list-build",
    "list-bulk",
    "maps",
    "sets",
    "calls",
    "case",
    "string-library",
    "small-values",
    "channel-pingpong",
    "print-lines",
    "deadline-pingpong",
    "sleepers",
]
SCALE_DEF = "def scale() -> Int\n  return 1\nend\n"
# Programs for the front-end rows: a main that imports the largest module of the corpus, so that `check` goes through
# every function body of it, and the smallest unit test.
GHERKIN_MAIN = 'import Gherkin from "std/bdd/gherkin"\n\ndef main() -> Void\n  puts("ok")\nend\n'
SMALL_TEST = 'def main() -> Void\n  Test.run([Test.test("adds") do\n    Test.eq(1 + 1, 2)\n  end])\nend\n'
# A one-minute load average above this makes the numbers rough; the report says so.
BUSY_LOAD = 2.0


@dataclass
class Sample:
    seconds: float
    stdout: str
    stderr: str
    code: int


@dataclass
class Row:
    name: str
    runner: str
    status: str
    median: float = 0.0
    best: float = 0.0
    rss_kb: int | None = None
    note: str = ""


def run(command: list[str]) -> Sample:
    start = time.perf_counter()
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    stdout, stderr = process.communicate()
    seconds = time.perf_counter() - start
    return Sample(seconds, stdout, stderr, process.returncode)


def peak_rss(command: list[str]) -> tuple[Sample, int | None]:
    if not TIME.exists():
        return run(command), None
    with tempfile.NamedTemporaryFile(mode="r") as report:
        sample = run([str(TIME), "-f", "%M", "-o", report.name, *command])
        lines = report.read().strip().splitlines()
    if not lines or not lines[-1].isdigit():
        return run(command), None
    return sample, int(lines[-1])


def diagnostic(stderr: str) -> str:
    lines = stderr.strip().splitlines()
    match = re.search(r"error\[([A-Z0-9-]+)\]", stderr)
    if not match:
        return lines[0] if lines else "no output"
    message = lines[1].strip() if len(lines) > 1 else ""
    return f"{match.group(1)}: {message}"


def scaled_source(name: str, size: int, workdir: Path) -> Path:
    source = PROGRAMS / f"{name}.agc"
    if size == 1:
        return source
    text = source.read_text()
    if SCALE_DEF not in text:
        raise SystemExit(f"{source}: no `def scale` returning 1")
    target = workdir / f"{name}.agc"
    target.write_text(text.replace(SCALE_DEF, f"def scale() -> Int\n  return {size}\nend\n"))
    return target


def runners(selected: list[str]) -> dict[str, list[str]]:
    available = {
        "exe": [str(EXE)] if EXE.exists() else None,
        "vm": [str(EXE), "run", "--"] if EXE.exists() else None,
        "python": [sys.executable],
    }
    for name in selected:
        if name not in available:
            raise SystemExit(f"unknown runner {name}; choose from {', '.join(available)}")
    return {name: available[name] for name in selected}


def measure(name: str, runner: str, command: list[str], runs: int, expected: str | None,
            codes: tuple[int, ...] = (0,)) -> tuple[Row, str]:
    first, rss = peak_rss(command)
    times = []
    for sample in [first] + [run(command) for _ in range(runs)]:
        if sample.code not in codes:
            return Row(name, runner, "failed", note=diagnostic(sample.stderr)), ""
        if expected is not None and sample.stdout != expected:
            last = sample.stdout.strip().splitlines()
            return Row(name, runner, "mismatch", note=last[-1] if last else "no output"), ""
        expected = sample.stdout
        if sample is not first:
            times.append(sample.seconds)
    return Row(name, runner, "ok", statistics.median(times), min(times), rss), expected


def compile_vm(name: str, runner: str, source: Path, bytecode: Path) -> Row | None:
    compiled = run([str(EXE), "compile", str(source), "-o", str(bytecode)])
    if compiled.code == 0:
        return None
    reason = diagnostic(compiled.stderr)
    status = "unsupported" if reason.startswith("LOWER-UNSUPPORTED") else "failed"
    return Row(name, runner, status, note=reason)


def benchmark(name: str, size: int, runs: int, commands: dict[str, list[str] | None],
              workdir: Path) -> list[Row]:
    source = scaled_source(name, size, workdir)
    rows = []
    expected = None
    for runner, command in commands.items():
        if command is None:
            rows.append(Row(name, runner, "missing", note="not built"))
            continue
        if runner == "python":
            argv = command + [str(PYTHON / f"{name.replace('-', '_')}.py"), str(size)]
        elif runner == "vm":
            bytecode = workdir / f"{name}.agcb"
            failure = compile_vm(name, runner, source, bytecode)
            if failure:
                rows.append(failure)
                continue
            argv = command + [str(bytecode)]
        else:
            argv = command + [str(source)]
        row, output = measure(name, runner, argv, runs, expected)
        if row.status == "ok" and expected is None:
            expected = output
        rows.append(row)
    return rows


def startup(runs: int, commands: dict[str, list[str] | None], workdir: Path) -> list[Row]:
    rows = []
    for runner, command in commands.items():
        if command is None:
            rows.append(Row("hello", runner, "missing", note="not built"))
            continue
        if runner == "python":
            argv = command + ["-c", "print('hello')"]
        elif runner == "vm":
            bytecode = workdir / "hello.agcb"
            failure = compile_vm("hello", runner, HELLO, bytecode)
            if failure:
                rows.append(failure)
                continue
            argv = command + [str(bytecode)]
        else:
            argv = command + [str(HELLO)]
        rows.append(measure("hello", runner, argv, runs, "hello\n")[0])
    return rows


def front_end(runs: int, workdir: Path) -> list[Row]:
    """Times the front end of dist/agentica (35.2): `check` of files of growing size and a small `agentica test`.

    gherkin.agc and parser.agc have no main, which `check` does not need."""
    if not EXE.exists():
        return [Row("check", "exe", "missing", note="not built")]
    wrapper = workdir / "gherkin_main.agc"
    wrapper.write_text(GHERKIN_MAIN)
    small = workdir / "small_test.agc"
    small.write_text(SMALL_TEST)
    cases = [
        ("check hello.agc", [str(EXE), "check", str(HELLO)], (0,)),
        ("check gherkin.agc", [str(EXE), "check", str(GHERKIN)], (0,)),
        ("check parser.agc", [str(EXE), "check", str(PARSER)], (0,)),
        ("check gherkin_main.agc", [str(EXE), "check", str(wrapper)], (0,)),
        ("check front_end.agc", [str(EXE), "check", str(FRONT_END)], (0,)),
        ("test small_test.agc", [str(EXE), "test", str(small)], (0,)),
    ]
    return [measure(name, "exe", command, runs, None, codes)[0] for name, command, codes in cases]


def load_note() -> str:
    one, five, fifteen = os.getloadavg()
    note = f"load average {one:.2f} {five:.2f} {fifteen:.2f}, {os.cpu_count()} cores"
    return f"{note}; measured under load" if one > BUSY_LOAD else note


def table(rows: list[Row]) -> str:
    baseline = {row.name: row.median for row in rows if row.runner == "python" and row.status == "ok"}
    lines = ["| program | runner | median s | min s | max RSS MB | vs python | note |",
             "|---|---|---:|---:|---:|---:|---|"]
    for row in rows:
        if row.status != "ok":
            lines.append(f"| {row.name} | {row.runner} | {row.status} | | | | {row.note} |")
            continue
        ratio = ""
        rss = "n/a" if row.rss_kb is None else f"{row.rss_kb / 1024:.1f}"
        if row.name in baseline and row.median > 0:
            ratio = f"{baseline[row.name] / row.median:.1f}x"
        lines.append(f"| {row.name} | {row.runner} | {row.median:.3f} | {row.best:.3f} | "
                     f"{rss} | {ratio} | |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Time Agentica benchmark programs on each runner.")
    parser.add_argument("--runs", type=int, default=5, help="runs per program and runner (default 5)")
    parser.add_argument("--size", type=int, default=1, help="work multiplier for every program (default 1)")
    parser.add_argument("--runners", default="exe,vm,python",
                        help="comma-separated runners: exe (agentica FILE.agc), vm (agentica run FILE.agcb), python")
    parser.add_argument("--only", default="", help="comma-separated program names")
    parser.add_argument("--no-startup", action="store_true", help="skip the hello.agc start-up check")
    args = parser.parse_args()
    if args.runs < 1 or args.size < 1:
        parser.error("--runs and --size must be at least 1")
    names = [name for name in args.only.split(",") if name] or NAMES
    for name in names:
        if name not in NAMES:
            parser.error(f"unknown program {name}; choose from {', '.join(NAMES)}")
    commands = runners([runner for runner in args.runners.split(",") if runner])
    workdir = Path(tempfile.mkdtemp(prefix="agentica-bench-"))
    rows = []
    try:
        if not args.no_startup:
            print(f"## Start-up (hello.agc, {args.runs} runs)\n")
            startup_rows = startup(args.runs, commands, workdir)
            rows.extend(startup_rows)
            print(table(startup_rows), flush=True)
            print()
            if "exe" in commands:
                print(f"## Front end (check and test, {args.runs} runs; {load_note()})\n")
                front_rows = front_end(args.runs, workdir)
                rows.extend(front_rows)
                print(table(front_rows), flush=True)
                print()
        print(f"## Programs (size {args.size}, {args.runs} runs)\n")
        program_rows = []
        for name in names:
            program_rows.extend(benchmark(name, args.size, args.runs, commands, workdir))
            print(f"{name}: done", file=sys.stderr, flush=True)
        rows.extend(program_rows)
        print(table(program_rows))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    return 1 if any(row.status in ("failed", "mismatch") for row in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
