## 5. Values in C

### 5.1 Representation

```c
typedef enum {
  AGC_T_VOID = 0, AGC_T_NIL, AGC_T_BOOL, AGC_T_INT, AGC_T_FLOAT,
  AGC_T_STRING, AGC_T_LIST, AGC_T_MAP, AGC_T_STRUCT, AGC_T_ENUM,
  AGC_T_RESULT, AGC_T_FN, AGC_T_RANGE, AGC_T_JSON, AGC_T_HANDLE
} agc_tag;                            /* the full set; vm/agc.h grows toward it */

typedef struct {
  uint32_t tag;
  union { bool b; int64_t i; double f; void *p; } as;   /* immediates write the full word: as.i = b */
} agc_value;                          /* 16 bytes, passed by value */
```

| Type | Representation |
|---|---|
| Void, Nil, Bool | Immediate. Tag 0 is Void, so zeroed registers are valid values. Today `vm/agc.h` has the tags above up to Fn, in that order, then `AGC_T_RANGE` (Phase 8a) and `AGC_T_JSON` (12.2 item 7); Handle joins with its PR. |
| Int, Float | `int64_t` (`__builtin_*_overflow`), `double`. |
| String | `{ size_t bytes, chars; char data[]; }`, `GC_MALLOC_ATOMIC`. `chars == bytes` means ASCII, O(1) indexing; otherwise indexing scans. Not NUL-terminated by contract. |
| List | `{ size_t len; agc_value items[]; }`, immutable. `append`, `set`, `concat` copy (same O(n) as now); indexing is O(1). |
| Map | `{ size_t size; agc_hamt *table; agc_keys *reversed; }` (`vm/map.c`): a persistent 32-way HAMT from key to value plus a persistent cons list of keys, newest first, exactly like `mapping`/`mapping-put` in `src/runtime-values.rkt`. A put copies only the path to its key (at most 14 nodes of at most 32 entries) and, for a new key, conses one cell onto the shared list; a replaced key keeps its cell, so its position. Put and lookup are O(log32 n) (12 levels of 5 hash bits and a 13th of 4 bits, then a collision node that holds the entries whose 64-bit hashes are equal and is searched linearly); building a literal of n entries is O(n log n), never O(n^2). Printing, `Map.keys` and `Map.values` walk the list once into an array, oldest first (`values` then looks each value up): O(n log n). Every node and cell is `GC_MALLOC`'d and immutable, so versions share structure. `Map.delete` (`agc_map_delete`) removes the key from the trie by copying its path (a child left with one leaf is pulled up into its parent, an empty node disappears, an empty map has no table) and copies the key list up to the key's cell, sharing the rest: O(n) like `remove` in the evaluator. A missing key returns the same map. Keys are Int (its 8 bytes, little-endian) or String (its UTF-8 bytes), compared by tag and value, which is `equal?` on them; they are hashed with SipHash-1-3, the value tag compressed as a leading 64-bit word before the bytes, so an Int and a String with the same bytes hash apart. The SipHash key is seeded once per run in `vm/main.c` from OS entropy, independent of `--seed`: on Linux `getrandom` (retried on `EINTR` and short reads), then `/dev/urandom` if `getrandom` fails (for example `ENOSYS` or `EPERM` under seccomp); `/dev/urandom` on other Unix systems and `rand_s` on Windows. If every source fails, the fixed default key stays. That is acceptable as a last resort: the hash is still 64 bits and a HAMT only degrades on full 64-bit collisions (a collision node is searched linearly), and forcing those still costs about 2^32 work per pair even with a known key. The C tests and the fuzzer keep the fixed default key. Iteration and printing order never depend on the hash. Later, if profiling asks for it: `MAP` can build its fresh literal with a transient in-place put instead of a persistent copy per pair, and a node can split child and leaf slots to use less memory. |
| Struct | `{ uint32_t type, n; agc_value fields[]; }`, declaration order. Text: the struct's display name, then `(f: v, ...)` from the table's field names. |
| Enum | `{ uint32_t variant, n; agc_value payload[]; }`; nullary variants are shared (one object per variant, made at load time). Text: enum display name, `.`, variant name, then `(a, b)` when `n > 0`. |
| Result | `{ bool ok; agc_value value; }` (`GC_MALLOC`); an error holds its String message; `ok()` holds Void. Debug form: `ok(v)`, `ok()` when the value is Void, `error("msg")` with the message in `write` form, printed by the same explicit-stack walker as lists, structs and enums. |
| Range | `agc_range { int64_t start, end; bool exclusive; }` (`GC_MALLOC_ATOMIC`), tag `AGC_T_RANGE`, immutable. Text and debug form `1..5` or `1...5` (`agc_scalar_text`; the longest form is 43 bytes, so `AGC_SCALAR_TEXT` is 48). `agc_range_bounds` gives the first and last included values and whether the range is non-empty, with no overflow for `...` (the end is above the start). `Range.size` fails with `RUNTIME-INTEGER-OVERFLOW` and `Range.to_a` above 1048576 values with `RUNTIME-INVALID-COUNT`, both at the receiver's span (`span + 1`), as the evaluator does; `first` and `last` of an empty range give `error("the range is empty")`. |
| Function value | `agc_fn { uint32_t function, n; agc_value captured[]; }` (`GC_MALLOC`), tag `AGC_T_FN`. `&name` is a value with `n = 0`. Text and debug form `<Fn>` (the checker never lets a program print one). |
| Json | `agc_json { kind; agc_value scalar; size_t count; agc_json_member *members; }` (`GC_MALLOC`), tag `AGC_T_JSON`: null, bool, int64, big integer (a String with its decimal text; parsed integers may exceed Int until extracted), double, string, array (`scalar` is a List of Json values, which `JSON.list` returns without a copy), object (`members`, `{ agc_string *key; agc_value value; }` sorted by key bytes). Objects are built by collecting pairs, then one stable sort and dedupe with the last value winning, which is the order `write-json` prints; `JSON.get` is a binary search. Text form: the JSON text; debug form `<Json>`. |
| Handle (7h) | `{ uint32_t kind; void *resource; }` for Task, Socket, Listener, HTTP values, FileHandle, Process. As built, each kind has its own tag and GC record: `Socket` is `agc_socket` and `Listener` is `agc_listener` (10.3.1). |

### 5.2 Safety rules for values

- `value.c` is the only code that reads a union member. Everything else uses
  checked accessors that take the VM, such as `agc_as_string(vm, v)` and
  `agc_as_list(vm, v)`; a wrong tag is `RUNTIME-INTERNAL`, always at the
  program span (2.5), so the accessors need no span.
- `CALL_BUILTIN` checks each argument's tag against the parameter tags in the
  C builtin table before the call (generic parameters accept any tag).
  Builtins check list and map elements when they touch them
  (`agc_expect`).
- `FIELD` and `PAYLOAD` check the index against the value's own `n`, not
  only against the struct and enum tables.
- Builtins that read builtin records (`Header`, `Request`, `Response`,
  `HttpClientOptions`, `HttpServerOptions`, `FileInfo`) check the struct type
  id; the loader accepts those names only with the exact field names and
  count of the C layout.
- Every String constructor either validates UTF-8 (no overlongs, no
  surrogates, at most U+10FFFF) or decodes with U+FFFD: argv, `Dir.list`,
  stdin, process and socket text, JSON `\u` escapes. Character counts are
  always computed, never read from a file.
- All size arithmetic goes through checked helpers (`agc_size_add`,
  `agc_size_mul`); a size overflow is an out-of-memory failure (6.3).

### 5.3 Boehm rules

- Objects holding `agc_value`s use `GC_MALLOC`; strings and byte buffers use
  `GC_MALLOC_ATOMIC`, which is not zeroed, so no code ever exposes an
  unfilled tail.
- Never store a GC pointer in `malloc` memory, in an atomic object, or in a
  `_Thread_local`: Boehm does not scan them. Pointers are never tagged. The
  one exception is `handle->data` and `SSL_set_app_data` in 7h, which may
  point to a GC object only while the resource registry also roots it (10.2).
- No GC finalizers for OS resources; closing is explicit (10.2).
- Roots (runtime, schedulers, program, tasks) live in GC objects reachable
  from the runtime struct, never in mutable static storage (10.2.3).

## 6. Execution

### 6.1 Stack, call depth and steps

- Each task (one before 7h) owns a register array and a frame array, both
  `GC_MALLOC` (native frames point to their state) and grown by doubling. A
  call grows the registers to fit the callee's declared count; new registers
  are zeroed. Frames hold base offsets, never raw pointers:
  `{ uint32_t function, pc, base, ret; agc_native *native; }`; a native
  frame (4.3) has `native` set. `RETURN` writes `ret`: the callee's base
  for `CALL` (the caller's `R[a]`), one register below the window for
  `CALL_VALUE` and callbacks. `frame_count` counts all frames, `depth`
  only the bytecode ones. A native frame keeps function index 0 as a
  placeholder, so code that walks frames must check `native` first.
- The interpreter is one `switch` loop. Agentica calls push frames and never
  recurse on the C stack, so a 7h task switch only changes the current task.
- Before `CALL`, `CALL_VALUE` or a callback push, `depth >= 10000` fails with
  `RUNTIME-STACK-OVERFLOW` ("call depth limit exceeded") at that
  instruction's span, like `call-function` and `call-closure`. `main` runs at
  depth 1; native frames do not count; each task starts at 0. `TAIL_CALL`
  replaces the current frame (4.3), so it neither checks nor changes the
  depth. The register
  array is capped at 2^24 per task; passing the cap fails the same way. A
  valid program reaches it only with more than about 1,600 registers per
  frame at full depth, so this is a documented difference, not a hole.
- Documented difference: the evaluator has no tail calls, so a deep
  tail-recursive program (a loop of a million `return f(n - 1)`, or two
  functions that tail-call each other) fails there with
  `RUNTIME-STACK-OVERFLOW` and runs on the VM. The VM's depth is never above
  the evaluator's, so a program that stays within the limit on the evaluator
  stays within it on the VM, with the same output; a
  runtime diagnostic carries one span and no stack trace, so the replaced
  frames are not visible (stack traces are planned after 7i, `docs/future/24-logging.md`
  §24.3, with a mark where a tail call removed frames). Non-tail recursion keeps the limit and its span.
  The evaluator is not changed: it goes away in 7i.
- `steps_left` is an atomic `int64_t` in the runtime: the limit, or
  `INT64_MAX` without one. All tasks share it; a turn takes it in batches
  (10.2.1, "As built"). `STEP` is one compare and one subtraction on a "next stop"
  counter; before 7h it is just `steps_left`, and from 7h it also covers the
  turn budget (10.2.1). Long builtins and opcodes charge their work to the
  turn only, never to `steps_left` (10.2.1, Builtins). With N schedulers,
  `steps_left` is one atomic counter that each scheduler takes from in
  batches (10.2.1, Quotas).

### 6.2 Failure, exit and cleanup

A runtime diagnostic always ends the run. `agc_fail(vm, code, message,
span)` records it and `longjmp`s to the `setjmp` in `agc_vm_run`, which runs
cleanup and returns an outcome (done, exit code, or diagnostic) to
`vm/main.c`. Only `main.c` prints and exits. `System.exit` takes the same
path.

Rules for `longjmp`: `agc_fail` is called only from interpreter and builtin
code running on the VM's own C stack, never from a libuv or OpenSSL
callback. Non-GC resources are registered before any call that can fail.
Locals live across `setjmp` are `volatile`.

Cleanup (kill and reap children, flush and close files, close sockets) runs
when the run ends normally, on `System.exit`, on diagnostics and on the step
limit (`agc_io_close`). While a child runs, `SIGINT`, `SIGTERM` and `SIGHUP`
kill and reap the children before the VM ends by that signal (through
`uv_signal_t`, 10.4); files are not flushed then. The out-of-memory and GC
abort exits (6.3) and `SIGKILL` run no cleanup and leave children running.
Windows is not built yet: there the plan is console control events and a
kill-on-close job object for the VM and its children, which would also
cover crashes.

### 6.3 Out of memory and GC aborts

At startup the VM sets `GC_set_oom_fn` and `GC_set_abort_func`. Their
handlers allocate nothing, `write(2, ...)` the fixed
line `agentica-vm: out of memory` (the abort handler: `agentica-vm: internal
GC error`) and call `_Exit(70)` (no atexit handlers, no stdio flush, so
buffered stdout is lost). They do not kill child processes: that would need
a global list of children, and the VM keeps none (10.2.3). A child then
sees EOF or `EPIPE` on its pipes and is left to end by itself (10.4).
Racket has no matching diagnostic, so this is a
documented difference (the exit code differs). It also sets `GC_set_warn_proc(GC_ignore_warn_proc)`,
so libgc warnings (such as `Repeated allocation of very large block`) never
reach the program's stderr.

## 7. Builtins in C

### 7.1 Calling convention

```c
typedef agc_value (*agc_builtin_fn)(agc_vm *vm, agc_value *args, uint32_t span);
```

`span` is the call's span index; argument `i` is at `span + 1 + i`. A
failing builtin calls `agc_fail` with the span the evaluator uses (`List.at`
uses its index argument, `Random.int` the call). `args` points into the
task's register array, which can move when it grows: a builtin never keeps
`args` across anything that pushes a frame or grows registers, and resumable
builtins copy what they need into their GC state.

### 7.2 Scope

7e: `IO`, `puts`, `print`, `gets`, `gets!`, `System`, `String`, `List`,
`Map`, `Float`, `Time`, `Random`, `ok`, `error`, `Result.*`, and `JSON`
(parse, extract, encode, builders, typed decode, schema: pure C, no event
loop). 7h: files (done on Linux, 2.8, 10.2.2), tasks (done, 10.2.1), processes (done, 10.4), TCP (done, 10.3.1), TLS,
HTTP. BDD gets no C builtins: it is written in Agentica (`std/bdd`,
`docs/future/31-bdd-in-agentica.md` §31); the VM adds only
`Process.spawn_captured`, `Process.output` and `Task.pending_count`.

### 7.3 Builtin safety and streams

- **Int bounds.** Every bounds check on an Int argument uses
  `__builtin_add_overflow` or the form `x < 0 || x > n - y`. A negative
  `int64_t` is never converted to `size_t` before the check.
- **No value-driven C recursion.** Printers, equality on nested data and every
  JSON operation (parse, encode, from, decode, schema) walk values with an
  explicit `GC_MALLOC`'d stack. Recursion is fine only when its depth is
  bounded by a constant or `log n` (HAMT levels, merge sort).
- **Strings to the OS.** `agc_cstr(s)` copies a String into `malloc`
  memory, so it can go to a thread-pool request, and adds the NUL; it
  returns NULL on an embedded NUL, and the caller returns the matching
  Racket message (2.8, or "command must be nonempty and arguments cannot
  contain NUL" in `process.rkt`). It is the only way a String reaches an OS
  or library call; file paths go through the same copy after the checks of
  2.8.
- **Sorting.** `List.sort` and `sort_by` are a stable merge sort with
  `order<?`: strings by code point (UTF-8 byte order), numbers by `<`, NaN
  last. `order<?` is a strict weak order on each key type (`-0.0` and
  `0.0` tie, NaNs tie with each other), so any stable sort gives Racket's
  result; `sort_by` is a bottom-up merge sort over item indexes (no
  recursion), and keys of mixed or other types are `RUNTIME-INTERNAL`.
- **Streams.** In 7e, stdin is one buffered reader over `read(0)`, shared by
  `gets`, `read`, `read_bytes` and `eof?`, like the single Racket port. It
  lives in `vm/input.c` (`agc_input_*`), the only code that reads stdin:
  one growing buffer (64 KiB first, doubled through `agc_size_mul`, so a
  long line or `IO.read` is bounded only by memory, and ends in the
  out-of-memory exit like any other growth; a buffer above 1 MiB is
  dropped for a fresh 64 KiB one once it is empty, so one huge line does
  not keep its memory for the rest of the run), blocking `read` with `EINTR`
  retried and, on Linux, `poll` when the descriptor is non-blocking. The
  builtins only call it; since the tasks PR each `read` runs as a
  thread-pool job that parks only the reading task (10.2.2, "Stdin"), and
  a builtin that must wait re-runs once the read is in, so what the
  builtins return did not change. A failed read
  is `RUNTIME-INTERNAL` for `gets`, `read` and `eof?` and the error value
  `"input read failed"` for `read_bytes`, as in the evaluator. The
  message differs (the evaluator shows Racket's port error, the VM says
  "cannot read standard input"), but the span is the same: the evaluator
  reports any Racket failure at the whole-program span, and the VM passes
  span 0, which maps to that span. When stdout is a terminal, `vm/main.c`
  opens stdin with `agc_input_open(vm, 0, isatty(1))`, so stdout is flushed
  before each blocking stdin read; a prompt written before `gets` shows
  up first, as it does with the evaluator on a terminal. Reading
  charges no steps: work inside builtins is free (2.1), so `--max-steps`
  does not bound a single read; only memory does (see the heap cap in
  13). `IO.flush` flushes
  stdout and fails like a write. `System.exit` records the code in the
  outcome (`AGC_EXITED`) and `longjmp`s like a diagnostic; `vm/main.c`
  flushes stdout and exits (2.5). A VM run without `vm/main.c` (the C
  tests, the fuzzer) has an empty stdin and no arguments.
  Output uses C stdio; on Windows all three streams are in binary mode
  (`_setmode`), because Racket does not translate `\n`.

### 7.4 Random

The VM has its own generator, so seeded sequences differ from the
evaluator's by design: `--seed N` repeats the same values run after run on
one backend, not across backends. The evaluator keeps Racket's `random`.
Only the contract is shared: the ranges, `Random.float` in `[0, 1)`, and
the `RUNTIME-INVALID-RANGE` error at the call.

- Generator (`vm/random.c`): xoshiro256** (Blackman and Vigna, public
  domain), its four state words (`agc_random` in `agc_vm`) filled by four
  splitmix64 outputs from the seed (also public domain).
- Tasks (7h, done): the generator state is per task (`agc_task.random`). The main task is seeded
  from `--seed`; a spawned task gets its own generator from its parent's at
  spawn time (a splitmix64 split of one parent draw). Each task's values
  then depend only on its own order of calls, so `--seed` repeats each
  task's values even with N>1 schedulers (10.2.3); only how output from
  different tasks interleaves is not repeatable. Every spawn takes exactly
  one draw from the parent's generator, whether or not the child uses
  `Random`, so the parent's later values depend on how many tasks it
  spawned before them. That is deterministic, but a seeded fixture that
  adds or removes a spawn changes the parent's values.
- `Random.float` is `(next >> 11) * 2^-53`. It can return exactly 0.0,
  which the evaluator's `(random)` never does; both stay in `[0, 1)`, so a
  fixture must not rely on `x > 0.0`.
- `Random.int(low, high)` (`agc_random_int`): `size = high - low + 1` in
  unsigned 64-bit arithmetic, where 0 means the full Int range (one draw
  as is). Otherwise the threshold method rejects draws below
  `2^64 mod size` (`(0 - size) % size`) and keeps `draw % size`, so the
  result is unbiased. The result is `low + offset` with wrapping unsigned
  arithmetic. `low > high` returns false without drawing, and the builtin
  fails with `RUNTIME-INVALID-RANGE` at the call.
- Seed: `--seed N` (0 .. 2147483647, the same check and message as
  `src/main.rkt`) on `agentica-vm`; `agentica --vm --seed N` passes it.
  Without it, `vm/main.c` takes 8 bytes from the same OS entropy as the
  map hash key (`getrandom`, then `/dev/urandom`; `rand_s` on Windows); if
  every source fails it uses the wall clock. `agc_vm_init` seeds with 0, so
  the C tests and the fuzzer stay deterministic.
- Tests: `vm/tests/random_test.c` checks that a seed repeats and two seeds
  differ, the bounds of `Random.float` and of `Random.int` for small,
  large, single-value and full ranges, a rough uniformity count, and that
  `low > high` leaves the state unchanged. The `random` fixture prints only
  what both backends share (counts of values in range, `[0, 1)` floats),
  and `random-invalid-range` compares the error. The extras shard checks
  that the VM repeats a seeded run, that two seeds differ, and the
  `--seed` option errors.

