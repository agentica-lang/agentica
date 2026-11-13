# VM C rules: writing, style, failure, Boehm GC, a change step by step

Read before writing or reviewing C in `vm/`.

Read first: `references/vm.md` (the trust model and the layers).

## Writing rules

Each rule names one place in the VM that follows it.

- **Sizes and indexes.** Size sums and products go through `agc_size_add` and
  `agc_size_mul` (`vm/value.c`), which end the run with the out-of-memory
  exit on overflow; the loader's sums use `uint64_t`. An Int argument is
  checked for a negative value first, then compared as `uint64_t` with what is
  left (`builtin_slice`, `vm/bytes.c`); never cast a negative `int64_t` to
  `size_t`. Int arithmetic uses `__builtin_*_overflow` (`vm/interp.c`).
- **No undefined behavior.** Shift an unsigned value by a count checked below
  64 (`builtin_int_shift_left`, `vm/numbers.c`). Read a value's bytes as
  another type with `memcpy` (`agc_value_word`, `vm/value.h`), never a
  pointer cast or a union of another member. Zero a union with `memset`
  (`vm/ffi.c`): `{0}` sets only its first member (*checked* for the
  `typedef union` types of `vm/`).
- **Check bytecode once, in the loader.** Every register, index, count and jump
  target of a `.agcb` is checked in `vm/loader.c` (`check_register`,
  `vm/loader.c`), so the interpreter reads registers without a check
  (`vm/interp.c`). A new operand or section gets its loader check and a
  `vm/tests/loader_test.c` assert, not a test on the hot path. Values still go
  through the checked accessors (`agc_as_*`), which stop a wrong tag in
  `agc_wrong_tag`.
- **A failure the program can reach is a value or a diagnostic.** A bad
  argument, an OS error, a closed handle or a refused `--deny-*` is the
  builtin's error value (`agc_error`, `vm/tcp.c`) or its documented
  `RUNTIME-` code through `agc_fail`; never `abort`, `assert` or `exit`.
  `abort()` is only for a broken internal rule that the caller checked first
  (`agc_list_set`, `vm/list.c`). Out of memory and a thread that cannot
  start end with one line and status 70 (`agc_out_of_memory`,
  `agc_thread_start_failed`).
- **An error value has a kind.** `agc_error` takes an `agc_error_kind`
  (`vm/error_kinds.h`); a new kind goes in that enum, its name in
  `kind_names` (`vm/value.c`) and the table of
  `site/content/library/errors/error.md` (`tests/test_error_kinds.py`).
  An OS error goes through `agc_system_error` with its family, which picks the
  kind from the errno and keeps the errno as the code (`agc_errno_kind`,
  `vm/stream.c`).
- **No C recursion whose depth a value decides.** Printing, comparing, hashing
  and JSON walk nested values with an explicit stack in `agc_alloc` memory
  (`compound_debug`, `vm/text.c`;
  `docs/vm/05-values-execution-builtins.md` §7.3). Depth bounded by a constant
  or `log n` takes `// NOLINT(misc-no-recursion)` on the function line (`put`,
  `vm/map.c`). The lint sees recursion within one file only.
- **Hold no `malloc` memory across a raise.** `agc_fail` `longjmp`s past every
  `free`. Run each check that can raise before the first `malloc`, and while
  you hold one call only helpers that never raise (`guard_of`,
  `vm/process.c`; `agc_host_path_try`, not `agc_host_path`). A `malloc`'d
  request is freed on every way out: a raise, a cancelled task, a detached job
  and the end of the run; a libuv request also gets its `uv_*_req_cleanup`
  (`vm/file_io.c`). cchecker checks this from the marks (`CC_OWNS`,
  `CC_JUMPS`; "cchecker" in `references/ci.md`).
- **A libuv pool request outlives the wait.** Once a pool thread runs a
  `uv_getaddrinfo` request, `uv_cancel` gives `UV_EBUSY` and the thread still
  writes into it (`vm/dns.c`). So a deadline or a drop only marks the job
  (`dropped`), and the completion callback frees it; `vm/tcp.c` does the same
  with counts (`settle`, and `shared_done` with `refs`). Test a deadline while
  it runs with a slow shim (`tests/fixtures/dns_shim.c`).
- **The hot path allocates nothing it can avoid.** Scratch space starts in a
  C-stack array and moves to `agc_alloc` memory only when it grows
  (`agc_equal`, `vm/equal.c`). Flags read on the hot path are plain
  `bool`s, not bit-fields.
- **Process-wide setup runs before threads exist**, in `agc_launch_init`
  before `agc_init` starts the collector's threads, and its result is kept
  (`agc_jit_mem_sync_register`, `vm/launch.c`).

## C style

C11. `make vm-lint` (clang-tidy, `.clang-tidy`) and
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
- Every `vm/*.c`, `vm/*.h` and `vm/tests/*.c` file starts with a header comment,
  except the generated `vm/unicode_data.c`. A source file's header is 3 to 8
  lines of text: what the file is, its main functions or builtin family, its
  layer, and where its design lives in `docs/vm/`, as `vm/agentica.c` does. A C
  test's header is 1 to 4 lines on what it tests. A legal header may come before
  it. *Checked* by `tests/test_vm_style.py`.
- Comments say why where the C is not obvious: an invariant, an ownership or
  lifetime rule, GC reachability (why a pointer is still alive after an
  allocation), an order, a protocol or library quirk, the RFC section, or the
  check that rejects hostile input. Short `/* */` blocks; no narration, no
  commented-out code. Tool markers (`// NOLINT(...)`) are not comments.
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

## Platform code (Linux, macOS, Windows)

One behavior, one copy; only the
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
- Tests of the shared behavior run on every system (an area of
  `tools/conformance.py`; on Windows also `WINDOWS_TEST_MODULES` for the local
  Wine check); a test of one system's adapter is `host_only` elsewhere
  (`references/ci.md`, "Conformance matrix").

## Failure and exit

`docs/vm/05-values-execution-builtins.md` §6.2. `agc_fail` `longjmp`s to
`agc_vm_run`, so call it only from interpreter or builtin code on the VM's own
C stack. It keeps CODE and MESSAGE by pointer, so pass a literal, static data
or GC memory, never a stack buffer (`agc_fail_text` takes a String).
`System.exit` calls `agc_exit`, which records `AGC_EXITED` and the code and
`longjmp`s the same way. Only the driver (`vm/launch.c`, with `agentica.c`)
prints and exits: it flushes stdout and maps the code (1..255 as is, anything
else 0). SIGPIPE is ignored and every write is checked.

## Boehm GC

`docs/vm/05-values-execution-builtins.md` §5.3.

- Allocate only through `agc_alloc` (objects that hold `agc_value`s) and
  `agc_alloc_atomic` (strings, byte buffers, the leaf blocks of Int and Float
  lists; not zeroed under Boehm, so never expose an unfilled tail), or
  `load_alloc` in the loader. They switch to `calloc` under `AGC_NO_GC` and
  route out-of-memory to the handler. Only `value.c` calls `GC_*` or includes
  `gc.h`.
- Roots: an object stays alive only while a pointer to it (or into it) is on
  the stack or in the registers of a thread the collector knows, in static data
  or in another GC object. It never sees `malloc` memory, an atomic object, a
  `_Thread_local`, a libuv or OpenSSL struct, or a hidden pointer (tagged,
  XORed or kept as an integer). C that keeps an object only there keeps it
  reachable from the runtime as well (a task, a register, the registry of
  `agc_register`) for as long. No packed struct holds a pointer: the collector
  reads aligned words. Frames hold register offsets, not pointers, because the
  register array moves when it grows.
- Threads: both libgc modes have thread support (`vm/value.c` defines
  `GC_THREADS` before `gc.h`); `agc_init` sets
  `GC_set_all_interior_pointers(1)` before `GC_INIT` so they agree. The
  collector starts no marker threads until `agc_gc_allow_threads`, which a run
  with N > 1 and the C tests call. Pool threads stay off GC memory (`malloc`
  only); a thread that touches the heap calls `agc_gc_thread_enter` first and
  `agc_gc_thread_leave` before it ends.
- C that may switch stacks runs under `agc_gc_blocking` (`vm/value.c`,
  `GC_do_blocking`): the collector scans that thread's stack only down to the
  call, so the function touches no GC memory. It calls `GC_do_blocking` from a
  noinline frame that saves the callee-saved registers first
  (`references/vm-build.md`, Gotchas).
- No GC finalizer for an OS resource (a descriptor, a libuv handle, a process):
  `close` or the owner's end frees it (`references/vm-io.md`). The one
  finalizer, `TLS.Context`'s (`vm/value.c`), is registered with
  `GC_REGISTER_FINALIZER_NO_ORDER` (the macro that matches the GC-debug build)
  and runs between turns (`agc_gc_finalize_pending`), never inside an
  allocation. OOM and abort
  handlers only `write(2)` and `_Exit(70)`.
- `agc_weak` (`vm/value.c`) is the one weak reference: register it with
  `GC_GENERAL_REGISTER_DISAPPEARING_LINK` (the plain
  `GC_general_register_disappearing_link` clears a live object's link in the
  GC-debug build) and read it under `GC_call_with_alloc_lock`.
- Under `AGC_NO_GC`, `agc_fuzz_one` frees every block after each mutant
  (`agc_release_all`), so never cache an `agc_alloc` pointer in a static. It
  also sets a 256 MB budget (`agc_set_alloc_limit`): an allocation past it
  longjmps out of the mutant and `agc_fuzz_one` returns 2. yyjson allocates
  through `agc_alloc_atomic` under `AGC_NO_GC` for this reason; anything else
  outside the agc heap (a libuv loop) must be closed on that path too.

## A C change, step by step

Build only what the issue asks; a new kind or subsystem needs a program that
uses it (`docs/vm/14-core-invariants.md` §14.6).

**A new value kind** (as `AGC_T_TLS_CONTEXT` and `AGC_T_MUTEX` were added):

1. Front end: the type in `OPAQUE_TYPES` (or `RECORDS`, `ENUMS`) of
   `compiler/catalog/builtins_data.agc`, with its catalog golden; `vm_type?`
   (`compiler/lower/lower_state.agc`) accepts it.
2. `vm/value.h`: the tag at the end of `agc_tag`, and the struct with a comment
   on who owns what it points to. The constructor and the checked accessor go
   inline in `value.h` for a hot kind, in `value.c` for a service resource.
3. Each place that switches on tags (`rg -n AGC_T_MUTEX vm/` lists those of the
   last kind): the text form in `agc_scalar_text` (`vm/text.c`); equality in
   `vm/equal.c`, or none, which `equality?` (`check_types.agc`) then refuses;
   a map or set key in `agc_key_hash` only if the language allows it; for a
   kind a task owns, `handle_tag` (`vm/task.c`), `agc_owned_of` (`vm/loop.c`)
   and the checker's `holds_handle?`.
4. Its builtins (below), a C test of its invariants, and a golden of its text
   form and of each runtime code.

**A builtin in C**: `references/vm-builtins.md`. New rows go at the end of
their table (a C test may index a table by position); a row that may park also
goes in `agc_jit_parking` (`vm/jit/jit.c`, sorted).

**An opcode**: `references/vm-lowering.md` ("Widen the subset"), and the JIT
part of `references/vm-core.md` if the opcode gets compiled code.

**Before the PR** (the commands: `references/vm-build.md`):

- `make`, `make vm-test` (one test: `make build/vm/release/<name>-test`),
  `make vm-golden-check FIXTURES="..."` for the touched fixtures, `make
  vm-lint`, `make vm-layers` and `make dup-check`.
- `make cchecker` when ownership, locks or raises change (`references/ci.md`).
- Shared state: `make vm-tsan` and `make test-shared`
  (`references/vm-tasks.md`). The turn loop of `vm/interp.c`: `make
  layout-check`.
- The PR gets the `platforms` label (`references/ci.md`, "Conformance
  matrix") and a `vm-c-critic` review (`agentica-dev-workflow`).
