# CI, release and the copy-paste check

Read this before changing `.github/workflows/`, the Makefile or `mk/*.mk`, or
before adding VM source files, test peers or fixtures. The build and the release
need only a C toolchain (they start from `bootstrap/stage0.agcb`). Each
`mk/*.mk` file starts with a comment saying what it owns; the targets carry
comments too.

## The checks of ci.yml, sweep.yml and the release are make targets

The steps of `ci.yml` and `sweep.yml`, and the test steps of `release.yml`, call
`make` targets, so they run locally with the same command. Only setup stays in
the YAML (checkout, toolchain, caches, the `changes` job, artifact steps, the
release's `zig` install and `strip`). A new check gets a target first (in
`.PHONY`, with a one-line comment), then a step that calls it.

- The bootstrap (`stage1` to `stage3`, `fixed-point`) is described in
  `mk/bootstrap.mk`. `dist/agentica` carries the files of `stdlib/CORE` as
  `internal/compiler/<path>`; a new import in that core needs a line in
  `stdlib/CORE` (`tests/test_stdlib_modules.py` checks it).
- `dist/agentica` is a real rule over every `.agc` under `compiler/`,
  `stdlib/*.agc`, `VERSION`, the VM objects and stage0, so a pull never leaves a
  stale binary. `cli`, `bdd-driver`, `exe` and `vm` stop with a message.
- The CLI's option and diagnostic forms are one golden of the whole output,
  messages included: `tests/fixtures/cli/forms.json` (`make goldens` rewrites
  it; the diff is the review).
- `test` and `test-slow` run one pytest process per module (`-O` needs GNU make
  4.0, so macOS jobs use `gmake`). `PY_ALONE` modules run only when named. A
  directory in `TESTS` adds only its own `test_*.py`.
  `AGENTICA_HEAVY_RACE_REPEATS` (default 5) sets the slow-tier repeats of the
  two heavy multicore race cases; the weekly sweep runs them 20 times.
- Test helpers are in `tests/agentica_test.py`. A missing tool or binary fails
  when `CI` is set, and skips locally.
- Property tests (Hypothesis; the profiles are in `tests/conftest.py`): write
  one for a codec or wire format that has a Python standard library peer, where
  the edge cases are easy to miss by hand: a round trip, or "accepted if and
  only if valid". It runs in both tiers: the fast tier replays the same few
  examples, the slow tier draws many from a seed it prints (`hypothesis seed
  N`). One VM serves every example of a run (a server, or a program that reads
  cases from stdin), as in `tests/test_prop_http.py`. A failure prints the
  shrunk input and a `@reproduce_failure` line to put on the test; a slow-tier
  seed replays with
  `PYTEST_ADDOPTS=--hypothesis-seed=N make test-slow TESTS=...`.
- Timeouts, three layers, all stretched by `AGENTICA_TEST_TIMEOUT_SCALE`
  (default 1; CI sets 4): one test (SIGALRM, 120 s, 900 s for `@slow`;
  `@timeout(seconds)` overrides; `faulthandler` kills the module 30 s later);
  one module (`MODULE_LIMIT` of `mk/test.mk`: 600 s, 1800 s slow); and the job's
  `timeout-minutes`, which must exceed the module limit times the scale. A
  deadline a correct run must beat uses `scaled(seconds)`. A deadline the test
  expects to fire, or a bound that measures the product (`LIMIT_MS` of
  `test_vm_latency.py`), stays unscaled. Step deadlines stay under the 30 s
  scenario deadline of `agentica test`.
- `make tests KIND=fast|files|slow|all` selects a group (`DOCKER=1`, `WINE=1`;
  `TESTS=` narrows only host fast and slow runs).
- The destructive filesystem group (`ISOLATED_PY_TESTS` of `mk/test.mk`) never
  runs on the host: locally only in Docker (`tools/docker-tests.sh`: read-only
  root, no network, bounded), in CI through `make test-remove-actions` on a
  GitHub-hosted runner. Wine runs of this group are compatibility checks, not
  proof of NTFS, ACL or reparse-point behavior.
- `vm-layers` compiles each `vm/*.h` alone and runs `vm/tools/check-layers.sh`
  (`docs/vm/15-layers.md` §15.5). A new `vm/*.c` file goes in one list of that
  script.
- `vm-sanitize-build`, `vm-sanitize-test` and `vm-diff-test` do not depend on
  `dist/agentica` on purpose: they test the binary an earlier step built.
  `AGENTICA_VM_BINARY=path` makes the Python tests use another binary.
- `VM_OS` is the target platform (`Windows_NT` for the cross build); `OS` stays
  the "is the host Windows" test.
- `windows-docker-check` runs the C tests and the Windows `platforms.yml`
  modules under Wine; no CI job calls it, and Wine is no substitute for native
  Windows (process creation, UTF-16 command lines and symlinks can differ).

### Refreshing stage0

`bootstrap/stage0.agcb` is a checked-in stage2, the only seed of the build (over
8 MB: refresh it only when needed). Refresh it after a change that the old
stage0 cannot compile or load (the `stage1` recipe says so), and before a
release.

- (a) The old stage0 still compiles `compiler/`: run `make fixed-point stage0`,
  check that the diff is only that file, run `make` again (it must build from
  the new file), and commit it.
- (b) It cannot (a syntax or builtin that `compiler/` itself uses, or a new
  bytecode format): split the change in two PRs. The first adds the
  feature without using it in `compiler/` and refreshes stage0; the second uses
  it. To rename a builtin that `compiler/` calls, the first PR keeps the old
  name as a catalog row whose key is the new one, plus the old C key for the
  base stage0; the second removes both. When that is not possible, compile
  `stage1` with another binary built from the parent commit, and say so in the
  PR: `make stage0 STAGE1_COMPILER="path/to/agentica"`. A new bytecode format
  needs the old VM to run the new compiler once by hand; the PR that changes the
  format writes the commands.

A row whose **type** changes (`List[Int]` to `Bytes`), not only its name, cannot
keep the old name: no source compiles against both types. Keep the old C key for
the base stage0, and add the new catalog rows with new C keys in the first
commit. Run `make stage1` at that commit and copy `build/stage/stage1.agcb` to
`I.agcb`, the intermediate front end. Later commits change the call sites. Then
refresh stage0 with:

```sh
make stage0 STAGE1_COMPILER="build/vm/release/bootstrap/agentica --front-end I.agcb"
```

After the refresh, run `make fixed-point` and `make` as usual. A later PR
removes the old keys once no stage0 imports them. The same goes for the short
arities that `Process.spawn`, `spawn_captured` and `spawn_channel` keep without
`env` (the 3, 4 and 4 rows of `agc_process_builtins`, and `builtin_spawn*` in
`vm/process.c`): remove them in the PR that refreshes stage0 after the one that
added `env`, and make the C tests call the arity with `env`.

A PR that changes stage0 runs `make stage0-check BASE_STAGE0=<base stage0>` in
the `checks` job (`mk/bootstrap.mk` says what it compares). It checks the merge
commit, so when another `compiler/` change lands first, merge master and refresh
again. Case (b) cannot pass it: say so in the PR, and the owner approves by
hand. The loader also accepts format 5 (`AGC_FORMAT_PREVIOUS` in
`vm/value.h`), kept for an older stage0; the checked-in stage0 is format 6.

## Windows console

`tests/test_windows_console_stop.py`, `test_vm_stop.py` (Ctrl+C through a pseudo
console, `run_on_console` of `tests/windows_console_support.py`),
`test_windows_handle_counts.py` and `test_windows_process_cleanup.py` need a
native Windows console; Wine skips them. A new process group turns Ctrl+C off (a
parent in one hands "ignore Ctrl+C" to every child), so the stop tests send
Ctrl+Break (exit 149, 128 + `SIGBREAK`); libuv reports both through one
`uv_signal_t`. Cleanup cases that run everywhere use a Python child, the
PowerShell process list, or a copy of `node.exe` on Windows, because the VM
starts only `.exe` and `.com` files there.

After changing Windows stdin handling, check on a native terminal (it does not
block CI): run a program that prints `waiting`, flushes and prints `IO.gets()`,
with `dist/agentica.exe` and stdin not redirected.

1. Type `hello` and Enter at `waiting`: `ok("hello")`, exit 0.
2. Press Ctrl+C at `waiting`: a prompt return, no read-error diagnostic, no
   surviving VM. libuv handles the signal on the loop even if `_read` stays
   blocked on the reader thread; retrying an interrupted `_read` must not be the
   signal handler.

## Pull requests (`.github/workflows/ci.yml`)

The job graph and the reason for each job are in the comments of the YAML and of
`.github/actions/use-build` (one `build` artifact, unpacked and re-dated so make
rebuilds nothing; the log line `no file of dist/ or build/ changed` is the
proof). These are the rules they do not show.

- `build/vm/flags` is shared by all build modes, so after a job runs another
  mode (`make vm-tsan-run`, `make vm-gc-stress`) make links that mode's
  binaries again. A job must not build two modes in a row and then use the
  first: its binaries would be relinked, and through the first binary of the
  bootstrap the stages would run again (about 45 s in sanitizer mode).
- **TSan and native peers.** `make vm-tsan-native` runs the native-call,
  native-module and FFI modules on the TSan binary at 2 and then 4 schedulers;
  the `tsan-native` jobs run one count each (`TSAN_NATIVE_SCHEDULERS`, about 8
  minutes each), and `vm-tsan-run` leaves those modules out. When the VM under
  test is that binary, `shared_library` of `tests/test_vm_native.py` builds each
  peer with clang and `-fsanitize=thread`, so a race in a peer's C fails the run
  (#1160); the target sets `AGENTICA_TSAN_PEERS=1`, which makes the module fail
  at import if the peers would be built without TSan. A library that TSan itself
  loads, such as the finalization hook, passes `sanitize=False`. An intended
  race stays out of the peers that the run loads: behind a `Native.mutex()`
  (`peer_racy_add`) or in a program of its own (the TSan control
  `tsan_finalize_control.c`). A change under `tests/fixtures/native/` or to
  `examples/ffi/*.c` runs the C half.
- **Check names.** `test` and `vm-sanitizers` are the checks to name in a
  branch protection rule or a merge gate; the other jobs are not (a shard job
  is `fast tests (1/2)` and so on).
- **Shards.** `tools/shard_tests.py` splits the modules longest first with the
  seconds of `tests/shard_weights.txt` (a module that is not listed counts as 1
  s). The weights come from a CI run: when a module gets slow or a new one is
  big, copy its `... passed in Ns` time from the log into the file. Changing `N`
  in `ci.yml` needs no other change. `tests/test_vm_multicore.py` takes 190 s in
  the slow tier alone, so that tier cannot go below it without splitting the
  module.
- The vendored check is the last build step of `checks`: it rebuilds
  `build/vm/release/obj` with other flags, so nothing that builds may run after
  it.
- `make layout-check` guards `plain_turn` (the `--jit off` loop): a 128-byte
  move with the same instructions made `arithmetic` 13% slower. An intended
  change gets the `layout-change` label (it accepts only exit code 4) and the
  pinned `--jit off` numbers in the PR body; the label does not start CI:
  re-run the job.
- The C half runs only when the merge commit changes `vm/`, the Makefile,
  `mk/*.mk`, `.gitmodules`, `.clang-tidy`, `ci.yml` or `.github/actions/` (the
  `changes` job); keep that list in step with new C folders.
- Every job that runs tests sets `AGENTICA_SWEEP=sampled` (seed from
  `GITHUB_SHA`; a failure prints `AGENTICA_SWEEP_SEED`). `RUNTIME-TEST-TIMEOUT`
  has coverage only in the slow tier.
- A new CI job counts against the 20 runners the organization shares with
  `platforms.yml`: a run is 9 jobs, and 19 when C changed (the two aggregates
  included), plus `cchecker` when `vm/`, the build files or its settings
  changed. Merge small steps into an existing job before adding one.
- The artifacts live one day: after 24 hours, re-run all jobs of a run, not only
  the failed ones, since a shard could not download the build.
- Peers: TCP needs Node; TLS needs Node and Python 3; the goldens need Python 3
  (`tests/fixtures/channel-run.py`; `channel-run.js` on Windows).
- PR jobs use the system libgc (`GC_MIN` 8.2.0; older systems use
  `AGENTICA_GC=vendored`), OpenSSL 3 and zlib 1.2.0; `warm-third-party`,
  `sweep.yml` and the release use the vendored ones. Both modes share
  `build/vm/release/obj`; a mode change forces a full rebuild.

## cchecker (`make cchecker`)

[cchecker](https://github.com/agentica-lang/cchecker) checks `vm/` for the
project rules of C (a short path never blocks, a lock is released on every
path, ownership) and runs `gcc -fanalyzer` and clang-tidy, on a compile
database of its own (`make cchecker-db`: that of `make compile-commands`
without `vm/tests/`, so every run is a full run, which checks the names of the
settings and reports a stale ignore of the rules). It is an Agentica program:
`make cchecker` clones the tag pinned in `mk/vm-test.mk` (`CCHECKER_VERSION`,
checked against `CCHECKER_COMMIT`; the release has no binary) into
`build/cchecker/`, runs it with `dist/agentica`, and needs gcc 10+, clang and
clang-tidy. A run takes 3 to 5 minutes. Its docs are in that clone
(`docs/settings.md`, `docs/suppressions.md`).

- `cchecker.toml` holds the settings (`[library]`, `[roots]`, `[assume]`);
  `cchecker-baseline.json` holds the accepted findings. It exits 1 on a
  finding the baseline lacks. A function that runs on the loop's thread but is
  only passed through a pointer (an `agc_loop_call` step) goes in `[roots]
  short`.
- The CI job `cchecker` runs when `vm/`, the build files, `.clang-tidy` or those
  two files change, and blocks: `test` needs it (skipped counts only when it
  did not run). A clone step tries the pinned tag three times, so a network
  failure shows there (a commit that is not the pinned one fails at once).
  The step fails when cchecker exits non-zero (the JSON says which: new
  findings, a stale ignore included, or a tool error), and the print step
  fails on an empty or invalid JSON. It prints the new findings, the tool errors and the
  files not checked, and uploads the JSON of `--json` as the artifact
  `cchecker-findings`, also on a failure.
- The job pins gcc 14 and clang and clang-tidy 19, which are the reference:
  the baseline matches by message and the analyzers reword between versions,
  so a local run with other versions may differ by a finding or an unused
  ignore (`CCHECKER_FLAGS="--gcc gcc-14 --clang clang-19 --clang-tidy
  clang-tidy-19"`). Fix what CI reports from the artifact.
- A new finding is accepted in the PR that brings it, in this order: fix the
  code; a false positive of one line gets `// cchecker: ignore CODE: reason`
  next to the code (or above the function, for a rule's finding); a function
  that makes many findings for the same reason gets an `[assume]` entry with
  its reason; only a finding that stays goes into the baseline, with `make
  cchecker-update-baseline` (the diff is the review, and the PR says why each
  new entry is accepted). Each reason is one line a reviewer can check.
- Marks: `vm/cchecker.h` is a copy of `include/cchecker.h` of the pinned
  release; its macros are empty in every build but cchecker's own AST dump
  (`CCHECKER_AST`). Put `CC_OWNS` on a function that returns malloc memory and
  on the fields and parameters that own it; `CC_OWNS_OUT` on a `char **out`
  parameter that hands an owned pointer to the caller (`agc_remove_tree`);
  `CC_FREES` on the parameter of a function that frees it; `CC_GC_ALLOC` on an
  allocator of the collector; `CC_ACQUIRES(lock)` or `CC_RELEASES(lock)` on a
  function that takes a lock for its caller or drops the caller's
  (`agc_lock_take`, `leave_with`). A function that takes or drops a lock only
  on some paths (by a flag or a count) gets an ignore with the reason.
  Settings first (`cchecker.toml`); a mark is for what they cannot say.
- To move to a new release, change `CCHECKER_VERSION` and `CCHECKER_COMMIT`
  (`git ls-remote https://github.com/agentica-lang/cchecker 'X^{}' X`), copy
  its `include/cchecker.h` over `vm/cchecker.h`, run
  `make cchecker-update-baseline` and review the diff.

## Conformance matrix (`platforms.yml`)

The header of `platforms.yml` says what it runs. Not in the matrix: the Docker
and Wine groups, the slow tier, sanitizers, fuzz and gc-stress (`ci.yml`,
`fuzz.yml`). A new `tests/test_*.py` must be in an area of
`tools/conformance.py` or in `EXCLUDED` with a reason
(`tests/test_conformance.py`). Run one system by hand with `make conformance`.

Skip rules, checked by the report:

- `host_only(condition, reason)` (`tests/agentica_test.py`): the system really
  lacks a capability (POSIX signals, FIFOs, mode bits on Windows; non-UTF-8
  names on macOS). The reason starts with `host-only:`, names the capability and
  any counterpart test, and the (module, system) pair must be in
  `HOST_ONLY_ALLOWED`. A harness limit or a product gap is not host-only. A
  golden named `-posix` or `-windows` is host-only on the other family, and
  `make goldens` leaves it alone there (refresh it by running it on that family:
  `python3 -m tests.vm_diff_support` with `AGENTICA_FIXTURES=name`); a golden
  that differs by system is split into a shared part and those parts.
- `known_issue(condition, number, reason)`: the promise holds but its test is
  missing, or the product has a bug. The reason is `known-issue: #N ...`, the
  number is in `KNOWN_ISSUES`, and the report lists it under "Open gaps". Remove
  the skip, the entry and the issue together.
- A tool the test needs is installed by the workflow; a skip for a missing tool
  fails the report. A hosted-runner limit is said in the PR, not skipped
  silently.

The Windows jobs set up MSYS2 with `.github/actions/msys2`, not
`msys2/setup-msys2` directly: it runs that action up to three times (waiting
60 s and 180 s) because the MSYS2 servers answer 504 now and then, and each
attempt uses its own `location`, since the action refuses a folder that exists.

## Caches and `master` pushes

- The vendored release-mode OpenSSL is cached with `actions/cache` (key:
  `make -s vm-openssl-key AGENTICA_OPENSSL=vendored`). `warm-third-party` saves
  it on `master`; the PR `checks` job only restores it (a PR can restore only
  caches of its merge ref or `master`). On a miss, the vendored check skips.
- The release sets `CCACHE=`, because PR jobs can write to a shared cache.
- A `master` push runs no tests: only `dup-check` and `warm-third-party`.

## Other workflows

`jit-soak.yml` and `platforms.yml` describe themselves in their headers;
`site-examples.yml` and `pages.yml`: `references/site.md`.

- `fuzz.yml` (by hand) runs `make vm-libfuzz-run` for an hour with a random
  seed; `vm-libfuzz-run` runs each input in the interpreter, then on Linux
  x86-64 with the JIT, and compares the outputs. The link wraps
  `agc_jit_mem_reserve` so each input's code memory is unmapped
  (`vm/fuzz_libfuzzer.c`). Seeds: `tests/fixtures/vm/` and
  `tests/fixtures/fuzz/`.
- `sweep.yml` (weekly, and by hand) runs `make sweep-full` and
  `vm-jit-self-compile` (the front end compiles itself under `--jit on` and
  `always`, through the test-only `AGENTICA_VM_TEST_FRONT_END_JIT`), and its
  `jit-stress` job runs the JIT goldens on the GC stress and ASan binaries.
- `jit-soak.yml` is the only daily schedule: `make test-jit-off` runs the tests
  with `AGENTICA_JIT=off`. A canary in `tests/test_vm_jit.py` fails if the
  variable stops reaching the VMs. A test that needs one mode passes `--jit`
  itself (the flag wins).

## Release (`release.yml`)

The header of `release.yml` lists the five packages. They are built from stage0
with vendored libgc, OpenSSL and zlib (Linux: pinned `zig cc` against glibc
2.28; macOS: ad hoc `codesign`, no notarization). The steps are `mk/release.mk`
targets; the Linux jobs also run the full golden sweep, `test-distribution` and
the examples.

- A change of a glibc or macOS floor, or of the allowed DLLs, goes in
  `tools/release-check.sh`.
- A `zig cc` link takes a helper it lacks from zig's `compiler_rt`, one object
  that also defines a stack protector with a constant canary, which then
  replaces glibc's. On Linux arm64 `__clear_cache` was such a helper, so
  `vm/jit/mem_posix.c` defines it; release-check fails when `__stack_chk_fail`
  is not glibc's.
- `tools/release.py package` writes the archive with `LICENSE`, `NOTICE`,
  `licenses/` (`LICENSE_FILES`; a new third-party library adds its license
  there) and `include/agentica_native.h`. The archive is reproducible; the
  binary is not.
- `tools/release.py smoke` (`python -I`) runs the extracted binary from a path
  with spaces and non-ASCII letters, with a system-only `PATH`. TLS is covered
  by the OpenSSL version line only.
- `publish` runs only for a tag push equal to `VERSION`, and creates the GitHub
  Release with empty notes. A manual `workflow_dispatch` only uploads artifacts.

Before merging a change to `release.yml`, the packaging tools or the binary
format, dispatch a dry run: `gh workflow run release.yml --ref BRANCH`.

`VERSION` (one line, no `v`) is the single source of the version: C gets it as
`AGC_VERSION`, the front end as `Settings.version` (`--version V`), and each
`.agcb` header carries it. Keep it equal to the Git tag. Cutting a release:
`.agents/skills/agentica-release/`; CHANGELOG entries: `AGENTS.md`.

## Copy-paste check (jscpd)

`make dup-check` runs jscpd over C in `vm/` and Python in `tests/`
(`.jscpd.json`). CI fails on any clone not in `.jscpd-baseline.json`. Remove the
copy instead of growing the baseline; a reviewer rejects a PR that grows it.
After removing old clones, refresh it with `make dup-baseline`.
