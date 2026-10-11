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
and Windows CI, the Lists PR, the structs, enums and `case` PR and the
Result PR, the Maps PR, the closures PR and the IO and System PR (12.2
items 1 to 4, 5a to 5e and 6a) are in, and so is the
tail-call PR (after the list in 12.2). The VM covers Int, Float, Bool, Nil and
String values, user structs and user enums (generic and recursive ones too,
imported ones included), `Result[T]` of any of them (and `Result[Void]`),
`List[T]` of any of them (lists of lists too), and `Map[K, V]` with Int or
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
`to_int`, `to_int!`, `to_float`, `to_float!`, 2.3). The other 6b modules
(`Float`, `Time`, `Random`) follow. Runtime diagnostics come in the plain,
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
- A `for` over a range charges one step per iteration at the `for`
  statement's span, before the body, even when the body is empty, so a loop
  over a huge range always stops at `--max-steps`. A `for` over a list
  charges nothing per iteration (the list length bounds it).
- A block's final expression statement is charged as a statement
  (`call-closure`). Callbacks run by the `List` builtins charge only their
  bodies, since the list length bounds them. The counting builtins
  (`Range.each`, `Int.times`, `Int.upto`, `Int.downto`) charge one step at
  the call's span before each callback call, so an empty block or a leaf
  function still meets the step limit.
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
- `String.split(s, sep)` with a non-empty separator splits on every
  non-overlapping match from the left and keeps every part, even empty ones
  at the ends or between two matches, so joining the parts with `sep` gives
  back `s`; empty text gives `[""]`. So `",,a,,"` gives
  `["", "", "a", "", ""]` and `"aaa"` split by `"aa"` gives `["", "a"]`.
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
  two U+FFFD then `c`). `IO.gets` ends lines at LF, CR or CRLF; a CR
  peeks at the next byte for the LF. `IO.read` and `IO.gets` decode only
  the bytes they consume, so `read_bytes` after `gets` starts right after
  the line terminator. A peek that finds EOF (`IO.eof?`, the byte after a
  CR) leaves it pending, as a Racket port does: the next read returns EOF
  without reading again.
- `System.args` on Linux and macOS: UTF-8, with `?` for each invalid byte,
  like Racket in a UTF-8 locale (glibc `iconv`), which also turns an
  incomplete sequence at the end of an argument into a single `?` (`E2 82`
  at the end gives one `?`; `E0 80` and `F0 80 80` are invalid starts, so
  they give one `?` per byte). Under a non-UTF-8 locale Racket decodes
  differently; that case is outside the contract. This includes the C and
  POSIX locales, the default in containers and cron jobs, when
  `agentica-vm` is called directly. Windows console input code pages are
  outside it too.

The case mapping, final-sigma and write-escape data are generated from
Racket itself by `vm/tools/gen-unicode.rkt` into a committed `vm/unicode_data.c`,
so they agree with the reference by construction (Racket 9.3).
`make vm-unicode` regenerates the file (about 55 s; run it with Racket CS 9.3,
the CI version, since the tables follow Racket's Unicode data), and the Linux CI job
fails when the committed file differs from what the generator prints.

- The tables are derived from Racket's output, not written by hand. The
  write-escape data is three range tables: code points `write`
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
  ever prints something else.
- The case data is two mapping tables and two range tables.
  `agc_upcase_map` and `agc_downcase_map` hold, sorted by code point, every
  code point whose `string-upcase` or `string-downcase` as a one-character
  string is not itself, with its full mapping (at most three code points,
  so `ß` gives `SS` and `İ` gives `i` plus U+0307). `agc_cased_ranges` are
  the code points after which a final `Σ` becomes `ς` (`xΣ`), and
  `agc_case_ignorable_ranges` the other code points that may stand between
  them (`AxΣ`); Racket uses the same two sets for the look-ahead.
- The C rule for case: upcase maps each code point through its table.
  Downcase does the same, except that `Σ` becomes `ς` when the last code
  point before it that is not case-ignorable (a cased one counts even when
  it is also ignorable) is cased, and the first one after it that is not
  case-ignorable is missing or not cased. So `ΣΣ` gives `σς`, `AΣ.B` gives
  `aσ.b`, `A\u0301Σ` gives `aς` and `AΣ Σ` gives `aς σ`. The generator
  checks this against Racket for every code point next to `Σ` in five
  contexts, for runs of two case-ignorable code points, for a cased code
  point with combining marks around `Σ`, and for the whole code point range
  in both orders; it stops on any difference.
- `String` library in C (`vm/strings.c`): lengths and indexes count code
  points (`agc_string` keeps both the byte and the code point count, and
  ASCII-only strings, whose two counts are equal, index bytes directly).
  For other strings `at` and `slice` find the byte offset through a
  one-entry cursor on the VM (`vm->cursor`: the string, a code point index
  and its byte offset, in the GC-scanned `agc_vm`, so the string stays
  reachable): the walk starts from whichever of the start, the end or the
  cursor is closest, and the cursor moves to just after the result. So a
  loop `s.at(j)` over `j` from 0 or down from the end costs O(1) per call,
  like the evaluator's O(1) `string-ref`; jumping around a long non-ASCII
  string costs O(distance). The cursor keeps the last non-ASCII string
  indexed by `at` or `slice` alive until the next non-ASCII `at` or
  `slice` replaces it, so it holds at most one string.
  `agc_utf8_next`, the one decoder shared by these builtins and
  `agc_write_form`, expects valid UTF-8 and a code point start (every VM
  String is valid UTF-8); on a truncated tail it stays inside the buffer.
  Every function is one or two
  O(n) passes that size the result first, then fill it; substring search
  is byte-wise (a valid UTF-8 match always starts on a code point): needles
  of 8 bytes or fewer use a `memchr` + `memcmp` scan with no allocation,
  longer ones Knuth-Morris-Pratt, so `split`, `replace`, `contains?` and `index_of` stay
  linear even on `aaaa...ab`. `String.trim` checks only the five ASCII
  bytes above, so it needs no table.
- `String.to_int` accepts `^[+-]?[0-9]+$` (ASCII digits only; no spaces,
  `_`, `0x` or exponent; `$` does not match before a final newline) and
  gives `Int result is outside the 64-bit range` past 64 bits;
  `String.to_float` accepts `^[+-]?[0-9]+(\.[0-9]+)?$`. Other text gives
  `cannot convert "TEXT" to Int` (or `Float`) with the String's debug form.
  The Result forms return these as `error(...)`; `to_int!` halts with
  `RUNTIME-INVALID-NUMBER` or `RUNTIME-INTEGER-OVERFLOW`, `to_float!` with
  `RUNTIME-INVALID-NUMBER`, all at the call span. After the pattern check,
  the C code runs `strtod` on a NUL-terminated copy (only digits, sign and
  dot reach it, so no locale, hex, `inf` or `nan` path), which rounds
  correctly like Racket: text without a dot is an exact integer in Racket
  that `exact->inexact` rounds, so `-0` gives `0.0`, while `-0.0` gives
  `-0.0`; 400 nines give `+inf.0`. `String.to_float` parity relies on
  glibc `strtod` rounding correctly; check it on macOS and Windows when
  those platforms come back.
- `String.from_bytes` first checks that every item is 0 to 255
  (`bytes must be integers between 0 and 255`), then decodes strictly
  (`invalid or incomplete UTF-8`: no surrogates, overlong forms or code
  points above U+10FFFF). `String.code` needs exactly one code point and
  `String.from_code` a Unicode scalar value, else
  `RUNTIME-INVALID-CHARACTER` at the argument span (the receiver for
  `s.code`). `String.at` fails at the index argument's span and
  `String.slice` at the call span, both with `RUNTIME-INDEX-OUT-OF-RANGE`.
  `String.split(s, "")` of empty text is `[]`, while a non-empty separator
  gives `[""]`.

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
- Struct and enum names in the tables are display names: the bytecode
  writer passes each linked name through `display-name`
  (`src/builtins.rkt`), the same function the evaluator prints with, so an
  imported type prints its declared name (`Point(x: 1)`, `Shape.Dot`), not
  the linker's internal `@2::` identity. Two modules that both declare
  `Point` both print `Point`; the name is display text only, and the VM
  never looks a type up by it.
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
  `RUNTIME-UNWRAP-ERROR` uses the error's own String as its message, so the
  VM's outcome carries the message with its byte length (`agc_fail_text`)
  and prints it as raw bytes, like any other String.
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
- `ir-function` and `ir-program` have every field; `captures` is 0 for
  declared functions.
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
| `JSON.decode(s, User)`, `JSON.schema(User)` | The type argument is charged one step and lowers to a String constant with the struct's display name, as `type-expression` evaluates to its name. |
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
resolves `x.to_s` on Int and Float to them.
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
charged: step counts and `--max-steps` failures do not change.

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
bumps the format version. Appending an opcode changes neither, so it keeps
the version (the Lists PR and the tail-call PR stayed on their versions); an
older VM rejects the new opcode as unknown. There are no compatibility
shims: the Racket side and the VM ship together.

## 5. Values in C

### 5.1 Representation

```c
typedef enum {
  AGC_T_VOID = 0, AGC_T_NIL, AGC_T_BOOL, AGC_T_INT, AGC_T_FLOAT,
  AGC_T_STRING, AGC_T_LIST, AGC_T_MAP, AGC_T_STRUCT, AGC_T_ENUM,
  AGC_T_RESULT, AGC_T_FN, AGC_T_RANGE, AGC_T_JSON, AGC_T_HANDLE
} agc_tag;                            /* the full set; vm/agc.h grows toward it */

typedef struct {
  uint32_t tag;
  union { bool b; int64_t i; double f; void *p; } as;   /* immediates write the full word: as.i = b */
} agc_value;                          /* 16 bytes, passed by value */
```

| Type | Representation |
|---|---|
| Void, Nil, Bool | Immediate. Tag 0 is Void, so zeroed registers are valid values. Today `vm/agc.h` has the tags above up to Fn, in that order, then `AGC_T_RANGE` (Phase 8a); Json and Handle join with their PRs. |
| Int, Float | `int64_t` (`__builtin_*_overflow`), `double`. |
| String | `{ size_t bytes, chars; char data[]; }`, `GC_MALLOC_ATOMIC`. `chars == bytes` means ASCII, O(1) indexing; otherwise indexing scans. Not NUL-terminated by contract. |
| List | `{ size_t len; agc_value items[]; }`, immutable. `append`, `set`, `concat` copy (same O(n) as now); indexing is O(1). |
| Map | `{ size_t size; agc_hamt *table; agc_keys *reversed; }` (`vm/map.c`): a persistent 32-way HAMT from key to value plus a persistent cons list of keys, newest first, exactly like `mapping`/`mapping-put` in `src/runtime-values.rkt`. A put copies only the path to its key (at most 14 nodes of at most 32 entries) and, for a new key, conses one cell onto the shared list; a replaced key keeps its cell, so its position. Put and lookup are O(log32 n) (12 levels of 5 hash bits and a 13th of 4 bits, then a collision node that holds the entries whose 64-bit hashes are equal and is searched linearly); building a literal of n entries is O(n log n), never O(n^2). Printing, `Map.keys` and `Map.values` walk the list once into an array, oldest first (`values` then looks each value up): O(n log n). Every node and cell is `GC_MALLOC`'d and immutable, so versions share structure. `Map.delete` (`agc_map_delete`) removes the key from the trie by copying its path (a child left with one leaf is pulled up into its parent, an empty node disappears, an empty map has no table) and copies the key list up to the key's cell, sharing the rest: O(n) like `remove` in the evaluator. A missing key returns the same map. Keys are Int (its 8 bytes, little-endian) or String (its UTF-8 bytes), compared by tag and value, which is `equal?` on them; they are hashed with SipHash-1-3, the value tag compressed as a leading 64-bit word before the bytes, so an Int and a String with the same bytes hash apart. The SipHash key is seeded once per run in `vm/main.c` from OS entropy, independent of `--seed`: on Linux `getrandom` (retried on `EINTR` and short reads), then `/dev/urandom` if `getrandom` fails (for example `ENOSYS` or `EPERM` under seccomp); `/dev/urandom` on other Unix systems and `rand_s` on Windows. If every source fails, the fixed default key stays. That is acceptable as a last resort: the hash is still 64 bits and a HAMT only degrades on full 64-bit collisions (a collision node is searched linearly), and forcing those still costs about 2^32 work per pair even with a known key. The C tests and the fuzzer keep the fixed default key. Iteration and printing order never depend on the hash. Later, if profiling asks for it: `MAP` can build its fresh literal with a transient in-place put instead of a persistent copy per pair, and a node can split child and leaf slots to use less memory. |
| Struct | `{ uint32_t type, n; agc_value fields[]; }`, declaration order. Text: the struct's display name, then `(f: v, ...)` from the table's field names. |
| Enum | `{ uint32_t variant, n; agc_value payload[]; }`; nullary variants are shared (one object per variant, made at load time). Text: enum display name, `.`, variant name, then `(a, b)` when `n > 0`. |
| Result | `{ bool ok; agc_value value; }` (`GC_MALLOC`); an error holds its String message; `ok()` holds Void. Debug form: `ok(v)`, `ok()` when the value is Void, `error("msg")` with the message in `write` form, printed by the same explicit-stack walker as lists, structs and enums. |
| Range | `agc_range { int64_t start, end; bool exclusive; }` (`GC_MALLOC_ATOMIC`), tag `AGC_T_RANGE`, immutable. Text and debug form `1..5` or `1...5` (`agc_scalar_text`; the longest form is 43 bytes, so `AGC_SCALAR_TEXT` is 48). `agc_range_bounds` gives the first and last included values and whether the range is non-empty, with no overflow for `...` (the end is above the start). `Range.size` fails with `RUNTIME-INTEGER-OVERFLOW` and `Range.to_a` above 1048576 values with `RUNTIME-INVALID-COUNT`, both at the receiver's span (`span + 1`), as the evaluator does; `first` and `last` of an empty range give `error("the range is empty")`. |
| Function value | `agc_fn { uint32_t function, n; agc_value captured[]; }` (`GC_MALLOC`), tag `AGC_T_FN`. `&name` is a value with `n = 0`. Text and debug form `<Fn>` (the checker never lets a program print one). |
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
  `{ uint32_t function, pc, base, ret; agc_native *native; }`; a native
  frame (4.3) has `native` set. `RETURN` writes `ret`: the callee's base
  for `CALL` (the caller's `R[a]`), one register below the window for
  `CALL_VALUE` and callbacks. `frame_count` counts all frames, `depth`
  only the bytecode ones. A native frame keeps function index 0 as a
  placeholder, so code that walks frames must check `native` first.
- The interpreter is one `switch` loop. Agentica calls push frames and never
  recurse on the C stack, so a 7h task switch only changes the current task.
- Before `CALL`, `CALL_VALUE` or a callback push, `depth >= 10000` fails with
  `RUNTIME-STACK-OVERFLOW` ("call depth limit exceeded") at that
  instruction's span, like `call-function` and `call-closure`. `main` runs at
  depth 1; native frames do not count; each task starts at 0. `TAIL_CALL`
  replaces the current frame (4.3), so it neither checks nor changes the
  depth. The register
  array is capped at 2^24 per task; passing the cap fails the same way. A
  valid program reaches it only with more than about 1,600 registers per
  frame at full depth, so this is a documented difference, not a hole.
- Documented difference: the evaluator has no tail calls, so a deep
  tail-recursive program (a loop of a million `return f(n - 1)`, or two
  functions that tail-call each other) fails there with
  `RUNTIME-STACK-OVERFLOW` and runs on the VM. The VM's depth is never above
  the evaluator's, so a program that stays within the limit on the evaluator
  stays within it on the VM, with the same output, steps and spans; a
  runtime diagnostic carries one span and no stack trace, so the replaced
  frames are not visible. Non-tail recursion keeps the limit and its span.
  The evaluator is not changed: it goes away in 7i.
- `steps_left` is an `int64_t`: the limit, or `INT64_MAX` without one. All
  tasks share it. `STEP` is one compare and one subtraction on a "next stop"
  counter; before 7h it is just `steps_left`, and from 7h it also covers the
  turn budget (10.2.1).

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
documented difference. It also sets `GC_set_warn_proc(GC_ignore_warn_proc)`,
so libgc warnings (such as `Repeated allocation of very large block`) never
reach the program's stderr.

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
  last. `order<?` is a strict weak order on each key type (`-0.0` and
  `0.0` tie, NaNs tie with each other), so any stable sort gives Racket's
  result; `sort_by` is a bottom-up merge sort over item indexes (no
  recursion), and keys of mixed or other types are `RUNTIME-INTERNAL`.
- **Streams.** In 7e, stdin is one buffered reader over `read(0)`, shared by
  `gets`, `read`, `read_bytes` and `eof?`, like the single Racket port. It
  lives in `vm/input.c` (`agc_input_*`), the only code that reads stdin:
  one growing buffer (64 KiB first, doubled through `agc_size_mul`, so a
  long line or `IO.read` is bounded only by memory, and ends in the
  out-of-memory exit like any other growth; a buffer above 1 MiB is
  dropped for a fresh 64 KiB one once it is empty, so one huge line does
  not keep its memory for the rest of the run), blocking `read` with `EINTR`
  retried and, on Linux, `poll` when the descriptor is non-blocking. The
  builtins only call it, so 7h can replace it with libuv reads that park
  the task (10.2) without changing what the builtins return. A failed read
  is `RUNTIME-INTERNAL` for `gets`, `read` and `eof?` and the error value
  `"input read failed"` for `read_bytes`, as in the evaluator. The
  message differs (the evaluator shows Racket's port error, the VM says
  "cannot read standard input"), but the span is the same: the evaluator
  reports any Racket failure at the whole-program span, and the VM passes
  span 0, which maps to that span. When stdout is a terminal, `vm/main.c`
  opens stdin with `agc_input_open(vm, 0, isatty(1))`, so stdout is flushed
  before each blocking stdin read; a prompt written before `gets` shows
  up first, as it does with the evaluator on a terminal. Reading
  charges no steps: work inside builtins is free (2.1), so `--max-steps`
  does not bound a single read; only memory does (see the heap cap in
  13). `IO.flush` flushes
  stdout and fails like a write. `System.exit` records the code in the
  outcome (`AGC_EXITED`) and `longjmp`s like a diagnostic; `vm/main.c`
  flushes stdout and exits (2.5). A VM run without `vm/main.c` (the C
  tests, the fuzzer) has an empty stdin and no arguments.
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
  (`CALL` and `TAIL_CALL` with the callee's parameter count, `CALL_VALUE` `a..a+b`,
  `CALL_BUILTIN` with its arity, `CLOSURE` with the captures); constant, function, builtin, type, struct,
  field, variant and span indexes in range, including the extra spans of
  `STEP` and `CALL_BUILTIN`; jump targets inside the function; `STEP` count at
  least 1.
- **Termination**: every backward jump targets a `STEP`, and every function
  starts with a `STEP` unless it has at most 2 instructions and no `CALL`,
  `TAIL_CALL`, `CALL_VALUE` or `CALL_BUILTIN` (the `const`/`return` of an empty body). The
  lowering in 3.3 always meets these rules. Together they mean every
  unbounded repetition charges a step (a range loop charges its own `STEP`
  each iteration, and a counting native frame charges one step before each
  callback, like `STEP`; a cycle of tail calls runs only
  functions that call, so each one charges its leading `STEP`), so `--max-steps` holds even for
  hostile files: the step budget bounds the number of instructions to about
  steps × code size. It does not bound bytes: `CONCAT` and `INSPECT` cost
  time and memory in proportion to their strings (trust model, 1). `LIST`
  and `TAIL_CALL` copy up to 65534 values in one instruction, so they cost
  O(count) per step, still within steps × code size. `MAP` hashes and puts
  at most 255 pairs, so one step cannot pay for a huge literal; longer
  literals are extended one `Map.put` at a time.
- **Entry**: exists, with no parameters or captures.
- **Ranges**: `RANGE` checks `a`, the window `b..b+1` and that `c` is 0 or
  1; `RANGE_BOUNDS` checks `b` and the window `a..a+2`.
- **Closures**: `CALL_VALUE` checks the window `a..a+b`; `CLOSURE` checks
  the function index and the window of that function's captures (`a`
  itself when it has none). `CALL` and `TAIL_CALL` may not name a
  function with captures (only `CALL_VALUE` fills them). A `CALL_VALUE`
  counts as a call for the termination rules.
- **In the slice**: constant kinds above 6 are
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
  `SAME` checks three registers; `TRY`, `IS_OK` and `RESULT_VALUE` two;
  `MAP` checks `a`, `c <= 255` (the lowerer's chunk size, 3.3) and the
  window `b..b+2c-1` (`b` itself when `c` is 0; `2c` is computed in 32
  bits), `MAP_GET` three registers.
  Builtin record layouts are not checked
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
  above (and that 65535 nullary variants and 65535 fields load), `CALL`,
  `TAIL_CALL` and `CALL_BUILTIN` windows, a `TAIL_CALL` to a function out of
  range, the registers of `TRY`, `IS_OK` and `RESULT_VALUE` (and, at run
  time, that they fail on a non-Result and that a `TRY` error in `main`
  is `RUNTIME-INTERNAL`), the `MAP` window, a `MAP` count of 256 (and that 255 loads) and
  `MAP_GET` registers (and, at
  run time, a missing key's code, span and message, a nested map printed,
  and `RUNTIME-INTERNAL` for a Void key or a `MAP_GET` on a list), a
  `Map.put` import of the wrong arity, the `CALL_VALUE` window, a
  `CALL_VALUE` that does not start its function with a `STEP`, a `CLOSURE`
  of a function out of range or with a capture window out of range, a
  `CALL` or `TAIL_CALL` of a function with captures,
  captures that do not fit the registers, an entry with captures (and, at
  run time, a `CLOSURE` called through `CALL_VALUE`, `List.map` with a
  closure, and `RUNTIME-INTERNAL` for a call of a non-function and for a
  wrong parameter count, directly or as a callback), a `List.map` import
  of the wrong arity, `STEP 0`, a backward jump that misses a `STEP`,
  functions that should start with one (one is just `TAIL_CALL`, `RETURN`), an unknown opcode, a missing final
  `RETURN`/`JUMP`, and a file over the memory budget.
- **Run time**: `CALL_VALUE` and callback parameter and capture counts,
  tags (5.2), list, map and string bounds, and the register cap (6.1).

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
  and `--`. `--seed` joins with `Random` (PR 6b); until then it is an
  unknown option (exit 2). `--ai` and `--json` may both appear; the last one
  wins, as with `command-line`. Giving one option twice prints `agentica-vm:
  the --ai option can only be specified once`. Racket's `command-line`
  exits 1 for every option error it raises itself (a repeated option, an
  unknown switch, a missing value); the VM exits 2 for all of them, since
  the 7i driver parses the user's options itself. Value errors that
  `src/main.rkt` checks (`--max-steps needs a positive integer`) exit 2 on
  both.
  Arguments after the file are the program's `System.args`.
- Tests in 7e and 7f spawn `dist/agentica-vm` directly.
- `agentica --vm file.agc [args...]` (7i, landed for Linux). `src/main.rkt`
  runs the front end and `lower`, then writes the bytecode to
  `agentica-<32 hex>.agcb` in the system temp directory (`TMPDIR`), created
  exclusively with mode 0600 (`#:exists 'error #:permissions #o600`). It
  runs the VM as `agentica-vm [--max-steps N] [--ai|--json] --driver-pid
  PID -- file [args...]`. `--driver-pid` is a hidden VM flag (not in the
  usage text). On Linux the VM first calls `prctl(PR_SET_PDEATHSIG,
  SIGKILL)` and then checks that `getppid()` is `PID`; if not, the driver
  is already gone, so it prints a message and exits 2 without touching the
  input (Racket's `subprocess` cannot run code between fork and exec, so
  the check closes that race). Then it opens the input with `O_NOFOLLOW`
  and loads it only if it is a regular file owned by the VM's user, with
  one link and no group or other permission bits; otherwise it exits 2.
  The path is visible in `ps`, and a shared temp directory without the
  sticky bit would let another user swap the file between the driver's
  close and the VM's open; these checks refuse a swapped file. After those
  checks it deletes the input, but only if the path still names the file it
  opened (same device and inode). The driver deletes the file too, when the
  VM never ran or failed before loading, and on a break. When a driver
  output port is not a file stream (rackunit, captured output) it copies
  that stream through a pipe, and a non-file stdin is copied into the VM's
  stdin by a thread that stops when the VM exits. The thread reads ahead
  of what the program consumes, so on a non-file stdin shared with other
  code the driver may take bytes the program never read. If reading the
  driver's stdin fails, the thread kills the VM and the driver reports
  `RUNTIME-INTERNAL` (exit 1), as the evaluator does for a failed read;
  a special (non-byte) value on the port ends the input like EOF. Otherwise it passes the real stdin, stdout
  and stderr, so the VM's output and exit code reach the user unchanged. Front-end and `LOWER-` diagnostics print as without
  `--vm` (exit 1). `--allow-run`, `--seed`, `--steps`, `--dump`,
  `--dump-ir`, `check`, `compile`, `help` and `test` exit 2 with
  `--vm does not support X`.
- Finding the VM, never in the current directory: `AGENTICA_VM=path` wins;
  under `racket src/main.rkt` it is `dist/agentica-vm` of the checkout
  (from the module's own source path); in a `raco exe` build it is
  `agentica-vm` next to the executable (`run-file`, with symlinks
  resolved). A missing or non-executable VM prints `agentica: cannot find
  the VM at PATH` and exits 2 before the front end runs, so this error
  wins over a program diagnostic. It does not use
  `define-runtime-path`: `raco distribute` would then copy the VM into
  `lib/` and fail when it is not built. Packaging the VM in `bin/` of the
  release is a later 7i item.
- Future work: Windows (a kill-on-close job object instead of
  `PR_SET_PDEATHSIG`) and macOS (no parent-death signal; the closest safe
  thing is the delete-after-load flag alone, or a pipe the VM watches).
  On macOS the flag skips only the parent check: the `O_NOFOLLOW`,
  privacy and inode checks run on every non-Windows system. Windows skips
  both checks, and the VM may fail to delete its still-open input, but the
  driver deletes it anyway. `--vm` is tested on Linux only.
- `PR_SET_PDEATHSIG` follows the OS thread that forked the VM, so the
  driver must call `subprocess` from the main thread.
- The hidden flag deletes its private input after loading, so it must not
  be reused for anything else.
- `check`, `help` and `test` stay Racket commands; from 7h, BDD
  handlers run on the VM. `make vm` builds `dist/agentica-vm` (`.exe` on Windows); in 7i the
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
  runs another ready task (10.2.1). Only the scheduler calls `uv_run`. libuv
  and OpenSSL callbacks only copy results and mark tasks ready.
- Racket threads are preemptive, so the scheduler also switches tasks that do
  not block, by reductions (10.2.1). Cross-task output order is not compared.
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

#### 10.2.1 Scheduler

- **libuv does I/O only.** It gives readiness, timers, processes, DNS, and
  the thread pool for file I/O, which epoll cannot poll. It never decides
  which task runs; the scheduler is ours. Raw epoll or io_uring would make us
  rewrite the file thread pool, processes, signals and DNS ourselves, on each
  platform.
- **Run queue.** Ready tasks wait in one FIFO queue. A new task, a task whose
  turn ended, and a task woken by a libuv callback all go to the back.
- **Reductions, as in BEAM.** Each turn has a budget of steps, counted by
  `STEP` like `--max-steps` (`STEP n` counts n). It starts at 2000 and is
  tuned by measurement in 7h; 7g gives the cost of `STEP` with one task. When
  a `STEP` spends the turn's budget, the task goes to the back of the run
  queue and the next one runs. A merged `STEP n` that crosses the turn
  budget charges all n, then yields at the next instruction; the extra is not
  carried over to the next turn. If it crosses `--max-steps`, the task fails
  at the span of 4.2 instead (see "One counter for both budgets"). To the
  program the scheduler is preemptive; inside the VM it switches only at a
  `STEP`, a safe point. Every loop passes a `STEP`: backward jumps land on
  one, and every function that calls starts with one (8), so a `TAIL_CALL`
  loop passes it too. A task also leaves its turn when it blocks.
- **Builtins.** No builtin's C code is stopped halfway. A resumable builtin
  (4.3: `map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`) can be
  switched out only between its callbacks, at their `STEP`s. Any other
  builtin finishes in its turn: `List.sort` on a big list, or the sort inside
  `sort_by` after its keys are collected, runs to the end without a switch.
  A callback short enough to skip its leading `STEP` (8) charges nothing, so
  a resumable builtin can run a whole list with it without a switch. This
  work is still bounded by the list length, so it is accepted. Counting
  `List` builtin iterations toward the turn would change step counts, so it
  is not done. The counting builtins (`Range.each`, `Int.times`, `upto`,
  `downto`) have no list to bound them, so each callback call charges one
  step through the same check as `STEP` and is a switch point.
- **One counter for both budgets.** `STEP` counts down one "next stop"
  counter, set to `min(turn_left, steps_left)` when a turn starts. The fast
  path runs while `counter > n` for `STEP n`: one compare and one
  subtraction. Otherwise the slow path first moves the steps spent so far
  out of both budgets. Then, if `steps_left < n`, the task fails with
  `RUNTIME-STEP-LIMIT` at span `s + steps_left` (4.2), and nothing more is
  charged. If not, all n is charged to both budgets, and the task yields if
  `turn_left <= 0`; it resumes at the next instruction.
- **Fairness with I/O.** After each turn (or every N turns, if measurement
  asks for it) the scheduler calls `uv_run(UV_RUN_NOWAIT)`, so ready I/O wakes
  its tasks even while other tasks keep computing. Timers (`Task.sleep`) wake
  the same way, inside `uv_run`. Tasks woken during a `NOWAIT` go behind the
  tasks already queued. The scheduler blocks in `uv_run(UV_RUN_ONCE)` only
  when the run queue is empty. Without channels, a parked task waits on I/O,
  a timer, or another live task, so either `uv_run` has an active handle or
  the queue is not empty. If `uv_run` reports no active handles while tasks
  are still parked, the VM fails with `RUNTIME-INTERNAL` and does not spin.
- **Quotas.**
  - `--max-steps` stays one global budget shared by all tasks (`steps_left`,
    6.1), as today. Preemption never changes what is charged. With one task,
    counts and failing spans match the evaluator (2.1). With several tasks,
    which task fails at the limit depends on the interleaving, so, like
    cross-task output order, it is not compared.
  - Per-task step quotas could later use the same counter. They are not in
    7h.
  - Per-task memory quotas are out of scope: the Boehm heap is shared, unlike
    BEAM's per-process heaps. Only a global heap limit is possible (13).
- **One OS thread in 7h.** Multicore (M:N, one scheduler per core with work
  stealing) is later work, done only if measurements of the 7h scheduler
  justify it. Immutable values make sharing safe, and the shared tables plan
  avoids locks. The costs: Boehm stops the world for each collection once
  there are threads, the interpreter state must become per-thread, and
  builtins that rely on the single thread (table calls, the resource
  registry) need atomics. `future.md` §13 relies on the single-thread rule for atomic table
  calls on the VM, so it must be revisited if multicore lands.

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
  and reject names with a trailing dot or space or any `:`. Both backends use this same
  allowlist: the Racket check in `process.rkt` (`windows-runnable-name?`)
  applies it to the last component of the resolved path, and the VM must do
  the same. Whether the current directory is searched is decided once in
  `grammar.md` before 7h.

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
| Windows programs other than `.exe`, `.com` | rejected | `process.rkt` |

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
  the `tests/vm-diff-*-test.rkt` shards on that binary (`AGENTICA_VM_BINARY` points the
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
  it to `fuzz-crash.agcb`. The fuzz workflow (`.github/workflows/fuzz.yml`,
  run by hand) builds the sanitizer VM, runs 5 million mutants with a
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
- `tests/vm-diff-*-test.rkt` (from the first VM PR, completed in 7f; four
  shards of `tests/vm-diff-common.rkt`) run each
  program on the evaluator in-process (as `tests/examples-test.rkt` does,
  formatting with `src/diagnostic.rkt`) and on `dist/agentica-vm`, and
  compare stdout, stderr, exit code, and diagnostic code and span in all
  three formats. Inputs: `examples/`, `tests/eval/tasks/*` reference
  solutions and hidden cases, and `tests/fixtures/vm/` with one program per
  runtime code and error span.
- Every program also runs with `--max-steps` 1 to 200 and some larger values;
  the failing span must match. In the slice the test finds each program's
  total step count with the evaluator and sweeps every limit from 1 to it
  when the total is at most 2000; above that (the call-depth program, about
  60,000 steps) it sweeps 1 to 300, 50 evenly spaced limits, and the total
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
  every Int parameter of every builtin. Deep-value corpus: a depth-1,000,000
  enum chain and nested JSON array, printed and encoded. A program's lists
  are only as deep as their types, which are written in the source (there
  are no user generics), whether built by one literal (capped near 65,000
  levels by registers, 3.5) or by chained bindings, so
  `vm/tests/text_test.c` builds a depth-1,000,000 list in C and prints it,
  and a depth-1,000,000 chain of enum payloads wrapped in structs: enough to
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
   jobs, the VM differential test (now `tests/vm-diff-*-test.rkt`).
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
     so there is no list equality. List library functions stay in item 6b.
   - **5b Structs, enums, `case`** (done). User structs and enums (generic
     and recursive too, imported ones with their declared display names),
     construction, field access, `case` with literal, `_` and variant
     patterns, their text and debug forms, and format version 2 with the
     struct and enum tables. The checker rejects `==` on them, so
     there is no struct or enum equality. Result patterns stay in 5c.
   - **5c Result values, `try`** (done). `Result[T]` values, `ok(...)`,
     `ok()` and `error(...)`, the `Result.*` builtins (`ok?`, `unwrap!`
     with `RUNTIME-UNWRAP-ERROR` at the call span, `unwrap_or`,
     `message`), `try` (`TRY`), Result patterns in `case` (`IS_OK`,
     `RESULT_VALUE`), and the text and debug forms `ok(v)`, `ok()` and
     `error("msg")`. No format bump: the three opcodes are appended.
   - **5d Maps** (done). `Map[K, V]` values as a persistent HAMT plus
     the evaluator's reversed key list (5.1), map literals (empty typed
     ones too; above 255 entries extended with `Map.put`, 3.3), `m[key]`
     with `RUNTIME-KEY-NOT-FOUND` at the index span, and the `{k: v}` text
     and debug forms in insertion order. `vm/tests/map_test.c` checks
     20,000 keys, order, replacement, persistence, full 64-bit hash
     collisions, keys that share 60 hash bits, and a depth-1,000,000
     nested map printed. No format bump: `MAP` and `MAP_GET` are appended.
     There is no `for` over a map (the checker rejects it); Map library
     functions stay in item 6b.
   - **5e Closures** (done). Blocks (`block-lit`) as closures with
     snapshot captures (3.4), `&name` of local and imported functions,
     `.call` (`CALL_VALUE`, `CLOSURE`), `Fn` values in lists, maps and
     structs, and the resumable `List` builtins (`map`, `filter`,
     `reduce`, `sort_by`, `each`, `any?`, `all?`) as native frames
     (4.3). No format bump: the function table always had its captures
     field, and the two opcodes are appended. Closures passed to
     `Task.spawn`, HTTP or BDD stay `LOWER-UNSUPPORTED` until 7h.
6. **Library.** Two PRs:
   - **6a IO and System** (done). Blocking stdio; it moves to libuv
     resumable builtins with the scheduler (7h). `IO.inspect`, `IO.gets`
     (and `gets`), `IO.gets!` (and `gets!`, `RUNTIME-END-OF-INPUT` at the
     call span), `IO.read`, `IO.read_bytes` (0..1 MiB, else an error
     value), `IO.flush`, `IO.eof?`, `System.args` and `System.exit`, all
     through the input layer of 7.3. `agentica --vm` now passes a non-file
     stdin through. Fixtures with a `.stdin` and an `.args` file next to
     them feed the differential test.
   - **6b** `String`, `List`, `Map`, `Float`, `Time`, `Random` (with the
     seeding port). `List` and `Map` are done: plain C builtins (no native
     frames), the evaluator's messages and spans (`RUNTIME-INDEX-OUT-OF-RANGE`
     for `at`/`set`, `RUNTIME-INVALID-COUNT` for `take`/`drop` and
     `repeat`, at the argument span), `Map.get` as a Result with the
     key's debug form in the message, and `List.sort` through the same
     merge sort as `sort_by` with the items as their own keys. Lists stay
     arrays, so `append` and `set` copy (O(n)); `repeat`, `concat`,
     `take`, `drop` and `reverse` are one pass, and `repeat` is capped at
     1048576 before allocating. `vm/tests/map_test.c` covers `delete`
     (persistence, order, collision nodes, shared prefixes, deleting to
     empty); the `list-library`, `map-library` and `list-*` error
     fixtures cover the rest. The `String` part is done too: every
     `String.*` builtin of the catalog in `vm/strings.c` (2.3), the case
     and final-sigma tables in `vm/unicode_data.c`,
     `vm/tests/string_test.c` (UTF-8 helpers, search, case, number
     parsing edge cases) and the `string-*` fixtures (non-ASCII text,
     empty strings, every runtime code and span).
7. **JSON.** Parse, extract, encode, builders, typed decode, schema.
   The VM Json tree, with its big-integer node from §5, must follow the number rules of `docs/future.md` §15.2.

Phase 8a (ranges, done) added the `Range` value (5.1), `RANGE` and
`RANGE_BOUNDS` (4.2), the counter loops of 3.3, the `Range` builtins and
the counting native frames of 4.3, with loader rules (8) and the `ranges`,
`range-size-overflow`, `range-to-a-count` and `times-callback-error`
fixtures.

Outside this list, the **tail-call** PR (done) added `TAIL_CALL`: a
`return f(...)` of a user function reuses the frame (3.3, 4.2, 4.3, 6.1),
with loader rules (8), the `tail-calls` fixture, and a VM-only test of a
loop and a mutually recursive pair one million calls deep.

7e is done when every example runs on the VM with the same results, except
those that need files, processes, tasks or the network by name:
`file-summary`, `process-tool`, `concurrency`, `tcp_echo`, `http_get` and
`http_server`.

## 13. Open questions

- **Random seeding**: port planned in PR 6b, fallback in 7.4.
- **Heap cap**: `--max-steps` does not bound memory (1), so a hostile or
  runaway file reaches the out-of-memory exit. Before 7i runs untrusted
  bytecode by default, decide on a cap such as `--max-heap N` through
  `GC_set_max_heap_size`, and whether the evaluator gets a matching limit for the one release it
  stays behind a flag.
- **BDD on the VM**: decided; handlers move to the VM in 7h, and
  the evaluator is removed in 7i (roadmap).
