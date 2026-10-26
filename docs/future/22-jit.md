## 22. JIT

**Status:** required, not gated (roadmap 7m). It starts after the VM layers
(`docs/vm/15-layers.md`, roadmap 7l) and the server measurement (7j), so it has
numbers to beat, and after packages and the FFI (issue
[#534](https://github.com/sonic182/agentica/issues/534)). Compiled code follows
the multicore rules of `docs/vm/16-architecture.md`. No language change.

**Tiers:**

- Tier 1 is the interpreter, with a counter per function and per loop (backward
  jump).
- Tier 2 is a baseline JIT for hot functions, in the style of V8's Sparkplug:
  one pass over the bytecode, no IR, fixed code per opcode. It has no
  speculation, so no deoptimization. It emits native code that calls the opcode
  helpers (`agc_op_*` in `vm/core.h`) and inlines the
  Int and Float fast paths, register moves and jumps.
- A later tier comes only if measurements ask for it: an SSA IR built from the
  bytecode and the checker's types, locals in registers, linear-scan register
  allocation (the shape of Ruby's ZJIT).
- Static types are the advantage over Ruby and JavaScript JITs: they need
  profiles, type guards and side exits back to the interpreter because they do
  not know the types. Agentica's checker does. If the bytecode keeps the operand
  types (this `+` is on `Int`), compiled code needs guards only for Int overflow
  and helper errors.

**Rules:**

- Compiled code keeps the `STEP` and turn-cost checks at the same safe points as
  the interpreter (backward jumps and calls), so `--max-steps`, fairness
  (`docs/vm/10-io-scheduler.md` §10.2.1) and cancellation still work.
- Frames stay interpreter-compatible, so a function can be interpreted or
  compiled, and a call can go either way.
- Black-box parity (`docs/vm/README.md` §1) holds: exit code, stdout, program
  stderr and diagnostic codes do not depend on the tier.

**Code generation:** our own emitter in C, one per architecture, with no new
dependency: no LLVM or libgccjit at run time (size, and libgccjit is GPL), no
sljit and no asmjit. The release ships x86-64 (Linux, Windows, macOS) and arm64
(macOS), so there are two emitters. Options seen in 2026:

| Option | Gain | Cost |
| --- | --- | --- |
| Small hand-written assembler | No dependency | One backend per architecture |
| sljit (C, BSD; used by PCRE2) | One emitter for x86-64, arm64 and more | A `vm/third_party` submodule (owner approval); no register allocation |
| Copy-and-patch (CPython) | Very fast compile | Needs clang at build time; CPython gained only 4-12% by 3.15, and was at times slower than its interpreter |
| MIR (C11, SSA, linear scan) | Real optimizations without LLVM | Larger dependency; release status unclear |

Lessons published by ZJIT (2026): inlining calls to C helpers pays the most;
spilling VM frame state at every side-effecting operation is expensive; count
events in compiled code (for example C calls) before choosing what to optimize.

Sources: [Sparkplug](https://v8.dev/blog/sparkplug),
[ZJIT in Ruby 4.0](https://bernsteinbear.com/blog/launch-zjit/),
[ZJIT load and store removal](https://railsatscale.com/2026-03-18-how-zjit-removes-redundant-object-loads-and-stores/),
[PEP 836](https://peps.python.org/pep-0836/),
[MIR](https://developers.redhat.com/articles/2022/02/16/code-specialization-mir-lightweight-jit-compiler).

**Code layout:** the JIT lives in `vm/jit/`, in the core layer. `jit.h` is its
only boundary with the interpreter: compile a function, enter compiled code,
and the exit, which returns `{status, pc}`. `jit.c` walks the bytecode,
`emit_x64.c` and `emit_a64.c` encode the instructions, and `mem_posix.c` and
`mem_windows.c` hold the code memory. Each file comes with its first use.

**Built (x86-64):** `--jit MODE` (or `AGENTICA_JIT`; the flag wins): `off`,
the default; `on`, which compiles a function that has a loop at its 100th
entry (a call, a return into it, or a turn that starts in it; counted only
until it compiles) once 32 of its entries were passes (an entry at or
before the pc of the one before: a call, or a loop that went round), so a
long loop body that runs a few times stays interpreted however many calls
it makes; `always`, every
function at its first entry, for tests. Only the user's program is
compiled; the front end stays in the interpreter. On another architecture
every mode runs the interpreter. `MOVE`, `CONST`, `STEP`, the Int, Float
and list opcodes, `EQ`, `NE`, `SAME`, `CONCAT`, `TO_TEXT`, `NOT`, `FIELD`, `IS_VARIANT`,
`PAYLOAD`, `IS_OK`, `RESULT_VALUE` and the jumps have code. A `CALL` of a
function that has code is a native call: compiled code pushes the frame as
`push_frame` does, in frames and registers the task already has, and calls the
callee's code, up to 256 calls deep on the C stack (`AGC_JIT_NATIVE_DEPTH`); the
callee's `RETURN` pops it. Any exit inside the callee goes up through its
callers' code unchanged, so the interpreter finds the callee's frame on top and
the native calls are gone. A call that cannot be native (no code yet, an array
to grow, the depth limit, the native depth) and a `RETURN` of a function not
called natively take the `CALL` and `RETURN` exits: the interpreter runs the
shared frame transition and goes on in the code of the new top frame when it
has some. Other unsupported instructions (including builtins and allocations)
leave the code for the interpreter. A leaf builtin is called between two runs
of compiled code, without the interpreter's loop.

- Decided once: the JIT looks at every function when the run starts. A
  function that `on` will not compile is never counted or walked again, and
  when no function is left the run has no JIT: it runs the plain turn loop,
  the same code as `off`.
- Why a loop: a function without a backward jump runs each instruction at
  most once per entry, and the entry, the exit and the `RETURN` in the
  interpreter cost more than those few instructions save. Blocks of 3 to 7
  instructions that `filter`, `map` or `reduce` call a million times, and an
  empty function called 20 million times (about 13 ns more per call), ran
  slower compiled. So `on` gives such a function code only for native calls,
  when none of its instructions leaves (a leaf builtin counts here, as its
  exit unwinds the native calls): at its first `CALL` exit from compiled
  code when it calls a function (it may recurse), else at its 16th
  (`AGC_JIT_CALLEE_THRESHOLD`), since a compile costs about as much as
  interpreting thousands of instructions; the interpreter enters that code
  only to resume a frame of it, never at its first instruction.
- Why `on` also keeps out a loop that often leaves: each trip to the
  interpreter and back costs more than interpreting the few instructions
  around it saves (`print-lines`, `small-values` and `strings` of
  `benchmarks/`, whose loops leave every 4 to 9 instructions, ran 3 to 8%
  slower compiled). A function stays out when one of its innermost loops has
  more than one instruction that leaves (a leaf builtin, a `RETURN` and a
  `CALL` of a function that may get code do not count) in 16
  (`AGC_JIT_SPACING`).
- Why no JIT when nothing compiles: the jit copy of the turn loop has the same
  handlers as the plain copy, but its machine code sits at other addresses,
  which alone made programs that compiled nothing 6 to 10% slower or faster
  than `off` (list-build slower, calls and string-library faster).
- Entry: at each reload of the turn loop (a call, a return, the start of a
  turn) the interpreter tests one byte of the function and enters its code at
  `frame->pc` through a table of entry offsets, so a turn that ended inside a
  compiled loop resumes in compiled code.
- Exits: a slow `STEP` (the interpreter runs `step_slow`, then ends the turn or
  enters the code again at the next instruction), a turn cost to apply (a
  String compare in `EQ`, `NE` or `SAME`, a join in `CONCAT`, a compound,
  String or Json form in `TO_TEXT`), a failure (raised as the helper
  contract says), and an instruction without code or a slow path (a wrong
  tag, a field index past the count), which the interpreter runs; the turn
  loop enters the code again when it reaches the next instruction, or at its
  next reload. A `CALL` or `RETURN` that is not native takes its own exit
  (above).
- Code: one pass, fixed code per instruction, the VM in rbx, the registers in
  r12, the constants in r13 and the native call depth in r14, the Int fast paths
  inline with their overflow checks; `EQ` and `NE` call `agc_op_eq` and
  `agc_op_ne` for any pair other than two Ints; the Float opcodes, `SAME`,
  `CONCAT`, `TO_TEXT`, `LIST_LEN` and `LIST_GET` call their helper; `NOT`,
  `FIELD`, `IS_VARIANT`, `PAYLOAD`, `IS_OK` and `RESULT_VALUE` read the value
  inline after a tag check.
- Code memory: one reservation of 64 MiB per run (`AGC_JIT_CODE_CAP`, in
  bytes), taken in whole pages from the start, one seal after the other. A
  sealed page is never written again (another scheduler may run it), so
  functions share pages only when sealed together: the code of a function
  without a loop waits in a batch until the next `CALL` exit of a function in
  it, the next function the interpreter enters, or 16 KiB of batch, so the
  callees of one loop body that get hot together share one seal. Only the
  scheduler that claims a function compiles it; another one interprets it
  until the code is published.
- `AGENTICA_VM_TRACE=jit` writes a `compile` line for each compiled function
  and a `skip` line for each function kept out: `loop=none` or `loop=exits`
  when the run starts, and `size` when its code did not fit at compile time.
  At the end of the run, `exit op=OP count=N` counts generic `INTERPRET`
  exits by opcode, `leaf count=N` the leaf builtins called between two
  runs of compiled code, and `transition count=N` the `CALL` and `RETURN`
  exits (a native call or return is not one).
- Tests: `tests/test_vm_jit.py` (the three modes on a `--max-steps` sweep of
  three tasks in compiled loops, failures, a cancel, a turn ended by cost, `on`
  switching in the middle of a loop, four schedulers, a function without a loop
  that `on` compiles only for a compiled caller, string joins and text forms in
  compiled code, fields, lists, enums, Results and Floats read in compiled code
  with the exit counts of the trace, native calls with a `--max-steps` sweep, an
  overflow and the depth limit inside natively called functions),
  `make vm-jit-test` (the goldens and their sweeps and `test_vm_multicore.py`
  with `AGENTICA_JIT=always`, which compiles every function, in CI) and
  `vm/tests/jit_test.c` (bytes, exits, the read-execute seal, functions
  packed in one reservation up to its cap, a batch sealed in one page, the
  work of settling `on` bounded by the program's size, a compile race,
  every opcode compiles, the results and statuses of the helper calls and inline
  reads, a native call's frame push and pop and its exits, also under
  `make vm-tsan`).
- Known limits: a function with a loop that is called very often from the
  interpreter but whose loop rarely runs still pays the entry and the exit at
  each call; a program with one function that `on` may compile keeps the jit
  copy of the turn loop (and its layout effect) even if that function never
  gets hot; and after an exit has unwound native calls (a turn that ends, a
  builtin), each of those frames returns through the `RETURN` exit.

**Helper contract** (`agc_op_*` and `agc_status` in `vm/core.h`): compiled code
never calls `agc_fail`, because on Windows x64 `longjmp` unwinds the stack and
JIT frames have no unwind info. A helper takes the VM, the result register and
the operand registers by pointer (a 16-byte struct by value is passed
differently by the SysV and Win64 conventions), writes the result only on
success, and returns a status: `OK`, `OVERFLOW`, `DIVISION_BY_ZERO`,
`INDEX_OUT_OF_RANGE` or `WRONG_TAG`. On any other status than `OK`, compiled
code returns `{status, pc}`, and the interpreter, outside compiled code, calls
`agc_op_fail` with the span of the instruction at `pc` (`WRONG_TAG` fails at
span 0, as `agc_wrong_tag` does). Before that, the exit leaves the operand
registers in the frame's register file (the `INDEX_OUT_OF_RANGE` message
prints the list's length and the index) and sets `frame->pc` past the failing
instruction, as the interpreter does before each instruction: the stack trace
reads it. Helpers count no step and apply no turn cost:
the caller runs the `STEP`s, and after `EQ`, `NE`, `SAME`, `CONCAT` and
`TO_TEXT`, which add the bytes of a String compare, a join, or a printed
form to the task's turn cost, it applies the cost where the interpreter
does. A helper never parks, yields or pushes a frame. Builtins
fail with `agc_fail`, so compiled code does not call them directly. The C test
`vm/tests/op_helpers_test.c` checks the statuses; the goldens check the
failures that `agc_op_fail` makes of them.

**Memory:** W^X: code is written RW, then made RX; never writable and
executable at once for a thread. Linux uses `mprotect` and Windows
`VirtualProtect`. macOS arm64 maps `MAP_JIT` pages and switches them per thread
with `pthread_jit_write_protect_np`. A code cache with a size cap.

**GC:** Boehm scans native stacks conservatively, so JIT frames need no stack
maps. Constants embedded in code must still stay reachable: each code object
holds its GC references in a scanned table.

**Tests:** the whole differential (later golden) suite and the latency test run
with `--jit=off`, `--jit=on` (normal thresholds) and `--jit=always` (compile
everything at its first call) in CI, and in the ASan job too.

**Benchmarks:** numbers before and after in `docs/vm-benchmarks.md`.

