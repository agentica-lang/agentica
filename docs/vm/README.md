# Agentica bytecode VM: design

The design of the C bytecode VM, which runs every program. The language does not
change: `docs/grammar/` (index `docs/grammar.md`) stays the contract. The VM is
the only backend. The Racket evaluator was deleted in roadmap 7i. The VM's
codename is Aurora, but only in these docs: the binary (`agentica`), the
`AGENTICA_VM_*` variables, the `agc_` prefix, `.agcb` and `vm/` keep their names.

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
  -> lexer, parser, module linker, checker      (Racket)
  -> checked AST + expression type table
  -> src/lower.rkt      IR: functions, slots, typed ops, labels, spans
  -> src/bytecode.rkt   bytecode: instructions, constants, tables, spans
  -> .agcb file (binary, versioned)
  -> vm/ (C11 + Boehm GC): load, validate, run
```

| Place | Owns |
|---|---|
| `src/checker.rkt` | Fills a caller-supplied `eq?` hash from each expression node to its checked type. |
| `src/lower.rkt` | Checked program to IR. Resolves names to slots and indexes, makes types explicit, keeps spans, converts closures. |
| `src/bytecode.rkt` | IR to bytecode: label resolution, constant pool, builtin imports, struct, enum, JSON type and span tables, step merging, binary writer. |
| `src/main.rkt` | `--dump-ir`, `compile`, and running every program on the VM. Printing and exit codes stay here. |
| `vm/` | The C VM: loader, values, interpreter loop, builtins, JSON, diagnostics, CLI driver. Builds `dist/agentica`. |

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

| § | Topic | File |
|---|---|---|
| 1 | Overview: golden outputs, black-box rule, pipeline, trust model | this file |
| 2 | Reference behavior: steps, numbers, strings, printing, diagnostics, JSON, files | [`02-reference-behavior.md`](02-reference-behavior.md) |
| 3, 4 | IR (lowering) and bytecode: machine model, instructions, calls, builtin imports, file format | [`03-ir-and-bytecode.md`](03-ir-and-bytecode.md) |
| 5, 6, 7 | Values in C, execution (stack, failure, out of memory) and builtins in C | [`05-values-execution-builtins.md`](05-values-execution-builtins.md) |
| 8, 9 | Loader safety; CLI and packaging, the driver and tracing | [`08-loader-and-cli.md`](08-loader-and-cli.md) |
| 10, 10.0, 10.1 | Dependencies and platforms, linking OpenSSL, libuv | [`10-dependencies-and-platforms.md`](10-dependencies-and-platforms.md) |
| 10.2, 10.2.1, 10.2.2 | Rules for 7h, the scheduler, the loop | [`10-io-scheduler.md`](10-io-scheduler.md) |
| 10.2.3 | Multicore: the rules for N schedulers and the I/O thread (the model is §16) | [`10-io-multicore.md`](10-io-multicore.md) |
| 10.3, 10.3.1 | TLS, TCP | [`10-io-tls.md`](10-io-tls.md) |
| 10.4, 10.5 | Processes, limits the C runtime keeps | [`10-io-processes.md`](10-io-processes.md) |
| 10.6, 10.7 | HTTP parsing; HTTP on the VM (the hybrid split, decisions, client, server, answers, tests) | [`10-io-http.md`](10-io-http.md) |
| 11 | Build, CI and supply chain | [`11-build-ci-supply-chain.md`](11-build-ci-supply-chain.md) |
| 12, 13 | Testing; the PR plan (done) and what is pending; open questions | [`12-testing-and-pr-plan.md`](12-testing-and-pr-plan.md) |
| 14 | VM core invariants: one way to wait, time out, cancel, end and own a handle; the entry rule for the core | [`14-core-invariants.md`](14-core-invariants.md) |
| 15 | VM layers: core, services and adapters plus the driver, the port between them, one header per layer and the CI check (done, roadmap row 7.2.1b) | [`15-layers.md`](15-layers.md) |
| 16 | VM architecture: the threads (schedulers and one I/O thread), the queues, who owns jobs and handles, the life cycle of a task, and what differs from N = 1 as built (roadmap row 7.2.1c) | [`16-architecture.md`](16-architecture.md) |
| 17 | Faster lists: a persistent vector behind `List` (design for roadmap 8d: representation, the C API, costs, tests, PR plan, unboxed Int and Float leaves) | [`17-lists.md`](17-lists.md) |
