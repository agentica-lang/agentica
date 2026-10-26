## 11. Build, CI and supply chain

### Build

- `make` compiles `vm/*.c` with `$(CC) -std=c11 -O2 -Wall -Wextra -Werror`
  and the hardening flags `-fstack-protector-strong -D_FORTIFY_SOURCE=2`, and
  links `dist/agentica` (the VM with the front end inside, the one product;
  §18.2). On Linux it links PIE with full RELRO. The binary builds on Linux,
  macOS and MinGW (`platforms.yml`; the front end is embedded as in 10). The
  Makefile picks the platform from `OS=Windows_NT` or `uname -s`. The warning
  flags apply to our own `vm/*.c` only.
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
- `AGENTICA_ZLIB` picks the zlib build the same way: `system` (the default on
  Linux) links the distro's zlib dynamically, through a `pkg-config zlib`
  stamp that stops with a fix when the package is missing or older than
  `ZLIB_MIN` (1.2.0, the series with gzip decoding in `inflateInit2`); the
  mode is not remembered, so pass `AGENTICA_ZLIB=vendored` to every make
  command to link the eight codec sources statically instead (the release
  and non-Linux hosts build this way). The flags stamp records the mode, so
  switching it relinks without stale objects.
- Both libgc builds have thread support: Debian's libgc is built with it, and
  the vendored `gc.o` has `GC_THREADS`, `PARALLEL_MARK` and
  `THREAD_LOCAL_ALLOC`. `vm/value.c` defines `GC_THREADS` before it includes
  `gc.h` (the only file that does), which gives it the registration calls.
  The collector starts its mark threads when `agc_gc_allow_threads` calls
  `GC_allow_register_threads`, and nothing calls it with one scheduler (N = 1),
  so the process has no mark thread.
  The libuv pool threads and the I/O work run on `malloc` memory and never call
  `GC_malloc` or hold a GC pointer (16.5), so they stay unregistered. A thread
  that touches GC memory calls `agc_gc_thread_enter` first and
  `agc_gc_thread_leave` before it ends. The one other difference is
  `ALL_INTERIOR_POINTERS`: `agc_init` calls `GC_set_all_interior_pointers(1)`
  before `GC_INIT`, so a libgc built without it behaves like the vendored one:
  both modes match.
- The Agentica version is the one line of the `VERSION` file, which the Makefile
  reads with `cat`. Each mode compiles `vm/*.c`
  once into `build/vm/<mode>/obj/` (with `-MMD -MP`, so an edited header
  recompiles only its users) and links the VM and the C tests from those
  objects. `build/vm/flags` holds the compile and link line, so
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
  the out-of-memory exit (6.3). `make vm-test SANITIZE=1` uses the same flags.
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
  with 64 bytes of overhead). The limit is soft: an allocation past it still
  succeeds and marks the run. The interpreter sees the mark at the next step
  taken after a charge or at a turn start (`set_counter`), and `step_slow`
  longjmps back to `agc_fuzz_one`, which frees the mutant and returns 2 (a
  mutant that counts as run). The jump then leaves no builtin's `malloc`'d
  memory behind, which the leak check would report. Past twice the limit an
  allocation jumps at once; a builtin that allocates without charging
  (`AGC_OP_LIST`, say) can still get there midway, a known hole. Under
  `AGC_NO_GC` yyjson allocates through `agc_alloc_atomic` (`vm/json.c`), so its
  documents count toward this limit too. The VM itself sets no limit.
  `agc_fuzz_one` is linked only into the fuzz and test binaries.
- In the libFuzzer build (`AGC_FUZZ`), `agc_out_of_memory` aborts instead of
  exiting with 70, libFuzzer's timeout code, so a size overflow or a failed
  `malloc` is a crash with a saved input.
- The fuzzer is libFuzzer (`vm/fuzz_libfuzzer.c`): `LLVMFuzzerTestOneInput`
  calls `agc_fuzz_one`, so AFL++, honggfuzz and Centipede can drive it too.
  `make vm-libfuzz` builds the VM objects in the `LIBFUZZ=1` mode (clang,
  `-fsanitize=fuzzer-no-link,address,undefined`, `AGC_NO_GC`) into
  `build/vm/libfuzz/` and links `agentica-vm-libfuzz` with libFuzzer's
  runtime. Linux and clang only; never shipped.
- `make vm-libfuzz-run` compiles every program in `tests/fixtures/vm/` into
  `build/vm/libfuzz/seeds/` and fuzzes for `LIBFUZZ_TIME` seconds (default 60)
  on `LIBFUZZ_JOBS` forked workers (default 1), each with `-rss_limit_mb=2048`
  (`LIBFUZZ_RSS_MB`). New inputs go to `build/vm/libfuzz/corpus/`, failures to
  `build/vm/libfuzz/crashes/`. `LIBFUZZ_FLAGS` adds libFuzzer flags, such as
  `-seed=N`.
- A crash, a leak or an input past the RSS limit fails the run. The run turns
  on the leak check (`ASAN_OPTIONS`) that `vm/value.c` turns off in the other
  ASan builds, since `agc_fuzz_one` frees every block of an input.
- A timeout (an input that runs past 10 s) fails the run too
  (`-ignore_timeouts=0`). Under `no_files` a run has no wall clock:
  `Task.sleep` only yields, and a channel, `Task.await` or `Task.map` timeout
  lasts 0 ms (`agc_timeout_length` in `vm/timers.c`). The task still parks,
  the other tasks run until the next turn boundary, and then it times out.
  A loop spends at least one step per wait (every backward jump lands on a
  `STEP`), so `--max-steps 10000` bounds a mutant that loops on timed waits.
- `agc_fuzz_one` sets `deny_run`, `deny_env` and `deny_net`. A mutant's
  strings are shell commands with mutated bytes, and a child process or a
  network wait is outside `--max-steps`. The environment and the network
  differ between machines, so an input that reads them would not reproduce
  elsewhere.
- There is no dictionary. The format has no section tags, and libFuzzer learns
  the magic, the format version and the builtin names from its `memcmp` and
  comparison hooks.
- The sanitizer job of each C PR runs it for 60 s on every core. Fork mode
  does not make a run repeatable from its seed: the saved file reproduces a
  failure. `.github/workflows/fuzz.yml` runs it by hand for the given number
  of seconds (default 3600, at most 6000) and prints the commit and seed
  first.
  Both upload `build/vm/libfuzz/crashes/` whenever it has files, including
  `timeout-*` files after a green run.
- To reproduce, run `ASAN_OPTIONS=detect_leaks=1
  build/vm/libfuzz/agentica-vm-libfuzz <file>` on the saved file
  (`detect_leaks=1` because `vm/value.c` turns the leak check off by default).

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
  - **Runs:** sanitizer build, `vm-test`, differential and bytecode tests, libFuzzer
    run, GC stress run

- **Job:** conformance matrix (`platforms.yml`), one per system:
  `linux-x86_64`, `windows-x86_64`, `macos-x86_64`, `macos-arm64`
  - **Runner:** GitHub-hosted `ubuntu-latest` (system libgc and OpenSSL),
    `windows-2025` (`msys2/setup-msys2` UCRT64: gcc, make), `macos-15-intel`
    and `macos-latest` (Apple clang); the last three link the vendored
    OpenSSL; submodules
  - **Runs:** `make vm-test`, the build from `bootstrap/stage0.agcb` and
    `make fixed-point`, then the areas of `tools/conformance.py` (command
    line, language rules, goldens, library, files, processes, tasks,
    network), and a report that fails when an area has no passed case or a
    case is skipped for a reason that is not on the reviewed list (the
    `WINDOWS_TEST_MODULES` of mk/windows.mk, for the local Wine check, is a
    separate list and is not derived from the areas)

- The Linux jobs run on every pull request that changes more than docs;
  `platforms.yml` runs on pull requests that carry the `platforms` label and
  on pushes to `master`, and either can be started by hand. No step checks or
  regenerates the frozen `vm/unicode_data.c` (its header gives the
  provenance). Every system runs the TCP, TLS and HTTP modules too.
- `.gitattributes` checks every text file out with LF. `.agcb` files are binary,
  and git detects the `string-inspect.agc` fixture as binary from its NUL bytes.
  So Windows sees the same sources, spans and output as Linux.
- Every CI job except the `test` job links the system OpenSSL, including the
  sanitizer and GC-stress builds. Pull request jobs also link the system libgc
  (`AGENTICA_GC=system`, the default) and the system zlib
  (`AGENTICA_ZLIB=system`, the default), and the apt fallback in each of them
  installs `libgc-dev` and `zlib1g-dev` next to `libssl-dev`. The jobs that run
  on `push` to `master` (`warm-third-party`), the weekly `sweep.yml` and the
  release use `AGENTICA_GC=vendored` and `AGENTICA_ZLIB=vendored`, so the
  vendored `gc.o` and the vendored zlib stay built and tested for the
  release and the GC-stress job (which always builds it, whatever the mode).
  `vendored-check` links with all three vendored libraries and fails when
  `readelf -d` shows `libgc` or `libz`. A cold sanitizer OpenSSL build took an hour on the
  shared runner host, so no job builds an instrumented OpenSSL. The
  `warm-third-party` job on `master` builds the vendored release-mode OpenSSL
  into a cache, keyed by `openssl-release-` and the hash of
  `make -s vm-openssl-key AGENTICA_OPENSSL=vendored`. The `test` job restores
  that cache (a pull request can restore only its own caches or `master`'s). On
  a hit it links `build/vm/release/agentica` against it, checks it with
  `readelf -d` and `run --version`, and runs the TLS and HTTP tests on it.
- The third-party objects (yyjson, picohttpparser, libuv, `build/vm/gc.o` and,
  in `AGENTICA_ZLIB=vendored` mode, the zlib objects) follow content stamps,
  `$(VM_BUILD)/third-party-flags` and `build/vm/gc-flags`, from
  `make -s vm-third-party-key`. The key starts with a `libgc=system` or
  `libgc=vendored` line and a `zlib=system` or `zlib=vendored` line, so the
  modes have different keys: in `system` each holds the library version and
  flags and not the submodule, and in `vendored` the compile line and the
  submodule. The stamps hold the compile
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
  or the Mach-O `minos` (the link target of the final binary: it does not prove
  that every object or API is safe on macOS 12, and CI does not run macOS 12),
  and the hardening of the format. On macOS the program
  is stripped and then signed ad hoc, which Apple silicon needs to start it;
  there is no Developer ID signature and no notarization. `make release-package`
  writes `agentica-VERSION-PLATFORM.(tar.gz|zip)` (`tools/release.py`; the
  same binary gives the same archive bytes, but the binary itself is not
  reproducible) and
  `make release-smoke` extracts it into a folder with spaces and non-ASCII
  letters outside the checkout, and runs it with a `PATH` of the system folders
  only: version, help, `check`, `compile`, `run`, `std/` imports, `agentica
  test` for unit tests and BDD, files, processes, loopback TCP and loopback
  HTTP (`std/http` client and server), on every platform.
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
  release fails if `readelf -d` shows `libssl`, `libcrypto`, `libgc` or `libz` (on
  the built binary and on the unpacked archive), and the archive ships
  `licenses/openssl/LICENSE.txt`.
