## 3. IR (7c)

### 3.1 Types from the checker

The checked AST carries no types; the evaluator dispatches on runtime values.
In 7c, `check` takes an optional `#:types` mutable `eq?` hash and records the
type of every expression it checks (one line in `check-expression`).

The table is needed: `FIELD` takes a field index, which depends on the
target's struct type, and indexing must pick `LIST_GET` or `MAP_GET`. Once
the table exists, the lowerer also uses it for typed arithmetic (Int, Float,
String `+`) and unary minus; each typed op still checks its tags (4.2). All
these operands pass through `check-expression`, with one exception: the
literal 2^63 under unary minus, which `check-unary` skips and the lowerer
handles by rule (3.3). Synthetic nodes built by `check-method` go through
`check-call` and are not recorded, but the lowerer never needs their type,
and a receiver wrapped in `typed-target` carries its type already.

### 3.2 Structures

```racket
(struct ir-program (sources structs enums functions entry span))
(struct ir-struct (name fields types))    ; linked name; field names in declaration order; JSON field types or #f
(struct ir-enum (name variants))          ; list of (variant-name . arity)
(struct ir-function (name params captures slots body span))
(struct ir-label (id))
(struct ir-instr (op args spans))         ; args: slots, constants, indexes, label ids
```

- `body` is a flat list of `ir-instr` and `ir-label`; `--dump-ir` prints it.
- `ir-function` and `ir-program` have every field; `captures` is 0 for
  declared functions.
  The tables hold every struct and enum declaration of the linked program in
  declaration order. Enums are generic only in their checked types, so the
  table needs only each variant's arity. `types` holds a struct's field
  types (`Int`, `Float`, `Bool`, `String`, `(List t)`, `(Map String t)`,
  `(Struct name)`) when every field is decodable, the checker's rule with
  recursion through structs allowed, else `#f`; only `JSON.decode` and
  `JSON.schema` read them.
- Slots are the VM registers, numbered per function: parameters `0..p-1`,
  captures `p..p+c-1`, then locals and temporaries. Temporaries follow a
  stack discipline, so a call's arguments are always the highest live slots
  (4.3). `slots` is the total.
- Locals are resolved statically from the evaluator's scope rules (`define!`
  versus `assign!` in `exec-statement`). A slot can be reused after its scope
  ends.
- `spans` is a list. Most instructions have one: the span their diagnostic
  uses (operator span for arithmetic, index expression for indexing, call
  span for calls). `step` with a merged count and `call-builtin` have several
  (4.1).

### 3.3 Lowering rules

| Form | Lowering |
|---|---|
| Statements and expressions | A `step` with the node span where the evaluator calls `step!` (2.1), then the node's code. |
| Literals, names | `const` for a literal. A local read uses its slot directly; no expression can change a local. Only call windows need `move`. |
| `-` over literal 2^63 | `step` (unary), `step` (literal), `const INT64_MIN`. |
| `and` / `or` | Left into the target slot; `jump-if-false` / `jump-if-true` past the right side. |
| Arithmetic, ordering | Typed ops. `a > b` is `lt b a`, `a >= b` is `le b a` (operands already evaluated; NaN stays false). |
| `if` / `elsif` / `else` | Conditional jumps over each branch. |
| `while` | Head label, condition (starts with its `step`), `jump-if-false` to the exit, body, `jump` to the head. `next` jumps to the head, `break` to the exit. |
| `for x in a..b`, `for x in a...b` | No `Range` value. `step` (the range span), `a` into the counter slot `i`, `b` into `last`, then `le-i` (or `lt-i` for `...`) into `ok`, `jump-if-false ok` past the loop, `const 1`, and for `...` `sub-i last last one` (`b` is above `a`, so no overflow). The loop variable is the counter slot itself (it is read-only); the loop top is a `step` with the `for` span (one per iteration, 2.1), then the body; an empty body keeps the loop. After the body (the target of `next`): `eq` of `i` and `last`, `jump-if-true` past the loop, `add-i i i one`, `jump` back to the body. The equality test comes before the increment, so a range ending at the largest Int never overflows. |
| `for x in r` (a `Range` value) | The iterable once, then `range-bounds i r`, which writes the first value, the last included value and whether the range is non-empty into `i`, `i+1`, `i+2`; then the same counter loop. The bounds are read once, so assigning `r` in the body does not change the loop, and `to_a` (and its cap) is never used. |
| `a..b`, `a...b` (as a value) | `step` (binary span), `a` and `b` into a window `w`, `w+1`, then `range dst w kind` (kind 0 for `..`, 1 for `...`). |
| `for x in xs` | Iterable once into a hidden slot (a `move` even for a local, since the body may assign that local), hidden index, length and one slots (`const 0`, `list-len`, `const 1`, set once); `jump` to the test; body; increment (`add-i`); test `lt-i`, `jump-if-true` back to the body. The body starts with its first statement's `step`, then `list-get x xs i` (span of the `for`), then the rest of that statement: the backward jump must land on a `STEP` (8), and the read charges nothing. `next` jumps to the increment, `break` past the test. An empty body lowers to just the iterable: its iterations charge nothing and do nothing. |
| Functions | One IR function each; falling off the end returns Void. |
| Calls | A builtin (`builtin-ref name arity`, as `eval-call`) gives `call-builtin`, including the higher-order `List` functions (4.3); a user function gives `call`, or `tail-call` when it is the value of a `return` (see `return`). |
| Structs | `step` (construct span); arguments evaluated in written order directly into the slot of their declared position, then `struct`. A `construct` named `Enum.Variant` is an enum constructor (`eval-step-expression`). Field access: `step` (node span), target, then `field` with the declared index. A struct type that is not declared in the program (a builtin record such as `Header`) stays `LOWER-UNSUPPORTED`. |
| Enums | `step` (constructor span), payload slots in order, then `enum` with a global variant id; a nullary variant is `enum dst dst v`. |
| Lists, maps | `list` / `map` from consecutive slots (a map's key and value slots alternate, each entry's key lowered before its value, as `map-lit` evaluates them; entries charge no step). Literals longer than 255 elements are built in chunks joined with `List.concat`, or extended with `Map.put` (no steps, literal span). For a list: the accumulator slot `w`, each chunk's elements in `w+1..`, the first chunk `list w`, every later one `list w+1` then `call-builtin w List.concat 2`, so a literal needs at most 256 slots beside its elements' own temporaries. For a map: the first 255 entries `map w w+1 255`, then each later entry's key in `w+1`, its value in `w+2` and `call-builtin w Map.put 3`, so a map literal needs at most 511 slots beside its entries' own temporaries. An empty literal is `list dst dst 0` or `map dst dst 0`; the checker gives an empty map literal its type from the context. |
| Indexing | `list-get` or `map-get` from the target's checked type. `step` (index node), target, index, then `list-get` or `map-get` at the index expression's span, which is where `RUNTIME-INDEX-OUT-OF-RANGE` ("index -1 is outside a list of length 3") and `RUNTIME-KEY-NOT-FOUND` (`key "x" is not in the map`, the key in `write` form) point. |
| `case` | Scrutinee once (a local is read in place: tests and payload reads all come before any body runs); per arm a test (`const` + `same` for literals, `is-variant`, `is-ok`), `jump-if-false` to the next arm, payload into arm slots (`_` skipped), body in its own scope through `lower-statement`, jump to the end. Patterns charge no steps. `_` has no test. An Int literal pattern outside 64 bits (the checker accepts `9223372036854775808 ->`) can never match, so its test is a plain `jump` to the next arm. A Result pattern (`ok(v)`, `error(m)`, `Result.Ok(v)`, `Result.Err(m)`; the scrutinee's checked type is `Result`) tests `is-ok`, then `jump-if-false` for `ok` or `jump-if-true` for `error`, and its binding reads `result-value` (the success value or the message). |
| `try` | `step` (the `try` span), the operand, then `try dst src`: on an error, return that Result from the current function (from the block once closures land); else its value goes to `dst`. A `try` of a `Result[Void]` may be a statement. `return try f(...)` is not a tail call. |
| `ok`, `error`, `Result.*` | Builtin calls: keys `ok` (arity 1, and arity 0 for `ok()`), `error`, `Result.ok?`, `Result.unwrap!`, `Result.unwrap_or`, `Result.message`. `Result.Ok(x)` and `Result.Err(m)` are already `ok`/`error` calls after parsing, and method forms (`r.ok?`, `r.unwrap!`) are resolved calls. |
| Interpolation | `step`, then the first part straight into the target; each later part into the next free slot, then `concat target target slot`. A string part is a `const`; an expression part is lowered as usual and followed by `to-text slot slot` unless it is a String. String parts charge no step. |
| `.inspect` | `inspect`. `.to_s` follows what the checker resolved: the receiver itself for String, `String.from_int`/`from_float` for Int/Float, a one-part interpolation for other types. A `method-call` or `field-access` with `resolved` set lowers its resolved node without a step, and a `typed-target` lowers its expression, as `eval-expression` does. |
| `JSON.decode(s, User)`, `JSON.schema(User)` | The type argument is charged one step and lowers to a String constant with the struct's linked name (`@2::User` when imported), as `type-expression` evaluates to it; the builtin finds the struct with that name in the Types section. A type without JSON field types (a builtin record such as `Header`, or a user struct whose fields reach one) is `LOWER-UNSUPPORTED` at the type argument; builtin records come with HTTP in 7h. |
| `&name` | `step`, then `closure dst fn` with no captures (a new function value each time, like `function-value`). |
| `f.call(...)` | `step` (invoke span), the target into the window base, the arguments after it, then `call-value base n` at the invoke span; the result lands in the base. |
| Blocks | `step` (block span), then closure conversion (3.4). |
| `return` | `return` of the value, or of a Void constant. Inside a block it leaves the block (the block is its own function). When the value is a direct call to a user function (local or imported; the linker turns `Mod.f(...)` into a plain call), the call lowers as usual but ends in `tail-call` instead of `call`, and no `return` follows. This holds wherever the `return` is: in `if`/`elsif`/`else` branches, `case` arms, `while` and `for` bodies, and in `main`. Builtin calls, calls inside a larger expression (`return 1 + f(n)`) and `return try f(...)` are not tail calls; neither will `.call` be, once the VM lowers it. |
| Assignment to an existing local | Value into a temporary, then `move`. `and`/`or` write their target before the right side runs, so lowering straight into the local would let `x = y and x` read the new `x`. A new local is lowered straight into its slot. |

### 3.4 Closure conversion

- A `block-lit` becomes an IR function named `block@file:line:col` after its
  span (the source file name without its directory). Block functions follow the declared functions, numbered in the
  order the lowerer meets them (an outer block before the blocks inside
  it). Its parameters are the block parameters.
- Its captures are the names that a `name-ref` anywhere in its body uses
  (nested blocks included) and that are visible where the block is
  created, in order of first appearance. The evaluator captures every
  visible variable (`capture-scopes`), but a block can only read them
  (`CHECK-CAPTURED-ASSIGNMENT`), and nothing may shadow a visible name
  (`CHECK-SHADOWED-NAME`), so capturing just the used ones is not
  observable. The checker records each block's `Fn` type in the `#:types`
  table, also for blocks it checks through a `List` rule.
- At creation, captured values move into consecutive slots and `closure`
  copies them into the function value: a snapshot, as `capture-scopes`
  unboxes the values, so a later assignment to the outer local does not
  reach the block. The block-lit node is charged one step, as now.
- At a call, the VM copies the captures into the callee's capture slots.
- A block returns the value of its final expression statement (charged as
  a statement, then lowered as an expression into the returned slot), or
  Void. `try` inside a block returns from the block.
- `break` and `next` never cross a function or block (`CHECK-LOOP-CONTROL`),
  so they are plain jumps.

### 3.5 Lowering diagnostics

The lowerer and the emitter are stages: they return data or one diagnostic
and never raise. Their codes use their own prefixes, so they cannot clash
with the language codes (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`):

| Code | Raised by | Meaning |
|---|---|---|
| `LOWER-UNSUPPORTED` | `src/lower.rkt` | The program uses a form or a type the VM does not support yet; the span is the first such node. |
| `LOWER-INTERNAL` | `src/lower.rkt` | A Racket exception inside the lowerer (a bug), at the program span. |
| `BYTECODE-LIMIT` | `src/bytecode.rkt` | A function needs more than 65535 registers (later also structs or variants, 4.4). |
| `BYTECODE-INTERNAL` | `src/bytecode.rkt` | A Racket exception inside `ir->bytecode` or `write-bytecode` (a bug), at the program span. |

`agentica compile` and `--dump-ir` print them like any other diagnostic and
exit 1. Today a value outside Int, Float, Bool, Nil, String, structs and
enums declared in the program, and `List`, `Map` and `Result` of those (nested to
any depth; `Result[Void]` too) and `Fn` over those (a Void result too) is rejected, except a Void call or `try`
used as a statement or returned. A struct or
enum type is accepted whatever its fields or payloads hold: a value of an
unsupported type can only come from an expression the lowerer rejects. The only builtins a program may call are `puts`,
`IO.print`, `IO.warn`, `IO.inspect`, `IO.gets`, `IO.gets!`, `IO.read`,
`IO.read_bytes`, `IO.flush`, `IO.eof?`, `System.args`, `System.exit`,
`String.from_int`, `String.from_float`, `ok`,
`error`, `Result.ok?`, `Result.unwrap!`, `Result.unwrap_or`,
`Result.message`, `List.map`, `List.filter`, `List.reduce`, `List.each`,
`List.any?`, `List.all?`, `List.sort_by`, `Range.size`, `Range.to_a`,
`Range.include?`, `Range.each`, `Range.first`, `Range.last`, `Int.times`,
`Int.upto`, `Int.downto`, `List.size`, `List.append`, `List.set`,
`List.repeat`, `List.concat`, `List.take`, `List.drop`, `List.at`,
`List.reverse`, `List.sort`, `Map.has_key?`, `Map.keys`, `Map.size`,
`Map.put`, `Map.get` (arities 2 and 3), `Map.delete` and `Map.values`
(their implementation keys; `print` and `IO.puts` map to
the first two, `gets` and `gets!` to `IO.gets` and `IO.gets!`).
`String.from_int` and `String.from_float` are there because the checker
resolves `x.to_s` on Int and Float to them. The `File`, `Dir` and `Path`
builtins are accepted too (2.8): `FileHandle` is a value type, and the
builtin record `FileInfo` (fields `kind`, `size_bytes`,
`modified_seconds`) is appended to the struct table when any checked type
in the program mentions it; `File.stat` finds it there by name and fields.
The lowerer also emits `List.concat` and `Map.put` for long literals
(3.3). No core form turns into a `List` library call: `for`,
literals and indexing have their own opcodes, `x.to_s` of a list is a
one-part interpolation, and `xs.size`/`xs.length` are written method calls
of `List.size`.

A list literal nested `d` levels deep needs about `d` registers in its
function, so nesting beyond about 65,000 levels in one literal is
`BYTECODE-LIMIT`; the evaluator has no such limit. Lowering stays linear in
the depth: the literal's own type is checked once, and its elements are not
checked again. This is a documented
difference, like the register cap (6.1).

## 4. Bytecode (7d)

### 4.1 Machine model

A register machine. Each function declares its register count; locals and
temporaries are registers. The IR already assigns slots, so emitting
register code is plain encoding. Each instruction is 8 bytes:

```c
typedef struct { uint16_t op, a, b, c; } agc_instr;   /* bx = b | (uint32_t)c << 16 */
```

`a`, `b`, `c` are registers or small indexes; `bx` is a 32-bit index. A
parallel `uint32_t` array gives each instruction one span index `s`. An
instruction that needs several spans (`STEP n`, `CALL_BUILTIN`) uses the
entries `s, s+1, ...` that follow it in the span table.

### 4.2 Instruction set

`R[x]` is a register, `K[x]` a constant. Every instruction reads values
through the checked accessors (5.2); a wrong tag is `RUNTIME-INTERNAL`
("invalid bytecode"), never undefined behavior.

| Group | Opcode | Operands | Meaning |
|---|---|---|---|
| Move | `MOVE` | a b | `R[a] = R[b]` |
| | `CONST` | a bx | `R[a] = K[bx]` |
| Budget | `STEP` | a | Charge `a` steps; with `k < a` left, fail at span `s + k` |
| Int | `ADD_I SUB_I MUL_I DIV_I MOD_I` | a b c | Checked int64 op; fails at the op span |
| | `NEG_I` | a b | Checked negation |
| Float | `ADD_F SUB_F MUL_F DIV_F` | a b c | IEEE; `DIV_F` fails on a zero divisor |
| | `NEG_F` | a b | IEEE negation |
| Text | `CONCAT` | a b c | String `+` |
| | `TO_TEXT` | a b | Text form (2.4) |
| | `INSPECT` | a b | Debug form (2.4) |
| Logic | `NOT` | a b | Bool not |
| Compare | `LT_I LE_I LT_F LE_F` | a b c | Ordering |
| | `EQ NE` | a b c | `=` for numbers, `equal?` for String, Bool, Nil |
| | `SAME` | a b c | `equal?` (Float by `eqv?`), for `case` literals |
| Jump | `JUMP` | bx | Go to instruction `bx` |
| | `JUMP_IF_FALSE JUMP_IF_TRUE` | a bx | Test Bool `R[a]` |
| Call | `CALL` | a bx | Call function `bx`; args `R[a..]`; result in `R[a]` |
| | `CALL_VALUE` | a b | Call function value `R[a]` with `b` args `R[a+1..]`; result in `R[a]` |
| | `CALL_BUILTIN` | a bx | Call builtin import `bx`; args `R[a..]`; result in `R[a]`; spans: call, then each argument |
| | `RETURN` | a | Return `R[a]` |
| | `TAIL_CALL` | a bx | Call function `bx` with args `R[a..]` in place of the current frame; its result goes where this frame's result would |
| | `CLOSURE` | a bx | Closure of function `bx`, captures from `R[a..]`, result in `R[a]` |
| Data | `LIST` | a b c | List of `R[b..b+c-1]` |
| | `LIST_LEN` | a b | Length of list `R[b]` |
| | `LIST_GET` | a b c | `R[b][R[c]]`; out of range fails at the index span |
| | `MAP` | a b c | Map from `c <= 255` key/value pairs at `R[b..b+2c-1]`, `mapping-put` rules |
| | `MAP_GET` | a b c | `R[b][R[c]]`; missing key fails at the index span |
| | `STRUCT` | a b c | Struct of type `c` from `R[b..]` in declaration order |
| | `FIELD` | a b c | Field `c` of struct `R[b]` |
| | `ENUM` | a b c | Variant `c` with payload `R[b..]` |
| | `IS_VARIANT` | a b c | Is `R[b]` variant `c`? |
| | `PAYLOAD` | a b c | Payload item `c` of enum `R[b]` |
| Result | `TRY` | a b | If `R[b]` is an error, return it; else `R[a]` = its value |
| | `IS_OK` | a b | Is `R[b]` ok? |
| | `RESULT_VALUE` | a b | Value of an ok, or message of an error (for `case`) |
| Range | `RANGE` | a b c | Range from Int `R[b]` to Int `R[b+1]`; `c` is 0 for `..`, 1 for `...` |
| | `RANGE_BOUNDS` | a b | From range `R[b]`: first value into `R[a]`, last included value into `R[a+1]`, non-empty into `R[a+2]` |

That is 49 opcodes. Everything else, including `ok`, `error`, `puts` and every
module function, is a builtin; later subphases add builtins, not opcodes.

Opcode numbers are positions in one list shared by `opcodes` in
`src/bytecode.rkt` and `agc_opcode` in `vm/agc.h`. Each PR appends the
opcodes it implements, so there are no numbers for unimplemented ones. In the
slice the list is `MOVE CONST STEP ADD_I SUB_I MUL_I DIV_I MOD_I NEG_I NOT
LT_I LE_I EQ NE JUMP JUMP_IF_FALSE JUMP_IF_TRUE CALL CALL_BUILTIN RETURN`
(20 opcodes); the Float PR appended `ADD_F SUB_F MUL_F DIV_F NEG_F LT_F
LE_F` (27); the Strings PR appended `CONCAT TO_TEXT INSPECT` (30); the Lists
PR appended `LIST LIST_LEN LIST_GET` (33); the structs, enums and `case` PR
appended `STRUCT FIELD ENUM IS_VARIANT PAYLOAD SAME` (39); the tail-call PR
appended `TAIL_CALL` (40); the Result PR appended `TRY IS_OK RESULT_VALUE`
(43); the Maps PR appended `MAP MAP_GET` (45); the closures PR appended
`CALL_VALUE CLOSURE` (47); the ranges PR (Phase 8a) appended `RANGE
RANGE_BOUNDS` (49), with no format bump. `CLOSURE` takes the capture count from the
function table; `CALL_VALUE` checks that `R[a]` is a function value whose
function takes exactly `b` parameters and has as many captures as the
value holds (otherwise `RUNTIME-INTERNAL` at the call's span). `EQ`/`NE`
accept Int, Float (C `==`, which is Racket `=`), Bool, Nil or String pairs
(String by length and bytes, which is `equal?` on valid UTF-8), and Range
pairs (start, end and kind, never identity: `equal?` on the evaluator's
transparent `range-value`); other pairs
are `RUNTIME-INTERNAL`. The checker allows `==` only on Int, Float, Bool,
String, Nil and Range (`CHECK-TYPE-MISMATCH` otherwise), so lists never reach
`EQ`; equality on nested data joins with `case` and maps if the checker ever
allows it there. `LIST` copies the window into a new immutable list (the
window may include `a`); `LIST_GET` checks `0 <= i < len` on the int64
before using it, and its message is built at run time. There is no String ordering: the checker allows
`< <= > >=` only on numbers. `TO_TEXT` returns a String operand itself and
`INSPECT` of a non-String gives the same text as `TO_TEXT`.
The checker allows `==` only on primitives, so structs and enums have no
equality either. `SAME` is Racket `equal?` on the literal types: false when
the tags differ, Int, Bool, Nil and String as in `EQ`, Float by `eqv?`
(`-0.0` does not match `0.0`, NaN matches NaN); other tags are
`RUNTIME-INTERNAL`. `STRUCT` takes its field count and `ENUM` its arity from
the tables; a nullary `ENUM` returns the variant's shared value, made by the
loader. `IS_VARIANT` compares the global variant id, which is unique per
enum declaration, as the evaluator compares the enum and variant names; an
id from another enum (only in a hand-made file) is simply false.
`FIELD` and `PAYLOAD` read item `c` of the value's own `n`; past it is
`RUNTIME-INTERNAL`. `TRY`, `IS_OK` and `RESULT_VALUE` read a Result
through its checked accessor (any other tag is `RUNTIME-INTERNAL`). An
error in `TRY` leaves the frame exactly as `RETURN` does, but it never
empties the call stack: an error in a `TRY` of the entry function (only in a
hand-made file; the checker allows `try` only in functions that return
Result) is `RUNTIME-INTERNAL`. Results have no equality
(`CHECK-TYPE-MISMATCH`), so `EQ` and `SAME` never see one; given one, they
are `RUNTIME-INTERNAL`.
`MAP` puts its `c` pairs in order into an empty map with the `mapping-put`
rule: a repeated key keeps its first position and takes the last value.
`MAP_GET` builds its message at run time from the key's debug form. A key
that is not an Int or a String (only in a hand-made file) is
`RUNTIME-INTERNAL` when it is hashed. The checker rejects `==` on maps, so
there is no map equality.

### 4.3 Calls, call windows and resumable builtins

`CALL a bx` starts the callee's frame at the caller's register `a`, so the
arguments are already the callee's parameters; the result lands in the
caller's `R[a]`. `CALL_VALUE` does the same one register higher, checks the
function value's parameter count against `b` at run time, and copies a
closure's captures after the parameters. The lowerer keeps call windows at
the top of the live registers; a corrupt file that breaks this mixes up
values but stays memory safe.

`TAIL_CALL a bx` keeps the current frame and its base. It first grows the
registers to `base + ` the callee's register count (the callee may need more
than the caller; the same cap and out-of-memory path as a push, 6.1), then
moves the arguments `R[a..a+params-1]` down to `R[0..]` with `memmove`, since
the two windows may overlap, and sets the frame's function to `bx` and its
`pc` to 0. The callee's `RETURN` then writes the frame's base register, the
result register of the `CALL` that made the frame, just as the replaced
function's `RETURN` would have. `CALL` and `RETURN` charge
no steps, and the lowering puts the same `step`s before a `tail-call` as
before a `call`, so a tail call charges exactly what `call` + `return`
charged: step counts and `--max-steps` failures do not change (exact counts
are not part of parity, 1, but keeping them made the change easy to test at
the time).

`List.map`, `filter`, `reduce`, `each`, `any?`, `all?` and `sort_by` are
**resumable builtins**. `CALL_BUILTIN` pushes a native frame whose state (the
list, the position, the partial result) lives in a GC object that bytecode
cannot reach. The interpreter asks it for the next callback call, pushes that
as a normal frame with the builtin's call span, and resumes the native frame
when the callback returns. So no builtin ever calls the interpreter from C,
iteration is bounded by the list length (the counting builtins, which
have no list, charge one step per callback instead), and a task can block inside a
callback (7h). Native frames do not count toward call depth, matching the
evaluator. `sort_by` collects all keys first, then sorts (7.3).
`Range.each`, `Int.times`, `Int.upto` and `Int.downto` are counting native
frames: their state is a current value, the last value, a direction (+1 or
-1) and a "more" flag, set once from the arguments (`n > 0`, `a <= b`,
`a >= b`, or the range's bounds). Each resume calls the callback with the
current value after charging one step at the call's span (the same check
as `STEP`: `RUNTIME-STEP-LIMIT` when the budget is gone, and the place a
task will yield in 7h), then clears "more" when it equals the last value and steps
otherwise, so counting up to the largest Int (or down to the smallest)
never overflows, and memory stays O(1).

In C (`vm/interp.c`): the C table marks these entries with an
`agc_native_kind` instead of a function. `CALL_BUILTIN` copies the list,
the callback and the initial value (`reduce`) out of the argument window
into an `agc_native` state, allocates the result list up front for `map`,
`filter` and `sort_by` (one slot per item, so it never grows), and pushes
a native frame whose base is the call's result register `R[a]`. Each
callback runs as an ordinary frame at base `R[a+1]` with its result
register `R[a]`, pushed by the same code as `CALL_VALUE` (depth check,
arity check, captures copied after the arguments). When a frame returns
into a native frame, the interpreter resumes it: the state reads the
callback result from `R[a]`, records it (`map` stores it, `filter` keeps
the item when it is `true`, `reduce` makes it the accumulator, `sort_by`
stores the key, `any?` stops at the first `true` and `all?` at the first
`false`), then either pushes the next callback or pops itself and writes
the builtin's result into `R[a]`. `reduce` calls `f(accumulator, item)`.
A `return` or `try` inside a block leaves only the block's frame, and a
tail call inside it keeps the frame's result register, so the native
frame still gets the value. Registers above `a` are free by the lowering
invariant, so the callback frames may use them.

### 4.4 Steps

The IR has one `step` per charged node. The 7d emitter merges only adjacent
`step`s with no label between them into one `STEP n`, splitting runs above
65535 because the count is 16 bits. Struct and variant ids are 16-bit
operands too, so the emitter rejects a program with more than 65535 structs
or variants. Today the charge points do not move, so counts and failing
spans match the evaluator. Black-box parity (1) allows more: merging `STEP`s
across pure instructions or moving them out of straight-line code is fine as
long as every loop and recursion still charges at least one step per round,
so a runaway program still stops with `RUNTIME-STEP-LIMIT`. Roadmap 7k
lists it with the other lowering optimizations.

### 4.5 Builtin imports

The file lists the builtins it uses as `(key, arity)`, where the key is the
catalog's implementation key in `src/builtins.rkt`, not the written name
(`puts` and `IO.puts` both import `"puts"`); overloads such as `Map.get` and
`ok` are separate entries by arity. The loader resolves each against the C table, comparing
length and bytes, and rejects unknown pairs. There are no internal helper
builtins: `List.concat`, which the lowerer emits for long list literals, is
the catalog builtin of that name.

### 4.6 File format

All integers are little-endian. `str` is a `u32` byte length plus UTF-8
bytes. Sections come in this fixed order; each starts with a `u32` count
(except the header and entry).

| Section | Entry |
|---|---|
| Header | magic `"AGCB"`, `u32` format version (3), `str` Agentica version (`src/version.rkt`) |
| Sources | `str` name, `str` full text |
| Spans | `u32` source, start line, start column, end line, end column; span 0 is the program span |
| Constants | `u8` kind (0 Void, 1 Nil, 2 false, 3 true, 4 Int, 5 Float, 6 String), then `i64`, `f64` bits or `str` |
| Structs | `str` display name, `u32` field count, each field's `str` name |
| Types | `u32` type count, each a `u8` kind (0 Int, 1 Float, 2 Bool, 3 String, 4 List, 5 Map with String keys, 6 Struct) and, for 4 to 6, a `u32` operand: the item or value type index (smaller than the entry's own) or the struct index; then a `u32` count of decodable structs, each a `u32` struct index (increasing), the `str` linked name, and one `u32` type index per field |
| Enums | `str` display name, `u32` variant count, each `str` name and `u32` arity; variants numbered globally in file order |
| Builtins | `str` name, `u32` arity |
| Functions | `str` name, `u32` params, captures, registers, span, instruction count, the instructions, then one `u32` span index per instruction |
| Entry | `u32` index of `main` |

The full source texts are embedded so the VM prints diagnostics without
reading files. A linked program has one Sources entry per file that a span
points into: the entry file first (span 0), then the others in the order
the lowerer meets them. Each entry keeps the name the front end gave the
file (the entry file as given on the command line, other files by their
full path, `std/` modules by their `std/...` key), so a diagnostic raised in
imported code names that file, line and column. The loader checks every span's line and column against its own
source.

Format version 2 (the structs, enums and `case` PR) fills the Structs and
Enums sections; version 1 had three empty sections there (Types, Structs,
Enums). Format version 3 (JSON part 2, 12.2 item 7) adds the Types section
after Structs: the type data that `JSON.decode` and `JSON.schema` need. List
and Map entries point to smaller indexes, so only struct entries make
cycles, and those go through the decodable struct records. `src/bytecode.rkt`
interns each distinct type once (children first) and writes a record for
every struct whose `ir-struct-types` is set. The lowerer sets them only
when the program has a JSON type argument (`JSON.decode` or `JSON.schema`);
any other program writes two zero counts and never meets the Types limits.
All seven constant kinds are in use; Float constants are the literal's IEEE
bits.

The VM accepts only its own format version and Agentica version; anything
else is rejected (8). Any change to the layout or to an opcode's meaning
bumps the format version. Appending an opcode changes neither, so it keeps
the version (the Lists PR and the tail-call PR stayed on their versions); an
older VM rejects the new opcode as unknown. There are no compatibility
shims: the Racket side and the VM ship together.

