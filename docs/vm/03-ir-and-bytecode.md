## 3. IR

The lowerer (`compiler/lower/lowering.agc`) turns the checked program into IR.
Each stage returns data or one diagnostic.

### 3.1 Types from the checker

The checker records the type of every expression in a table. The lowerer needs
it for field indexes (which depend on the struct type),
for `LIST_GET` or `MAP_GET`, for typed arithmetic and for unary minus. Each
typed op still checks its tags at run time (4.2).

### 3.2 Structures

The IR is data, defined in `compiler/lower/ir.agc`: `Program` (sources,
structs, enums, functions, entry, globals, span), `Function` (name, params,
captures, slots, body, span), `Instr` (op, args, imm, name, spans), `StructDef`
(linked name, field names in declaration order, field types) and `EnumDef`.

- `body` is a flat list of `Instr`; a label is an `Instr` with op `label` and
  one argument, the label id. `--dump-ir` prints it.
- Slots are the VM registers, numbered per function: parameters `0..p-1`,
  captures `p..p+c-1`, then locals and temporaries. Temporaries follow a stack
  discipline, so a call's arguments are the highest live slots (4.3).
- A `StructDef` holds its field types only when every field is decodable
  (`decodable`). Only `JSON.decode` and `JSON.schema` read them.
- Each instruction has a list of spans: the span its diagnostic uses (operator
  for arithmetic, index expression for indexing, call span for calls). A merged
  `step` and `call-builtin` have several (4.1).

### 3.3 Lowering rules

- **Form:** Statements, expressions
  - **Lowering:** `step` with the node span, then the node's code.

- **Form:** Literals, names
  - **Lowering:** `const` for a literal. A local is read from its slot. Only
    call windows need `move`.

- **Form:** `-` over literal 2^63
  - **Lowering:** `step`, `step`, `const INT64_MIN`.

- **Form:** `and` / `or`
  - **Lowering:** Left side into the target, `jump-if-false` / `jump-if-true`
    past the right side.

- **Form:** Arithmetic, ordering
  - **Lowering:** Typed ops. `a > b` is `lt b a`, `a >= b` is `le b a` (NaN
    stays false).

- **Form:** `if` / `elsif` / `else`
  - **Lowering:** Conditional jumps over each branch.

- **Form:** `while`
  - **Lowering:** Head label, condition (starts with its `step`),
    `jump-if-false` to the exit, body, `jump` to the head. `next` jumps to the
    head, `break` to the exit.

- **Form:** `for x in a..b`, `a...b`
  - **Lowering:** No `Range` value. The counter `i` starts at `a`, `last` is
    `b`. The test `le-i` (`lt-i` for `...`) runs before the body. For `...`,
    `last` is `b - 1` (`sub-i`, after the nonempty test; b is above a, so no
    overflow). The loop top is a `step` with the `for` span, one per iteration.
    After the body (the target of `next`) the loop compares `i` with `last` and
    only then adds 1, so a range ending at the largest Int never overflows.

- **Form:** `for x in r` (a `Range` value)
  - **Lowering:** `range-bounds` once into the counter, `last` and non-empty
    flag, then the same loop. Assigning `r` in the body does not change the
    loop.

- **Form:** `a..b`, `a...b` as a value
  - **Lowering:** `step`, then `range dst w kind` (kind 0 for `..`, 1 for
    `...`).

- **Form:** `for x in s` (a `Set` value)
  - **Lowering:** `call-builtin Set.to_a` on the hidden slot, then the loop of
    `for x in xs` over the list. The set is read once, so assigning `s` in the
    body does not change the loop.

- **Form:** `for x in xs`
  - **Lowering:** The iterable goes into a hidden slot (a `move`, even for a
    local, since the body may assign it). Hidden index, length and one. The body
    starts with the `step` of its first statement, then `list-get`. The backward
    jump lands on a `STEP`. `next` jumps to the increment, `break` past the
    test. An empty body charges nothing.

- **Form:** Functions
  - **Lowering:** One IR function each. Falling off the end returns Void.

- **Form:** Calls
  - **Lowering:** A builtin gives `call-builtin` (including the higher-order
    `List` functions, 4.3). A user function gives `call`, or `tail-call` when it
    is the value of a `return`.

- **Form:** Structs, enums
  - **Lowering:** `step` (construct span), fields evaluated in written order
    straight into their declared slots, then `struct`. An enum constructor is
    `step`, payload, `enum` with the global variant id; a nullary variant is
    `enum dst dst v`. Field access is `step`, target, `field` with the declared
    index.

- **Form:** Struct update `v.with(f: x)`
  - **Lowering:** `step` (the update span), a window with the receiver in its
    first slot and the new values after it, in the order of the struct's fields
    (each value is evaluated in written order into its slot), then `struct-with
    dst window s fields`: one instruction copies the receiver and overwrites
    those fields. The receiver is evaluated once, before the values.

- **Form:** Lists, maps
  - **Lowering:** `list` / `map` from consecutive slots (a map's key before its
    value). A literal longer than 255 elements is built in chunks joined with
    `List.concat`; a longer map literal is extended with `Map.put`. Literals
    need at most 256 slots (list) or 511 (map) beside their elements. An empty
    literal is `list dst dst 0` or `map dst dst 0`.

- **Form:** Indexing
  - **Lowering:** `list-get` or `map-get` by the target's checked type, after a
    `step` for the index node. `RUNTIME-INDEX-OUT-OF-RANGE` and
    `RUNTIME-KEY-NOT-FOUND` point at the index expression's span.

- **Form:** `case`
  - **Lowering:** The scrutinee is evaluated once. Each arm has a test (`const`
    + `same` for literals, `is-variant`, `is-ok`), `jump-if-false` to the next
    arm, payload into arm slots (`_` skipped), then the body. Patterns charge no
    steps. `_` has no test. An Int literal outside 64 bits can never match, so
    its test is a plain `jump`. A Result pattern tests `is-ok`, and its binding
    reads `result-value` (the value or the message).

- **Form:** `try`
  - **Lowering:** `step` (the `try` span), the operand, then `try dst src`: on
    an error, return that Result from the function (the block, inside a block).
    `return try f(...)` is not a tail call. A `try` that the checker found in
    the block of a `Lazy` method (`Checked.step_tries`) is `try-step dst src`
    instead.

- **Form:** `ok`, `error`, `Result.*`
  - **Lowering:** Builtin calls. `Result.Ok(x)` and `Result.Err(m)` are `ok` and
    `error` calls after parsing.

- **Form:** Interpolation
  - **Lowering:** `step`, then the first part into the target and each later
    part into the next slot, then `concat`. An expression part that is not a
    String is followed by `to-text`. String parts charge no step.

- **Form:** `.inspect`, `.to_s`
  - **Lowering:** `inspect`. `.to_s` follows the checker's resolution: the
    receiver for String, `String.from_int` or `String.from_float` for Int and
    Float, a one-part interpolation otherwise.

- **Form:** `JSON.decode(s, T)`, `JSON.schema(T)`
  - **Lowering:** The type argument is charged one step and lowers to a String
    constant with the struct's linked name (`@2::User` when imported). The
    builtin finds the struct by that name in the Types section. A target that is
    not decodable is rejected by the checker (`CHECK-NOT-DECODABLE`).

- **Form:** `&name`
  - **Lowering:** `step`, then `closure dst fn` with no captures.

- **Form:** `f.call(...)`
  - **Lowering:** `step` (invoke span), the target into the window base, the
    arguments after it, then `call-value base n`.

- **Form:** Blocks
  - **Lowering:** `step` (block span), then closure conversion (3.4).

- **Form:** `return`
  - **Lowering:** The value, or a Void constant. Inside a block it leaves the
    block. A direct call to a user function (local or imported) ends in
    `tail-call` instead of `call`, wherever the `return` is: in branches, `case`
    arms and loop bodies. Builtin calls, calls inside a larger expression
    (`return 1 + f(n)`) and `return try f(...)` are not tail calls.

- **Form:** Assignment to an existing local
  - **Lowering:** Value into a temporary, then `move`. Lowering straight into
    the local would let `x = y and x` read the new `x`. A new local is lowered
    straight into its slot.

The builtin record types (`FileInfo`, `Header`, `HttpRequest`, `HttpResponse`,
`HttpClientOptions`, `HttpServerOptions`, `ProcessOutput`) join the struct table
only when the program names them or a checked type mentions them. Then they
lower like user structs (`compiler/lower/lower_program.agc`).

### 3.4 Closure conversion

- A block becomes an IR function named `block@file:line:col` (the source file
  name without its directory). Block functions follow the declared functions, in
  the order the lowerer meets them. Its parameters are the block parameters.
- Its captures are the names used by a `name-ref` anywhere in its body (nested
  blocks included) that are visible where the block is created, in
  first-appearance order. This is enough because a block can only read captured
  variables (`CHECK-CAPTURED-ASSIGNMENT`) and no name may shadow a visible one
  (`CHECK-SHADOWED-NAME`).
- At creation the captured values go into consecutive slots and `closure` copies
  them into the function value. This is a snapshot: a later assignment to the
  outer local does not reach the block.
- At a call, the VM copies the captures into the callee's capture slots.
- A block returns the value of its final expression statement, or Void. `try`
  inside a block returns from the block.
- `break` and `next` never cross a function or block (`CHECK-LOOP-CONTROL`), so
  they are plain jumps.

### 3.5 Lowering diagnostics

The lowerer and the emitter never raise. Their codes have their own prefixes, so
they cannot clash with the language codes.

- **Code:** `LOWER-UNSUPPORTED`
  - **Raised by:** `compiler/lower/lowering.agc`
  - **Meaning:** A form or a type the lowerer does not handle yet (`vm_type?` in
    `compiler/lower/lower_state.agc`). The span is the first such node.

- **Code:** `LOWER-INTERNAL`
  - **Raised by:** `compiler/lower/lowering.agc`
  - **Meaning:** A failed internal assumption inside the lowerer (a bug), at the
    program span.

- **Code:** `BYTECODE-LIMIT`
  - **Raised by:** `compiler/bytecode/bytecode_writer.agc`
  - **Meaning:** A function needs more than 65535 registers, or the program has
    more than 65535 structs or variants (4.4).

- **Code:** `BYTECODE-INTERNAL`
  - **Raised by:** `compiler/bytecode/bytecode_writer.agc`
  - **Meaning:** An impossible IR reaches the writer (a bug), at the program
    span.

A builtin call lowers only when its implementation key is in `VM_BUILTINS`
(`compiler/lower/lower_tables.agc`). A builtin outside that list is
`LOWER-UNSUPPORTED` at the
call span. Today the list covers every catalog key.

`agentica compile` and `--dump-ir` print them like other diagnostics and exit 1.
A list literal nested `d` levels deep needs about `d` registers, so nesting
beyond about 65,000 levels in one literal is `BYTECODE-LIMIT`. Lowering stays
linear in the depth.

## 4. Bytecode

### 4.1 Machine model

A register machine. Each function declares its register count. Locals and
temporaries are registers, so the IR's slots become registers one for one. Each
instruction is 8 bytes:

```c
typedef struct { uint16_t op, a, b, c; } agc_instr;   /* bx = b | (uint32_t)c << 16 */
```

`bx` is a 32-bit index. A parallel `uint32_t` array gives each instruction one
span index `s`. An instruction that needs several spans (`STEP n`,
`CALL_BUILTIN`) uses the entries `s, s+1, ...` after it.

### 4.2 Instruction set

`R[x]` is a register, `K[x]` a constant. Each instruction reads values through
checked accessors (5.2). A wrong tag is `RUNTIME-INTERNAL`, never undefined
behavior.

- **Group:** Move
  - **Opcodes:** `MOVE a b`, `CONST a bx`
  - **Meaning:** `R[a] = R[b]`, `R[a] = K[bx]`

- **Group:** Budget
  - **Opcodes:** `STEP a`
  - **Meaning:** Charge `a` steps. With `k < a` left, fail at span `s + k`.

- **Group:** Int
  - **Opcodes:** `ADD_I SUB_I MUL_I DIV_I MOD_I`, `NEG_I`
  - **Meaning:** Checked int64 ops. Fail at the operator span.

- **Group:** Float
  - **Opcodes:** `ADD_F SUB_F MUL_F DIV_F`, `NEG_F`
  - **Meaning:** IEEE. `DIV_F` fails on a zero divisor.

- **Group:** Text
  - **Opcodes:** `CONCAT`, `TO_TEXT`, `INSPECT`
  - **Meaning:** String `+`; text form (2.4); debug form (2.4).

- **Group:** Logic, compare
  - **Opcodes:** `NOT`; `LT_I LE_I LT_F LE_F`; `EQ NE`; `SAME`
  - **Meaning:** Bool not; ordering; `=` for numbers and `equal?` for String,
    Bool, Nil and Range; `SAME` is the `case` literal test (`eqv?` for Float).

- **Group:** Jump
  - **Opcodes:** `JUMP bx`, `JUMP_IF_FALSE a bx`, `JUMP_IF_TRUE a bx`
  - **Meaning:** Go to `bx`; test Bool `R[a]`.

- **Group:** Call
  - **Opcodes:** `CALL a bx`, `CALL_VALUE a b`, `CALL_BUILTIN a bx`, `TAIL_CALL
    a bx`, `RETURN a`, `CLOSURE a bx`
  - **Meaning:** 4.3.

- **Group:** Data
  - **Opcodes:** `LIST a b c`, `LIST_LEN a b`, `LIST_GET a b c`, `MAP a b c`,
    `MAP_GET a b c`, `STRUCT a b c`, `STRUCT_WITH a b c`, `FIELD a b c`, `ENUM a
    b c`, `IS_VARIANT a b c`, `PAYLOAD a b c`
  - **Meaning:** Lists, maps, structs and enums. `LIST_GET` and `MAP_GET` fail
    at the index span. `STRUCT_WITH`: `R[a]` is a copy of the struct in `R[b]`
    whose fields listed in update entry `c` (4.6) are overwritten by `R[b+1]`,
    `R[b+2]`, ... in that order.

- **Group:** Result
  - **Opcodes:** `TRY a b`, `IS_OK a b`, `RESULT_VALUE a b`, `TRY_STEP a b`
  - **Meaning:** `TRY`: if `R[b]` is an error, return it, else `R[a]` = its
    value. `TRY_STEP` (opcode 52) is `TRY` in the block of a `Lazy` method: on
    an error it also sets `escaped` on the stepper of the frame below (4.3), so
    the terminal ends the pipeline with that error instead of taking it as the
    block's value. The frame below must be the native frame of a `Lazy`
    terminal (`agc_stepper.lazy`), else `RUNTIME-INTERNAL`: another stepper
    (`File.each_line`, `Profile.measure`) or a native loop such as `List.map`
    is refused.

- **Group:** Range
  - **Opcodes:** `RANGE a b c`, `RANGE_BOUNDS a b`
  - **Meaning:** `RANGE` from Int `R[b]` to `R[b+1]`, `c` 0 for `..`, 1 for
    `...`. `RANGE_BOUNDS`: first value into `R[a]`, last included value into
    `R[a+1]`, non-empty flag into `R[a+2]`.

- **Group:** Global
  - **Opcodes:** `GLOBAL a bx`, `GLOBAL_SET a bx`
  - **Meaning:** `R[a] = G[bx]` and `G[bx] = R[a]`, where `G` is the table of
    the Globals section (4.6), the module constants of
    the grammar's `Module constants` section. `GLOBAL` of a slot that was
    never
    set is `RUNTIME-INTERNAL`.

There are 53 opcodes. Everything else, including `ok`, `error`, `puts` and every
module function, is a builtin. Opcode numbers are positions in one list shared
by `OPCODES` in `compiler/bytecode/bytecode_tables.agc` and `agc_opcode` in
`vm/value.h`. New opcodes are appended at the end. An appended opcode does not
bump the format version, and an older VM rejects it as unknown.

Fused STEP: after it has checked a file, the loader rewrites each `STEP` whose
next instruction is `MOVE`, `CONST`, `FIELD`, `LIST_GET`, `IS_VARIANT`,
`GLOBAL`, `ADD_I`, `SUB_I`, `MUL_I`, `LT_I` or `RETURN` into a fused opcode
(`agc_fused_opcode` in `vm/value.h`, numbered from `AGC_OP_COUNT`) and leaves
the next instruction in place. The fused opcode is that `STEP` (same charge,
same stop and span, same yield, before the next instruction runs), then the
next instruction without a second dispatch. A jump to the next instruction, or
a resume after the yield, runs it alone. Steps and stop points do not change,
and no file holds a fused opcode: the loader rejects one as unknown. The
profile (`docs/vm/08-loader-and-cli.md` §9) runs every fused `STEP` as a plain
`STEP`, so its counts are those of the file's opcodes.

Details that code and tests rely on:

- `EQ` and `NE` accept pairs of Int, Float, Bool, Nil, String or Range (ranges
  by start, end and kind). Other pairs are `RUNTIME-INTERNAL`. The checker
  allows `==` only on those types, so lists, maps, structs, enums and Results
  never reach `EQ` or `SAME`.
- `SAME` is false when the tags differ. Float compares by `eqv?`, so `-0.0` does
  not match `0.0` and NaN matches NaN.
- `LIST` copies its window into a new immutable list. `LIST_GET` checks
  `0 <= i < len` on the int64 before using it.
- `MAP` puts its `c <= 255` pairs in order with the rule of `Map.put`: a
  repeated key keeps its first position and takes the last value. A key that is
  not Int or String (only in a hand-made file) is `RUNTIME-INTERNAL`.
- `STRUCT` and `ENUM` take their sizes from the tables. A nullary `ENUM` returns
  the variant's shared value. `IS_VARIANT` compares the global variant id, which
  is unique per enum declaration.
- `FIELD` and `PAYLOAD` read item `c` of the value's own `n`. Past it is
  `RUNTIME-INTERNAL`.
- `STRUCT_WITH` allocates one struct of the receiver's size and copies the
  receiver into it, then writes the updated fields. The receiver must be the
  struct type that update entry `c` names, with the field count of that type's
  table entry (a hand-made file may put another value there); anything else is
  `RUNTIME-INTERNAL` (5.2). The loader has checked every field index of the
  entry against the struct's field count, so the writes need no bounds test.
  Unlike `STRUCT`, the copy is linear in the field count, so the instruction
  charges `n * sizeof(agc_value)` bytes of cost, like `CONCAT`.
- `GLOBAL` and `GLOBAL_SET` index the Globals table. The loader has checked
  that `bx` is below the slot count, so the interpreter does not check it again,
  as for `CONST`. A slot starts as zeroed memory, which is tag 0, `AGC_T_VOID`.
  No module constant has type `Void`, so tag 0 means "never set", and `GLOBAL`
  of such a slot is `RUNTIME-INTERNAL` (only a hand-made file can do it, or a
  `GLOBAL_SET` of a `Void`, which unsets the slot again). Neither instruction
  charges cost beyond the `STEP`s of the function that holds it, as `MOVE` and
  `CONST` do. `GLOBAL_SET` is the only instruction that writes to the loaded
  program. The loader allows it only in the entry function, which has no
  backward jump (4.6) and cannot be called when the table is not empty, so each
  `GLOBAL_SET` runs at most once, in the main task, before the entry hands over
  to `main`. `10-io-multicore.md` §10.2.3 and `16-architecture.md` §16.7 say
  why that makes the table safe to share.
- An error in `TRY` returns from the frame like `RETURN`. An error in a `TRY` of
  the entry function is `RUNTIME-INTERNAL` (the checker allows `try` only in
  functions that return Result).
- `CALL_VALUE` checks that `R[a]` is a function value whose function takes
  exactly `b` parameters and has as many captures as the value holds.

### 4.3 Calls, call windows and resumable builtins

- `CALL a bx` starts the callee's frame at the caller's `R[a]`, so the arguments
  are already its parameters. The result lands in `R[a]`. `CALL_VALUE` does the
  same one register higher and checks the parameter count at run time; a
  closure's captures follow the parameters. The lowerer keeps call windows at
  the top of the live registers. A corrupt file that breaks this mixes up values
  but stays memory safe.
- `TAIL_CALL a bx` replaces the current frame. It grows the registers if the
  callee needs more, moves the arguments down to the frame's base and jumps to
  the callee. The callee's `RETURN` writes the result register of the `CALL`
  that made the frame. `CALL`, `RETURN` and `TAIL_CALL` charge no steps. The
  lowering puts the same `step`s before a tail call as before a call, so step
  counts do not change.
- `List.map`, `filter`, `reduce`, `each`, `any?`, `all?` and `sort_by` are
  resumable builtins. `CALL_BUILTIN` pushes a native frame whose state lives in
  a GC object that bytecode cannot reach. The interpreter pushes each callback
  as a normal frame and resumes the native frame when the callback returns. No
  builtin calls the interpreter from C, so a task can block inside a callback.
  Iteration is bounded by the list length. `sort_by` collects all keys first,
  then sorts.
- `File.each_line` is a resumable builtin that also parks between callbacks (a
  stepper). `CALL_BUILTIN` runs the builtin function, which checks its arguments
  and installs a step function on the task; then the interpreter pushes a native
  frame. Each time that frame runs, the step function says what comes next: call
  the block with a String, park the task while a read or the final close runs,
  or end with the Result. What a callback or a woken job produced is given back
  to the step function, so no C code calls the interpreter, and the task can
  block inside the callback, like the `List` builtins. A native frame on top of
  the call stack is resumed at the start of the task's next turn. Each block
  call costs one step, charged as for the other native frames, and the turn
  cost of the bytes read.
- The terminals of `Lazy` (`to_a`, `each`, `reduce`, `find`; `vm/lazy.c`) are
  steppers too, with no block of their own: each call names its function
  (`AGC_STEP_CALL` with `fn`, `AGC_STEP_CALL2` for two arguments). Each item
  that enters the first stage costs one step (`agc_step_turn`); each stage it
  passes without a callback, and each item `to_a` keeps, charges one unit of
  turn cost, an `each_cons` window its size, and a terminal's start the depth
  of the recipe (`agc_charge`). When the step count or the turn cost
  (`agc_turn_charge`) ends the turn, the step returns `AGC_STEP_YIELD`: the
  native frame stays on the stack and runs again at the task's next turn. So
  `--max-steps`, the turns of other tasks and a cancel reach a pipeline that
  calls no block. These steps run without `rt->sync` (`agc_stepper.unlocked`):
  they touch only the run of the calling task. Over `File.foreach` or
  `ch.lazy` they take it only around the line reader of `File.each_line` and
  `agc_channel_receive`, which may park inside that section; the step then
  returns `AGC_STEP_WAIT` with the lock dropped, and the file is closed before
  every `AGC_STEP_END`. `write_lines` is a terminal with a line writer
  (`agc_writer_next` in `vm/files.c`): it opens its file before the first item,
  parks on each write job and on the close, under the same lock rule. A
  callback that returns through a failed `TRY_STEP` sets `escaped` on the
  stepper; the terminal clears it and ends with that error.
- `Range.each`, `Int.times`, `Int.upto` and `Int.downto` are counting native
  frames. Before each callback they charge one step at the call span, the same
  check as `STEP`. They stop by comparing with the last value before adding, so
  counting up to the largest Int never overflows, and memory stays O(1).
- Native frames do not count toward call depth (6.1).

### 4.4 Steps

The emitter merges adjacent `step`s with no label between them into one
`STEP n`, and splits runs above 65535 because the count is 16 bits. Struct and
variant ids are 16-bit operands too, so more than 65535 of either is
`BYTECODE-LIMIT`. Any change to charge points is allowed if every loop and
recursion still charges at least one step per round, so a runaway program still
stops with `RUNTIME-STEP-LIMIT`. The optimization items are in
`docs/roadmap/07-vm.md`.

### 4.5 Builtin imports

The file lists the builtins it uses as `(key, arity)`. The key is the
implementation key in `compiler/catalog/builtins_data.agc`, not the written
name: `puts` and `IO.puts` both import `"puts"`. Overloads such as `Map.get` and
`ok` are separate entries by arity. The loader resolves each pair against the C
table and rejects unknown pairs. There are no internal helper builtins with one
exception: `__fail_arg(code, index, message)` is a prelude-only builtin (4.7).
Its name starts with `__`, no program can call it (the checker knows it only in
the files of the prelude), and the loader rejects a call to it from a function
that has no prelude flag. `List.concat`, which the lowerer emits for long list
literals, is the catalog builtin of that name.

### 4.6 File format

All integers are little-endian. `str` is a `u32` byte length plus UTF-8 bytes.
Sections come in this fixed order. Each starts with a `u32` count, except the
header and the entry.

- **Section:** Header
  - **Entry:** magic `"AGCB"`, `u32` format version (6), `str` Agentica version
    (the `VERSION` file)

- **Section:** Sources
  - **Entry:** `str` name, `str` full text. The name is the path from the folder
    of the entry file (`main.agc`, `lib/util.agc`, `../shared/x.agc`) or
    `std/NAME.agc` (a user file under a `std/` folder is `./std/NAME.agc`),
    never an absolute path, so the bytes do not depend on where the program
    lives (§18.3). The VM prints it in diagnostics and stack traces, under
    `--source-root DIR` when given (§9).

- **Section:** Spans
  - **Entry:** `u32` source, start line, start column, end line, end column.
    Span 0 is the program span.

- **Section:** Constants
  - **Entry:** `u8` kind (0 Void, 1 Nil, 2 false, 3 true, 4 Int, 5 Float, 6
    String), then `i64`, `f64` bits or `str`

- **Section:** Structs
  - **Entry:** `str` display name, `u32` field count, each field's `str` name

- **Section:** Types
  - **Entry:** `u32` type count. Each entry is a `u8` kind (0 Int, 1 Float, 2
    Bool, 3 String, 4 List, 5 Map with String keys, 6 Struct) and, for 4 to 6, a
    `u32` operand: the item or value type index (smaller than the entry's own)
    or the struct index. Then a `u32` count of decodable structs, each a `u32`
    struct index (increasing), the `str` linked name and one `u32` type index
    per field.

- **Section:** Enums
  - **Entry:** `str` display name, `u32` variant count, each `str` name and
    `u32` arity. Variants are numbered globally in file order.

- **Section:** Updates
  - **Entry:** `u32` struct index, `u32` field count k (1 to the struct's field
    count), k `u32` field indexes, strictly increasing and below the struct's
    field count. One entry per distinct set of fields of a struct that a
    `.with(...)` changes; `STRUCT_WITH` names an entry.

- **Section:** Globals
  - **Entry:** `u32` slot count, nothing else (at most 65,535). The slots are
    the module constants (the grammar's `Module constants` section); the
    initializers are ordinary functions that the entry calls. A program without
    constants writes 0.

- **Section:** Builtins
  - **Entry:** `str` name, `u32` arity

- **Section:** Functions
  - **Entry:** `str` name, `u32` params, captures, registers, span, prelude flag
    (0 or 1, 4.7), instruction count, the instructions, then one `u32` span
    index per instruction

- **Section:** Entry
  - **Entry:** `u32` index of the entry function: `main`, or `<start>` in a file
    with module constants, which sets the slots and tail-calls `main`

- The Sources section embeds the full source texts, so the VM prints diagnostics
  without reading files. A linked program has one entry per file a span points
  into: the entry file first, then the others in the order the lowerer meets
  them. Each keeps the name the front end gave it (`std/` modules by their
  `std/...` key), so a diagnostic in imported code names that file.
- Only struct entries can make cycles in the Types section, and they go through
  the decodable struct records. `compiler/bytecode/bytecode_types.agc` interns
  each distinct type once, children first. A program without a JSON type
  argument writes two zero counts.
- The Globals section holds only a count because a slot has no bytes of its
  own to read. The loader allocates the slots as zeroed memory inside the
  program, so the collector scans them like constants. It rejects a count above
  65,535 (the bytes left in the file cannot bound it, so the cap does) and
  charges the array to the load budget. The entry rules of 8 apply only to a
  file with a count above zero: a file with no slots has a plain `main` as
  entry, and a program may call `main()`.
- The VM accepts only its own format version and Agentica version (8). Any
  change to the layout or to an opcode's meaning bumps the format version
  (version 6 added the prelude flag of each function, 4.7). Versions 7 and 8
  are reserved by the designs of §42 and §41. Opcode 52 (`TRY_STEP`) did not
  bump it: an older VM rejects the file as an unknown opcode.
- The C loader is the only reader of this format and has no compatibility
  shims, with one transitional exception: the loader still reads format 5,
  which has no prelude flag (`AGC_FORMAT_PREVIOUS`). It was kept while
  `bootstrap/stage0.agcb` wrote format 5; the checked-in stage0 now writes
  format 6, so a later change can remove it.

### 4.7 The prelude

The compiler prelude (see the development skill's `references/stages.md`) is
Agentica code that the compiler adds to a program: the bodies of `List.find`,
`List.group_by` and the other prelude methods. Its functions are ordinary
functions, with differences that make an error inside them read as an error at
the call in the program.

- **The flag.** The Functions section gives each function a `u32` prelude flag,
  0 or 1; any other value is a rejected file. The flag is 1 for the functions
  whose source is a prelude file. The name of such a source starts with
  `<prelude>/` (`<prelude>/list.agc`) and it has no text; every span in its
  functions is the single span `1:1-1:1`. The VM never prints it.
- **Argument spans.** The compiler emits a call of a prelude function as a
  `CALL` with the spans of its arguments right after the span of the call:
  argument `i` has span `s + 1 + i` when the call has span `s`. The loader
  requires `s .. s + params` to be in range for a `CALL` of a function with the
  flag. A call of a prelude function is never a `TAIL_CALL`, so the frame of the
  caller stays on the stack, and `CALL_VALUE` has no argument spans.
- **The error span.** A runtime error raised while a prelude frame runs is
  reported at the call in the program. Take the innermost run of consecutive
  prelude frames (the frame of a native function that a prelude function
  calls is transparent). The error is at the span of the `CALL` in the caller
  of the outermost frame of that run. When the error names an argument
  (`__fail_arg(code, index, message)` and the builtins that fail at an
  argument) and that call carries argument spans, the span is the one of that
  argument; otherwise it is the span of the call. If no frame of the program is
  below the run (a flagged `main`), the static span of the instruction is used.
  Frames with the flag are left out of stack traces (plain, `--ai` and
  `--json`), so a block called by a prelude function shows next the frame of
  the program that called the prelude.
- **`__fail_arg`.** `__fail_arg(code: String, index: Int, message: String)`
  ends the run with a diagnostic of that code and message at argument `index`
  of the call of the prelude function. The code must be `RUNTIME-` followed by
  upper case letters, digits and `-` (at most 64 bytes); any other code is
  `RUNTIME-INTERNAL`. It is the only prelude-only builtin: the loader rejects
  a `CALL_BUILTIN` of it, or of any builtin whose name starts with `__`, from a
  function without the flag.
- **Cost.** The steps of a prelude function are steps of the program: the
  budget (`--max-steps`) is the caller's. A step limit reached inside a prelude
  function is `RUNTIME-STEP-LIMIT` at the call in the program.

The loader cannot tell a `CALL` that carries argument spans from one that does
not, so it checks only the range above.
