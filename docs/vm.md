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
| `src/bytecode.rkt` (7d) | IR to bytecode: label resolution, constant pool, builtin imports, struct, enum and span tables (type tables join with JSON), step merging, binary writer and reader. |
| `src/main.rkt` | `--dump-ir` (7c), `compile` (7d), `--vm` (7i). Printing and exit codes stay here. |
| `vm/` (7e) | The C VM: loader, values, interpreter loop, builtins, JSON, diagnostics, CLI driver. Builds `dist/agentica-vm`. |

**Status.** The vertical slice, the Float PR, the Strings PR, the macOS
and Windows CI, the Lists PR and the structs, enums and `case` PR (12.2
items 1 to 4, 5a and 5b) are in. The VM covers Int, Float, Bool, Nil and
String values, user structs and user enums (generic and recursive ones too,
imported ones included), and `List[T]` of any of them (lists of lists too),
locals, their operators (Float `+ - * /`, unary minus and comparisons with
IEEE semantics; String `+`, `==` and `!=`), `if`/`elsif`/`else`, `while` with
`break` and `next`, `for x in xs` with `break` and `next`, list literals,
indexing `xs[i]`, struct construction and field access, enum constructors,
`case` with literal, `_` and variant patterns, user functions, calls, `return`, interpolation,
`x.to_s` and `x.inspect` of those values, and `puts`/`print`/`IO.puts`/
`IO.print`/`IO.warn` of any of them. List library functions (`xs.size`,
`List.append`, ...) join with the `List` library (12.2 item 6). Runtime diagnostics come in the plain,
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
  `0.0` and `-0.0` divisors fail (`zero?`); a NaN divisor does not (the
  result is NaN). Float `+ - *` never fail: overflow gives `+inf.0`/`-inf.0`,
  `inf - inf` and `inf * 0.0` give NaN, underflow gives subnormals or `0.0`.
  Unary minus negates the sign bit (`-0.0` from `0.0`, NaN stays NaN and
  prints `+nan.0`). Float `%` does not exist (`CHECK-TYPE-MISMATCH`).
- Ordering with NaN on either side is false for `< <= > >=`, which is why
  `a > b` may lower to `lt b a`.
- Float literals are `digits.digits` only (no exponent syntax; `1e21` is a
  parse error). The lexer converts them with Racket `string->number`, and the
  bytecode carries the resulting double bit for bit, so the VM never parses
  decimal text. Infinity, NaN and subnormals reach programs only through
  arithmetic.
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
  `0.0001`). Specials: `+nan.0` (any NaN, whatever its sign), `+inf.0`,
  `-inf.0`, `-0.0`, `0.0`.
- Shortest digits are Racket's free-format digits (Burger and Dybvig), which
  differ from "correctly round to the first precision that round-trips" in
  two places: an exact tie at the last digit rounds up in magnitude
  (`11789751951819.5625` prints `11789751951819.563`, where `%.13e` gives
  `...562`), and at a power of two the rounding interval is asymmetric, so the
  shortest string may be the farther neighbor (`2^-1017` prints
  `7.120236347223045e-307`, not the nearer 17-digit form). `agc_float_text` in
  `vm/value.c` therefore prints the exact decimal expansion once
  (`snprintf("%.767e")`; `vm/tests/float_text_test.c` checks it against the
  full expansion of 2^-1074 on every CI job: exact on glibc, on the macOS
  libc (`macos-15`, arm64) and on Windows, where the build uses mingw-w64's
  own printf because `_POSIX_C_SOURCE` turns on `__USE_MINGW_ANSI_STDIO`.
  Verified in PR #44's CI: mingw-w64's printf, and the UCRT's printf and
  `strtod` in a probe run), and for each length tries the
  nearest candidate (ties up) and then the other neighbor, keeping the first
  that round-trips through `strtod`. Lengths start at 1 for subnormals and at
  15 for normal values: there a 15-digit step is at least 4.5 ulp, so a
  shorter form is the nearest 15-digit candidate with trailing zeros, which
  are trimmed. One-off runs during PR #42 matched Racket 9.3 on about 1.9
  million values (random bit patterns, subnormals, every power of two and its
  neighbors, decimal grids from 1e-330 to 1e309, dyadic values with exact
  ties, random arithmetic chains); the lasting checks are the 40 values in
  `vm/tests/float_text_test.c` and the `float-text` differential fixture.
  The algorithm reads only the first 18 exact digits (index 17 decides the
  nearest candidate). A `%.40e` print gives them unless rounding carried
  into them, which needs digits 18 to 40 of its output to be all `0`; then,
  unless the value has at most 34 fractional bits and is below 1e40 (so
  `%.40e` is exact and the zeros are real), the 768-digit print runs as
  before. A scratch comparison of the two paths agreed on 7 million values
  (5 million random bit patterns, every power of two with both neighbors,
  decimal and integer grids). Printing costs about 1 µs per value (about
  5 µs on the slow path) plus a few `snprintf`/`strtod` pairs; 7g revisits
  it.

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
Racket itself by `vm/tools/gen-unicode.rkt` into a committed `vm/unicode_data.c`,
so they agree with the reference by construction (Racket 9.3).
`make vm-unicode` regenerates the file (about 40 s; run it with Racket CS 9.3,
the CI version, since the tables follow Racket's Unicode data), and the Linux CI job
fails when the committed file differs from what the generator prints.

- In the slice: only the write-escape data exists, as three range tables
  derived from Racket's output, not written by hand: code points `write`
  prints as themselves (`agc_write_raw_ranges`), joiners that print raw
  only after a raw non-blank character (`agc_write_joiner_ranges`: U+200C,
  U+200D and U+E0020 to U+E007F), and blanks (`agc_write_blank_ranges`: the
  17 `Zs` characters U+0020, U+00A0, U+1680, U+2000 to U+200A, U+202F,
  U+205F, U+3000).
- `agc_write_form` takes printable ASCII other than `"` and `\` (0x20 to
  0x7E) raw without a table search; that is what the tables give for them,
  and the exhaustive pair test in `vm/tests/text_test.c` covers it.
- The C rule in `agc_write_form`, with `join` false at the start: the ten
  short escapes above; else raw when the code point is in the raw table,
  or `join` is true and it is a joiner; else `\uXXXX` below U+10000 and
  `\UXXXXXXXX` above. Then `join = raw && !blank`. So `"a\u200D\u200D"`
  prints both joiners raw, while a joiner at the start, after a blank or
  after an escaped character is escaped; family emoji and flag tag
  sequences print raw.
- The generator checks this rule against `(format "~s" ...)` for every code
  point alone, after `a`, before U+200D and before U+E0041; for every pair
  of joiners after 14 prefixes (empty, letters, blanks, an escape, a
  combining mark, an emoji, joiners), also with `a` or a space between
  them; and for one string holding every code point. It stops if Racket
  ever prints something else. The case-mapping tables join with the
  `String` library (12.2 item 6).

### 2.4 Printing values (`value->text`, `value->debug-string`)

- Text form: a String as is, a Json as its JSON text, anything else in debug
  form.
- Debug form: `nil`, `true`, Int, Float (2.2), String (2.3), `[a, b]`,
  `{k: v}` in insertion order, `Name(f: v, ...)` in declaration order,
  `Enum.Variant` or `Enum.Variant(a, b)`, `ok(v)`, `ok()` for Void,
  `error("msg")`, `<Json>`, `<Fn>`, `<Task>`, `<Socket>`, `<Listener>`,
  `<HttpClient>`, `<HttpServer>`, `<HttpBody>`, `<HttpWriter>`,
  `<FileHandle>`, `<Process>`.
- A list prints its items in debug form even in the text form:
  `puts(["a"])` prints `["a"]`. Only a String at the top is printed raw.
- Struct and enum names are the display names the lowerer copies verbatim
  from the linked program, so the VM prints what the evaluator prints.
  Today that includes the linker's internal prefix for imported types
  (`@2::Point(x: 1)`, `@2::Shape.Dot`), an evaluator bug; when the evaluator
  is fixed, the lowerer copies the fixed name and the VM follows.
- A struct prints its fields in declaration order whatever order the
  constructor wrote them in; a struct with no fields prints `Name()`, a
  nullary variant `Enum.Variant` (with no parentheses even when written
  `Enum.Variant()`).
- JSON text (`write-json`): object keys sorted; strings escape `"`, `\`,
  control characters and DEL, with short forms such as `\n` and lowercase
  `\u007f` otherwise; non-ASCII stays raw; floats use 2.2.

### 2.5 Diagnostics, streams and exit codes

- Runtime diagnostics carry only code, message and span. Messages are copied
  verbatim from the Racket sources.
- `--ai` prints `check failed: 1 error`, a blank line, `[CODE]`, then
  `  message: `, `  at: file:line:column` and `  source: ` with the span's
  first source line trimmed by `string-trim`, which removes only ASCII
  space, `\t`, `\n`, `\f` and `\r` at both ends (Racket's `\s`; `\v` and
  NBSP stay). `--json` prints one line; `jsexpr->string` escapes `"`, `\`,
  `\b \f \n \r \t` in short form and the other bytes below 0x20 and DEL as
  lowercase `\u00XX`, and leaves everything else raw, so the VM's JSON is
  byte-for-byte the evaluator's even for odd file names.
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
- SIGPIPE is ignored at startup (Windows has none). Every `fwrite`/`fflush` result is checked; a
  failed write ends the run with `RUNTIME-INTERNAL`, exit 1. Documented
  difference: when stdout cannot be written (a full disk, `/dev/full`), the
  evaluator prints a Racket error and still exits 0.
- Source names and source lines are printed as raw bytes in the plain and
  `--ai` formats, like Racket, control characters included. Filtering them
  would protect nothing: any program can print any bytes with `puts` or
  `IO.warn`.
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
(struct ir-program (sources structs enums functions entry span))
(struct ir-struct (name fields))          ; display name; field names in declaration order
(struct ir-enum (name variants))          ; list of (variant-name . arity)
(struct ir-function (name params captures slots body span))
(struct ir-label (id))
(struct ir-instr (op args spans))         ; args: slots, constants, indexes, label ids
```

- `body` is a flat list of `ir-instr` and `ir-label`; `--dump-ir` prints it.
- In the slice, `ir-function` is `(name params slots body span)`; the
  capture field joins with closures (5e). `ir-program` has every field.
  The tables hold every struct and enum declaration of the linked program in
  declaration order. Enums are generic only in their checked types, so the
  table needs only each variant's arity. Field types are not in the IR yet:
  only `JSON.decode` and `JSON.schema` need them, and the JSON PR (12.2
  item 7) adds them.
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
| `for x in xs` | Iterable once into a hidden slot (a `move` even for a local, since the body may assign that local), hidden index, length and one slots (`const 0`, `list-len`, `const 1`, set once); `jump` to the test; body; increment (`add-i`); test `lt-i`, `jump-if-true` back to the body. The body starts with its first statement's `step`, then `list-get x xs i` (span of the `for`), then the rest of that statement: the backward jump must land on a `STEP` (8), and the read charges nothing. `next` jumps to the increment, `break` past the test. An empty body lowers to just the iterable: its iterations charge nothing and do nothing. |
| Functions | One IR function each; falling off the end returns Void. |
| Calls | A builtin (`builtin-ref name arity`, as `eval-call`) gives `call-builtin`, including the higher-order `List` functions (4.3); a user function gives `call`. |
| Structs | `step` (construct span); arguments evaluated in written order directly into the slot of their declared position, then `struct`. A `construct` named `Enum.Variant` is an enum constructor (`eval-step-expression`). Field access: `step` (node span), target, then `field` with the declared index. A struct type that is not declared in the program (a builtin record such as `Header`) stays `LOWER-UNSUPPORTED`. |
| Enums | `step` (constructor span), payload slots in order, then `enum` with a global variant id; a nullary variant is `enum dst dst v`. |
| Lists, maps | `list` / `map` from consecutive slots. Literals longer than 255 elements are built in chunks joined with `List.concat`, or extended with `Map.put` (no steps, literal span). For a list: the accumulator slot `w`, each chunk's elements in `w+1..`, the first chunk `list w`, every later one `list w+1` then `call-builtin w List.concat 2`, so a literal needs at most 256 slots beside its elements' own temporaries. An empty literal is `list dst dst 0`. |
| Indexing | `list-get` or `map-get` from the type table. `step` (index node), target, index, then `list-get` at the index expression's span, which is where `RUNTIME-INDEX-OUT-OF-RANGE` ("index -1 is outside a list of length 3") points. |
| `case` | Scrutinee once (a local is read in place: tests and payload reads all come before any body runs); per arm a test (`const` + `same` for literals, `is-variant`, `is-ok`), `jump-if-false` to the next arm, payload into arm slots (`_` skipped), body in its own scope through `lower-statement`, jump to the end. Patterns charge no steps. `_` has no test. An Int literal pattern outside 64 bits (the checker accepts `9223372036854775808 ->`) can never match, so its test is a plain `jump` to the next arm. Result patterns join with 5c. Until then nothing in `case` checks for them: the scrutinee goes through the type check of every expression, which rejects a Result value with `LOWER-UNSUPPORTED` at the scrutinee, so no Result pattern is ever reached. |
| `try` | `try dst src`: on error, return it from the current function or block. |
| `ok`, `error`, `Result.*` | Builtin calls. |
| Interpolation | `step`, then the first part straight into the target; each later part into the next free slot, then `concat target target slot`. A string part is a `const`; an expression part is lowered as usual and followed by `to-text slot slot` unless it is a String. String parts charge no step. |
| `.inspect` | `inspect`. `.to_s` follows what the checker resolved: the receiver itself for String, `String.from_int`/`from_float` for Int/Float, a one-part interpolation for other types. A `method-call` or `field-access` with `resolved` set lowers its resolved node without a step, and a `typed-target` lowers its expression, as `eval-expression` does. |
| `JSON.decode(s, User)`, `JSON.schema(User)` | The type argument is charged one step and lowers to a String constant with the struct's display name, as `type-expression` evaluates to its name. |
| `&name` | `closure` with no captures. |
| `f.call(...)` | `call-value` at the invoke span. |
| `return` | `return` of the value, or of a Void constant. Inside a block it leaves the block. |
| Assignment to an existing local | Value into a temporary, then `move`. `and`/`or` write their target before the right side runs, so lowering straight into the local would let `x = y and x` read the new `x`. A new local is lowered straight into its slot. |

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
enums declared in the program, and `List` of those (nested to any depth) is
rejected, except a Void call used as a statement or returned. A struct or
enum type is accepted whatever its fields or payloads hold: a value of an
unsupported type can only come from an expression the lowerer rejects. The only builtins a program may call are `puts`,
`IO.print`, `IO.warn`, `String.from_int` and `String.from_float` (their
implementation keys; `print` and `IO.puts` map to the first two). The last
two exist because the checker resolves `x.to_s` on Int and Float to them.
`List.concat` is in the C table too, but only the lowerer emits it, for
long literals (3.3); a written call to it stays `LOWER-UNSUPPORTED` until
the `List` library PR. No core form turns into a `List` library call: `for`,
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

Opcode numbers are positions in one list shared by `opcodes` in
`src/bytecode.rkt` and `agc_opcode` in `vm/agc.h`. Each PR appends the
opcodes it implements, so there are no numbers for unimplemented ones. In the
slice the list is `MOVE CONST STEP ADD_I SUB_I MUL_I DIV_I MOD_I NEG_I NOT
LT_I LE_I EQ NE JUMP JUMP_IF_FALSE JUMP_IF_TRUE CALL CALL_BUILTIN RETURN`
(20 opcodes); the Float PR appended `ADD_F SUB_F MUL_F DIV_F NEG_F LT_F
LE_F` (27); the Strings PR appended `CONCAT TO_TEXT INSPECT` (30); the Lists
PR appended `LIST LIST_LEN LIST_GET` (33); the structs, enums and `case` PR
appended `STRUCT FIELD ENUM IS_VARIANT PAYLOAD SAME` (39). `EQ`/`NE`
accept Int, Float (C `==`, which is Racket `=`), Bool, Nil or String pairs
(String by length and bytes, which is `equal?` on valid UTF-8); other pairs
are `RUNTIME-INTERNAL`. The checker allows `==` only on Int, Float, Bool,
String and Nil (`CHECK-TYPE-MISMATCH` otherwise), so lists never reach
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
`RUNTIME-INTERNAL`.

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
| Header | magic `"AGCB"`, `u32` format version (2), `str` Agentica version (`src/version.rkt`) |
| Sources | `str` name, `str` full text |
| Spans | `u32` source, start line, start column, end line, end column; span 0 is the program span |
| Constants | `u8` kind (0 Void, 1 Nil, 2 false, 3 true, 4 Int, 5 Float, 6 String), then `i64`, `f64` bits or `str` |
| Structs | `str` display name, `u32` field count, each field's `str` name |
| Enums | `str` display name, `u32` variant count, each `str` name and `u32` arity; variants numbered globally in file order |
| Builtins | `str` name, `u32` arity |
| Functions | `str` name, `u32` params, captures, registers, span, instruction count, the instructions, then one `u32` span index per instruction |
| Entry | `u32` index of `main` |

The full source texts are embedded so the VM prints diagnostics without
reading files.

Format version 2 (the structs, enums and `case` PR) fills the Structs and
Enums sections; version 1 had three empty sections there (Types, Structs,
Enums). Version 2 has no Types section: the type data that `JSON.decode`
and `JSON.schema` need (a type table with List and Map entries pointing to
smaller indexes, so only struct entries make cycles, and a type index per
struct field) joins with the JSON PR (12.2 item 7) and its own format bump.
All seven constant kinds are in use; Float constants are the literal's IEEE
bits.

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
} agc_tag;                            /* the full set; vm/agc.h grows toward it */

typedef struct {
  uint32_t tag;
  union { bool b; int64_t i; double f; void *p; } as;   /* immediates write the full word: as.i = b */
} agc_value;                          /* 16 bytes, passed by value */
```

| Type | Representation |
|---|---|
| Void, Nil, Bool | Immediate. Tag 0 is Void, so zeroed registers are valid values. Today `vm/agc.h` has Void, Nil, Bool, Int, Float, String and List, in the order above. |
| Int, Float | `int64_t` (`__builtin_*_overflow`), `double`. |
| String | `{ size_t bytes, chars; char data[]; }`, `GC_MALLOC_ATOMIC`. `chars == bytes` means ASCII, O(1) indexing; otherwise indexing scans. Not NUL-terminated by contract. |
| List | `{ size_t len; agc_value items[]; }`, immutable. `append`, `set`, `concat` copy (same O(n) as now); indexing is O(1). |
| Map | `{ size_t size; agc_hamt *table; agc_keys *reversed; }`: a persistent 32-way HAMT plus a persistent cons list of keys, newest first, exactly like `mapping`/`mapping-put` in `src/runtime-values.rkt`. Keys are Int or String, hashed with SipHash-1-3 under a per-run key from OS entropy (independent of `--seed`). |
| Struct | `{ uint32_t type, n; agc_value fields[]; }`, declaration order. Text: the struct's display name, then `(f: v, ...)` from the table's field names. |
| Enum | `{ uint32_t variant, n; agc_value payload[]; }`; nullary variants are shared (one object per variant, made at load time). Text: enum display name, `.`, variant name, then `(a, b)` when `n > 0`. |
| Result | `{ bool ok; agc_value value; }`; an error holds its String message; `ok()` holds Void. |
| Function value | `{ uint32_t function, n; agc_value captured[]; }`. |
| Json | Tree: null, bool, int64, big integer as decimal text (parsed integers may exceed Int until extracted), double, string, array, object. Objects are built by collecting pairs, then one sort and dedupe with the last value winning, which is the order `write-json` prints. |
| Handle (7h) | `{ uint32_t kind; void *resource; }` for Task, Socket, Listener, HTTP values, FileHandle, Process. |

### 5.2 Safety rules for values

- `value.c` is the only code that reads a union member. Everything else uses
  checked accessors that take the VM, such as `agc_as_string(vm, v)` and
  `agc_as_list(vm, v)`; a wrong tag is `RUNTIME-INTERNAL`, always at the
  program span (2.5), so the accessors need no span.
- `CALL_BUILTIN` checks each argument's tag against the parameter tags in the
  C builtin table before the call (generic parameters accept any tag).
  Builtins check list and map elements when they touch them
  (`agc_expect`).
- `FIELD` and `PAYLOAD` check the index against the value's own `n`, not
  only against the struct and enum tables.
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
  `{ uint32_t function, pc, base, ret; }`, or a native frame (4.3). In the
  slice a frame is `{ function, pc, base }`: `RETURN` writes the callee's
  base register, which is the caller's `R[a]`; `ret` joins with
  `CALL_VALUE`, whose result register differs from its window.
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
line `agentica-vm: out of memory` (the abort handler: `agentica-vm: internal
GC error`) and call `_Exit(70)` (no atexit handlers, no stdio flush, so
buffered stdout is lost). Racket has no matching diagnostic, so this is a
documented difference.

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
  and size sums use `uint64_t`. Loading has a memory budget of 4 times the
  file length plus 1 MiB; every allocation is charged to it first, and a file
  that needs more is rejected.
- **Header**: magic, format version and Agentica version must match exactly;
  the file must end right after the entry.
- **Strings**: valid UTF-8 with no surrogates; character counts are computed.
- **Spans**: an existing source; `start <= end`; for both start and end,
  `1 <= line <= ` the source's line count and `1 <= column <=` the line's
  length in characters plus 1.
- **Tables**: known constant kinds (and, with JSON, type kinds and type
  operands in range); field counts and arities fit 16 bits;
  builtin record names only with their exact C layout; builtin `(name,
  arity)` pairs exist.
- **Functions**: `1 <= registers <= 65535` and `params + captures <= registers`; at least one
  instruction; the last is `RETURN` or `JUMP`; known opcodes; every register
  operand below `registers`, including ranges: `LIST` `b..b+c-1`, `MAP`
  `b..b+2c-1`, `STRUCT` `b..b+fields-1`, `ENUM` `b..b+arity-1`, call windows
  (`CALL` with the callee's parameter count, `CALL_VALUE` `a..a+b`,
  `CALL_BUILTIN` with its arity, `CLOSURE` with the captures); constant, function, builtin, type, struct,
  field, variant and span indexes in range, including the extra spans of
  `STEP` and `CALL_BUILTIN`; jump targets inside the function; `STEP` count at
  least 1.
- **Termination**: every backward jump targets a `STEP`, and every function
  starts with a `STEP` unless it has at most 2 instructions and no `CALL`,
  `CALL_VALUE` or `CALL_BUILTIN` (the `const`/`return` of an empty body). The
  lowering in 3.3 always meets these rules. Together they mean every
  unbounded repetition charges a step, so `--max-steps` holds even for
  hostile files: the step budget bounds the number of instructions to about
  steps × code size. It does not bound bytes: `CONCAT` and `INSPECT` cost
  time and memory in proportion to their strings (trust model, 1).
- **Entry**: exists, with no parameters or captures.
- **In the slice**: captures must be 0; constant kinds above 6 are
  rejected. Struct field counts and variant arities are at most 65535. All
  variants go into one array sized by a first pass over the Enums section,
  and each nullary variant gets one small shared empty enum value, so a file
  with 65535 variants or a struct with 65535 fields stays within the load
  budget. `load_alloc` returns NULL for a zero size without charging the
  budget; callers never read or copy through a zero-size result.
  `STRUCT` checks `a`, `c`
  below the struct count and the window of that struct's field count;
  `ENUM` checks `a`, `c` below the variant count and the window of its
  arity (`b` itself when it is 0); `IS_VARIANT` checks two registers and the
  variant id; `FIELD` and `PAYLOAD` check two registers and `c` below the
  largest field count or arity (the run time checks the value's own `n`);
  `SAME` checks three registers. Builtin record layouts are not checked
  yet: the lowerer rejects builtin record types, and the check joins with
  the first library PR that reads one. `CONCAT`
  checks three registers, `TO_TEXT` and `INSPECT` two. `LIST` checks `a`
  and the window `b..b+c-1` (and `b` itself when `c` is 0), `LIST_LEN` two
  registers and `LIST_GET` three. `vm/tests/loader_test.c` checks each rejection by its reason:
  truncation at every byte, bad magic and versions, trailing bytes, entry out
  of range or with parameters, unknown builtins, invalid UTF-8 (overlong,
  surrogate, above U+10FFFF, and a truncated sequence in a String
  constant), span lines and columns out of range and spans
  that start after they end, bad register counts (0, above 65535, fewer than
  the parameters), out-of-range registers, constants, jumps and spans
  (including the extra spans of `STEP` and `CALL_BUILTIN`, and the
  registers of the Float, String, List, struct and enum opcodes, and the
  `LIST`, `STRUCT` and `ENUM` windows), every struct and enum table rule
  above (and that 65535 nullary variants and 65535 fields load), `CALL` and
  `CALL_BUILTIN` windows, `STEP 0`, a backward jump that misses a `STEP`,
  functions that should start with one, an unknown opcode, a missing final
  `RETURN`/`JUMP`, and a file over the memory budget.
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
  (`-municode`) and are converted to UTF-8; the input file is opened with `_wopen` on the original UTF-16 argument, so
  non-ASCII paths load and a lone surrogate never maps to another file. The
  size comes from `_fstat64`, so a file over 2 GiB is rejected, not read
  as a prefix. Paths over 260 characters fail with `_wopen` unless they use
  `\\?\` or the executable has a `longPathAware` manifest; 7h decides. A
  differential test runs a copy named `cálculo-λ-日本-𝔸.agcb`, and a CRLF
  program under a non-ASCII directory.
- `agentica-vm --version` prints the VM version and the versions of libgc
  (and libuv and OpenSSL from 7h).
- In the slice the VM accepts `--version`, `--max-steps N`, `--ai`, `--json`
  and `--`. `--seed` joins with `Random` (PR 6); until then it is an
  unknown option (exit 2). `--ai` and `--json` may both appear; the last one
  wins, as with `command-line`. Giving one option twice prints `agentica-vm:
  the --ai option can only be specified once`. Racket's `command-line`
  exits 1 for every option error it raises itself (a repeated option, an
  unknown switch, a missing value); the VM exits 2 for all of them, since
  the 7i driver parses the user's options itself. Value errors that
  `src/main.rkt` checks (`--max-steps needs a positive integer`) exit 2 on
  both.
  Arguments after the file are accepted and unused until `System.args`
  lands.
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
Paths over 260 characters (`MAX_PATH`) fail with `_wopen` today; 7h, which
opens files, picks `\\?\` prefixes or a `longPathAware` manifest.

| Dependency | When | Choice |
|---|---|---|
| C compiler | 7e | C11, gcc or clang. Windows: MSYS2 UCRT64 gcc. No MSVC: it lacks `__builtin_*_overflow`, and one compiler family keeps one Makefile. |
| libc | 7e | Dynamic (static glibc breaks NSS; macOS forbids static libc). |
| Boehm GC | 7e | Vendored: git submodule `vm/third_party/bdwgc`, pinned to tag v8.2.12. `make vm` compiles its single-file amalgamation (`extra/gc.c`) and links it statically (with `-lpthread` on Linux and macOS). No system package. |
| libuv | 7h | Vendored the same way: a git submodule from `https://github.com/libuv/libuv` pinned to a recent release tag, added in 7h when it is first needed, built from source and linked statically. No system package. |
| OpenSSL 3 | 7h | Static `libssl.a`/`libcrypto.a` from the platform package managers (Debian, Homebrew, MSYS2). |

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
  `-fstack-protector-strong -D_FORTIFY_SOURCE=2`, PIE and full RELRO on
  Linux; macOS links PIE by default and has no RELRO; MinGW uses
  `--dynamicbase --nxcompat --high-entropy-va` instead, links `vm/main.c`
  with `-municode`, and every binary gets the `.exe` suffix. The Makefile
  picks the platform from `OS=Windows_NT` or `uname -s`. The warning flags
  apply to our own `vm/*.c` only. libgc is compiled once from the submodule
  (`$(CC) -std=c11 -O2 -fPIE -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION
  -I vm/third_party/bdwgc/include -c vm/third_party/bdwgc/extra/gc.c`, about
  3 s) into `build/vm/gc.o` and linked with `-lpthread` (not on Windows).
  The two defines are what bdwgc's configure and CMake builds set.
  `NO_EXECUTE_PERMISSION` maps the heap without execute permission: macOS on
  arm64 refuses writable and executable pages (`Cannot allocate executable
  pages` once the heap grows), and Linux no longer gets RWX heap pages.
  bdwgc always honors interior pointers from the stack and registers;
  `ALL_INTERIOR_POINTERS` extends that to pointers stored in GC objects and
  static data and to one-past-the-end pointers, at one extra byte per
  object. Nothing in the VM relies on it today; it is upstream's default and
  costs nothing measurable. libuv follows the same pattern in 7h. OpenSSL (7h)
  comes through `pkg-config --atleast-version` and its static archive path.
  The Agentica version is read from `src/version.rkt` with `sed`, so the VM
  build needs no Racket. Output `dist/agentica-vm`. The compiler flags are
  recorded in `build/vm/flags`, so switching between a normal and a sanitizer
  build always relinks.
- `make vm-test`: small C tests in `vm/tests/` with plain `assert`.
- `make vm SANITIZE=1`: clang with ASan and UBSan,
  `-fno-sanitize-recover=all`. In this build `agc_alloc` uses `calloc` and
  never frees, so ASan guards every object; libgc is not compiled or linked
  at all (`-DAGC_NO_GC`). Leak detection is off because nothing is freed, and
  `allocator_may_return_null=1` lets a huge request reach the out-of-memory
  path (6.3) instead of aborting.
  `make vm-test SANITIZE=1` and `make vm-fuzz SANITIZE=1` use the same flags.
- GC stress: `make vm-gc-stress` builds `build/vm/gcstress/agentica-vm`
  with `GC_STRESS=1` (`-DGC_DEBUG -DAGC_GC_STRESS`, gcc): `agc_alloc` and
  `agc_alloc_atomic` call `GC_gcollect()` every 64 allocations, and
  `GC_DEBUG` adds the debug headers whose smashed-object report on stderr
  would fail the comparison. It runs `make vm-test` with those flags and
  `tests/vm-diff-test.rkt` on that binary (`AGENTICA_VM_BINARY` points the
  test at it; `dist/agentica-vm` is left alone). The Linux sanitizers job
  runs it. No Valgrind: conservative scanning makes it report many false
  errors.
- Fuzzing: `agc_fuzz_one(data, len)` (`vm/fuzz.c`) loads one file and, if
  accepted, runs it with `--max-steps 10000` and prints any diagnostic, all
  to `/dev/null`, so the diagnostic printer is fuzzed too. It is linked only
  into the fuzz and test binaries. The plain C driver (`vm/fuzz_main.c`,
  `make vm-fuzz`) applies 1 to 4 mutations per run (byte deletion and
  insertion, bit flips, random bytes, small or maximal 16-bit operands) to a
  corpus seeded with every
  compiled program in `tests/fixtures/vm/`; examples join the corpus as they
  enter the VM subset. The driver's random sequence is fixed, so every PR's
  short run (30,000 mutants in the sanitizer job, about 12 s) is
  reproducible; `FUZZ_SEED=N` picks another sequence and is printed on
  stderr. In a sanitizer build a crash prints the mutant's index and saves
  it to `fuzz-crash.agcb`. The weekly workflow (`.github/workflows/fuzz.yml`,
  also run by hand) builds the sanitizer VM, runs 5 million mutants with a
  random `FUZZ_SEED`, prints the commit and seed first, and uploads
  `fuzz-crash.agcb` as an artifact on failure; `agentica-vm --` on that
  file, or the same commit, seed and at least as many runs, reproduces it. A clang
  job also builds it with `-fsanitize=fuzzer` (later PR).
- `make test` includes the VM tests. They first run `make -s vm`, so a stale
  `dist/agentica-vm` is rebuilt from its sources. They skip visibly when the
  VM cannot be built locally (no C compiler, or the submodule is not checked
  out) and fail in CI (`AGENTICA_REQUIRE_VM=1`), as `AGENTS.md` requires.
  `make vm` reads `SANITIZE` from the environment, so the sanitizer job sets
  `SANITIZE=1` once and the tests rebuild the sanitized VM.
- Supply chain: pinned runner images; libgc (and libuv from 7h) are git
  submodules pinned to a release tag, upgraded only by bumping the submodule
  in a reviewed PR; CI checks out with `submodules: true`. `agentica-vm
  --version` and the release notes list the libgc, libuv and OpenSSL
  versions; the release checklist says to rebuild and release after any High
  or Critical advisory for libgc, libuv or OpenSSL.

CI matrix:

| Job | Runner | Runs | Added in |
|---|---|---|---|
| Linux | self-hosted runner (`docker-runner`, Debian), submodules | `make vm vm-test`, `make test` (with the differential tests), smoke tests | first VM PR |
| Linux sanitizers | same, clang and `libclang-rt-dev` from the runner image | sanitizer build, `vm-test`, differential and bytecode tests, fuzz run, GC stress run | first VM PR (GC stress in PR 3) |
| macOS (by hand, `platforms.yml`) | `macos-15` (Apple clang, arm64), submodules | `make vm vm-test`, differential and bytecode tests | PR 4 |
| Windows (by hand, `platforms.yml`) | `windows-2025`, `msys2/setup-msys2` UCRT64 (gcc, make), submodules | `make vm vm-test`, differential and bytecode tests | PR 4 |
| Fuzz (by hand, `fuzz.yml`) | self-hosted runner, clang | sanitizer build, 5 million mutants, random `FUZZ_SEED` | after PR 5a |

The Linux jobs run on every pull request that changes more than docs. On
the self-hosted runner, Racket is installed once into the runner's tool cache
(`$RUNNER_TOOL_CACHE/racket-cs-9.3`, on its persistent work volume) and
later jobs only add it to `PATH`. The `vm/unicode_data.c` check is skipped
when a cache entry shows it passed for the same generator, table and
Makefile. The jobs
cache `src/compiled` and `tests/compiled` per job and touch every tracked file
after the restore, so `raco make` checks each source's SHA-1 and recompiles
only what changed. macOS and Windows minutes cost 10 and 2 times Linux minutes
on a private repository, so `platforms.yml` and `fuzz.yml` run by hand: run
`platforms.yml` before merging a change to platform code (`vm/main.c`, the
Makefile, files, processes, text output).

Racket comes from `Bogdanp/setup-racket` everywhere, since the tests compile
with the front end. The macOS and Windows jobs do not run the whole `make
test`: the process and network tests are not portable yet. `.gitattributes`
checks every text file out with LF (`.agcb` files are binary, and git
detects the `string-inspect.agc` fixture as binary from its NUL bytes), so Windows sees the same sources,
spans and output as Linux. 7h adds the libuv submodule and OpenSSL (`pkgconf` plus
the platform's OpenSSL package) to each job.

## 12. Testing and first PRs

### 12.1 Tests

- 7c `tests/lower-test.rkt`: one test per form (ops, slots, captures, spans).
  7d `tests/bytecode-test.rkt`: write, read back, compare; every example
  compiles. In the slice there is no Racket reader: the C loader is the
  only reader, and every differential test sends writer output through it.
  `tests/bytecode-test.rkt` checks step merging, that the opcode list matches
  `vm/agc.h`, that an out-of-subset program gets `LOWER-UNSUPPORTED`, and the
  `compile` exit codes; `tests/lower-test.rkt` comes with the wider lowering.
- `tests/vm-diff-test.rkt` (from the first VM PR, completed in 7f) runs each
  program on the evaluator in-process (as `tests/examples-test.rkt` does,
  formatting with `src/diagnostic.rkt`) and on `dist/agentica-vm`, and
  compares stdout, stderr, exit code, and diagnostic code and span in all
  three formats. Inputs: `examples/`, `tests/eval/tasks/*` reference
  solutions and hidden cases, and `tests/fixtures/vm/` with one program per
  runtime code and error span.
- Every program also runs with `--max-steps` 1 to 200 and some larger values;
  the failing span must match. In the slice the test finds each program's
  total step count with the evaluator and sweeps every limit from 1 to it
  when the total is at most 2000; above that (the call-depth program, about
  50,000 steps) it sweeps 1 to 300, 50 evenly spaced limits, and the total
  and the total minus one. The run without a limit compares all three
  formats; the sweep compares the plain format; stderr includes `IO.warn`
  output before the diagnostic. The inputs are `tests/fixtures/vm/` only. This covers 2.1 and 4.4, so the IR needs no
  step test. Programs using `Random` run with several `--seed` values.
- Corpora: Float text has a fixed table in `vm/tests/float_text_test.c`
  (values picked from a 708k-value comparison with Racket, 2.2) and the
  `tests/fixtures/vm/float-text.agc` differential fixture. Write escapes
  are checked where the data is made: `vm/tools/gen-unicode.rkt` compares its C
  rule with Racket's `write` for every code point and the joiner contexts
  (2.3) and refuses to generate otherwise. On the C side,
  `vm/tests/text_test.c` checks the range lookup at every range edge, a few
  debug forms, and that the debug form of every adjacent pair of scalar
  values is valid UTF-8 with an exact character count; the
  `string-inspect` fixture compares with the evaluator. Split, trim and
  case mapping join with the `String` library. `make vm-test` builds every
  `vm/tests/<name>_test.c` listed in `VM_TESTS`.
- Extreme Int corpus under UBSan: `INT64_MIN`, -1, 0, n, n+1, `INT64_MAX` for
  every Int parameter of every builtin. Deep-value corpus: a depth-200,000
  enum chain and nested JSON array, printed and encoded. A program's lists
  are only as deep as their types, which are written in the source (there
  are no user generics), whether built by one literal (capped near 65,000
  levels by registers, 3.5) or by chained bindings, so
  `vm/tests/text_test.c` builds a depth-200,000 list in C and prints it,
  and a depth-200,000 chain of enum payloads wrapped in structs: enough to
  overflow an 8 MB C stack even at about 48 bytes per frame, so a recursive
  printer would crash. The GC stress build uses depth 1,000 for both, since
  there the test is about GC safety while printing, not depth; the
  printer walks lists, structs and enums with one explicit `agc_alloc`'d
  stack (7.3). Recursive enums can be built to any depth in a loop; the
  `enums-case` fixture builds one and walks it with `case`.
- Tasks, processes and network programs join in 7h, with the independent
  counterparts the current tests use.

### 12.2 PR plan

Each PR keeps its own tests and docs and ticks its roadmap items.

1. **Vertical slice** (done). `#:types` in the checker; `src/lower.rkt`,
   `src/bytecode.rkt` and `vm/` for Int, Bool, their operators (including
   `and`/`or`, comparisons and every Int rule of 2.2), `if`, `while`,
   `break`/`next`, functions, calls, returns, steps and `puts` of plain
   strings and Ints; the loader with full validation and the fuzz driver;
   `--dump-ir`, `agentica compile`; `make vm`, the Linux and sanitizer CI
   jobs, `tests/vm-diff-test.rkt`.
2. **Float** (done). Float ops, comparisons and Float text (2.2), Nil, and
   `puts`/`print` of Float, Bool and Nil.
3. **Strings and printing** (done). Strings, interpolation, debug forms, the
   write-escape generator, the three diagnostic formats, exit codes, the GC
   stress run.
4. **macOS and Windows CI** (done). `make vm vm-test` and the differential
   and bytecode tests on `macos-15` and `windows-2025` (MSYS2 UCRT64 gcc),
   `wmain` with UTF-8 arguments, binary stdio, LF checkouts, and libgc built
   with upstream's defines (no executable heap pages).
5. **Data.** Too big for one review, so it lands as five PRs:
   - **5a Lists** (done). `List[T]` values, list literals (chunked above
     255 elements, 3.3), `for x in xs`, indexing `xs[i]` with
     `RUNTIME-INDEX-OUT-OF-RANGE` at the index span, and the text and debug
     forms `[a, b]` for every value type the VM has, through `puts`,
     interpolation, `to_s` and `inspect`. The checker rejects `==` on lists,
     so there is no list equality. List library functions stay in item 6.
   - **5b Structs, enums, `case`** (done). User structs and enums (generic
     and recursive too, imported ones with their linked display names),
     construction, field access, `case` with literal, `_` and variant
     patterns, their text and debug forms, and format version 2 with the
     struct and enum tables. The checker rejects `==` on them, so
     there is no struct or enum equality. Result patterns stay in 5c.
   - **5c** Result, `ok`/`error`/`Result.*`, `try`.
   - **5d** Maps (HAMT, 5.1), map literals and indexing.
   - **5e** Closures (`block-lit`), `&name`, `.call`, the resumable `List`
     builtins (`map`, `filter`, `reduce`, `sort_by`, `each`, `any?`,
     `all?`).
6. **Library.** `IO`, `System`, `String`, `List`, `Map`, `Float`, `Time`,
   `Random` (with the seeding port).
7. **JSON.** Parse, extract, encode, builders, typed decode, schema.

7e is done when every example runs on the VM with the same results, except
those that need files, processes, tasks or the network by name:
`file-summary`, `process-tool`, `concurrency`, `tcp_echo`, `http_get` and
`http_server`.

## 13. Open questions

- **Random seeding**: port planned in PR 6, fallback in 7.4.
- **Heap cap**: `--max-steps` does not bound memory (1), so a hostile or
  runaway file reaches the out-of-memory exit. Before 7i runs untrusted
  bytecode by default, decide on a cap such as `--max-heap N` through
  `GC_set_max_heap_size`, and whether the evaluator gets a matching limit.
- **BDD on the VM**: 7h decides whether handlers move to the VM.
