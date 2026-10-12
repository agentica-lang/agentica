# Agentica bytecode VM (Aurora): design

This document closes roadmap step 7b. It fixes the decisions that 7c
(lowering), 7d (bytecode emitter) and 7e (VM core) build on, and the library
choices and safety rules that 7h and 7i need. The language does not change.
`grammar.md` stays the contract. The VM is the default backend; the Racket
evaluator (`src/evaluator.rkt`) is frozen and runs only the programs the VM
cannot run yet (`TCP`, `TLS`, `HTTP`, `BDD`, and `agentica test`) until 7i
deletes it. Roadmap step 7b lists each decision in one line; this document
gives the details and reasons. The VM's codename is Aurora (Aurora VM). Only
the docs use it: the binary (`agentica-vm`), the `AGENTICA_VM*` variables, the
`agc_` prefix, `.agcb` and `vm/` keep their names.

## 1. Overview

**Golden outputs, not parity.** The VM is the reference. Each fixture in
`tests/fixtures/vm/` has a golden file, `<name>.expected`, with its exit
code, stdout, program stderr (what the program itself writes, as with
`IO.warn`; the diagnostic after it is not part of this) and diagnostic code
(`RUNTIME-INDEX-OUT-OF-RANGE`, say). The goldens were generated from the
evaluator, and the VM matched every one. A runaway program must stop with
`RUNTIME-STEP-LIMIT` under `--max-steps`, and a run stopped by any smaller
limit gives a prefix of the full stdout and program stderr (12.1). When
behaviour changes on purpose, `make goldens` rewrites the files from the VM
and the PR shows their diff for review. Catch-up work (TCP, TLS, HTTP, BDD on
the VM) is tested with golden outputs and independent Node/Python peers, not
against the evaluator; new features are VM-only and come after 7i.
Diagnostic message text and span, the VM's own stderr wording, OS error
text, exact step counts and the step-limit span may change in a PR that
updates the goldens. An error string that a program prints is program data,
so it is part of the golden. VM messages must be clear and useful for
agents; evaluation rounds judge that, not identity with Racket. Much of this
document records Racket's exact behavior because the first PRs copied it;
that is a description of today's VM, not a rule, and designs kept only to
copy Racket's text or counts may be simplified. For example, the HTTP
adapter does not need to map parser failures onto `http-wire.rkt`'s exact
messages, only onto the same diagnostic or `Result` error kind (10.6). The
turn cost (10.2.1) stays: it is there for fairness. The compiler may
optimize freely as long as the exit code, stdout, program stderr and
diagnostic codes in the goldens stay the same: inlining, constant folding,
common subexpression elimination, loop-invariant code motion, and merging or
moving `STEP`s (a runaway loop must still hit `RUNTIME-STEP-LIMIT`; step
counts may change).

```text
.agc files
  -> lexer, parser, module linker, checker      (Racket, unchanged)
  -> checked AST + expression type table
  -> src/lower.rkt      IR: functions, slots, typed ops, labels, spans
  -> src/bytecode.rkt   bytecode: instructions, constants, tables, spans
  -> .agcb file (binary, versioned)
  -> vm/ (C11 + Boehm GC): load, validate, run
```

| Place | Owns |
|---|---|
| `src/checker.rkt` | One addition in 7c: it can fill a caller-supplied `eq?` hash from expression node to its checked type. |
| `src/lower.rkt` (7c) | Checked program to IR. Resolves names to slots and indexes, makes types explicit, keeps spans, converts closures. |
| `src/bytecode.rkt` (7d) | IR to bytecode: label resolution, constant pool, builtin imports, struct, enum, JSON type and span tables, step merging, binary writer and reader. |
| `src/main.rkt` | `--dump-ir` (7c), `compile` (7d), running on the VM by default with the evaluator fallback (7i). Printing and exit codes stay here. |
| `vm/` (7e) | The C VM: loader, values, interpreter loop, builtins, JSON, diagnostics, CLI driver. Builds `dist/agentica-vm`. |

**Status.** The vertical slice, the Float PR, the Strings PR, the macOS
and Windows CI, the Lists PR, the structs, enums and `case` PR and the
Result PR, the Maps PR, the closures PR, the IO and System PR, the
library PR and both parts of the JSON PR (12.2 items 1 to 4, 5a to 5e, 6a,
6b and 7) are in, and so is the
tail-call PR (after the list in 12.2). The VM covers Int, Float, Bool, Nil and
String values, user structs and user enums (generic and recursive ones too,
imported ones included), `Result[T]` of any of them (and `Result[Void]`),
`Json` values, `List[T]` of any of them (lists of lists too), and `Map[K, V]` with Int or
String keys and any of them as values, function values `Fn[...]` of them
(blocks `do |x| ... end` with their captures, `&name` of local and imported
functions, `f.call(...)`),
locals, their operators (Float `+ - * /`, unary minus and comparisons with
IEEE semantics; String `+`, `==` and `!=`), `if`/`elsif`/`else`, `while` with
`break` and `next`, `for x in xs` with `break` and `next`, list literals,
indexing `xs[i]`, map literals, map indexing `m[key]`, struct construction and field access, enum constructors,
`case` with literal, `_`, variant and Result patterns, `ok`/`error`, the
`Result.*` builtins, `try`, user functions, calls, tail
calls (`return f(...)` reuses the frame, 6.1), `return`, the callback
builtins `List.map`, `filter`, `reduce`, `each`, `any?`, `all?` and
`sort_by` (resumable, 4.3), ranges (Phase 8a: `a..b`, `a...b`, `for`
over a range, the `Range` builtins and `Int.times`, `upto`, `downto`, 3.3,
4.3, 5.1), interpolation,
`x.to_s` and `x.inspect` of those values, `puts`/`print`/`IO.puts`/
`IO.print`/`IO.warn`/`IO.inspect` of any of them, blocking stdin
(`gets`, `gets!`, `IO.read`, `IO.read_bytes`, `IO.eof?`), `IO.flush`,
`System.args` and `System.exit`, the `List` and `Map` library
(`List.size`, `append`, `set`, `repeat`, `concat`, `take`, `drop`, `at`,
`reverse`, `sort`; `Map.has_key?`, `keys`, `values`, `size`, `put`, `get`
with or without a default, `delete`; also as methods such as `xs.size` and
`m.keys`; 12.2 item 6b), and every `String` builtin of the catalog
(`length`, `upcase`, `downcase`, `trim`, `split`, `join`, `contains?`,
`starts_with?`, `ends_with?`, `replace`, `slice`, `index_of`, `at`,
`reverse`, `code`, `from_code`, `from_int`, `from_float`, `from_bytes`,
`to_int`, `to_int!`, `to_float`, `to_float!`, 2.3), and the `Float`,
`Time` and `Random` builtins (`Float.from_int`, `to_int`, `to_int!`, also
as `n.to_f`, `x.to_i` and `x.to_i!`; `Time.now_ms`, `monotonic_ms`;
`Random.int`, `Random.float` with the VM's own seeded generator of 7.4),
and every `JSON` builtin (`JSON.parse`, `encode`, `from`, `object`,
`array`, `null`, `null?`, `get`, `at`, `string`, `int`, `float`, `bool`,
`list`, also as methods such as `j.get("a")`, and the typed `decode` and
`schema` of user structs through the Types section; 2.4, 2.6, 2.7, 4.6,
5.1). Linked programs run: relative, `std/` and
`pkg/` imports are resolved and linked by the front end
(`src/modules.rkt`) into one program before lowering, so the bytecode holds
no imports, and code from an imported file keeps that file's spans (4.6).
On Linux the first part of 7h runs too: the libuv event loop and the
resource registry (10.2.2) with every `File`, `Dir` and `Path` builtin
(`File.open`, `read_bytes`, `read_line`, `write`, `write_bytes`, `flush`,
`close`, `read_text`, `write_text`, `append_text`, `stat`; `Dir.list`,
`mkdir`; `Path.cwd`, `join`, `resolve`), `FileHandle` values and the
`FileInfo` record (2.8), and the tasks PR of 7h: `Task.spawn`,
`Task.await` and `Task.sleep` on one scheduler (N=1) with a run queue,
turns and turn costs, per-task `Random`, and stdin, file jobs and sleeps
that park only their own task (10.2.1 to 10.2.3, "As built"), and the
processes PR of 7h: every `Process` builtin (`Process.spawn`, `send`,
`send_bytes`, `read_line`, `read_bytes`, `close_stdin`, `wait`, `close`)
and `Process` values, behind the VM's own `--allow-run` (10.4). Runtime diagnostics come in the plain,
`--ai` and `--json` formats. The lowerer rejects everything else with
`LOWER-UNSUPPORTED` at the node's span (3.5) instead of guessing. Each later
PR widens the subset; this document describes the full design, and the notes
marked "In the slice" say where the code is still narrower.

**Trust model.** A `.agcb` file is untrusted input. Whatever it contains, the
VM must not have memory errors, must not run child processes unless the VM
itself got `--allow-run`, and must stop within `--max-steps` when a limit is
given. A file that passes the loader can still compute wrong values or end
with `RUNTIME-INTERNAL`; that is the whole guarantee. `--max-steps` bounds
instructions, not memory: one `CONCAT` or `INSPECT` costs time and memory in
proportion to its strings, so a file can double a string per instruction
and reach the out-of-memory exit (70, 6.3) in a few dozen steps. A program
on the evaluator grows strings the same way. Printing a list costs time and
memory in proportion to its text, and lists can share items. A program with
chained bindings `a1 = [a0, a0]`, `a2 = [a1, a1]`, ... (each a new type one
level deeper, since a variable's type is fixed) has text exponential in the
number of bindings, and a file can run `LIST r0 r0 2` in a loop; printing
such a list ends in the same out-of-memory exit (the evaluator also runs out
of memory). A heap cap is an open question (13).


## Files

The design is split by topic. Section numbers stay as they were, so a reference such as `§10.4` still finds its place: look up the number below.

| § | Topic | File |
|---|---|---|
| 1 | Overview: parity, the pipeline, status, trust model | this file |
| 2 | Reference behavior (today's VM): steps, numbers, strings, printing, diagnostics, JSON, files | [`02-reference-behavior.md`](02-reference-behavior.md) |
| 3, 4 | IR (7c) and bytecode (7d): machine model, instructions, calls, builtin imports, file format | [`03-ir-and-bytecode.md`](03-ir-and-bytecode.md) |
| 5, 6, 7 | Values in C, execution (stack, failure, out of memory) and builtins in C | [`05-values-execution-builtins.md`](05-values-execution-builtins.md) |
| 8, 9 | Loader safety; CLI and packaging | [`08-loader-and-cli.md`](08-loader-and-cli.md) |
| 10, 10.0, 10.1 | Dependencies and platforms, linking OpenSSL, libuv | [`10-dependencies-and-platforms.md`](10-dependencies-and-platforms.md) |
| 10.2, 10.2.1, 10.2.2 | Rules for 7h, the scheduler, the loop | [`10-io-scheduler.md`](10-io-scheduler.md) |
| 10.2.3 | Multicore: M:N schedulers | [`10-io-multicore.md`](10-io-multicore.md) |
| 10.3 to 10.6 | TLS, processes, limits the C runtime keeps, HTTP parsing | [`10-io-tls-processes-http.md`](10-io-tls-processes-http.md) |
| 11 | Build, CI and supply chain | [`11-build-ci-supply-chain.md`](11-build-ci-supply-chain.md) |
| 12, 13 | Testing and first PRs (12.2 is the PR plan); open questions | [`12-testing-and-pr-plan.md`](12-testing-and-pr-plan.md) |
