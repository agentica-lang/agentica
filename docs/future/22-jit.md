## 22. JIT

**Status:** required, not gated (roadmap 7m). It starts after the VM layers (section 21, roadmap 7l) and the server measurement (7j), so it has numbers to beat. It is independent of 7i and of the multicore decision. No language change.

**Tiers:**

- Tier 1 is the interpreter, with a counter per function and per loop (backward jump).
- Tier 2 is a baseline JIT for hot functions, with no speculation at first, so no deoptimization. It emits native code that calls the opcode helpers (`agc_op_concat`, `agc_op_eq`, ... from section 21) and inlines the Int and Float fast paths, register moves and jumps.
- A later tier, type-specialized code with guards and deoptimization, comes only if profiling asks for it.

**Rules:**

- Compiled code keeps the `STEP` and turn-cost checks at the same safe points as the interpreter (backward jumps and calls), so `--max-steps`, fairness (`docs/vm/10-io-scheduler.md` §10.2.1) and cancellation still work.
- Frames stay interpreter-compatible, so a function can be interpreted or compiled, and a call can go either way.
- Black-box parity (`docs/vm/README.md` §1) holds: exit code, stdout, program stderr and diagnostic codes do not depend on the tier.

**Code generation** (decided in the JIT PR): copy-and-patch (stencils generated at build time with clang, as CPython 3.13 does) or a small hand-written x86-64 assembler. No LLVM or libgccjit at run time (size, and libgccjit is GPL). x86-64 Linux first, ARM64 next.

**Memory:** W^X: code is mapped RW, written, then `mprotect`ed to RX; never RWX. A code cache with a size cap.

**GC:** Boehm scans native stacks conservatively, so JIT frames need no stack maps. Constants embedded in code must still stay reachable: each code object holds its GC references in a scanned table.

**Tests:** the whole differential (later golden) suite and the latency test run with `--jit=off`, `--jit=on` (normal thresholds) and `--jit=always` (compile everything at its first call) in CI, and in the ASan job too.

**Benchmarks:** numbers before and after in `docs/vm-benchmarks.md`.

