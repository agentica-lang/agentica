# Lowering and bytecode: new forms, opcodes and linked programs

Read before changing `src/lower.rkt`, `src/bytecode.rkt` or adding an opcode.

## Widen the subset (new form or opcode)

1. Read the matching rules in `docs/vm/02-reference-behavior.md` §2 (reference behavior) and `docs/vm/03-ir-and-bytecode.md` §3.3
   (lowering). When a detail is not written down, decide it, write it into §2
   and pin it with a golden.
2. `src/lower.rkt`: lower the form. Emit one IR `step` per former AST
   entry, before the node's children (§3.3). Anything still out of
   the subset keeps failing with `LOWER-UNSUPPORTED` at its span; never
   miscompile. `vm-type?` says which checked types the VM accepts (the
   scalars, `(Struct name)` and `(Enum name ...)` declared in the program,
   `Json`, `List` and `Map` of accepted types, `Result` of accepted types or Void, and
   `Fn` over accepted types with an accepted or Void result); a new
   value type widens it.
3. New opcode: append it to `opcodes` in `src/bytecode.rkt` and to
   `agc_opcode` in `vm/value.h` at the same position (a test compares them).
   No opcodes for later PRs.
4. `vm/loader.c`: validate every operand (register ranges and windows,
   indexes, jump targets, spans). A new file section checks its counts
   against the bytes left and allocates through `load_alloc`, which charges
   the load memory budget. Add one assert per new rule to
   `vm/tests/loader_test.c`.
5. `vm/interp.c`: implement it with checked accessors only.
6. Add a fixture to `tests/fixtures/vm/` for each new runtime code or span;
   the diff test sweeps `--max-steps` over it.
7. Update the "Status" note and any rule that changed in `docs/vm/`, tick
   the roadmap items, and keep this guide current.

## Linked programs

Imports never reach the VM. `src/main.rkt` (`compile` and the default run) and
`compile-file` in `tests/vm-diff-common.rkt` run `link-program`
(`src/modules.rkt`) before `check`, so `lower` sees one program whose
imported declarations carry `@N::` prefixes (display names drop them,
`write-bytecode` uses `display-name`). The span table names its source
per span: `lower` collects every `source` a span points to (`note-source!`,
entry file first), and `vm/diag.c` prints `p->sources[span->source]`, so a
diagnostic in imported code shows that file (full
path, or `std/queue.agc` for an embedded module). Block function names use
only the file's base name, so two imported files may give equal
`block@m.agc:2:17` names (the `same-basename` fixture); nothing looks
functions up by name.

## Gotchas

- Typed JSON: `user-tables` in `src/lower.rkt` gives each `ir-struct` its
  JSON field types when the struct is decodable (greatest fixpoint, so
  recursive structs stay in), and `src/bytecode.rkt` interns them into the
  Types section (format version 3). `$defs` names and the type-argument
  constant are the linked names (`@2::Point`), not display names: the
  evaluator's `JSON.schema` prints them, and two imported structs can share
  a display name. A new decodable kind (enums, `JsonField`) needs a new
  type kind, loader rules and a format bump.
- Struct and enum table names are display names: `write-bytecode` passes
  the linked name through `display-name` (`builtins.rkt`), as the
  evaluator does when printing (`docs/vm/02-reference-behavior.md` §2.4). The lowerer keeps the
  unique linked names as its keys and in `format-ir`. Variant ids are global in file order;
  struct ids and field indexes follow declaration order. Generic enums need
  nothing special: type arguments exist only in the checker.
- `case` reads a local scrutinee in place (no copy) because every test and
  payload read comes before any arm body runs. Arm bodies go through
  `lower-block`, so the `for` element read (`after-step`) still lands after
  the first statement's `step` when a `case` starts a loop body.
- The checker accepts Int literal patterns outside 64 bits
  (`9223372036854775808 ->`); they never match, so the lowerer emits a plain
  jump to the next arm instead of a constant the writer cannot encode.
- Tail calls: the lowerer turns `return f(...)` into `tail-call` when the
  value is a direct user call (`tail-call?` in `src/lower.rkt`; builtins
  and calls inside larger expressions do not count) and emits no `return`
  after it. `TAIL_CALL` grows the registers to the frame base plus the
  callee's count first, then `memmove`s the argument window to `R[0..]`
  (windows overlap). It does not touch the depth, so a deep tail recursion
  runs (the depth rule is in `docs/vm/05-values-execution-builtins.md` §6.1). Fixtures that must overflow need a
  non-tail call (`stack-overflow.agc` uses `return down(n + 1) + 1`); the
  deep tail-recursion case lives in `tests/vm-diff-common.rkt`. The loader
  treats `TAIL_CALL` as a call for the termination rules.
- Closures: a `block-lit` becomes an extra IR function after the declared
  ones (`block@file:line:col`), lowered by a fresh `lower-function` context;
  its captures are the visible names its body (nested blocks included)
  reads, found by `referenced-names`, a generic walk over the transparent
  AST structs. Captures sit after the parameters; `closure` copies them
  into the function value (a snapshot). The checker records every block's
  `Fn` type in `#:types`, also when a `List` rule checks it directly. A
  block's final expression statement is its value. `&name` is `closure`
  with no captures, `.call` is `call-value` (window base holds the
  function, result lands there).
- Ranges: `AGC_T_RANGE` holds an atomic `agc_range` (start, end,
  exclusive); `agc_range_bounds` gives first, last included and non-empty
  without overflow. A `for` over a range literal lowers to a counter loop
  with no `RANGE` (`lower-range-for`); over a Range value it reads
  `RANGE_BOUNDS` once into three slots. The loop variable is the counter
  slot, and the exit test (`eq` with the last value) runs before `add-i`,
  so the largest Int never overflows. The loop top is a `STEP` with the
  `for` span, so each iteration charges one step even with an empty body
  (never drop the loop); the counting natives call `charge_steps`, shared with `STEP`, before
  each callback. The evaluator charges the same (`step!` per range
  iteration and per counting callback). `tests/fixtures/vm/step-limited/`
  holds huge loops that the extras shard runs only with small
  `--max-steps` values. `Range.each`, `Int.times`, `upto` and
  `downto` are counting native frames (`counting()` in `vm/interp.c`): no
  list, a current value, a last value, a direction and a "more" flag. The
  range text is at most 43 bytes, so `AGC_SCALAR_TEXT` is 48 (a `_Static_assert` keeps it at least 44).
- Results: `ok`, `error` and `Result.*` are builtins (`vm/builtins.c`);
  `try`, `is-ok` and `result-value` are opcodes. A Result pattern is a
  `variant-pattern` with enum name `"Result"` and variant `"Ok"` or `"Err"`
  (the parser turns `ok(v)`/`error(m)` into it); the lowerer picks the
  Result test from the scrutinee's checked type. `ok()` holds Void and
  prints `ok()`. `Result.unwrap!` fails with the error's own String
  through `agc_fail_text`, which keeps the byte length (the String may hold
  NUL); `agc_outcome` has `message_len`, and `vm/diag.c` prints by length.
  `agc_outcome.text` is never read: it keeps the String reachable while
  `message` points into its data, so do not remove it.
- `SAME` (case literals) is `equal?`, not `=`: Float by `eqv?`, so `-0.0`
  and `0.0` are different patterns.
- A loop body is the target of a backward jump, so it must start with a
  `STEP`. `for` therefore emits its `list-get` right after the first body
  statement's `step` (the `after-step` hook in `lower-statement`), and an
  empty body lowers to just the iterable.
- The `for` iterable is copied into a hidden slot even when it is a local:
  the body may assign that local, and the evaluator iterates the old list.
