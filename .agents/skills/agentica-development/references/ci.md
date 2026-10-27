# CI, release and the copy-paste check

Read this before changing `.github/workflows/`, the Makefile or `mk/*.mk`, or
before adding VM source files, test peers or fixtures. The build and the
release need only a C toolchain (they start from `bootstrap/stage0.agcb`).
Each `mk/*.mk` file starts with a comment saying what it owns; the targets
carry comments too, so read them for details not listed here.

## The checks of ci.yml, sweep.yml and the release are make targets

The steps of `ci.yml` and `sweep.yml`, and the test steps of `release.yml`,
call `make` targets, so they run locally with the same command. Only setup
stays in the YAML: checkout, toolchain and `apt` installs, caches and their
keys, the `changes` step of `vm-sanitizers`, and the release's `zig` install
and `strip`. A new check gets a target first (in `.PHONY`, with a one-line
comment), then a step that calls it. Targets that are not obvious:

- `all` (the default goal) builds `dist/agentica`
  (`docs/future/18-front-end-language.md` §18.2). A first binary
  (`build/vm/<mode>/bootstrap/agentica`, never shipped, with no runner or
  step program) is linked with `bootstrap/stage0.agcb` and the `std/`
  sources; it compiles `stage1`; `--front-end stage1` compiles `stage2`;
  `--front-end stage2` compiles `stage3`; make stops unless
  `stage2 == stage3`; `dist/agentica` is linked with `stage2`. The stages are
  the same bytes in every mode. `fixed-point` adds: `dist/agentica` compiles
  the front end with its embedded sources to `stage2` again, and compiles
  `compiler/embedded/runner.agc` and `steps.agc` to the bytes it carries.
- `dist/agentica` also carries the files of `stdlib/CORE` (the pure core that
  `std/analysis` needs) as `internal/compiler/<path>`
  (`vm/tools/gen-embedded.sh`). A new import in that core needs a line in
  `stdlib/CORE` (`tests/test_stdlib_modules.py` checks it).
- `dist/agentica` is a real rule over every `.agc` under `compiler/`,
  `stdlib/*.agc`, `VERSION`, the VM objects and stage0; `test`, `test-bdd`,
  `test-cli` and `smoke` depend on it, so a pull never leaves a stale binary.
- `cli`, `bdd-driver`, `exe` and `vm` stop with a message (`make vm` would
  otherwise find the `vm/` folder and do nothing).
- `test-cli` runs `CLI_TESTS` on `dist/agentica` (`AGENTICA_TEST_EXECUTABLE`).
  CI does not run it: `make test` runs the same modules on the same binary.
  The option and diagnostic forms of the CLI are one golden of the whole
  output, messages included: `tests/fixtures/cli/forms.json`
  (`tests/test_cli_forms.py`; `make goldens` rewrites it, the diff is the
  review).
- `test` and `test-slow` run one pytest process per module
  (`make -k -O -j$(JOBS)` over `py-test/<file>`; `-O` needs GNU make 4.0, so
  macOS jobs use `gmake`). `TESTS` takes module files or directories; a
  directory adds only its own `test_*.py`, not subfolders (`tests/eval/` is
  not part of this runner). `PY_ALONE` modules (`test_vm_latency.py`,
  `test_vm_task_map.py`) run only when named (`make vm-latency`,
  `make vm-task-map`). `test-slow` sets `AGENTICA_TEST_SLOW=1`.
  `AGENTICA_HEAVY_RACE_REPEATS` (default 5) sets the slow-tier repeats of the
  two heavy multicore race cases; the weekly sweep runs them 20 times.
- Test helpers are in `tests/agentica_test.py`: paths, the binary, `run` with
  a timeout, `compile_agc`, `@slow`, `tool` for Node, `Child` and `start_vm`
  (a peer or VM read line by line, killed with its process group at the end),
  `process_alive` and `wait_until` (no process left), `make_suite` and
  `report_cases` (`agentica test --json`). A missing tool or binary fails
  when `CI` is set and skips locally.
- Timeouts, three layers, all stretched by `AGENTICA_TEST_TIMEOUT_SCALE`
  (default 1; CI sets 4): one test (SIGALRM, 120 s, 900 s for `@slow`;
  `@timeout(seconds)` overrides; `faulthandler` kills the module 30 s
  later), one module (`MODULE_LIMIT` of `mk/test.mk`: 600 s, 1800 s slow),
  and the job's `timeout-minutes`, which must exceed the module limit times
  the scale. A deadline a correct run must beat uses `scaled(seconds)`; a
  deadline the test expects to fire, or a bound that measures the product
  (`LIMIT_MS` of `test_vm_latency.py`), stays unscaled. Step deadlines stay
  under the 30 s scenario deadline of `agentica test`.
- `make tests KIND=fast|files|slow|all` selects a group; `DOCKER=1` runs it
  in the Ubuntu test container, `WINE=1` its Windows checks under Wine
  (`fast` and `files`). `TESTS=` narrows only host fast and slow runs; make
  rejects it elsewhere. An unknown `KIND` fails before anything runs.
- The destructive filesystem group (`ISOLATED_PY_TESTS` of `mk/test.mk`)
  never runs on the host: `test-py` refuses it; `make test-bdd` also runs
  through Docker locally. `docker-test-image` builds the Ubuntu test container
  (`tools/ubuntu-test.Dockerfile`, `TEST_BASE` picks the base). Locally the
  group runs only in Docker (`tools/docker-tests.sh --mode ...`: read-only
  root and checkout,
  tmpfs `/tmp`, named volumes for `build/` and `dist/`, no capabilities, no
  network, bounded memory and time; it never falls back to the host). In CI,
  `make test-remove-actions` runs it on a GitHub-hosted runner only (it fails
  elsewhere), each case in its own `RUNNER_TEMP` subtree with an outside
  sentinel. Wine runs of this group are compatibility checks, not proof of
  NTFS, ACL or reparse-point behavior.
- `tools/refreeze.py` (`references/frontend.md`, "Refreeze") rewrites the
  frozen front-end goldens; `make goldens` runs its `--fast-only` tier. Not a
  CI step.
- `vendored-check` links against the vendored libgc, OpenSSL and zlib and
  fails on a dynamic `libgc`, OpenSSL, `libz`/`zlib1.dll` or `msys-2.0.dll`;
  `vendored-test` adds the TLS and HTTP tests on that binary.
- `vm-lint` includes the clang-tidy 19 version check; `vm-trace-off` builds
  with `TRACE=0` and checks `--version`.
- `vm-layers` (Linux; needs `rg` and `nm`) compiles each `vm/*.h` alone and
  runs `vm/tools/check-layers.sh` (`docs/vm/15-layers.md` §15.5). A new
  `vm/*.c` file goes in one list of that script.
- `vm-sanitize-build`, `vm-sanitize-test` and `vm-diff-test` do not depend on
  `dist/agentica` on purpose: they test the binary an earlier step built
  (`SANITIZE=1` makes `dist/agentica` the sanitizer build).
- `build/vm/<mode>/agentica` is a second link of the binary for
  `vm-gc-stress` and `vendored-check`, so they do not replace
  `dist/agentica`. `AGENTICA_VM_BINARY=path` makes the Python tests use
  another binary.
- `VM_OS` is the target platform (`Windows_NT` for the cross build); `OS`
  stays the "is the host Windows" test. `RUN_PROGRAM` prefixes recipes that
  run a program they just compiled; `VM_TEST_RUNNER` prefixes each C test.
- `windows-docker-build` and `windows-docker-check` cross-build
  `dist/agentica.exe` with llvm-mingw in `tools/windows-check.Dockerfile` and
  run the C tests and the Windows `platforms.yml` modules under Wine
  (`WINDOWS_TEST_MODULES=...` picks others). The bootstrap needs Wine to run
  each stage. They need Docker with buildx and about 6 GB; no CI job calls
  them. Wine is no substitute for native Windows (process creation, UTF-16
  command lines and symlinks can differ).
- `sweep-full` runs the golden shards with `AGENTICA_SWEEP=full`.
  `vm-jit-test` runs the goldens with `AGENTICA_JIT=always`, then half the
  shards with `on` (odd or even by the last digit of `GITHUB_SHA`;
  `VM_JIT_ON_TESTS` names others).
  `test-distribution` copies `dist/agentica` away from the checkout and runs
  it (`tests/test_stdlib_distribution.py`).

### Refreshing stage0

`bootstrap/stage0.agcb` is a checked-in stage2, the only seed of the build
(a 3.7 MB blob: refresh it only when needed). Refresh it after a change that
the old stage0 cannot compile or load (the `stage1` recipe says so), and
before a release.

- (a) The old stage0 still compiles `compiler/`: run
  `make fixed-point stage0`, check that the diff is only that file, run
  `make` again (it must build from the new file) and commit it.
- (b) It cannot (a syntax or builtin that `compiler/` itself uses, a new
  bytecode format): split the change in two PRs (§18.2): the first adds the
  feature without using it in `compiler/` and refreshes stage0; the second
  uses it. When that is not possible, compile `stage1` with another binary
  built from the parent commit and say so in the PR:
  `make stage0 STAGE1_COMPILER="path/to/agentica"`. A new bytecode format
  needs the old VM to run the new compiler once by hand; the PR that changes
  the format writes the commands.

A PR that changes stage0 runs `make stage0-check BASE_STAGE0=<base stage0>`
in the `test` job: stage2 built from the base stage0 with the PR's
`compiler/` must equal the PR's file. It checks the merge commit, so when
another `compiler/` change lands first, merge master and refresh again. Case
(b) cannot pass it: say so in the PR; the owner approves by hand. The loader
also accepts format 5 (`AGC_FORMAT_PREVIOUS` in `vm/value.h`), kept for an
older stage0; the checked-in stage0 is format 6, so it can go.

## Windows console

These tests need a native Windows console; Wine skips them:

- `tests/test_windows_console_stop.py`: the VM in a new process group gets
  `CTRL_BREAK_EVENT` (exit 149, 128 + `SIGBREAK`), a child that ignores it is
  stopped, buffered file data is written, a stuck stdout does not hold the
  exit. Output through ConPTY (`WriteConsoleW` from a pool thread, a line
  longer than the 64 KiB buffer). A new process group turns Ctrl+C off, so
  these cases send Ctrl+Break; libuv reports both through one `uv_signal_t`.
  It also types a line into the console and keeps a console read waiting
  while file calls run.
- `test_vm_stop.py` tests Ctrl+C itself: the CLI runs in a pseudo console
  and the test types character 3 (`run_on_console` of
  `tests/windows_console_support.py`, which first turns Ctrl+C on, since a
  parent in a new process group hands "ignore Ctrl+C" to every child).
- `tests/test_windows_handle_counts.py` (named pipes,
  `GetProcessHandleCount`) and `tests/test_windows_process_cleanup.py` (the
  Windows side of the SIGTERM, SIGKILL and chmod cleanup cases). Other
  cleanup cases run everywhere; on Windows they use a Python child, the
  PowerShell process list or a copy of `node.exe`, because the VM starts
  only `.exe` and `.com` files there.

After changing Windows stdin handling, a check on a native terminal is
useful but does not block. Save as `console-input.agc`:

```agentica
def main() -> Void
  puts("waiting")
  IO.flush()
  puts(IO.gets())
end
```

1. `dist/agentica.exe console-input.agc` without redirecting stdin; after
   `waiting`, type `hello` and Enter: `ok("hello")`, exit 0.
2. Again, and press Ctrl+C at `waiting`: a prompt return, no read-error
   diagnostic, no surviving VM. libuv handles the signal on the loop even if
   `_read` stays blocked on the reader thread; retrying an interrupted
   `_read` must not be the signal handler.

## Pull requests (`.github/workflows/ci.yml`)

Runs on pull requests and `master` pushes, on GitHub-hosted Ubuntu. Docs,
site and Markdown-only changes skip it; a newer push cancels an older run.

- `test` runs `vm-test test-bdd`, `test-remove-actions`, the whole suite,
  `test-shared`, `test-multicore-modules`, `vm-jit-test`, `fixed-point`,
  `stage0-check`, `test-slow`, `vm-latency` and `vm-task-map` alone,
  `smoke`, the vendored check, then `dup-check`. The vendored check is the last
  step that builds: it rebuilds `build/vm/release/obj` with other flags, so
  nothing that builds may run beside it. `dup-check` runs even when an earlier
  step fails.
- `vm-sanitizers` (`needs: test`, runs even if it fails): `vm-lint`, ASan C
  tests, 60 s of libFuzzer (`vm-libfuzz-run`, `-seed=1`,
  `LIBFUZZ_TIMEOUT=30`), `vm-layers`, the sanitizer binary's fixed point
  (about 75 s and 1.8 GB: no GC) and Python modules, `vm-tsan`,
  `vm-tsan-run`, and GC stress (it links the release `stage2`, since it
  collects every 64 allocations). It builds only when the merge commit
  changes `vm/`, the Makefile, `mk/*.mk`, `.gitmodules`, `.clang-tidy` or
  `ci.yml` (keep that list in step with new C folders); a manual run always
  runs it.
  `vm-trace-off` runs only on a manual run or a change to `vm/trace.*` or
  `vm/tests/trace_test.c`.
- Both jobs set `AGENTICA_SWEEP=sampled` (seed from `GITHUB_SHA`; a failure
  prints `AGENTICA_SWEEP_SEED`). The full sweep runs locally, in the release
  and weekly in `sweep.yml`.
- `RUNTIME-TEST-TIMEOUT` has coverage only in the slow tier.
- Peers: TCP needs Node; TLS needs Node and Python 3; the goldens need
  Python 3 (`tests/fixtures/channel-run.py`; `channel-run.js` on Windows).
- PR jobs use the system libgc (`GC_MIN` 8.2.0; older systems use
  `AGENTICA_GC=vendored`), OpenSSL 3 and zlib 1.2.0; a guard step installs
  the `-dev` packages when `pkg-config` cannot find them. `warm-third-party`,
  `sweep.yml` and the release use the vendored libgc and zlib, and the release
  the vendored OpenSSL. Both modes share `build/vm/release/obj`; a mode change
  changes the flag stamps and forces a full rebuild.

## Conformance matrix (`platforms.yml`)

One job per system: `linux-x86_64`, `windows-x86_64` (MSYS2 UCRT64),
`macos-x86_64` and `macos-arm64`; the last three link the vendored OpenSSL
and zlib.
It runs on PRs with the `platforms` label and on `master` pushes. Each job:
`vm-test`, `vendored-check`, `bootstrap-smoke`, `fixed-point`, then
`make conformance-area/<area>` per area of `tools/conformance.py`, then
`make conformance-report` (a job summary, `summary.json`, exit 1 when a
module did not finish, a case failed, an area has no passed case, or a skip
is not allowed). `conformance all-systems` merges the four reports and fails
when a system is missing or a case ran on none. Not in the matrix: the Docker
and Wine groups, the slow tier, sanitizers, fuzz and gc-stress (`ci.yml`,
`fuzz.yml`).

A new `tests/test_*.py` must be in an area or in `EXCLUDED` with a reason
(`tests/test_conformance.py`). Run one system by hand with `make conformance`.

Skip rules, checked by the report:

- `host_only(condition, reason)` (`tests/agentica_test.py`): the system
  really lacks a capability (POSIX signals, FIFOs, mode bits on Windows;
  non-UTF-8 names on macOS). The reason starts with `host-only:`, names the
  capability and any counterpart test; the (module, system) pair must be in
  `HOST_ONLY_ALLOWED`. A harness limit or a product gap is not host-only. A
  golden named `-posix` or `-windows` is host-only on the other family; a
  golden that differs by system is split into a shared part and those parts.
- `known_issue(condition, number, reason)`: the promise holds but its test is
  missing, or the product has a bug. The reason is `known-issue: #N ...`, the
  number is in `KNOWN_ISSUES`, and the report lists it under "Open gaps".
  Remove the skip, the entry and the issue together.
- A tool the test needs is installed by the workflow; a skip for a missing
  tool fails the report. A hosted-runner limit is said in the PR, not
  skipped silently.

## Caches and `master` pushes

- The vendored release-mode OpenSSL is cached with `actions/cache` (key:
  `make -s vm-openssl-key AGENTICA_OPENSSL=vendored`); `warm-third-party`
  saves it on `master`, the PR `test` job only restores it (a PR can restore
  only caches of its merge ref or `master`). On a miss the vendored check
  skips.
- Compiles go through ccache when it is on `PATH`; the release sets `CCACHE=`
  because PR jobs can write to a shared cache.
- A `master` push runs no tests: only `dup-check` (it saves the jscpd npm
  cache) and `warm-third-party`.

## Other workflows

- `vm-libfuzz-run` runs each input in the interpreter, then on Linux with
  `AGC_JIT_ALWAYS`; the link wraps `agc_jit_mem_reserve` so each input's code
  memory is unmapped (`vm/fuzz_libfuzzer.c`).
- `fuzz.yml` (by hand): `make vm-libfuzz-run` for an hour (the `seconds`
  input) on every core, random seed; a crash, leak or timeout fails it;
  uploads `build/vm/libfuzz/crashes/` unless cancelled.
- `sweep.yml`: Monday 03:00 UTC and by hand, `make sweep-full` and
  `vm-jit-self-compile` (the front end compiles itself under `--jit on` and
  `always`, via the test-only `AGENTICA_VM_TEST_FRONT_END_JIT`, to stage2) on
  the release VM; job `jit-stress` runs `vm-gc-stress-jit` and
  `vm-sanitize-jit-test` (the goldens with `AGENTICA_JIT=always` on the GC
  stress and the ASan binaries, sampled sweep).
- `jit-soak.yml`: daily 04:30 UTC and by hand, on the four systems,
  `make test-jit-on` (the conformance areas and the destructive group with
  `AGENTICA_JIT=on`; the report names the failed cases). A test that needs
  one mode passes `--jit` itself (the flag wins). Nothing else runs on a
  schedule.
- `site-examples.yml` and `pages.yml`: `references/site.md`.

## Release (`release.yml`)

Four packages, one job each, vendored libgc, OpenSSL and zlib, built from stage0
(`make vm-test fixed-point`): `linux-x86_64` (`.tar.gz`, pinned `zig cc`
against glibc 2.28), `windows-x86_64` (`.zip`, MSYS2 UCRT64), `macos-x86_64`
and `macos-arm64` (`.tar.gz`, `MACOSX_DEPLOYMENT_TARGET=12.0`). Per package:
build, strip (macOS adds an ad hoc `codesign`; no Developer ID or
notarization), `make release-check`, `release-package`, `release-smoke`,
upload. `RELEASE_PLATFORM` names the package. The Linux job also runs the
full golden sweep, `test-distribution` and the examples.

- `tools/release-check.sh elf|macho|pe BINARY ARCH FLOOR` checks the format,
  architecture, hardening flags, the glibc or macOS floor and the allowed
  libraries or DLLs (no libgc, OpenSSL or MSYS runtime). A change of a floor
  or of the allowed DLLs goes in that script.
- `tools/release.py package` writes `agentica-VERSION-PLATFORM.(tar.gz|zip)`
  with `bin/agentica`, `LICENSE`, `NOTICE` and `licenses/` (`LICENSE_FILES`;
  a new third-party library adds its license there). The archive is
  reproducible; the binary is not.
- `tools/release.py smoke` (`python -I`) runs the extracted binary from a
  path with spaces and non-ASCII letters, with a system-only `PATH`. TLS is
  covered by the OpenSSL version line only.
- `collect` (every run) checks that there are exactly the four archives of
  `VERSION` and writes `SHA256SUMS`. `publish` runs only for a tag push equal
  to `VERSION` and creates the GitHub Release with empty notes. A manual
  `workflow_dispatch` only uploads artifacts.

Before merging a change to `release.yml`, the packaging tools or the binary
format, dispatch a dry run: `gh workflow run release.yml --ref BRANCH`.

### Tags, versions and CHANGELOG

- `VERSION` (one line, no `v`) is the single source of the version: C gets it
  as `AGC_VERSION`, the front end as `Settings.version` (`--version V`), and
  each `.agcb` header carries it. Keep it equal to the Git tag.
- CHANGELOG entries: `AGENTS.md`. Sections Added, Changed, Removed, Fixed;
  add the PR number. Internal-only work (CI, refactors, docs) needs none.
- Cutting a release: `.agents/skills/agentica-release/`.

## Copy-paste check (jscpd)

- `make dup-check` runs jscpd over C in `vm/` and Python in `tests/`
  (`.jscpd.json`; it skips `tests/eval/tasks/`, triple-quoted text and
  comments). jscpd is pinned by `tools/jscpd/package-lock.json` and installed
  with `npm ci --ignore-scripts`.
- CI fails on any clone not in `.jscpd-baseline.json`. Remove the copy
  instead of growing the baseline; a reviewer rejects a PR that grows it.
  After removing old clones, refresh it with `make dup-baseline`.
