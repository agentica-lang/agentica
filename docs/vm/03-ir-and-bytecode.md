## 3. IR

The lowerer (`src/lower.rkt`) turns the checked program into IR. Each stage
returns data or one diagnostic.

### 3.1 Types from the checker

The checker records the type of every expression in a table (`#:types`, an `eq?`
hash). The lowerer needs it for field indexes (which depend on the struct type),
for `LIST_GET` or `MAP_GET`, for typed arithmetic and for unary minus. Each
typed op still checks its tags at run time (4.2).

### 3.2 Structures

```racket
(struct ir-program (sources structs enums functions entry span))
(struct ir-struct (name fields types))    ; linked name; field names in declaration order; JSON field types or #f
(struct ir-enum (name variants))          ; list of (variant-name . arity)
(struct ir-function (name params captures slots body span))
(struct ir-label (id))
(struct ir-instr (op args spans))         ; args: slots, constants, indexes, label ids
```

- `body` is a flat list of `ir-instr` and `ir-label`. `--dump-ir` prints it.
- Slots are the VM registers, numbered per function: parameters `0..p-1`,
  captures `p..p+c-1`, then locals and temporaries. Temporaries follow a stack
  discipline, so a call's arguments are the highest live slots (4.3).
- `types` holds a struct's field types when every field is decodable, else `#f`.
  Only `JSON.decode` and `JSON.schema` read it.
- Each instruction has a list of spans: the span its diagnostic uses (operator
  for arithmetic, index expression for indexing, call span for calls). A merged
  `step` and `call-builtin` have several (4.1).

### 3.3 Lowering rules

| Form | Lowering |
|---|---|
| Statements, expressions | `step` with the node span, then the node's code. |
| Literals, names | `const` for a literal. A local is read from its slot. Only call windows need `move`. |
| `-` over literal 2^63 | `step`, `step`, `const INT64_MIN`. |
| `and` / `or` | Left side into the target, `jump-if-false` / `jump-if-true` past the right side. |
| Arithmetic, ordering | Typed ops. `a > b` is `lt b a`, `a >= b` is `le b a` (NaN stays false). |
| `if` / `elsif` / `else` | Conditional jumps over each branch. |
| `while` | Head label, condition (starts with its `step`), `jump-if-false` to the exit, body, `jump` to the head. `next` jumps to the head, `break` to the exit. |
| `for x in a..b`, `a...b` | No `Range` value. The counter `i` starts at `a`, `last` is `b`. The test `le-i` (`lt-i` for `...`) runs before the body. For `...`, `last` is `b - 1` (`sub-i`, after the nonempty test; b is above a, so no overflow). The loop top is a `step` with the `for` span, one per iteration. After the body (the target of `next`) the loop compares `i` with `last` and only then adds 1, so a range ending at the largest Int never overflows. |
| `for x in r` (a `Range` value) | `range-bounds` once into the counter, `last` and non-empty flag, then the same loop. Assigning `r` in the body does not change the loop. |
| `a..b`, `a...b` as a value | `step`, then `range dst w kind` (kind 0 for `..`, 1 for `...`). |
| `for x in s` (a `Set` value) | `call-builtin Set.to_a` on the hidden slot, then the loop of `for x in xs` over the list. The set is read once, so assigning `s` in the body does not change the loop. |
| `for x in xs` | The iterable goes into a hidden slot (a `move`, even for a local, since the body may assign it). Hidden index, length and one. The body starts with the `step` of its first statement, then `list-get`. The backward jump lands on a `STEP`. `next` jumps to the increment, `break` past the test. An empty body charges nothing. |
| Functions | One IR function each. Falling off the end returns Void. |
| Calls | A builtin gives `call-builtin` (including the higher-order `List` functions, 4.3). A user function gives `call`, or `tail-call` when it is the value of a `return`. |
| Structs, enums | `step` (construct span), fields evaluated in written order straight into their declared slots, then `struct`. An enum constructor is `step`, payload, `enum` with the global variant id; a nullary variant is `enum dst dst v`. Field access is `step`, target, `field` with the declared index. |
| Struct update `v.with(f: x)` | `step` (the update span), a window with the receiver in its first slot and the new values after it, in the order of the struct's fields (each value is evaluated in written order into its slot), then `struct-with dst window s fields`: one instruction copies the receiver and overwrites those fields. The receiver is evaluated once, before the values. |
| Lists, maps | `list` / `map` from consecutive slots (a map's key before its value). A literal longer than 255 elements is built in chunks joined with `List.concat`; a longer map literal is extended with `Map.put`. Literals need at most 256 slots (list) or 511 (map) beside their elements. An empty literal is `list dst dst 0` or `map dst dst 0`. |
| Indexing | `list-get` or `map-get` by the target's checked type, after a `step` for the index node. `RUNTIME-INDEX-OUT-OF-RANGE` and `RUNTIME-KEY-NOT-FOUND` point at the index expression's span. |
| `case` | The scrutinee is evaluated once. Each arm has a test (`const` + `same` for literals, `is-variant`, `is-ok`), `jump-if-false` to the next arm, payload into arm slots (`_` skipped), then the body. Patterns charge no steps. `_` has no test. An Int literal outside 64 bits can never match, so its test is a plain `jump`. A Result pattern tests `is-ok`, and its binding reads `result-value` (the value or the message). |
| `try` | `step` (the `try` span), the operand, then `try dst src`: on an error, return that Result from the function (the block, inside a block). `return try f(...)` is not a tail call. |
| `ok`, `error`, `Result.*` | Builtin calls. `Result.Ok(x)` and `Result.Err(m)` are `ok` and `error` calls after parsing. |
| Interpolation | `step`, then the first part into the target and each later part into the next slot, then `concat`. An expression part that is not a String is followed by `to-text`. String parts charge no step. |
| `.inspect`, `.to_s` | `inspect`. `.to_s` follows the checker's resolution: the receiver for String, `String.from_int` or `String.from_float` for Int and Float, a one-part interpolation otherwise. |
| `JSON.decode(s, T)`, `JSON.schema(T)` | The type argument is charged one step and lowers to a String constant with the struct's linked name (`@2::User` when imported). The builtin finds the struct by that name in the Types section. A target that is not decodable is rejected by the checker (`CHECK-NOT-DECODABLE`). |
| `&name` | `step`, then `closure dst fn` with no captures. |
| `f.call(...)` | `step` (invoke span), the target into the window base, the arguments after it, then `call-value base n`. |
| Blocks | `step` (block span), then closure conversion (3.4). |
| `return` | The value, or a Void constant. Inside a block it leaves the block. A direct call to a user function (local or imported) ends in `tail-call` instead of `call`, wherever the `return` is: in branches, `case` arms and loop bodies. Builtin calls, calls inside a larger expression (`return 1 + f(n)`) and `return try f(...)` are not tail calls. |
| Assignment to an existing local | Value into a temporary, then `move`. Lowering straight into the local would let `x = y and x` read the new `x`. A new local is lowered straight into its slot. |

The builtin record types (`FileInfo`, `Header`, `HttpRequest`, `HttpResponse`,
`HttpClientOptions`, `HttpServerOptions`, `ProcessOutput`) join the struct table
only when the program names them or a checked type mentions them. Then they
lower like user structs (`used-builtin-structs` in `src/lower.rkt`).

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

| Code | Raised by | Meaning |
|---|---|---|
| `LOWER-UNSUPPORTED` | `src/lower.rkt` | A form or a type the lowerer does not handle yet (`vm-type?` in `src/lower.rkt`). The span is the first such node. |
| `LOWER-INTERNAL` | `src/lower.rkt` | A Racket exception inside the lowerer (a bug), at the program span. |
| `BYTECODE-LIMIT` | `src/bytecode.rkt` | A function needs more than 65535 registers, or the program has more than 65535 structs or variants (4.4). |
| `BYTECODE-INTERNAL` | `src/bytecode.rkt` | A Racket exception in `ir->bytecode` or `write-bytecode` (a bug), at the program span. |

A builtin call lowers only when its implementation key is in `vm-builtins`
(`src/lower.rkt`). A builtin outside that list is `LOWER-UNSUPPORTED` at the
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

| Group | Opcodes | Meaning |
|---|---|---|
| Move | `MOVE a b`, `CONST a bx` | `R[a] = R[b]`, `R[a] = K[bx]` |
| Budget | `STEP a` | Charge `a` steps. With `k < a` left, fail at span `s + k`. |
| Int | `ADD_I SUB_I MUL_I DIV_I MOD_I`, `NEG_I` | Checked int64 ops. Fail at the operator span. |
| Float | `ADD_F SUB_F MUL_F DIV_F`, `NEG_F` | IEEE. `DIV_F` fails on a zero divisor. |
| Text | `CONCAT`, `TO_TEXT`, `INSPECT` | String `+`; text form (2.4); debug form (2.4). |
| Logic, compare | `NOT`; `LT_I LE_I LT_F LE_F`; `EQ NE`; `SAME` | Bool not; ordering; `=` for numbers and `equal?` for String, Bool, Nil and Range; `SAME` is the `case` literal test (`eqv?` for Float). |
| Jump | `JUMP bx`, `JUMP_IF_FALSE a bx`, `JUMP_IF_TRUE a bx` | Go to `bx`; test Bool `R[a]`. |
| Call | `CALL a bx`, `CALL_VALUE a b`, `CALL_BUILTIN a bx`, `TAIL_CALL a bx`, `RETURN a`, `CLOSURE a bx` | 4.3. |
| Data | `LIST a b c`, `LIST_LEN a b`, `LIST_GET a b c`, `MAP a b c`, `MAP_GET a b c`, `STRUCT a b c`, `STRUCT_WITH a b c`, `FIELD a b c`, `ENUM a b c`, `IS_VARIANT a b c`, `PAYLOAD a b c` | Lists, maps, structs and enums. `LIST_GET` and `MAP_GET` fail at the index span. `STRUCT_WITH`: `R[a]` is a copy of the struct in `R[b]` whose fields listed in update entry `c` (4.6) are overwritten by `R[b+1]`, `R[b+2]`, ... in that order. |
| Result | `TRY a b`, `IS_OK a b`, `RESULT_VALUE a b` | `TRY`: if `R[b]` is an error, return it, else `R[a]` = its value. |
| Range | `RANGE a b c`, `RANGE_BOUNDS a b` | `RANGE` from Int `R[b]` to `R[b+1]`, `c` 0 for `..`, 1 for `...`. `RANGE_BOUNDS`: first value into `R[a]`, last included value into `R[a+1]`, non-empty flag into `R[a+2]`. |

There are 50 opcodes. Everything else, including `ok`, `error`, `puts` and every
module function, is a builtin. Opcode numbers are positions in one list shared
by `opcodes` in `src/bytecode.rkt` and `agc_opcode` in `vm/value.h`. New opcodes
are appended at the end. An appended opcode does not bump the format version,
and an older VM rejects it as unknown.

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
  table entry (a hand-made file may put another value there, or a builtin record
  declared with more fields than the VM makes); anything else is
  `RUNTIME-INTERNAL`. The loader has checked every field index of the entry
  against the struct's field count, so the writes need no bounds test. It charges
  no cost beyond its `STEP`s, like `STRUCT`.
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
  to the step function, so no C code calls the interpreter and the task can
  block inside the callback, like the `List` builtins. A native frame on top of
  the call stack is resumed at the start of the task's next turn. Each block
  call costs one step, charged as for the other native frames, and the turn cost
  of the bytes read.
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
implementation key in `src/builtins.rkt`, not the written name: `puts` and
`IO.puts` both import `"puts"`. Overloads such as `Map.get` and `ok` are
separate entries by arity. The loader resolves each pair against the C table and
rejects unknown pairs. There are no internal helper builtins: `List.concat`,
which the lowerer emits for long list literals, is the catalog builtin of that
name.

### 4.6 File format

All integers are little-endian. `str` is a `u32` byte length plus UTF-8 bytes.
Sections come in this fixed order. Each starts with a `u32` count, except the
header and the entry.

| Section | Entry |
|---|---|
| Header | magic `"AGCB"`, `u32` format version (4), `str` Agentica version (`src/version.rkt`) |
| Sources | `str` name, `str` full text |
| Spans | `u32` source, start line, start column, end line, end column. Span 0 is the program span. |
| Constants | `u8` kind (0 Void, 1 Nil, 2 false, 3 true, 4 Int, 5 Float, 6 String), then `i64`, `f64` bits or `str` |
| Structs | `str` display name, `u32` field count, each field's `str` name |
| Types | `u32` type count. Each entry is a `u8` kind (0 Int, 1 Float, 2 Bool, 3 String, 4 List, 5 Map with String keys, 6 Struct) and, for 4 to 6, a `u32` operand: the item or value type index (smaller than the entry's own) or the struct index. Then a `u32` count of decodable structs, each a `u32` struct index (increasing), the `str` linked name and one `u32` type index per field. |
| Enums | `str` display name, `u32` variant count, each `str` name and `u32` arity. Variants are numbered globally in file order. |
| Updates | `u32` struct index, `u32` field count k (1 to the struct's field count), k `u32` field indexes, strictly increasing and below the struct's field count. One entry per distinct set of fields of a struct that a `.with(...)` changes; `STRUCT_WITH` names an entry. |
| Builtins | `str` name, `u32` arity |
| Functions | `str` name, `u32` params, captures, registers, span, instruction count, the instructions, then one `u32` span index per instruction |
| Entry | `u32` index of `main` |

- The Sources section embeds the full source texts, so the VM prints diagnostics
  without reading files. A linked program has one entry per file a span points
  into: the entry file first, then the others in the order the lowerer meets
  them. Each keeps the name the front end gave it (`std/` modules by their
  `std/...` key), so a diagnostic in imported code names that file.
- Only struct entries can make cycles in the Types section, and they go through
  the decodable struct records. `src/bytecode.rkt` interns each distinct type
  once, children first. A program without a JSON type argument writes two zero
  counts.
- The VM accepts only its own format version and Agentica version (8). Any
  change to the layout or to an opcode's meaning bumps the format version.
- The C loader is the only reader of this format. There is no Racket reader, and
  no compatibility shims: the Racket side and the VM ship together.
