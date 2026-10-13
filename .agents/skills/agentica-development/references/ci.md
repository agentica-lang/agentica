# CI, release and the copy-paste check

Read this before changing `.github/workflows/`, the Makefile, or before
adding VM source files, test peers or fixtures. Everything runs on Racket
CS 9.3.

## Pull requests (`.github/workflows/ci.yml`)

CI runs its checks on pull requests, on the self-hosted Linux runner
(`docker-runner` label).

- `test`: `make vm vm-test`, `make test`, `make vm-latency` right after
  `make test`, and the example smoke tests. It also checks that
  `vm/unicode_data.c` is up to date. That check is skipped when the
  generator, the table and the Makefile's `vm-unicode` rule match an earlier
  passing check.
- `dup-check`: `make dup-check`. It is its own job, so a clone or an npm
  outage does not hide the test results.
- `vm-sanitizers`: `make vm-lint`, the ASan golden, bytecode, trace, TCP and
  TLS tests, the fuzz smoke and the GC stress build. The TCP tests need
  Node; the TLS tests need Node and Python 3.
- OpenSSL: every CI job builds with the system OpenSSL (the default
  `VM_OPENSSL=system`; a guard step installs `libssl-dev pkg-config` when
  `pkg-config` cannot find OpenSSL 3, a no-op on our runners), the
  sanitizer and GC-stress builds too, so no job builds an instrumented
  OpenSSL. Only the release sets `VM_OPENSSL=vendored`. To keep that path
  from rotting, the last step of `test` restores the cached vendored
  release-mode OpenSSL (restore only) and, on a hit, links
  `build/vm/release/agentica-vm` against it, checks that `readelf -d`
  shows no `libssl` or `libcrypto` and that `--version` names the
  submodule's version, and runs the TLS and HTTP tests on that binary. On
  a miss (a new OpenSSL key, such as a submodule bump) it skips;
  `warm-third-party` runs the same link check on `master`.
- The `test` and `vm-sanitizers` jobs need Node and Python 3 for the
  network peers.

### When `vm-sanitizers` runs

A first `changes` job diffs the pull request merge commit against its base
(`git diff HEAD^1 HEAD`). It runs `vm-sanitizers` only when the VM,
lowering or bytecode files, the `std/` modules, or CI itself, change:

- `vm/`, `src/lower.rkt`, `src/bytecode.rkt`, `src/version.rkt`,
  `src/stdlib.rkt` (the registry that embeds the `std/` modules);
- `tests/vm-diff-*`, `tests/vm-trace-test.rkt`, `tests/vm-tcp-test.rkt`,
  `tests/fixtures/tcp-peer.js`, `tests/vm-tls-test.rkt`,
  `tests/fixtures/tls-peer.js`, `tests/fixtures/tls-peer.py`,
  `tests/fixtures/tls/`, `tests/vm-http-test.rkt`, `tests/fixtures/http-*`,
  `tests/cli-in-process.rkt`, `tests/bytecode-test.rkt`,
  `tests/fixtures/vm/`;
- `stdlib/`: every `std/` module written in Agentica, `stdlib/bdd/` too (the
  pattern is `stdlib/*`; in a shell `case`, `*` also matches `/`);
- the Makefile, `.gitmodules`, `.clang-tidy`, `ci.yml`.

Otherwise it shows as skipped. If `changes` fails, `vm-sanitizers` still
runs. A manual run always runs it. Front-end changes (checker, AST,
builtins, `main.rkt`) skip `vm-sanitizers` on purpose; the `test` job still
runs the `vm-diff` golden shards and every CLI test with the real VM. Keep
that path list in `ci.yml` in step with new VM files.

Only a manual run, or a pull request that changes `vm/trace.*` or
`vm/tests/trace_test.c`, also runs `make vm vm-test TRACE=0` and checks
that `--version` says `trace off`.

Pull requests and `master` pushes that change only docs, the site or
Markdown skip the whole CI workflow. A newer push cancels an older run.

## Caches and `master` pushes

- Compiled Racket files are cached per job. `vm-sanitizers` and
  `site-examples.yml` fall back to the `test` cache.
- The vendored OpenSSL's headers, `libssl.a`, `libcrypto.a` and stamp are
  cached for the release mode only, with `actions/cache`. The key is the
  hash of `make -s vm-openssl-key VM_OPENSSL=vendored` (the Configure and
  make command lines, compiler version, OpenSSL version and submodule
  commit). `warm-third-party` saves it; `test` only restores it.
- `vm-sanitizers` caches the sanitizer and GC-stress builds of
  yyjson, picohttpparser and libuv (and `build/vm/gc.o` for GC stress),
  with their `third-party-flags` (and `gc-flags`) stamps. The key is the
  hash of `make -s vm-third-party-key`. The VM and test binaries are not
  cached.
- `vm-sanitizers` runs its `make` steps with `-j"$(nproc)"`. The C tests
  still run one after another.
- A `master` push runs no tests. It runs only `dup-check` (which also saves
  the npm cache of jscpd, keyed by `tools/jscpd/package-lock.json`) and
  three jobs that fill caches under the PR jobs' keys:
  - `warm-cache` compiles the Racket files;
  - `warm-unicode` runs the unicode check (a separate job, so a stale table
    fails `master` without losing the compiled-files cache);
  - `warm-third-party` builds the vendored release-mode OpenSSL and runs
    the vendored link check, then builds the other third-party libraries
    in the sanitizer and GC-stress modes.

  These exist because a pull request can restore caches saved on its own
  merge ref or on `master`, never another pull request's.

## Workflows run by hand

Actions → Run workflow:

- `platforms.yml` runs `make vm vm-test` and the VM golden and bytecode
  tests on macOS and Windows (MSYS2 UCRT64). Run it before merging a change
  to platform code (`vm/main.c`, the Makefile, file or process handling).
- `fuzz.yml` fuzzes the sanitizer VM with 5 million mutants and a random
  seed.

macOS and Windows are paused until further notice: `platforms.yml` is not
run and only Linux is required. Their platform code is kept but untested;
Linux code goes under `#ifdef __linux__`.

Two more workflows: `site-examples.yml` and `pages.yml` (see
`references/site.md`).

## Release (`release.yml`)

The release workflow builds `agentica-vm` with a pinned `zig cc` against
glibc 2.28, with `VM_OPENSSL=vendored` set for the whole job. It checks that
floor with `objdump -T`, checks that OpenSSL is linked statically and that
`--version` names the submodule's OpenSSL version. It ships the VM in the archive's `bin/` next to
`agentica`, with the VM's third-party licenses in `licenses/`. Tags,
versions and the Racket bundle are in SKILL.md, "Releases".

## Copy-paste check (jscpd)

- `make dup-check` runs jscpd over `src/*.rkt`, `vm/*.c`, `vm/agc.h` and
  `vm/tests/*.c` with `.jscpd.json`.
- jscpd is pinned with its whole dependency tree by
  `tools/jscpd/package-lock.json` and installed by `npm ci --ignore-scripts`
  into `tools/jscpd/node_modules`.
- CI runs it in its own `dup-check` job and fails on any clone not in
  `.jscpd-baseline.json`, so new duplicated code fails CI.
- Remove the copy instead of growing the baseline. After removing old
  clones, refresh it with `make dup-baseline` and commit the file.
