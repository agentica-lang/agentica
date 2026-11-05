# VM C rules: style, failure and exit, Boehm GC

Read before writing or reviewing C in `vm/`.

Read first: `references/vm.md` (the trust model and the layers).

**C style.** C11. `make vm-lint` (clang-tidy, `.clang-tidy`) and
`tests/test_vm_style.py` check the rules marked *checked*.

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
- No prototypes of `static` functions: define each helper before its first use,
  so files read bottom-up and the `agc_*` functions usually come last
  (*checked*); only unavoidable mutual recursion may have one.
- No value-driven C recursion (`docs/vm/05-values-execution-builtins.md` §7.3;
  *checked* by
  `misc-no-recursion` within one file only: recursion across files through
  `agc_*` calls is not caught). Depth bounded by a constant or `log n` (HAMT
  levels) is allowed with `// NOLINT(misc-no-recursion)` on the function line.
- Size arithmetic goes through `agc_size_add`/`agc_size_mul`; the loader's
  index and size sums use `uint64_t`.
- Every `vm/*.c`, `vm/*.h` and `vm/tests/*.c` file starts with a header comment,
  except the generated `vm/unicode_data.c`. A source file's header is 3 to 8
  lines of text: what the file is, its main functions or builtin family, its
  layer, and where its design lives in `docs/vm/`, as `vm/agentica.c` does. A C
  test's header is 1 to 4 lines on what it tests. A legal header may come before
  it. *Checked* by `tests/test_vm_style.py`.
- Comments are welcome where the C is complex or not obvious, and they say why,
  not what: an invariant, an ownership or lifetime rule, GC reachability (why a
  pointer is still alive after an allocation), an order that is not obvious, a
  protocol or an OpenSSL or libuv quirk, the RFC section the code follows, or
  the check that rejects hostile input (a length, offset or count from a `.agcb`
  or the wire). Use short `/* */` block comments. Never narrate obvious code and
  never leave commented-out code. Tool markers (`// NOLINT(...)`, `/* fall
  through */`) are not comments in this sense.
- Only `value.c` and the inline constructors and accessors of `value.h` read the
  value union (`docs/vm/05-values-execution-builtins.md` §5.2), besides the two
  inline word helpers (`agc_value_word`, `agc_word_value`) that list leaves use
  for the 8-byte payload of an Int or Float. Immediates write the full word. A
  new constructor or accessor for a hot type goes inline in `value.h`; one for a
  service resource stays in `value.c`.

`make vm-lint` (clang-tidy 19 or newer, for `misc-use-internal-linkage`) skips
only `vm/unicode_data.c`. A hook name that a tool fixes
(`__asan_default_options`) takes an exact `NOLINT(check,...)`. The style test is
a line scanner with known limits (read `tests/test_vm_style.py` before trusting
a pass or a false report on prototypes, `#if` branches or `\`+newline literals).
The `_WIN32` and macOS branches are not linted: CI runs `make vm-lint` on Linux
only.

**Platform code (Linux, macOS, Windows).** One behavior, one copy; only the
operating system call differs. The adapter shape (a plain header, one file per
system family, each guarded whole) and the list of older code to move behind
one are in `docs/vm/15-layers.md` §15.3.

- Use libuv's portable API first. Write an OS branch only where libuv has no
  call, or where its call breaks a rule of `docs/vm/14-core-invariants.md` (for
  example a write that runs on the loop thread).
- Shared files (validation, buffers, ownership, scheduling, Result and timeout)
  keep no `#ifdef` inside a function body. The adapter has no VM state,
  scheduling, timeouts or resource ownership, and its header comment names the
  real differences between systems. `file_io.h` with `file_windows.c` is the
  model; `__APPLE__` and `__linux__` only for a real API gap inside a POSIX
  file.
- Signal to split: a shared file whose `#if` count grows with a port, two copies
  of one function under `#ifdef`, or flags that only make sense on one system.
  Move the operation behind an adapter in the same PR, and add the new file to
  `VM_SRC` in `mk/vm.mk`, `vm/tools/check-layers.sh` and
  `references/repo-map.md`.
- Tests of the shared behavior go in an area of `tools/conformance.py` (the
  conformance matrix of `platforms.yml`; a test module in no area fails
  `tests/test_conformance.py`), so they run on every system, and on Windows also
  in `WINDOWS_TEST_MODULES` for the local Wine check. A test of one system's
  adapter skips elsewhere with `host_only(...)` and a reason that names the
  capability; any other skip fails the report.

**Failure and exit** (`docs/vm/05-values-execution-builtins.md` §6.2).
`agc_fail` `longjmp`s to `agc_vm_run`, so call it only from interpreter or
builtin code on the VM's own C stack. It keeps CODE and MESSAGE by pointer, so
pass a literal, static data or GC memory, never a stack buffer. `System.exit`
calls `agc_exit`, which records `AGC_EXITED` and the code and `longjmp`s the
same way. Only the driver (`vm/launch.c`, with `agentica.c`) prints and exits:
it flushes stdout and maps the code (1..255 as is, anything else 0). SIGPIPE is
ignored and every write is checked.

**Boehm GC** (`docs/vm/05-values-execution-builtins.md` §5.3).
- Allocate only through `agc_alloc` (objects that hold `agc_value`s) and
  `agc_alloc_atomic` (strings, byte buffers, the leaf blocks of Int and Float
  lists; not zeroed under Boehm, so never expose an unfilled tail), or
  `load_alloc` in the loader. They switch to `calloc` under `AGC_NO_GC` and
  route out-of-memory to the handler. Only `value.c` calls `GC_*` or includes
  `gc.h`.
- Under `AGC_NO_GC`, `agc_fuzz_one` frees every block after each mutant
  (`agc_release_all`), so never cache an `agc_alloc` pointer in a static. It
  also sets a 256 MB budget (`agc_set_alloc_limit`): an allocation past it
  longjmps out of the mutant and `agc_fuzz_one` returns 2. yyjson allocates
  through `agc_alloc_atomic` under `AGC_NO_GC` for this reason; anything else
  outside the agc heap (a libuv loop) must be closed on that path too.
- Never keep a GC pointer in `malloc` memory, an atomic object or a
  `_Thread_local`; never tag pointers. Frames hold register offsets, not
  pointers, because the register array moves when it grows. No GC finalizers
  for OS resources. OOM and abort handlers only `write(2)` and `_Exit(70)`.
- `AGENTICA_GC` picks the libgc (`docs/vm/11-build-ci-supply-chain.md`,
  `vm-build.md`). The mode is not remembered: pass it to every make command or
  export it. Both builds have thread support (`vm/value.c` defines `GC_THREADS`
  before `gc.h`). The collector starts no marker threads until
  `agc_gc_allow_threads`, which a run with N > 1 and the C tests call, so N=1
  has none. Keep pool threads off GC memory (they use `malloc` only); a thread
  that touches the heap calls `agc_gc_thread_enter` first and
  `agc_gc_thread_leave` before it ends. `agc_init` sets
  `GC_set_all_interior_pointers(1)` before `GC_INIT` so both builds agree.
