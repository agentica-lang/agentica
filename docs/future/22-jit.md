## 22. JIT

**Status:** required, not gated (roadmap 7m). It starts after the VM layers
(section 21, roadmap 7l) and the server measurement (7j), so it has numbers to
beat, and after packages and the FFI (§40.5). Compiled code follows the
multicore rules of `docs/vm/16-architecture.md`. No language change.

**Tiers:**

- Tier 1 is the interpreter, with a counter per function and per loop (backward
  jump).
- Tier 2 is a baseline JIT for hot functions, in the style of V8's Sparkplug:
  one pass over the bytecode, no IR, fixed code per opcode. It has no
  speculation, so no deoptimization. It emits native code that calls the opcode
  helpers (`agc_op_concat`, `agc_op_eq`, ... from section 21) and inlines the
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

**Code generation** (decided in the JIT PR). No LLVM or libgccjit at run time
(size, and libgccjit is GPL). The release builds x86-64 and arm64, so the
choice must cover both. Options seen in 2026:

| Option | Gain | Cost |
| --- | --- | --- |
| Small hand-written assembler | No dependency | One backend per architecture |
| sljit (C, BSD; used by PCRE2) | One emitter for x86-64, arm64 and more | Third-party library (owner approval); no register allocation |
| Copy-and-patch (CPython) | Very fast compile | Needs clang at build time; CPython gained only 4-12% by 3.15, and was at times slower than its interpreter |
| MIR (C11, SSA, linear scan) | Real optimizations without LLVM | Larger dependency; release status unclear |

Lessons published by ZJIT: inlining calls to C helpers pays the most; spilling
VM frame state at every side-effecting operation is expensive; count events in
compiled code (for example C calls) before choosing what to optimize.

**Memory:** W^X: code is mapped RW, written, then made RX; never RWX. Linux
uses `mprotect`, Windows `VirtualProtect`, macOS arm64 `MAP_JIT` with
`pthread_jit_write_protect_np`. A code cache with a size cap.

**GC:** Boehm scans native stacks conservatively, so JIT frames need no stack
maps. Constants embedded in code must still stay reachable: each code object
holds its GC references in a scanned table.

**Tests:** the whole differential (later golden) suite and the latency test run
with `--jit=off`, `--jit=on` (normal thresholds) and `--jit=always` (compile
everything at its first call) in CI, and in the ASan job too.

**Benchmarks:** numbers before and after in `docs/vm-benchmarks.md`.

