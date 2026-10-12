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
  `$(VM_BUILD)/libuv.a` per build mode (10). OpenSSL (7h) is linked
  dynamically by default: `OPENSSL=system` checks `pkg-config
  --atleast-version=3.0 libssl libcrypto` and links `-lssl -lcrypto`.
  `OPENSSL=static` requires `OPENSSL_PREFIX`, unsets `PKG_CONFIG_PATH`,
  sets `PKG_CONFIG_LIBDIR` to the prefix's `lib/pkgconfig`,
  `lib64/pkgconfig` and `lib/<multiarch>/pkgconfig`, fails if `pkg-config
  --exists libssl libcrypto` fails there or if `--variable=libdir` is
  outside the prefix, and links `libssl.a` and `libcrypto.a` from that
  `libdir` by full path, plus each other non-glibc library of libcrypto's
  `Libs.private` as its `.a` archive by full path (a missing one is a
  build error); only glibc's own flags stay (10.0). Both modes take `pkg-config --cflags` from the same
  environment and compile with `-DOPENSSL_API_COMPAT=30000`. The recipe
  for the `build/vm/flags` stamp runs `pkg-config` and writes the resolved
  flags; the link recipe reads them back; nothing runs `pkg-config` at
  Makefile parse time.
  The Agentica version is read from `src/version.rkt` with `sed`, so the VM
  build needs no Racket. Output `dist/agentica-vm`. The compiler flags,
  `OPENSSL`, `OPENSSL_PREFIX` and the resolved OpenSSL cflags and link
  flags are recorded in `build/vm/flags`, so switching between a normal and
  a sanitizer build, or between OpenSSL modes, always relinks.
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
  out, or no OpenSSL 3 development package or `pkg-config`) and fail in CI
  (`AGENTICA_REQUIRE_VM=1`), as `AGENTS.md` requires.
  `make vm` reads `SANITIZE` from the environment, so the sanitizer job sets
  `SANITIZE=1` once and the tests rebuild the sanitized VM.
- Supply chain: pinned runner images; libgc, yyjson (and libuv and
  picohttpparser from 7h) are git submodules pinned to a release tag,
  upgraded only by bumping the submodule in a reviewed PR; CI checks out
  with `submodules: true`. `agentica-vm --version` and the release notes
  list the libgc, yyjson, libuv, picohttpparser and OpenSSL versions (for
  OpenSSL, the one in use at run time); the release checklist says to
  rebuild and release after any High or Critical advisory for libgc,
  yyjson, libuv, picohttpparser or OpenSSL (or the other archives the
  static build links, such as zlib and zstd). For OpenSSL that means the release artifacts,
  which are built with `OPENSSL=static` (10.0); dynamic builds get OpenSSL
  fixes from the distro.

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
spans and output as Linux. 7h adds the libuv submodule and OpenSSL (`pkgconf` plus
the platform's OpenSSL 3 development package, `libssl-dev` on Debian) to each
job; these jobs use the default dynamic build. One Linux job (or the release
workflow) also installs the `-dev` packages of libcrypto's
`Libs.private` (on trixie `zlib1g-dev` and `libzstd-dev`), builds
`OPENSSL=static OPENSSL_PREFIX=/usr`, checks `readelf -d` against the
`NEEDED` allowlist of 10.0, and runs the TLS tests. The
`test` job, after `make vm`, fails if
`objdump -T dist/agentica-vm | rg -o 'OPENSSL_3\.[0-9.]+' | rg -v '^OPENSSL_3\.0\.0$'` prints
anything. On macOS (paused),
Homebrew's keg-only `openssl@3` needs `PKG_CONFIG_PATH` set to its
`lib/pkgconfig`.

