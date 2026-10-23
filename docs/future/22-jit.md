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

**Helper contract** (`agc_op_*` and `agc_status` in `vm/core.h`): compiled code
never calls `agc_fail`, because on Windows x64 `longjmp` unwinds the stack and
JIT frames have no unwind info. A helper takes the VM, the result register and
the operand registers by pointer (a 16-byte struct by value is passed
differently by the SysV and Win64 conventions), writes the result only on
success, and returns a status: `OK`, `OVERFLOW`, `DIVISION_BY_ZERO`,
`INDEX_OUT_OF_RANGE` or `WRONG_TAG`. On any other status than `OK`, compiled
code returns `{status, pc}`, and the interpreter, outside compiled code, calls
`agc_op_fail` with the span of the instruction at `pc` (`WRONG_TAG` fails at
span 0, as `agc_wrong_tag` does). Helpers count no step and apply no turn cost:
the caller runs the `STEP`s, and after `EQ`, `NE` and `SAME`, which add the
bytes of a String compare to the task's turn cost, it applies the cost where
the interpreter does. A helper never parks, yields or pushes a frame. Builtins
fail with `agc_fail`, so compiled code does not call them directly.

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

