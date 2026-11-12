"""Source builds of native modules (`[native.NAME] build`, docs/grammar/05b-modules.md), through the CLI.

The project (a `path` dependency, or a git dependency pinned in the lock) holds a small native module in its native/
folder, which a run, `compile`, `test` or `install` builds with the system C compiler into the package cache of a
temporary folder; `check` never builds. The git dependency is a bare repository in a temporary folder
(tests/package_support.py, `Remotes`). The cases that only check or fail before the compiler runs need no compiler and
run everywhere; the ones that build and call the module need one and native calls (NATIVE_CALLS). Cases assert codes
and the file and key path, never message text (AGENTS.md).
"""
import json
import os
import re
import shutil
import signal
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, tool, vm_environment
from tests.package_support import assert_at_key, dependency, git, lock_entry, remotes, ws  # noqa: F401
from tests.test_vm_native import NATIVE_CALLS

ADDER_C = """#include "agentica_native.h"
#include "offset.h"

static an_term add(an_env *env, int argc, const an_term *argv) {
  int64_t a, b;
  (void)argc;
  if (!an_get_int(env, argv[0], &a) || !an_get_int(env, argv[1], &b)) return an_badarg(env, 0);
  return an_int(env, a * SCALE + b + OFFSET);
}

static const an_function functions[] = {{"add", "(Int, Int) -> Int", add, AN_SHORT}};

AN_MODULE("adder", functions, NULL)
"""
ADDER_AGC = 'extern module "adder"\n  export def add(a: Int, b: Int) -> Int\nend\n'
MAIN = 'import Adder from "adder"\n\ndef main() -> Void\n  puts(Adder.add(40, 2))\nend\n'
TABLE = '[native.adder]\nbuild = { sources = ["native/adder.c"], defines = ["SCALE=1"] }\n'
# The adder with a header in a folder of native/.
NESTED_C = ADDER_C.replace('#include "offset.h"\n', '#include "offset.h"\n#include "sub/scale.h"\n')
BUILT = re.compile(r"built native adder: (.+)\n")
OPTIONAL_TABLE = TABLE + "optional = true\n"
# A program that uses the adder only when it opens, as one of a package with an optional module must.
GUARDED_MAIN = ('import Adder from "adder"\n\ndef main() -> Void\n  if Native.load("adder").ok?\n'
                '    puts(Adder.add(40, 2))\n  else\n    puts("without adder")\n  end\nend\n')
NOT_BUILT = re.compile(r"warning: native module adder not built: [^\n]+; the package runs without it\n")


def environment(ws, **extra):
    """The bytecode cache of the runs is on, in a folder of the case (bytecode_entries)."""
    return vm_environment({"AGENTICA_PATH": "", "AGENTICA_BUILD_DIR": str(ws.base / "build"), **ws.cache_variables,
                           **extra})


def bytecode_entries(ws):
    return [path for path in (ws.base / "build").rglob("*.agcb")]


def agentica(ws, *words, folder=None, **extra):
    return run(cli() + list(words), cwd=folder or ws.project, env=environment(ws, **extra))


def problem(result):
    assert result.code == 1, result.stderr
    return json.loads(result.stderr)


def module_folder(folder, table=TABLE, name="app", source=ADDER_C):
    """A package folder with the adder module: its manifest, adder.agc, native/adder.c and the header it includes."""
    (folder / "native").mkdir(parents=True, exist_ok=True)
    (folder / "agentica.toml").write_text('name = "%s"\n\n%s' % (name, table), encoding="utf-8")
    (folder / "adder.agc").write_text(ADDER_AGC, encoding="utf-8")
    (folder / "native" / "adder.c").write_text(source, encoding="utf-8")
    (folder / "native" / "offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")


def project(ws, **options):
    module_folder(ws.project, **options)
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def path_dependency(ws, source=ADDER_C):
    """A project whose main file uses the adder module of the `path` dependency ../adder, locked."""
    module_folder(ws.base / "adder", name="adder", source=source)
    (ws.project / "agentica.toml").write_text('name = "app"\n\n[dependencies]\nadder = { path = "../adder" }\n',
                                              encoding="utf-8")
    (ws.project / "agentica.lock").write_text('version = 1\n\n[[package]]\nname = "adder"\npath = "../adder"\n',
                                              encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")


def fetched(ws, remotes, source=NESTED_C):
    """A project whose main file uses the adder module of a git dependency, published to a local bare repository and
    pinned in the lock by its commit and hash; a header is in a folder of native/, so the copy of a build has one. It
    gives the folder of the package in deps/, as the build sees it."""
    files = {"agentica.toml": 'name = "adder"\n\n' + TABLE, "adder.agc": ADDER_AGC, "native/adder.c": source,
             "native/offset.h": "#define OFFSET 0\n", "native/sub/scale.h": "#define SCALE_TOO 1\n"}
    commit = remotes.publish("owner/adder", files, tag="v1.0.0")
    lock_entry(ws, remotes, "owner/adder", files, commit, tag="v1.0.0")
    ws.write_manifest({"adder": dependency(remotes.url("owner/adder"), tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")
    return ws.deps.resolve() / "adder"


def builds(ws):
    """The entries of the build cache, temporary folders included (the lock files of the keys are not entries)."""
    base = ws.pkg_root / "native-build"
    return sorted(path.name for path in base.iterdir() if path.suffix != ".lock") if base.exists() else []


def files_of(folder):
    """The files below the folder, outside a _build/ folder."""
    return sorted(str(path.relative_to(folder)) for path in folder.rglob("*") if "_build" not in path.parts)


def no_compiler(ws):
    """A CC that cannot start: a run that tried to build would fail."""
    return {"CC": str(ws.base / "no-such-cc")}


@pytest.mark.parametrize("build, key", [
    ('{ sources = ["src/adder.c"] }', "native.adder.build.sources[0]"),
    ('{ sources = ["native/../adder.c"] }', "native.adder.build.sources[0]"),
    ('{ sources = ["native/adder.h"] }', "native.adder.build.sources[0]"),
    ('{ sources = ["native/adder.c"], defines = ["X -o /tmp/evil"] }', "native.adder.build.defines[0]"),
    ('{ sources = ["native/adder.c"], defines = ["X=\\"1\\""] }', "native.adder.build.defines[0]"),
    ('{ sources = ["native/adder.c"], libs = ["-Wl,-rpath,/tmp"] }', "native.adder.build.libs[0]"),
    ('{ sources = ["native/adder.c"], flags = ["-O0"] }', "native.adder.build.flags"),
    ('{ sources = [] }', "native.adder.build.sources"),
    ('{ defines = ["X"] }', "native.adder.build"),
], ids=["outside native", "dot dot", "not C", "a flag in a define", "a quote in a define", "a flag as a lib",
        "an unknown key", "no source", "no sources key"])
def test_a_build_table_holds_only_sources_in_native_defines_and_library_names(ws, build, key):
    project(ws, table="[native.adder]\nbuild = %s\n" % build)
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key)


def test_check_never_builds_and_a_missing_source_is_pkg_native_missing_at_its_item(ws):
    project(ws)
    checked = agentica(ws, "--json", "check", str(ws.project / "main.agc"), **no_compiler(ws))
    assert (checked.code, checked.stdout, checked.stderr) == (0, '{"ok":true}\n', "")
    assert builds(ws) == []
    (ws.project / "native" / "adder.c").unlink()
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-MISSING", ws.project / "agentica.toml", "native.adder.build.sources[0]")


def test_a_compiler_that_cannot_start_is_pkg_native_build_at_the_build_table(ws):
    project(ws)
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc"), **no_compiler(ws)))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


SWITCHER_C = """#define _GNU_SOURCE
#define _XOPEN_SOURCE 700
#include "agentica_native.h"
#include <stdlib.h>
#include <ucontext.h>

#define ROUNDS 64

typedef struct {
  const char *data;
  size_t len;
  uint64_t sum;
} work;

static __thread ucontext_t caller, coroutine;
static __thread work *current;

static void run(void) {
  for (int round = 0; round < ROUNDS; round++) {
    for (size_t k = 0; k < current->len; k++) current->sum += (unsigned char)current->data[k];
    swapcontext(&coroutine, &caller);
  }
}

/* Reads the argument on a stack of its own, as MariaDB Connector/C's non-blocking calls do. */
static void switched(void *arg) {
  void *stack = malloc(65536);
  if (!stack || getcontext(&coroutine) != 0) abort();
  coroutine.uc_stack.ss_sp = stack;
  coroutine.uc_stack.ss_size = 65536;
  coroutine.uc_link = &caller;
  current = arg;
  makecontext(&coroutine, run, 0);
  for (int round = 0; round < ROUNDS; round++) swapcontext(&caller, &coroutine);
  free(stack);
}

static an_term copy(an_env *env, int argc, const an_term *argv) {
  work w = {NULL, 0, 0};
  uint64_t want = 0;
  (void)argc;
  if (!an_get_string(env, argv[0], &w.data, &w.len)) return an_badarg(env, 0);
  an_term made = an_string(env, w.data, w.len);
  for (size_t k = 0; k < w.len; k++) want += (unsigned char)w.data[k];
  an_blocking(env, switched, &w);
  return w.sum == ROUNDS * want ? made : an_raise(env, "wrong sum");
}

static const an_function functions[] = {{"copy", "(String) -> String", copy, AN_SHORT}};

AN_MODULE("switcher", functions, NULL)
"""
SWITCHER_AGC = """extern module "switcher"
  def copy(text: String) -> String
end

def churn(n: Int) -> Int
  i = 0
  kept = 0
  while i < n
    kept = "#{i} #{kept}".size
    i = i + 1
  end
  return kept
end

def main() -> Void
  worker = Task.spawn(&churn, 300000)
  i = 0
  same = 0
  while i < 3000
    text = "text #{i}"
    if copy(text) == text
      same = same + 1
    end
    i = i + 1
  end
  puts(same)
  puts(Task.await(worker) > 0)
end
"""


# A short call switches stacks under an_blocking on a scheduler thread while a task on another one allocates in a
# heap of 1 MiB, so collections land while C is on its own stack: the program ends with every copy intact. With the
# function called without an_blocking, the run dies of SIGSEGV.
@NATIVE_CALLS
@host_only(WINDOWS, "the module switches stacks with ucontext, which Windows does not have")
def test_a_short_call_that_switches_stacks_under_an_blocking_runs_beside_the_collector(ws):
    tool("cc")
    (ws.project / "native").mkdir()
    (ws.project / "native" / "switcher.c").write_text(SWITCHER_C, encoding="utf-8")
    table = '[native.switcher]\nbuild = { sources = ["native/switcher.c"] }\n'
    (ws.project / "agentica.toml").write_text('name = "app"\n\n' + table, encoding="utf-8")
    (ws.project / "main.agc").write_text(SWITCHER_AGC, encoding="utf-8")
    ran = agentica(ws, "--schedulers", "2", str(ws.project / "main.agc"), AGENTICA_GC_HEAP="1M")
    assert (ran.code, ran.stdout) == (0, "3000\ntrue\n"), ran.stderr


@host_only(WINDOWS, "a symbolic link needs a privilege on Windows")
def test_a_link_in_native_is_refused_so_a_build_reads_only_the_package(ws, tmp_path):
    project(ws)
    outside = tmp_path / "outside.c"
    outside.write_text(ADDER_C, encoding="utf-8")
    (ws.project / "native" / "adder.c").unlink()
    (ws.project / "native" / "adder.c").symlink_to(outside)
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


@NATIVE_CALLS
def test_a_git_dependency_pinned_in_the_lock_builds_on_first_use_from_its_locked_files(ws, remotes):
    tool("cc")
    folder = fetched(ws, remotes)
    installed = agentica(ws, "install", **remotes.environment)
    assert (installed.code, installed.stderr) == (0, "")
    # A file of native/ that the hash leaves out (a dotfile) is not copied into the build, so it changes nothing.
    (folder / "native" / ".DS_Store").write_bytes(b"junk")
    before = files_of(folder)
    main = str(ws.project / "main.agc")
    ran = agentica(ws, main, **remotes.environment)
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    built = BUILT.fullmatch(ran.stderr)
    assert built and Path(built.group(1)).parent.parent == ws.pkg_root / "native-build", ran.stderr
    assert sorted(path.name for path in Path(built.group(1)).parent.iterdir()) == sorted(
        ["include", Path(built.group(1)).name, "receipt"])
    # The build compiles a private copy: nothing is written into deps/.
    assert files_of(folder) == before
    # The next runs take the program from the bytecode cache, then (with no cache) the build from the build cache.
    for words in ([], ["--no-cache"]):
        again = agentica(ws, *words, main, **remotes.environment)
        assert (again.code, again.stdout, again.stderr) == (0, "42\n", "")
    assert len(builds(ws)) == 1 and bytecode_entries(ws)


@NATIVE_CALLS
def test_a_fetched_package_builds_only_the_files_of_native_so_an_include_from_outside_is_not_found(ws, remotes):
    tool("cc")
    folder = fetched(ws, remotes, source=NESTED_C.replace('"offset.h"', '"../offset.h"'))
    assert agentica(ws, "--json", "install", **remotes.environment).code == 0
    # The hash covers no header at the root, so this one is not the locked package's and the build never sees it.
    (folder / "offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc"), **remotes.environment))
    assert_at_key(found, "PKG-NATIVE-BUILD", folder / "agentica.toml", "native.adder.build")
    assert builds(ws) == []


def test_install_of_a_fetched_native_dependency_needs_no_compiler_and_a_run_that_uses_it_builds(ws, remotes):
    folder = fetched(ws, remotes)
    installed = agentica(ws, "--json", "install", **remotes.environment, **no_compiler(ws))
    assert (installed.code, installed.stdout, installed.stderr) == (0, '{"ok":true}\n', ""), installed.stderr
    assert builds(ws) == []
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc"), **remotes.environment, **no_compiler(ws)))
    assert_at_key(found, "PKG-NATIVE-BUILD", folder / "agentica.toml", "native.adder.build")


def test_a_fetched_package_whose_copy_differs_from_the_lock_never_builds(ws, remotes):
    folder = fetched(ws, remotes)
    installed = agentica(ws, "--deny-native", "install", **remotes.environment)
    assert installed.code == 0, installed.stderr
    (folder / "native" / "offset.h").write_text("#define OFFSET 1\n", encoding="utf-8")
    for words in (["check"], []):
        found = problem(agentica(ws, "--json", *words, str(ws.project / "main.agc"), **remotes.environment,
                                 **no_compiler(ws)))
        assert found["code"] == "PKG-HASH-MISMATCH"
    assert builds(ws) == []


@NATIVE_CALLS
@pytest.mark.parametrize("flag", ["--deny-native", "--sandbox"])
def test_under_a_deny_flag_a_fetched_package_builds_nothing(ws, remotes, flag):
    folder = fetched(ws, remotes)
    main = str(ws.project / "main.agc")
    environment = {**remotes.environment, **no_compiler(ws)}
    installed = agentica(ws, "--json", flag, "install", **environment)
    assert installed.code == 0, installed.stderr
    denied = agentica(ws, "--json", flag, main, **environment)
    assert (denied.code, json.loads(denied.stderr)["code"]) == (2, "RUNTIME-NATIVE-DENIED"), denied.stderr
    found = problem(agentica(ws, "--json", flag, "compile", main, "-o", str(ws.base / "main.agcb"), **environment))
    assert_at_key(found, "PKG-NATIVE-BUILD", folder / "agentica.toml", "native.adder.build")
    assert builds(ws) == []


@NATIVE_CALLS
def test_a_run_builds_the_project_module_into_the_cache_and_builds_again_after_an_edit(ws):
    tool("cc")
    project(ws)
    before = files_of(ws.project)
    ran = agentica(ws, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    built = BUILT.fullmatch(ran.stderr)
    assert built, ran.stderr
    # The library is in the build cache under its key, and nothing but _build/ is written into the project.
    entry = builds(ws)
    assert len(entry) == 1 and re.fullmatch(r"[0-9a-f]{64}", entry[0])
    library = Path(built.group(1))
    assert library.is_file() and library.parent == ws.pkg_root / "native-build" / entry[0]
    assert files_of(ws.project) == before

    again = agentica(ws, str(ws.project / "main.agc"))
    assert (again.code, again.stdout, again.stderr) == (0, "42\n", "")
    # A header the source includes is a file of native/, so the key covers it: the cached program misses and the
    # module is built again, under another key.
    (ws.project / "native" / "offset.h").write_text("#define OFFSET 1\n", encoding="utf-8")
    edited = agentica(ws, str(ws.project / "main.agc"))
    assert (edited.code, edited.stdout) == (0, "43\n"), edited.stderr
    assert BUILT.fullmatch(edited.stderr) and len(builds(ws)) == 2
    quiet = agentica(ws, "--json", "--no-cache", str(ws.project / "main.agc"))
    assert (quiet.code, quiet.stdout, quiet.stderr) == (0, "43\n", "")


def counting_cc(ws):
    """A CC that runs cc and adds a line to the file COMPILES for each compile (not for --version or -dumpmachine);
    with HANG set it touches that file and hangs in the compile instead. The words of CC are in the key, so every run
    with it builds under one key."""
    script = ws.base / "cc.sh"
    script.write_text('#!/bin/sh\ncase "$1" in --version|-dumpmachine) ;; *) echo >> "$COMPILES"\n'
                      '  [ -n "$HANG" ] && touch "$HANG" && sleep 60 ;; esac\nexec %s "$@"\n' % tool("cc"),
                      encoding="utf-8")
    script.chmod(0o755)
    return {"CC": str(script), "COMPILES": str(ws.base / "compiles")}


def compiles(ws):
    path = ws.base / "compiles"
    return len(path.read_text(encoding="utf-8").splitlines()) if path.exists() else 0


@NATIVE_CALLS
@host_only(WINDOWS, "the compiler stand-in is a shell script")
def test_parallel_first_runs_wait_for_one_build_and_all_succeed(ws):
    project(ws)
    compiler = counting_cc(ws)
    with ThreadPoolExecutor(max_workers=4) as pool:
        runs = list(pool.map(lambda _: agentica(ws, "--no-cache", str(ws.project / "main.agc"), **compiler), range(4)))
    for ran in runs:
        assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    assert compiles(ws) == 1 and len(builds(ws)) == 1
    # The lock file is private like the rest of the cache, so no other user can open it and hold its lock.
    locks = list((ws.pkg_root / "native-build").glob("*.lock"))
    assert len(locks) == 1 and locks[0].stat().st_mode & 0o077 == 0


@NATIVE_CALLS
@host_only(WINDOWS, "the compiler stand-in is a shell script")
def test_a_build_killed_while_it_holds_the_lock_does_not_block_the_next_one(ws):
    project(ws)
    compiler = counting_cc(ws)
    marker = ws.base / "compiling"
    words = cli() + ["--no-cache", str(ws.project / "main.agc")]
    started = []

    def start(**extra):
        process = subprocess.Popen(words, cwd=ws.project, env=environment(ws, **compiler, **extra),
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        started.append(process)
        return process

    try:
        hung = start(HANG=str(marker))
        deadline = time.monotonic() + 60
        while not marker.exists():
            assert hung.poll() is None and time.monotonic() < deadline
            time.sleep(0.05)
        assert [path.suffix for path in (ws.pkg_root / "native-build").iterdir()].count(".lock") == 1
        # While the hung build holds the lock, the next run waits for it.
        waiter = start()
        with pytest.raises(subprocess.TimeoutExpired):
            waiter.wait(timeout=1)
        os.killpg(hung.pid, signal.SIGKILL)
        hung.wait()
        out, err = waiter.communicate(timeout=60)
    finally:
        for process in started:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    assert (waiter.returncode, out.decode()) == (0, "42\n"), err.decode()
    assert BUILT.fullmatch(err.decode()) and compiles(ws) == 2


@NATIVE_CALLS
def test_a_failed_build_is_pkg_native_build_and_leaves_no_entry(ws):
    tool("cc")
    project(ws, source=ADDER_C + "int broken = ;\n")
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    assert builds(ws) == []


@pytest.mark.parametrize("table", [
    TABLE + 'optional = "yes"\n',
    '[native.adder]\noptional = true\nlinux = { system = "libadder.so" }\n',
], ids=["not a boolean", "no build table"])
def test_optional_is_a_boolean_beside_a_build_table(ws, table):
    project(ws, table=table)
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", "native.adder.optional")


@NATIVE_CALLS
def test_an_optional_module_with_no_compiler_warns_once_a_run_and_the_program_runs_without_it(ws):
    project(ws, table=OPTIONAL_TABLE)
    (ws.project / "main.agc").write_text(GUARDED_MAIN, encoding="utf-8")
    main = str(ws.project / "main.agc")
    # Nothing is cached, so every run tries the build again and warns again, once for the two uses of the module.
    for _ in range(2):
        ran = agentica(ws, main, **no_compiler(ws))
        assert (ran.code, ran.stdout) == (0, "without adder\n") and NOT_BUILT.fullmatch(ran.stderr), ran.stderr
    assert builds(ws) == [] and bytecode_entries(ws) == []
    # With --json the warning is the object of a problem with "warning": true; with --ai, a block that starts so.
    quiet = agentica(ws, "--json", main, **no_compiler(ws))
    assert (quiet.code, quiet.stdout) == (0, "without adder\n"), quiet.stderr
    warning = json.loads(quiet.stderr)
    assert warning["warning"] is True
    assert_at_key(warning, "PKG-NATIVE-UNBUILT", ws.project / "agentica.toml", "native.adder.build")
    compact = agentica(ws, "--ai", main, **no_compiler(ws))
    assert (compact.code, compact.stdout) == (0, "without adder\n"), compact.stderr
    assert compact.stderr.startswith("warning\n") and compact.stderr.count("[PKG-NATIVE-UNBUILT]") == 1
    assert "\n  key: native.adder.build\n" in compact.stderr and compact.stderr.endswith("\n\n")
    installed = agentica(ws, "install", **no_compiler(ws))
    assert installed.code == 0 and NOT_BUILT.fullmatch(installed.stderr), installed.stderr
    compiled = agentica(ws, "compile", main, "-o", str(ws.base / "main.agcb"), **no_compiler(ws))
    assert compiled.code == 0 and NOT_BUILT.fullmatch(compiled.stderr), compiled.stderr
    ran = agentica(ws, "run", "--", str(ws.base / "main.agcb"))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "without adder\n", "")
    # A call of the module fails as for a missing library, after the warning.
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    called = agentica(ws, "--json", main, **no_compiler(ws))
    codes = [json.loads(line)["code"] for line in called.stderr.splitlines()]
    assert (called.code, codes) == (1, ["PKG-NATIVE-UNBUILT", "RUNTIME-NATIVE-LOAD"]), called.stderr


@NATIVE_CALLS
@host_only(WINDOWS, "the cache root comes from LOCALAPPDATA there")
def test_an_optional_module_with_no_cache_root_warns_and_a_call_fails_as_for_a_missing_library(ws):
    project(ws, table=OPTIONAL_TABLE)
    env = environment(ws, **no_compiler(ws))
    for name in ("HOME", "XDG_CACHE_HOME"):
        env.pop(name, None)
    called = run(cli() + ["--json", str(ws.project / "main.agc")], cwd=ws.project, env=env)
    codes = [json.loads(line)["code"] for line in called.stderr.splitlines()]
    assert (called.code, codes) == (1, ["PKG-NATIVE-UNBUILT", "RUNTIME-NATIVE-LOAD"]), called.stderr


@NATIVE_CALLS
def test_agentica_test_json_gives_the_warning_of_an_optional_module_and_the_test_falls_back(ws):
    project(ws, table=OPTIONAL_TABLE)
    (ws.project / "test").mkdir()
    (ws.project / "test" / "adder_test.agc").write_text(
        'import Adder from "../adder"\n\ndef main() -> Void\n  Test.run([Test.test("adds or falls back") do\n'
        '    Test.assert(!Native.load("adder").ok? or Adder.add(40, 2) == 42, "adds")\n  end])\nend\n',
        encoding="utf-8")
    tested = agentica(ws, "--json", "test", **no_compiler(ws))
    assert tested.code == 0 and json.loads(tested.stdout)["passed"] == 1, tested.stdout + tested.stderr
    assert [json.loads(line)["code"] for line in tested.stderr.splitlines()] == ["PKG-NATIVE-UNBUILT"], tested.stderr


def test_an_optional_module_still_fails_on_a_missing_source_and_under_a_deny_flag_compile(ws):
    project(ws, table=OPTIONAL_TABLE)
    main = str(ws.project / "main.agc")
    found = problem(agentica(ws, "--json", "--deny-native", "compile", main, "-o", str(ws.base / "main.agcb"),
                             **no_compiler(ws)))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    (ws.project / "native" / "adder.c").unlink()
    found = problem(agentica(ws, "--json", main, **no_compiler(ws)))
    assert_at_key(found, "PKG-NATIVE-MISSING", ws.project / "agentica.toml", "native.adder.build.sources[0]")


@NATIVE_CALLS
def test_an_optional_module_that_does_not_compile_warns_and_builds_once_it_compiles(ws):
    tool("cc")
    project(ws, table=OPTIONAL_TABLE, source=ADDER_C + "int broken = ;\n")
    (ws.project / "main.agc").write_text(GUARDED_MAIN, encoding="utf-8")
    main = str(ws.project / "main.agc")
    ran = agentica(ws, main)
    assert (ran.code, ran.stdout) == (0, "without adder\n") and len(NOT_BUILT.findall(ran.stderr)) == 1, ran.stderr
    (ws.project / "native" / "adder.c").write_text(ADDER_C, encoding="utf-8")
    ran = agentica(ws, main)
    assert (ran.code, ran.stdout) == (0, "42\n") and BUILT.fullmatch(ran.stderr), ran.stderr


@NATIVE_CALLS
def test_install_builds_the_module_of_a_path_dependency_and_a_run_finds_it_built(ws):
    tool("cc")
    path_dependency(ws)
    installed = agentica(ws, "install")
    assert (installed.code, installed.stdout) == (0, "in place adder@path\n"), installed.stderr
    assert BUILT.fullmatch(installed.stderr), installed.stderr
    ran = agentica(ws, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "42\n", "")
    # The compiled program names the library by its path in the cache, so `run --` opens it as it is.
    compiled = agentica(ws, "compile", str(ws.project / "main.agc"), "-o", str(ws.base / "main.agcb"))
    assert (compiled.code, compiled.stderr) == (0, "")
    assert agentica(ws, "run", "--", str(ws.base / "main.agcb")).stdout == "42\n"


BOXES_C = """#include "agentica_native.h"

typedef struct {
  int64_t n;
} box;

static an_term make(an_env *env, int argc, const an_term *argv) {
  an_term out;
  int64_t n;
  (void)argc;
  if (!an_get_int(env, argv[0], &n)) return an_badarg(env, 0);
  box *b = an_resource_new(env, 0, &out);
  if (b) b->n = n;
  return out;
}

static an_term get(an_env *env, int argc, const an_term *argv) {
  box *b;
  (void)argc;
  if (!an_get_resource(env, argv[0], 0, (void **)&b)) return an_badarg(env, 0);
  return an_int(env, b->n);
}

static const an_resource_type resources[] = {{"Box", sizeof(box), NULL}};
static const an_function functions[] = {
  {"make", "(Int) -> Box", make, AN_SHORT},
  {"get", "(Box) -> Int", get, AN_SHORT},
};

AN_MODULE_TABLES("boxes", functions, AN_COUNT(functions), NULL, 0, resources, AN_COUNT(resources), NULL)
"""
BOXES_AGC = """extern module "boxes"
  resource Box
  def make(n: Int) -> Box
  def get(box: Box) -> Int
end

def main() -> Void
  puts(get(make(7)))
end
"""


@NATIVE_CALLS
def test_a_resource_of_a_module_that_the_manifest_names_crosses_to_its_functions(ws):
    # The block's library is the [native.NAME] of the manifest, which the linker turns into the built file: the
    # resource names that library too, so the checker and the VM find that the two belong to one module.
    tool("cc")
    (ws.project / "native").mkdir()
    (ws.project / "native" / "boxes.c").write_text(BOXES_C, encoding="utf-8")
    table = '[native.boxes]\nbuild = { sources = ["native/boxes.c"] }\n'
    (ws.project / "agentica.toml").write_text('name = "app"\n\n' + table, encoding="utf-8")
    (ws.project / "main.agc").write_text(BOXES_AGC, encoding="utf-8")
    ran = agentica(ws, str(ws.project / "main.agc"))
    assert (ran.code, ran.stdout) == (0, "7\n"), ran.stderr


@host_only(WINDOWS, "a symbolic link needs a privilege on Windows")
@pytest.mark.parametrize("hidden", [False, True], ids=["a linked native folder", "a hidden link"])
def test_a_linked_native_folder_or_a_hidden_link_in_it_is_refused(ws, tmp_path, hidden):
    project(ws)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")
    if hidden:
        (ws.project / "native" / ".offset.h").symlink_to(outside / "offset.h")
    else:
        (ws.project / "native" / "adder.c").rename(outside / "adder.c")
        (ws.project / "native" / "offset.h").unlink()
        (ws.project / "native").rmdir()
        (ws.project / "native").symlink_to(outside, target_is_directory=True)
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


def test_a_windows_device_name_is_not_a_library_name_to_build(ws):
    project(ws, table='[native.con]\nbuild = { sources = ["native/adder.c"] }\n')
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", "native.con")


def test_a_library_no_file_uses_never_builds(ws):
    project(ws)
    (ws.project / "main.agc").write_text('def main() -> Void\n  puts(1)\nend\n', encoding="utf-8")
    ran = agentica(ws, str(ws.project / "main.agc"), **no_compiler(ws))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "1\n", "")
    assert builds(ws) == []


@NATIVE_CALLS
@pytest.mark.parametrize("flag", ["--deny-native", "--deny-run", "--deny-fs", "--sandbox"])
def test_under_a_deny_flag_nothing_builds_and_a_run_is_refused_alike_on_a_cache_hit_and_a_miss(ws, flag):
    tool("cc")
    project(ws)
    main = str(ws.project / "main.agc")
    ran = agentica(ws, main)
    assert (ran.code, ran.stdout) == (0, "42\n") and BUILT.fullmatch(ran.stderr), ran.stderr
    # The CC cannot start, so a build would fail: the miss and then the hit of the refused run are the VM's refusal.
    for _ in range(2):
        denied = agentica(ws, "--json", flag, main, **no_compiler(ws))
        assert (denied.code, json.loads(denied.stderr)["code"]) == (2, "RUNTIME-NATIVE-DENIED"), denied.stderr
    assert len(builds(ws)) == 1 and len(bytecode_entries(ws)) == 2
    # `compile` writes a program that may run without the flag, so it refuses the module instead.
    found = problem(agentica(ws, "--json", flag, "compile", main, "-o", str(ws.base / "main.agcb")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    assert not (ws.base / "main.agcb").exists()
    # The refused runs kept their programs apart: a plain run takes its own, with the built library.
    assert agentica(ws, main).stdout == "42\n"


@NATIVE_CALLS
@pytest.mark.parametrize("words", [["--deny-native", "--json", "test"], ["--json", "test", "--deny-run"]],
                         ids=["in front of test", "after test"])
def test_test_under_a_deny_flag_builds_nothing_and_the_test_file_is_refused(ws, words):
    project(ws)
    (ws.project / "test").mkdir()
    (ws.project / "test" / "adder_test.agc").write_text(
        'import Adder from "../adder"\n\ndef main() -> Void\n'
        '  Test.run([Test.test("adds") do Test.eq(Adder.add(40, 2), 42) end])\nend\n', encoding="utf-8")
    tested = agentica(ws, *words, **no_compiler(ws))
    assert (tested.code, tested.stderr) == (1, ""), tested.stdout
    report = json.loads(tested.stdout)
    assert [entry["error"]["code"] for entry in report["files"]] == ["RUNTIME-NATIVE-DENIED"]
    assert builds(ws) == []


@NATIVE_CALLS
def test_a_program_under_test_under_a_deny_flag_builds_nothing_and_is_refused(ws):
    """`BDD.given_program` compiles the program once per run with the run's deny flags (#1458), so the compile refuses
    the module instead of building it, and the start goes through the front end, which the VM refuses."""
    tool("cc")
    project(ws)
    (ws.project / "specs").mkdir()
    (ws.project / "specs" / "start.feature").write_text(
        'Feature: Start\n\n  Scenario: refused\n    Given the Agentica program "../main.agc"\n'
        '    Then the program exits with code 2 within 20000 milliseconds\n    And stderr includes:\n'
        '      """\n      RUNTIME-NATIVE-DENIED\n      """\n', encoding="utf-8")
    tested = agentica(ws, "--deny-native", "--json", "test")
    assert (tested.code, tested.stderr) == (0, ""), tested.stdout
    assert json.loads(tested.stdout)["passed"] == 1
    assert builds(ws) == []


@NATIVE_CALLS
@host_only(WINDOWS, "the stand-in compiler is a shell script")
def test_a_scenario_that_sets_path_to_another_compiler_does_not_reuse_the_program_built_with_the_first(ws):
    """With no CC, PATH finds the compiler of a native module, so `BDD.given_program` and the bytecode cache key on it:
    the scenario whose PATH finds a compiler that cannot answer builds again and fails, instead of starting the
    program the first scenario built with the real one."""
    tool("cc")
    project(ws)
    fake = ws.base / "fake-cc"
    fake.mkdir()
    (fake / "cc").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    (fake / "cc").chmod(0o755)
    path = json.dumps(f"{fake}{os.pathsep}{os.environ['PATH']}")[1:-1]
    (ws.project / "specs").mkdir()
    (ws.project / "specs" / "start.feature").write_text(
        'Feature: Start\n\n  Scenario: the real compiler\n    Given the Agentica program "../main.agc"\n'
        '    Then I receive the line "42" within 20000 milliseconds\n\n'
        '  Scenario: a compiler that cannot answer\n'
        f'    Given the environment variable "PATH" is "{path}"\n'
        '    And the Agentica program "../main.agc"\n'
        '    Then the program exits with code 1 within 20000 milliseconds\n    And stderr includes:\n'
        '      """\n      PKG-NATIVE-BUILD\n      """\n', encoding="utf-8")
    tested = agentica(ws, "--json", "test", CC=None)
    assert (tested.code, tested.stderr) == (0, ""), tested.stdout
    assert json.loads(tested.stdout)["passed"] == 2


def test_a_lock_row_that_says_member_outside_its_workspace_never_builds(ws):
    module_folder(ws.base / "repo" / "adder", name="adder")
    url = "https://example.test/owner/repo"
    (ws.project / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nadder = { git = "%s", tag = "v1", subdir = "adder" }\n' % url,
        encoding="utf-8")
    (ws.project / "agentica.lock").write_text(
        'version = 1\n\n[[package]]\nname = "adder"\ngit = "%s"\nsubdir = "adder"\ntag = "v1"\nworkspace = true\n'
        % url, encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")
    found = problem(agentica(ws, "--json", str(ws.project / "main.agc"), **no_compiler(ws)))
    assert_at_key(found, "PKG-LOCK-STALE", ws.project / "agentica.toml", "dependencies.adder")
    assert builds(ws) == []


@NATIVE_CALLS
def test_a_workspace_member_builds_in_place(ws, tmp_path):
    tool("cc")
    repo = tmp_path / "repo"
    url = "https://example.test/owner/repo"
    repo.mkdir()
    (repo / "agentica.toml").write_text('[workspace]\nrepository = "%s"\nmembers = ["adder", "app"]\n' % url,
                                        encoding="utf-8")
    module_folder(repo / "adder", name="adder")
    app = repo / "app"
    app.mkdir()
    (app / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nadder = { git = "%s", tag = "adder-1", subdir = "adder" }\n' % url,
        encoding="utf-8")
    (app / "main.agc").write_text(MAIN.replace('"adder"', '"pkg/adder/adder"', 1), encoding="utf-8")
    updated = agentica(ws, "--json", "update", folder=app)
    assert updated.code == 0, updated.stderr
    ran = agentica(ws, str(app / "main.agc"), folder=app)
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    assert BUILT.fullmatch(ran.stderr) and len(builds(ws)) == 1


@NATIVE_CALLS
def test_agentica_test_builds_the_module_a_test_file_uses(ws):
    tool("cc")
    project(ws)
    (ws.project / "test").mkdir()
    (ws.project / "test" / "adder_test.agc").write_text(
        'import Adder from "../adder"\n\ndef main() -> Void\n'
        '  Test.run([Test.test("adds") do Test.eq(Adder.add(40, 2), 42) end])\nend\n', encoding="utf-8")
    tested = agentica(ws, "test")
    assert tested.code == 0, tested.stdout + tested.stderr
    assert BUILT.search(tested.stderr) and len(builds(ws)) == 1


@NATIVE_CALLS
def test_another_define_or_compiler_is_another_entry_and_a_tampered_entry_is_pkg_native_build(ws):
    compiler = tool("cc")
    project(ws)
    main = str(ws.project / "main.agc")
    assert agentica(ws, "--no-cache", main).stdout == "42\n"
    (ws.project / "agentica.toml").write_text('name = "app"\n\n' + TABLE.replace("SCALE=1", "SCALE=2"),
                                              encoding="utf-8")
    assert agentica(ws, "--no-cache", main).stdout == "82\n"
    assert agentica(ws, "--no-cache", main, CC=compiler).stdout == "82\n"
    entries = builds(ws)
    assert len(entries) == 3
    # The entry of this table and CC: its library, then its receipt, changed after the build.
    newest = max((ws.pkg_root / "native-build" / name for name in entries), key=lambda path: path.stat().st_mtime_ns)
    library = next(path for path in newest.iterdir() if path.name.startswith(("libadder", "adder")))
    built = library.read_bytes()
    library.write_bytes(built + b"\0")
    found = problem(agentica(ws, "--json", "--no-cache", main, CC=compiler))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    library.write_bytes(built)
    (newest / "receipt").write_text("0" * 64 + "\n", encoding="utf-8")
    found = problem(agentica(ws, "--json", "--no-cache", main, CC=compiler))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


@host_only(WINDOWS, "a named pipe is a POSIX file")
def test_a_pipe_in_native_is_refused(ws):
    project(ws)
    os.mkfifo(ws.project / "native" / "fifo")
    found = problem(agentica(ws, "--json", "check", str(ws.project / "main.agc")))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


@NATIVE_CALLS
def test_with_the_bytecode_cache_a_new_file_a_changed_library_and_a_removed_entry_are_seen(ws):
    tool("cc")
    project(ws)
    main = str(ws.project / "main.agc")
    assert BUILT.fullmatch(agentica(ws, main).stderr)
    assert agentica(ws, main).stderr == ""
    assert bytecode_entries(ws), "no bytecode cache entry"
    # A new file of native/ is in the key, so the cached program misses and the module is built again.
    (ws.project / "native" / "notes.txt").write_text("new\n", encoding="utf-8")
    added = agentica(ws, main)
    assert (added.code, added.stdout) == (0, "42\n") and BUILT.fullmatch(added.stderr), added.stderr
    assert agentica(ws, main).stderr == ""
    entry = ws.pkg_root / "native-build" / BUILT.fullmatch(added.stderr).group(1).split("/")[-2]
    library = Path(BUILT.fullmatch(added.stderr).group(1))
    built = library.read_bytes()
    library.write_bytes(built + b"\0")
    found = problem(agentica(ws, "--json", main))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    library.unlink()
    found = problem(agentica(ws, "--json", main))
    assert_at_key(found, "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")
    # Removing the entry, as the help says, builds it again.
    shutil.rmtree(entry)
    again = agentica(ws, main)
    assert (again.code, again.stdout) == (0, "42\n") and BUILT.fullmatch(again.stderr), again.stderr


@NATIVE_CALLS
def test_with_the_bytecode_cache_an_edit_to_a_hidden_header_of_a_path_dependency_builds_again(ws):
    tool("cc")
    path_dependency(ws, source=ADDER_C.replace('"offset.h"', '".offset.h"'))
    (ws.base / "adder" / "native" / ".offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")
    main = str(ws.project / "main.agc")
    ran = agentica(ws, main)
    assert (ran.code, ran.stdout) == (0, "42\n") and BUILT.fullmatch(ran.stderr), ran.stderr
    assert agentica(ws, main).stderr == ""
    (ws.base / "adder" / "native" / ".offset.h").write_text("#define OFFSET 1\n", encoding="utf-8")
    edited = agentica(ws, main)
    assert (edited.code, edited.stdout) == (0, "43\n") and BUILT.fullmatch(edited.stderr), edited.stderr


@NATIVE_CALLS
def test_compile_builds_the_module_a_file_uses_and_the_bytecode_opens_it(ws):
    tool("cc")
    project(ws)
    compiled = agentica(ws, "compile", str(ws.project / "main.agc"), "-o", str(ws.base / "main.agcb"))
    assert compiled.code == 0 and BUILT.fullmatch(compiled.stderr), compiled.stderr
    ran = agentica(ws, "run", "--", str(ws.base / "main.agcb"))
    assert (ran.code, ran.stdout, ran.stderr) == (0, "42\n", "")
