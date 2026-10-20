#!/usr/bin/env python3
"""The conformance matrix: which test modules prove each promised area, and the evidence a system produced.

    conformance.py modules AREA            print the modules of an area, separated by spaces (the Makefile uses it)
    conformance.py areas                   print the area names, in the order the workflow runs them
    conformance.py host PLATFORM           fail unless this machine is the PLATFORM that the job says it is
    conformance.py report DIR [--platform P]
                                           read the JUnit files that `make conformance-*` wrote under DIR, print what
                                           ran on this system and exit 1 when an area has no evidence; it also writes
                                           DIR/summary.json, the outcome of every case on this system
    conformance.py merge DIR               read DIR/*/summary.json of the four systems and exit 1 when a system is
                                           missing or a case ran on none of them

The four platform names are those of release.py: linux-x86_64, windows-x86_64, macos-x86_64 and macos-arm64. A module
that is not in an area is in EXCLUDED with the reason, and tests/test_conformance.py checks that every tests/test_*.py
file is in one or the other, so a new test cannot stay out of the matrix by accident. Python's standard library only.

What counts as evidence: every module of an area has a JUnit file with no failure and at least one passed case, and every
skipped case is one of three kinds:
- host-only (HOST_ONLY): the system really lacks a capability (POSIX signals, FIFOs, Windows handles). The pair (module
  or golden fixture, system) must be in HOST_ONLY_ALLOWED, which a reviewer reads; a harness limit or a product gap
  is not host-only.
- known-issue (KNOWN_ISSUE): the promise holds on the system but its test is missing, or the product has a bug. The
  issue number must be in KNOWN_ISSUES; the report lists every such skip as an open gap.
- a case of the other test tier.
A skip for any other reason, such as a tool that was not found, fails the report: CI must install the tool. The merge
step fails when a case ran on none of the four systems.
"""
from __future__ import annotations

import argparse
import json
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
KNOWN_ISSUE = re.compile(r"known-issue: #(\d+) \S")

# The open issues that a known-issue skip may name: number -> what is missing. Closing an issue removes its skips and
# its line here in the same pull request.
KNOWN_ISSUES = {
    425: "Windows: the pkg/ library roots ignore ';', drive paths and %LOCALAPPDATA%",
    431: "Windows: a stdin read can hold a pool thread",
    432: "Windows: no independent peer for the child channel protocol (two pipes at descriptors 3 and 4)",
    433: "Windows: no test for blocking stream files (named pipes instead of FIFOs)",
    434: "Windows: process cleanup and handoff cases are tested with /bin/sh or POSIX signals only",
    435: "Windows: descriptor leak checks count /proc/self/fd",
    436: "macOS and Windows: golden fixtures for paths, errno text and processes only run on Linux",
    437: "Windows: Ctrl+C through the CLI and a signal during a blocked wait have no test",
    440: "Windows: standard output that is a socket has no test",
}

# Reasons that only mean "this case belongs to the other tier" (tests/conftest.py, tests/agentica_test.py).
TIER_REASONS = ("not selected in this test tier", "slow tier only", "fast tier only", "no cases in this tier")

# The modules whose every case needs something that only Windows has.
WINDOWS_ONLY_MODULES = frozenset({
    "tests/test_process_windows.py", "tests/test_windows_console_stop.py", "tests/test_windows_filesystem_safety.py",
    "tests/test_windows_metadata_and_locks.py",
})

# The modules that have some cases a system cannot run because it really lacks the capability. A case of a module that
# is not listed for its system, as host-only, fails the report. Windows lacks POSIX signals, FIFOs, /dev/stdin, modes and
# colon names; macOS lacks /dev/full and non-UTF-8 names; the other systems lack the Windows-only modules above.
# Golden fixtures named -posix or -windows are allowed by name (host_only_fixture).
_NEEDS_POSIX = frozenset({
    "tests/test_bdd_integration.py", "tests/test_bdd_posix.py", "tests/test_filesystem.py",
    "tests/test_source_paths.py", "tests/test_vm_child_channel_posix.py", "tests/test_vm_diff_8.py",
    "tests/test_vm_os.py", "tests/test_vm_stdout.py", "tests/test_vm_stop.py",
})
_NEEDS_LINUX = frozenset({"tests/test_vm_diff_8.py", "tests/test_vm_stdout.py"})
HOST_ONLY_ALLOWED = {
    "linux-x86_64": WINDOWS_ONLY_MODULES,
    "windows-x86_64": _NEEDS_POSIX,
    "macos-x86_64": WINDOWS_ONLY_MODULES | _NEEDS_LINUX,
    "macos-arm64": WINDOWS_ONLY_MODULES | _NEEDS_LINUX,
}

# The reason of a golden fixture that holds the answers of the other family of systems (tests/vm_diff_support.py).
FIXTURE_VARIANT = re.compile(r"^([\w.-]+-(posix|windows)\.agc) holds the answers of")

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

# The destructive filesystem group (make test-remove-actions): it writes one JUnit file, destructive/remove-actions.xml,
# and these modules must each have passed there. The group is the same pytest run as the area files, but in the scratch
# of an ephemeral runner, so it cannot be an area of the make targets.
DESTRUCTIVE = {
    "posix": ["tests/test_vm_os_remove.py", "tests/test_bdd_cleanup.py"],
    "windows": ["tests/test_windows_filesystem_safety.py"],
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
    """What one module did: passed cases, skips by kind, and the problems found. `cases` keeps the outcome of each case
    ("pass", "host-only", "known-issue" or "tier") for the merge of the four systems."""

    def __init__(self) -> None:
        self.passed = 0
        self.tier = 0
        self.host_only: dict[str, int] = {}
        self.gaps: dict[str, int] = {}
        self.problems: list[str] = []
        self.cases: dict[str, str] = {}
        self.passed_by_module: dict[str, int] = {}

    @property
    def skipped_host_only(self) -> int:
        return sum(self.host_only.values())


def host_only_allowed(platform_name: str, module: str, reason: str) -> bool:
    """Whether a host-only skip is on the reviewed list: a golden variant by its name, any other case by its module."""
    variant = FIXTURE_VARIANT.match(reason)
    if variant:
        # A -windows fixture is host-only on the systems that are not Windows, and a -posix one on Windows.
        return (variant.group(2) == "windows") != platform_name.startswith("windows")
    return module in HOST_ONLY_ALLOWED.get(platform_name, frozenset())


def read_module(path: Path, module: str, platform_name: str | None = None) -> Count:
    """Count the cases of one JUnit file. `platform_name` None skips the check of the reviewed host-only list."""
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
        classname = case.get("classname", "")
        name = f"{classname}::{case.get('name', '')}"
        if case.find("failure") is not None or case.find("error") is not None:
            count.problems.append(f"failed: {name}")
            continue
        skipped = case.find("skipped")
        if skipped is None:
            count.passed += 1
            count.cases[name] = "pass"
            found = re.match(r"tests\.(test_\w+)", classname)
            if found:
                count.passed_by_module[found.group(1)] = count.passed_by_module.get(found.group(1), 0) + 1
            continue
        reason = (skipped.get("message") or skipped.text or "").strip()
        reason = reason.split("\n")[0]
        known = KNOWN_ISSUE.match(reason)
        if reason.startswith(HOST_ONLY):
            reason = reason[len(HOST_ONLY):].strip()
            if platform_name is not None and not host_only_allowed(platform_name, module, reason):
                count.problems.append(f"host-only skip that is not on the reviewed list of {platform_name}: "
                                      f"{name}: {reason}")
                continue
            count.host_only[reason] = count.host_only.get(reason, 0) + 1
            count.cases[name] = "host-only"
        elif known:
            if int(known.group(1)) not in KNOWN_ISSUES:
                count.problems.append(f"skipped for an issue that is not in KNOWN_ISSUES: {name}: {reason}")
                continue
            count.gaps[reason] = count.gaps.get(reason, 0) + 1
            count.cases[name] = "known-issue"
        elif any(tier in reason for tier in TIER_REASONS):
            count.tier += 1
            count.cases[name] = "tier"
        else:
            count.problems.append(f"skipped without a host-only reason: {name}: {reason}")
    if count.passed == 0 and not count.problems and count.skipped_host_only == 0 and count.tier == 0 \
            and not count.gaps:
        count.problems.append("no case ran")
    return count


def read_environment(directory: Path, area: str) -> dict[str, str]:
    """The `slow=... sweep=...` line that `make conformance-area/AREA` wrote before it ran the area."""
    path = directory / area / "env.txt"
    if not path.is_file():
        return {}
    return dict(word.split("=", 1) for word in path.read_text(encoding="utf-8").split() if "=" in word)


def destructive_modules(platform_name: str) -> list[str]:
    return DESTRUCTIVE["windows" if platform_name.startswith("windows") else "posix"]


def report(directory: Path, name: str) -> tuple[str, bool]:
    """The markdown report of one system and whether every area has its evidence. It also writes summary.json."""
    lines = [f"## Conformance on {name}", "", "| area | modules | passed | host-only skips | open gaps | other tier | problems |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    detail: list[str] = []
    reasons: dict[str, int] = {}
    gaps: dict[str, int] = {}
    summary: dict[str, str] = {}
    tiers: dict[str, dict[str, str]] = {}
    ok = True
    for area, (_, mods) in AREAS.items():
        counts = []
        for module in mods:
            count = read_module(directory / area / (Path(module).stem + ".xml"), module, name)
            # A module that is host-only on this system proves nothing here and says why; it needs no passed case.
            host_only_module = count.passed == 0 and count.skipped_host_only > 0 and not count.problems
            counts.append((module, count, host_only_module))
            summary.update({f"{module}::{case}": outcome for case, outcome in count.cases.items()})
        tiers[area] = read_environment(directory, area)
        passed = sum(c.passed for _, c, _ in counts)
        problems = [f"{module}: {p}" for module, c, _ in counts for p in c.problems]
        if passed == 0:
            problems.append(f"{area}: no case passed")
        if not tiers[area]:
            problems.append(f"{area}: no env.txt (the area was not run by make conformance-area)")
        for _, c, _ in counts:
            for reason, number in c.host_only.items():
                reasons[reason] = reasons.get(reason, 0) + number
            for reason, number in c.gaps.items():
                gaps[reason] = gaps.get(reason, 0) + number
        ran = sum(1 for _, c, host in counts if not host and not c.problems)
        lines.append(
            f"| {area} | {ran}/{len(mods)} | {passed} | {sum(c.skipped_host_only for _, c, _ in counts)} | "
            f"{sum(sum(c.gaps.values()) for _, c, _ in counts)} | {sum(c.tier for _, c, _ in counts)} | "
            f"{len(problems)} |")
        for module, c, host in counts:
            if host:
                detail.append(f"- {area}: {module} is host-only here ({'; '.join(c.host_only)})")
        detail.extend(f"- **{area}**: {p}" for p in problems)
        if problems:
            ok = False
    path = directory / "destructive" / "remove-actions.xml"
    destructive = read_module(path, "tools/run_remove_actions.py", name)
    if not path.is_file() and not os.environ.get("CI"):
        # A developer machine cannot run the destructive group (make tests KIND=files runs it in Docker).
        destructive.problems.clear()
        detail.append("- destructive: not run here (make test-remove-actions runs it on an ephemeral CI runner)")
    else:
        for module in destructive_modules(name):
            if not destructive.passed_by_module.get(Path(module).stem):
                destructive.problems.append(f"{module} has no passed case in the destructive group")
    lines.append(f"| destructive | {len(destructive_modules(name))} | {destructive.passed} | "
                 f"{destructive.skipped_host_only} | {sum(destructive.gaps.values())} | {destructive.tier} | "
                 f"{len(destructive.problems)} |")
    detail.extend(f"- **destructive**: {p}" for p in destructive.problems)
    summary.update({f"destructive::{case}": outcome for case, outcome in destructive.cases.items()})
    if destructive.problems:
        ok = False
    lines.append("")
    slow = {env.get("slow", "") for env in tiers.values() if env}
    sweep = tiers.get("golden", {}).get("sweep", "unset")
    lines.append(f"Test tier: {'fast' if slow <= {''} else 'slow included'} in every area. "
                 f"Golden sweep: {sweep or 'unset'}.")
    lines.append("")
    if reasons:
        lines.append("Host-only skips (a capability that only some systems have):")
        lines.append("")
        lines.extend(f"- {number} x {reason}" for reason, number in sorted(reasons.items()))
        lines.append("")
    if gaps:
        lines.append("Open gaps (the promise holds here but its test is missing, or the product has a bug):")
        lines.append("")
        lines.extend(f"- {number} x {reason}" for reason, number in sorted(gaps.items()))
        lines.append("")
    if detail:
        lines.extend(["Details:", "", *detail, ""])
    lines.append("Result: " + ("every area has evidence." if ok else "evidence is missing."))
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "summary.json").write_text(json.dumps({"platform": name, "cases": summary}, sort_keys=True),
                                            encoding="utf-8")
    return "\n".join(lines) + "\n", ok


def merge(directory: Path) -> tuple[str, bool]:
    """Compare the summaries of the four systems: every case must have passed on at least one of them, and a case
    that no system ran is a test that proves nothing."""
    summaries = {}
    for path in sorted(directory.glob("**/summary.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        summaries[data["platform"]] = data["cases"]
    lines = ["## Conformance across the four systems", ""]
    problems = [f"no summary of {platform_name}" for platform_name in PLATFORMS if platform_name not in summaries]
    cases: dict[str, dict[str, str]] = {}
    for platform_name, found in summaries.items():
        for case, outcome in found.items():
            cases.setdefault(case, {})[platform_name] = outcome
    # A slow-tier case is not selected anywhere in the fast tier (the other tier runs it), whatever else a system says.
    never = sorted(case for case, by in cases.items() if "pass" not in by.values() and "tier" not in by.values())
    problems.extend(f"ran on no system: {case} ({', '.join(f'{p}: {o}' for p, o in sorted(cases[case].items()))})"
                    for case in never)
    on_all = sum(1 for by in cases.values() if sum(1 for o in by.values() if o == "pass") == len(PLATFORMS))
    lines.append(f"{len(cases)} cases, {on_all} passed on all four systems.")
    lines.append("")
    lines.append("| system | passed | host-only | open gaps |")
    lines.append("| --- | ---: | ---: | ---: |")
    for platform_name in PLATFORMS:
        found = summaries.get(platform_name, {})
        lines.append(f"| {platform_name} | {sum(1 for o in found.values() if o == 'pass')} | "
                     f"{sum(1 for o in found.values() if o == 'host-only')} | "
                     f"{sum(1 for o in found.values() if o == 'known-issue')} |")
    lines.append("")
    if problems:
        lines.extend(["Problems:", "", *[f"- {problem}" for problem in problems], ""])
    lines.append("Result: " + ("every case ran on a system." if not problems else "evidence is missing."))
    return "\n".join(lines) + "\n", not problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("modules").add_argument("area")
    commands.add_parser("areas")
    commands.add_parser("host").add_argument("platform")
    reporter = commands.add_parser("report")
    reporter.add_argument("directory")
    reporter.add_argument("--platform", default=None)
    commands.add_parser("merge").add_argument("directory")
    args = parser.parse_args(argv)
    if args.command == "modules":
        print(" ".join(modules(args.area)))
    elif args.command == "areas":
        print(" ".join(AREAS))
    elif args.command == "host":
        check_host(args.platform)
    else:
        if args.command == "merge":
            text, ok = merge(Path(args.directory))
        else:
            text, ok = report(Path(args.directory), args.platform or this_platform())
        sys.stdout.write(text)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as handle:
                handle.write(text)
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
