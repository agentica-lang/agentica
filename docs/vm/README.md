# Agentica bytecode VM: design

The design of the C bytecode VM, which runs every program. The language does not
change: `docs/grammar/` (index `docs/grammar.md`) stays the contract. The VM is
the only backend. The VM's codename is Aurora, but only in these docs: the
binary (`agentica`), the `AGENTICA_VM_*` variables, the `agc_` prefix, `.agcb`
and `vm/` keep their names.

The section numbers stay as they were, so a reference such as `§10.4` still
finds its place. The table below gives the file for each number. The checklist
of what is built and what is pending is `docs/roadmap/07-vm.md`.

## 1. Overview

**Golden outputs, not parity.** Each fixture in `tests/fixtures/vm/` has a
golden file, `<name>.expected`, with its exit code, stdout, program stderr and
diagnostic code. The VM is the reference. When behavior changes on purpose,
`make goldens` rewrites the files, and the PR shows their diff for review
(12.1). A new fixture gets hand-checked expected output.

**Black-box rule.** The goldens check the exit code, stdout, program stderr and
diagnostic code, and nothing else. A runaway program must stop with
`RUNTIME-STEP-LIMIT` under `--max-steps`. A run stopped by a smaller limit gives
a prefix of the full stdout and program stderr (12.1). Diagnostic message text
and span, the VM's own stderr wording, OS error text, exact step counts and
step-limit spans may change in a PR that updates the goldens. An error string
that a program prints is program data, so it is part of its golden. VM messages
must be clear and useful for agents. The turn cost (10.2.1) stays, for fairness.

The compiler may optimize freely as long as the goldens stay the same: inlining,
constant folding, common subexpression elimination, loop-invariant code motion,
and merging or moving `STEP`s. A runaway loop must still hit
`RUNTIME-STEP-LIMIT`. Step counts may change.

```text
.agc files
  -> lexer, parser, module linker, checker      (compiler/, Agentica)
  -> checked AST + expression type table
  -> compiler/lower/lowering.agc        IR: functions, slots, typed ops, labels, spans
  -> compiler/bytecode/bytecode_writer.agc bytecode: instructions, constants, tables, spans
  -> .agcb file (binary, versioned)
  -> vm/ (C11 + Boehm GC): load, validate, run
```

The checker gives the checked type of each expression node, by node id. Lowering
resolves names to slots and indexes, makes types explicit, keeps spans and
converts closures. The bytecode writer resolves labels and writes the constant
pool, builtin imports, the struct, enum, JSON type and span tables, merges
steps and writes the binary. Printing and exit codes stay in
`compiler/app/cli.agc`. `vm/` is the C VM that builds `dist/agentica`.

The lowerer rejects a form it does not handle yet with `LOWER-UNSUPPORTED` at
the node's span (3.5). It never guesses.

**Trust model.** A `.agcb` file is untrusted input. Whatever it contains, the VM
must not have memory errors, must not run child processes unless the VM itself
got `--allow-run`, and must stop within `--max-steps` when a limit is given. A
file that passes the loader can still compute wrong values or end with
`RUNTIME-INTERNAL`. That is the whole guarantee. `--max-steps` bounds
instructions, not memory. One `CONCAT` or `INSPECT` costs time and memory in
proportion to its strings, so a file can double a string per instruction and
reach the out-of-memory exit (70, 6.3) in a few dozen steps. Printing a list
costs time and memory in proportion to its text, and lists can share items.
Chained bindings can make that text exponential in the number of bindings, and
printing such a list ends in the same out-of-memory exit. A heap cap is an open
question (13).

## Files

- **§1:** Overview, golden contract, pipeline and trust model (this file).
- **§2:** [Reference behavior](02-reference-behavior.md)—steps, values,
  diagnostics, JSON and files.
- **§§3–4:** [IR and bytecode](03-ir-and-bytecode.md), including the
  file format.
- **§§5–7:** [VM core](05-values-execution-builtins.md): values, execution
  and builtins.
- **§§8–9:** [Loader and CLI](08-loader-and-cli.md), packaging and tracing.
- **§10, 10.0–10.1:**
  [Dependencies/platforms](10-dependencies-and-platforms.md).
- **§10.2–10.2.2:** [Scheduler and event loop](10-io-scheduler.md).
- **§10.2.3:** [Multicore rules](10-io-multicore.md); model in §16.
- **§§10.3–10.3.1:** [TLS and TCP](10-io-tls.md).
- **§§10.4–10.5:** [Processes and runtime limits](10-io-processes.md).
- **§§10.6–10.7:** [HTTP](10-io-http.md)—parser and VM implementation.
- **§11:** [Build, CI and supply chain](11-build-ci-supply-chain.md).
- **§§12–13:** [Tests and PR plan](12-testing-and-pr-plan.md); open questions.
- **§14:** [Core invariants](14-core-invariants.md).
- **§15:** [VM layers](15-layers.md); roadmap 7.2.1b.
- **§16:** [VM architecture](16-architecture.md); roadmap 7.2.1c.
- **§17:** [Persistent lists](17-lists.md); design for roadmap 8d.
