## 11. Build, CI and supply chain

### Build

- `make vm` compiles `vm/*.c` with `$(CC) -std=c11 -O2 -Wall -Wextra -Werror` and the hardening flags `-fstack-protector-strong -D_FORTIFY_SOURCE=2`. On Linux it links PIE with full RELRO. macOS links PIE and has no RELRO. MinGW uses `--dynamicbase --nxcompat --high-entropy-va`, links `vm/main.c` with `-municode`, and adds `.exe`. The Makefile picks the platform from `OS=Windows_NT` or `uname -s`. The warning flags apply to our own `vm/*.c` only.
- libgc is compiled once from its submodule with `-DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION` into `build/vm/gc.o`, and linked with `-lpthread` (not on Windows). Those two defines are the ones bdwgc's own configure and CMake builds set. `NO_EXECUTE_PERMISSION` keeps the heap without execute permission, since macOS on arm64 refuses writable and executable pages. Nothing in the VM relies on `ALL_INTERIOR_POINTERS` today.
- yyjson's reader, picohttpparser and libuv are compiled per build mode (10). OpenSSL is the system one by default, or the vendored static build for the release (10.0).
- The Agentica version is read from `src/version.rkt` with `sed`, so the VM build needs no Racket. Each mode compiles `vm/*.c` once into `build/vm/<mode>/obj/` (with `-MMD -MP`, so an edited header recompiles only its users) and links the VM, the fuzz driver and the C tests from those objects. `build/vm/flags` holds the compile and link line, so switching between a normal and a sanitizer build relinks.
- Compiles go through ccache when it is on `PATH` and its cache directory is writable (`CCACHE=` turns it off). `CCACHE_BASEDIR` is the checkout, and the `-g` modes map the checkout to `.` in debug info, so worktrees share cache hits. The CI ccache volume is shared with PR jobs, so the release passes `CCACHE=` and never reads it.
- `make vm-test` builds the small C tests in `vm/tests/` with plain `assert`.
- `make vm SANITIZE=1` builds with clang, ASan and UBSan, `-fno-sanitize-recover=all`. In this build `agc_alloc` uses `calloc` and never frees, so ASan guards every object. libgc is not built (`-DAGC_NO_GC`). Leak detection is off, and `allocator_may_return_null=1` lets a huge request reach the out-of-memory exit (6.3). `make vm-test SANITIZE=1` and `make vm-fuzz SANITIZE=1` use the same flags.
- `make vm-gc-stress` builds `build/vm/gcstress/agentica-vm` with `GC_STRESS=1` (`-DGC_DEBUG -DAGC_GC_STRESS`, gcc). `agc_alloc` and `agc_alloc_atomic` call `GC_gcollect()` every 64 allocations. It runs `make vm-test` and the differential shards on that binary (`AGENTICA_VM_BINARY` points the tests at it). Valgrind is not used: conservative scanning reports many false errors.
- `make vm-lint` runs clang-tidy over `vm/*.c` and `vm/tests/*.c` in the release, sanitizer and GC-stress configurations.

### Fuzzing

- `agc_fuzz_one(data, len)` (`vm/fuzz.c`) loads one file and, if it is accepted, runs it with `--max-steps 10000`, printing any diagnostic to `/dev/null`. So the diagnostic printer is fuzzed too. Under `AGC_NO_GC` it frees every block of that mutant afterwards, so the peak memory is that of one mutant plus ASan's quarantine.
- Steps bound instructions, not bytes, so a mutant can still grow a value to gigabytes. `agc_set_alloc_limit` gives each mutant 256 MB (each block counted with 64 bytes of overhead). An allocation past the limit longjmps back to `agc_fuzz_one`, which frees the mutant and returns 2 (a mutant that counts as run). Under `AGC_NO_GC` yyjson allocates through `agc_alloc_atomic` (`vm/json.c`), so its documents count toward this limit too. The VM itself sets no limit. `agc_fuzz_one` is linked only into the fuzz and test binaries.
- The plain driver (`vm/fuzz_main.c`, `make vm-fuzz`) applies 1 to 4 mutations per run (byte deletion and insertion, bit flips, random bytes, small or maximal 16-bit operands). The corpus is every compiled program in `tests/fixtures/vm/`, and examples join it as they enter the VM subset.
- The driver's random sequence is fixed, so the short run of each PR is reproducible: 30,000 mutants in the sanitizer job (`FUZZ_RUNS`), about 12 s. `FUZZ_SEED=N` picks another sequence and is printed on stderr. In a sanitizer build a crash prints the mutant's index and saves it to `fuzz-crash.agcb`.
- `.github/workflows/fuzz.yml` runs by hand. It builds the sanitizer VM, runs 5 million mutants with a random `FUZZ_SEED`, prints the commit and seed first, and uploads `fuzz-crash.agcb` on failure. `agentica-vm --` on that file, or the same commit, seed and run count, reproduces a failure.
- Planned: a clang job that also builds the fuzzer with `-fsanitize=fuzzer`.

### Tests in make

- `make test` includes the VM tests. They run `make -s vm` first, so a stale `dist/agentica-vm` is rebuilt. Locally they skip visibly when the VM cannot be built (no C compiler, submodule not checked out, no system OpenSSL 3, or no Perl for the vendored build). In CI they fail instead, since `AGENTICA_REQUIRE_VM=1` is set, as `AGENTS.md` requires.
- `make vm` reads `SANITIZE` from the environment. The sanitizer job sets it once, and the tests rebuild the sanitized VM.

### Supply chain

- Runner images are pinned. The submodules (libgc, yyjson, libuv, picohttpparser and OpenSSL) are pinned to release tags and upgraded only by a reviewed PR that bumps the submodule. CI checks out with `submodules: true`.
- `agentica-vm --version` prints the versions of libgc, yyjson, libuv and OpenSSL. The release checklist says to rebuild and release after any High or Critical advisory for libgc, yyjson, libuv, picohttpparser or OpenSSL.
- The release links OpenSSL statically, so a fix reaches users only through a submodule bump and a new release. Only development and CI builds use the distro's OpenSSL.

### CI

| Job | Runner | Runs |
|---|---|---|
| Linux (`ci.yml`) | self-hosted runner (`docker-runner`, Debian), submodules | `make vm vm-test`, `make test` (with the differential tests), smoke tests |
| Linux sanitizers (`ci.yml`) | the same runner, clang and `libclang-rt-dev` | sanitizer build, `vm-test`, differential and bytecode tests, fuzz run, GC stress run |
| macOS (`platforms.yml`, by hand) | `macos-15` (Apple clang, arm64), submodules | `make vm vm-test`, differential and bytecode tests |
| Windows (`platforms.yml`, by hand) | `windows-2025`, `msys2/setup-msys2` UCRT64 (gcc, make), submodules | `make vm vm-test`, differential and bytecode tests |
| Fuzz (`fuzz.yml`, by hand) | self-hosted runner, clang | sanitizer build, 5 million mutants, random `FUZZ_SEED` |

- The Linux jobs run on every pull request that changes more than docs. Racket is installed once into the runner's tool cache (`$RUNNER_TOOL_CACHE/racket-cs-9.3`) and later jobs only add it to `PATH`. The `vm/unicode_data.c` check is skipped when a cache entry shows that it passed for the same generator, table and Makefile. Jobs cache `src/compiled` and `tests/compiled`, and touch every tracked file after the restore, so `raco make` checks each source's SHA-1.
- macOS and Windows minutes cost 10 and 2 times Linux minutes on a private repository. So `platforms.yml` and `fuzz.yml` run by hand. Run `platforms.yml` before merging a change to platform code (`vm/main.c`, the Makefile, files, processes, text output).
- Racket comes from `Bogdanp/setup-racket` everywhere. The macOS and Windows jobs do not run the whole `make test`, since the process and network tests are not portable yet.
- `.gitattributes` checks every text file out with LF. `.agcb` files are binary, and git detects the `string-inspect.agc` fixture as binary from its NUL bytes. So Windows sees the same sources, spans and output as Linux.
- Every CI job except the `test` job links the system OpenSSL, including the sanitizer and GC-stress builds. A cold sanitizer OpenSSL build took an hour on the shared runner host, so no job builds an instrumented OpenSSL. The `warm-third-party` job on `master` builds the vendored release-mode OpenSSL into a cache, keyed by `openssl-release-` and the hash of `make -s vm-openssl-key AGENTICA_OPENSSL=vendored`. The `test` job restores that cache (a pull request can restore only its own caches or `master`'s). On a hit it links `build/vm/release/agentica-vm` against it, checks it with `readelf -d` and `--version`, and runs the TLS and HTTP tests on it.
- The third-party objects (yyjson, picohttpparser, libuv and `build/vm/gc.o`) follow content stamps, `$(VM_BUILD)/third-party-flags` and `build/vm/gc-flags`, from `make -s vm-third-party-key`. The stamps hold the compile lines, the compiler and `ar` versions, and each submodule's commit, diff and untracked files, or a checksum when it is not a git checkout. They rebuild only when the key changes, and CI does not cache them, since ccache rebuilds them in under a second.
- The release workflow does not cache. It builds OpenSSL with the pinned `zig cc` against glibc 2.28. `ZIG_VERSION` and `ZIG_SHA256` in `.github/workflows/release.yml` pin the compiler, and the downloaded archive must pass `sha256sum -c` before it is used. The `objdump -T` floor check covers OpenSSL's symbols too. The release fails if `readelf -d` shows `libssl` or `libcrypto`, and the archive ships `licenses/openssl/LICENSE.txt`.
