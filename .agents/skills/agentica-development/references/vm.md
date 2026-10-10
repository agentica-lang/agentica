# Bytecode VM development (phase 7)

`docs/vm.md` is the contract: reference behavior, IR, bytecode format, value
layout, loader rules, libraries and the PR plan. Its "Status" note says which
subset runs today. This file is the working guide: where things live, how to
widen the VM, and the rules every change keeps. When this guide and
`docs/vm.md` disagree, `docs/vm.md` wins; when `docs/vm.md` and
`src/evaluator.rkt` disagree, the evaluator wins and the doc is fixed.

## Pipeline and files

```text
check #:types (src/checker.rkt)   eq? hash: expression node -> checked type
lower         (src/lower.rkt)     checked program -> IR, or LOWER-UNSUPPORTED / LOWER-INTERNAL
ir->bytecode  (src/bytecode.rkt)  IR -> bytecode; adjacent STEP merge; BYTECODE-LIMIT / -INTERNAL
write-bytecode                    the versioned .agcb file (magic, format version, Agentica version)
vm/main.c     dist/agentica-vm [--max-steps N] -- file.agcb [args...]
```

| Path | Owns |
|---|---|
| `vm/agc.h` | shared types, `agc_opcode` (same order as `opcodes` in `src/bytecode.rkt`) |
| `vm/loader.c` | full validation of untrusted `.agcb` input (`docs/vm.md` §8) |
| `vm/value.c` | allocation, checked accessors, UTF-8 checks, OOM/abort handlers |
| `vm/interp.c` | the loop: frames, registers, `STEP`, call depth, Int rules |
| `vm/builtins.c` | builtin table matched by implementation key and arity from the import table |
| `vm/diag.c` | the plain diagnostic format, byte-for-byte like `format-diagnostic` |
| `vm/fuzz.c`, `vm/fuzz_main.c` | `agc_fuzz_one` and the mutation driver (not in the release binary) |
| `vm/tests/loader_test.c` | one assert per loader rule |
| `vm/third_party/bdwgc` | Boehm GC submodule, pinned to a release tag |
| `tests/vm-diff-test.rkt`, `tests/fixtures/vm/` | differential tests against the evaluator |
| `tests/bytecode-test.rkt` | step merging, `LOWER-UNSUPPORTED`, opcode sync, `compile` exit codes |

## Commands

```sh
git submodule update --init          # fetch bdwgc after a clone or a bump
make vm                              # dist/agentica-vm (libgc from extra/gc.c, static)
make vm-test                         # C loader tests
make vm SANITIZE=1 && make vm-test SANITIZE=1   # clang ASan+UBSan, no GC (calloc, never free)
make vm-fuzz                         # compile fixtures, mutate, run accepted mutants
AGENTICA_REQUIRE_VM=1 raco test tests/vm-diff-test.rkt tests/bytecode-test.rkt
racket src/main.rkt compile prog.agc -o prog.agcb && dist/agentica-vm -- prog.agcb
racket src/main.rkt --dump-ir prog.agc
```

- `SANITIZE` may come from the environment; `build/vm/flags` relinks when the
  flags change. Run `make build` (raco make) before many `compile` calls, or
  each one recompiles `src/`.
- `tests/vm-diff-test.rkt` runs `make -s vm` first, prints `SKIP` locally
  when the VM cannot be built, and fails in CI (`AGENTICA_REQUIRE_VM=1`).
  `tests/bytecode-test.rkt` needs no VM binary.
- `-Wall -Wextra -Werror` and the hardening flags apply to `vm/*.c` only;
  `gc.c` gets only `-O2 -fPIE`.

## Widen the subset (new form or opcode)

1. Read the matching rules in `docs/vm.md` §2 (reference behavior) and §3.3
   (lowering). Probe the evaluator with small programs when a detail is not
   written down, and write the finding into §2.
2. `src/lower.rkt`: lower the form. Emit one IR `step` exactly where the
   evaluator calls `step!`, before the node's children. Anything still out of
   the subset keeps failing with `LOWER-UNSUPPORTED` at its span; never
   miscompile.
3. New opcode: append it to `opcodes` in `src/bytecode.rkt` and to
   `agc_opcode` in `vm/agc.h` at the same position (a test compares them).
   No opcodes for later PRs.
4. `vm/loader.c`: validate every operand (register ranges and windows,
   indexes, jump targets, spans). A new file section checks its counts
   against the bytes left and allocates through `load_alloc`, which charges
   the load memory budget. Add one assert per new rule to
   `vm/tests/loader_test.c`.
5. `vm/interp.c`: implement it with checked accessors only.
6. Add a fixture to `tests/fixtures/vm/` for each new runtime code or span;
   the diff test sweeps `--max-steps` over it.
7. Update the "Status" note and any rule that changed in `docs/vm.md`, tick
   the roadmap items, and keep this guide current.

## Add a C builtin

1. `src/lower.rkt`: let the call through the builtin check (today only the
   `puts` implementation is accepted; everything else is
   `LOWER-UNSUPPORTED`) and emit `call-builtin` with the catalog's
   implementation key and arity. The import table carries the
   implementation key, not the written name: `puts` and `IO.puts` both
   import `"puts"`.
2. `vm/builtins.c`: add the entry under that key and arity.
3. Add a fixture to `tests/fixtures/vm/` for the happy path and for each
   runtime code or span the builtin can raise; add a loader assert if the
   import rules change.

Rules for the C code:

- The catalog in `src/builtins.rkt` stays the source of keys and arity; the
  loader resolves each `(key, arity)` against the C table.
- Check argument tags generically from the table; check list and map
  elements when you touch them.
- Fail at the span the evaluator uses (call span, or `span + 1 + i` for
  argument `i`) with the evaluator's message text, copied verbatim.
- Every bounds check on an Int argument uses `__builtin_add_overflow` or
  `x < 0 || x > n - y`; never cast a negative `int64_t` to `size_t` first.
- Strings reach the OS or a library only through `agc_cstr` (copy, NUL
  terminate, fail on embedded NUL; add it with the first builtin that needs
  it). Every String constructor validates UTF-8
  or decodes with U+FFFD.
- No C recursion whose depth depends on a value (printing, `to_s`/`inspect`,
  JSON): use an explicit stack allocated with `agc_alloc`.
- Builtins never call the interpreter. Callback builtins are resumable
  native frames. A builtin must not keep `args` across anything that pushes a
  frame or grows registers.

## Rules every change keeps

**Parity.** Same stdout, stderr, exit code, diagnostic code and span as the
evaluator. Diagnostic messages are copied verbatim; `RUNTIME-INTERNAL` text is
not compared. Each deliberate difference goes into `docs/vm.md` as a
documented difference; `docs/vm.md` lists them (for example a failed stdout
write exits 1, control bytes from the file print as `?`, out of memory exits
70, and the 2^24 register cap gives `RUNTIME-STACK-OVERFLOW`).

**Trust model.** A `.agcb` is untrusted. Whatever it contains, the VM has no
memory errors or undefined behavior, runs children only with its own
`--allow-run`, and stops within `--max-steps`. The loader enforces the
termination rules: every backward jump lands on a `STEP`, every function that
calls starts with one, and a function without a leading `STEP` has at most 2
instructions. A file that loads may still compute wrong values or end with
`RUNTIME-INTERNAL`.

**C style.** C11. Exported names `agc_`, macros and enum constants `AGC_`,
file-local helpers `static`. Only `value.c` reads the value union. Size
arithmetic goes through `agc_size_add`/`agc_size_mul`; the loader's index
and size sums use `uint64_t`. Immediates write the full word. No comments unless
a line is unclear without one.

**Failure and exit.** Runtime failures call `agc_fail`, which `longjmp`s to
`agc_vm_run`; call it only from interpreter or builtin code on the VM's own C
stack. Only `vm/main.c` prints and exits. SIGPIPE is ignored and every write
is checked.

**Boehm GC.**
- Allocate only through `agc_alloc` (objects that hold `agc_value`s) and
  `agc_alloc_atomic` (strings, byte buffers; not zeroed under Boehm, so never
  expose an unfilled tail), or `load_alloc` in the loader. They switch to
  `calloc` under `AGC_NO_GC` and route out-of-memory to the handler. Only
  `value.c` calls `GC_*` or includes `gc.h`.
- Never keep a GC pointer in `malloc` memory, an atomic object or a
  `_Thread_local`; never tag pointers. Frames hold register offsets, not
  pointers, because the register array moves when it grows.
- No GC finalizers for OS resources. OOM and abort handlers only `write(2)`
  and `_exit(70)`.
- The submodule is pinned to a release tag. To bump it: check out the new
  tag inside `vm/third_party/bdwgc`, then `git add vm/third_party/bdwgc` (the
  index keeps the old commit otherwise), rebuild, and run the sanitizer and
  diff tests.

## Later phases (read `docs/vm.md` §10 before starting them)

- **libuv (7h)**: added then as a pinned submodule, built from source like
  bdwgc. One OS thread runs the interpreter and the loop; only the scheduler
  calls `uv_run`; libuv and OpenSSL callbacks only copy results and mark tasks
  ready. Handles and requests are `malloc`'d; the GC object that owns one
  stays in the run's resource registry until its `uv_close` callback, and
  `uv_write`/`uv_fs` buffers stay reachable until their callback. All handles
  and descriptors are non-inheritable.
- **OpenSSL 3 (7h)**: `OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG)`;
  system trust from the Windows ROOT store or the macOS Keychain (never
  `set_default_verify_paths` there); a non-empty `ca_file` replaces system
  trust; `SSL_set1_host` and SNI per connection; no `SSL_VERIFY_NONE` path.
- **Processes (7h)**: the VM resolves the executable itself; on Windows only
  `.exe`/`.com`, case-insensitive; never verbatim arguments; all three stdio
  piped.
- **Limits**: the 1 MiB per-call reads, HTTP framing limits and the other
  caps in the `docs/vm.md` limits table stay exactly as in the Racket
  sources.

## Gotchas

- Checking out a branch without the submodule warns `unable to rmdir
  vm/third_party/bdwgc`; run `git submodule update --init` after switching
  back.
- Step-limit sweeps on long programs are slow; the diff test samples above
  2000 steps.
- Under ASan, Boehm is off (`-DAGC_NO_GC`); GC bugs need the GC-debug stress
  run (planned for the strings PR), not ASan.
