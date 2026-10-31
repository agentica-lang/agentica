# Lowering and bytecode: new forms, opcodes and linked programs

Read before changing `compiler/lower/*.agc`, `compiler/bytecode/*.agc` or
adding an opcode.

Read first: `references/vm.md` and `references/vm-c.md`.

## Widen the subset (new form or opcode)

1. Read the matching rules in `docs/vm/02-reference-behavior.md` §2 (reference
   behavior) and `docs/vm/03-ir-and-bytecode.md` §3.3
   (lowering). When a detail is not written down, decide it, write it into §2
   and pin it with a golden.
2. `compiler/lower/lower_*.agc`: lower the form. Emit one IR `step` per former
   AST entry, before the node's children (§3.3). Anything still out of the
   subset keeps failing with `LOWER-UNSUPPORTED` at its span; never miscompile.
   `vm-type?` says which checked types the VM accepts (the scalars, `(Struct
   name)` and `(Enum name ...)` declared in the program, `Json`, `List`, `Map`
   and `Set` of accepted types, `Result` of accepted types or Void, and `Fn`
   over accepted types with an accepted or Void result); a new value type widens
   it.
3. New opcode: append it to `OPCODES` in `compiler/bytecode/bytecode_tables.agc`
   and to `agc_opcode` in `vm/value.h` at the same position (a test compares
   them). An opcode lands with the lowering that emits it, or its PR names
   the lowering that will. The loader and interpreter part
   needs its own `vm-c-critic` review.
4. `vm/loader.c`: validate every operand (register ranges and windows,
   indexes, jump targets, spans). A new file section checks its counts
   against the bytes left and allocates through `load_alloc`, which charges
   the load memory budget. Add one assert per new rule to
   `vm/tests/loader_test.c`; `references/vm-core.md` covers the loader.
5. `vm/interp.c`: implement it with checked accessors only, and `goto reload`
   if it changes the frames or can move the registers (the interpreter is in
   `references/vm-core.md`).
6. Add a fixture to `tests/fixtures/vm/` for each new runtime code or span;
   the diff test sweeps `--max-steps` over it.
7. Update any rule that changed in `docs/vm/`, tick the roadmap item, and
   keep the guide that owns the change current:
   this file for lowering and bytecode, `references/vm-core.md` for the loader
   and the interpreter, `references/vm.md` for the rules every change keeps.

## Linked programs

Imports never reach the VM. The front end of the binary
(`compiler/front_end.agc`) links the imports (`compiler/modules/linker.agc`)
before `check`, so `lower` sees one program whose imported declarations carry
`@N::` prefixes (display names drop them, the bytecode writer uses the display
name). The span table names its source per span: `lower` collects every `source`
a span points to (`note-source!`, entry file first), and `vm/diag.c` prints
`p->sources[span->source]`, so a diagnostic in imported code shows that file
(full path, or `std/queue.agc` for an embedded module). Block function names use
only the file's base name, so two imported files may give equal
`block@m.agc:2:17` names (the `same-basename` fixture); nothing looks functions
up by name.

## Gotchas

- Module constants (the rules are in the grammar's `Module constants`
  section): the Globals section is only a `u32` slot count (at most
  65,535, else
  `BYTECODE-LIMIT`; `ir-program-globals`). `GLOBAL a bx` reads slot `bx`
  into `R[a]` and `GLOBAL_SET a bx` writes it. The loader allows `GLOBAL_SET`
  only in the entry function, and only in a function with no backward jump, and
  when the count is above zero it rejects any `CALL`, `TAIL_CALL` or `CLOSURE`
  of the entry (with a count of 0 the entry is `main`, which a program may
  call). So a lowering that emits them must put every `GLOBAL_SET` in straight
  line code of the entry (`<start>`), which ends with a tail call of `main`,
  and must never call `<start>` or take `&<start>`.
- `"text".bytes` on a string literal without interpolation lowers to one
  `const` of `Ir.Imm.Bytes` (constant kind 7, made once at load) in
  `lower_resolved` (`compiler/lower/lower_expr.agc`), with the steps of the call
  and the literal; an interpolated string keeps the `String.bytes` call.
- How the lowering handles constants. The linked program is flat, so
  `compiler/lower/lower_const.agc` decides from the call graph: the functions
  reachable from `main` (calls, `&f`, blocks) keep the constants they read, and
  the constants those read; only kept constants are initialized. A scalar
  literal constant (one literal, or `-` and a number) is a `CONST` at each read
  and has no slot. Every other constant that any emitted function reads gets a
  slot, numbered in initialization order (`Checked.constants`), so an
  unreachable function still loads; a slot nothing writes stays unset, and
  nothing can run the function that reads it. A kept constant is a function with
  no parameters named by its linked name whose body is `return <value>`. The
  function table is: the declared functions in program order, the kept
  constants' functions in initialization order, `<start>`, then the block
  functions in the order they are lowered (functions first, then constants).
  `<start>` exists whenever the Globals count is above zero, even with no kept
  constant, so the entry is never `main` when slots exist (the loader would
  reject a call of `main` inside `main`); it starts with a `step` and ends with
  `return` after the tail call, as the loader wants of every function. An error
  in an initializer shows the constant's function, then `<start>`, in the stack
  trace (`tests/fixtures/vm/constants-error`).
- Typed JSON: `lower_program.agc` gives each IR struct its JSON field types when
  the struct is decodable (greatest fixpoint, so recursive structs stay in), and
  the bytecode writer interns them into the Types section. `$defs` names and the
  type-argument constant are the linked names (`@2::Point`), not display names:
  `JSON.schema` prints them, and two imported structs can share a display name.
  A new decodable kind (enums) needs a new type kind and loader rules; an
  appended kind keeps the format version, as type kind 7 (`JsonField`) did.
  `JsonField[T]` is only the direct type of a field (`field_type`), and a
  program whose decodable structs use it gets the `JsonField` enum in its table
  even when no expression names it; the loader checks that enum's shape, and
  the encoders find its variants through `agc_program.json_field`.
- `value.with(...)` lowers to one `STRUCT_WITH`: the receiver
  goes in the first slot of a window, the values follow it in field order, and
  the Updates section interns each (struct, field indexes) pair. It beats a
  constructor call for structs of four or more fields (the numbers are in
  `docs/vm-benchmarks.md`), so a new copy-with-changes form should reuse it. The
  copy is charged by size, like `CONCAT`. The VM also checks the receiver's
  struct type and field count at run time, as `agc_struct_def_of` does; the C
  creators already go through `agc_builtin_struct`, so it is a defence.
- Struct and enum table names are display names: the bytecode writer passes the
  linked name through the display name (`types.agc`;
  `docs/vm/02-reference-behavior.md` §2.4). The lowerer keeps the
  unique linked names as its keys and in the IR text. Variant ids are global in
  file order; struct ids and field indexes follow declaration order. Generic
  enums need nothing special: type arguments exist only in the checker.
- `case` reads a local scrutinee in place (no copy) because every test and
  payload read comes before any arm body runs. Arm bodies go through
  `lower-block`, so the `for` element read (`after-step`) still lands after
  the first statement's `step` when a `case` starts a loop body.
- The checker accepts Int literal patterns outside 64 bits
  (`9223372036854775808 ->`); they never match, so the lowerer emits a plain
  jump to the next arm instead of a constant the writer cannot encode.
- Tail calls: the lowerer turns `return f(...)` into `tail-call` when the value
  is a direct user call (`lower_expr.agc`; builtins and calls inside larger
  expressions do not count) and emits no `return` after it. `TAIL_CALL` grows
  the registers to the frame base plus the callee's count first, then `memmove`s
  the argument window to `R[0..]` (windows overlap). It does not touch the
  depth, so a deep tail recursion runs (the depth rule is in
  `docs/vm/05-values-execution-builtins.md` §6.1). Fixtures that must overflow
  need a non-tail call (`stack-overflow.agc` uses `return down(n + 1) + 1`); the
  deep tail-recursion case lives in `tests/test_vm_diff_8.py`. The loader treats
  `TAIL_CALL` as a call for the termination rules.
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
- Ranges: `AGC_T_RANGE` holds an atomic `agc_range` (start, end, exclusive);
  `agc_range_bounds` gives first, last included and non-empty without overflow.
  A `for` over a range literal lowers to a counter loop with no `RANGE`
  (`lower-range-for`); over a Range value it reads `RANGE_BOUNDS` once into
  three slots. The loop variable is the counter slot, and the exit test (`eq`
  with the last value) runs before `add-i`, so the largest Int never overflows.
  The loop top is a `STEP` with the `for` span, so each iteration charges one
  step even with an empty body (never drop the loop); the counting natives call
  `count_step`, shared with `STEP`, before each callback.
  `tests/fixtures/vm/step-limited/` holds huge loops that the extras shard runs
  only with small `--max-steps` values. `Range.each`, `Int.times`, `upto` and
  `downto` are counting native frames (`counting()` in `vm/interp.c`): no list,
  a current value, a last value, a direction and a "more" flag. The range text
  is at most 43 bytes, so `AGC_SCALAR_TEXT` is 48 (a `_Static_assert` keeps it
  at least 44).
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
  the body may assign that local, and the loop iterates the old list.
