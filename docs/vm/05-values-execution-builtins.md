## 5. Values in C

### 5.1 Representation

A value is a 16-byte tagged union passed by value (`vm/value.h`). Tag 0 is Void,
so zeroed registers are valid values.

| Type | Representation |
|---|---|
| Void, Nil, Bool | Immediate. |
| Int, Float | `int64_t` with `__builtin_*_overflow`; `double`. |
| String | `{ bytes, chars, data[] }`, `GC_MALLOC_ATOMIC`. `chars == bytes` means ASCII, so indexing is O(1). Not NUL-terminated by contract. Character counts are always computed, never read from a file. |
| List | Opaque: `struct agc_list` is defined in `vm/list.c` and in the private `vm/list_impl.h` (included by `list.c` and `interp.c`, for the inline `LIST_LEN` and `LIST_GET`, and by `tests/list_test.c`, to check the shape), and every other file reaches a list through the API of `value.h` (`agc_list_len`, `agc_list_get`, a sized builder for a new list, a cursor for a scan, `agc_list_append`, `agc_list_set`, `agc_list_slice`, `agc_list_concat`; [§17.4](17-lists.md)), so no file reads the layout. Only a builder writes a list, and only before it returns it. The layout is a persistent vector as in Clojure: a 32-way trie of leaves of 32 items plus a tail of 1 to 32 items held inline in the list object (`{ len, root, shift, tail[] }`; `root` is NULL up to 32 items), immutable. `append` copies the tail (and the path to a new leaf every 32nd time), `set` copies the tail and the path to its leaf, so both are near constant time; `get` is one compare up to 32 items and at most 4 loads up to a million, and a build of n pushes is O(n). `take`, `drop`, `reverse` and a `concat` with a long right list stay O(n) ([§17.2](17-lists.md)). |
| Map | A persistent 32-way HAMT from key to value (`vm/map.c`), plus a persistent list of keys, newest first, which gives the order. A put copies only its path. Put and lookup are O(log32 n). Printing, `keys` and `values` walk the key list oldest first. Keys are Int or String, compared by tag and value. They are hashed with SipHash-1-3. The key is seeded once per run from OS entropy (`getrandom`, then `/dev/urandom`; `rand_s` on Windows), independent of `--seed`. Tests and the fuzzer use the fixed default key. Iteration order never depends on the hash. `Map.delete` copies the path to the key and returns the same map for a missing key. |
| Struct | `{ type, n, fields[] }` in declaration order. |
| Enum | `{ variant, n, payload[] }`. Nullary variants are shared, one object per variant, made at load time. |
| Result | `{ ok, value }`. An error holds its String message. `ok()` holds Void. |
| Range | `{ start, end, exclusive }`, immutable. Text `1..5` or `1...5`. `Range.size` fails with `RUNTIME-INTEGER-OVERFLOW`. `Range.to_a` above 1048576 values fails with `RUNTIME-INVALID-COUNT`. `first` and `last` of an empty range are an error value. |
| Function value | `{ function, n, captured[] }`. `&name` has `n = 0`. Text `<Fn>`. |
| Json | `{ kind, scalar, count, members }`: null, bool, int64, big integer (kept as its decimal text until extracted), double, string, array (a List of Json), or object. Object members are sorted by key bytes, and the last of equal keys wins. `JSON.get` is a binary search. Text form is the JSON text. |
| Handles | One tag and GC record per kind: Task, Channel, Socket, Listener, HTTP values, FileHandle and Process. |

### 5.2 Safety rules for values

- `value.c` is the only code that reads a union member. Everything else uses
  checked accessors that take the VM. A wrong tag is `RUNTIME-INTERNAL` at the
  program span.
- `CALL_BUILTIN` checks each argument's tag against the builtin's parameter
  tags. Builtins check list and map elements when they touch them.
- `FIELD` and `PAYLOAD` check the index against the value's own `n`, not only
  against the tables.
- A builtin that reads a builtin record (`Header`, `HttpRequest`,
  `HttpResponse`, `FileInfo`, `ProcessOutput`) finds its struct by exact name
  and fields (`agc_builtin_struct`, `vm/builtins.c`). If the struct is missing,
  it fails with `RUNTIME-INTERNAL`. The loader does not check these records.
- Every String constructor validates UTF-8 (no overlongs, no surrogates, at most
  U+10FFFF) or decodes with U+FFFD: argv, `Dir.list`, stdin, process and socket
  text, JSON `\u` escapes.
- Size arithmetic goes through checked helpers (`agc_size_add`, `agc_size_mul`).
  An overflow is an out-of-memory failure (6.3).

### 5.3 Boehm rules

- Objects holding `agc_value`s use `GC_MALLOC`. Strings and byte buffers use
  `GC_MALLOC_ATOMIC`, which is not zeroed, so no code exposes an unfilled tail.
- Never store a GC pointer in `malloc` memory, in an atomic object or in a
  `_Thread_local`: Boehm does not scan them. Pointers are never tagged. The
  exception is `handle->data` and `SSL_set_app_data`, which may point to a GC
  object only while the resource registry also roots it (10.2).
- No GC finalizers for OS resources. Closing is explicit (10.2).
- Roots (runtime, schedulers, program, tasks) live in GC objects reachable from
  the runtime struct, never in mutable static storage (10.2.3).

## 6. Execution

### 6.1 Stack, call depth and steps

- Each task owns a register array and a frame array, both GC memory, grown by
  doubling. A call grows the registers to the callee's declared count and new
  registers are zeroed. Frames hold base offsets, never raw pointers. A native
  frame (4.3) has a state pointer, so code that walks frames checks it first.
- The interpreter is one `switch` loop. Agentica calls push frames and never
  recurse on the C stack, so a task switch only changes the current task.
- Before `CALL`, `CALL_VALUE` or a callback push, a call depth of 10000 fails
  with `RUNTIME-STACK-OVERFLOW` at that instruction's span. `main` runs at
  depth 1. Native frames do not count, and each task starts at 0. `TAIL_CALL`
  replaces the frame, so it neither checks nor changes the depth.
- The register array is capped at 2^24 per task, and passing the cap fails the
  same way. A valid program reaches it only with more than about 1,600 registers
  per frame at full depth.
- A tail call removes frames, so a deep tail-recursive loop runs without
  overflow. A diagnostic carries one span and no stack trace, so the removed
  frames are not visible. Stack traces are planned in
  `docs/future/24-logging.md` §24.3.
- `steps_left` is an atomic `int64_t`: the limit, or `INT64_MAX` without one.
  All tasks share it. A turn takes it in batches (10.2.1). `STEP` compares
  against a "next stop" counter. Long builtins and opcodes charge their work to
  the turn only, never to `steps_left` (10.2.1).

### 6.2 Failure, exit and cleanup

- A runtime diagnostic always ends the run. `agc_fail(vm, code, message, span)`
  records it and `longjmp`s to the `setjmp` in `agc_vm_run`, which runs cleanup
  and returns an outcome (done, exit code or diagnostic) to `vm/main.c`. Only
  `main.c` prints and exits. `System.exit` takes the same path.
- `agc_fail` is called only from interpreter and builtin code on the VM's own C
  stack, never from a libuv or OpenSSL callback. Non-GC resources are registered
  before any call that can fail. Locals that live across `setjmp` are
  `volatile`.
- Cleanup is one exit path (`end_run` in `vm/main.c`, 10.2.2): kill and reap the
  children, flush stdout, stderr and the files, then `_exit`. It runs on a
  normal end, on `System.exit`, on a diagnostic, on the step limit and on
  `SIGINT`, `SIGTERM` and `SIGHUP`. After a stop signal the VM ends by that
  signal. A second stop signal ends it at once, but only after the children are
  stopped. The out-of-memory and GC abort exits (6.3) and `SIGKILL` run no
  cleanup.
- Windows does not have this cleanup yet. The plan is console control events and
  a kill-on-close job object, which would also cover crashes.

### 6.3 Out of memory and GC aborts

At startup the VM sets `GC_set_oom_fn` and `GC_set_abort_func`. Their handlers
allocate nothing, write one fixed line with `write(2)`
(`agentica-vm: out of memory`, or `agentica-vm: internal GC error` for an abort)
and call `_Exit(70)`. There are no atexit handlers and no stdio flush, so
buffered stdout is lost. The VM keeps no list of children, so it does not kill
them: they see EOF or `EPIPE` and end by themselves (10.4). libgc warnings are
ignored (`GC_set_warn_proc`), so they never reach the program's stderr.

## 7. Builtins in C

### 7.1 Calling convention

```c
typedef agc_value (*agc_builtin_fn)(agc_vm *vm, agc_value *args, uint32_t span);
```

`span` is the call's span index. Argument `i` is at `span + 1 + i`. A failing
builtin calls `agc_fail` with the span its diagnostic uses (`List.at` uses its
index argument, `Random.int` the call). `args` points into the task's register
array, which moves when it grows. A builtin never keeps `args` across anything
that pushes a frame or grows registers. Resumable builtins copy what they need
into their GC state.

### 7.2 Scope

The C builtins are in `vm/*.c`, with one table per module. The catalog and the
implementation keys are in `src/builtins.rkt`. BDD has no C builtins: it is
written in Agentica (`std/bdd`, `docs/bdd.md`). The VM adds only
`Process.spawn_captured`, `Process.output`, the child channel builtins of 25c
(`Process.spawn_channel`, `channel_read_line`, `channel_send`, `channel_close`,
`read_available`, `parent_read_line` and `parent_send`; `vm/process.c`,
`vm/duplex.c`), `Task.pending_count`, `Task.spawn_owning` (24b, `vm/task.c`) and
the `Channel` builtins (`vm/channel.c`). A channel call that must wait needs the
event loop, so off Linux it fails like the other loop builtins. The event loop,
files, processes, TCP, TLS and HTTP (client and server) are Linux only for now
(the `__linux__` guards in `vm/loop.c`, `vm/files.c`, `vm/process.c`,
`vm/tcp.c`, `vm/tls_openssl.c`, `vm/http_client.c` and `vm/http_server.c`).

### 7.3 Builtin safety and streams

- **Int bounds.** Every bounds check on an Int argument uses
  `__builtin_add_overflow` or the form `x < 0 || x > n - y`. A negative
  `int64_t` is never converted to `size_t` before the check.
- **No value-driven C recursion.** Printers, equality on nested data and every
  JSON operation walk values with an explicit `GC_MALLOC`'d stack. Recursion is
  fine only when its depth is bounded by a constant or by `log n` (HAMT levels,
  merge sort).
- **Strings to the OS.** `agc_cstr` copies a String into `malloc` memory with a
  NUL and returns NULL on an embedded NUL. It is the only way a String reaches
  an OS or library call. File paths go through the same copy after the checks in
  2.8.
- **Sorting.** `List.sort` and `sort_by` are stable merge sorts with `order<?`:
  strings by code point, numbers by `<`, NaN last. `order<?` is a strict weak
  order, so any stable sort gives the same result. `sort_by` is a bottom-up
  merge over item indexes (no recursion). Keys of mixed types are
  `RUNTIME-INTERNAL`.
- **Streams.** stdin is one buffered reader over `read(0)`, shared by `gets`,
  `read`, `read_bytes` and `eof?`. It lives in `vm/input.c`, the only code that
  reads stdin. The buffer starts at 64 KiB and doubles through `agc_size_mul`,
  so a long line is bounded only by memory. A buffer above 1 MiB is dropped for
  a fresh one once it is empty. Each blocking read runs as a thread-pool job
  that parks only the reading task (10.2.2). A failed read is `RUNTIME-INTERNAL`
  for `gets`, `read` and `eof?`, and an error value for `read_bytes`. Reading
  charges no steps, so `--max-steps` does not bound a single read; only memory
  does (13). `IO.flush` fails like a write. Output uses C stdio. On Windows the
  three streams are in binary mode.
- A VM run without `vm/main.c` (the C tests and the fuzzer) has an empty stdin
  and no arguments.

### 7.4 Random

- The VM has its own generator. Seeded sequences are the VM's own, so the
  fixtures print only what does not depend on the numbers.
- The generator is xoshiro256** (Blackman and Vigna, public domain). Its four
  state words are filled by four splitmix64 outputs from the seed
  (`vm/random.c`).
- Each task has its own generator state. The main task is seeded from `--seed`.
  A spawned task gets its generator from its parent at spawn time (a splitmix64
  split of one parent draw). Every spawn takes exactly one draw from the parent,
  whether or not the child uses `Random`. So adding or removing a spawn changes
  the parent's later values in a seeded run.
- `Random.float` is `(next >> 11) * 2^-53`. It is in `[0, 1)` and can be exactly
  `0.0`, so a fixture must not rely on `x > 0.0`.
- `Random.int(low, high)` uses `size = high - low + 1` in unsigned 64-bit
  arithmetic, where 0 means the full Int range (one draw as is). Otherwise it
  uses the threshold method: draws below `2^64 mod size` are rejected, and
  `draw % size` is kept. The result is unbiased. `low > high` fails with
  `RUNTIME-INVALID-RANGE` at the call, and draws nothing.
- `--seed N` takes 0 to 2147483647 on `agentica-vm`, and `agentica --seed N`
  passes it through. Without a seed the VM takes 8 bytes from the same OS
  entropy as the map hash key. If every source fails, it uses the wall clock.
  `agc_vm_init` seeds with 0, so the C tests and the fuzzer are deterministic.
- Tests: `vm/tests/random_test.c` checks that a seed repeats and that two seeds
  differ, the bounds of both functions for small, large, single-value and full
  ranges, a rough uniformity count, and that `low > high` leaves the state
  unchanged.
