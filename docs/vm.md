# Agentica bytecode VM: design

This document closes roadmap step 7b. It fixes the decisions that 7c
(lowering), 7d (bytecode emitter) and 7e (VM core) build on, and the library
choices and safety rules that 7h and 7i need. The language does not change.
`grammar.md` stays the contract, and the Racket evaluator
(`src/evaluator.rkt`) stays the reference until 7i. Where this document and
the evaluator disagree, the evaluator wins and this document is fixed.
Roadmap step 7b lists each decision in one line; this document gives the
details and reasons.

## 1. Overview

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
| `src/bytecode.rkt` (7d) | IR to bytecode: label resolution, constant pool, builtin imports, type and span tables, step merging, binary writer and reader. |
| `src/main.rkt` | `--dump-ir` (7c), `compile` (7d), `--vm` (7i). Printing and exit codes stay here. |
| `vm/` (7e) | The C VM: loader, values, interpreter loop, builtins, JSON, diagnostics, CLI driver. Builds `dist/agentica-vm`. |

**Trust model.** A `.agcb` file is untrusted input. Whatever it contains, the
VM must not have memory errors, must not run child processes unless the VM
itself got `--allow-run`, and must stop within `--max-steps` when a limit is
given. A file that passes the loader can still compute wrong values or end
with `RUNTIME-INTERNAL`; that is the whole guarantee.

## 2. Reference behavior the VM must copy

These rules come from the Racket sources, not only from the grammar. The
differential tests (section 12) check them.

### 2.1 Steps (`task-step!` in `src/task.rkt`, `step!` in `src/evaluator.rkt`)

- One step is charged when each statement starts (`exec-statement`) and when
  each expression starts (`eval-step-expression`), before its children run.
- Not charged, because `eval-expression` passes through them: `typed-target`,
  a `method-call` with `resolved` set, and a `field-access` with `resolved`
  set. Their resolved node is charged normally. So `s.to_s` on a String
  charges only the receiver, and `xs.size` charges the synthetic `List.size`
  call plus the receiver.
- Also not charged: `if-branch`, `case-arm`, patterns, `map-entry`,
  `named-arg`, string parts of an interpolation, function entry, binding the
  `for` variable, and work inside builtins.
- A `while` condition is charged on every evaluation, including the last
  false one. A `for` iterable is charged once.
- A block's final expression statement is charged as a statement
  (`call-closure`). Callbacks run by the `List` builtins charge only their
  bodies.
- Without `--max-steps`, nothing is counted. With limit N, the first N entries
  run and entry N+1 fails with `RUNTIME-STEP-LIMIT` at its own span. All tasks
  share one counter. Racket accepts any positive integer; the VM clamps values
  above `INT64_MAX`, which can never be exhausted anyway.

### 2.2 Numbers

- Int arithmetic is exact, then range checked (`in-int-range`): overflow is
  `RUNTIME-INTEGER-OVERFLOW` at the operator span. `INT64_MIN / -1`
  overflows. `%` is Racket `remainder`, so `INT64_MIN % -1` is `0`; C must
  special-case it.
- Division and modulo by zero fail at the operator span. For Float, both
  `0.0` and `-0.0` divisors fail (`zero?`). Float `+ - *` never fail.
- `==` uses `=` for numbers (NaN differs from itself, `0.0 == -0.0`) and
  `equal?` otherwise. A `case` literal pattern uses `equal?` even for Float,
  so pattern `0.0` does not match `-0.0`.
- `-9223372036854775808` is legal: `check-unary` accepts the literal 2^63
  under unary minus without checking the literal (3.3).
- `Float.to_int` truncates and fails on NaN, infinity or a result outside
  Int. C checks `-2^63 <= x < 2^63` on the double before the cast.
- `String.to_int`/`to_float` first match ASCII regexes
  (`decimal-integer-pattern`, `decimal-float-pattern`), then convert. A long
  integer text in `to_float` becomes infinity, not an error. C uses `strtod`
  in the "C" locale (the VM never calls `setlocale`).
- Float text is Racket CS `number->string`. Take the shortest round-trip
  digits `d1 d2 ... dn` and decimal exponent `e` (value `d1.d2... x 10^e`).
  Use exponent form when `e < -4`, or when `e >= 0` and both `pos > 16` and
  `pos > sci`, where `pos` is the positional length (`n + 1` with a fraction,
  else `e + 3` for `ddd.0`) and `sci` is `n + (n > 1 ? 1 : 0) + 2 + digits(e)`.
  Exponents print as `e+14` and `e-5`; one digit has no point (`1e+21`).
  Otherwise print positionally with at least one fractional digit (`100.0`,
  `0.0001`). Specials: `+nan.0`, `+inf.0`, `-inf.0`, `-0.0`. This rule matched
  Racket on 200,000 random values and a grid of patterns. Shortest digits come
  from `snprintf("%.*e")` with precision 1 to 17, keeping the first that
  round-trips through `strtod`.

### 2.3 Strings and text

- Strings are sequences of Unicode scalar values. `length`, `at`, `slice`,
  `index_of`, `reverse` and `split(s, "")` count code points.
- `String.trim` removes exactly space, `\t`, `\n`, `\f` and `\r` (Racket's
  `\s`); NBSP, `\v` and U+3000 stay.
- `String.split(s, sep)` with a non-empty separator follows `string-split`:
  remove one separator match at the start and one at the end (if they
  overlap or meet, the text is empty), then split on every non-overlapping
  match; empty text gives `[]`. So `",,a,,"` gives `["", "a", ""]` and
  `"aaa"` split by `"aa"` gives `[]`.
- `String.replace` replaces every non-overlapping match; an empty `from`
  inserts at every position (`"abc"` gives `"xaxbxcx"`).
- `upcase` and `downcase` are full Unicode mappings with special cases
  (`"straße"` to `"STRASSE"`) and final sigma (`"ΑΣ"` to `"ας"`).
- The debug form of a String is Racket `write`: `\"`, `\\`,
  `\a \b \t \n \v \f \r \e`, and characters Racket does not print as graphic
  become `\uXXXX` or `\UXXXXXXXX` with uppercase hex (U+00AD, U+2028, U+E000,
  unassigned code points). Map-key, `index_of` and conversion messages use
  the same form (`format "~s"`): one shared C function.
- Text from stdin is decoded like a Racket port: each byte that does not
  start a complete valid UTF-8 sequence becomes one U+FFFD (`E2 82 63` gives
  two U+FFFD then `c`). `IO.gets` ends lines at LF, CR or CRLF.
- `System.args` on Linux and macOS: UTF-8, with `?` for each invalid byte.
  Under a non-UTF-8 locale Racket decodes differently; that case is outside
  the contract. Windows console input code pages are outside it too.

The case mapping, final-sigma and write-escape data are generated from
Racket itself by `vm/gen-unicode.rkt` into a committed `vm/unicode_data.c`,
so they agree with the reference by construction (Racket 9.3).

### 2.4 Printing values (`value->text`, `value->debug-string`)

- Text form: a String as is, a Json as its JSON text, anything else in debug
  form.
- Debug form: `nil`, `true`, Int, Float (2.2), String (2.3), `[a, b]`,
  `{k: v}` in insertion order, `Name(f: v, ...)` in declaration order,
  `Enum.Variant` or `Enum.Variant(a, b)`, `ok(v)`, `ok()` for Void,
  `error("msg")`, `<Json>`, `<Fn>`, `<Task>`, `<Socket>`, `<Listener>`,
  `<HttpClient>`, `<HttpServer>`, `<HttpBody>`, `<HttpWriter>`,
  `<FileHandle>`, `<Process>`.
- Struct and enum names are the display names the lowerer copies verbatim
  from the linked program, so the VM prints what the evaluator prints.
- JSON text (`write-json`): object keys sorted; strings escape `"`, `\`,
  control characters and DEL, with short forms such as `\n` and lowercase
  `\u007f` otherwise; non-ASCII stays raw; floats use 2.2.

### 2.5 Diagnostics, streams and exit codes

- Runtime diagnostics carry only code, message and span. Messages are copied
  verbatim from the Racket sources.
- The formats are `format-diagnostic`, `format-diagnostic-ai` (which also
  starts with `check failed: 1 error` at runtime) and `diagnostic->jsexpr` in
  `src/diagnostic.rkt`. Columns count characters; source lines split on LF
  with a trailing CR removed. JSON keys come out sorted: `code`, `file`,
  `message`, `range` (`end` before `start`, `column` before `line`).
- Order: like `fail!` in `src/main.rkt`, the VM writes the diagnostic to
  stderr and then exits; stdout is flushed by the exit. How the two streams
  interleave at buffer boundaries is outside the contract.
- Before each blocking stdin read, `if (isatty(1)) fflush(stdout)`, so
  prompts show up as they do with Racket.
- SIGPIPE is ignored at startup. Every `fwrite`/`fflush` result is checked; a
  failed write ends the run with `RUNTIME-INTERNAL`, exit 1.
- A diagnostic exits with 1. `System.exit(n)` exits with `n` only when
  `1 <= n <= 255`, else with 0 (Racket's exit handler). Normal end exits 0.
- `RUNTIME-INTERNAL` is at the program span. Its message text is not part of
  the contract and not compared.

### 2.6 JSON parsing (`read-json-value` in `src/json.rkt`)

- A first pass over the text rejects a raw character below U+0020 inside a
  string with `unescaped control character in a JSON string`. DEL (U+007F)
  passes.
- Any other syntax error, including a lone `\u` surrogate (high or low), is
  `invalid JSON`. A surrogate pair decodes to one character.
- Empty input is `expected a JSON value`; anything after the value other than
  space, tab, CR or LF is `unexpected content after the JSON value`; a number
  that is not finite is `JSON number is not finite`.
- Every message has the `JSON.parse: ` prefix. Numbers with a fraction or an
  exponent are Float (`1e2` is `100.0`); others are integers of any size.

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
(struct ir-program (sources types structs enums functions entry span))
(struct ir-struct (name fields))          ; display name; (field-name . type-index) in declaration order
(struct ir-enum (name variants))          ; list of (variant-name . arity)
(struct ir-function (name params captures slots body span))
(struct ir-label (id))
(struct ir-instr (op args spans))         ; args: slots, constants, indexes, label ids
```

- `body` is a flat list of `ir-instr` and `ir-label`; `--dump-ir` prints it.
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
| `for x in xs` | Iterable once, hidden index slot, `list-len`; `jump` to the test; body (starts with a statement `step`); increment; test `lt`, `jump-if-true` back to the body. `next` jumps to the increment. An empty body lowers to just the iterable: its iterations charge nothing and do nothing. |
| Functions | One IR function each; falling off the end returns Void. |
| Calls | A builtin (`builtin-ref name arity`, as `eval-call`) gives `call-builtin`, including the higher-order `List` functions (4.3); a user function gives `call`. |
| Structs | Arguments evaluated in written order directly into the slot of their declared position, then `struct`. A `construct` named `Enum.Variant` is an enum constructor (`eval-step-expression`). |
| Enums | Payload slots in order, then `enum` with a global variant id. |
| Lists, maps | `list` / `map` from consecutive slots. Literals longer than 255 elements are built in chunks joined with `List.concat`, or extended with `Map.put` (no steps, literal span). |
| Indexing | `list-get` or `map-get` from the type table. |
| `case` | Scrutinee once; per arm a test (`same` for literals, `is-variant`, `is-ok`), jump to the next arm, payload into arm slots (`_` skipped), body, jump to the end. |
| `try` | `try dst src`: on error, return it from the current function or block. |
| `ok`, `error`, `Result.*` | Builtin calls. |
| Interpolation | `to-text` per expression part, constants for string parts, joined with `concat`. |
| `.inspect` | `inspect`. `.to_s` follows what the checker resolved: the receiver itself for String, `String.from_int`/`from_float` for Int/Float, a one-part interpolation for other types. |
| `JSON.decode(s, User)`, `JSON.schema(User)` | The type argument is charged one step and lowers to a String constant with the struct's display name, as `type-expression` evaluates to its name. |
| `&name` | `closure` with no captures. |
| `f.call(...)` | `call-value` at the invoke span. |
| `return` | `return` of the value, or of a Void constant. Inside a block it leaves the block. |

### 3.4 Closure conversion

- A `block-lit` becomes an IR function named after its position. Its
  parameters are the block parameters.
- Its captures are its free variables in order of first use, including those
  only nested blocks use. The evaluator captures every visible variable
  (`capture-scopes`), but a block can only read them
  (`CHECK-CAPTURED-ASSIGNMENT`), so capturing just the used ones is not
  observable.
- At creation, captured values move into consecutive slots and `closure`
  runs. The block-lit node is charged one step, as now.
- At a call, the VM copies the captures into the callee's capture slots.
- A block returns the value of its final expression statement, or Void.
- `break` and `next` never cross a function or block (`CHECK-LOOP-CONTROL`),
  so they are plain jumps.

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
| | `CLOSURE` | a bx | Closure of function `bx`, captures from `R[a..]`, result in `R[a]` |
| Data | `LIST` | a b c | List of `R[b..b+c-1]` |
| | `LIST_LEN` | a b | Length of list `R[b]` |
| | `LIST_GET` | a b c | `R[b][R[c]]`; out of range fails at the index span |
| | `MAP` | a b c | Map from `c` key/value pairs at `R[b..b+2c-1]`, `mapping-put` rules |
| | `MAP_GET` | a b c | `R[b][R[c]]`; missing key fails at the index span |
| | `STRUCT` | a b c | Struct of type `c` from `R[b..]` in declaration order |
| | `FIELD` | a b c | Field `c` of struct `R[b]` |
| | `ENUM` | a b c | Variant `c` with payload `R[b..]` |
| | `IS_VARIANT` | a b c | Is `R[b]` variant `c`? |
| | `PAYLOAD` | a b c | Payload item `c` of enum `R[b]` |
| Result | `TRY` | a b | If `R[b]` is an error, return it; else `R[a]` = its value |
| | `IS_OK` | a b | Is `R[b]` ok? |
| | `RESULT_VALUE` | a b | Value of an ok, or message of an error (for `case`) |

That is 46 opcodes. Everything else, including `ok`, `error`, `puts` and every
module function, is a builtin; later subphases add builtins, not opcodes.

### 4.3 Calls, call windows and resumable builtins

`CALL a bx` starts the callee's frame at the caller's register `a`, so the
arguments are already the callee's parameters; the result lands in the
caller's `R[a]`. `CALL_VALUE` does the same one register higher, checks the
function value's parameter count against `b` at run time, and copies a
closure's captures after the parameters. The lowerer keeps call windows at
the top of the live registers; a corrupt file that breaks this mixes up
values but stays memory safe.

`List.map`, `filter`, `reduce`, `each`, `any?`, `all?` and `sort_by` are
**resumable builtins**. `CALL_BUILTIN` pushes a native frame whose state (the
list, the position, the partial result) lives in a GC object that bytecode
cannot reach. The interpreter asks it for the next callback call, pushes that
as a normal frame with the builtin's call span, and resumes the native frame
when the callback returns. So no builtin ever calls the interpreter from C,
iteration is bounded by the list length, and a task can block inside a
callback (7h). Native frames do not count toward call depth, matching the
evaluator. `sort_by` collects all keys first, then sorts (7.3).

### 4.4 Steps

The IR has one `step` per charged node. The 7d emitter merges only adjacent
`step`s with no label between them into one `STEP n`, splitting runs above
65535 because the count is 16 bits. Struct and variant ids are 16-bit
operands too, so the emitter rejects a program with more than 65535 structs
or variants. The charge points do
not move, so counts and failing spans stay exact. Wider merging across pure
instructions is left to 7g if profiling asks for it.

### 4.5 Builtin imports

The file lists the builtins it uses as `(name, arity)`, using the names and
arities of `src/builtins.rkt` (overloads such as `Map.get` and `ok` are
separate entries). The loader resolves each against the C table, comparing
length and bytes, and rejects unknown pairs. There are no internal helper
builtins.

### 4.6 File format

All integers are little-endian. `str` is a `u32` byte length plus UTF-8
bytes. Sections come in this fixed order; each starts with a `u32` count
(except the header and entry).

| Section | Entry |
|---|---|
| Header | magic `"AGCB"`, `u32` format version (1), `str` Agentica version (`src/version.rkt`) |
| Sources | `str` name, `str` full text |
| Spans | `u32` source, start line, start column, end line, end column; span 0 is the program span |
| Constants | `u8` kind (0 Void, 1 Nil, 2 false, 3 true, 4 Int, 5 Float, 6 String), then `i64`, `f64` bits or `str` |
| Types | `u8` kind (0 Int, 1 Float, 2 Bool, 3 String, 4 List, 5 Map, 6 Struct, 7 other), `u32` x, `u32` y (element, key/value, or struct index) |
| Structs | `str` display name, `u32` field count, each `str` name and `u32` type index |
| Enums | `str` display name, `u32` variant count, each `str` name and `u32` arity; variants numbered globally in file order |
| Builtins | `str` name, `u32` arity |
| Functions | `str` name, `u32` params, captures, registers, span, instruction count, the instructions, then one `u32` span index per instruction |
| Entry | `u32` index of `main` |

The type table exists for `JSON.decode` and `JSON.schema`; List and Map
entries must point to smaller indexes, so only Struct entries can make
cycles (recursive structs). The full source texts are embedded so the VM
prints diagnostics without reading files.

The VM accepts only its own format version and Agentica version; anything
else is rejected (8). Any change to the layout or to an opcode's meaning
bumps the format version. There are no compatibility shims: the Racket side
and the VM ship together.

## 5. Values in C

### 5.1 Representation

```c
typedef enum {
  AGC_T_VOID = 0, AGC_T_NIL, AGC_T_BOOL, AGC_T_INT, AGC_T_FLOAT,
  AGC_T_STRING, AGC_T_LIST, AGC_T_MAP, AGC_T_STRUCT, AGC_T_ENUM,
  AGC_T_RESULT, AGC_T_FN, AGC_T_JSON, AGC_T_HANDLE
} agc_tag;

typedef struct {
  uint32_t tag;
  union { bool b; int64_t i; double f; void *p; } as;   /* immediates write the full word: as.i = b */
} agc_value;                          /* 16 bytes, passed by value */
```

| Type | Representation |
|---|---|
| Void, Nil, Bool | Immediate. Tag 0 is Void, so zeroed registers are valid values. |
| Int, Float | `int64_t` (`__builtin_*_overflow`), `double`. |
| String | `{ size_t bytes, chars; char data[]; }`, `GC_MALLOC_ATOMIC`. `chars == bytes` means ASCII, O(1) indexing; otherwise indexing scans. Not NUL-terminated by contract. |
| List | `{ size_t len; agc_value items[]; }`, immutable. `append`, `set`, `concat` copy (same O(n) as now); indexing is O(1). |
| Map | `{ size_t size; agc_hamt *table; agc_keys *reversed; }`: a persistent 32-way HAMT plus a persistent cons list of keys, newest first, exactly like `mapping`/`mapping-put` in `src/runtime-values.rkt`. Keys are Int or String, hashed with SipHash-1-3 under a per-run key from OS entropy (independent of `--seed`). |
| Struct | `{ uint32_t type, n; agc_value fields[]; }`, declaration order. |
| Enum | `{ uint32_t variant, n; agc_value payload[]; }`; nullary variants are shared. |
| Result | `{ bool ok; agc_value value; }`; an error holds its String message; `ok()` holds Void. |
| Function value | `{ uint32_t function, n; agc_value captured[]; }`. |
| Json | Tree: null, bool, int64, big integer as decimal text (parsed integers may exceed Int until extracted), double, string, array, object. Objects are built by collecting pairs, then one sort and dedupe with the last value winning, which is the order `write-json` prints. |
| Handle (7h) | `{ uint32_t kind; void *resource; }` for Task, Socket, Listener, HTTP values, FileHandle, Process. |

### 5.2 Safety rules for values

- `value.c` is the only code that reads a union member. Everything else uses
  checked accessors that take the VM and a span, such as
  `agc_as_string(vm, v, span)` and `agc_as_list(vm, v, span)`; a wrong tag is
  `RUNTIME-INTERNAL`.
- `CALL_BUILTIN` checks each argument's tag against the parameter tags in the
  C builtin table before the call (generic parameters accept any tag).
  Builtins check list and map elements when they touch them
  (`agc_expect`).
- `FIELD` and `PAYLOAD` check the index against the value's own `n`, not
  only against the type table.
- Builtins that read builtin records (`Header`, `Request`, `Response`,
  `HttpClientOptions`, `HttpServerOptions`, `FileInfo`) check the struct type
  id; the loader accepts those names only with the exact field names and
  count of the C layout.
- Every String constructor either validates UTF-8 (no overlongs, no
  surrogates, at most U+10FFFF) or decodes with U+FFFD: argv, `Dir.list`,
  stdin, process and socket text, JSON `\u` escapes. Character counts are
  always computed, never read from a file.
- All size arithmetic goes through checked helpers (`agc_size_add`,
  `agc_size_mul`); a size overflow is an out-of-memory failure (6.3).

### 5.3 Boehm rules

- Objects holding `agc_value`s use `GC_MALLOC`; strings and byte buffers use
  `GC_MALLOC_ATOMIC`, which is not zeroed, so no code ever exposes an
  unfilled tail.
- Never store a GC pointer in `malloc` memory, in an atomic object, or in a
  `_Thread_local`: Boehm does not scan them. Pointers are never tagged. The
  one exception is `handle->data` and `SSL_set_app_data` in 7h, which may
  point to a GC object only while the resource registry also roots it (10.2).
- No GC finalizers for OS resources; closing is explicit (10.2).
- Roots (VM state, program, tasks) live in static storage or GC objects
  reachable from it.

## 6. Execution

### 6.1 Stack, call depth and steps

- Each task (one before 7h) owns a register array and a frame array, both
  `GC_MALLOC` (native frames point to their state) and grown by doubling. A
  call grows the registers to fit the callee's declared count; new registers
  are zeroed. Frames hold base offsets, never raw pointers:
  `{ uint32_t function, pc, base, ret; }`, or a native frame (4.3).
- The interpreter is one `switch` loop. Agentica calls push frames and never
  recurse on the C stack, so a 7h task switch only changes the current task.
- Before `CALL`, `CALL_VALUE` or a callback push, `depth >= 10000` fails with
  `RUNTIME-STACK-OVERFLOW` ("call depth limit exceeded") at that
  instruction's span, like `call-function` and `call-closure`. `main` runs at
  depth 1; native frames do not count; each task starts at 0. The register
  array is capped at 2^24 per task; passing the cap fails the same way. A
  valid program reaches it only with more than about 1,600 registers per
  frame at full depth, so this is a documented difference, not a hole.
- `steps_left` is an `int64_t`: the limit, or `INT64_MAX` without one. `STEP`
  is one compare and one subtraction. All tasks share it.

### 6.2 Failure, exit and cleanup

A runtime diagnostic always ends the run. `agc_fail(vm, code, message,
span)` records it and `longjmp`s to the `setjmp` in `agc_vm_run`, which runs
cleanup and returns an outcome (done, exit code, or diagnostic) to
`vm/main.c`. Only `main.c` prints and exits. `System.exit` takes the same
path.

Rules for `longjmp`: `agc_fail` is called only from interpreter and builtin
code running on the VM's own C stack, never from a libuv or OpenSSL
callback. Non-GC resources are registered before any call that can fail.
Locals live across `setjmp` are `volatile`.

Cleanup (kill and reap children, flush and close files, close sockets) runs
on every exit path: normal end, `System.exit`, diagnostics, out of memory,
and SIGINT/SIGTERM/SIGHUP (through `uv_signal_t`; console control events on
Windows). On Windows the VM also puts itself and its children in a
kill-on-close job object, which covers crashes.

### 6.3 Out of memory and GC aborts

At startup the VM sets `GC_set_oom_fn` and `GC_set_abort_func`. Their
handlers allocate nothing, kill child processes, `write(2, ...)` the fixed
line `agentica-vm: out of memory` and call `_exit(70)` (no atexit handlers,
no stdio flush, so buffered stdout is lost). Racket has no
matching diagnostic, so this is a documented difference.

## 7. Builtins in C

### 7.1 Calling convention

```c
typedef agc_value (*agc_builtin_fn)(agc_vm *vm, agc_value *args, uint32_t span);
```

`span` is the call's span index; argument `i` is at `span + 1 + i`. A
failing builtin calls `agc_fail` with the span the evaluator uses (`List.at`
uses its index argument, `Random.int` the call). `args` points into the
task's register array, which can move when it grows: a builtin never keeps
`args` across anything that pushes a frame or grows registers, and resumable
builtins copy what they need into their GC state.

### 7.2 Scope

7e: `IO`, `puts`, `print`, `gets`, `gets!`, `System`, `String`, `List`,
`Map`, `Float`, `Time`, `Random`, `ok`, `error`, `Result.*`, and `JSON`
(parse, extract, encode, builders, typed decode, schema: pure C, no event
loop). 7h: files, tasks, processes, TCP, TLS, HTTP, BDD.

### 7.3 Builtin safety and streams

- **Int bounds.** Every bounds check on an Int argument uses
  `__builtin_add_overflow` or the form `x < 0 || x > n - y`. A negative
  `int64_t` is never converted to `size_t` before the check.
- **No value-driven C recursion.** Printers, equality on nested data and every
  JSON operation (parse, encode, from, decode, schema) walk values with an
  explicit `GC_MALLOC`'d stack. Recursion is fine only when its depth is
  bounded by a constant or `log n` (HAMT levels, merge sort).
- **Strings to the OS.** `agc_cstr(vm, s)` copies a String, adds the NUL, and
  fails on an embedded NUL with the matching Racket message (for example
  "command must be nonempty and arguments cannot contain NUL" in
  `process.rkt`). It is the only way a String reaches an OS or library call.
- **Sorting.** `List.sort` and `sort_by` are a stable merge sort with
  `order<?`: strings by code point (UTF-8 byte order), numbers by `<`, NaN
  last.
- **Streams.** In 7e, stdin is one buffered reader over `read(0)`, shared by
  `gets`, `read`, `read_bytes` and `eof?`, like the single Racket port.
  Output uses C stdio; on Windows all three streams are in binary mode
  (`_setmode`), because Racket does not translate `\n`.

### 7.4 Random

The VM reproduces Racket's generator so `--seed` gives the same sequence on
both backends. Confirmed against Racket 9.3 with
`pseudo-random-generator->vector`:

- State: six MRG32k3a words stored newest first,
  `#(x1[n] x1[n-1] x1[n-2] x2[n] x2[n-1] x2[n-2])`. A draw is the standard
  step (`m1 = 4294967087`, `m2 = 4294944443`; multipliers 1403580, 810728,
  527612, 1370589) giving `z = (p1 - p2) mod m1`.
- `(random)` is `(double)(z + 1) * (1.0 / (m1 + 1))`, and `(random k)` for
  `k <= 4294967087` is `z * k / m1` in 64-bit integers: each matched 10,000 of
  10,000 draws (k = 1000 and k = 4294967087).
- `random-in-range` (larger ranges) is ported as written, with 128-bit
  unsigned arithmetic, since `size` reaches 2^64.

Plan: 7e ports `random-seed` (seed to six words) from Racket's source and
checks the state vector for seeds 0, 1, 2, 3, 12345 and 2147483647, then
1,000 draws of each kind. Fallback if it cannot be matched: `--seed`
sequences become backend-specific, `grammar.md` says so before 7i, and seeded
programs leave the differential corpus. Without `--seed`, the seed comes from
the OS (`getrandom`, `arc4random_buf`, `BCryptGenRandom`), in `0 .. 2^31-1`.

## 8. Loader safety

The loader validates the whole file before running anything. Failures print
`agentica-vm: invalid bytecode: <reason>` and exit with 2.

- **Input**: a regular file of at most 256 MiB. Every read is bounds-checked;
  every count is checked against the bytes left before allocating. All index
  and size sums use `uint64_t`.
- **Header**: magic, format version and Agentica version must match exactly;
  the file must end right after the entry.
- **Strings**: valid UTF-8 with no surrogates; character counts are computed.
- **Spans**: an existing source; `start <= end`; for both start and end,
  `1 <= line <= ` the source's line count and `1 <= column <=` the line's
  length in characters plus 1.
- **Tables**: known constant and type kinds; type operands in range, List and
  Map pointing to smaller indexes; field counts and arities fit 16 bits;
  builtin record names only with their exact C layout; builtin `(name,
  arity)` pairs exist.
- **Functions**: `params + captures <= registers <= 65535`; at least one
  instruction; the last is `RETURN` or `JUMP`; known opcodes; every register
  operand below `registers`, including ranges: `LIST` `b..b+c-1`, `MAP`
  `b..b+2c-1`, `STRUCT` `b..b+fields-1`, `ENUM` `b..b+arity-1`, call windows
  (`CALL` with the callee's parameter count, `CALL_VALUE` `a..a+b`,
  `CALL_BUILTIN` with its arity, `CLOSURE` with the captures); constant, function, builtin, type, struct,
  field, variant and span indexes in range, including the extra spans of
  `STEP` and `CALL_BUILTIN`; jump targets inside the function; `STEP` count at
  least 1.
- **Termination**: every backward jump targets a `STEP`, and every function
  that contains `CALL`, `CALL_VALUE` or `CALL_BUILTIN` starts with a `STEP`. The lowering in 3.3
  always meets both rules. Together they mean every unbounded repetition
  charges a step, so `--max-steps` holds even for hostile files.
- **Entry**: exists, with no parameters or captures.
- **Run time**: `CALL_VALUE` parameter counts, tags (5.2), list, map and
  string bounds, and the register cap (6.1).

Types are not verified statically; tag checks at run time are far simpler
and cost one predictable branch each.

## 9. CLI and packaging

- `agentica compile file.agc -o file.agcb` (7d) runs the front end and writes
  bytecode.
- `agentica-vm [--max-steps N] [--seed N] [--ai|--json] -- file.agcb
  [args...]` (7e; `--allow-run` joins in 7h). The option parser is hand
  written: it stops at the first non-option and honors `--`. Option values are
  checked with the same messages and exit code 2 as `src/main.rkt`. Callers
  always pass `--` before the file. A test checks that `--allow-run` after the
  file is a program argument. On Windows, arguments come from `wmain`
  (`-municode`) and are converted to UTF-8.
- `agentica-vm --version` prints the VM version and the versions of libgc
  (and libuv and OpenSSL from 7h).
- Tests in 7e and 7f spawn `dist/agentica-vm` directly.
- `agentica --vm file.agc` lands in 7i. It writes the bytecode to a temporary
  file with a random name, created exclusively with mode 0600
  (`#:exists 'error #:permissions #o600`); passes a hidden VM flag that
  deletes the input right after loading; under that flag the VM itself calls
  `prctl(PR_SET_PDEATHSIG, SIGKILL)` on Linux and then checks `getppid()` to
  close the race (Racket's `subprocess` cannot run code between fork and
  exec), and uses a kill-on-close job object on Windows; when the driver's
  ports are not file streams it copies them through pipes; and finds the VM relative to the
  installation (`define-runtime-path`, next to the executable), never in the
  current directory. `AGENTICA_VM` overrides it and is documented.
- `check`, `help` and `test` stay on Racket; 7h decides where BDD handlers
  run. `make vm` builds `dist/agentica-vm` (`.exe` on Windows); in 7i the
  release archive ships it in `bin/` next to `agentica`.

## 10. Dependencies and platforms

The VM runs on Linux, macOS and Windows, always in the "C" locale. Windows
specifics: binary-mode stdio, UTF-8 arguments from `wmain`,
`BCryptGenRandom`, `GetSystemTimePreciseAsFileTime`,
`QueryPerformanceCounter`; console rendering is outside the contract.

| Dependency | When | Choice |
|---|---|---|
| C compiler | 7e | C11, gcc or clang. Windows: MSYS2 UCRT64 gcc. No MSVC: it lacks `__builtin_*_overflow`, and one compiler family keeps one Makefile. |
| libc | 7e | Dynamic (static glibc breaks NSS; macOS forbids static libc). |
| Boehm GC | 7e | Static `libgc.a`: Debian `libgc-dev`, Homebrew `bdw-gc`, MSYS2 `mingw-w64-ucrt-x86_64-gc`. |
| libuv | 7h | Static: `libuv1-dev`, `libuv`, `mingw-w64-ucrt-x86_64-libuv`. |
| OpenSSL 3 | 7h | Static `libssl.a`/`libcrypto.a` from the same managers. |

### 10.1 Event loop: libuv, not libevent

| Need (current API) | libevent | libuv |
|---|---|---|
| TCP, timers (`TCP.*`, `Task.sleep`, timeouts) | Yes | Yes |
| Spawn with stdio pipes, kill, exit status (`Process.*`) | No; per-platform code by hand | `uv_spawn`, `uv_process_kill` |
| Child pipes with timeouts on Windows | No; Windows backends watch sockets only | `uv_pipe_t` (IOCP) |
| Stdin read in one task while others run, on a Windows console or pipe | No | `uv_tty_t` / `uv_pipe_t` |
| File I/O with timeouts and UTF-8 paths on Windows (`File.*`, `Dir.*`) | No | `uv_fs_*` on a thread pool |
| DNS | `evdns` | `uv_getaddrinfo` |
| TLS | `bufferevent_openssl` | None; OpenSSL with memory BIOs |

With libevent, Windows would need a hand-written process layer, helper
threads relaying pipe and console reads into the loop, and a separate file
path: most of what libuv is, and the hardest platform code to get right. So
the gap blocks `Process`, stdin and `File` on Windows, and the choice is
libuv. Its cost is about 200 lines to drive OpenSSL through memory BIOs.

### 10.2 Rules for 7h

- One OS thread runs the interpreter and the loop. Tasks are VM stacks. A
  blocking builtin starts a libuv request, parks its task, and the scheduler
  runs another ready task or `uv_run(UV_RUN_ONCE)`. Only the scheduler calls
  `uv_run`. libuv and OpenSSL callbacks only copy results and mark tasks
  ready.
- Racket threads are preemptive, so the scheduler also switches after a fixed
  number of instructions. Cross-task output order is not compared.
- Builtins that take a function (`Task.spawn`, `HTTP.listen` and
  `HTTP.listen_tls` handlers, `HTTP.request_stream`'s producer, `BDD.step`)
  run it as a new VM task; the ones that need its result await it.
- Stdin may be a TTY, pipe or file: `uv_guess_handle` picks the reader, and a
  file (`UV_FILE`) uses a `uv_fs_read` path. Stdout and stderr stay on
  blocking stdio.
- Files open with `O_NONBLOCK`, then `fstat` checks the kind. The libuv thread
  pool keeps its default size (4, `UV_THREADPOOL_SIZE`); this is documented.
- Thread-pool threads never touch GC memory. Requests and handles are
  `malloc`'d, and `uv_fs` buffers are `malloc`'d copies. The GC object that owns a handle sits in the run's resource
  registry (a GC object, like the registries in `src/process.rkt` and
  `src/filesystem.rkt`) until its `uv_close` callback; only then does it leave.
  `uv_write` and `uv_fs` buffers stay reachable from the registry until their
  callback. `handle->data` and `SSL_set_app_data` point to GC objects only
  while registered. `CRYPTO_set_mem_functions` is never routed to the GC.
- All VM file descriptors and handles are created non-inheritable
  (`O_CLOEXEC`, no handle inheritance on Windows).

### 10.3 TLS

- OpenSSL 3, which Racket's `openssl` module also uses. Initialize with
  `OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL)`.
- With an empty `ca_file`, use system trust like
  `ssl-secure-client-context`: on Linux, `SSL_CERT_FILE`/`SSL_CERT_DIR`, then
  well-known bundle paths (`/etc/ssl/certs/ca-certificates.crt`,
  `/etc/pki/tls/certs/ca-bundle.crt`, ...), because a static OpenSSL's
  built-in paths point at the build machine; on Windows only the `ROOT` store,
  on macOS only the Keychain anchors, never `set_default_verify_paths`. A
  non-empty `ca_file` replaces system trust. Trust-store usage and disallowed
  lists are honored only as far as Racket honors them.
- Per connection: `SSL_set1_host`, SNI set, IP literals through
  `X509_VERIFY_PARAM_set1_ip_asc`. There is no `SSL_VERIFY_NONE` path.
- Hermetic tests: wrong hostname, self-signed server without `ca_file`, and a
  `ca_file` that excludes system roots.

### 10.4 Processes

- `--allow-run` is the VM's own flag, checked inside `Process.spawn` at call
  time for every task and handler, as `current-process-allowed?` does.
- The VM resolves the executable itself, with one rule shared with Racket
  (PATH or a path relative to the working directory), and passes the absolute
  path to `uv_spawn`. All three stdio streams are pipes.
  `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS` is never used.
- Windows: after resolution, allow only `.exe` and `.com`, case-insensitively,
  and reject names with a trailing dot or space. The Racket check in
  `process.rkt` is case-sensitive today (`x.BAT` passes); it gets its own fix
  before 7h so both backends match. Whether the current directory is searched
  is decided once in `grammar.md` before 7h.

### 10.5 Limits the C runtime keeps

| Limit | Value | Racket source |
|---|---|---|
| `IO.read_bytes` count | 0..1 MiB | `max-read-bytes`, `evaluator.rkt` |
| Process send, read, line | 1 MiB | `bytes-limit`, `process.rkt` |
| File read, line, text, writes | 1 MiB | `bytes-limit`, `filesystem.rkt` |
| TCP send, receive, line | 1 MiB | `bytes-limit`, `network.rkt` |
| Byte values | 0..255 | `valid-bytes`, `network.rkt`; `process.rkt`; `String.from_bytes` |
| `List.repeat` count | 0..1048576 | `evaluator.rkt` |
| HTTP start and header line | 8192 bytes | `wire-line`, `http-wire.rkt` |
| HTTP header block | 65536 bytes | `http-wire.rkt` |
| HTTP headers | 100 | `http-wire.rkt` |
| HTTP interim responses | 16 | `http-wire.rkt` |
| `max_connections` | at most 65536 | `http-client.rkt` |
| HTTP body | `max_body_bytes`, 413 | `http-wire.rkt` |
| Process launch | `--allow-run` | `process.rkt` |
| Windows batch files | rejected | `process.rkt` |

HTTP numbers: `Content-Length` and chunk sizes accumulate with saturation:
parsing stops once a value exceeds the limit (413), and every comparison is
written `size > limit - total`. A hermetic test sends over-long values.

## 11. Build, CI and supply chain

- `make vm`: `$(CC) -std=c11 -O2 -Wall -Wextra -Werror`, hardening flags
  `-fstack-protector-strong -D_FORTIFY_SOURCE=2`, PIE and full RELRO
  (MinGW: `--dynamicbase --nxcompat --high-entropy-va`). Libraries via
  `pkg-config --atleast-version` minimums and the static archive path
  (`$(pkg-config --variable=libdir bdw-gc)/libgc.a`, which works on all three
  platforms). Output `dist/agentica-vm`.
- `make vm-test`: small C tests in `vm/tests/` with plain `assert`.
- `make vm SANITIZE=1`: clang with ASan and UBSan,
  `-fno-sanitize-recover=all`. In this build `agc_alloc` uses `calloc` and
  never frees, so ASan guards every object; libgc is not used for VM objects.
- GC stress: a `-DGC_DEBUG` build that calls `GC_gcollect()` every 64
  allocations (`AGC_GC_STRESS=1`). No Valgrind: conservative scanning makes
  it report many false errors.
- Fuzzing: `agc_fuzz_one(data, len)` loads one file and, if accepted, runs it
  with `--max-steps 10000`. A plain C driver mutates (truncation, bit flips)
  a corpus seeded with every compiled example; a clang job also builds it
  with `-fsanitize=fuzzer`.
- `make test` includes the VM tests. They first run `make -s vm`, so a stale
  `dist/agentica-vm` is rebuilt from its sources. They skip visibly when the
  VM cannot be built locally (no C compiler or libgc) and fail in CI
  (`AGENTICA_REQUIRE_VM=1`), as `AGENTS.md` requires.
- Supply chain: pinned runner images; `agentica-vm --version` and the release
  notes list the libgc, libuv and OpenSSL versions; the release checklist
  says to rebuild and release after any High or Critical OpenSSL advisory.

CI matrix:

| Job | Runner | Runs | Added in |
|---|---|---|---|
| Linux | pinned Ubuntu, `libgc-dev` | `make vm vm-test`, `make test`, smoke tests | first VM PR |
| Linux sanitizers | same, clang | sanitizer build, VM tests, corpus, fuzz run, GC stress | first VM PR |
| macOS | pinned macOS, `brew install bdw-gc pkgconf` | `make vm vm-test`, differential tests | follow-up PR |
| Windows | pinned Windows, `msys2/setup-msys2` UCRT64 (gcc, make, pkgconf, gc) | `make vm vm-test`, differential tests | follow-up PR |

Racket comes from `Bogdanp/setup-racket` everywhere, since the tests compile
with the front end. 7h adds libuv and OpenSSL to each job.

## 12. Testing and first PRs

### 12.1 Tests

- 7c `tests/lower-test.rkt`: one test per form (ops, slots, captures, spans).
  7d `tests/bytecode-test.rkt`: write, read back, compare; every example
  compiles.
- `tests/vm-diff-test.rkt` (from the first VM PR, completed in 7f) runs each
  program on the evaluator in-process (as `tests/examples-test.rkt` does,
  formatting with `src/diagnostic.rkt`) and on `dist/agentica-vm`, and
  compares stdout, stderr, exit code, and diagnostic code and span in all
  three formats. Inputs: `examples/`, `tests/eval/tasks/*` reference
  solutions and hidden cases, and `tests/fixtures/vm/` with one program per
  runtime code and error span.
- Every program also runs with `--max-steps` 1 to 200 and some larger values;
  the failing span must match. This covers 2.1 and 4.4, so the IR needs no
  step test. Programs using `Random` run with several `--seed` values.
- Generated corpora, checked by C tests against outputs from a Racket script:
  float text, split and trim, case mapping of every code point, write escapes.
- Extreme Int corpus under UBSan: `INT64_MIN`, -1, 0, n, n+1, `INT64_MAX` for
  every Int parameter of every builtin. Deep-value corpus: a depth-1,000,000
  enum chain and nested JSON array, printed and encoded.
- Tasks, processes and network programs join in 7h, with the independent
  counterparts the current tests use.

### 12.2 PR plan

Each PR keeps its own tests and docs and ticks its roadmap items.

1. **Vertical slice.** `#:types` in the checker; `src/lower.rkt`,
   `src/bytecode.rkt` and `vm/` for Int, Bool, `if`, `while`, functions,
   calls, returns, steps and `puts` of plain strings and Ints; the loader with
   full validation and the fuzz driver; `--dump-ir`, `agentica compile`;
   `make vm`, the Linux and sanitizer CI jobs, `tests/vm-diff-test.rkt`.
2. **Float and operators.** Float ops and Float text (2.2), `and`/`or`,
   comparisons, the remaining Int rules.
3. **Strings and printing.** Strings, interpolation, debug forms, the Unicode
   and write-escape generator, the three diagnostic formats, exit codes.
4. **macOS and Windows CI.**
5. **Data.** Lists, `for`, HAMT maps, structs, enums, `case`, Result, `try`,
   indexing errors, closures, `&name`, `.call`, resumable `List` builtins.
6. **Library.** `IO`, `System`, `String`, `List`, `Map`, `Float`, `Time`,
   `Random` (with the seeding port).
7. **JSON.** Parse, extract, encode, builders, typed decode, schema.

7e is done when every example runs on the VM with the same results, except
those that need files, processes, tasks or the network by name:
`file-summary`, `process-tool`, `concurrency`, `tcp_echo`, `http_get` and
`http_server`.

## 13. Open questions

- **Random seeding**: port planned in PR 6, fallback in 7.4.
- **BDD on the VM**: 7h decides whether handlers move to the VM.
