## 5. Values in C

### 5.1 Representation

A value is a 16-byte tagged union passed by value (`vm/value.h` has the
layouts). Tag 0 is Void, so zeroed registers are valid values. Notes the code
does not make obvious:

- **Int, Float.** Int uses `__builtin_*_overflow`.
- **String.** `GC_MALLOC_ATOMIC`, not NUL-terminated by contract. `chars ==
  bytes` means ASCII, so indexing is O(1). Character counts are always computed,
  never read from a file.
- **Bytes.** Immutable, `GC_MALLOC_ATOMIC`. `slice`, `take` and `drop` copy.
  `==` is the builtin `Bytes.equal` (`memcmp`, not constant time), not `EQ`. A
  Map key or Set item hashes its bytes with the tag as SipHash domain, so it
  never equals a String of the same bytes. `to_s` is `<Bytes 3>`; inspect adds
  the first 32 bytes in hex. No JSON form (the encoder fails with
  `RUNTIME-INTERNAL`) and no bytecode constant holds one.
- **List.** Opaque: `struct agc_list` lives in `vm/list.c` and the private
  `vm/list_impl.h`, and every other file uses the API of `value.h` (§17.4,
  [17-lists.md](17-lists.md)). Only a builder writes a list, and only before it
  returns it. It is a persistent vector (a 32-way trie with an inline tail) and
  a list of all Ints or all Floats keeps 8 raw bytes per item
  ([§17.12](17-lists.md#1712-unboxed-numeric-leaves)); the builder picks the
  kind from the values, so a mixed list from hostile bytecode is simply boxed.
  `append`, `set` and `get` are near constant time; `take`, `drop`, `reverse`
  and a `concat` with a long right list stay O(n) (§17.2).
- **Map.** A persistent 32-way HAMT (`vm/map.c`) plus a persistent list of keys,
  newest first, which gives the order. A put copies only its path. A delete is
  O(log32 n) amortized along one line of versions: it marks the key's cell dead
  by adding its insertion number to the map's dropped list, and the key list is
  rebuilt (O(n)) once dead cells outnumber live ones. Printing, `keys` and
  `values` walk the key list oldest first and skip dead cells without a key
  lookup. Keys are Int, String or Bytes. String and Bytes keys use SipHash-1-3.
  An Int key is XORed with the key and mixed with MurmurHash3's finalizer: a
  bijection, so two Ints never share a hash and no set of Int keys makes a
  lookup scan. The hash key is seeded once per run from OS entropy
  (`getrandom`, `/dev/urandom`, `rand_s` on Windows), independent of `--seed`;
  tests and the fuzzer use the fixed default key. Iteration order never depends
  on the hash. `Map.delete` of a missing key returns the same map.
- **Set.** The `agc_map` of a Map under its own tag (`AGC_T_SET`): every value
  nil, so the elements are the keys in first-insertion order. `Set.add` of a
  member and `Set.delete` of a missing element return the same map. `==` and
  `Test.eq` compare by size and membership; there is no JSON form.
- **Enum.** Nullary variants are shared, one object per variant, made at load
  time.
- **Result.** An error holds its String message; `ok()` holds Void.
- **Range.** Immutable. `Range.size` fails with `RUNTIME-INTEGER-OVERFLOW`;
  `Range.to_a` above 1048576 values fails with `RUNTIME-INVALID-COUNT`; `first`
  and `last` of an empty range are an error value.
- **Function value.** `&name` has no captures.
- **Json.** Big integers stay decimal text until extracted. Object members are
  sorted by key bytes and the last of equal keys wins, so `JSON.get` is a binary
  search.
- **Handles.** One tag and GC record per kind: Task, Channel, Socket, Listener,
  HTTP values, FileHandle and Process.

### 5.2 Safety rules for values

- `value.c` and the inline constructors and checked accessors of `value.h` are
  the only code that reads a union member. Everything else uses the checked
  accessors, which take the VM. A wrong tag is `RUNTIME-INTERNAL` at the
  program span. The accessors of the common types are `static inline`, with
  one out-of-line failure (`agc_wrong_tag`): the interpreter calls two or
  three on most instructions, and as calls into `value.c` they cost more than
  the `ADD_I` they served.
- `CALL_BUILTIN` checks each argument's tag against the builtin's parameter
  tags. Builtins check list and map elements when they touch them.
- `FIELD`, `PAYLOAD` and `STRUCT_WITH` check against the value's own size, not
  only the tables (4.2). The C creators of a record go through
  `agc_builtin_struct`, which checks the name, the count and the field names.
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
- No GC finalizers for OS resources. Closing is explicit (10.2). The one
  finalizer is a `TlsContext`'s, which only gives back its count on a
  `malloc`'d TLS config (10.3). `GC_set_finalize_on_demand(1)` keeps it out of
  allocations: it runs at the start of a scheduler's next task. It is
  registered with `GC_REGISTER_FINALIZER_NO_ORDER`, the macro that matches
  `GC_MALLOC_ATOMIC` in the GC-debug build.
- Roots (runtime, schedulers, program, tasks) live in GC objects reachable from
  the runtime struct, never in mutable static storage (10.2.3).
- Heap growth: `agc_init` sets the free-space divisor to 2 (libgc's default is
  3), so more is allocated between collections. The front end's self-compile
  ran 10% faster with 13% more peak memory. `GC_FREE_SPACE_DIVISOR` in the
  environment still wins: 3 gives back libgc's default, and 1 is faster still
  for more memory.

## 6. Execution

### 6.1 Stack, call depth and steps

- Each task owns a register array and a frame array, both GC memory, grown by
  doubling. A call grows the registers to the callee's declared count and new
  registers are zeroed. Frames hold base offsets, never raw pointers. A native
  frame (4.3) has a state pointer, so code that walks frames checks it first.
- The interpreter is one `switch` loop. Agentica calls push frames and never
  recurse on the C stack, so a task switch only changes the current task.
- The loop keeps the top frame's code, span table, register window and next
  `pc` in locals, and reloads them only after an instruction that changes the
  frame stack or can move the frame or register arrays (`CALL`, `CALL_VALUE`,
  `TAIL_CALL`, `RETURN`, a failing `TRY`, a builtin that pushes a native frame).
  A builtin that returns normally leaves them valid: frames and registers are
  pushed only by the interpreter, on the running task. The saved `pc` of the
  frame is still written before each instruction runs, because a failure, a
  park and a yield read it.
- Before `CALL`, `CALL_VALUE` or a callback push, a call depth of 10000 fails
  with `RUNTIME-STACK-OVERFLOW` at that instruction's span. `main` runs at
  depth 1. Native frames do not count, and each task starts at 0. `TAIL_CALL`
  replaces the frame, so it neither checks nor changes the depth.
- The register array is capped at 2^24 per task, and passing the cap fails the
  same way. A valid program reaches it only with more than about 1,600 registers
  per frame at full depth.
- A tail call removes frames, so a deep tail-recursive loop runs without
  overflow. `TAIL_CALL` sets the `tail` flag of the frame it reuses, and a frame
  that `CALL` or a native pushes starts with it clear. Those stores, plus the
  span of the spawning call that a task keeps (`spawn_span`), are all the stack
  trace costs while a program runs.
- The stack trace is built when the program fails (the shape is in
  [`02-reference-behavior.md`](02-reference-behavior.md)). `agc_fail` and
  `agc_fail_text` call `agc_stack_capture` (`vm/diag.c`) before the `longjmp`,
  only while a task runs (`vm->in_turn`). It keeps the 15 innermost and the 5
  outermost lines in `outcome.stack`, a fixed array: it allocates nothing, so it
  cannot fail, and it reads at most the frames of one task (the depth is capped
  at 10000), twice. A caller's place is the span at its saved `pc - 1`, with
  `pc` clamped to the code; a function or span index out of range (a
  hand-built program) drops the frame or uses span 0, so a hostile `.agcb`
  cannot make the walk read out of bounds. The lines are copied at the failure
  because the outcome is printed later, when the failing task's frames may be
  freed.
- `steps_left` is an atomic `int64_t`: the limit, or `INT64_MAX` without one.
  All tasks share it. A turn takes it in batches (10.2.1). `STEP` compares
  against a "next stop" counter. Long builtins and opcodes charge their work to
  the turn only, never to `steps_left` (10.2.1).

### 6.2 Failure, exit and cleanup

- A runtime diagnostic always ends the run. `agc_fail(vm, code, message, span)`
  records it and `longjmp`s to the `setjmp` in `agc_vm_run`, which runs cleanup
  and returns an outcome (done, exit code or diagnostic) to the driver. Only the
  driver (`agentica.c`, `launch.c`) prints and exits. `System.exit`
  takes the same path.
- `agc_fail` is called only from interpreter and builtin code on the VM's own C
  stack, never from a libuv or OpenSSL callback. Non-GC resources are registered
  before any call that can fail. Locals that live across `setjmp` are
  `volatile`.
- Cleanup is one exit path (`agc_launch_settle` in `vm/launch.c`, 10.2.2): kill
  and reap the children, flush stdout, stderr and the files, then `_exit`. It
  runs on a normal end, on `System.exit`, on a diagnostic, on the step limit and
  on `SIGINT`, `SIGTERM` and `SIGHUP`. After a stop signal the VM ends by that
  signal. A second stop signal ends it at once, but only after the children are
  stopped. The out-of-memory and GC abort exits (6.3) and `SIGKILL` run no
  cleanup.
- On Windows, `SIGINT`, `SIGBREAK` and `SIGHUP` take the same path
  (`vm/loop.c`), and the kill-on-close job object of 10.4 ends the children of
  a VM that is killed.

### 6.3 Out of memory and GC aborts

At startup the VM sets `GC_set_oom_fn` and `GC_set_abort_func`. Their handlers
allocate nothing, write one fixed line with `write(2)`
(`agentica: out of memory`, or `agentica: internal GC error` for an abort)
and call `_Exit(70)`. There are no atexit handlers and no stdio flush, so
buffered stdout is lost. The VM keeps no list of children, so it does not kill
them: they see EOF or `EPIPE` and end by themselves (10.4). libgc warnings are
ignored (`GC_set_warn_proc`), so they never reach the program's stderr.

### 6.4 JIT

The JIT (`vm/jit/`) compiles hot functions of the user's program to x86-64 or
arm64 (Linux and macOS) machine code. Other hosts run the interpreter. The front
end runs in the interpreter, except under the test-only
`AGENTICA_VM_TEST_FRONT_END_JIT`: on the short run that compiles a small
program, its own compiles cost more than they save. The JIT changes no exit
code, output, diagnostic, span or step count (`tests/test_vm_jit.py`).
`vm/jit/jit.h` is its only boundary with the interpreter: the interpreter asks
for a function's code, enters it at the frame's `pc`, and handles the exit it
returns.

- **Modes.** `--jit MODE`, or `AGENTICA_JIT` (the flag wins): `off`, `on` (the
  default) or `always` (every function at its first entry, for tests). At the
  start of a run `on` decides every function once (`agc_jit_settle`), in time
  linear in the program. The policy lives in `vm/jit/jit.c` (the thresholds are
  constants there). In short: a function with a loop is compiled at its 100th
  entry once enough entries were passes, unless one of its innermost loops
  leaves compiled code too often (a builtin that may park counts as three
  exits); a function without a loop gets code only for native calls, when none
  of its instructions leaves compiled code.
- **Native calls.** A `CALL`, or a `CALL_VALUE` (a block, a closure or `&name`),
  of a function that has code is a native call: compiled code pushes the frame
  and calls the callee's code, up to `AGC_JIT_NATIVE_DEPTH` (256) deep; the
  callee's `RETURN` pops it. A `TAIL_CALL` of a function that has code replaces
  the top frame in place, as the interpreter does, and nests nothing on the C
  stack. A call that cannot be native (no code, the frames or registers would
  grow, or a tail call of more than `AGC_JIT_TAIL_PARAMS` arguments) takes an
  exit.
- **Exits.** Three kinds of builtin matter. A *direct* builtin only returns a
  value: it may allocate, do work that grows with its arguments, charge turn
  cost and fail, but it never parks, starts a block or a native frame, moves
  frames or yields halfway (`==` on two large equal values runs whole in one
  turn, and the task yields after it returns). A *leaf* builtin is a plain C
  call that also never charges turn cost, and its work is bounded. A *block
  call* is a builtin row with a native kind (`map`, `filter`, `reduce` and the
  others): its block runs in compiled code when it has code. Compiled code calls
  a direct builtin itself, and a leaf builtin when a native call is below it, so
  the native calls stay on the C stack; a leaf at native depth 0 takes the
  `INTERPRET` exit, which costs less than the catch of the call. A few hot
  leaves that cannot fail once their arguments pass a check (`plain_leaves` in
  `vm/jit/jit.c`) are called at any depth. Compiled code returns `{status, pc}`
  at its first exit, and `run_compiled` (`vm/interp.c`) handles it as the
  interpreter handles the instruction at `pc`. The exit kinds are `STEP` (the
  slow step), `COST`, `INTERPRET`, `RESUME` (a block call whose next step may
  fail, take a slow step or sort), `CALL`, `CALL_VALUE`, `TAIL_CALL` and
  `RETURN` (the interpreter's frame transitions), `RETURNED` (a native return,
  never seen by `run_compiled`), `YIELD` and `RAISE`. A block's `RETURN` to a
  block call that calls the same function again takes no exit: the block's frame
  starts over in place (`agc_jit_block_return`), and a turn that its cost ends
  yields at pc `AGC_JIT_PC_RESTART` so the frame's pc stays 0.
- **Helper contract.** The machine code never fails itself. Its `agc_op_*`
  helpers (`vm/core.h`) return an `agc_status`; a status other than `OK` makes
  compiled code return as an exit, and the interpreter raises the failure at the
  span of the instruction at `pc` (`WRONG_TAG` at span 0), after `run_compiled`
  sets `frame->pc` past that instruction for the stack trace. Helpers charge no
  step and no turn cost; the caller does. Compiled code never calls `agc_fail`:
  on Windows x64, `longjmp` unwinds the stack, and JIT frames have no unwind
  info. A direct or leaf builtin is called through `agc_jit_call_builtin` or
  `agc_jit_call_leaf`, which set `vm->jit_catch`, so a failure jumps back to
  them and not across compiled code. The builtin's registers stay in the
  frame's register file during the call, so the collector sees them.
- **Code.** Each instruction has fixed code, emitted in one pass over the
  bytecode; the register conventions are in the headers of `vm/jit/emit_x64.c`
  and `vm/jit/emit_a64.c`. On arm64 the thread that runs compiled code first
  runs `isb` (`agc_jit_sync`), as the code may come from another thread. On
  Linux each seal runs membarrier's `SYNC_CORE`, registered by the launch before
  any other thread starts, so a native call branches without `isb`; where that
  fails (an old kernel, seccomp) and on macOS, a native call runs `isb` first
  (`agc_jit_use_sync`).
- **Code memory.** At most 64 MiB per run (`AGC_JIT_CODE_CAP`), reserved in
  chunks that double from 1 MiB. Code is written read-write, then sealed
  read-execute (`mprotect`, `VirtualProtect` on Windows): no page is writable
  and executable at once, and a sealed page is never written again. Only the
  scheduler that claims a function compiles it; another scheduler interprets it
  until its code is published. A function without a loop waits in a 16 KiB batch
  that is sealed with the next function compiled to run at once, so the callees
  of one loop body can share a seal. After a memory failure nothing more
  compiles.
- **Compile budget.** Each compile takes the function's instruction count plus
  32 units from `AGC_JIT_BUDGET` (1,000,000). A unit counts work, not time, so
  every host compiles the same functions. The first compile that does not fit
  the budget or the code memory stops compiling for the rest of the run.
  `AGENTICA_VM_TEST_JIT_BUDGET=N` gives a test a smaller budget.
- **Perf map.** With `AGENTICA_PERF_MAP=1` (any POSIX host), each function is
  added to `/tmp/perf-PID.map` when its code is published, so `perf report`
  names compiled code. The file is opened to append with `O_NOFOLLOW` and
  `O_NONBLOCK` and used only when it is a regular file of the user who runs the
  VM with one link. The first open of a process empties a map that an earlier
  process with the same PID left.
- **Why the policy.** Each point was measured on `benchmarks/programs/`.
  - A function without a loop runs each instruction once per entry; the entry,
    the exit and the `RETURN` cost more than the instructions they save, so a
    small block or an empty function ran slower compiled. It still gets code for
    native calls, so a call on a rare path (`Logger.debug`) costs nothing on the
    common one.
  - A loop that leaves compiled code often loses: each trip out and back costs
    more than it saves (`print-lines`, `small-values`, `strings`). A channel or
    task wait that parks ends the turn and the woken task enters the code only
    to leave at the same call (`channel-pingpong` ran 1.2 times slower).
  - A block call does not count as leaving, as compiled code starts it.
  - The jit copy of the turn loop has the same handlers as the plain copy at
    other addresses, and that alone changed the timings of programs that
    compiled nothing. So a run with no function to compile has no JIT
    (`agc_jit_new` returns NULL). `make layout-check` guards the layout of the
    plain copy.
- **Trace.** `AGENTICA_VM_TRACE=jit` (or `all`) writes the `skip`, `compile`,
  `memory`, `budget` and exit-count lines; `tests/test_vm_jit.py` shows each.
- **Tests.** `tests/test_vm_jit.py` covers the modes, failures, cancels, turns
  that end inside compiled code, native and block calls, tail calls and the
  trace counts. `vm/tests/jit_test.c` covers the emitter, code memory, helpers
  and exits. `make vm-jit-test` runs the goldens with `AGENTICA_JIT=always` and
  half the shards with `off`; `make vm-jit-self-compile` compiles the front end
  under each mode and compares the bytes; `make test-jit-off` runs the
  conformance areas with `off` (`jit-soak.yml` daily on the five systems).
  `make vm-libfuzz` (clang, Linux) runs each accepted input with `always` and
  `on` and compares the result with the interpreter's, for runs that read no
  clock. `make layout-check` (Linux x86-64, release) compares the layout of the
  `--jit off` loop with a base revision; an intended move carries the
  `layout-change` label.
- **Known limits.**
  - Windows on arm64 and 32-bit hosts run the interpreter. On macOS the code
    pages are sealed with plain `mprotect`, which needs a binary without the
    hardened runtime: the release signs it ad hoc, and `tools/release-check.sh`
    fails a binary signed with `--options runtime`.
  - A builtin that is neither leaf, direct nor a block call (output, tasks,
    channels, files) returns to the turn loop and unwinds the native calls below
    it.
  - A function with a loop that is called often but whose loop rarely runs still
    pays the entry and the exit at each call.
  - Until some code is published, only turns that start near a function that may
    get code, and a turn drawn at random (one in 16 on average, down to one in
    256 after 8 drawn turns with no entry counted), run the jit copy of the turn
    loop. Code that runs only inside turns therefore compiles later.
  - The jit copy interprets slower than the plain copy (it tests the resume pc
    at each instruction): `logger-disabled` took about 1.4 times as long with
    nothing compiled (the machine of `docs/vm-benchmarks.md`).

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
implementation keys are in `compiler/catalog/builtins_data.agc`. BDD has no C
builtins: it is written in Agentica (`std/bdd`, `docs/bdd.md`). A channel call
that must wait, and `Task.map`, need the event loop. The event loop, files,
processes, TCP, TLS and every `HttpWire` builtin (the pure helpers, the client
service and the server) build and run on Linux, macOS and Windows, so
`std/http` works on all three.

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
- A VM run without `vm/agentica.c` (the C tests and the fuzzer) has an empty
  stdin and no arguments.

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
- `--seed N` takes 0 to 2147483647 on `agentica run`, and `agentica --seed N`
  passes it through. Without a seed the VM takes 8 bytes from the same OS
  entropy as the map hash key. If every source fails, it uses the wall clock.
  `agc_vm_init` seeds with 0, so the C tests and the fuzzer are deterministic.
