#!/usr/bin/env python3
"""The conformance matrix: which test modules prove each promised area, and the evidence a system produced.

    conformance.py modules AREA            print the modules of an area, separated by spaces (the Makefile uses it)
    conformance.py areas                   print the area names, in the order the workflow runs them
    conformance.py host PLATFORM           fail unless this machine is the PLATFORM that the job says it is
    conformance.py report DIR [--platform P]
                                           read the JUnit files that `make conformance-*` wrote under DIR, print what
                                           ran on this system and exit 1 when an area has no evidence

The four platform names are those of release.py: linux-x86_64, windows-x86_64, macos-x86_64 and macos-arm64. A module
that is not in an area is in EXCLUDED with the reason, and tests/test_conformance.py checks that every tests/test_*.py
file is in one or the other, so a new test cannot stay out of the matrix by accident. Python's standard library only.

What counts as evidence: every module of an area has a JUnit file with no failure and at least one passed case, and every
skipped case names a host-only reason (HOST_ONLY, a concrete capability of one system) or is a case of the other test
tier. A real product bug that a system has not fixed yet may be skipped with a "known-issue: #N ..." reason (KNOWN_ISSUE);
the report lists every such skip as an open gap, so the gap stays visible. A skip for any other reason, such as a tool
that was not found, fails the report: CI must install the tool.
"""
from __future__ import annotations

import argparse
import os
import platform
import re
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PLATFORMS = ("linux-x86_64", "windows-x86_64", "macos-x86_64", "macos-arm64")

# Prefix of the reason of a skip that belongs to one system. The text after it says which capability the other systems
# lack, so a reader of the report can judge it: "host-only: Windows has no /proc".
HOST_ONLY = "host-only:"

# A skip for a product bug with an open issue: "known-issue: #425 the pkg/ roots ignore ';' on Windows".
KNOWN_ISSUE = re.compile(r"known-issue: #\d+ \S")

# Reasons that only mean "this case belongs to the other tier" (tests/conftest.py, tests/agentica_test.py).
TIER_REASONS = ("not selected in this test tier", "slow tier only", "fast tier only", "no cases in this tier")

# area -> (what it proves, modules). The order is the order of the workflow steps. The areas that the Makefile and the
# workflow run on their own (the build, the fixed point, the C tests and the destructive filesystem group) are steps of
# the job, not modules, so they are not here.
AREAS = {
    "cli": (
        "the command line: options, diagnostics, run, compile, test, modules, the single binary",
        [
            "tests/test_cli_forms.py", "tests/test_examples.py", "tests/test_modules.py",
            "tests/test_source_utf8.py", "tests/test_bdd.py", "tests/test_bdd_posix.py",
            "tests/test_bdd_integration.py", "tests/test_unit_test.py", "tests/test_vm_diff_8.py",
            "tests/test_single_binary.py", "tests/test_stdlib_distribution.py",
        ],
    ),
    "spec": (
        "the rules of the language through `check`: lexer, parser, checker, modules, bytecode",
        [
            "tests/test_spec_alias.py", "tests/test_spec_bytecode.py", "tests/test_spec_checker_defaults.py",
            "tests/test_spec_checker.py", "tests/test_spec_checker_rest.py", "tests/test_spec_diagnostic.py",
            "tests/test_spec_lexer.py", "tests/test_spec_modules.py", "tests/test_spec_parser.py",
            "tests/test_spec_patterns.py",
        ],
    ),
    "golden": (
        "the builtins and the VM, program by program, against the golden outputs",
        [
            "tests/test_vm_diff_1.py", "tests/test_vm_diff_2.py", "tests/test_vm_diff_3.py",
            "tests/test_vm_diff_4.py", "tests/test_vm_diff_5.py", "tests/test_vm_diff_6.py",
            "tests/test_vm_diff_7.py", "tests/test_vm_bits.py", "tests/test_vm_stack.py",
        ],
    ),
    "library": (
        "std/ modules and standard streams: binary, toml, prelude, logger, clock, stdout and stderr",
        [
            "tests/test_std_binary.py", "tests/test_std_toml.py", "tests/test_stdlib_prelude.py",
            "tests/test_vm_logger.py", "tests/test_vm_monotonic.py", "tests/test_vm_stdout.py",
        ],
    ),
    "files": (
        "files, directories, paths, metadata and locks",
        [
            "tests/test_filesystem.py", "tests/test_source_paths.py", "tests/test_vm_os.py",
            "tests/test_vm_file_lines.py", "tests/test_windows_metadata_and_locks.py",
        ],
    ),
    "processes": (
        "Process, the private channel between a parent and its child, stop signals and the bootstrap binary",
        [
            "tests/test_process.py", "tests/test_process_bdd.py", "tests/test_process_lifecycle.py",
            "tests/test_process_windows.py", "tests/test_vm_child_channel.py",
            "tests/test_vm_child_channel_posix.py", "tests/test_vm_stop.py", "tests/test_vm_test_protocol.py",
            "tests/test_platform_bootstrap.py", "tests/test_windows_console_stop.py",
        ],
    ),
    "tasks": (
        "tasks, channels and timers",
        ["tests/test_vm_channel.py", "tests/test_vm_task_map.py", "tests/test_vm_latency.py", "tests/test_vm_shared.py"],
    ),
    "network": (
        "TCP, TLS and HTTP, client and server, against independent peers",
        ["tests/test_vm_tcp.py", "tests/test_vm_tls.py", "tests/test_vm_http.py"],
    ),
}

# Modules that are not a promised feature, or that another route runs, with the reason. test_conformance.py keeps this
# list and AREAS together equal to the test modules of the repository.
EXCLUDED = {
    "tests/test_bdd_cleanup.py": "destructive: make test-remove-actions runs it in the scratch of an Actions runner",
    "tests/test_vm_os_remove.py": "destructive: make test-remove-actions runs it in the scratch of an Actions runner",
    "tests/test_windows_filesystem_safety.py":
        "destructive: make test-remove-actions runs it in the scratch of an Actions runner",
    "tests/test_conformance.py": "checks this manifest itself, in make test on Linux",
    "tests/test_docker_tests.py": "the Docker launcher of the Linux developer container, not the product",
    "tests/test_release_tools.py": "tools/release.py packing; release.yml runs the packages on all four systems",
    "tests/test_site_examples.py": "the code blocks of the site, checked with the site build",
    "tests/test_frontend_bytecode.py": "frozen goldens of the front end stages; the spec and golden areas run it live",
    "tests/test_frontend_catalog.py": "frozen goldens of the front end stages; the spec and golden areas run it live",
    "tests/test_frontend_check.py": "frozen goldens of the front end stages; the spec and golden areas run it live",
    "tests/test_frontend_lexer.py": "frozen goldens of the front end stages; the spec and golden areas run it live",
    "tests/test_frontend_lower.py": "frozen goldens of the front end stages; the spec and golden areas run it live",
    "tests/test_frontend_modules.py": "frozen goldens of the front end stages; the spec and golden areas run it live",
    "tests/test_frontend_parser.py": "frozen goldens of the front end stages; the spec and golden areas run it live",
    "tests/test_frontend_refreeze.py": "tools/refreeze.py, a developer tool",
    "tests/test_stdlib_docs.py": "a check of the sources (docs on every export), the same on every system",
    "tests/test_stdlib_modules.py": "a check of stdlib/MODULES, the same on every system",
    "tests/test_style_line_width.py": "a check of the sources (line width), the same on every system",
    "tests/test_vm_style.py": "a check of the C sources (style), the same on every system",
    "tests/test_timeout_guard.py": "the time limit of the test harness itself",
    "tests/test_vm_trace.py": "VM tracing, a developer tool of the Linux debug builds",
    "tests/test_vm_multicore.py": "programs on several schedulers; step 13b brings them to Windows and macOS",
}


def modules(area: str) -> list[str]:
    """The test modules of an area; an unknown name is a mistake of the caller."""
    if area not in AREAS:
        raise SystemExit(f"conformance.py: unknown area {area!r}; areas: {' '.join(AREAS)}")
    return AREAS[area][1]


def all_modules() -> list[str]:
    """Every tests/test_*.py file, as the Makefile names it."""
    return sorted(f"tests/{path.name}" for path in (ROOT / "tests").glob("test_*.py"))


def unclassified() -> list[str]:
    """Test modules that are in no area and not excluded."""
    known = {m for _, mods in AREAS.values() for m in mods} | set(EXCLUDED)
    return [m for m in all_modules() if m not in known]


def this_platform() -> str:
    """The platform name of the machine that runs this script, in the names of release.py."""
    machine = platform.machine().lower()
    arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64" if machine in ("x86_64", "amd64") else machine
    if sys.platform.startswith("linux"):
        system = "linux"
    elif sys.platform == "darwin":
        system = "macos"
    elif sys.platform in ("win32", "cygwin", "msys"):
        system = "windows"
    else:
        system = sys.platform
    return f"{system}-{arch}"


def check_host(expected: str) -> None:
    """A runner that is not what its job name says would write evidence for the wrong system."""
    if expected not in PLATFORMS:
        raise SystemExit(f"conformance.py: unknown platform {expected!r}; platforms: {' '.join(PLATFORMS)}")
    actual = this_platform()
    if actual != expected:
        raise SystemExit(f"conformance.py: this job is {expected} but the machine is {actual}")
    print(f"host: {actual}")


class Count:
    """What one module did: passed cases, host-only skips by reason, other-tier skips, and the problems found."""

    def __init__(self) -> None:
        self.passed = 0
        self.tier = 0
        self.host_only: dict[str, int] = {}
        self.gaps: dict[str, int] = {}
        self.problems: list[str] = []

    @property
    def skipped_host_only(self) -> int:
        return sum(self.host_only.values())


def read_module(path: Path) -> Count:
    """Count the cases of one JUnit file."""
    count = Count()
    if not path.is_file():
        count.problems.append("no JUnit file (the module did not finish)")
        return count
    try:
        root = ElementTree.parse(path).getroot()
    except ElementTree.ParseError as error:
        count.problems.append(f"unreadable JUnit file: {error}")
        return count
    for case in root.iter("testcase"):
        name = f"{case.get('classname', '')}::{case.get('name', '')}"
        if case.find("failure") is not None or case.find("error") is not None:
            count.problems.append(f"failed: {name}")
            continue
        skipped = case.find("skipped")
        if skipped is None:
            count.passed += 1
            continue
        reason = (skipped.get("message") or skipped.text or "").strip()
        reason = reason.split("\n")[0]
        if reason.startswith(HOST_ONLY):
            reason = reason[len(HOST_ONLY):].strip()
            count.host_only[reason] = count.host_only.get(reason, 0) + 1
        elif KNOWN_ISSUE.match(reason):
            count.gaps[reason] = count.gaps.get(reason, 0) + 1
        elif any(tier in reason for tier in TIER_REASONS):
            count.tier += 1
        else:
            count.problems.append(f"skipped without a host-only reason: {name}: {reason}")
    if count.passed == 0 and not count.problems and count.skipped_host_only == 0 and count.tier == 0 \
            and not count.gaps:
        count.problems.append("no case ran")
    return count


def report(directory: Path, name: str) -> tuple[str, bool]:
    """The markdown report of one system and whether every area has its evidence."""
    lines = [f"## Conformance on {name}", "", "| area | modules | passed | host-only skips | other tier | problems |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    detail: list[str] = []
    reasons: dict[str, int] = {}
    gaps: dict[str, int] = {}
    ok = True
    for area, (_, mods) in AREAS.items():
        counts = []
        for module in mods:
            count = read_module(directory / area / (Path(module).stem + ".xml"))
            # A module that is host-only on this system proves nothing here and says why; it needs no passed case.
            host_only_module = count.passed == 0 and count.skipped_host_only > 0 and not count.problems
            counts.append((module, count, host_only_module))
        passed = sum(c.passed for _, c, _ in counts)
        problems = [f"{module}: {p}" for module, c, _ in counts for p in c.problems]
        if passed == 0:
            problems.append(f"{area}: no case passed")
        for _, c, _ in counts:
            for reason, number in c.host_only.items():
                reasons[reason] = reasons.get(reason, 0) + number
        for _, c, _ in counts:
            for reason, number in c.gaps.items():
                gaps[reason] = gaps.get(reason, 0) + number
        ran = sum(1 for _, c, host in counts if not host and not c.problems)
        lines.append(
            f"| {area} | {ran}/{len(mods)} | {passed} | {sum(c.skipped_host_only for _, c, _ in counts)} | "
            f"{sum(c.tier for _, c, _ in counts)} | {len(problems)} |")
        for module, c, host in counts:
            if host:
                detail.append(f"- {area}: {module} is host-only here ({'; '.join(c.host_only)})")
        detail.extend(f"- **{area}**: {p}" for p in problems)
        if problems:
            ok = False
    lines.append("")
    if reasons:
        lines.append("Host-only skips (a capability that only some systems have):")
        lines.append("")
        lines.extend(f"- {number} x {reason}" for reason, number in sorted(reasons.items()))
        lines.append("")
    if gaps:
        lines.append("Open gaps (skipped for a product bug with an open issue):")
        lines.append("")
        lines.extend(f"- {number} x {reason}" for reason, number in sorted(gaps.items()))
        lines.append("")
    if detail:
        lines.extend(["Details:", "", *detail, ""])
    lines.append("Result: " + ("every area has evidence." if ok else "evidence is missing."))
    return "\n".join(lines) + "\n", ok


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("modules").add_argument("area")
    commands.add_parser("areas")
    commands.add_parser("host").add_argument("platform")
    reporter = commands.add_parser("report")
    reporter.add_argument("directory")
    reporter.add_argument("--platform", default=None)
    args = parser.parse_args(argv)
    if args.command == "modules":
        print(" ".join(modules(args.area)))
    elif args.command == "areas":
        print(" ".join(AREAS))
    elif args.command == "host":
        check_host(args.platform)
    else:
        name = args.platform or this_platform()
        text, ok = report(Path(args.directory), name)
        sys.stdout.write(text)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as handle:
                handle.write(text)
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
