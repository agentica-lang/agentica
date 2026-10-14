# VM C rules: style, failure and exit, Boehm GC

Read before writing or reviewing C in `vm/`.

**C style.** C11. `make vm-lint` (clang-tidy, `.clang-tidy`) and
`tests/vm-style-test.rkt` check the rules marked *checked*.

- File order: includes, macros, every `struct`/`typedef`/`enum`/`union`
  definition, static data, functions. No type definition between functions
  (*checked*). Builtin tables that point to the file's functions come last.
- Exported names start with `agc_` (*checked* for functions); macros in
  the headers and enum constants start with `AGC_`; file-local macros are plain
  upper case.
- File-local helpers and data are `static` (*checked*).
- No mutable global or file-scope `static` variable in `vm/*.c` and
  `vm/*.h` (*checked* by
  `cppcoreguidelines-avoid-non-const-global-variables`; function-local
  `static` variables are not caught). State goes in `agc_vm`; constant data
  is `const`. The exceptions of `docs/vm/10-io-multicore.md` §10.2.3 take
  `// NOLINT(cppcoreguidelines-avoid-non-const-global-variables)`.
  `vm/tests/.clang-tidy` turns the check off for the C tests.
- No prototypes of `static` functions: define each helper before its first use, so files read bottom-up and the `agc_*` functions usually come last (*checked*); only unavoidable mutual recursion may have one.
- No value-driven C recursion (`docs/vm/05-values-execution-builtins.md` §7.3; *checked* by
  `misc-no-recursion` within one file only: recursion across files through
  `agc_*` calls is not caught). Depth bounded by a constant or `log n` (HAMT
  levels) is allowed with `// NOLINT(misc-no-recursion)` on the function line.
- Size arithmetic goes through `agc_size_add`/`agc_size_mul`; the loader's
  index and size sums use `uint64_t`.
- Every `vm/*.c`, `vm/*.h` and `vm/tests/*.c` file starts with a header
  comment, except the generated `vm/unicode_data.c`, and a new C file needs
  one too. A source file's header is 3 to 8 lines of text (the `/*` and `*/`
  lines do not count): what the file is, its main functions or builtin
  family, its layer, and where its design lives in `docs/vm/`, as
  `vm/main.c` does. A C test's header is 1 to 4 lines on what it tests. A
  legal header may come before it.
- Apart from the headers, the default is no comment. Add one only where the
  code's complexity justifies it, and make it say why, not what: an
  invariant, a subtle ownership or lifetime rule, a protocol, OpenSSL or libuv
  quirk, an order that is not obvious, or the spec section or RFC the code
  follows. Use short `/* */` block comments. Never narrate obvious code and
  never leave commented-out code. Tool markers (`// NOLINT(...)`,
  `/* fall through */`) are not comments in this sense.
- Only `value.c` reads the value union. Immediates write the full word.

`make vm-lint` (clang-tidy 19 or newer, for `misc-use-internal-linkage`)
skips only `vm/unicode_data.c` (generated). A hook name that a tool fixes
(`__asan_default_options`) takes an exact `NOLINT(check,...)`. The style test
is a line scanner with known limits: it misses prototypes of functions that
return function pointers or that start with a macro or attribute; it reports
static arrays whose size contains `(` (`x[sizeof(y)]`) as prototypes; it
miscounts when `#if` branches open or close different numbers of braces; and
a `\`+newline inside a literal shifts its line numbers. The `_WIN32` and
macOS branches are not linted while those platforms are paused.

**Failure and exit.** Runtime failures call `agc_fail`, which `longjmp`s to
`agc_vm_run`; call it only from interpreter or builtin code on the VM's own C
stack. `System.exit` calls `agc_exit`, which records `AGC_EXITED` and the
code and `longjmp`s the same way. Only `vm/main.c` prints and exits: it
flushes stdout and maps the code (1..255 as is, anything else 0, like
Racket's exit handler). SIGPIPE is ignored and every write is checked.

**Boehm GC.**
- Allocate only through `agc_alloc` (objects that hold `agc_value`s) and
  `agc_alloc_atomic` (strings, byte buffers; not zeroed under Boehm, so never
  expose an unfilled tail), or `load_alloc` in the loader. They switch to
  `calloc` under `AGC_NO_GC` and route out-of-memory to the handler. Only
  `value.c` calls `GC_*` or includes `gc.h`.
- Under `AGC_NO_GC`, `agc_fuzz_one` frees every block after each mutant
  (`agc_release_all`), so never cache an `agc_alloc` pointer in a static.
  It also sets a 256 MB budget (`agc_set_alloc_limit`, blocks tracked only
  while it is set); an allocation past it longjmps out of the mutant and
  `agc_fuzz_one` returns 2. yyjson allocates through `agc_alloc_atomic` under
  `AGC_NO_GC` for this reason; anything else outside the agc heap (a libuv
  loop) must be closed on that path too.
- Never keep a GC pointer in `malloc` memory, an atomic object or a
  `_Thread_local`; never tag pointers. Frames hold register offsets, not
  pointers, because the register array moves when it grows.
- No GC finalizers for OS resources. OOM and abort handlers only `write(2)`
  and `_Exit(70)`.
- The submodule is pinned to a release tag. To bump it: check out the new
  tag inside `vm/third_party/bdwgc`, then `git add vm/third_party/bdwgc` (the
  index keeps the old commit otherwise), rebuild with `AGENTICA_GC=vendored`,
  and run the sanitizer and diff tests.
- `AGENTICA_GC` picks the libgc (`docs/vm/11-build-ci-supply-chain.md`):
  `system` (the Linux default) links the distro's libgc with `pkg-config
  --cflags --libs bdw-gc`, after the stamp `$(VM_BUILD)/gc-system` (an
  order-only prerequisite of every VM object and a prerequisite of every
  binary) has checked pkg-config, the package and `GC_MIN` (8.2.0);
  `vendored` builds `build/vm/gc.o` from the submodule (non-Linux hosts, the
  release, and `GC_STRESS=1` always); `SANITIZE=1` has no libgc. The mode is
  not remembered: pass it to every make command or export it. Debian's libgc
  is threaded and `gc.o` is not; the VM never defines `GC_THREADS`, so the
  collector knows only the main thread and starts no marker threads. Keep
  pool threads off GC memory (they use `malloc` only); a thread that
  touches the heap needs `GC_THREADS` and `GC_register_my_thread` first.
  `agc_init` sets `GC_set_all_interior_pointers(1)` before `GC_INIT` so both
  builds agree.
