# VM build, submodules, sanitizers and platforms

Make targets, the third-party submodules, sanitizers, fuzzing and portability.

Read first: `references/vm.md`.

## Commands

```sh
git submodule update --init          # fetch bdwgc, yyjson, libuv, picohttpparser and openssl after a clone or a bump
make                                 # dist/agentica, the one binary, from bootstrap/stage0.agcb (Linux: the system libgc and OpenSSL 3 from pkg-config, dynamic: Debian libgc-dev libssl-dev pkg-config)
make AGENTICA_GC=vendored            # libgc from the submodule (extra/gc.c) instead, static; the release, the GC-stress build and non-Linux hosts build this way
make AGENTICA_OPENSSL=vendored       # OpenSSL from the submodule instead, static, built once per mode (needs Perl, a few minutes the first time); the release builds this way
make vm-openssl                      # AGENTICA_OPENSSL=vendored: only build/vm/<mode>/openssl/libssl.a and libcrypto.a; AGENTICA_OPENSSL=system: check pkg-config and the version (3.0 or newer)
make -s vm-openssl-key AGENTICA_OPENSSL=vendored   # the OpenSSL build key (Configure and make lines, compiler, version, commit); CI caches by its hash
make vm-third-party                  # only libgc (the vendored gc.o, or the system libgc check), yyjson, picohttpparser and libuv for this mode
make -s vm-third-party-key           # their build key (includes a libgc=system|vendored line; compile lines, compiler, submodule commits and local diffs)
make vm-test                         # C tests: every vm/tests/<name>_test.c in VM_TESTS
make stage1 stage2 stage3            # the front end (compiler/front_end.agc) in build/stage/: a first binary linked with bootstrap/stage0.agcb compiles stage1; stage1 compiles stage2; stage2 compiles stage3 (--front-end); stage2 == stage3
make fixed-point                     # the stages, dist/agentica (Linux: the VM, vm/agentica.c, stage2, the BDD runner and step program, and the std/ sources embedded by vm/tools/gen-embedded.sh), and dist/agentica compiling the front end gives stage2 again (about 25 s after the VM objects are built); CI runs it in `test` and in `vm-sanitizers`
make stage0                          # refresh bootstrap/stage0.agcb from stage2 (references/ci.md, "Refreshing stage0")
make vm-layers                       # the layer check ("Which layer"): each vm/*.h compiles alone, include and link rules, self-test; Linux, needs rg and nm
make CCACHE=                         # without ccache (used when installed and its cache dir is writable)
make SANITIZE=1 && make vm-test SANITIZE=1   # clang ASan+UBSan, no GC (calloc, never free)
make vm-test TRACE=0                 # trace points compiled out (still type-checked); `agentica run --version` says "trace off"
AGENTICA_VM_TRACE=all AGENTICA_VM_TRACE_FILE=./t.trace dist/agentica run -- prog.agcb   # sched,io,proc,tls,loader,gc
AGENTICA_VM_TRACE=profile dist/agentica check compiler/front_end.agc   # steps and calls per function and source file, time per builtin, at the end of the run (not part of `all`)
make vm-fuzz                         # compile fixtures, mutate, run accepted mutants
FUZZ_SEED=7 make vm-fuzz SANITIZE=1 FUZZ_RUNS=1000000   # another sequence; the fuzz.yml workflow (run by hand) picks a random seed
make vm-gc-stress                    # GC_STRESS=1 build (collect every 64 allocations), vm-test and the golden tests; JOBS=n sets the test workers
make vm-tsan                         # TSAN=1 build, no libgc: the threaded C tests (inbox, outcome, run queue, wake, job, sync, output, timers, threads) under TSan
make vm-tsan-run                     # a TSan agentica (front end of the release build) running tests/test_vm_multicore.py
make test-multicore                  # tests/test_vm_multicore.py: programs on 4 schedulers (AGENTICA_VM_TEST_MULTICORE=1)
make vm-latency                      # tests/test_vm_latency.py alone (see `vm-tasks.md`, Gotchas)
make vm-task-map                     # tests/test_vm_task_map.py alone (the timing cases of Task.map, see `vm-tasks.md`)
make goldens                         # rewrite tests/fixtures/vm/**/*.expected from the VM; review the diff
make goldens FIXTURES="name ..."     # only those fixtures (names without .agc, step-limited/ ones too); an unknown name exits 2
make vm-golden-check FIXTURES="name ..."  # the CI golden check (3 formats, sweep, sidecars, stack files) for only those fixtures
make vm-lint CLANG_TIDY=path        # clang-tidy 19+ over vm/*.c and vm/tests/*.c (release, sanitizer, GC stress); any warning fails
AGENTICA_REQUIRE_VM=1 make vm-diff-test JOBS=4
dist/agentica compile prog.agc -o prog.agcb && dist/agentica run -- prog.agcb
dist/agentica --dump-ir prog.agc
dist/agentica prog.agc               # front end + VM in one step, in one process
```

- CI runs `vm-sanitizers` (`make vm-lint`, `make vm-layers`, ASan diff and
  bytecode tests, `make vm-fuzz`,
  `make vm-gc-stress`) only when a pull request (never a `master` push) touches
the VM paths listed
  in the `changes` job of `.github/workflows/ci.yml`; the list and the other
  jobs are in `references/ci.md`. A new VM source or test file outside those
  paths must be added there.
- `agentica file.agc` runs in one process
  (`docs/vm/08-loader-and-cli.md` §9): the front end of the binary
  (`compiler/front_end.agc`) compiles in memory and hands the bytes to C with
  `FrontEnd.hand_off`; `vm/agentica.c` runs them in a new runtime. A
  `LOWER-UNSUPPORTED` is printed like any diagnostic, exit 1. Every catalog
  implementation is in `VM_BUILTINS` (`compiler/lower_tables.agc`), so no
builtin
  reaches it today.
  `agentica run [FLAGS] -- file.agcb [ARGS...]` runs a compiled file: C
  handles it when `run` is the first word, with the VM flags (`--max-steps`,
  `--seed`, `--flush-timeout`, `--schedulers`, `--allow-run`, `--ai`, `--json`,
  `--source-root`,
  `--version`) and the hidden `--driver-pid PID` and `--embedded NAME` (run
  the `runner` or `steps` program that the binary carries; the front end may
  not pass it on in a hand-off). The VM then deletes its
  input right after reading it (only a private file is read with that flag); on
  Linux it first resets `SIGTERM` to its default, sets `PR_SET_PDEATHSIG` to
  `SIGTERM` and exits 2 when `getppid()` is not `PID`. `agentica test` runs the
  BDD driver in the front end; it starts the runner with `self_path run
  --driver-pid ... --embedded runner` (see `references/bdd.md`). A new VM option
goes in
  `agc_launch_parse` and in the pass-through list of the front end
  (`compiler/cli_options.agc` and the hand-off check in
  `vm/agentica.c`). A new builtin goes into `VM_BUILTINS` with its C
  implementation. There is no `AGENTICA_VM`: no code reads it, and
  `AGENTICA_VM_BINARY` is a test knob only (the Python tests run that build of
  the binary: the GC stress, the vendored link, a sanitizer build).
  `tests/test_vm_diff_8.py` checks the CLI against the goldens (with `TMPDIR`
  set, checking no `.agcb` is left), that the removed `--vm` and `--legacy-eval`
  flags are unknown, that `compile` exits 1 on a diagnostic and 2 on an
  unwritable output, a standard input that cannot be read, and that
  `AGENTICA_VM` changes nothing. The same file checks `--driver-pid` on `run`
  alone.

- Each mode compiles `vm/*.c`, `vm/tests/*.c` and the drivers once into
  `$(VM_BUILD)/obj/` with `-MMD -MP` (dependency files beside the objects),
  and every binary links from them (`VM_LINK`); a new `vm/*.c` file goes
  in `VM_SRC` only. `$(VM_BUILD)/obj-flags` recompiles the mode when the
  compile line or the compiler's `--version` changes; `tls_openssl.o` also
  follows the OpenSSL stamp. Compiles run through `$(CCACHE)`, the vendored
  OpenSSL too, but not its key. It is found on `PATH` and used only when
  its cache dir (`ccache -k cache_dir`, or `$CCACHE_DIR`/`~/.ccache` for a
  ccache without `-k`) or its nearest existing parent is writable; the
  check creates nothing. `CCACHE=` turns it off (use it when a ccache
  setup fails). `CCACHE_BASEDIR` is the checkout, and the `-g` modes add
  `-fdebug-prefix-map=$(CURDIR)=.` (`DEBUG_MAP`) to the VM, third-party and
  vendored OpenSSL compiles but not to the stamps or the OpenSSL key, so
  worktrees share hits and debug info names `.`. From a checkout reached
  through a symlink, `$(PWD)` (the path gcc and ccache see) is mapped too.
  Third-party `-g` objects built earlier or restored from the CI cache
  keep their absolute paths until their key changes. A read-only ccache
  (`CCACHE_READONLY`, or a cache dir you cannot write) is turned off.
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
  OUT`), never in process. When behaviour
  changes on purpose, `make goldens` rewrites the expected files from the VM;
  commit them, and the PR diff shows the change for review.
- One fixture: `make vm-golden-check FIXTURES="list-sort-runs std-binary"`
  runs the shard code (`check_fixture`; `check_runaway` for `step-limited/`
  names) on just those fixtures, then the stack-trace cases of
  `tests/test_vm_stack.py` for the ones it covers, and exits non-zero with the
  shard failure text on a mismatch.
  `make goldens FIXTURES="list-sort-runs"` rewrites only their `.expected`
  and `.stack.*` files. Both pass the list (space or comma separated,
  names without `.agc`) in `AGENTICA_FIXTURES`; a name that matches no
  fixture exits 2, and `vm-golden-check` without `FIXTURES` exits 2. The
  same names work by hand: `AGENTICA_FIXTURES=name python3 -m
  tests.vm_diff_support check`. Sidecars next to `<name>.agc`, read by
  `Fixture.of` (the golden test and the `--max-steps` sweep feed `.stdin`
  and `.args` to the VM):
  - `.stdin`: raw bytes fed to the program's stdin (`.gitattributes` marks them
    binary so CRLF survives). The golden batch gives them as a file, the
    step-count search and the extras as a pipe.
  - `.args`: a list of double-quoted strings (the harness reads them with a
    small regular expression) passed as
    program arguments; `"@tmp"` becomes a fresh empty directory per run, and
    that path is turned back into `@tmp` in the output before the comparison;
    `"@fixtures/x"` the path `tests/fixtures/x`. File fixtures (`files-*`) use
    `@tmp` and long timeouts, and never touch paths outside it.
  - `.env`: a list of `("NAME" . "value")` string pairs in the same syntax
    added to the environment of every VM run of the fixture
    (`system-env.env`); a program reads only the names it lists and never prints
    the whole environment.
  - `.channel`: the golden run goes through `tests/fixtures/channel-run.py`
    (Python 3). The wrapper opens a socket pair, hands one end to
    the VM as fd 3 with `AGENTICA_CHANNEL=3`, sends the first line of the file
    and one more after each line the VM sends back, closes its sending side
    after the last, and writes everything to its stdout in the order the child
    produced it: the child's stdout as it is, each channel line as `channel> `
    and the line. Stdout is drained before each channel line is shown, which is
    why the order is fixed. The `test-*` fixtures use it; the plain golden reads
    of `agentica test` modes (`--agentica-test run`) need a `.channel` file, and
    a fixture without one is the no-channel case (`test-no-channel`).
  - `process-` name prefix: runs with `--allow-run`.
  - `HEAVY_FIXTURES` (in `tests/vm_diff_support.py`): fixtures pinned to a
    shard;
    the others rotate over shards 1 to 7 and shard 8 runs the extras.
  - `step-limited/<name>.agc`: runaway loops, golden taken at
    `--max-steps 500`, checked at 1 to 5, 50 and 500.
  - `<name>.stack.plain`, `.stack.ai`, `.stack.json`: expected stderr of the
    stack-trace fixtures in the three formats, kept by
    `tests/test_vm_stack.py` (`python3 -m tests.test_vm_stack` rewrites them).
- The `tests/test_vm_diff_*.py` shards need a built VM (`make test` builds it;
  `make vm-diff-test` does not): a local run skips them when it is missing,
  and CI fails (`AGENTICA_REQUIRE_VM=1`). `AGENTICA_FIXTURES` does not filter
  a shard run, only `make goldens` and `make vm-golden-check`.
  They run each fixture on the VM with `--json` and compare exit code,
  stdout, stderr without the final JSON diagnostic line, and the diagnostic
  code parsed from that line (`outcome`), with the fixture's golden
  (`read_expected`; JSON with `exit`, `code`, and `stdout`/`stderr` as lists
  of lines). One more VM run each in the plain and `--ai` formats must match
  exit code, stdout and program stderr, and name the same code
  (`check_text_format`; task crash blocks, with their stack lines, and the
  unobserved summary line are taken out of both sides first, and their codes
  must match; `skip_stack` knows the stack line shapes). Crash
  lines and crash texts carry the fixture's path, so `unfixture` replaces
  the `tests/fixtures/` directory with `@fixtures/` in stdout and stderr
  before any compare. The `--max-steps` sweep: each limit must give the
  golden outcome, or exit 1 with `RUNTIME-STEP-LIMIT` and stdout and stderr
  that are prefixes of the golden's; once a limit finishes, larger ones must
  too (`check_sweep`). Each golden records the fixture's step count T
  (`"steps"`, the smallest limit that finishes); the VM's own count, found
  by `total_steps`, may be lower but at most `T + max(10, T / 10)`
  (`check_steps`, which catches over-charging), and the last sweep limit,
  `max(2T + 100, T + 2 * 2000)` with the golden's T, must finish. With
  `AGENTICA_SWEEP=sampled` (the `test` and ASan jobs and `make vm-gc-stress`)
each
  fixture runs only 1, 2, T - 1, T, the last limit and 8 limits drawn one
  from each eighth of 3 to T - 2 (`sampled_limits`); local `make test`,
  the release and the weekly `sweep.yml` keep the full sweep. The draw comes
from `AGENTICA_SWEEP_SEED`, else the
  first 8 hex digits of `GITHUB_SHA` or `git rev-parse HEAD`, plus the
  fixture name, so it rotates with the commit and is fixed within a run.
  Each shard prints the seed, and a failed limit names it: rerun with that
  `AGENTICA_SWEEP=sampled AGENTICA_SWEEP_SEED=...`. A new
  fixture needs its golden: run `make goldens`, read the new `.expected` by
  hand, and commit it; a changed golden is a reviewed behaviour change.
  `make goldens` refuses a run that timed out, died by a signal (status
  129 to 159) or ends in `RUNTIME-INTERNAL`, and names `.expected` files
  with no `.agc` next to them. The runaway fixtures in `step-limited/`
  keep their golden at `--max-steps 500`, with no step count. Every program
  the tests run gets `LC_ALL=C.UTF-8` and `LANG=C.UTF-8` (`vm_environment` in
  `tests/agentica_test.py`), so OS error text is the untranslated
  C text. The VM runs have the scratch folder of the test as working
  directory. The sweep cannot see an ignored limit: add a runaway
  program to `tests/fixtures/vm/step-limited/` for each new loop or call
  construct (it prints nothing after the loop). Sweep and runaway
  VM runs time out after 60 seconds; after the first timeout (or exit 124 or
  137) the rest of the batch is skipped and recorded as 124. Output is decoded
  with one U+FFFD for each byte that is not part of a valid sequence
  (`decode`), which is how the goldens were written.
  The VM runs of one fixture go through `vm_batch`, which runs the VM once
  for each list of options. A new costly fixture may need an
  entry in `HEAVY_FIXTURES` in `tests/vm_diff_support.py`. A fixture whose
  name starts with `process-` runs with `--allow-run`
  (`Fixture.allow_run`); its children must be on every CI runner (`/bin/sh`,
  `cat`, `sleep`) and must end or be closed.
  Fixture stdin comes from a file; pipe stdin is covered by the extras of
  shard 8 and the CLI tests. `AGENTICA_VM_BINARY=path` makes the tests
  run another build of the binary (`make vm-gc-stress` uses it
  for `build/vm/gcstress/agentica`).
- `-Wall -Wextra -Werror` and the hardening flags apply to `vm/*.c` only;
  `gc.c` gets only `-O2 -fPIE -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION
  -DGC_THREADS -DGC_BUILTIN_ATOMIC -DPARALLEL_MARK -DTHREAD_LOCAL_ALLOC`
  (`build/vm/gc.o` rebuilds when its stamp
  `build/vm/gc-flags` changes). `yyjson.c` is built per mode into
`$(VM_BUILD)/yyjson.o`
  with `YY_CFLAGS` (the sanitizers in `SANITIZE=1`, no `-Werror`) and the
  `YY_DEFS` that turn off everything but the reader; `vm/*.c` see the same
  `YY_DEFS` and `-I vm/third_party/yyjson/src`, and only `vm/json.c`
  includes `yyjson.h`. libuv (a `UV_NAMES` list per system in the Makefile,
  from the lists of its `CMakeLists.txt`) builds per mode into
  `$(VM_BUILD)/uv/*.o` with `-std=gnu11`, its own `UV_DEFS` and the mode's
  `YY_CFLAGS`, then `$(VM_BUILD)/libuv.a`, linked with `-ldl -lrt` on Linux. The
  yyjson, picohttpparser and libuv objects follow only their own stamp,
  `$(VM_BUILD)/third-party-flags` (the output of `make -s
  vm-third-party-key`: the `YY_COMPILE`, `PICO_COMPILE` and `UV_COMPILE`
  lines, `UV_NAMES`, the compiler version, and each submodule's commit and
  local diff), not `build/vm/flags`, the Makefile or the source mtimes, so
  `TRACE` does not rebuild them and a CI cache hit stays valid. Compile them
  only through those variables, so a new flag changes the stamp;
  `vm/*.c` see `-I vm/third_party/libuv/include`, and only `vm/loop.c`,
  `vm/stream.c`, `vm/process.c`, `vm/tcp.c` and `vm/http_client.c` include
`uv.h`. Bumping libuv: check out the new tag inside
  `vm/third_party/libuv`, compare its Linux source list with `UV_NAMES`,
  `git add vm/third_party/libuv`, and rerun the sanitizer and diff tests.
- Platforms: the Makefile picks Linux, macOS (`uname -s` is `Darwin`) or
  Windows (`OS=Windows_NT`, MSYS2 UCRT64) in one block: Linux values by
  default, Windows overrides `EXE`, the PIE/RELRO flags, `-lpthread` and
  `-municode` and defaults `CC` to `gcc` (UCRT64 has no `cc`), and Darwin
  only drops `-pie` and RELRO. Every binary
  target ends in `$(EXE)` (`.exe` on Windows); the front end is embedded as
  ELF, Mach-O or COFF data. The `platforms.yml` workflow runs on every PR and
  on pushes to `master`: `make vm-test`, the bootstrap and a test subset on
  `windows-2025`, `macos-15-intel` and `macos-latest`. Platform code follows
  "Platform code" in `references/vm-c.md`.

## Files

- **Path:** `vm/third_party/bdwgc`
  - **Owns:** Boehm GC submodule, pinned to a release tag

- **Path:** `vm/third_party/libuv`
  - **Owns:** libuv submodule (MIT), pinned to tag v1.53.0; its Linux sources
    build into `$(VM_BUILD)/libuv.a`

- **Path:** `vm/third_party/openssl`
  - **Owns:** OpenSSL submodule (Apache-2.0), shallow, pinned to tag
    `openssl-3.5.9`; with `AGENTICA_OPENSSL=vendored` (the release) built static
    on Linux per build mode into `$(VM_BUILD)/openssl/` (`libssl.a`,
    `libcrypto.a`; `docs/vm/10-dependencies-and-platforms.md` §10.0); the
    default `AGENTICA_OPENSSL=system` links the system OpenSSL 3 instead

- **Path:** `vm/third_party/yyjson`
  - **Owns:** yyjson submodule (MIT), pinned to tag 0.13.0; only its reader is
    built, into `$(VM_BUILD)/yyjson.o`

- **Path:** `vm/third_party/picohttpparser`
  - **Owns:** picohttpparser submodule (MIT or Perl, dual; the MIT notice is at
    the top of `picohttpparser.h`), pinned to tag v1.4; `picohttpparser.c` is
    built like yyjson, into `$(VM_BUILD)/picohttpparser.o`, and only
    `vm/http_pico.c` includes its header

## Gotchas

- Checking out a branch without the submodule warns `unable to rmdir
  vm/third_party/bdwgc`; run `git submodule update --init` after switching
  back.
- Under ASan, Boehm is off (`-DAGC_NO_GC`); GC bugs need the GC-debug stress
  run (`make vm-gc-stress`), not ASan.
- Portability: keep driver platform code in `vm/launch.c` and the Makefile
  platform block; VM platform code follows "Platform code" in
  `references/vm-c.md`. `#ifdef SIGPIPE`, not `#ifdef _WIN32`,
  guards the signal. `_Exit` is C11; mingw-w64 still provides `write`,
  `open`, `read`, `fstat` and `ssize_t` with `-std=c11`, but its `struct
  stat` has a 32-bit `st_size`, so Windows uses `_fstat64`. A Windows port of
  the binary would open its input with `_wopen` on the original UTF-16
  argument, never through `open` (ANSI code page) or a UTF-8 round trip (a
  lone surrogate would become U+FFFD and name another file); the old
  `vm/main.c` did that, and `-municode` went only on binaries that linked it.
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
