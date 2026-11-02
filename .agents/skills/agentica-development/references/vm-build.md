# VM build, submodules, sanitizers and platforms

Make targets, the third-party submodules, sanitizers, fuzzing and portability.

Read first: `references/vm.md`.

## Commands

`make help` and the comments of `mk/*.mk` list every target. The ones that need
a note:

```sh
git submodule update --init          # bdwgc, yyjson, libuv, picohttpparser, openssl, libffi
make                                 # dist/agentica from bootstrap/stage0.agcb (Linux: system libgc, OpenSSL 3, zlib via pkg-config; Debian: libgc-dev libssl-dev zlib1g-dev pkg-config)
make AGENTICA_GC=vendored            # libgc from the submodule, static (release, GC-stress, non-Linux hosts)
make AGENTICA_OPENSSL=vendored       # OpenSSL from the submodule, static, built once per mode (needs Perl; a few minutes the first time; the release)
make AGENTICA_ZLIB=vendored          # zlib from the submodule, static (release, non-Linux hosts)
make -s vm-openssl-key AGENTICA_OPENSSL=vendored   # OpenSSL build key; CI caches by its hash (vm-third-party-key: the others)
make fixed-point                     # stage2 == stage3, and dist/agentica compiling the front end gives stage2 again
make stage0                          # refresh bootstrap/stage0.agcb (references/ci.md, "Refreshing stage0")
make CCACHE=                         # without ccache
make SANITIZE=1 && make vm-test SANITIZE=1   # clang ASan+UBSan, no GC (calloc, never free)
make vm-test TRACE=0                 # trace points compiled out (still type-checked)
AGENTICA_VM_TRACE=all AGENTICA_VM_TRACE_FILE=./t.trace dist/agentica run -- prog.agcb   # sched,io,proc,tls,loader,gc
AGENTICA_VM_TRACE=profile dist/agentica check compiler/front_end.agc   # step profile at the end; folded stacks and Profile.measure: agentica-programming, references/performance.md
make vm-libfuzz-run LIBFUZZ_TIME=300 LIBFUZZ_JOBS=2   # coverage-guided run; failures in build/vm/libfuzz/crashes/ (docs/vm/11-build-ci-supply-chain.md, Fuzzing)
make vm-gc-stress                    # GC_STRESS=1 (collect every 64 allocations), vm-test and the goldens
make vm-tsan / vm-tsan-run           # TSAN=1 build, no libgc: the threaded C tests / tests/test_vm_multicore.py under TSan
make goldens FIXTURES="name ..."     # rewrite tests/fixtures/vm/**/*.expected (all, or only those fixtures; an unknown name exits 2); review the diff
make vm-golden-check FIXTURES="name ..."  # the CI golden check (3 formats, sweep, sidecars, stack files) for only those fixtures
make vm-lint CLANG_TIDY=path         # clang-tidy 19+ over vm/*.c and vm/tests/*.c; any warning fails
AGENTICA_REQUIRE_VM=1 make vm-diff-test JOBS=4
dist/agentica compile prog.agc -o prog.agcb && dist/agentica run -- prog.agcb
dist/agentica --dump-ir prog.agc
```

- CI runs `vm-sanitizers` only for the VM paths listed in the `changes` job
  of `.github/workflows/ci.yml`; a new VM source or test file outside those
  paths must be added there (`references/ci.md`).
- `agentica file.agc` runs in one process
  (`docs/vm/08-loader-and-cli.md` §9): the front end of the binary
  (`compiler/front_end.agc`) compiles in memory and hands the bytes to C with
  `FrontEnd.hand_off`; `vm/agentica.c` runs them in a new runtime. A
  `LOWER-UNSUPPORTED` is printed like any diagnostic, exit 1. Every catalog
  implementation is in `VM_BUILTINS` (`compiler/lower/lower_tables.agc`), so no
  builtin reaches it today.
  `agentica run [FLAGS] -- file.agcb [ARGS...]` runs a compiled file: C
  handles it when `run` is the first word, with the VM flags (`--max-steps`,
  `--seed`, `--flush-timeout`, `--schedulers`, `--jit`, the `--deny-*` flags,
  `--sandbox`, `--ai`, `--json`, `--source-root`, `--version`) and the hidden
  `--driver-pid PID` and `--embedded NAME` (run the `runner` or `steps`
  program that the binary carries; the front end may not pass it on in a
  hand-off). The VM then
  deletes its input right after reading it (only a private file is read with
  that flag); on Linux it first resets `SIGTERM` to its default, sets
  `PR_SET_PDEATHSIG` to `SIGTERM` and exits 2 when `getppid()` is not `PID`.
  `agentica test` runs the BDD driver in the front end; it starts the runner
  with `self_path run --driver-pid ... --embedded runner` (see
  `references/bdd.md`). A new VM option goes in `agc_launch_parse` and in the
  pass-through list of the front end (`compiler/app/cli_options.agc` and the
  hand-off check in `vm/agentica.c`). A new builtin goes into `VM_BUILTINS`
  with its C implementation. `AGENTICA_VM_BINARY` is a test knob only (the
  Python tests run that build of the binary: the GC stress, the vendored link,
  a sanitizer build). `tests/test_vm_diff_8.py` checks the CLI against the
  goldens.

- Each mode compiles `vm/*.c`, `vm/tests/*.c` and the drivers once into
  `$(VM_BUILD)/obj/` with `-MMD -MP` (dependency files beside the objects),
  and every binary links from them (`VM_LINK`); a new `vm/*.c` file goes
  in `VM_SRC` only. `$(VM_BUILD)/obj-flags` recompiles the mode when the
  compile line or the compiler's `--version` changes; `tls_openssl.o` also
  follows the OpenSSL stamp. Compiles run through `$(CCACHE)`, the vendored
  OpenSSL too, but not its key. ccache is found on `PATH` and used only when
  its cache dir (or its nearest existing parent) is writable; the check
  creates nothing. `CCACHE=` turns it off (use it when a ccache setup fails).
  `CCACHE_BASEDIR` is the checkout, and the `-g` modes add
  `-fdebug-prefix-map=$(CURDIR)=.` (`DEBUG_MAP`) to the VM, third-party and
  vendored OpenSSL compiles but not to the stamps or the OpenSSL key, so
  worktrees share hits and debug info names `.`. From a checkout reached
  through a symlink, `$(PWD)` (the path gcc and ccache see) is mapped too.
  Third-party `-g` objects built earlier or restored from the CI cache
  keep their absolute paths until their key changes.
- `build/vm/<mode>/obj/tests/*_test.o` are `.SECONDARY`, so make keeps them
  and a second `make vm-test` recompiles nothing.
- `SANITIZE` may come from the environment; `build/vm/flags` relinks when the
  flags change.
- Golden tests (`docs/vm/README.md` §1, `docs/vm/12-testing-and-pr-plan.md`
  §12.1): `tests/test_vm_diff_1.py` … `test_vm_diff_8.py` (unittest) run each
  fixture of `tests/fixtures/vm/` on the VM and compare exit code, stdout,
  program stderr and diagnostic code with its `<name>.expected`, plus a
  `--max-steps` sweep. Shared code is in `tests/vm_diff_support.py`; each
  shard takes a fixed share of the fixtures so `make test-py` runs them in
  parallel. The fixtures are compiled by the product CLI (`compile FILE -o
  OUT`), never in process. When behaviour changes on purpose, `make goldens`
  rewrites the expected files from the VM; commit them, and the PR diff shows
  the change for review.
- One fixture: `make vm-golden-check FIXTURES="list-sort-runs std-binary"`
  runs the shard code (`check_fixture`; `check_runaway` for `step-limited/`
  names) on just those fixtures, then the stack-trace cases of
  `tests/test_vm_stack.py` for the ones it covers, and exits non-zero with the
  shard failure text on a mismatch. `make goldens FIXTURES=...` rewrites only
  their `.expected` and `.stack.*` files. Both pass the list (space or comma
  separated, names without `.agc`) in `AGENTICA_FIXTURES`; a name that matches
  no fixture exits 2, and `vm-golden-check` without `FIXTURES` exits 2. The
  same names work by hand: `AGENTICA_FIXTURES=name python3 -m
  tests.vm_diff_support check`. Sidecars next to `<name>.agc`, read by
  `Fixture.of` (the golden test and the `--max-steps` sweep feed `.stdin`
  and `.args` to the VM):
  - `.stdin`: raw bytes fed to the program's stdin (`.gitattributes` marks them
    binary so CRLF survives). The golden batch gives them as a file, the
    step allowance run and the extras as a pipe.
  - `.args`: a list of double-quoted strings (the harness reads them with a
    small regular expression) passed as program arguments; `"@tmp"` becomes a
    fresh empty directory per run, and that path is turned back into `@tmp` in
    the output before the comparison; `"@fixtures/x"` the path
    `tests/fixtures/x`. File fixtures (`files-*`) use `@tmp` and long
    timeouts, and never touch paths outside it.
  - `.env`: a list of `("NAME" . "value")` string pairs in the same syntax
    added to the environment of every VM run of the fixture
    (`system-env.env`); a program reads only the names it lists and never prints
    the whole environment.
  - `.channel`: the golden run goes through `tests/fixtures/channel-run.py`
    (Python 3; `channel-run.js` with Node on Windows). The wrapper hands a
    socket to the VM as fd 3 (`AGENTICA_CHANNEL=3`), sends the first line of
    the file and one more after each line the VM sends back, and writes
    everything to its stdout in a fixed order: the child's stdout as it is,
    each channel line as `channel> ` and the line. The `test-*` fixtures use
    it; a fixture of the `agentica test` modes (`--agentica-test run`) without
    a `.channel` file is the no-channel case (`test-no-channel`).
  - `spawn-denied` name prefix: runs with `--deny-run`. A `process-` fixture's
    children must be on every CI runner (`/bin/sh`, `cat`, `sleep`) and must
    end or be closed.
  - `HEAVY_FIXTURES` (in `tests/vm_diff_support.py`): fixtures pinned to a
    shard; the others rotate over shards 1 to 7 and shard 8 runs the extras. A
    new costly fixture may need an entry.
  - `step-limited/<name>.agc`: runaway loops, golden taken at
    `--max-steps 500`, checked at 1 to 5, 50 and 500, with no step count. The
    sweep cannot see an ignored limit: add a runaway program there for each new
    loop or call construct (it prints nothing after the loop).
  - `<name>.stack.plain`, `.stack.ai`, `.stack.json`: expected stderr of the
    stack-trace fixtures in the three formats, kept by
    `tests/test_vm_stack.py` (`python3 -m tests.test_vm_stack` rewrites them).
- The `tests/test_vm_diff_*.py` shards need a built VM (`make test` builds it;
  `make vm-diff-test` does not): a local run skips them when it is missing,
  and CI fails (`AGENTICA_REQUIRE_VM=1`). `AGENTICA_FIXTURES` does not filter
  a shard run, only `make goldens` and `make vm-golden-check`. Each shard runs
  the fixture with `--json` and compares exit code, stdout, stderr without the
  final JSON diagnostic line, and the diagnostic code with the golden; one
  more run each in the plain and `--ai` formats must match exit code, stdout
  and program stderr and name the same code. Crash lines carry the fixture's
  path, so `unfixture` replaces `tests/fixtures/` with `@fixtures/` first.
  The `--max-steps` sweep, around the golden's step count T (the smallest
  limit that finished when `make goldens` searched for it): each limit must
  give the golden outcome, or exit 1 with `RUNTIME-STEP-LIMIT` and output
  that is a prefix of the golden's; once a limit finishes, larger ones must
  too (`check_sweep`). A run under `T + max(10, T / 10)` must finish
  (`check_step_allowance`, which catches over-charging). With
  `AGENTICA_SWEEP=sampled` (the `test` and ASan jobs and `make vm-gc-stress`)
  each fixture runs only some limits, drawn from `AGENTICA_SWEEP_SEED` (else
  `GITHUB_SHA`, so it rotates with the commit); a failed limit names the seed:
  rerun with that `AGENTICA_SWEEP=sampled AGENTICA_SWEEP_SEED=...`. Local
  `make test`, the release and the weekly `sweep.yml` keep the full sweep.
  `AGENTICA_SWEEP=ends` (`make test-shared`) runs only the ends, as do the
  fixtures of `ENDS_ONLY_FIXTURES` in every mode (costly runs). A fixture
  whose steps change with the kernel is in `KERNEL_TIMED_FIXTURES` (no limit at
  `T` or `T - 1`); the reason is in `tests/vm_diff_support.py`. Make a fixture's
  step count independent of time first: wait on a channel, never loop with
  `Task.sleep` until something changes, read a known size with `read_line`
  (not a `recv_bytes` loop), and leave no producer with a timer running when
  `main` returns (its last steps would race with the exit).
  A new fixture needs its golden: run `make goldens`, read the new `.expected`
  by hand, and commit it; a changed golden is a reviewed behaviour change.
  `make goldens` refuses a run that timed out, died by a signal or ends in
  `RUNTIME-INTERNAL`, and names `.expected` files with no `.agc` next to them.
  Every test program gets `LC_ALL=C.UTF-8` and `LANG=C.UTF-8`
  (`vm_environment` in `tests/agentica_test.py`), so OS error text is the
  untranslated C text. Sweep and runaway runs time out after 60 seconds; the
  rest of the batch is then skipped and recorded as 124. Fixture stdin comes
  from a file; pipe stdin is covered by the extras of shard 8 and the CLI
  tests.
- `-Wall -Wextra -Werror` and the hardening flags apply to `vm/*.c` only;
  `gc.c` gets only `-O2 -fPIE -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION
  -DGC_THREADS -DGC_BUILTIN_ATOMIC -DPARALLEL_MARK -DTHREAD_LOCAL_ALLOC`
  (`build/vm/gc.o` rebuilds when its stamp `build/vm/gc-flags` changes).
  `yyjson.c` is built per mode into `$(VM_BUILD)/yyjson.o` with `YY_CFLAGS`
  (the sanitizers in `SANITIZE=1`, no `-Werror`) and the `YY_DEFS` that turn
  off everything but the reader; `vm/*.c` see the same `YY_DEFS` and `-I
  vm/third_party/yyjson/src`, and only `vm/json.c` includes `yyjson.h`. libuv
  (a `UV_NAMES` list per system in `mk/vm.mk`, from the lists of its
  `CMakeLists.txt`) builds per mode into `$(VM_BUILD)/uv/*.o` with
  `-std=gnu11`, its own `UV_DEFS` and the mode's `YY_CFLAGS`, then
  `$(VM_BUILD)/libuv.a`, linked with `-ldl -lrt` on Linux. The yyjson,
  picohttpparser and libuv objects follow only their own stamp,
  `$(VM_BUILD)/third-party-flags` (the output of `make -s
  vm-third-party-key`), not `build/vm/flags`, the Makefile or the source
  mtimes, so `TRACE` does not rebuild them and a CI cache hit stays valid.
  Compile them only through the `YY_COMPILE`, `PICO_COMPILE` and `UV_COMPILE`
  variables, so a new flag changes the stamp; the I/O files (`rg -l uv.h vm`)
  include `uv.h`. Bumping libuv: check out the new tag inside
  `vm/third_party/libuv`, compare its Linux source list with `UV_NAMES`,
  `git add vm/third_party/libuv`, and rerun the sanitizer and diff tests.
- Platforms: `mk/vm.mk` picks Linux, macOS or Windows (MSYS2 UCRT64) in one
  block; every binary target ends in `$(EXE)`, and `vm/agentica.rc` (the
  `longPathAware` manifest) replaces MinGW's default on Windows. The
  `platforms.yml` matrix is in `references/ci.md`; platform code follows
  "Platform code" in `references/vm-c.md`.

## Submodules

Under `vm/third_party/` (`git submodule status` shows the pins). `openssl` is
built static per mode only with `AGENTICA_OPENSSL=vendored`
(`docs/vm/10-dependencies-and-platforms.md` §10.0); `yyjson` builds only its
reader; `picohttpparser` (MIT or Perl; the MIT notice is at the top of its
header) is included only by `vm/http_pico.c`.

## Gotchas

- Checking out a branch without the submodule warns `unable to rmdir
  vm/third_party/bdwgc`; run `git submodule update --init` after switching
  back.
- Under ASan, Boehm is off (`-DAGC_NO_GC`); GC bugs need the GC-debug stress
  run (`make vm-gc-stress`), not ASan.
- Portability: keep driver platform code in `vm/launch.c` and the platform block
  of `mk/vm.mk`; VM platform code follows "Platform code" in
  `references/vm-c.md`. `#ifdef SIGPIPE`, not `#ifdef _WIN32`,
  guards the signal. `_Exit` is C11; mingw-w64 still provides `write`,
  `open`, `read`, `fstat` and `ssize_t` with `-std=c11`, but its `struct
  stat` has a 32-bit `st_size`, so Windows uses `_fstat64`. Windows opens
  files through libuv (`vm/file_io.c`, UTF-16 underneath), never through
  `open` (ANSI code page).
- libgc without `NO_EXECUTE_PERMISSION` maps writable and executable pages,
  and macOS on arm64 aborts with `Cannot allocate executable pages` as soon
  as the heap grows (the loader test does). Interior pointers on the stack
  and in registers always count; `ALL_INTERIOR_POINTERS` only adds those
  stored in GC objects and static data and one-past-the-end pointers (one
  extra byte per object). Nothing relies on it; it is upstream's default.
- `-D_POSIX_C_SOURCE` makes mingw-w64 use its own printf
  (`__USE_MINGW_ANSI_STDIO=1`), not the UCRT's; both print `%.767e`
  exactly, as does the macOS libc.
- `.gitattributes` keeps LF on checkout (GitHub's Windows runners set
  `core.autocrlf`). Git detects files with NUL bytes as binary; a binary
  fixture without them needs a `binary` line there.
- MSYS2 in CI has no `grep`; use `sed` or install the package.
