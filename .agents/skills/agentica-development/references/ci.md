# CI, release and the copy-paste check

Read this before changing `.github/workflows/`, the Makefile, or before
adding VM source files, test peers or fixtures. Everything runs on Racket
CS 9.3.

## The checks of ci.yml, sweep.yml and the release are make targets

The steps of `ci.yml` and `sweep.yml`, and the test steps of `release.yml`,
call `make` targets, so those checks run locally with the same command. In
those files only setup stays in the YAML: checkout, toolchain and `apt`
installs, caches and their keys, and the `changes` step. Still inline are
`site-examples.yml`, `platforms.yml`, `fuzz.yml` (its `make vm-fuzz` was
already a target) and the packaging steps of `release.yml` (the `strip` and
ELF checks, `make exe`, `raco distribute`, the archive). A new check in
`ci.yml` or `sweep.yml` gets a target first (in `.PHONY` and with a one-line
comment), then a step that calls it. Targets that are not obvious:

- `build` (`raco make src/main.rkt`) and `vm` run before `make test` and
  `make smoke`, and `make test` then starts its Racket test workers in parallel.
- `build-tests` compiles every test module; `test-ci` runs `make test
  JOBS=6` with `test-exe` (the process and module tests on `dist/agentica`)
  beside it (`tests/test-ci.sh`); `smoke` is the example smoke runs
  (`tests/smoke.sh`). `dist/agentica` is a real Makefile rule over
  `src/*.rkt` and `stdlib/*.agc`, and `exe`, `test-bdd`, `test-exe`,
  `test-ci` and `smoke` all use it, so a pull never leaves a stale
  executable and an up-to-date one is not rebuilt. The `vm` target is only
  built before it, never a reason to rebuild it.
- `vm-unicode-check` regenerates `vm/unicode_data.c` and fails if it changed.
- `vendored-check` links the VM against the vendored OpenSSL and checks it
  (static, the submodule's version); `vendored-test` adds the TLS and HTTP
  tests on that binary.
- `vm-lint` includes the clang-tidy 19 version check; `vm-trace-off` builds
  with `TRACE=0` and checks `--version`.
- `vm-layers` (Linux only; needs `rg` and `nm`) builds the VM, compiles each
  `vm/*.h` on its own, runs `vm/tools/check-layers.sh` on the objects of the
  mode (`docs/vm/15-layers.md` §15.5) and its self-test. A new `vm/*.c` file
  goes in one list of the script.
- `vm-sanitize-build` and `vm-sanitize-test` (`SANITIZE_JOBS`, 4) are the
  Racket tests that run against the VM in the sanitizer job. They and
  `vm-diff-test` do not depend on `vm` on purpose: they test the VM that an
  earlier step built.
- `vm-diff-build` and `vm-diff-test` are the golden tests; `sweep-full` runs
  them with `AGENTICA_SWEEP=full` (the weekly `sweep.yml`). `test-distribution`
  is the release's distributed-executable test.

## Pull requests (`.github/workflows/ci.yml`)

CI runs its checks on pull requests, on the self-hosted Linux runner
(`docker-runner` label).

- `test`: first the `changes` step (below), then `make -j vm vm-test test-bdd`
  (one make: the C tests run in parallel and `dist/agentica` is built beside
  them), `make test` with the process and module tests on `dist/agentica`
  (`AGENTICA_TEST_EXECUTABLE`) running alongside it, `make vm-latency` alone
  after that, `make smoke` (the example smoke runs in `tests/smoke.sh`, in parallel), the vendored OpenSSL
  check (the last step that builds), and then `make dup-check` (it runs even
  when an earlier step fails, so a clone or an npm outage does not hide the
  test results). `make test` runs with `JOBS=6` beside the two executable-test
  workers, and the vm-latency negative control starts its two VMs together
  (it can only raise latency, so the control stays valid). It also
  checks that `vm/unicode_data.c` is up to date. That check is skipped when
  the generator, the table and the Makefile's `vm-unicode` rule match an
  earlier passing check. The vendored check stays last: it rebuilds
  `build/vm/release/obj` with other flags, so nothing that runs `make vm`
  may run beside it.
- `dup-check` as a job runs only on `master` pushes (it saves the npm cache).
- `vm-sanitizers` (`needs: test`, and it still runs when `test` fails):
  `make vm-lint`, one `make -j vm vm-test vm-fuzz`, `make vm-layers` (on the
  sanitizer objects; the job installs ripgrep if `rg` is missing), the ASan golden,
  bytecode, trace, TCP and TLS tests, and the GC stress build. The TCP tests need
  Node; the TLS tests need Node and Python 3. Both PR jobs set
  `AGENTICA_SWEEP=sampled`, so their golden and GC-stress runs sample the
  `--max-steps` sweep with a seed from `GITHUB_SHA`; a failure prints
  `AGENTICA_SWEEP_SEED`. The full sweep runs locally (`make test`), in
  `release.yml` (`AGENTICA_SWEEP=full`), and weekly in `sweep.yml` (Monday
  03:00 UTC, or by hand) on the release VM.
- OpenSSL: every CI job builds with the system OpenSSL (the default
  `AGENTICA_OPENSSL=system`; a guard step installs `libssl-dev pkg-config` when
  `pkg-config` cannot find OpenSSL 3, a no-op on our runners), the
  sanitizer and GC-stress builds too, so no job builds an instrumented
  OpenSSL. Only the release sets `AGENTICA_OPENSSL=vendored`. To keep that path
  from rotting, the last building step of `test` restores the cached vendored
  release-mode OpenSSL (restore only) and, on a hit, links
  `build/vm/release/agentica-vm` against it, checks that `readelf -d`
  shows no `libssl` or `libcrypto` and that `--version` names the
  submodule's version, and runs the TLS and HTTP tests on that binary. On
  a miss (a new OpenSSL key, such as a submodule bump) it skips;
  `warm-third-party` runs the same link check on `master`.
- libgc: pull request jobs build with the system libgc (the default
  `AGENTICA_GC=system`); the same guard step also installs `libgc-dev` when
  `pkg-config` cannot find `bdw-gc` 8.2.0 or newer (a no-op on the current
  runner image, which has libgc-dev 8.2.12). `GC_MIN` is 8.2.0 because that
  is the series the VM is tested with; Debian 12 and 13 and Ubuntu 24.04 and
  newer ship 8.2.x, and older systems use `AGENTICA_GC=vendored`. The jobs
  that run on `push` to `master` (`warm-third-party`), the weekly `sweep.yml`
  and the release set `AGENTICA_GC: vendored`, so the full sweep tests the GC
  the release ships and the submodule's `gc.o` stays built for the release and
  for GC stress, which always uses it. `vendored-check` links
  with the vendored libgc and OpenSSL and fails on `libgc` in `readelf -d`;
  the release also checks the unpacked archive. The key of
  `make -s vm-third-party-key` starts with a `libgc=` line, and the VM flag
  stamps include the mode. Both modes use the same `build/vm/release/obj`
  directory; a change of mode changes the stamps, which forces a full
  recompile and relink. `fuzz.yml` stays on the system default.
- The `test` and `vm-sanitizers` jobs need Node and Python 3 for the
  network peers. The golden tests need Python 3 too (the child channel
  fixtures run through `tests/fixtures/channel-run.py`): `sweep.yml` and the
  golden step of `release.yml` print `python3 --version` before them, and
  the goldens fail in CI when it is missing.

### When `vm-sanitizers` runs

The first steps of the `test` job (the `changes` step, checkout with
`fetch-depth: 2`) diff the pull request merge commit against its base
(`git diff HEAD^1 HEAD`) and publish the result as job outputs. It runs `vm-sanitizers` only when the VM,
lowering or bytecode files, the `std/` modules, or CI itself, change:

- `vm/`, `src/lower.rkt`, `src/bytecode.rkt`, `src/version.rkt`,
  `src/stdlib.rkt` (the registry that embeds the `std/` modules);
- `tests/vm-diff-*`, `tests/vm-trace-test.rkt`, `tests/vm-tcp-test.rkt`,
  `tests/fixtures/tcp-peer.js`, `tests/vm-tls-test.rkt`,
  `tests/fixtures/tls-peer.js`, `tests/fixtures/tls-peer.py`,
  `tests/fixtures/tls/`, `tests/vm-http-test.rkt`, `tests/fixtures/http-*`,
  `tests/vm-stop-test.rkt`, `tests/fixtures/stop-peer.py`,
  `tests/vm-channel-test.rkt`, `tests/fixtures/channel-peer.py`,
  `tests/vm-stdout-test.rkt`, `tests/fixtures/stdout-peer.py`,
  `tests/vm-file-lines-test.rkt`, `tests/fixtures/lines-peer.py`,
  `tests/vm-stack-test.rkt`,
  `tests/vm-test-protocol-test.rkt`, `tests/fixtures/test-protocol-peer.*`,
  `tests/vm-child-channel-test.rkt`, `tests/fixtures/child-channel*`,
  `tests/fixtures/child_channel.py`, `tests/fixtures/channel-run.py`,
  `tests/cli-in-process.rkt`, `tests/bytecode-test.rkt`,
  `tests/fixtures/vm/`;
- `stdlib/`: every `std/` module written in Agentica, `stdlib/bdd/` too (the
  pattern is `stdlib/*`; in a shell `case`, `*` also matches `/`);
- the Makefile, `.gitmodules`, `.clang-tidy`, `ci.yml`.

Otherwise it shows as skipped. If the `changes` step does not set its outputs, `vm-sanitizers` still
runs. A manual run always runs it. Front-end changes (checker, AST,
builtins, `main.rkt`) skip `vm-sanitizers` on purpose; the `test` job still
runs the `vm-diff` golden shards and every CLI test with the real VM. Keep
that path list in `ci.yml` in step with new VM files.

Only a manual run, or a pull request that changes `vm/trace.*` or
`vm/tests/trace_test.c`, also runs `make vm-trace-off` (`make vm vm-test
TRACE=0`, then it checks that `--version` says `trace off`).

Pull requests and `master` pushes that change only docs, the site or
Markdown skip the whole CI workflow. A newer push cancels an older run.

## Caches and `master` pushes

- Compiled Racket files are cached per job. `vm-sanitizers` and
  `site-examples.yml` fall back to the `test` cache.
- The vendored OpenSSL's headers, `libssl.a`, `libcrypto.a` and stamp are
  cached for the release mode only, with `actions/cache`. The key is the
  hash of `make -s vm-openssl-key AGENTICA_OPENSSL=vendored` (the Configure and
  make command lines, compiler version, OpenSSL version and submodule
  commit). `warm-third-party` saves it; `test` only restores it.
- The sanitizer and GC-stress builds of yyjson, picohttpparser, libuv and
  `build/vm/gc.o` are not cached with `actions/cache`: with the ccache volume
  warm they rebuild in under a second, less than restoring the caches took.
- Every compile goes through ccache: the Makefile finds it on `PATH`, and
  the runner image (ccache 4.12) points `CCACHE_DIR` at a volume that both
  runners share (`CCACHE_MAXSIZE=5G`), so hits carry across jobs and
  pull requests. PR jobs can write to that volume, so the release sets
  `CCACHE=` (in the job env and on the `make` line) and never uses it.
- `vm-sanitizers` runs its `make` steps with `-j"$(nproc)"`, and
  `make vm-sanitize-test` runs `raco test -j 4`. `make vm-test` and `make vm-lint` run their C tests
  and clang-tidy files in parallel (`xargs -P $(JOBS)`).
- A `master` push runs no tests. It runs only `dup-check` (which also saves
  the npm cache of jscpd, keyed by `tools/jscpd/package-lock.json`) and
  three jobs that fill caches under the PR jobs' keys:
  - `warm-cache` compiles the Racket files;
  - `warm-unicode` runs the unicode check (a separate job, so a stale table
    fails `master` without losing the compiled-files cache);
  - `warm-third-party` builds the vendored release-mode OpenSSL and runs
    the vendored link check.

  These exist because a pull request can restore caches saved on its own
  merge ref or on `master`, never another pull request's.

## Workflows run by hand

Actions → Run workflow:

- `platforms.yml` runs `make vm vm-test` and the VM golden and bytecode
  tests on macOS and Windows (MSYS2 UCRT64). Run it before merging a change
  to platform code (`vm/main.c`, the Makefile, file or process handling).
- `fuzz.yml` fuzzes the sanitizer VM with 5 million mutants and a random
  seed.

`sweep.yml` runs by schedule (Monday 03:00 UTC) and by hand: the `vm-diff` shards on
the release VM with `AGENTICA_SWEEP=full` (`make sweep-full`). Nothing else in CI runs on a schedule.

macOS and Windows are paused until further notice: `platforms.yml` is not
run and only Linux is required. Their platform code is kept but untested;
Linux code goes under `#ifdef __linux__`.

Two more workflows: `site-examples.yml` and `pages.yml` (see
`references/site.md`).

## Release (`release.yml`)

The release workflow builds `agentica-vm` with a pinned `zig cc` against
glibc 2.28, with `AGENTICA_OPENSSL: vendored` and `AGENTICA_GC: vendored`
set for the whole job. It
checks that floor with `objdump -T`, checks that OpenSSL is linked
statically (in the build and in the unpacked archive) and that `--version`
names the submodule's OpenSSL version. It fails when `readelf -d` shows a
NEEDED `libgc` (in the build and in the unpacked archive). It ships the VM in the archive's
`bin/` next to `agentica`, with the VM's third-party licenses in
`licenses/`. Its test steps are targets: `make vm-diff-test` runs the golden
tests on the release VM (`AGENTICA_VM_BINARY=dist/agentica-vm`, with the
full sweep), and `make test-distribution` runs the distributed-executable
test. The tags, the version, the Racket bundle and the CHANGELOG rules are
under "Tags, versions and CHANGELOG" below.

### Tags, versions and CHANGELOG

- `src/version.rkt` is the single source of the version: `make version` prints
  it and `agentica --version` reports it. Keep it in sync with the Git tag.
- Every PR with a user-visible change adds a short entry under `## [Unreleased]`
  in `CHANGELOG.md` (Added, Changed, Removed or Fixed; start a change that
  breaks programs or CLI use with `**Breaking:**`; add the PR number).
  Internal-only work (CI, refactors, docs) needs none. A release PR renames
  `[Unreleased]` to `## [X.Y.Z] - DATE`, leaves an empty `[Unreleased]` above
  it, bumps `src/version.rkt` and fixes the compare links at the bottom.
- Every minor or patch bump is tagged, and the tag pushed, right away after its
  PR merges. The bump commit and the annotated tag message are both `release
  version <tag>`, for example `git tag -a 0.2.0 -m "release version 0.2.0"`.
- Tag releases with the bare version (`0.2.0`, no `v` prefix).
  `.github/workflows/release.yml` validates the tag against `src/version.rkt`,
  builds `dist/agentica`, packages a `raco distribute` bundle with `LICENSE`,
  `NOTICE` and, in `licenses/racket/`, Racket's license files (from its share
  directory) and Chez Scheme's `NOTICE` (checked in at
  `licenses/racket/ChezScheme-NOTICE`, from Racket v9.3's source; update it when
  the Racket version changes), checks that the archive has them, and publishes a
  GitHub Release with empty notes; a maintainer writes a short summary of the
  release by hand afterwards (key points and breaking changes, no PR list; the
  details stay in `CHANGELOG.md`).

## Copy-paste check (jscpd)

- `make dup-check` runs jscpd over `src/*.rkt`, `vm/*.c`, `vm/*.h` and
  `vm/tests/*.c` with `.jscpd.json`. Its `weak` mode skips comments, so
  similar file header comments are not clones.
- jscpd is pinned with its whole dependency tree by
  `tools/jscpd/package-lock.json` and installed by `npm ci --ignore-scripts`
  into `tools/jscpd/node_modules`.
- CI runs it in the `test` job of pull requests and in its own `dup-check`
  job on `master` pushes, and fails on any clone not in
  `.jscpd-baseline.json`, so new duplicated code fails CI.
- Remove the copy instead of growing the baseline. After removing old clones,
  refresh it with `make dup-baseline` and commit the file. A reviewer must
  reject a PR that grows the baseline instead of removing a copy.

## What CI runs

- Pull requests: the jobs and their make targets are listed under "Pull
  requests" above.
- `master` pushes: `dup-check` and the cache jobs, under "Caches and `master`
  pushes".
- Schedule and by hand: `sweep.yml` and "Workflows run by hand".
- Release: "Release (`release.yml`)".
