"""#1328 experiment (never merged): runs the switcher program of tests/test_spec_package_native_build.py many times
and counts the runs that lose copies.

usage: exp-1328.py LABEL BIN MODULE RUNS JOBS [agentica args ...]
MODULE is `switcher` (the test's module: an_blocking and a stack switch) or `plain` (the same copy, no an_blocking,
no stack switch). The environment passes through (AGC_EXP_REDZONE, AGENTICA_JIT, ...)."""
import ast
import collections
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TEST = Path(__file__).resolve().parent.parent / "tests" / "test_spec_package_native_build.py"
EXPECTED = "3000\ntrue\n"


def sources():
    found = {}
    for node in ast.parse(TEST.read_text(encoding="utf-8")).body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ("SWITCHER_C", "SWITCHER_AGC"):
                found[node.targets[0].id] = ast.literal_eval(node.value)
    return found["SWITCHER_C"], found["SWITCHER_AGC"]


def main():
    label, binary, module, runs, jobs, extra = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(
        sys.argv[5]), sys.argv[6:]
    c_source, agc_source = sources()
    if module == "plain":
        blocking = "  an_blocking(env, switched, &w);\n"
        assert blocking in c_source
        c_source = c_source.replace(blocking, "  w.sum = ROUNDS * want;\n")
    base = Path(tempfile.mkdtemp(prefix="exp1328-"))
    project = base / "project"
    (project / "native").mkdir(parents=True)
    (project / "native" / "switcher.c").write_text(c_source, encoding="utf-8")
    (project / "agentica.toml").write_text(
        'name = "app"\n\n[native.switcher]\nbuild = { sources = ["native/switcher.c"] }\n', encoding="utf-8")
    (project / "main.agc").write_text(agc_source, encoding="utf-8")
    env = dict(os.environ, AGENTICA_PATH="", AGENTICA_BUILD_DIR=str(base / "build"), XDG_CACHE_HOME=str(base / "cache"),
               AGENTICA_GC_HEAP="1M", LC_ALL="C.UTF-8", LANG="C.UTF-8")
    command = [binary, *extra, "--schedulers", "2", str(project / "main.agc")]

    def once(_):
        ran = subprocess.run(command, env=env, capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
        return ran.returncode, ran.stdout, ran.stderr

    first = once(0)
    if first[0] != 0:
        print("%s: first run failed: exit %d\n%s" % (label, first[0], first[2]))
        sys.exit(1)
    with ThreadPoolExecutor(jobs) as pool:
        results = [first, *pool.map(once, range(runs - 1))]
    outcomes = collections.Counter((code, out) for code, out, _ in results)
    lost_runs = sum(n for (code, out), n in outcomes.items() if (code, out) != (0, EXPECTED))
    lost_copies = 0
    for (code, out), n in outcomes.items():
        head = out.split("\n", 1)[0]
        if code == 0 and head.isdigit():
            lost_copies += (3000 - int(head)) * n
    print("%s: runs=%d bad_runs=%d lost_copies=%d outcomes=%s" % (
        label, runs, lost_runs, lost_copies,
        sorted(((code, out.split("\n", 1)[0]), n) for (code, out), n in outcomes.items())), flush=True)
    for code, out, err in results:
        if code not in (0,) and err:
            print("%s: stderr of a failed run: %s" % (label, err[-2000:]))
            break


if __name__ == "__main__":
    main()
