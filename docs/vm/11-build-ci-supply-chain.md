## 11. Build, CI and supply chain

The Makefile (`make help`), `mk/*.mk` and `.github/workflows/` are the source
for targets, flags and jobs; the development skill's `references/vm-build.md`
and `references/ci.md` say how to run them. This section keeps the decisions
behind them.

### Build

- `make` compiles `vm/*.c` with `-std=c11 -O2 -Wall -Wextra -Werror` and the
  hardening flags (PIE with full RELRO on Linux), and links `dist/agentica`.
  The warning flags apply to our own `vm/*.c` only. `build/vm/flags` holds the
  compile and link line, so switching between a normal and a sanitizer build
  relinks.
- `AGENTICA_GC`, `AGENTICA_OPENSSL` and `AGENTICA_ZLIB` pick `system` (the
  default on Linux: the distro's library, found with `pkg-config`, linked
  dynamically) or `vendored` (the default elsewhere and in the release: built
  from the submodule, linked statically). A stamp checks the system library
  first and stops with a message that names the fix when it is missing or older
  than `GC_MIN` or `ZLIB_MIN`; for libgc it also links a tiny program that
  calls `GC_register_my_thread`, so a libgc built without thread support stops
  the build. The mode of libgc and zlib is not remembered: pass the variable to
  every make command. `make vm-gc-stress` always uses the vendored GC (it needs
  `GC_DEBUG`), and `SANITIZE=1` links no libgc.
- The vendored libgc is built with `-DALL_INTERIOR_POINTERS
  -DNO_EXECUTE_PERMISSION -DGC_THREADS -DGC_BUILTIN_ATOMIC -DPARALLEL_MARK
  -DTHREAD_LOCAL_ALLOC`. `NO_EXECUTE_PERMISSION` keeps the heap without execute
  permission, since macOS on arm64 refuses writable and executable pages;
  `GC_BUILTIN_ATOMIC` avoids the `libatomic_ops` header.
- Both libgc builds have thread support. `vm/value.c` is the only file that
  defines `GC_THREADS` before `gc.h`. The collector starts its mark threads only
  when `agc_gc_allow_threads` runs, which nothing calls with one scheduler. The
  libuv pool threads and the I/O work never call `GC_malloc` or hold a GC
  pointer (16.5), so they stay unregistered; a thread that touches GC memory
  calls `agc_gc_thread_enter` and `agc_gc_thread_leave`. `agc_init` calls
  `GC_set_all_interior_pointers(1)` before `GC_INIT`, so both modes match.
- `make SANITIZE=1` builds with clang, ASan and UBSan. `agc_alloc` uses `calloc`
  and never frees, so ASan guards every object; libgc is not built
  (`-DAGC_NO_GC`); leak detection is off, and `allocator_may_return_null=1` lets
  a huge request reach the out-of-memory exit (6.3).
- `make vm-gc-stress` builds with `GC_STRESS=1`: `agc_alloc` calls
  `GC_gcollect()` every 64 allocations. Valgrind is not used: conservative
  scanning reports many false errors.

### Fuzzing

- `agc_fuzz_one` (`vm/fuzz.c`) loads one file and, if it is accepted, runs it
  with `--max-steps 10000`, printing any diagnostic to the stream it is given,
  so the diagnostic printer is fuzzed too. It sets `deny_run`, `deny_env` and
  `deny_net`: a mutant's strings are shell commands with mutated bytes, and a
  child process or a network wait is outside `--max-steps`. Under `no_files` a
  run has no wall clock: `Task.sleep` only yields and every timeout lasts 0 ms
  (`agc_timeout_length`), so the fuzzer does not explore the order of unequal
  deadlines.
- Steps bound instructions, not bytes. `agc_set_alloc_limit` gives each mutant
  256 MB; the limit is soft (an allocation past it succeeds and marks the run),
  the interpreter sees the mark at the next step after a charge or at a turn
  start, and `step_slow` longjmps back to `agc_fuzz_one`, which frees the mutant
  and returns 2. Past twice the limit an allocation jumps at once. A builtin
  that allocates without charging (`AGC_OP_LIST`, say) can still get there
  midway: a known hole. The VM itself sets no limit.
- The fuzzer is libFuzzer (`vm/fuzz_libfuzzer.c`), so AFL++, honggfuzz and
  Centipede can drive it too. In its build (`AGC_FUZZ`), `agc_out_of_memory`
  aborts instead of exiting with 70, libFuzzer's timeout code. Where the wrap is
  on (`AGC_FUZZ_JIT_WRAP`, Linux), each accepted input also runs under the JIT
  modes and fails when a JIT run's stdout, stderr, diagnostic or end differs
  from the interpreter's while a second interpreter run agrees with the first. A
  run whose program read a clock is not compared, and `agc_secure_random` is
  wrapped to a fixed stream, as the fixed seed does for `Random`.
- `make vm-libfuzz` (clang, Linux, never shipped) builds the VM in `LIBFUZZ=1`
  mode and `make vm-libfuzz-run` fuzzes the compiled `tests/fixtures/vm/` seeds
  (knobs in `mk/vm-test.mk`). A crash, a leak (the run turns the leak check on,
  since `agc_fuzz_one` frees every block of an input), an input past the RSS
  limit, a timeout, or a new `crash-`, `leak-`, `timeout-` or `oom-` file in
  `crashes/` fails the run. A timeout can also be a slow input to triage: steps
  do not bound CPU work (a linear builtin on a large string, once per step).
  There is no dictionary: libFuzzer learns the magic, the format version and the
  builtin names from its comparison hooks.
- The sanitizer job of each C PR runs it for 60 s on every core. Fork mode is
  not repeatable from its seed: the saved file reproduces a failure, with
  `ASAN_OPTIONS=detect_leaks=1 build/vm/libfuzz/agentica-vm-libfuzz <file>`.
  `.github/workflows/fuzz.yml` runs it by hand.

### Supply chain

- Runner images are pinned. The submodules are pinned to release tags and
  upgraded only by a reviewed PR that bumps the submodule.
- `agentica run --version` prints the versions of libgc, yyjson, libuv and
  OpenSSL. Rule: rebuild and release after any High or Critical advisory for a
  library the release links statically.
- The release links OpenSSL statically, so a fix reaches users only through a
  submodule bump and a new release. Only development and CI builds use the
  distro's OpenSSL.

### CI

The jobs, their triggers and caches are in the development skill's
`references/ci.md`. The decisions behind them:

- `.gitattributes` checks every text file out with LF (`.agcb` files are
  binary), so Windows sees the same sources, spans and output as Linux.
- CI links the system OpenSSL, the sanitizer and GC-stress builds included: a
  cold sanitizer OpenSSL build took an hour on the shared runner, so no job
  builds an instrumented OpenSSL. Jobs on `master`, the weekly sweep and the
  release use `vendored`, so the vendored libgc and zlib stay built and tested;
  `make vendored-check` (`mk/vm-test.mk`) checks that each is linked statically.
- The third-party objects follow content stamps (`make -s vm-third-party-key`).
  They rebuild only when the key changes, and CI does not cache them, since
  ccache rebuilds them in under a second.
- The release (`release.yml`) builds five packages, each on a runner of its own
  system, with every third-party library linked statically. The C library stays
  dynamic: glibc with at most 2.28 symbols (the pinned `zig cc`), libSystem with
  `MACOSX_DEPLOYMENT_TARGET=12.0` (a link target, not proof that every API is
  safe on macOS 12), and the Universal C Runtime of Windows 10. A static glibc
  breaks NSS, and macOS forbids a static libc. `make release-check`
  (`tools/release-check.sh`) fails on a wrong architecture, an imported library
  outside that list, a newer glibc symbol or missing hardening. On macOS the
  binary is signed ad hoc, which Apple silicon needs to start it; there is no
  Developer ID signature and no notarization. The same binary gives the same
  archive bytes, but the binary itself is not reproducible. A tag publishes
  only after all five builds pass; a manual run publishes nothing.
