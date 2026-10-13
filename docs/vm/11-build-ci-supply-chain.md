## 11. Build, CI and supply chain

- `make vm`: `$(CC) -std=c11 -O2 -Wall -Wextra -Werror`, hardening flags
  `-fstack-protector-strong -D_FORTIFY_SOURCE=2`, PIE and full RELRO on
  Linux; macOS links PIE by default and has no RELRO; MinGW uses
  `--dynamicbase --nxcompat --high-entropy-va` instead, links `vm/main.c`
  with `-municode`, and every binary gets the `.exe` suffix. The Makefile
  picks the platform from `OS=Windows_NT` or `uname -s`. The warning flags
  apply to our own `vm/*.c` only. libgc is compiled once from the submodule
  (`$(CC) -std=c11 -O2 -fPIE -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION
  -I vm/third_party/bdwgc/include -c vm/third_party/bdwgc/extra/gc.c`, about
  3 s) into `build/vm/gc.o` and linked with `-lpthread` (not on Windows).
  The two defines are what bdwgc's configure and CMake builds set.
  yyjson's `src/yyjson.c` is compiled per build mode into
  `$(VM_BUILD)/yyjson.o` with only its reader enabled (10).
  picohttpparser (7h) is compiled the same way into
  `$(VM_BUILD)/picohttpparser.o`, without `-msse4.2` (10, 10.6).
  `NO_EXECUTE_PERMISSION` maps the heap without execute permission: macOS on
  arm64 refuses writable and executable pages (`Cannot allocate executable
  pages` once the heap grows), and Linux no longer gets RWX heap pages.
  bdwgc always honors interior pointers from the stack and registers;
  `ALL_INTERIOR_POINTERS` extends that to pointers stored in GC objects and
  static data and to one-past-the-end pointers, at one extra byte per
  object. Nothing in the VM relies on it today; it is upstream's default and
  costs nothing measurable. libuv (7h) is built from its submodule into
  `$(VM_BUILD)/libuv.a` per build mode (10). OpenSSL is the system
  OpenSSL 3 by default (`pkg-config`, dynamic); with
  `AGENTICA_OPENSSL=vendored` (the release) OpenSSL 3.5 LTS (7h) is built
  from its submodule `vm/third_party/openssl` into
  `$(VM_BUILD)/openssl/libssl.a` and `libcrypto.a`, static, per build mode
  (10.0); that build needs Perl. `$(VM_BUILD)/openssl-flags` holds the key of
  that build (the Configure and sub-make command lines, the compiler
  version, `VERSION.dat` and the submodule commit; `make -s vm-openssl-key`
  prints it), so a `TRACE` or VM flag change never rebuilds OpenSSL, and a
  compiler, flag or version change always does. `make vm-openssl` builds
  only the two archives.
  The Agentica version is read from `src/version.rkt` with `sed`, so the VM
  build needs no Racket. Output `dist/agentica-vm`. Each mode compiles
  `vm/*.c` once into `build/vm/<mode>/obj/` (with `-MMD -MP`, so an edited
  header recompiles only its users; `build/vm/<mode>/obj-flags` holds the
  compile line and the compiler's `--version`) and links the VM, the fuzz
  driver and every C test from those objects. `build/vm/flags` holds the compile and link line, so
  switching between a normal and a sanitizer build always relinks. Every
  compile goes through ccache when it is on `PATH` and its cache directory
  is writable (`CCACHE=` turns it off), with `CCACHE_BASEDIR` set to the
  checkout. The `-g` modes pass `-fdebug-prefix-map=$(CURDIR)=.` to the VM,
  third-party and vendored OpenSSL compiles (and map `$(PWD)` too when the
  checkout is reached through a symlink), so debug info names `.` and
  worktrees at other paths share hits. The CI ccache
  volume is shared and PR jobs can write to it, so the release passes
  `CCACHE=` and never reads it.
- `make vm-test`: small C tests in `vm/tests/` with plain `assert`.
- `make vm SANITIZE=1`: clang with ASan and UBSan,
  `-fno-sanitize-recover=all`. In this build `agc_alloc` uses `calloc` and
  never frees, so ASan guards every object; libgc is not compiled or linked
  at all (`-DAGC_NO_GC`). Leak detection is off because nothing is freed, and
  `allocator_may_return_null=1` lets a huge request reach the out-of-memory
  path (6.3) instead of aborting.
  `make vm-test SANITIZE=1` and `make vm-fuzz SANITIZE=1` use the same flags.
- GC stress: `make vm-gc-stress` builds `build/vm/gcstress/agentica-vm`
  with `GC_STRESS=1` (`-DGC_DEBUG -DAGC_GC_STRESS`, gcc): `agc_alloc` and
  `agc_alloc_atomic` call `GC_gcollect()` every 64 allocations, and
  `GC_DEBUG` adds the debug headers whose smashed-object report on stderr
  would fail the comparison. It runs `make vm-test` with those flags and
  the `tests/vm-diff-*-test.rkt` shards on that binary (`AGENTICA_VM_BINARY` points the
  test at it; `dist/agentica-vm` is left alone). The Linux sanitizers job
  runs it. No Valgrind: conservative scanning makes it report many false
  errors.
- Fuzzing: `agc_fuzz_one(data, len)` (`vm/fuzz.c`) loads one file and, if
  accepted, runs it with `--max-steps 10000` and prints any diagnostic, all
  to `/dev/null`, so the diagnostic printer is fuzzed too. Under `AGC_NO_GC` it
  then frees every block of that mutant (`agc_release_all`, a no-op with libgc),
  so the fuzzer's peak memory is that of one mutant plus ASan's quarantine,
  which still catches a use after free across mutants. Steps bound
  instructions, not bytes, so a mutant can still grow a value to gigabytes;
  `agc_set_alloc_limit` gives each mutant 256 MB (each block counted with 64
  bytes of overhead), and an allocation past it longjmps back to
  `agc_fuzz_one`, which frees the mutant and returns 2 (a mutant that counts
  as run; a seed that fails). Blocks are tracked only while a limit is set,
  and yyjson allocates through `agc_alloc_atomic` in this build, so its
  documents count toward the limit and are freed with the mutant. The VM
  itself sets no limit. `agc_fuzz_one` is linked only
  into the fuzz and test binaries. The plain C driver (`vm/fuzz_main.c`,
  `make vm-fuzz`) applies 1 to 4 mutations per run (byte deletion and
  insertion, bit flips, random bytes, small or maximal 16-bit operands) to a
  corpus seeded with every
  compiled program in `tests/fixtures/vm/`; examples join the corpus as they
  enter the VM subset. The driver's random sequence is fixed, so every PR's
  short run (30,000 mutants in the sanitizer job, about 12 s) is
  reproducible; `FUZZ_SEED=N` picks another sequence and is printed on
  stderr. In a sanitizer build a crash prints the mutant's index and saves
  it to `fuzz-crash.agcb`. The fuzz workflow (`.github/workflows/fuzz.yml`,
  run by hand) builds the sanitizer VM, runs 5 million mutants with a
  random `FUZZ_SEED`, prints the commit and seed first, and uploads
  `fuzz-crash.agcb` as an artifact on failure; `agentica-vm --` on that
  file, or the same commit, seed and at least as many runs, reproduces it. A clang
  job also builds it with `-fsanitize=fuzzer` (later PR).
- `make test` includes the VM tests. They first run `make -s vm`, so a stale
  `dist/agentica-vm` is rebuilt from its sources. They skip visibly when the
  VM cannot be built locally (no C compiler, the submodule is not checked
  out, no system OpenSSL 3, or no Perl to build the vendored one) and fail in CI
  (`AGENTICA_REQUIRE_VM=1`), as `AGENTS.md` requires.
  `make vm` reads `SANITIZE` from the environment, so the sanitizer job sets
  `SANITIZE=1` once and the tests rebuild the sanitized VM.
- Supply chain: pinned runner images; libgc, yyjson, libuv and OpenSSL
  (and picohttpparser from 7h) are git submodules pinned to a release tag,
  upgraded only by bumping the submodule in a reviewed PR; CI checks out
  with `submodules: true`. `agentica-vm --version` and the release notes
  list the libgc, yyjson, libuv, picohttpparser and OpenSSL versions (for
  OpenSSL, the one that runs: the distro's in a system build); the release
  checklist says to
  rebuild and release after any High or Critical advisory for libgc,
  yyjson, libuv, picohttpparser or OpenSSL. The release links OpenSSL
  statically, so a fix reaches users only through a submodule bump and a
  new release; only development and CI builds use the distro's OpenSSL.

CI matrix:

| Job | Runner | Runs | Added in |
|---|---|---|---|
| Linux | self-hosted runner (`docker-runner`, Debian), submodules | `make vm vm-test`, `make test` (with the differential tests), smoke tests | first VM PR |
| Linux sanitizers | same, clang and `libclang-rt-dev` from the runner image | sanitizer build, `vm-test`, differential and bytecode tests, fuzz run, GC stress run | first VM PR (GC stress in PR 3) |
| macOS (by hand, `platforms.yml`) | `macos-15` (Apple clang, arm64), submodules | `make vm vm-test`, differential and bytecode tests | PR 4 |
| Windows (by hand, `platforms.yml`) | `windows-2025`, `msys2/setup-msys2` UCRT64 (gcc, make), submodules | `make vm vm-test`, differential and bytecode tests | PR 4 |
| Fuzz (by hand, `fuzz.yml`) | self-hosted runner, clang | sanitizer build, 5 million mutants, random `FUZZ_SEED` | after PR 5a |

The Linux jobs run on every pull request that changes more than docs. On
the self-hosted runner, Racket is installed once into the runner's tool cache
(`$RUNNER_TOOL_CACHE/racket-cs-9.3`, on its persistent work volume) and
later jobs only add it to `PATH`. The `vm/unicode_data.c` check is skipped
when a cache entry shows it passed for the same generator, table and
Makefile. The jobs
cache `src/compiled` and `tests/compiled` per job and touch every tracked file
after the restore, so `raco make` checks each source's SHA-1 and recompiles
only what changed. macOS and Windows minutes cost 10 and 2 times Linux minutes
on a private repository, so `platforms.yml` and `fuzz.yml` run by hand: run
`platforms.yml` before merging a change to platform code (`vm/main.c`, the
Makefile, files, processes, text output).

Racket comes from `Bogdanp/setup-racket` everywhere, since the tests compile
with the front end. The macOS and Windows jobs do not run the whole `make
test`: the process and network tests are not portable yet. `.gitattributes`
checks every text file out with LF (`.agcb` files are binary, and git
detects the `string-inspect.agc` fixture as binary from its NUL bytes), so Windows sees the same sources,
spans and output as Linux. 7h adds the libuv submodule to each job. Like
libuv, OpenSSL is built and linked only on Linux for now; other systems
get a stub adapter whose calls fail with "TLS needs Linux", and building
it there will need Perl (MSYS2's `perl` on Windows) when those ports
resume.

Every CI job, the sanitizer and GC-stress builds included, links the
system OpenSSL, so no job builds an instrumented OpenSSL (a cold sanitizer
OpenSSL build took an hour on the shared runner host). Only the release
links the vendored one. To keep that path tested, a `warm-third-party` job
on `master` pushes builds the vendored release-mode OpenSSL into a cache
(`build/vm/release/openssl/include`, `libssl.a`, `libcrypto.a` and the
`openssl-flags` stamp, keyed by `openssl-release-` and the hash of `make
-s vm-openssl-key AGENTICA_OPENSSL=vendored`) and links
`build/vm/release/agentica-vm` against it; the `test` job restores that
cache (a pull request can restore only its own caches or `master`'s) and,
on a hit, links the same binary, checks it with `readelf -d` and
`--version`, and runs the TLS and HTTP tests on it. A hit leaves the stamp
unchanged, so make does not rebuild.

The sanitizer and GC-stress builds of yyjson, picohttpparser and libuv
(and `build/vm/gc.o`) follow the content stamps
`$(VM_BUILD)/third-party-flags` and `build/vm/gc-flags`, the output of
`make -s vm-third-party-key` (compile lines, compiler and `ar` versions,
and each submodule's commit, diff and untracked files, or a checksum of
its files when it is not a git checkout), not source times. So
`vm-sanitizers` caches them as `third-party-<mode>-` keyed by the hash of
that output, and `warm-third-party` fills those caches on `master`.

The release workflow does not cache: it builds OpenSSL
with the pinned `zig cc` against glibc 2.28, the `objdump -T` floor check
covers OpenSSL's symbols too, it fails if `readelf -d` shows `libssl` or
`libcrypto`, and the archive ships `licenses/openssl/LICENSE.txt`.

