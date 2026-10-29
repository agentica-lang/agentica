## 5. Values in C

### 5.1 Representation

A value is a 16-byte tagged union passed by value (`vm/value.h`). Tag 0 is Void,
so zeroed registers are valid values.

- **Type:** Void, Nil, Bool
  - **Representation:** Immediate.

- **Type:** Int, Float
  - **Representation:** `int64_t` with `__builtin_*_overflow`; `double`.

- **Type:** String
  - **Representation:** `{ bytes, chars, data[] }`, `GC_MALLOC_ATOMIC`. `chars
    == bytes` means ASCII, so indexing is O(1). Not NUL-terminated by contract.
    Character counts are always computed, never read from a file.

- **Type:** Bytes
  - **Representation:** `{ len, data[] }`, `GC_MALLOC_ATOMIC`, immutable (tag
    `AGC_T_BYTES`). Items read as Int 0 to 255. The empty Bytes is one
    constant (`agc_empty_bytes`); `slice`, `take` and `drop` copy. `==` is the
    same length and bytes (`memcmp`, not constant time). A Map key or Set item
    hashes its bytes with the tag as SipHash domain, so it never equals a
    String of the same bytes. `to_s` is `<Bytes 3>`; inspect adds the first 32
    bytes in hex (`<Bytes 3 616263>`, `...` past them). No JSON form: the
    encoder fails with `RUNTIME-INTERNAL`. No bytecode constant holds one.

- **Type:** List
  - **Representation:** Opaque: `struct agc_list` is defined in `vm/list.c` and
    the private `vm/list_impl.h`, and every other file reaches a list through
    the API of `value.h` ([§17.4](17-lists.md)), so no file reads the layout.
    Only a builder writes a list, and only before it returns it. The layout is
    a persistent vector as in Clojure: a 32-way trie of leaves of 32 items plus
    a tail of 1 to 32 items held inline in the list object (`{ len, root, shift,
    kind, tail[] }`; `root` is NULL up to 32 items), immutable. A list whose
    items are all Ints, or all Floats, keeps 8 raw bytes per item, with no tag,
    in atomic leaves, and `kind` says which
    ([§17.12](17-lists.md#1712-unboxed-numeric-leaves)); the code that builds
    the list picks the kind from the values, so a mixed list from hostile
    bytecode is simply boxed. `append`, `set` and `get` are near constant time,
    a build of n pushes is O(n), and `take`, `drop`, `reverse` and a `concat`
    with a long right list stay O(n) ([§17.2](17-lists.md)).

- **Type:** Map
  - **Representation:** A persistent 32-way HAMT from key to value (`vm/map.c`),
    plus a persistent list of keys, newest first, which gives the order. A node
    keeps its leaves, then its child pointers, so a put copies only its path
    and a child link costs 8 bytes. Put and lookup are O(log32 n). A delete is
    O(log32 n) amortized along one line of versions: it marks its key's cell
    dead by adding the key's insertion number to the map's dropped list, and
    the list is rebuilt without dead cells (O(n)) once they outnumber the live
    ones. Printing, `keys` and `values` walk the key list oldest first and skip
    dead cells by insertion number, with no key lookup. Keys are Int, String or
    Bytes, compared by tag and value. They are hashed with SipHash-1-3. The key
    is seeded once per run from OS entropy (`getrandom`, then `/dev/urandom`;
    `rand_s` on Windows), independent of `--seed`. Tests and the fuzzer use
    the fixed default key. Iteration order never depends on the hash.
    `Map.delete` copies the path to the key and returns the same map for a
    missing key.

- **Type:** Set
  - **Representation:** The `agc_map` of a Map under its own tag (`AGC_T_SET`):
    the same HAMT and key list, every value nil, so the elements are the keys,
    in first-insertion order. `Set.add` of a member and `Set.delete` of a
    missing element return the same map. Text `Set[1, 2]`, elements as in a
    list. `Test.eq` compares by size and membership; there is no `==` and no
    JSON form.

- **Type:** Struct
  - **Representation:** `{ type, n, fields[] }` in declaration order.

- **Type:** Enum
  - **Representation:** `{ variant, n, payload[] }`. Nullary variants are
    shared, one object per variant, made at load time.

- **Type:** Result
  - **Representation:** `{ ok, value }`. An error holds its String message.
    `ok()` holds Void.

- **Type:** Range
  - **Representation:** `{ start, end, exclusive }`, immutable. Text `1..5` or
    `1...5`. `Range.size` fails with `RUNTIME-INTEGER-OVERFLOW`. `Range.to_a`
    above 1048576 values fails with `RUNTIME-INVALID-COUNT`. `first` and `last`
    of an empty range are an error value.

- **Type:** Function value
  - **Representation:** `{ function, n, captured[] }`. `&name` has `n = 0`. Text
    `<Fn>`.

- **Type:** Json
  - **Representation:** `{ kind, scalar, count, members }`: null, bool, int64,
    big integer (kept as its decimal text until extracted), double, string,
    array (a List of Json), or object. Object members are sorted by key bytes,
    and the last of equal keys wins. `JSON.get` is a binary search. Text form is
    the JSON text.

- **Type:** Handles
  - **Representation:** One tag and GC record per kind: Task, Channel, Socket,
    Listener, HTTP values, FileHandle and Process.

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
- `FIELD` and `PAYLOAD` check the index against the value's own `n`, not only
  against the tables. `STRUCT_WITH` checks that the receiver has the struct type
  and the field count of its update entry. The count test is a defence: the C
  creators of a record go through `agc_builtin_struct`, which checks the name,
  the count and the field names.
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
- The loop keeps the top frame's code, span table, register window and next
  `pc` in locals, and reloads them only after an instruction that changes the
  frame stack or can move the frame or register arrays (`CALL`, `CALL_VALUE`,
  `TAIL_CALL`, `RETURN`, a failing `TRY`, and a builtin that pushes a native
  frame). A builtin that returns normally leaves them valid: frames and
  registers are pushed only by the interpreter, on the running task, and a
  builtin spawns its tasks' frames, never its own. The saved `pc` of the frame
  is still written before each instruction runs, because a failure (the stack
  trace), a park and a yield read it.
- Before `CALL`, `CALL_VALUE` or a callback push, a call depth of 10000 fails
  with `RUNTIME-STACK-OVERFLOW` at that instruction's span. `main` runs at
  depth 1. Native frames do not count, and each task starts at 0. `TAIL_CALL`
  replaces the frame, so it neither checks nor changes the depth.
- The register array is capped at 2^24 per task, and passing the cap fails the
  same way. A valid program reaches it only with more than about 1,600 registers
  per frame at full depth.
- A tail call removes frames, so a deep tail-recursive loop runs without
  overflow. The removed frames are not visible, but `TAIL_CALL` sets the `tail`
  flag of the frame it reuses, and a frame that `CALL` or a native pushes starts
  with the flag clear. Those stores of the flag (one per `TAIL_CALL`, `CALL` and
  native push) are all the stack trace costs while a program runs, plus the span
  of the spawning call that a task keeps (`spawn_span`, set when the task is
  spawned).
- The stack trace is built when the program fails (the shape is in
  [`02-reference-behavior.md`](02-reference-behavior.md)). `agc_fail` and
  `agc_fail_text` call `agc_stack_capture` (`vm/diag.c`)
  before the `longjmp`, only while a task runs (`vm->in_turn`). It walks the
  frames of `vm->task` from the innermost one, skips the native frames, merges
  neighbouring frames with the same function, place and tail flag, and keeps
  the 15 innermost and the 5 outermost lines in `outcome.stack`, a fixed array:
  it allocates nothing, so it cannot fail, and it reads at most the frames of
  one task (the depth is capped at 10000), twice. The place of the innermost
  frame is the span of the error; the place of a caller is the span of the
  instruction at its saved `pc - 1`, read through the function's own span table
  with `pc` clamped to the code. A function index or span index that is out
  of range (a hand-built program; the loader checks them) drops the frame or
  uses span 0, so a hostile `.agcb` cannot make the walk read out of bounds.
  The outcome is printed later, by `vm/launch.c` at the end of the run or by the
  scheduler for the crash of a task other than `main`, when the failing task may
  be finished and its frames freed, so the lines are copied at the failure.
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

The JIT (`vm/jit/`) compiles hot functions of the user's program to x86-64
machine code. The front end runs in the interpreter, except under the test-only
`AGENTICA_VM_TEST_FRONT_END_JIT`: on the short run that compiles a small
program, its own compiles cost more than they save. The JIT changes no exit
code, output, diagnostic, span or step count (`tests/test_vm_jit.py`).
`vm/jit/jit.h` is its only boundary with the interpreter: the interpreter asks
for a function's code, enters it at the frame's `pc`, and handles the exit it
returns.

- **Modes.** `--jit MODE`, or `AGENTICA_JIT` (the flag wins), takes `off`, `on`
  or `always`. `off` has no JIT; `on` is the default. At the start of a run `on`
  decides every function once (`agc_jit_settle`), in time linear in the program:
  about 1.2 ms for the 174,000 instructions of the front end's bytecode on the
  Ryzen 5 3550H of `docs/vm-benchmarks.md` (`agentica run -- stage2.agcb
  --version 0 -- --help`: median 33 ms with `off`, 35 ms with `on`). An entry of
  a function is a call, a return into it, or a turn that starts in it. `on`
  compiles a function with a loop (a backward jump, or a `TAIL_CALL` of itself)
  at its 100th entry, once 32 of its entries were passes (an entry at or before
  the previous one: a new call, or a loop that went round). It keeps a function
  out when one of its innermost loops has more than one instruction that leaves
  compiled code per 16 instructions; a builtin that may park (a channel or task
  wait, a sleep, a read of stdin, a file, path, process or socket call:
  `agc_jit_parking` in `vm/jit/jit.c`) counts as three. A function without a
  loop gets code only for native calls, and only when none of its instructions
  leaves compiled code: at its first `CALL`, `TAIL_CALL` or `CALL_VALUE` exit
  from compiled code when it calls a function, else at its 16th call that leaves
  compiled code. `always` compiles every function at its first entry, for tests.
  A host without an emitter runs every mode in the interpreter.
- **Native calls.** A `CALL` of a function that has code is a native call. So is
  a `CALL_VALUE` (a block, a closure or `&name`) whose function has code.
  Compiled code pushes the frame and calls the callee's code, up to 256 deep
  (`AGC_JIT_NATIVE_DEPTH`); the callee's `RETURN` pops it. A `TAIL_CALL` of a
  function that has code replaces the top frame in place, as the interpreter
  does (same base, `ret` and depth, `tail` set), and jumps to the callee's code;
  a `TAIL_CALL` of the function itself jumps to its first instruction. It nests
  nothing on the C stack and charges nothing; the callee's `STEP`s do. A call
  that cannot be native (no code, the frames or registers would grow, or a tail
  call of more than 32 arguments, `AGC_JIT_TAIL_PARAMS`) takes an exit. `on`
  counts a `CALL_VALUE` as a call, not as leaving.
- **Exits.** Three kinds of builtin matter here:
  - A *direct* builtin only returns a value. It may allocate, do work that grows
    with its arguments, charge turn cost and fail. It never parks, starts a
    block or a native frame, or moves frames.
  - A *leaf* builtin is a plain C call. It never parks, starts a block or a
    stepper, or charges turn cost, and its work is bounded.
  - A *block call* is a builtin row with a native kind (`map`, `filter`,
    `reduce` and the others). Its native frame calls a block, and the block's
    frames run in compiled code when the block has code.

  Compiled code calls a direct builtin itself, and a leaf builtin when a native
  call is below it, so the native calls stay on the C stack. A leaf at native
  depth 0 takes the `INTERPRET` exit, which unwinds nothing and costs less than
  the catch of the call. The hottest leaves that cannot fail once their
  arguments pass a check (`plain_leaves` in `vm/jit/jit.c`) are called at any
  depth, with no catch, after that check: the tags for `size` of a List,
  `append`, `ok`, `ok?` and `length` of a String, and for `code` of a String
  also that the String has one character. A failed check takes the `INTERPRET`
  exit. Compiled code returns `{status, pc}` at its first exit.
  `run_compiled` (`vm/interp.c`) handles it as the interpreter handles the
  instruction at `pc`:
  - `STEP`: the slow step (`step_slow`), which may stop, yield or start a batch.
  - `COST`: applies a turn cost.
  - `INTERPRET`: an instruction without code or with a slow path, which the
    interpreter runs. `run_compiled` calls a leaf builtin itself, at native
    depth 0 or after a failed tag check. It starts a block call, whose block
    then runs in its code.
  - `CALL`, `CALL_VALUE`, `TAIL_CALL` and `RETURN`: the interpreter's frame
    transitions, then the code of the new top frame if it has some.
  - `RETURNED`: a native `RETURN` to the caller's code. It never reaches
    `run_compiled`.
  - A block's `RETURN` to a block call that calls the same function again
    takes no exit. `agc_jit_block_return` does what the native frame does with
    the value and charges the step or turn cost of the next call. Then the
    block's frame starts over in place, at instruction 0 with the next
    arguments. A turn that this cost ends takes the `YIELD` exit at pc
    `UINT32_MAX` (`AGC_JIT_PC_RESTART`), so the frame's pc stays 0. The other
    cases take the `RETURN` exit: the last item, a value that ends the call
    (`any?`, `all?`) or that it would fail on, a slow step, a stepper (`Lazy`,
    `File.each_line`), a block call whose function value is not the
    returning frame's function, and a frame that a native tail call reached.
  - `YIELD` and `RAISE`: a direct builtin that compiled code called ended the
    turn or failed.
- **Helper contract.** The machine code never fails itself. Its `agc_op_*`
  helpers (`vm/core.h`) return an `agc_status`: `OK`, `OVERFLOW`,
  `DIVISION_BY_ZERO`, `INDEX_OUT_OF_RANGE` or `WRONG_TAG`. A status other than
  `OK` makes compiled code return as an exit. The interpreter then raises the
  failure at the span of the instruction at `pc`; `WRONG_TAG` fails at span 0.
  Before it raises, `run_compiled` sets `frame->pc` past that instruction,
  which the stack trace reads. Helpers charge no step and no turn cost; the
  caller does.

  Compiled code never calls `agc_fail`. On Windows x64, `longjmp` unwinds the
  stack, and JIT frames have no unwind info. A direct builtin is called through
  `agc_jit_call_builtin`, a leaf one through `agc_jit_call_leaf`. Both set
  `vm->jit_catch`, so a failure inside the builtin jumps back to them and not
  across compiled code. The builtin's registers stay in the frame's register
  file during the call, so the collector sees them.
- **Code.** Each instruction has fixed code, emitted in one pass over the
  bytecode. The register convention is in the header of `vm/jit/emit_x64.c`.
- **Code memory.** At most 64 MiB per run (`AGC_JIT_CODE_CAP`). Memory is
  reserved in chunks of 1 MiB, each twice the last, so the address space follows
  the code. Code is written read-write, then sealed read-execute (`mprotect` on
  Linux and macOS, `VirtualProtect` on Windows). No page is writable and
  executable at once, and a sealed page is never written again. Only the
  scheduler that claims a function compiles it; another scheduler interprets the
  function until its code is published. A function without a loop waits in a
  16 KiB batch. The batch is sealed with the next function compiled to run at
  once (a hot function the interpreter enters, a callee that calls, or a block
  at its first block call), when a function in it reaches its 32nd call that
  leaves compiled code, or when the batch holds 16 KiB. So the callees of one
  loop body can share a seal. After a memory failure nothing more compiles.
- **Compile budget.** Each compile first takes the function's instruction count
  plus 32 units from `AGC_JIT_BUDGET` (1,000,000 units). A unit is a count of
  work, not a time, so every host compiles the same functions. The first compile
  that does not fit the budget or the code memory stops compiling for the rest
  of the run, and the functions not yet compiled stay interpreted. A function
  whose cost alone exceeds the budget stays interpreted.
  `AGENTICA_VM_TEST_JIT_BUDGET=N` gives a test a smaller budget (`vm/launch.c`).
- **Why.**
  - A function without a loop runs each instruction once per entry. The entry,
    the exit and the `RETURN` cost more than the few instructions they save.
    Blocks of a few instructions that `filter`, `map` or `reduce` call, and an
    empty function called many times, ran slower compiled. So `on` gives such a
    function code only for native calls.
  - `on` keeps out a function whose loop leaves compiled code often: each trip
    out and back costs more than the instructions it saves. The loops of
    `benchmarks/programs/print-lines.agc`, `small-values.agc` and `strings.agc`
    leave every few instructions, and ran slower compiled.
  - A channel or task wait that parks ends the turn, and the woken task enters
    the code again only to leave at the same call, which it retries. The loops
    of `benchmarks/programs/channel-pingpong.agc` (32 instructions, a send and a
    receive) ran 1.2 times slower compiled; with longer bodies, two such calls
    broke even at 64 to 96 instructions, about three plain exits each.
  - A block call in a function without a loop counts as leaving, so `on` keeps
    that function out. A block without a loop gets code at the first block call
    that compiled code starts with it, since that call runs it once per item.
  - The jit copy of the turn loop has the same handlers as the plain copy, but
    its machine code sits at other addresses. That alone changed the timings of
    programs that compiled nothing. So a run with no function to compile has no
    JIT: `agc_jit_new` returns NULL, for `off` and for an `on` run that keeps
    every function out. `make layout-check` guards the layout of the plain copy.
- **Trace.** `AGENTICA_VM_TRACE=jit` (or `all`) writes these lines:
  - `skip function=F loop=none` or `loop=exits` at the start, for each function
    that `on` keeps out.
  - `compile function=F instructions=N bytes=B` for each compile.
  - `skip function=F size` when the emitter cannot encode the function, or
    `skip function=F budget` when it costs more than the budget.
  - `memory pages=N` when the code memory fails.
  - `budget spent=work|bytes ...` once, when compiling stops: `work` for the
    budget, `bytes` for the code memory.
  - At the end: `exit op=OP count=N` (interpreter exits by opcode), `leaf
    count=N` (the leaf exits at native depth 0, and the plain leaves whose
    check failed), `block count=N`, `transition count=N` (the `CALL`,
    `CALL_VALUE`, `TAIL_CALL` and `RETURN` exits; a native call, tail call or
    return is not one), `transition op=tail-call count=N compiled=M` (the
    `TAIL_CALL` exits, and those whose callee had code) and `turn count=N` (the
    turns that ran the jit copy of the turn loop).
- **Tests.** `tests/test_vm_jit.py` covers the modes, failures, cancels, turns
  that end inside compiled code, native and block calls, tail calls and the exit
  counts of the trace. `vm/tests/jit_test.c` covers the emitter, code memory,
  helpers and exits; `make vm-tsan` runs it under ThreadSanitizer. `make
  vm-jit-test` runs the goldens with `AGENTICA_JIT=always` and half the shards
  with `off`, in CI. `make vm-jit-self-compile` compiles the front end under
  each mode and compares the bytes. `make test-jit-off` runs the conformance
  areas with `off`, and `jit-soak.yml` runs it daily on the three x86-64
  systems.
- **Fuzzing and layout.** `make vm-libfuzz` needs clang and runs on Linux. It
  runs each accepted input with `always` and `on` and compares the result with
  the interpreter's. Only runs that read no clock are compared. A JIT run that
  stops at the allocation limit, where the interpreter's run did not, is counted
  and not compared. `make layout-check` runs on Linux x86-64, release build
  only. It compares the layout of the `--jit off` loop with a base revision. An
  intended move carries the `layout-change` label in CI, which accepts it.
- **Known limits.**
  - Only x86-64 has an emitter; the other hosts run the interpreter, arm64 macOS
    included.
  - A builtin that is neither leaf, direct nor a block call (for example
    output, tasks, channels and files) returns to the turn loop and unwinds the
    native calls below it.
  - A block call whose block has code takes the `RETURN` exit at its end, and
    at a slow step of `times`, `upto`, `downto` or `each` of a Range. A block
    that a stepper calls takes it at each call.
  - A function with a loop that is called often but whose loop rarely runs still
    pays the entry and the exit at each call.
  - Until some code is published, only turns that start near a function that may
    get code, and a turn drawn at random (one in 16 on average), run the jit
    copy of the turn loop. Code that runs only inside turns therefore compiles
    later. After 8 drawn turns in a row with no entry counted, the draw takes
    half as many turns, down to one in 256; an entry counted sets it back to one
    in 16.
  - The jit copy of the turn loop interprets slower than the plain copy: it
    tests the resume pc at each instruction, and gcc keeps its code pointer on
    the stack. With every turn in it and nothing compiled, `logger-disabled`
    took about 1.4 times as long, `arithmetic` 1.2 and `channel-pingpong` 1.2
    (the Ryzen 5 3550H and gcc 14.2.0 of `docs/vm-benchmarks.md`).
    Once some code is published every turn runs it, so the interpreted part of
    such a run pays this.

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
