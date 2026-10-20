## 11. Build, CI and supply chain

### Build

- `make` compiles `vm/*.c` with `$(CC) -std=c11 -O2 -Wall -Wextra -Werror`
  and the hardening flags `-fstack-protector-strong -D_FORTIFY_SOURCE=2`, and
  links `dist/agentica` (the VM with the front end inside, the one product;
  §18.2). On Linux it links PIE with full RELRO. The binary embeds the front end
  as ELF, Mach-O or COFF data and builds on Linux, macOS and MinGW
  (`platforms.yml`). The Makefile
  picks the platform from `OS=Windows_NT` or `uname -s`. The warning flags apply
  to our own `vm/*.c` only.
- `AGENTICA_GC` picks the libgc build, like `AGENTICA_OPENSSL` picks OpenSSL.
  `system` (the default on Linux) links the distro's libgc dynamically with the
  flags of `pkg-config --cflags --libs bdw-gc`. The stamp
  `$(VM_BUILD)/gc-system` runs before any `vm/*.c` compile. It stops with a
  clear message when `pkg-config` or the package is missing, or when the version
  is older than `GC_MIN` (8.2.0, the series the VM is tested with; Debian 12 and
  13 and Ubuntu 24.04 and newer ship 8.2.x), and names the fixes (Debian:
  `apt install libgc-dev pkg-config`, or `AGENTICA_GC=vendored`). It also links
  a tiny program that calls `GC_register_my_thread`, so a libgc built without
  thread support stops the build with a hint to use `AGENTICA_GC=vendored`. The
  stamp holds the version and flags, so a new system libgc relinks, and the
  submodule is not compiled. `vendored` (the default off Linux, where there is
  no pkg-config module to count on) compiles libgc once from its submodule with
  `-DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION -DGC_THREADS
  -DGC_BUILTIN_ATOMIC -DPARALLEL_MARK -DTHREAD_LOCAL_ALLOC` into
  `build/vm/gc.o`, and links it with `-lpthread` (not on Windows). The first
  two defines are the ones bdwgc's own configure and CMake builds set; the
  rest build the collector with thread support (below), and
  `GC_BUILTIN_ATOMIC` makes it use the compiler's atomics, since the build
  has no `libatomic_ops` header. `NO_EXECUTE_PERMISSION` keeps the
  heap without execute permission, since macOS on arm64 refuses writable and
  executable pages. `make vm-gc-stress` always uses the vendored GC (it needs
  `GC_DEBUG`), and `SANITIZE=1` links no libgc. Pass `AGENTICA_GC=vendored` to
  every make command, or export it. `build/vm/flags` and `obj-flags` record the
  mode, so switching it recompiles and relinks.
- Both libgc builds have thread support: Debian's libgc is built with it, and
  the vendored `gc.o` has `GC_THREADS`, `PARALLEL_MARK` and
  `THREAD_LOCAL_ALLOC`. `vm/value.c` defines `GC_THREADS` before it includes
  `gc.h` (the only file that does), which gives it the registration calls.
  The collector starts its mark threads when `agc_gc_allow_threads` calls
  `GC_allow_register_threads`, and nothing calls it with one scheduler (N = 1),
  so the process has no mark thread (the same threads as before the change).
  The libuv pool threads and the I/O work run on `malloc` memory and never call
  `GC_malloc` or hold a GC pointer (16.5), so they stay unregistered. A thread
  that touches GC memory calls `agc_gc_thread_enter` first and
  `agc_gc_thread_leave` before it ends. The one other difference is
  `ALL_INTERIOR_POINTERS`: `agc_init` calls `GC_set_all_interior_pointers(1)`
  before `GC_INIT`, so a libgc built without it behaves like the vendored one:
  both modes match.
- yyjson's reader, picohttpparser and libuv are compiled per build mode (10).
  OpenSSL is the system one by default, or the vendored static build for the
  release (10.0).
- The Agentica version is the one line of the `VERSION` file, which the Makefile
  reads with `cat`, so the VM build needs no Racket. Each mode compiles `vm/*.c`
  once into `build/vm/<mode>/obj/` (with `-MMD -MP`, so an edited header
  recompiles only its users) and links the VM, the fuzz driver and the C tests
  from those objects. `build/vm/flags` holds the compile and link line, so
  switching between a normal and a sanitizer build relinks.
- Compiles go through ccache when it is on `PATH` and its cache directory is
  writable (`CCACHE=` turns it off). `CCACHE_BASEDIR` is the checkout, and the
  `-g` modes map the checkout to `.` in debug info, so worktrees share cache
  hits. The CI ccache volume is shared with PR jobs, so the release passes
  `CCACHE=` and never reads it.
- `make vm-test` builds the small C tests in `vm/tests/` with plain `assert`.
- `make SANITIZE=1` builds with clang, ASan and UBSan,
  `-fno-sanitize-recover=all`. In this build `agc_alloc` uses `calloc` and never
  frees, so ASan guards every object. libgc is not built (`-DAGC_NO_GC`). Leak
  detection is off, and `allocator_may_return_null=1` lets a huge request reach
  the out-of-memory exit (6.3). `make vm-test SANITIZE=1` and
  `make vm-fuzz SANITIZE=1` use the same flags.
- `make vm-gc-stress` builds `build/vm/gcstress/agentica` (the binary, linked
  with the stage2 of the release build; it does not run the fixed point) with
  `GC_STRESS=1` (`-DGC_DEBUG -DAGC_GC_STRESS`, gcc). `agc_alloc` and
  `agc_alloc_atomic` call `GC_gcollect()` every 64 allocations. It runs `make
  vm-test` and the differential shards on that binary (`AGENTICA_VM_BINARY`
  points the tests at it). Valgrind is not used: conservative scanning reports
  many false errors.
- `make vm-lint` runs clang-tidy over `vm/*.c` and `vm/tests/*.c` in the
  release, sanitizer and GC-stress configurations.

### Fuzzing

- `agc_fuzz_one(data, len)` (`vm/fuzz.c`) loads one file and, if it is accepted,
  runs it with `--max-steps 10000`, printing any diagnostic to `/dev/null`. So
  the diagnostic printer is fuzzed too. Under `AGC_NO_GC` it frees every block
  of that mutant afterwards, so the peak memory is that of one mutant plus
  ASan's quarantine.
- Steps bound instructions, not bytes, so a mutant can still grow a value to
  gigabytes. `agc_set_alloc_limit` gives each mutant 256 MB (each block counted
  with 64 bytes of overhead). An allocation past the limit longjmps back to
  `agc_fuzz_one`, which frees the mutant and returns 2 (a mutant that counts as
  run). Under `AGC_NO_GC` yyjson allocates through `agc_alloc_atomic`
  (`vm/json.c`), so its documents count toward this limit too. The VM itself
  sets no limit. `agc_fuzz_one` is linked only into the fuzz and test binaries.
- The plain driver (`vm/fuzz_main.c`, `make vm-fuzz`) applies 1 to 4 mutations
  per run (byte deletion and insertion, bit flips, random bytes, small or
  maximal 16-bit operands). The corpus is every compiled program in
  `tests/fixtures/vm/`, and examples join it as they enter the VM subset.
- The driver's random sequence is fixed, so the short run of each PR is
  reproducible: 30,000 mutants in the sanitizer job (`FUZZ_RUNS`), about 12 s.
  `FUZZ_SEED=N` picks another sequence and is printed on stderr. In a sanitizer
  build a crash prints the mutant's index and saves it to `fuzz-crash.agcb`.
- `.github/workflows/fuzz.yml` runs by hand. It builds the sanitizer VM, runs 5
  million mutants with a random `FUZZ_SEED`, prints the commit and seed first,
  and uploads `fuzz-crash.agcb` on failure. `agentica run --` on that file, or
  the same commit, seed and run count, reproduces a failure.
- Planned: a clang job that also builds the fuzzer with `-fsanitize=fuzzer`.

### Tests in make

- `make test` includes the VM tests. They run `make -s` first, so a stale
  `dist/agentica` is rebuilt. Locally they skip visibly when the VM cannot be
  built (no C compiler, submodule not checked out, no system OpenSSL 3 or libgc,
  or no Perl for the vendored build). In CI they fail instead, since
  `AGENTICA_REQUIRE_VM=1` is set, as `AGENTS.md` requires.
- `make` reads `SANITIZE` from the environment. The sanitizer job sets it
  once, and the tests rebuild the sanitized VM.

### Supply chain

- Runner images are pinned. The submodules (libgc, yyjson, libuv, picohttpparser
  and OpenSSL) are pinned to release tags and upgraded only by a reviewed PR
  that bumps the submodule. CI checks out with `submodules: true`.
- `agentica run --version` prints the versions of libgc, yyjson, libuv and
  OpenSSL. Rule: rebuild and release after any High or Critical advisory for
  libgc, yyjson, libuv, picohttpparser or OpenSSL.
- The release links OpenSSL statically, so a fix reaches users only through a
  submodule bump and a new release. Only development and CI builds use the
  distro's OpenSSL.

### CI

- **Job:** Linux (`ci.yml`)
  - **Runner:** GitHub-hosted `ubuntu-latest`, submodules
  - **Runs:** the binary from `bootstrap/stage0.agcb` and `make vm-test`, `make
    test` (with the differential tests), the fixed point, smoke tests

- **Job:** Linux sanitizers (`ci.yml`)
  - **Runner:** GitHub-hosted `ubuntu-latest`, clang and `libclang-rt-dev`
  - **Runs:** sanitizer build, `vm-test`, differential and bytecode tests, fuzz
    run, GC stress run

- **Job:** macOS (`platforms.yml`)
  - **Runner:** GitHub-hosted `macos-15-intel` and `macos-latest` (Apple
    clang, x86-64 and arm64), submodules
  - **Runs:** `make vm-test`, `make fixed-point` (the binary) and the test
    subset listed in `platforms.yml`

- **Job:** Windows (`platforms.yml`)
  - **Runner:** GitHub-hosted `windows-2025`, `msys2/setup-msys2` UCRT64 (gcc,
    make), submodules
  - **Runs:** `make vm-test`, `make fixed-point` (the binary) and the test
    subset listed in `platforms.yml` (the Makefile's `WINDOWS_TEST_MODULES`
    is the same list, for the local Wine check)

- **Job:** Fuzz (`fuzz.yml`, by hand)
  - **Runner:** GitHub-hosted `ubuntu-latest`, clang
  - **Runs:** sanitizer build, 5 million mutants, random `FUZZ_SEED`

- The Linux jobs run on every pull request that changes more than docs;
  `platforms.yml` runs on pull requests and pushes to `master`, and either can
  be started by hand. No job installs Racket (the Racket front end was deleted,
  PR #313), and no step checks or regenerates the frozen `vm/unicode_data.c`
  (its header gives the provenance). The macOS and Windows jobs run the test
  subset named in `platforms.yml`; the network tests are Linux only until
  the multiplatform port reaches TCP, TLS and HTTP.
- `.gitattributes` checks every text file out with LF. `.agcb` files are binary,
  and git detects the `string-inspect.agc` fixture as binary from its NUL bytes.
  So Windows sees the same sources, spans and output as Linux.
- Every CI job except the `test` job links the system OpenSSL, including the
  sanitizer and GC-stress builds. Pull request jobs also link the system libgc
  (`AGENTICA_GC=system`, the default), and the apt fallback in each of them
  installs `libgc-dev` next to `libssl-dev`. The jobs that run on `push` to
  `master` (`warm-third-party`), the weekly `sweep.yml` and the release use
  `AGENTICA_GC=vendored`, so the vendored `gc.o` stays built and tested for the
  release and the GC-stress job (which always builds it, whatever the mode).
  `vendored-check` links with both vendored libraries and fails when
  `readelf -d` shows `libgc`. A cold sanitizer OpenSSL build took an hour on the
  shared runner host, so no job builds an instrumented OpenSSL. The
  `warm-third-party` job on `master` builds the vendored release-mode OpenSSL
  into a cache, keyed by `openssl-release-` and the hash of
  `make -s vm-openssl-key AGENTICA_OPENSSL=vendored`. The `test` job restores
  that cache (a pull request can restore only its own caches or `master`'s). On
  a hit it links `build/vm/release/agentica` against it, checks it with
  `readelf -d` and `run --version`, and runs the TLS and HTTP tests on it.
- The third-party objects (yyjson, picohttpparser, libuv and `build/vm/gc.o`)
  follow content stamps, `$(VM_BUILD)/third-party-flags` and
  `build/vm/gc-flags`, from `make -s vm-third-party-key`. The key starts with a
  `libgc=system` or `libgc=vendored` line, so the two modes have different keys:
  in `system` it holds the libgc version and flags and not the submodule, and in
  `vendored` the compile line and the submodule. The stamps hold the compile
  lines, the compiler and `ar` versions, and each submodule's commit, diff and
  untracked files, or a checksum when it is not a git checkout. They rebuild
  only when the key changes, and CI does not cache them, since ccache rebuilds
  them in under a second.
- The release workflow (`release.yml`) builds four packages, each on a runner of
  its own system, with vendored OpenSSL and libgc: `linux-x86_64` on
  `ubuntu-latest` (the zig build below), `windows-x86_64` on `windows-2025`
  (MSYS2 UCRT64 GCC), `macos-x86_64` on `macos-15-intel` and `macos-arm64` on
  `macos-latest` (Apple clang, `MACOSX_DEPLOYMENT_TARGET=12.0`). After the
  build, `make release-check` (`tools/release-check.sh`) checks the binary in
  its own format: the architecture it holds, which is also the one of the
  machine that built it (a runner that is not what its name says fails), the
  libraries it imports (`otool -L`, `objdump -p`, `readelf -d`), the glibc floor
  or the Mach-O `minos`, and the hardening of the format. On macOS the program
  is stripped and then signed ad hoc, which Apple silicon needs to start it;
  there is no Developer ID signature and no notarization. `make release-package`
  writes `agentica-VERSION-PLATFORM.(tar.gz|zip)` (`tools/release.py`) and
  `make release-smoke` extracts it into a folder with spaces and non-ASCII
  letters outside the checkout, and runs it with a `PATH` of the system folders
  only: version, help, `check`, `compile`, `run`, `std/` imports, `agentica
  test` for unit tests and BDD, files, processes and, where the binary has the
  TCP builtins, loopback TCP and HTTP. A binary says that it lacks them with the
  loader error `unknown builtin`; on Linux and macOS that error fails the test.
  The `collect` job checks that exactly the four archives of `VERSION` exist
  and writes `SHA256SUMS`; the `publish` job runs only for a tag that is the
  `VERSION` file and only after all four builds pass. A manual run uploads the
  archives and the checksums as artifacts and publishes nothing.
- The Linux release caches only the zig toolchain (keyed by `ZIG_SHA256`), no
  build objects. It sets `AGENTICA_OPENSSL: vendored` and
  `AGENTICA_GC: vendored`, and builds both with the pinned `zig cc` against
  glibc 2.28. `ZIG_VERSION` and `ZIG_SHA256` in `.github/workflows/release.yml`
  pin the compiler, and the downloaded archive must pass `sha256sum -c` before
  it is used. The `objdump -T` floor check covers OpenSSL's symbols too. The
  release fails if `readelf -d` shows `libssl`, `libcrypto` or `libgc` (on the
  built binary and on the unpacked archive), and the archive ships
  `licenses/openssl/LICENSE.txt`.
