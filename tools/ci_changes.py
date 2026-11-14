#!/usr/bin/env python3
"""The `changes` job of ci.yml: which parts of CI a pull request needs, from the files it changes.

    git diff --name-only HEAD^1 HEAD | ci_changes.py     classify the changed files (one per line on stdin)
    ci_changes.py --all                                  everything runs (a push, a manual run, a failed diff)

It prints the lines a step appends to $GITHUB_OUTPUT:

    c             the C half (sanitizers, TSan, lint, layers, JIT on arm64)
    trace         make vm-trace-off
    cchecker      the cchecker job
    std_only      the light path: only portable std/ modules, their tests and docs changed
    std_tests     on the light path, the test modules of the changed std modules
    std_fixtures  on the light path, the VM goldens that import them

A std module is portable when the front end does not compile it in: not the files that `compiler/` (with
`compiler/embedded/`) imports, transitively, and not FRONT_END_STD.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The VM, the front end or tools/release.py also know std/logger, std/actor and std/eag by name.
FRONT_END_STD = ("MODULES", "CORE", "agentica.toml", "prelude/", "test/", "bdd/", "bdd.agc", "analysis.agc",
                 "logger.agc", "actor.agc", "eag.agc")
DOCS = ("docs/", "site/content/")
# The modules that check every std module or its page; every light path runs them.
ALWAYS = (
    "tests/test_error_kinds.py", "tests/test_frontend_catalog.py", "tests/test_frontend_modules.py",
    "tests/test_single_binary.py", "tests/test_site_examples.py", "tests/test_stdlib_docs.py",
    "tests/test_stdlib_modules.py", "tests/test_style_line_width.py", "tests/test_unit_test.py",
)
C_PATHS = re.compile(
    r"vm/|tests/fixtures/native/|examples/ffi/[^/]*\.c$|Makefile$|mk/|\.gitmodules$|\.clang-tidy$"
    r"|\.github/workflows/ci\.yml$|\.github/actions/"
)
CCHECKER_PATHS = re.compile(
    r"vm/|Makefile$|mk/|\.gitmodules$|\.clang-tidy$|cchecker\.toml$|cchecker-baseline\.json$"
    r"|\.github/workflows/ci\.yml$|\.github/actions/"
)
TRACE_PATHS = re.compile(r"vm/trace\.|vm/tests/trace_test\.c$")
# tests/std/ runs through tests/test_unit_test.py; the frozen manifests read their own copy of stdlib/.
SELF_TESTED = {("tests", "std")}
FROZEN = ("tests", "fixtures", "frontend", "frozen")
# A module that many tests use (std/queue is the std module of the front-end tests) takes the full path.
MAX_TESTS = 15
IMPORT = re.compile(r'^import\b.*\bfrom\s+"std/([\w/]+)"', re.M)


class FullPath(Exception):
    pass


def read(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def tracked(root, *folders):
    listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *folders],
                            check=True, capture_output=True).stdout
    return [Path(name) for name in listed.decode("utf-8").split("\0") if name]


def std_modules(root):
    """Every std module by name (`queue`, `bdd/tags`) and the std modules it imports."""
    return {
        str(rel.relative_to("stdlib").with_suffix("")): set(IMPORT.findall(read(root / rel)))
        for rel in tracked(root, "stdlib")
        if rel.suffix == ".agc"
    }


def front_end_std(root, modules):
    """The std modules that the binary's front end carries compiled in."""
    sources = [root / rel for rel in tracked(root, "compiler") if rel.suffix == ".agc"]
    todo = [name for path in sources for name in IMPORT.findall(read(path))]
    todo += [name for name in modules if (name + ".agc").startswith(FRONT_END_STD)]
    seen = set()
    while todo:
        name = todo.pop()
        if name not in seen:
            seen.add(name)
            todo.extend(modules.get(name, ()))
    return seen


def dependents(changed, modules):
    """The changed modules and every module that imports one of them, transitively."""
    found = set(changed)
    grew = True
    while grew:
        grew = False
        for name, imports in modules.items():
            if name not in found and imports & found:
                found.add(name)
                grew = True
    return found


def module_of(path, portable):
    """The portable std module a changed file belongs to, or None."""
    parts = path.split("/")
    if path.startswith("stdlib/") and path.endswith(".agc"):
        name = path.removeprefix("stdlib/").removesuffix(".agc")
    elif len(parts) == 3 and path.startswith("tests/std/") and path.endswith("_test.agc"):
        name = parts[2].removesuffix("_test.agc")
    elif len(parts) == 2 and re.fullmatch(r"tests/test_std_\w+\.py", path):
        name = parts[1].removeprefix("test_std_").removesuffix(".py")
    elif len(parts) > 3 and path.startswith("tests/fixtures/"):
        name = parts[2]
    else:
        return None
    return name if name in portable else None


def users(name, root):
    """The test modules and VM goldens that cover the uses of std/<name>; FullPath when a use maps to none."""
    uses = re.compile(r"std/" + re.escape(name) + r"(?![\w/])")
    py = sorted((root / "tests").glob("test_*.py"))
    tests, fixtures = set(), set()
    for rel in tracked(root, "tests", "examples", "site/content"):
        path = root / rel
        if rel.parts[:2] in SELF_TESTED or rel.parts[:4] == FROZEN:
            continue
        if not uses.search(read(path)):
            continue
        if rel.parts[0] == "examples":
            tests.add("tests/test_examples.py")
        elif rel.parts[0] == "site":
            tests.add("tests/test_site_examples.py")
        elif len(rel.parts) == 2 and path.name.startswith("test_") and path.suffix == ".py":
            tests.add(str(rel))
        elif rel.parts[:3] == ("tests", "fixtures", "vm"):
            fixture = path.name.split(".")[0]
            if len(rel.parts) != 4 or not (path.parent / f"{fixture}.agc").is_file():
                raise FullPath(f"{rel} uses std/{name} and is no VM golden")
            fixtures.add(fixture)
        elif rel.parts[:3] == ("tests", "fixtures", "frontend"):
            owner = root / "tests" / f"test_frontend_{rel.parts[3]}.py"
            if not owner.is_file():
                raise FullPath(f"{rel} uses std/{name} and has no test module")
            tests.add(str(owner.relative_to(root)))
        else:
            key = Path(rel.parts[2] if rel.parts[1] == "fixtures" else rel.parts[1]).stem
            named = re.compile(r"[\"'/]" + re.escape(key) + r"(\.\w+)?[\"'/]")
            owners = [str(p.relative_to(root)) for p in py if p != path and named.search(read(p))]
            if not owners:
                raise FullPath(f"{rel} uses std/{name} and no test module names {key}")
            tests.update(owners)
    return tests, fixtures


def is_docs(path):
    return path.startswith(DOCS) or path.endswith(".md") and (path.startswith(".agents/") or "/" not in path)


def light_path(files, root):
    """(std_tests, std_fixtures) when every file is a portable std module, its tests or docs; else FullPath."""
    modules = std_modules(root)
    portable = set(modules) - front_end_std(root, modules)
    changed = set()
    for path in files:
        if is_docs(path) or path == "tests/test_unit_test.py":
            continue
        name = module_of(path, portable)
        if name is None:
            raise FullPath(f"{path} is not a portable std module, its tests or docs")
        changed.add(name)
    if not changed:
        raise FullPath("no portable std module changed")
    tests, fixtures = set(), set()
    for name in dependents(changed, modules):
        own = root / "tests" / f"test_std_{name}.py"
        if own.is_file():
            tests.add(str(own.relative_to(root)))
        found = users(name, root)
        tests |= found[0]
        fixtures |= found[1]
    tests -= set(ALWAYS)
    if len(tests) > MAX_TESTS:
        raise FullPath(f"{len(tests)} test modules use the changed std modules (more than {MAX_TESTS})")
    return sorted(tests | set(ALWAYS)), sorted(fixtures)


def classify(files, root=ROOT):
    files = [f for f in files if f]
    try:
        light = light_path(files, root)
    except FullPath as reason:
        print(f"full path: {reason}", file=sys.stderr)
        light = None
    return {
        "c": any(C_PATHS.match(f) for f in files),
        "trace": any(TRACE_PATHS.match(f) for f in files),
        "cchecker": any(CCHECKER_PATHS.match(f) for f in files),
        "std_only": light is not None,
        "std_tests": " ".join(light[0]) if light else "",
        "std_fixtures": " ".join(light[1]) if light else "",
    }


def everything():
    return {"c": True, "trace": True, "cchecker": True, "std_only": False, "std_tests": "", "std_fixtures": ""}


def main(argv):
    out = everything() if argv[1:] == ["--all"] else classify(sys.stdin.read().splitlines())
    for key, value in out.items():
        print(f"{key}={str(value).lower() if isinstance(value, bool) else value}")


if __name__ == "__main__":
    main(sys.argv)
