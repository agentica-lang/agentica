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
- Every `vm/*.c`, `vm/*.h` and `vm/tests/*.c` file starts with a header
  comment, except the generated `vm/unicode_data.c`, and a new C file needs
  one too. A source file's header is about 3 to 8 lines of text (the `/*` and
  `*/` lines do not count): what the file is, its main functions or builtin
  family, its layer, and where its design lives in `docs/vm/`, as
`vm/agentica.c`
  does. A C test's header is 1 to 4 lines on what it tests. A legal header may
  come before it. *Checked* by `tests/test_vm_style.py` (3 to 8 lines of text
  for a source file, 1 to 4 for a C test, the generated file skipped).
- Comments are welcome where the C is complex or not obvious, and they say
  why, not what: an invariant, a subtle ownership or lifetime rule, GC
  reachability (why a pointer is still alive after an allocation), an order
  that is not obvious, a protocol or an OpenSSL or libuv quirk, the RFC or spec
  section the code follows, or the check that rejects hostile input (a length,
  offset or count from a `.agcb` or the wire). Use short `/* */` block
  comments. Never narrate obvious code and never leave commented-out code. Tool
  markers (`// NOLINT(...)`, `/* fall through */`) are not comments in this
  sense.
- Only `value.c` and the inline constructors and accessors of `value.h`
  (`agc_int`, `agc_as_int`, ... for the common types, with `agc_wrong_tag` as
  their one out-of-line failure) read the value union, besides the two inline
  word helpers of `value.h` (`agc_value_word`, `agc_word_value`) that list
  leaves use for the 8-byte payload of an Int or Float. Immediates write the
  full word. A new constructor or accessor for a hot type goes inline in
  `value.h`; one for a service resource stays in `value.c`.

`make vm-lint` (clang-tidy 19 or newer, for `misc-use-internal-linkage`)
skips only `vm/unicode_data.c` (generated). A hook name that a tool fixes
(`__asan_default_options`) takes an exact `NOLINT(check,...)`. The style test
is a line scanner with known limits: it misses prototypes of functions that
return function pointers or that start with a macro or attribute; it reports
static arrays whose size contains `(` (`x[sizeof(y)]`) as prototypes; it
miscounts when `#if` branches open or close different numbers of braces; and
a `\`+newline inside a literal shifts its line numbers. The `_WIN32` and
macOS branches are not linted: CI runs `make vm-lint` on Linux only.

**Platform code (Linux, macOS, Windows).** One behavior, one copy; only the
operating system call differs.

- Use libuv's portable API first (`uv_fs_*`, `uv_pipe_t`, `uv_hrtime`,
  `uv_os_*`). Write an OS branch only where libuv has no call, or where its
  call breaks a rule of `docs/vm/14-core-invariants.md` (for example a write
  that runs on the loop thread).
- Shared files (validation, buffers, ownership, scheduling, Result and
  timeout) keep no `#ifdef` inside a function body. An OS difference is a
  function of a platform adapter, in the façade/adapter shape of
  `docs/vm/15-layers.md` §15.1 ("Files have a platform adapter") and §15.3:
  - one plain header (`file_io.h` is the model) with a few operations, opaque
    handles, no VM values, and one error convention (libuv codes or errno);
    its comment names the real differences between systems, if any; declarations
    that exist on one system only sit in one whole `#ifdef` block;
  - one file per system family (`<area>_posix.c`, `<area>_windows.c`), each
    guarded whole by `#ifdef _WIN32` or `#ifndef _WIN32`, like
    `file_windows.c`; `__APPLE__` and `__linux__` only for a real API gap
    inside the POSIX file;
  - no VM state, scheduling, timeouts or resource ownership in the adapter.
- Older code is debt: `file_io.c` (POSIX and Windows mixed; split it into
  `file_io_posix.c`) and the platform `#if` blocks in shared files such as
  `files.c`, `loop.c`, `launch.c`, `process.c`, `input.c` and `output.c`. A PR
  that adds a platform branch to one of them moves that operation behind an
  adapter instead; a PR that only touches nearby code need not.
- Signal to split: a shared file whose `#if` count grows with a port, two
  copies of one function under `#ifdef`, or flags that only make sense on one
  system. Move the operation behind the adapter header in the same PR, and
  add the new file to the Makefile, `vm/tools/check-layers.sh` and
  `references/repo-map.md`.
- Tests of the shared behavior go in the Platforms CI subset (add a new test
  file to the job lists of `platforms.yml`, and on Windows also to
  `WINDOWS_TEST_MODULES` for the local Wine check), so they
  run on every system; a test of one system's adapter says so in its name and
  runs only in that system's job (a skip fails the native Windows gate).

**Failure and exit.** Runtime failures call `agc_fail`, which `longjmp`s to
`agc_vm_run`; call it only from interpreter or builtin code on the VM's own C
stack. `System.exit` calls `agc_exit`, which records `AGC_EXITED` and the
code and `longjmp`s the same way. Only the driver (`vm/launch.c`, with
`agentica.c`) prints and exits: it
flushes stdout and maps the code (1..255 as is, anything else 0, like
Racket's exit handler). SIGPIPE is ignored and every write is checked.

**Boehm GC.**
- Allocate only through `agc_alloc` (objects that hold `agc_value`s) and
  `agc_alloc_atomic` (strings, byte buffers, the leaf blocks of Int and Float
  lists; not zeroed under Boehm, so never expose an unfilled tail), or
  `load_alloc` in the loader. They switch to
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
  not remembered: pass it to every make command or export it. Both builds
  have thread support (Debian's libgc, and `gc.o` with the defines above;
  `vm/value.c` defines `GC_THREADS` before `gc.h`). The collector starts no
  marker threads until `agc_gc_allow_threads`, which only the C tests call, so
  N=1 has none. Keep pool threads off GC memory (they use `malloc` only); a
  thread that touches the heap calls `agc_gc_thread_enter` first and
  `agc_gc_thread_leave` before it ends.
  `agc_init` sets `GC_set_all_interior_pointers(1)` before `GC_INIT` so both
  builds agree.
