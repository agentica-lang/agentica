# Agentica bytecode VM: design

This document closes roadmap step 7b. It fixes the decisions that 7c
(lowering), 7d (bytecode emitter) and 7e (VM core) build on, and the library
choices and safety rules that 7h and 7i need. The language does not change.
`grammar.md` stays the contract, and the Racket evaluator
(`src/evaluator.rkt`) stays the reference until 7i. Roadmap step 7b lists
each decision in one line; this document gives the details and reasons.

## 1. Overview

**Parity is black-box.** The VM must give the evaluator's exit code, the
stdout and program stderr (what the program itself writes, as with
`IO.warn`; the diagnostic after it is not part of this) of every run except
one stopped by `--max-steps`, and on failure the same diagnostic code
(`RUNTIME-INDEX-OUT-OF-RANGE`, say); a runaway program must stop with
`RUNTIME-STEP-LIMIT` under `--max-steps`, and a program the evaluator runs
in T steps must finish on the VM under a limit of the larger of 2T + 100
and T + 4000 (two task turns, so a run with tasks does not depend on when
Racket first switches threads). Everything else may differ: diagnostic message text
and span, the VM's own stderr wording, OS error text, the error strings of
library `Result`s (HTTP, files, processes), exact step counts and the
step-limit span, `Random` sequences, and cross-task order. An error string
that a program prints is program data, though: today's fixtures that print
one must still match. When a library message changes (roadmap 7k), the
fixtures that print it switch, in the same PR, to printing only ok or error
(or a stable kind). VM
messages must still be clear and useful for agents; evaluation rounds judge
that, not identity with Racket. Where this document and the evaluator
disagree on what must match, the evaluator wins and this document is
fixed. Much of this document records Racket's exact behavior because the
first PRs copied it; that is a description of today's VM, not a rule, and
designs kept only to copy Racket's text or counts may be simplified. For
example, the HTTP adapter does not need to map parser failures onto
`http-wire.rkt`'s exact messages, only onto the same diagnostic or `Result`
error kind (10.6). The turn cost (10.2.1) stays: it is there for fairness, not
for parity. With black-box parity the compiler may also optimize freely as
long as exit code, stdout, program stderr and diagnostic codes stay the
same: inlining,
constant folding, common subexpression elimination, loop-invariant code
motion, and merging or moving `STEP`s (a runaway loop must still hit
`RUNTIME-STEP-LIMIT`; step counts may change). New APIs the evaluator never
had (UDP, say) may be VM-only, tested with fixed expected output.

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
| `src/main.rkt` | `--dump-ir` (7c), `compile` (7d), `--vm` (7i). Printing and exit codes stay here. |
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

## 2. Reference behavior (today's VM)

These rules come from the Racket sources, not only from the grammar. The
differential tests (section 12) check only what black-box parity needs
(exit code, stdout, program stderr, diagnostic code); messages, spans and step counts below
describe the VM today and may change (1).

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
  share one counter. Only the outcome must match the evaluator: a runaway
  program stops with `RUNTIME-STEP-LIMIT`; the exact count and span may
  differ (1). Racket accepts any positive integer; the VM clamps values
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
  `\u007f` otherwise; non-ASCII stays raw; floats use 2.2; a big integer is
  its decimal text. `JSON.encode` of a non-Json value keeps a struct's
  declaration order and a map's insertion order (only a `Json` inside is
  sorted); `JSON.from`, `JSON.object` and `JSON.array` build a `Json`, so
  their text is sorted. A non-finite Float in either is
  `RUNTIME-JSON-ENCODE` at the call span. `JSON.float` of a big integer is
  `strtod` of its text (correctly rounded like `exact->inexact`), an error
  value when that is infinite. The VM writes this text with its own
  encoder in `vm/json.c` (one explicit stack for values and Json nodes).

### 2.5 Diagnostics, streams and exit codes

- Runtime diagnostics carry only code, message and span. Messages started as
  copies of the Racket text; only the code must match (1), and a VM message
  may be reworded when that makes it clearer.
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
  valid even for odd file names.
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
- The order of the checks: the control-character pass over the whole text
  first, then the syntax, then the trailing content, and only then the
  finite check, so `1e400 x` is `unexpected content after the JSON value`.
- `read-json` stops early on a top-level number or literal: a number ends
  at the first byte its grammar does not take, so `01` is the value `0`
  followed by `unexpected content`, and `[01]` is `invalid JSON`; a
  literal followed by `[A-Za-z0-9_]` (`truex`) is `invalid JSON`, while
  `true-` is `unexpected content`. Whitespace is space, tab, CR and LF;
  any other whitespace before the value (`\f`, NBSP) is `invalid JSON`,
  after it `unexpected content`.
- A Float is the exact decimal rounded to nearest (ties to even), except
  that a mantissa of only zeros gives `0.0` whatever its sign or exponent
  (`-0.0` and `-0e5` are `0.0`); a non-zero negative value that rounds to
  zero is `-0.0` (`-1e-500`). `-0` is the integer 0.
- A repeated object key keeps the last value.
- In the VM (`vm/json.c`), the control pass, the leading whitespace, the
  empty input and top-level numbers and literals are its own code; a
  top-level string, array or object goes to the yyjson reader (10) with
  `YYJSON_READ_STOP_WHEN_DONE` and `YYJSON_READ_NUMBER_AS_RAW`, and any
  yyjson error is `invalid JSON` (its allocation failure is the
  out-of-memory exit). Every number reaches the VM as its text: an integer
  that fits int64 is an Int node, any other integer the big-integer node
  holding the text as written (JSON integers have no leading zeros, so the
  text is canonical), and a Float is `strtod` of the text with the zero
  rule above. Number parity relies on glibc `strtod` being correctly
  rounded in the "C" locale; recheck it on macOS and Windows when
  `platforms.yml` runs again. The yyjson tree is then copied into GC nodes with an
  explicit stack (7.3) and freed; objects are sorted by key bytes
  (`symbol<?` on the UTF-8 text) with a stable merge sort, and the last of
  equal keys is kept.

### 2.7 Typed JSON (`src/json-typed.rkt`)

- `JSON.decode(s, T)` parses `s` like `JSON.parse` (a parse failure is the
  same error value with the `JSON.parse: ` prefix), then walks the target
  type in field order, depth first, and stops at the first problem. Every
  field is required; extra keys are ignored; a repeated key keeps its last
  value, as in parsing.
- Errors are values `"<path>: expected <what>"`. The path is `$` at the
  root, `a.b` for fields, `a[3]` for list items and `a["k"]` for map keys,
  the key in `write` form. `<what>` is `object` (struct or map), `array`,
  `required field` (missing key, path of the field), `signed 64-bit Int`
  (a JSON float or an integer outside int64), `finite Float` (an integer is
  converted, and a big one that rounds to infinity fails), `Bool` or
  `String`.
- A decoded map is built in the order of the sorted JSON keys; the VM's
  object nodes are already sorted (2.6).
- `JSON.schema(T)` is the object `{type, properties, required}` of `T`,
  plus `$defs` when `T`'s fields reach any struct (`T` itself only when it
  is recursive). Every struct reached is in `$defs` once, under its linked
  name (`@2::Point` for an imported one, as the evaluator keeps it), and a
  struct field is `{"$ref": "#/$defs/<name>"}` with `~` as `~0` and `/` as
  `~1`. Int is `{"type": "integer", "minimum": -2^63, "maximum": 2^63-1}`.
- The VM (`vm/json_typed.c`) walks the JSON tree and the type table with
  one explicit stack and builds the error path only on failure; schema
  marks the types and structs reachable from the target with a queue, then
  builds one schema per marked type in index order (entries only point
  back). Neither recurses, so a
  recursive struct and a deep value are safe (7.3).

### 2.8 Files and paths (`src/filesystem.rkt`)

Every failure is an error value. Its text started as the evaluator's (Racket's
own messages included, where the evaluator lets them through); error strings
need not match (1), so they may be replaced with clearer ones. The checks
run in this order:

- `File.write`, `write_text`, `append_text`: text above 1 MiB (`filesystem:
  text exceeds 1048576 bytes`); `File.write_bytes`: `network: bytes must be
  0..255 and at most 1048576 per call`; `File.read_bytes`: `max_bytes` out
  of 1..1048576. Then the timeout (`network: timeout must be positive
  milliseconds`). `File.open` then checks the mode. A handle operation then
  checks that the handle is open (`filesystem: file handle is closed`) and
  readable or writable. `File.close` of a closed handle does no I/O.
- A path must be a nonempty String without NUL, else `NAME: contract
  violation\n  expected: E\n  given: FORM` with `path->complete-path` (and
  `(or/c path-string? path-for-some-system?)`) for `File.*` and
  `Path.resolve`, `directory-list` and `make-directory*` (`path-string?`)
  for `Dir.*`, and `build-path` for `Path.join`. FORM is the String's
  `write` form (2.3); above 256 characters it keeps the first 253 and adds
  `...` (Racket's `error-print-width`).
- A relative path is completed with the current directory (the raw
  `getcwd` bytes, read once at start-up by `agc_files_init` as Racket fixes
  `current-directory` when it starts, with a trailing `/`; if `getcwd`
  fails it is `/`, Racket's fallback too), and runs of `/` collapse,
  as Racket's host paths do. That path is what the OS gets and what
  messages show after `path: `. `Path.cwd` and `Path.resolve` return the
  directory decoded with U+FFFD for invalid UTF-8.
- Output is buffered as Racket's file ports do, 4096 bytes per handle: a
  `File.write` or `File.write_bytes` whose bytes fit with what is pending
  (pending + n <= 4096) is only appended to the buffer, with no I/O;
  otherwise the pending and the new bytes are written together and the
  buffer is empty again. `File.flush` and `File.close` write the buffer
  (`File.flush` with nothing pending does no I/O), and so does the end of
  the run for handles left open. A write error therefore shows at the call
  that writes the buffer. A handle closed by a timeout drops its buffer,
  as the evaluator's custodian shutdown does.
- Kinds follow `stat` (symlinks followed): a directory is `directory`,
  anything else `file`; a failed `stat` is no kind, except `ELOOP`, a link
  loop. Reads need a file (`filesystem: path does not refer to a regular
  file`); writes refuse a directory or a loop and create a missing file.
  A write path that ends in `/`, or `EISDIR`, gives `open-output-file: path
  is a directory\n  path: P\n  system error: path refers to a directory;
  rkt_err=9`. Other OS errors give `open-input-file: cannot open input
  file`, `open-output-file: error opening file`, `directory-list: could not
  open directory` or `make-directory: cannot make directory`, then
  `\n  path: P\n  system error: S; errno=N`, with S from `strerror` in the
  environment's message locale, like Racket.
- `File.read_text` refuses a file above 1 MiB by its size, reads at most
  size + 1 bytes, and decodes strictly: invalid UTF-8 gives
  `bytes->string/utf-8: byte string is not a well-formed UTF-8 encoding\n
  byte string: #"..."` with Racket's byte string form (`\a`..`\r`, `\e`,
  octal with three digits only before a digit 0-7), cut at 256 characters
  like FORM. `File.read_line` uses the same decoding, strips LF or CRLF,
  and fails after 1048576 bytes without a LF, having consumed 1048577.
  `File.read_bytes` reads until it has `max_bytes` or reaches EOF.
- `File.stat` gives `filesystem: path does not exist` without a kind and
  `filesystem: path is not a regular file or directory` for a loop; a
  directory's size is 0; `modified_seconds` is `st_mtim.tv_sec`.
- `Dir.list` drops `.` and `..`, decodes names with U+FFFD and sorts them
  by code point. `Dir.mkdir` follows `make-directory*`: it walks up with
  Racket's `split-path` until a parent exists, then creates each missing
  level with mode 0777; `EEXIST` is ignored, so an existing file succeeds.
- `Path.join` checks every part first, then refuses an absolute later part
  (`build-path: absolute path cannot be added to a path\n  absolute path:
  FORM`); parts join with one `/` unless the left side ends in one, and a
  left side that starts with exactly `//name` followed by a single `/` or
  the end loses one leading `/`, as `build-path` does. `Path.resolve`
  completes the path, drops `.`, pops `..` (never above `/`) and collapses
  `/`; the result ends in `/` when the input did or ended in `.` or `..`.

After a timeout on an active handle operation both backends close the
handle: later operations give `filesystem: file handle is closed` and
`File.close` gives `ok()`.

Documented difference: FIFOs and devices
count as files on both backends, but they are not compared beyond a timed
out read: the evaluator waits on them with Racket's nonblocking ports, while
the VM does a blocking read or write on a thread-pool thread. So a FIFO with
no peer can give `ok("")`, `ok([])`, end of file or an `ENXIO` error on the
VM where the evaluator times out. A timed-out VM job keeps its pool thread
until the OS call returns, and libuv's pool has 4 threads, so four calls
stuck on FIFOs or devices make every later file call in the run time out. `JSON.decode` and `JSON.schema` of `FileInfo` stay
`LOWER-UNSUPPORTED`.

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
| Void, Nil, Bool | Immediate. Tag 0 is Void, so zeroed registers are valid values. Today `vm/agc.h` has the tags above up to Fn, in that order, then `AGC_T_RANGE` (Phase 8a) and `AGC_T_JSON` (12.2 item 7); Handle joins with its PR. |
| Int, Float | `int64_t` (`__builtin_*_overflow`), `double`. |
| String | `{ size_t bytes, chars; char data[]; }`, `GC_MALLOC_ATOMIC`. `chars == bytes` means ASCII, O(1) indexing; otherwise indexing scans. Not NUL-terminated by contract. |
| List | `{ size_t len; agc_value items[]; }`, immutable. `append`, `set`, `concat` copy (same O(n) as now); indexing is O(1). |
| Map | `{ size_t size; agc_hamt *table; agc_keys *reversed; }` (`vm/map.c`): a persistent 32-way HAMT from key to value plus a persistent cons list of keys, newest first, exactly like `mapping`/`mapping-put` in `src/runtime-values.rkt`. A put copies only the path to its key (at most 14 nodes of at most 32 entries) and, for a new key, conses one cell onto the shared list; a replaced key keeps its cell, so its position. Put and lookup are O(log32 n) (12 levels of 5 hash bits and a 13th of 4 bits, then a collision node that holds the entries whose 64-bit hashes are equal and is searched linearly); building a literal of n entries is O(n log n), never O(n^2). Printing, `Map.keys` and `Map.values` walk the list once into an array, oldest first (`values` then looks each value up): O(n log n). Every node and cell is `GC_MALLOC`'d and immutable, so versions share structure. `Map.delete` (`agc_map_delete`) removes the key from the trie by copying its path (a child left with one leaf is pulled up into its parent, an empty node disappears, an empty map has no table) and copies the key list up to the key's cell, sharing the rest: O(n) like `remove` in the evaluator. A missing key returns the same map. Keys are Int (its 8 bytes, little-endian) or String (its UTF-8 bytes), compared by tag and value, which is `equal?` on them; they are hashed with SipHash-1-3, the value tag compressed as a leading 64-bit word before the bytes, so an Int and a String with the same bytes hash apart. The SipHash key is seeded once per run in `vm/main.c` from OS entropy, independent of `--seed`: on Linux `getrandom` (retried on `EINTR` and short reads), then `/dev/urandom` if `getrandom` fails (for example `ENOSYS` or `EPERM` under seccomp); `/dev/urandom` on other Unix systems and `rand_s` on Windows. If every source fails, the fixed default key stays. That is acceptable as a last resort: the hash is still 64 bits and a HAMT only degrades on full 64-bit collisions (a collision node is searched linearly), and forcing those still costs about 2^32 work per pair even with a known key. The C tests and the fuzzer keep the fixed default key. Iteration and printing order never depend on the hash. Later, if profiling asks for it: `MAP` can build its fresh literal with a transient in-place put instead of a persistent copy per pair, and a node can split child and leaf slots to use less memory. |
| Struct | `{ uint32_t type, n; agc_value fields[]; }`, declaration order. Text: the struct's display name, then `(f: v, ...)` from the table's field names. |
| Enum | `{ uint32_t variant, n; agc_value payload[]; }`; nullary variants are shared (one object per variant, made at load time). Text: enum display name, `.`, variant name, then `(a, b)` when `n > 0`. |
| Result | `{ bool ok; agc_value value; }` (`GC_MALLOC`); an error holds its String message; `ok()` holds Void. Debug form: `ok(v)`, `ok()` when the value is Void, `error("msg")` with the message in `write` form, printed by the same explicit-stack walker as lists, structs and enums. |
| Range | `agc_range { int64_t start, end; bool exclusive; }` (`GC_MALLOC_ATOMIC`), tag `AGC_T_RANGE`, immutable. Text and debug form `1..5` or `1...5` (`agc_scalar_text`; the longest form is 43 bytes, so `AGC_SCALAR_TEXT` is 48). `agc_range_bounds` gives the first and last included values and whether the range is non-empty, with no overflow for `...` (the end is above the start). `Range.size` fails with `RUNTIME-INTEGER-OVERFLOW` and `Range.to_a` above 1048576 values with `RUNTIME-INVALID-COUNT`, both at the receiver's span (`span + 1`), as the evaluator does; `first` and `last` of an empty range give `error("the range is empty")`. |
| Function value | `agc_fn { uint32_t function, n; agc_value captured[]; }` (`GC_MALLOC`), tag `AGC_T_FN`. `&name` is a value with `n = 0`. Text and debug form `<Fn>` (the checker never lets a program print one). |
| Json | `agc_json { kind; agc_value scalar; size_t count; agc_json_member *members; }` (`GC_MALLOC`), tag `AGC_T_JSON`: null, bool, int64, big integer (a String with its decimal text; parsed integers may exceed Int until extracted), double, string, array (`scalar` is a List of Json values, which `JSON.list` returns without a copy), object (`members`, `{ agc_string *key; agc_value value; }` sorted by key bytes). Objects are built by collecting pairs, then one stable sort and dedupe with the last value winning, which is the order `write-json` prints; `JSON.get` is a binary search. Text form: the JSON text; debug form `<Json>`. |
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
- Roots (runtime, schedulers, program, tasks) live in GC objects reachable
  from the runtime struct, never in mutable static storage (10.2.3).

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
  stays within it on the VM, with the same output; a
  runtime diagnostic carries one span and no stack trace, so the replaced
  frames are not visible. Non-tail recursion keeps the limit and its span.
  The evaluator is not changed: it goes away in 7i.
- `steps_left` is an atomic `int64_t` in the runtime: the limit, or
  `INT64_MAX` without one. All tasks share it; a turn takes it in batches
  (10.2.1, "As built"). `STEP` is one compare and one subtraction on a "next stop"
  counter; before 7h it is just `steps_left`, and from 7h it also covers the
  turn budget (10.2.1). Long builtins and opcodes charge their work to the
  turn only, never to `steps_left` (10.2.1, Builtins). With N schedulers,
  `steps_left` is one atomic counter that each scheduler takes from in
  batches (10.2.1, Quotas).

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
when the run ends normally, on `System.exit`, on diagnostics and on the step
limit (`agc_io_close`). While a child runs, `SIGINT`, `SIGTERM` and `SIGHUP`
kill and reap the children before the VM ends by that signal (through
`uv_signal_t`, 10.4); files are not flushed then. The out-of-memory and GC
abort exits (6.3) and `SIGKILL` run no cleanup and leave children running.
Windows is not built yet: there the plan is console control events and a
kill-on-close job object for the VM and its children, which would also
cover crashes.

### 6.3 Out of memory and GC aborts

At startup the VM sets `GC_set_oom_fn` and `GC_set_abort_func`. Their
handlers allocate nothing, `write(2, ...)` the fixed
line `agentica-vm: out of memory` (the abort handler: `agentica-vm: internal
GC error`) and call `_Exit(70)` (no atexit handlers, no stdio flush, so
buffered stdout is lost). They do not kill child processes: that would need
a global list of children, and the VM keeps none (10.2.3). A child then
sees EOF or `EPIPE` on its pipes and is left to end by itself (10.4).
Racket has no matching diagnostic, so this is a
documented difference (the exit code differs). It also sets `GC_set_warn_proc(GC_ignore_warn_proc)`,
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
loop). 7h: files (done on Linux, 2.8, 10.2.2), tasks (done, 10.2.1), processes, TCP, TLS,
HTTP, BDD.

### 7.3 Builtin safety and streams

- **Int bounds.** Every bounds check on an Int argument uses
  `__builtin_add_overflow` or the form `x < 0 || x > n - y`. A negative
  `int64_t` is never converted to `size_t` before the check.
- **No value-driven C recursion.** Printers, equality on nested data and every
  JSON operation (parse, encode, from, decode, schema) walk values with an
  explicit `GC_MALLOC`'d stack. Recursion is fine only when its depth is
  bounded by a constant or `log n` (HAMT levels, merge sort).
- **Strings to the OS.** `agc_cstr(s)` copies a String into `malloc`
  memory, so it can go to a thread-pool request, and adds the NUL; it
  returns NULL on an embedded NUL, and the caller returns the matching
  Racket message (2.8, or "command must be nonempty and arguments cannot
  contain NUL" in `process.rkt`). It is the only way a String reaches an OS
  or library call; file paths go through the same copy after the checks of
  2.8.
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
  builtins only call it; since the tasks PR each `read` runs as a
  thread-pool job that parks only the reading task (10.2.2, "Stdin"), and
  a builtin that must wait re-runs once the read is in, so what the
  builtins return did not change. A failed read
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

The VM has its own generator, so seeded sequences differ from the
evaluator's by design: `--seed N` repeats the same values run after run on
one backend, not across backends. The evaluator keeps Racket's `random`.
Only the contract is shared: the ranges, `Random.float` in `[0, 1)`, and
the `RUNTIME-INVALID-RANGE` error at the call.

- Generator (`vm/random.c`): xoshiro256** (Blackman and Vigna, public
  domain), its four state words (`agc_random` in `agc_vm`) filled by four
  splitmix64 outputs from the seed (also public domain).
- Tasks (7h, done): the generator state is per task (`agc_task.random`). The main task is seeded
  from `--seed`; a spawned task gets its own generator from its parent's at
  spawn time (a splitmix64 split of one parent draw). Each task's values
  then depend only on its own order of calls, so `--seed` repeats each
  task's values even with N>1 schedulers (10.2.3); only how output from
  different tasks interleaves is not repeatable. Every spawn takes exactly
  one draw from the parent's generator, whether or not the child uses
  `Random`, so the parent's later values depend on how many tasks it
  spawned before them. That is deterministic, but a seeded fixture that
  adds or removes a spawn changes the parent's values.
- `Random.float` is `(next >> 11) * 2^-53`. It can return exactly 0.0,
  which the evaluator's `(random)` never does; both stay in `[0, 1)`, so a
  fixture must not rely on `x > 0.0`.
- `Random.int(low, high)` (`agc_random_int`): `size = high - low + 1` in
  unsigned 64-bit arithmetic, where 0 means the full Int range (one draw
  as is). Otherwise the threshold method rejects draws below
  `2^64 mod size` (`(0 - size) % size`) and keeps `draw % size`, so the
  result is unbiased. The result is `low + offset` with wrapping unsigned
  arithmetic. `low > high` returns false without drawing, and the builtin
  fails with `RUNTIME-INVALID-RANGE` at the call.
- Seed: `--seed N` (0 .. 2147483647, the same check and message as
  `src/main.rkt`) on `agentica-vm`; `agentica --vm --seed N` passes it.
  Without it, `vm/main.c` takes 8 bytes from the same OS entropy as the
  map hash key (`getrandom`, then `/dev/urandom`; `rand_s` on Windows); if
  every source fails it uses the wall clock. `agc_vm_init` seeds with 0, so
  the C tests and the fuzzer stay deterministic.
- Tests: `vm/tests/random_test.c` checks that a seed repeats and two seeds
  differ, the bounds of `Random.float` and of `Random.int` for small,
  large, single-value and full ranges, a rough uniformity count, and that
  `low > high` leaves the state unchanged. The `random` fixture prints only
  what both backends share (counts of values in range, `[0, 1)` floats),
  and `random-invalid-range` compares the error. The extras shard checks
  that the VM repeats a seeded run, that two seeds differ, and the
  `--seed` option errors.

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
- **Tables**: known constant kinds; field counts and arities fit 16 bits;
  builtin record names only with their exact C layout; builtin `(name,
  arity)` pairs exist.
- **Types**: at most 65535 types, each with a known kind; a List or Map
  entry names an earlier type and nests at most 1024 List and Map levels
  (the writer gives `BYTECODE-LIMIT` past that), a Struct entry a struct in range that has a
  decodable record; records name structs in range in increasing order (so
  at most one each) with distinct names (sorted, then adjacent names
  compared), have one field type per field (the count checked
  against the bytes left), and every field type index is in range. So the
  only cycles go through named structs. `vm/tests/loader_test.c` checks
  each rule and truncation at every byte of a file with a type table.
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
- `agentica-vm [--max-steps N] [--seed N] [--allow-run] [--ai|--json] --
  file.agcb [args...]` (7e; `--allow-run` since the 7h processes PR). The option parser is hand
  written: it stops at the first non-option and honors `--`. Option values are
  checked with exit code 2, as in `src/main.rkt`. Callers
  always pass `--` before the file. A test checks that `--allow-run` after the
  file is a program argument. On Windows, arguments come from `wmain`
  (`-municode`) and are converted to UTF-8; the input file is opened with `_wopen` on the original UTF-16 argument, so
  non-ASCII paths load and a lone surrogate never maps to another file. The
  size comes from `_fstat64`, so a file over 2 GiB is rejected, not read
  as a prefix. Paths over 260 characters fail with `_wopen` unless they use
  `\\?\` or the executable has a `longPathAware` manifest; 7h decides.
  `--schedulers N` (10.2.3) comes with the 7h multicore schedulers item;
  `agentica --vm --schedulers N` passes it through, as it does `--seed`. A
  differential test runs a copy named `cálculo-λ-日本-𝔸.agcb`, and a CRLF
  program under a non-ASCII directory.
- `agentica-vm --version` prints the VM version and the versions of libgc
  (and libuv, picohttpparser and OpenSSL from 7h). For OpenSSL it prints the version in use:
  in the default dynamic build that is the loaded library's
  `OpenSSL_version(OPENSSL_VERSION)`, not the headers it was built with.
- In the slice the VM accepts `--version`, `--max-steps N`, `--seed N`
  (7.4), `--ai`, `--json`, `--allow-run` (10.4) and `--`. `--ai` and `--json` may both appear; the last one
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
  runs the VM as `agentica-vm [--max-steps N] [--seed N] [--allow-run] [--ai|--json] --driver-pid
  PID -- file [args...]`. `--driver-pid` is a hidden VM flag (not in the
  usage text). On Linux the VM first sets `SIGTERM` back to its default
  action, calls `prctl(PR_SET_PDEATHSIG, SIGTERM)` (`SIGTERM`, not
  `SIGKILL`, so the VM kills its children before it ends, 10.4) and then
  checks that `getppid()` is `PID`; if not, the driver
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
  VM never ran or failed before loading, and on a break. On a break
  (`SIGINT`, `SIGTERM` or `SIGHUP` to the driver) the driver stops a
  running VM with `SIGTERM`, waits up to 2 seconds for it to end, and only
  then sends `SIGKILL`; the VM's watchers kill its children in that
  time (10.4). When a driver
  output port is not a file stream (rackunit, captured output) it copies
  that stream through a pipe, and a non-file stdin is copied into the VM's
  stdin by a thread that stops when the VM exits. The thread reads ahead
  of what the program consumes, so on a non-file stdin shared with other
  code the driver may take bytes the program never read. If reading the
  driver's stdin fails, the thread stops the VM the same way and the driver reports
  `RUNTIME-INTERNAL` (exit 1), as the evaluator does for a failed read;
  a special (non-byte) value on the port ends the input like EOF. Otherwise it passes the real stdin, stdout
  and stderr, so the VM's output and exit code reach the user unchanged. Front-end and `LOWER-` diagnostics print as without
  `--vm` (exit 1). `--seed N` and `--allow-run` are passed to the VM.
  `--steps`, `--dump`, `--dump-ir`, `check`, `compile`, `help` and `test`
  exit 2 with `--vm does not support X`.
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
| yyjson | 7 (JSON) | Vendored: git submodule `vm/third_party/yyjson` (MIT, its `LICENSE` stays in the submodule), pinned to tag 0.13.0. Only the reader: `make vm` compiles `src/yyjson.c` into its own object (`$(VM_BUILD)/yyjson.o`, with the sanitizers in a `SANITIZE=1` build but without `-Werror`) with the writer, incremental reader, file API, JSON Pointer/Patch, non-standard extensions and its own float conversion disabled. Its reader does not recurse and is fuzzed on OSS-Fuzz. It allocates with `malloc` and holds no GC pointers; the document is freed right after the copy into GC nodes (2.6). Under `AGC_NO_GC` it allocates through `agc_alloc_atomic` instead (freeing is a no-op), so the fuzzer's per-mutant limit counts it. The encoder is our own (2.4), since yyjson's writer formats floats and escapes differently. |
| libuv | 7h | Vendored the same way: git submodule `vm/third_party/libuv` from `https://github.com/libuv/libuv` (MIT, with BSD-2-Clause and ISC parts in its `LICENSE-extra`; both files stay in the submodule and ship with releases), pinned to tag v1.53.0. `make vm` compiles its Linux sources (the list in its `CMakeLists.txt`) per build mode into `$(VM_BUILD)/uv/` with its own defines (`-std=gnu11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64`), the mode's flags (the sanitizers in `SANITIZE=1`, no `-Werror`), and links `$(VM_BUILD)/libuv.a` statically with `-ldl -lrt`. Linux only for now; macOS and Windows builds leave it out and have no file builtins. No system package. |
| picohttpparser | 7h (HTTP) | Vendored: git submodule `vm/third_party/picohttpparser` from `https://github.com/h2o/picohttpparser` (dual MIT or Perl license; we take MIT; the notice is in `picohttpparser.h`, and releases ship it extracted to a license file), pinned to tag v1.4 (commit `516cdd3e00b3`). It parses and validates the start line and headers (`phr_parse_request`, `phr_parse_response`), behind our adapter (10.6); `phr_decode_chunked` is not used, since it knows no limits. `make vm` compiles `picohttpparser.c` per build mode into `$(VM_BUILD)/picohttpparser.o`, like yyjson, at the baseline (no `-msse4.2`; its SSE4.2 path is a SIMD candidate, `future.md` §19). Everything else in HTTP is our own C. |
| OpenSSL 3 | 7h | Dynamic by default, static as an option (10.0). `make vm` (`OPENSSL=system`) finds the system OpenSSL 3 with `pkg-config libssl libcrypto` and links `-lssl -lcrypto`; `make vm OPENSSL=static OPENSSL_PREFIX=/path` links `libssl.a` and `libcrypto.a` from that prefix by full path, searching only that prefix's `pkg-config` files, and fails rather than fall back to the system's shared libraries. Not vendored; see the note on OpenSSL under the license rule. |

License rule: vendored or statically linked third-party code must be MIT,
BSD, ISC, zlib, Apache-2.0 or similarly permissive (no copyleft). Its
license file stays with it (in the submodule) and ships with releases.
Where there is no license file, releases ship the notice extracted to one:
bdwgc's from its `README.QUICK`, like picohttpparser's from its header.
The notices that ship with the VM also include the Unicode License v3
notice for `vm/unicode_data.c`, which is generated from Unicode data.
OpenSSL 3 (Apache-2.0) is permissive too, but it is singled out for two
reasons: Apache-2.0 adds an attribution duty (its `LICENSE.txt`, and a
`NOTICE` file if one is present; OpenSSL 3.0 to 3.5 have none), and the
default build does not ship it at all, since it is linked dynamically. It
is linked statically only in release artifacts that include its
`LICENSE.txt` (10.0). Agentica itself is `Apache-2.0 WITH LLVM-exception`,
and releases ship its `LICENSE` and `NOTICE` alongside the third-party
licenses.

### 10.0 Linking OpenSSL

The default build links OpenSSL 3 dynamically, so `dist/agentica-vm` needs
libc and `libssl.so.3`/`libcrypto.so.3`. All other libraries stay static.
The dynamic build is the default for local builds, CI and distro packages;
every downloadable release artifact (the `dist/` archive and the single
file) is built with `OPENSSL=static`, so it needs only glibc's own
libraries (libc, libm and the dynamic loader; on an older glibc baseline,
`future.md` §18). The release baseline is Debian bookworm
or newer, whose `libssl-dev` has the OpenSSL 3 static archives (glibc
2.36); an older baseline would need a built OpenSSL prefix.

- `make vm` (default `OPENSSL=system`) finds the system OpenSSL 3 with
  `pkg-config libssl libcrypto` and links `-lssl -lcrypto`. A missing
  OpenSSL, or one older than 3.0, stops the build with a clear error.
- Why dynamic: security fixes come with the distro's `libssl.so.3`, with no
  VM release; the system OpenSSL knows its own CA store (`OPENSSLDIR`); the
  binary is smaller and CI does not build OpenSSL; we do not ship OpenSSL
  code, so its attribution duty does not apply (license rule above); and
  the OpenSSL 3.x ABI is stable.
- `make vm OPENSSL=static` links a static OpenSSL 3, for the release
  artifacts or minimal glibc images without OpenSSL (distroless, `scratch`
  style). musl (Alpine) needs its own build (`future.md` §18); there the
  dynamic build with Alpine's `openssl-dev` works. If a musl artifact is
  ever released, it is static too (musl plus a static OpenSSL).
- `OPENSSL=static` needs `OPENSSL_PREFIX=/path`, a prefix with `libssl.a`
  and `libcrypto.a`; without it the build stops with an error. Debian's
  `libssl-dev` ships both archives, so CI and the release build use
  `OPENSSL_PREFIX=/usr` with the distro's own static archives and never
  build OpenSSL. Any other prefix works too (for example OpenSSL built with
  `no-shared`). There is no vendored OpenSSL submodule unless the release
  workflow needs one later.
- The static build must never link the system's shared OpenSSL by
  accident. Its recipe unsets `PKG_CONFIG_PATH` and sets
  `PKG_CONFIG_LIBDIR` to the prefix's `lib/pkgconfig`, `lib64/pkgconfig`
  and `lib/<multiarch>/pkgconfig` (multiarch from `$(CC) -print-multiarch`
  when it is not empty), which replaces `pkg-config`'s default search path.
  The build fails if `pkg-config --exists libssl libcrypto` fails there, or
  if `pkg-config --variable=libdir` for `libssl` or `libcrypto` is not
  inside `OPENSSL_PREFIX`. The VM links the two archives by full path, in
  that `libdir` (so the `.pc` files decide `lib`, `lib64` or the multiarch
  directory). The extra libraries come from libcrypto's `Libs.private`
  (`pkg-config --static --libs-only-l --libs-only-other libssl
  libcrypto`): each `-lX` that is not part of glibc is linked as `libX.a`
  by full path, found through `pkg-config` in the same environment, and a
  missing one is a build error. Nothing is hard-coded; on Debian trixie,
  for example, `libcrypto.a` needs `-lz -lzstd` (from `zlib1g-dev` and
  `libzstd-dev`). Only glibc's own flags (such as `-ldl`, `-pthread`,
  `-lm`) stay as they are. The static CI or release job checks `readelf
  -d` of the VM against an allowlist: `NEEDED` may only name libc, libm and the dynamic loader
  (`ld-linux`), plus libpthread, libdl and librt on an old glibc.
- Both modes take `pkg-config --cflags libssl libcrypto` from the same
  `pkg-config` environment as their link flags.
- `pkg-config` never runs when the Makefile is parsed (no parse-time
  `$(shell pkg-config ...)`), so `make site`, `make dup-check` and the
  Racket-only tests do not need OpenSSL. The recipe for the
  `build/vm/flags` stamp runs `pkg-config` and writes the resolved cflags
  and link flags there, with `OPENSSL` and `OPENSSL_PREFIX`; the link
  recipe reads them back. A change of mode, prefix or flags relinks.
- The VM needs only OpenSSL 3.0.0 and loads with any 3.x. It calls only
  symbols of the `OPENSSL_3.0.0` version node; OpenSSL also has later
  nodes inside 3.0 (`OPENSSL_3.0.3`, `3.0.8`, `3.0.9`, for example
  `OPENSSL_strcasecmp`) and in 3.1 and later. `-DOPENSSL_API_COMPAT=30000`
  only hides deprecated API; what enforces the rule is a check in the
  normal dynamic CI `test` job, after `make vm`: it fails if
  `objdump -T dist/agentica-vm | rg -o 'OPENSSL_3\.[0-9.]+' | rg -v '^OPENSSL_3\.0\.0$'` prints anything. Newer features
  (Argon2id and `OSSL_set_max_threads` need 3.2) are found at run time: if
  `EVP_KDF_fetch` returns `NULL`, the call returns an error `Result` that
  names the missing feature.
- A static OpenSSL's built-in paths point at the build machine, so the
  static build finds the CA store itself (10.3).
- Static release artifacts ship OpenSSL's `LICENSE.txt` (and its `NOTICE`
  if a later version adds one), as the license rule above requires.
- Rejected for now: loading OpenSSL with `dlopen` only when a program uses
  TLS. It is more complex, so the default VM needs libssl even for programs
  without TLS. On purpose, then, without an OpenSSL development package the
  VM does not build and all VM tests skip locally; install `libssl-dev` to
  run them.

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

libuv also stays for multicore (10.2.3); we do not replace it with raw
epoll or io_uring. libuv works with one loop per thread, which is what
one loop per scheduler needs. It gives the thread pool for files (epoll
cannot poll regular files), process spawn, signals and DNS, which we would
otherwise write ourselves on each platform. libuv types stay inside the I/O
layer (`vm/loop.c`, added in 7h, and the builtin files that use it), so a later swap to
raw epoll or io_uring stays local if measurements ever ask for it.

### 10.2 Rules for 7h

- The design target is multicore: N scheduler threads (M:N, as in BEAM,
  10.2.3), each running the interpreter and its own libuv loop. The first
  tasks PR of 7h runs N=1, but on the structures built for N schedulers.
  N>1 is built only if a measured server needs it (roadmap order). Tasks are
  VM stacks. A blocking builtin starts a libuv request, parks its task, and
  the scheduler runs another ready task (10.2.1). Only the scheduler that
  owns a loop calls `uv_run` on it. libuv and OpenSSL callbacks only copy
  results and mark tasks ready.
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
  `malloc`'d, and `uv_fs` buffers are `malloc`'d copies. The GC object that owns a handle sits in the owning scheduler's resource
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
- **Run queue.** Each scheduler has its own FIFO run queue of ready tasks. A
  new task, a task whose turn ended, and a task woken by a libuv callback
  all go to the back of their scheduler's queue. With N>1, an idle scheduler
  steals ready tasks from other queues (10.2.3).
- **Reductions, as in BEAM.** Each turn has a budget of steps, counted by
  `STEP` like `--max-steps` (`STEP n` counts n). It starts at 2000 and is
  tuned by measurement in 7h; 7g gives the cost of `STEP` with one task. When
  a `STEP` spends the turn's budget, the task goes to the back of the run
  queue and the next one runs. A merged `STEP n` that crosses the turn
  budget charges all n, then yields at the next instruction; the extra is not
  carried over to the next turn. If it crosses `--max-steps`, the task fails
  at the span of 4.2 instead (see "One counter for both budgets"). To the
  program the scheduler is preemptive; inside the VM it switches only at a
  `STEP`, a safe point, or right after a builtin or opcode whose turn cost
  spent the turn (see "Builtins"; the next instruction is a safe point
  too). Every loop passes a `STEP`: backward jumps land on one, and every
  function that calls starts with one (8), so a `TAIL_CALL` loop passes it
  too. A task also leaves its turn when it blocks.
- **Builtins.** No builtin's C code is stopped halfway. A resumable builtin
  (4.3: `map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`) can be
  switched out only between its callbacks. Any other builtin finishes in its
  turn: `List.sort` on a big list, `String.join` of many parts,
  `JSON.encode` of a big value, or the sort inside `sort_by` after its keys
  are collected, runs to the end without a switch. `STEP` alone would then
  be the only fairness signal, and one task could hold the scheduler long
  past its turn. So a builtin whose work grows with its input charges a
  **turn cost** for that work: about one unit per item it handles (list
  items, map entries, JSON nodes; a sort counts n·⌈log2 n⌉ comparisons) and
  one per 64 bytes of text it copies or scans. The units are tuned with the
  turn budget in 7h; a builtin with constant work charges nothing. The turn
  cost is taken from the turn only, never from `--max-steps`
  (`steps_left`), so it never changes when `--max-steps` stops a program. When the builtin has
  returned and its result is stored, the task yields at the next
  instruction if its turn is spent (see "One counter for both budgets").
  This does not cut a long builtin in half: it bounds what runs after it.
  A resumable builtin charges one turn unit per callback call the same way
  and may yield between two callbacks, so a callback short enough to skip
  its leading `STEP` (8), which charges no step, no longer runs a whole
  list in one turn. The counting builtins (`Range.each`, `Int.times`,
  `upto`, `downto`) have no list to bound them, so each callback call
  charges one step through the same check as `STEP` and is a switch point.
  Some opcodes also do work that grows with their operands, outside
  `CALL_BUILTIN`: `CONCAT` copies both strings, `TO_TEXT` and `INSPECT`
  build the text of a whole value (interpolation, `to_s`, `inspect`,
  `puts` of a big list), and `EQ`, `NE` and `SAME` compare whole strings
  (`==` on big strings, String literal patterns in `case`; the checker
  allows `==` only on scalars, strings and ranges). `MAP_GET`, and `MAP`
  for each entry, hash a String key whole (SipHash, `vm/map.c`) and
  compare it with the keys they meet (`key_equal`). They leave a turn cost
  in the same per-task field, with the same units (one per 64 bytes
  copied, built, hashed or compared), and it is applied after the
  instruction through the same path (below). The other opcodes do
  constant work, or work bounded by their operand count (`LIST`,
  `STRUCT`, `CLOSURE`, at most 255 items), and charge nothing.
- **One counter for both budgets.** `STEP` counts down one "next stop"
  counter. It is set to `min(turn_left, steps_left)` when a turn starts and
  after each sync (below), and the value it was set to is kept. The fast
  path runs while `counter > n` for `STEP n`: one compare and one
  subtraction. Turn costs never touch the counter, so the fast path stays
  that. Otherwise the slow path first syncs: it takes the steps spent since
  the counter was set (the kept value minus the counter) out of both
  `turn_left` and `steps_left`. Then, if `steps_left < n`, the task fails
  with `RUNTIME-STEP-LIMIT` at span `s + steps_left` (4.2), and nothing more
  is charged. If not, all n is charged to both budgets, and the task yields
  if `turn_left <= 0`; it resumes at the next instruction. Otherwise the
  counter is set again.
  A turn cost of c units is applied by `CALL_BUILTIN` after the builtin
  returns, by a native frame between two callbacks, and by the opcodes of
  "Builtins" after their work, and only when c > 0. The builtin or opcode
  leaves c in a per-task field that is 0 by default; the apply path reads
  it and sets it back to 0 before it charges, so a cost is charged once. A
  builtin or opcode that fails through `agc_fail` (`longjmp`) never reaches
  the apply path: the run ends (6.2), and a field left non-zero is dropped,
  since the field is also cleared when a turn starts. A constant builtin
  pays one compare on the builtin path and nothing on `STEP`. The apply
  path syncs as above, then takes c from `turn_left` only. If
  `turn_left <= 0`, the task yields at the next instruction, with the
  result already in its register; otherwise the counter is set again to
  `min(turn_left, steps_left)`. The sync cannot fail: the counter is never
  above `steps_left`, so the steps spent fit in it.
  `steps_left` never sees c. Like the extra of a merged `STEP n`, a turn
  cost past the end of the turn is not carried over to the next turn. The
  other way, setting the counter to 0 so that the next `STEP` takes the
  slow path, was not chosen: the slow path would have to tell that forced
  stop from a real one and keep the steps spent somewhere else, and the
  task would yield only at the next `STEP`, not right after the builtin.
  So that the 7h latency test can show it fails without the rule, a test
  environment variable, `AGENTICA_VM_TEST_NO_TURN_COST=1`, read once at
  start-up into the runtime config, makes the apply path skip the charge.
  It changes only when tasks switch, never output, step counts or
  diagnostics, so every build honors it and the latency test uses the
  normal `make vm` binary. It is for tests only, not documented for users,
  and may be removed after 7i.
  With N schedulers, `steps_left` in this bullet is the scheduler's batch
  (Quotas): the sync takes spent steps out of the batch, not the atomic
  counter, and a turn cost touches neither. The turn-cost path checks the
  cancel and stop flags as the `STEP` slow path does (10.2.3).
- **Fairness with I/O.** After each turn (or every N turns, if measurement
  asks for it) the scheduler calls `uv_run(UV_RUN_NOWAIT)`, so ready I/O wakes
  its tasks even while other tasks keep computing. Timers (`Task.sleep`) wake
  the same way, inside `uv_run`. Tasks woken during a `NOWAIT` go behind the
  tasks already queued. The scheduler blocks in `uv_run(UV_RUN_ONCE)` only
  when its run queue is empty and, with N>1, it found nothing to steal.
  Without channels, a parked task waits on I/O, a timer, or another live
  task, so either some loop has an active handle or some queue is not empty.
  If every scheduler is idle, no loop has an active handle, and tasks are
  still parked, the VM fails with `RUNTIME-INTERNAL` and does not spin. With
  N=1 this is the plain check that `uv_run` reports no active handles; for
  N>1 see 10.2.3, Stall check. With the turn costs of "Builtins", a ready
  timer or I/O event waits at most for the turns of the tasks queued ahead
  of it, each about one turn budget plus the last builtin call or opcode
  of that turn. A test in the 7h tasks PR (roadmap) checks it: while one
  task loops on CPU, one calls a long builtin and one runs a `CONCAT`-heavy
  loop, a `Task.sleep` wake and a stdin pipe read must stay within a
  generous measured limit.
- **Quotas.**
  - `--max-steps` stays one global budget shared by all tasks (`steps_left`,
    6.1), as today. Preemption never changes what is charged, and turn
    costs (see "Builtins") are never charged to it. With one task, a
    runaway program stops with `RUNTIME-STEP-LIMIT` as on the evaluator
    (black-box parity, 1; today counts and spans also match, 2.1). With several tasks,
    which task fails at the limit depends on the interleaving, so, like
    cross-task output order, it is not compared.
  - With N schedulers, `steps_left` is one atomic counter. A scheduler takes
    a batch from it when a turn starts (one turn's budget, or what is left
    if less) and gives the unspent part back at once when the turn ends,
    when the task parks mid-turn, and when the scheduler goes idle. The "next
    stop" counter is set from the batch, so the fast path stays one compare
    and one subtraction and touches no atomic. A `STEP n` that crosses the
    end of its batch first takes more from the shared counter, and fails
    with `RUNTIME-STEP-LIMIT` only when that is not enough. With N=1 this is
    the same as one plain counter, so counts and the span `s + steps_left`
    are those of one task's counter. With N>1, other schedulers may hold
    unspent batches, so the run may stop up to (N-1) times the turn budget
    below the limit, and which task hits the limit is not compared, as
    cross-task output order is not compared.
  - Per-task step quotas could later use the same counter. They are not in
    7h.
  - Per-task memory quotas are out of scope: the Boehm heap is shared, unlike
    BEAM's per-process heaps. Only a global heap limit is possible (13).
- **N=1 first.** The first tasks PR of 7h runs one scheduler, but on the
  split structures of 10.2.3, so going to N>1 later adds threads, stealing
  and the I/O hand-off without a rewrite.
- **As built (tasks PR).** `vm/task.c` holds the scheduler (`agc_vm_run`,
  the FIFO run queue, wake, park) and the `Task` builtins; `vm/interp.c`
  runs one turn of the current task (`agc_run_turn`, which returns yield,
  parked or done) and owns the budget code (`agc_turn_begin`,
  `agc_turn_finish`, the `STEP` slow path, the turn-cost apply path).
  Decisions and tuning:
  - The turn budget stays 2000 steps (`AGC_TURN_STEPS`), and one turn
    unit is one step, one list item, map entry or JSON node, or 64 bytes
    (`AGC_COST_BYTES`). Measured with the latency test: a `Task.sleep(10)`
    wake is at most about 20 ms late next to a CPU loop, a task sorting
    100,000 Ints (one sort is about 25 ms) and a task concatenating a
    1 MiB string; a stdin echo about 30 ms. Without turn costs the same
    waits take about 4.5 s. Single-task speed did not change measurably
    (the `make bench` programs within noise of the previous VM).
  - Builtin costs come from a `cost` field in each C table entry:
    `AGC_COST_SIZE` charges the size of the arguments and of the result
    (String bytes / 64, List items, Map entries, Json members) around
    the call, for the builtins whose work is linear in those sizes
    (`String.upcase`, `split`, `join`, `replace`, `index_of`, ...,
    `List.append`, `concat`, `take`, `drop`, `reverse`, `repeat`,
    `Map.keys`, `values`, `Range.to_a`, `JSON.parse`, `JSON.list`,
    `puts`, `IO.read`, `Path.join`). Walkers charge from inside:
    `agc_sort_by_keys` (n·⌈log2 n⌉), `agc_debug`, `agc_text` and
    `agc_json_encode` (output bytes), `agc_json_from` and
    `agc_json_decode` (one per node), `agc_key_hash` and the map key
    compare (String bytes, so `MAP`, `MAP_GET` and every `Map` builtin
    are covered), and `EQ`/`NE`/`SAME` on equal-length Strings. `CONCAT`
    charges its result bytes. File builtins charge nothing: their work is
    I/O, at most 1 MiB per call.
  - The step budget is the runtime's atomic `steps_left`; a turn takes a
    batch of `AGC_TURN_STEPS` (or what is left) and gives the unspent part
    back at its end, and a `STEP n` past its batch takes more first, so
    with N=1 the stop is exact: the program stops at the step that passes
    the limit. Without
    `--max-steps` the counter starts at `INT64_MAX`.
  - `Task.sleep(0)` yields (the task goes to the back of the queue).
    `Task.sleep(n)` starts a timer-only job (`agc_io_kind` with no `work`
    half) and parks. Under `no_files` (the fuzzer) every sleep yields, so
    a mutant never waits on a clock.
  - A turn cost charged where no apply path follows is applied at the
    next one: the cost of a resumable builtin's last step (the sort in
    `sort_by`) right after its native frame finishes, and the cost of a
    parked task's `done` half (a big `Dir.list` sort) right after the
    turn begins, so the task may yield before it runs anything.
  - Stdin EOF: each read that returns EOF bumps the input's `eof_seq`, and
    each task keeps the last `eof_seq` it has seen (`input_seen`; a spawn
    starts at the current one). A task that needs more input and has not
    seen the latest EOF gets it once, so every task that waited for that
    read sees the EOF and a TTY reader never blocks for a second Ctrl-D.
  - `Task.await` of a running task appends the caller to that task's
    FIFO of waiters and parks with *retry*: when the target finishes, the
    waiters are queued in order and each re-runs its `CALL_BUILTIN`,
    which now returns the cached result. Stdin reads and a second
    reader waiting for a read in flight use the same retry (a wake is
    only a hint, as 10.2.3 asks). A task whose bottom frame returns, or
    leaves through `try`, is done; its registers and frames are dropped.
  - Cancellation: when `main` returns, the run ends; ready and parked
    tasks never run again, and `agc_io_close` closes their timers and
    jobs as before. A failure or `System.exit` in any task ends the run at
    once through `agc_fail`/`agc_exit`, as the evaluator's first
    published outcome does.
  - Stall check (N=1): the queue is empty and `uv_loop_alive` is false
    (or there is no loop) while `main` is not done: `RUNTIME-INTERNAL`
    ("every task is waiting and nothing can wake them"). No Agentica
    program reaches it: a task can only await tasks created before it
    (there are no channels and no way to pass a task its own handle), so
    awaits form no cycle, and every other wait holds a libuv request or
    timer. It guards against VM bugs.
  - Under the black-box rule (§1) a multi-task run must stop with
    `RUNTIME-STEP-LIMIT` when it runs away, and the `--max-steps` sweep
    (§12.1) needs each limit to give the full outcome or the step limit
    with stdout a prefix of the full run. The task fixtures keep that
    deterministic: their step counts do not depend on the clock, and main
    prints after its awaits. Which task meets the limit depends on the
    interleaving, so the span may differ from the evaluator's.

#### 10.2.2 The loop

The first 7h PR had one task; the tasks PR added the run queue (10.2.1,
"As built"). What the loop has:

- **Resource registry** (`vm/loop.c`). `vm->registry` is a GC object with
  an array of `agc_resource` GC objects. Each one owns `malloc` memory
  (`native`) and a `release` function, and keeps its slot until it is
  unregistered. A `FileHandle` value points to its resource; its `native`
  is the `malloc`'d file state (descriptor and read buffer), NULL once
  closed. Each pending request is a resource too, whose `native` is a
  `malloc`'d job with the `uv_work_t` and its `uv_timer_t`. The job stays
  registered until its work callback has run, its timer's `uv_close`
  callback has run, and its result was taken. No GC pointer is stored in
  `malloc` memory, and no `handle->data` is used: callbacks find their job
  with `offsetof`.
- **Blocking builtins** are two halves. The C builtin checks its arguments
  in the evaluator's order, copies what the OS needs into a `malloc`'d
  request (paths through the rules of 2.8), and calls `agc_io_start`, which
  queues one `uv_queue_work` request for the whole operation (stat, open,
  read, close: one thread-pool job, so the task parks once per call) and
  starts a timer for the call's timeout after `uv_update_time` (a
  negative timeout starts no timer, a kind without `work` is a timer
  only). It records the task in the resource (`r->task`) and in
  `task->parked`, and marks the task as parking. `CALL_BUILTIN` sees that,
  keeps the result register (`park_reg`) and ends the turn.
- **Waking**: the work and timer callbacks only set flags and append the
  `malloc`'d job to the loop's ready list. After each `uv_run` the
  scheduler drains that list: the job keeps its registry slot (an index,
  updated when `agc_unregister` moves an entry), so the scheduler finds
  the resource and queues its task. No GC pointer is stored in `malloc`
  memory.
- **Parking** is the scheduler's job. After each turn it calls
  `uv_run(UV_RUN_NOWAIT)` when the loop is alive; with an empty run queue
  it calls `uv_run(UV_RUN_ONCE)`, or fails with `RUNTIME-INTERNAL` when the
  loop has nothing alive (stall check, 10.2.1). When a parked task runs
  again, `agc_io_finish` closes the timer and, on completion, calls the
  request's `done` half on the interpreter thread, which turns the
  `malloc`'d result into GC values and frees the request; on timeout it
  calls `expired`, which
  gives `filesystem: operation timed out` and, for a handle operation,
  closes the handle as the evaluator does (the stuck request then owns the
  file state). The result goes into the call's result register. A
  timed-out job stays registered until its work ends; then its `drop` half
  frees it and the file state it owns, which closes the descriptor.
- **Thread-pool threads** only run the `work` half: system calls on
  `malloc` memory. The libuv pool keeps its default size (4,
  `UV_THREADPOOL_SIZE`). `UV_USE_IO_URING` is set to `0` (unless already
  set) before the loop is created, so libuv uses its plain thread pool and
  epoll. Boehm is built without thread support (until 10.2.3) and never
  sees these threads. `agc_io_start` blocks `SIGINT`, `SIGTERM` and
  `SIGHUP` around `uv_queue_work`, so the pool threads (made on the first
  call) start with them blocked and only the loop thread runs libuv's
  handler for them (10.4).
- **Descriptors** open with `O_CLOEXEC` (and `O_NONBLOCK` before the kind
  check, then blocking for reads and writes in the pool).
- **End of run.** `vm/main.c` calls `agc_io_close` after the run, however
  it ended: open handles are closed (the evaluator's cleanup), timers are
  closed, the loop runs once without waiting, and the loop is freed when no
  job is left. Closing a handle writes its pending output. `agc_io_close`
  returns false when a job is still stuck in the OS (a read on a silent
  FIFO, say); `vm/main.c` then flushes stdout and stderr and ends with
  `_exit`, because a normal exit would run libuv's destructor, which joins
  the pool threads and would wait for that read. The flush of a handle's
  write buffer at the end of run is a blocking write, so it can block on a
  FIFO whose reader stopped reading, as Racket's flush in
  `filesystem-close-all!` does (parity). A handle whose operation is still
  running in the pool (`main` returned while a child task's read was in
  flight) is not released: the job still uses its state. It is released
  after the loop's last run once that job's work is done; otherwise it
  stays registered, `agc_io_close` returns false, and the process ends
  with `_exit` as above.
- **Per-handle lock (tasks PR, as built).** A `FileHandle` resource has a
  `holder` (the job resource of the operation in flight on it), a
  `next_owner` task and a FIFO of waiting tasks, all on the GC
  `agc_resource`, never in `malloc` memory. `agc_io_start` sets `holder`
  when its context is a handle. Every handle builtin (`read_bytes`,
  `read_line`, `write`, `write_bytes`, `flush`, `close`) first checks its
  arguments and timeout, then calls `agc_handle_wait`, and only then checks
  that the handle is open and has the right mode, as the evaluator does
  inside its semaphore. `agc_handle_wait` gives the lock to the task when
  it is the `next_owner`, or when there is no holder and no `next_owner`;
  otherwise the task joins the FIFO and parks with retry on a timer-only
  job that ends at its own deadline (set from its `timeout_ms` at the
  first wait and kept across retries). At the deadline the task leaves
  the FIFO and the builtin returns the timeout error; the handle stays
  open, as with the evaluator's `network-timed` around the semaphore. One
  deadline covers the wait and the operation, as there: a task that gets
  the lock passes what is left of its timeout to the operation, and one
  that gets it after its deadline returns the timeout error (waking the
  other waiters first, as a `next_owner` does).
  Release is a FIFO hand-off, never a free-for-all: `agc_io_finish`
  clears `holder` before the `done` or `expired` half runs, pops the
  head waiter, makes it `next_owner` and wakes only it, so the releasing
  task cannot take the handle back in the same turn (a looping reader
  next to `File.close` ends, as with Racket's fair semaphore). When the
  `next_owner` takes the lock it wakes the rest, which re-run and queue
  again in order behind it; that also covers an owner whose call ends
  without a job (a buffered write, a closed handle). So `close` waits
  for the operation in flight, two readers take turns and never share
  the read buffer, and buffered writes keep their order. On an operation
  timeout, `expired` hands the state to the stuck operation and closes the
  handle (`native` is NULL), so the next owner gets "file handle is
  closed" and never touches the state the stuck work still uses. Wait
  lists link tasks through `wait_next`, apart from the run queue's
  `next`, since a waiter woken by its timer is in both until it runs.
- **External jobs (processes PR).** A kind with `external` set has no
  `work` half: nothing runs in the pool. A libuv callback on the loop
  thread (a pipe read, a finished write, a child's exit) completes it with
  `agc_io_ready`, which marks the work done and puts the job on the ready
  list like a pool job; a second call, or one after the job was taken, does
  nothing. The timer, the `done` and `expired` halves, the lock hand-off
  and `drop` are the same as for pool jobs, and `agc_io_close` marks an
  external job done when it takes it at the end of the run.
- **Fuzzing.** `agc_fuzz_one` sets `vm->no_files`, so mutated programs
  never touch the file system; a file builtin (`Path.cwd` and
  `Path.resolve` too, since they read the current directory) then ends the
  run with `RUNTIME-INTERNAL`. It never sets `--allow-run`, so `Process.spawn`
  returns its error and no child starts. It still calls `agc_io_close` before
  `agc_release_all`, on the normal path and after the allocation limit, so
  a loop or a resource would never outlive the mutant.

**Stdin (deviation from 10.2).** Stdin is read by thread-pool jobs, not
by `uv_pipe_t`/`uv_tty_t` handles chosen with `uv_guess_handle`: a job
does one blocking `read(0)` (with `poll` on `EAGAIN`) into a `malloc`'d
buffer of up to 1 MiB, and its `done` half appends the bytes to the
shared `agc_input` buffer (owned by the runtime, served by scheduler 0)
and wakes the tasks waiting for that read. It works for every kind of
descriptor (TTY, pipe, file, socket) with one code path, and it never
changes the descriptor's flags: `uv_pipe_open` and `uv_tty_init` make the
inherited descriptor non-blocking, which leaks into the parent's open file
description (a shell's terminal) when the VM is killed. One read is in
flight at a time; a second reader parks in the input's FIFO. A read stuck
at the end of the run is handled like a stuck file job (`_exit`). A stdin
read shares the pool with file jobs, so four stuck file calls delay it.
Non-Linux builds keep the blocking read.

How tasks extended it (10.2.1): `agc_io_park` became the place where a task
leaves its turn. It records the task and the result register, and the
scheduler runs the next ready task; the work and timer callbacks, which
today only set flags, also put the task at the back of the run queue;
when the task runs again, the same completion code calls `done` or
`expired` and stores the result. The scheduler calls `uv_run` with
`UV_RUN_NOWAIT` between turns and `UV_RUN_ONCE` only when the run queue is
empty. Handles got a per-handle lock (the evaluator's semaphore), as
built above. It is a task-level lock: waiters park in a FIFO, and it is
never an OS mutex. With N>1 (10.2.3) each scheduler has its own
loop, and an operation on a handle owned by another scheduler goes through
the I/O hand-off.

#### 10.2.3 Multicore: M:N schedulers

The design lets the VM use all CPU cores (parallelism), not only run tasks
concurrently. It follows BEAM. It is gated: the roadmap builds it only after
the server measurement (7j) and the evaluation round (6c), and only if that
measurement shows CPU-bound work that one scheduler cannot serve.

- **Schedulers.** N scheduler threads. The default is
  `uv_available_parallelism()`, which respects CPU affinity; `--schedulers
  N` sets it, capped at 1024, and 0, negative or non-numeric values exit 2
  like other bad VM flags. `--schedulers 1` gives the N=1 order (which still
  depends on timer and pool timing).
  `--seed` does not imply `--schedulers 1`: a repeatable run needs
  `--schedulers 1` given explicitly; at N>1 only each task's random values
  repeat (7.4).
  Each scheduler has its own run queue, its own `uv_loop_t` (libuv loops are
  per thread) and its own resource registry. The loop and the wake
  `uv_async_t` are `malloc`'d, pointed to by the scheduler struct, and freed
  after `uv_loop_close` at shutdown: pool threads and other schedulers write
  to them, so they are never GC memory. Tasks are green VM stacks, as
  in 10.2.1, and reductions and turns stay as they are there.
- **Work stealing.** A scheduler whose queue is empty steals from the queues
  of others. It takes only ready tasks; a parked task stays with the
  scheduler that owns what it waits on. A steal makes the thief the task's
  home. A spawned or preempted task stays on its own scheduler's queue, for
  locality. As in BEAM, when a scheduler pushes onto its queue while the
  idle count is above 0 and its queue holds more than one task, it sends
  `uv_async_send` to one idle scheduler, which then tries to steal. It
  picks that scheduler from an atomic idle bitmask (one bit per scheduler,
  set while idle). Requeueing a preempted task onto the same queue does not
  touch the shared packed word (Stall check), since the task never stops
  being live.
- **Home scheduler and waking.** Every task has a home scheduler: the one
  whose queue it was last put on. Waking a task (an await finishing, an I/O
  reply, cancellation) pushes it onto its home scheduler's MPSC wake queue
  and calls `uv_async_send` on that scheduler's wake handle. A task's result
  and state changes are published with release/acquire, or under a small
  per-task lock, so an awaiting task on another scheduler sees the whole
  result. Cancellation sets the task's cancel flag, plus a wake if it is
  parked.
- **Cancel and stop flags.** The task's cancel flag and the run's stop flag
  are atomics, checked only on the `STEP` slow path, when the "next stop"
  counter runs out. The fast path still touches no atomic. A cancel or stop
  takes effect within one turn budget.
- **Park and wake protocol.** Each task has an atomic state: RUNNING,
  PARKING, PARKED or WOKEN. To park, the task sets RUNNING to PARKING
  before it registers its wait. Then it re-checks its wait condition and
  its cancel flag; if either is satisfied, it unregisters and goes back to
  RUNNING with one CAS that accepts PARKING or WOKEN. Otherwise it CASes PARKING to PARKED. Registering on another
  task's result is done under that task's lock and fails if the result is
  already published. A waker acts only on PARKING (CAS to WOKEN, no queue:
  the task's CAS fails, so it sets WOKEN to RUNNING and re-checks at once)
  and on PARKED (CAS to WOKEN, then queue the task). A waker that finds
  PARKING, and so does not queue, undoes its pending-wake increment. A wake
  that finds
  RUNNING or WOKEN is stale and dropped. The scheduler sets
  WOKEN to RUNNING when the task's turn starts. A resumed task re-checks
  its wait condition, so a wake is only a hint. No wake is lost, and a task
  is queued at most once.
- **State split.** As built (`vm/agc.h`): `agc_runtime` (shared),
  `struct agc_vm` (the scheduler: the context every builtin gets, with
  `rt`, the current `task`, the run queue, `loop`, `registry`, the turn
  counters and the `fail` jmp_buf) and `agc_task`. Deviations, with N=1:
  the runtime is GC-allocated by `agc_vm_init` and reachable from the
  scheduler, not a struct on the main thread's stack (both are roots for
  Boehm); the `fail` jmp_buf is per scheduler, not per task, because the
  only `setjmp` is the scheduler's own, armed once on its thread, and any
  failure ends the run; the task state is a plain READY, RUNNING, PARKED,
  DONE enum without the PARKING and WOKEN steps, which only matter when
  another thread can wake a task; and there are no stream locks, since
  one thread writes. Every field of the old `struct agc_vm` has a place:
  - Runtime, read-only after start-up: `program` (with its constants),
    `args`, `cwd` (raw bytes, read at start-up by `agc_files_init`),
    `no_files`, and the config. Also in the runtime but shared under rules: the
    atomic `steps_left` (10.2.1, Quotas), `outcome` (set once by a CAS on the outcome kind, 6.2), `out`
    and `err` (one lock per stream, see Output). Stdin (`in`, an
    `agc_input`) is a handle owned by scheduler 0 (see I/O ownership).
  - Per scheduler: the loop (`loop`), the run queue, the resource registry
    (`registry`) and the turn counter.
  - Per task: the registers and frames (`regs`, `reg_capacity`, `frames`,
    `frame_capacity`, `frame_count`, `depth`), `random` (7.4), the `fail`
    jmp_buf target (armed on the thread that runs the task's turn), the
    string cursor cache (`cursor`, `cursor_index`, `cursor_offset`), and
    `parked`, the request the task waits on, which it sets while PARKING
    (see Park and wake protocol).
  - A runtime diagnostic or `System.exit` on any scheduler ends the run
    (6.2): that scheduler records the outcome once and sends
    `uv_async_send` to every other scheduler; they stop at their next
    `STEP` slow path or loop wake-up, then cleanup runs.
- **I/O ownership.** A libuv handle belongs to the loop that created it. A
  task parked on I/O wakes on the scheduler that owns that loop. If a task
  that was stolen to another scheduler uses a handle owned elsewhere, the
  operation is sent to the owner loop (an MPSC queue plus `uv_async_send`),
  and the task parks until the reply. The reply wakes it on the scheduler
  that owns the loop: that one becomes its home. A stolen task that keeps
  using a handle owned elsewhere moves back to the owner on each
  operation; this is intended, for locality. Thread-pool threads still
  never touch GC memory (10.2).
- **Stdin.** Stdin is a handle owned by scheduler 0. Reads from other
  schedulers go through the same hand-off. Each read stays whole because
  the owner keeps a FIFO of waiting reader tasks and serves one read at a
  time. No OS mutex or spinlock is ever held across a park.
- **Output.** Each print to stdout or stderr is written whole under one lock
  per stream, so lines from different tasks never mix mid-line. These
  writes never park, so the lock is never held across a park. Under the
  lock, a write checks for short writes and `ferror` and retries. Once the
  outcome is set, writes are dropped; the check is made under the stream
  lock. The final diagnostic that `vm/main.c` prints is exempt. Only the order in which output from different tasks interleaves is
  not repeatable.
- **Idle schedulers park, not spin.** An idle scheduler (empty queue,
  nothing to steal) raises the idle count, re-checks the queues once (a
  read only; it leaves idle before it pops or steals), then refs its wake `uv_async_t` and blocks in
  `uv_run(UV_RUN_ONCE)`, so its loop stays alive even with no other handle.
  A wake or new work for it calls `uv_async_send`. When the run ends, each
  scheduler unrefs its wake handle so its loop can close. With N=1 the wake
  handle is never ref'd, so the plain "no active handles" check of 10.2.1
  still holds.
- **Stall check.** For N>1 it uses only atomic counters, never `uv_run`'s
  return value. One 64-bit atomic word packs the idle scheduler count and
  the live count (handles, parked I/O and timer waiters, pending wakes,
  pending I/O hand-offs, and ready tasks in run queues), so the check reads
  one snapshot. The per-scheduler wake `uv_async_t` is not counted. A
  pending wake or hand-off counts as live: the sender increments the count
  before the push, and the receiving scheduler decrements it when it drains
  the item. Every hand-on of liveness (waiter, then pending wake, then
  ready task) increments the new item before it decrements the old one, or
  does both in one CAS on the packed word. A libuv callback that readies a
  task on an idle scheduler leaves idle in that same CAS. A scheduler
  leaves idle before it touches a queue or drains a wake.
  The check runs on every change of the word that makes idle == N and
  live == 0: the idle increment and every live decrement. The thread that
  makes that change, if tasks are still parked, fails the run with
  `RUNTIME-INTERNAL` and wakes the other schedulers (10.2.1, Fairness).
- **Main thread.** It does the start-up-only work (`GC_INIT`,
  `GC_allow_register_threads`, the `setenv`, the SipHash keys, the messages
  locale), starts schedulers 1..N-1, runs scheduler 0 itself, and joins the
  others after its own loop ends.
- **Shutdown.** Each scheduler closes its own registry's handles and runs
  its own loop to completion on its own thread before the main thread
  joins it.
- **GC.** Boehm is built with `GC_THREADS`, `PARALLEL_MARK` and
  `THREAD_LOCAL_ALLOC`. The main thread calls `GC_allow_register_threads()`
  first. Scheduler threads are created with `GC_pthread_create` or register
  with `GC_register_my_thread`; the libuv pool threads stay unregistered on
  purpose, since they never touch GC memory. The runtime struct stays on
  the main thread's stack, which Boehm scans, for the whole run. MPSC wake
  and hand-off queue nodes, and the run-queue and steal-deque storage, are
  GC-allocated; if one is not, the task or payload it carries is also
  rooted in the owner's registry until it is drained. Collections
  stop the world; that cost is accepted and measured (round 2 benchmarks,
  which also measure contention on the packed word of the Stall check).
  Boehm stops threads with signals, installed with `SA_RESTART`, and the
  VM's syscall paths retry on
  `EINTR`, and libuv signal handling (`uv_signal_t`) must never take
  Boehm's suspend and restart signals.
- **No mutable global state in `vm/`.** Every mutable `static` or global
  variable goes into the runtime, scheduler or task struct. Lazy one-time
  init uses `pthread_once` or happens at start-up. `make vm-lint` enforces
  this with clang-tidy's `cppcoreguidelines-avoid-non-const-global-variables`
  on `vm/*.c` and `vm/agc.h` (`vm/tests/.clang-tidy` turns it off for the C
  tests); the check does not see function-local `static` variables. What
  `vm/` has today:
  - Exceptions that stay, each with
    `// NOLINT(cppcoreguidelines-avoid-non-const-global-variables)`: the
    `AGC_NO_GC` block tracking in `vm/value.c` (fuzz and test builds only,
    single-threaded); the fuzz harness statics in `vm/fuzz.c` and
    `vm/fuzz_main.c`; `wide_args` in `vm/main.c` (Windows), set once before
    any scheduler starts; the block-scope `extern char **environ` in
    `vm/process.c`, read (never written) when `Process.spawn` builds a
    child's environment.
  - `agc_init` (`vm/value.c`) asks Boehm (`GC_is_init_called`) instead of
    keeping a `ready` flag.
  - The GC-stress counter in `vm/value.c` (`AGC_GC_STRESS`, a test build
    only) is `_Atomic`.
  - `Result.message` of an `Ok` and `String.join` of an empty list make a
    fresh empty string; the shared `empty_string` and `empty_text` are gone.
  - The SipHash keys are `hash_key` in `agc_vm`, set by `agc_vm_init` and,
    from OS entropy, by `vm/main.c` before the run.
  - The locale for OS error text (`vm/files.c`) is `messages_locale` in
    `agc_vm`, made on first use and never freed. The tasks PR made it
    once at start-up (`agc_files_init`), read-only in the shared runtime,
    and freed on exit (`agc_files_close`).
  - `setenv("UV_USE_IO_URING", "0", 0)` in `vm/loop.c` runs when the first
    loop is made; `setenv` is not thread-safe, so the tasks PR moved it to
    start-up (`agc_io_init`, called by `vm/main.c` before any loop exists).
    `agc_io_init` returns whether it set the variable; `vm/main.c` keeps
    that in the shared runtime (`drop_uring_env`) for `Process.spawn`
    (10.4).
    The tasks PR also moved the `agc_vm` fields above to the shared
    runtime or the scheduler.
- **Values are immutable**, so tasks on different schedulers share them
  without locks. Any in-place mutation inside the VM (caches, updates in
  place when a value is known to be unique, the faster lists of roadmap 8d)
  must be proven unshared or made atomic. Future mutable structures (for example mutable vectors)
  and the shared tables of `future.md` §13 must use an owner scheduler or
  locks and atomics. A table call does not yield, so it is atomic with N=1;
  once N>1, each table call needs a lock, an owner scheduler, or a
  persistent structure installed with compare-and-swap (as the evaluator
  does with `box-cas!`).
- **Order of work.** First the tasks PR on these split structures with N=1;
  then, if the gate above opens, the multicore schedulers item (N>1, work
  stealing, Boehm threads, the I/O hand-off, and a stress test of the task
  fixtures with
  `--schedulers 4`, under TSan when available; TSan does not get along with
  Boehm's stop-the-world, so that run uses an `AGC_NO_GC`-style build with
  `-fsanitize=thread` that never calls `agc_set_alloc_limit`, so the
  `AGC_NO_GC` block tracking stays off. ASan and TSan, both without GC,
  cover memory errors and data races in the scheduler code; the
  GC-threaded build is covered only by a GC-stress run with
  `--schedulers 4`); then round 2 of the benchmarks covers multicore
  (roadmap phase 12) if it landed. Multicore does not block 7i: the
  evaluator cannot run in parallel anyway. The parity rule stays
  black-box (1): with N=1, exit code, stdout, program stderr and diagnostic
  codes match the evaluator. The differential, bytecode and golden tests, the `--max-steps`
  sweep and the seeded runs all run the VM with `--schedulers 1`.

### 10.3 TLS

- OpenSSL 3, which Racket's `openssl` module also uses. The default
  dynamic build initializes without `OPENSSL_INIT_NO_LOAD_CONFIG`, so
  OpenSSL loads the system `openssl.cnf` as it does for Racket, and the
  distro's hardening applies. The `OPENSSL=static` build initializes with
  `OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG, NULL)`, since its
  configuration path points at the build machine, and sets explicit
  minimums (TLS 1.2, security level 2); this is a documented difference of
  the static build.
- With an empty `ca_file`, use system trust like
  `ssl-secure-client-context`, matching Racket: the CA file and the CA
  directory are two sources, and each is replaced on its own. On Linux the
  default dynamic build loads exactly Racket's sources: the file is
  `SSL_CERT_FILE` or else `X509_get_default_cert_file()`, the directory is
  `SSL_CERT_DIR` or else `X509_get_default_cert_dir()` (both under
  `OPENSSLDIR`), loaded with `SSL_CTX_load_verify_file` and
  `SSL_CTX_load_verify_dir` (3.0 API; no store URI). The `OPENSSL=static` build (10.0) cannot use its built-in
  paths, which point at the build machine: the file is `SSL_CERT_FILE` or
  else the first existing file of a list of distro bundles
  (`/etc/ssl/certs/ca-certificates.crt`,
  `/etc/pki/tls/certs/ca-bundle.crt`, ...), and the directory is
  `SSL_CERT_DIR` or else none. Racket probes such paths only for its
  natipkg OpenSSL build (`RACKET_USE_ALT_PATH`). The static build has two
  documented differences: this CA-bundle probing, and its own TLS
  minimums without `openssl.cnf` (above). On a normal host the
  evaluator and the dynamic VM both use OpenSSL's defaults. On Windows only
  the `ROOT` store, on macOS only the Keychain anchors, never
  OpenSSL's default paths. A non-empty `ca_file` replaces system trust.
  Trust-store usage and disallowed lists are honored only as far as Racket
  honors them.
- Per connection: `SSL_set1_host`, SNI set, IP literals through
  `X509_VERIFY_PARAM_set1_ip_asc`. There is no `SSL_VERIFY_NONE` path.
- Hermetic tests: wrong hostname, self-signed server without `ca_file`, and a
  `ca_file` that excludes system roots.

### 10.4 Processes

- `--allow-run` is the VM's own flag, checked inside `Process.spawn` at call
  time for every task and handler, as `current-process-allowed?` does.
- The VM resolves the executable itself, with one rule shared with Racket
  and written in `grammar.md` (Processes): a command that contains `/`
  resolves against the program's working directory; a bare name is looked
  up in each `PATH` entry in order. The VM never adds the working
  directory itself: empty entries are skipped, and an explicit relative
  entry such as `.` or `bin` resolves against the working directory, as in
  the shell. It passes the absolute path to `uv_spawn`.
  All three stdio streams are pipes.
  `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS` is never used.
- The file loop sets `UV_USE_IO_URING=0` in the VM's own environment
  (10.2.2). The processes PR must not pass it on: it removes it from the
  child's environment unless the user had set it before the VM started.
- Windows: after resolution, allow only `.exe` and `.com`, case-insensitively,
  and reject names with a trailing dot or space or any `:`. Both backends use this same
  allowlist: the Racket check in `process.rkt` (`windows-runnable-name?`)
  applies it to the last component of the resolved path, and the VM must do
  the same when its process code is ported to Windows. On Windows the
  evaluator also searches the current directory before `PATH` (Racket's
  `find-executable-path`); the VM's port must not.

**As built (processes PR, Linux).** `vm/process.c` holds the eight
`Process` builtins; only it and `vm/loop.c` include `uv.h`. Other systems
get an empty table, so the lowerer's keys fail at load as unknown imports.

- **Values.** A `Process` value (`AGC_T_PROCESS`, printed `<Process>`) is
  a GC `agc_process` with three `agc_resource` pointers: `state`, the
  registered resource whose `native` is the `malloc`'d process state, and
  two lock records, `reader` and `writer`, that are never registered and
  only carry the lock fields of 10.2.2. `read_line` and `read_bytes` take
  the reader lock, `send`, `send_bytes` and `close_stdin` the writer lock,
  through `agc_handle_wait`, as the evaluator's two semaphores; `wait` and
  `close` take neither. So a reader parked on a silent child never blocks
  a writer, and a lock-wait timeout leaves the process running (the
  evaluator's `network-timed` around a semaphore).
- **Spawn.** Checks in the evaluator's order (`--allow-run` before any
  work on the arguments, then a nonempty command and no NUL, then the
  timeout), resolution as above (a path that does not exist or is a
  directory is "executable is unavailable"), then three real pipes made
  with `uv_pipe` and given to the child with `UV_INHERIT_FD` (libuv's
  `UV_CREATE_PIPE` makes socketpairs, which some programs treat
  differently), and the parent's ends opened with `uv_pipe_open`. The
  first spawn of a run also marks every descriptor the VM inherited above
  2 close-on-exec (a walk over `/proc/self/fd` with `fcntl`;
  `close_range` is not declared under the VM's `_POSIX_C_SOURCE` build),
  and the VM opens its own descriptors close-on-exec, so a child sees only
  0, 1 and 2, as with the evaluator. `argv[0]` is the resolved path. The
  child's environment is the VM's, without `UV_USE_IO_URING` when
  `drop_uring_env` says the VM set it. A failed `uv_spawn` (`EACCES`,
  `ENOEXEC`) is an error `Result` with the OS text (`agc_system_error`).
  `Process.spawn` charges a turn cost by the size of its arguments
  (`AGC_COST_SIZE`, 10.2.1).
- **State.** The `malloc`'d `proc` holds the `uv_process_t`, the three
  `uv_pipe_t`, one `uv_write_t`, the stdout buffer, and the pending
  requests (one reader, one writer, a list of waits). Callbacks find it with
  `offsetof`. It is freed when its resource was released, every request
  that points to it was dropped, and the close callback of each of its
  libuv handles ran (a user count and a handle count), so no callback ever
  sees freed memory.
- **Operations park only their task** on external jobs (10.2.2) with the
  call's timeout on the job's timer. Reads start `uv_read_start` on stdout
  only while a reader waits and stop as soon as its line or bytes are
  buffered (or at EOF or an error). Each read asks for 4 KiB, or for what
  a `read_bytes` still needs when that is more, so the VM reads at most
  about 4 KiB past what the program asked for, like the evaluator's 4 KiB
  port buffer, and a child that writes much more than the program reads
  blocks on its pipe as it does there. A write first tries
  `uv_try_write`; the rest is copied and sent with `uv_write`, and the
  task parks until its callback. `wait` returns at once when the child has
  exited and its stderr reached EOF; otherwise it parks on a job that
  `exit_cb` or the stderr EOF readies. A timed-out read or write closes
  the process, as the evaluator does; a timed-out `wait` leaves the child
  running.
- **Stderr** is read all the time and each chunk is written and flushed to
  the program's stderr in the read callback, so it reaches the user in
  order with `IO.warn` output and without waiting for a builtin. If that
  write fails, the rest is read and dropped.
- **Close.** `Process.close`, a timed-out read or write, and the end of
  the run (`agc_io_close` releases every resource, also after
  `System.exit`, a runtime error or the step limit) all go through one
  close. If the child still runs, it sends `SIGKILL` and polls `waitpid`
  with `WNOHANG` every 0.1 ms until a `CLOCK_MONOTONIC` deadline 1 second
  away; a child normally dies within the first polls. `Process.close` and
  a stream timeout give their one child its own deadline. A cleanup of all
  children (the end of the run, or a stop signal, below) sends `SIGKILL`
  to every running child first and then reaps them under one shared
  deadline, so the whole cleanup stays within about 1 second, inside the
  driver's 2-second grace (9). A child in uninterruptible sleep (a hung
  network file system, say) can outlast that bound: then, and when the
  kill fails (`EPERM`, for example a child that became another user
  through `sudo`), the VM does not wait. It keeps the `uv_process_t` open
  so that libuv reaps the child when it ends and `exit_cb` closes the
  handle. A failed kill in `Process.close` ends the run with
  `RUNTIME-PROCESS-CLOSE`, as the evaluator's failed cleanup does; inside
  a timed-out read or write the timeout error stands. If such a child is
  still there at the end of the run, `uv_loop_close` fails and the VM ends
  with `_exit` (10.2.2), leaving that child to `init`. Otherwise the pipes
  are closed at once; libuv's own reap later finds no child and does
  nothing. The waiting reader, writer and waits are readied and see
  "process is closed". A second `close` does nothing, and any other
  operation after it returns "process is closed", as in the evaluator. So
  no child outlives a run that ends normally and no zombie or pipe stays
  behind.
- **Signals.** The first spawn of a run makes a guard with one
  `uv_signal_t` each for `SIGINT`, `SIGTERM` and `SIGHUP` (not for a
  signal the VM started with ignored, as under `nohup`), registered as a
  resource so the end of the run releases it. The guard keeps a list of
  the running children and starts its watchers before the first child's
  `uv_spawn`, so a signal that comes during a spawn is seen once the
  child is listed; it stops them when the last running child is reaped,
  so a program with no running child keeps the default actions (and the
  scheduler's stall check). libuv's own handler only writes to a pipe, so
  nothing runs in signal context. When a watcher runs on the loop thread,
  it kills and reaps every running child and raises the signal again
  after stopping the watchers, so the VM ends by that signal as it would
  without children. Stopping a watcher could drop a signal that libuv
  caught but had not dispatched yet (it discards the queued message of a
  stopped watcher), so every stop blocks the three signals on the loop
  thread, compares the watcher's `caught_signals` with its
  `dispatched_signals` (fields of the pinned libuv's `uv_signal_t`), and
  when one was caught it raises it before unblocking: the VM then ends by
  it once the children are gone. The pool threads keep the three signals
  blocked (10.2.2), so no handler runs on another thread while the loop
  thread stops the watchers. The loop runs between turns, so a CPU-bound
  task delays the cleanup by at most one turn. A blocking write to stdout
  delays it until that write ends, which may be never: if nobody reads the
  VM's stdout any more (for example `agentica --vm prog.agc | less` after
  the pager stopped reading and the driver died), the VM stays blocked in
  `write`, never runs its loop, and neither it nor its children react to
  the `SIGTERM` (the parent-death signal of 9 included); the VM has no
  alarm fallback for this. A VM killed by `SIGKILL`, or ended by the
  out-of-memory exit (70, 6.3), leaves its children running (they get EOF
  or `EPIPE` when they next touch a pipe). `agentica --vm` stops the VM
  with `SIGTERM` and kills it only after 2 seconds (9), so a cleanup that
  takes longer than that leaves the rest of the children running.
- **Black-box differences.**
  - A file that exists but cannot be executed (no execute permission, a
    bad format) is an error `Result` from `Process.spawn` on the VM; the
    evaluator returns a process that writes `exec failed` to stderr and
    exits 1.
  - After a read or write timeout closes a process, the evaluator's dead
    stream thread keeps that direction's semaphore, so a later read (or
    write) in the same direction waits its whole timeout and returns
    "network: operation timed out"; the VM returns "process: process is
    closed" at once (an evaluator bug, not copied).
  - A `read_line` or `read_bytes` pending in another task when the
    process is closed (by `Process.close`, or by a send that timed out)
    returns "process: process is closed" on the VM; the evaluator returns
    Racket's port error ("read-byte: input port is closed" and similar).
  - When forwarding the child's stderr fails (the program's stderr is
    `/dev/full`, say), the evaluator's forwarding thread fails and kills
    the child; the VM drops the rest of that stderr and keeps the child.
  - libuv resets signals 1 to 31 to their default action in the child, so
    a signal the VM inherited as ignored (`nohup`) is not ignored in its
    children; Racket's children keep it ignored. The VM does not patch
    libuv for this.
  - `Process.spawn` checks its timeout but does not apply it to the
    lookup and start, which run without a timer; the evaluator runs them
    under it. Only timing can differ.
  - Error texts of failed system calls follow `agc_system_error`.

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
| HTTP interim responses | 15 accepted, the 16th fails | `read-response-head`, `http-wire.rkt` |
| `max_connections` | at most 65536 | `http-client.rkt` |
| HTTP body | `max_body_bytes`, 413 | `http-wire.rkt` |
| Process launch | `--allow-run` | `process.rkt` |
| Windows programs other than `.exe`, `.com` | rejected | `process.rkt` |

HTTP numbers: `Content-Length` and chunk sizes accumulate with saturation:
parsing stops once a value exceeds the limit (413), and every comparison is
written `size > limit - total`. A hermetic test sends over-long values.

### 10.6 HTTP parsing

Parity with the evaluator is black-box (1): the exit code, the stdout and
program stderr of every run except one stopped by `--max-steps`, the
diagnostic code, and the HTTP status or `Result` error kind must match; message text, spans, step counts and library error
strings may differ. For HTTP this means:

- Well-formed messages: the VM and the evaluator agree on the status, the
  headers, the body, and whether a `Result` is ok or an error.
- Malformed or hostile input: both reject it. A server answers with an
  error status and closes the connection; a client request call returns an
  error `Result` (the "error kind" in this section; its message text is
  free). The exact 4xx or 5xx code may differ, except these, which must
  match: 413 (body over the limit), 431 (too many headers or trailers, or
  a line, head or trailer block over its size limit), 505 (a request with
  an HTTP version the evaluator rejects with 505; a bad response version
  is a client error `Result`) and 501 (`CONNECT`, and any
  `Transfer-Encoding` other than one `chunked`).
- The VM does not copy evaluator quirks (for example 431 for a bad chunk
  terminator byte), and it does not have to report the first failing line
  in the evaluator's order.
- Documented differences: picohttpparser's RFC 9112 leniencies, one
  leading empty line before a request and runs of spaces in the start line,
  are accepted. They do not make framing ambiguous. The reason phrase
  accepts what picohttpparser accepts; control bytes in a reason phrase
  give a client error on the VM.
- Framing rules stay strict: `Content-Length` with `Transfer-Encoding`
  (with any `Transfer-Encoding`, this is 400 first), conflicting `Content-Length` values (400), bad chunk sizes and obs-fold
  are rejected. Equal duplicate `Content-Length` values (the header twice,
  or `5, 5`) are accepted as one, like the evaluator (RFC 9110 §8.6).
  `Transfer-Encoding` other than one `chunked` (`gzip`, `gzip, chunked`,
  two `Transfer-Encoding` headers) gives 501.

The VM does not copy `src/http-wire.rkt` check by check. picohttpparser
validates the head; that is why it is a dependency (and its SSE4.2 path
later, `future.md` §19). It sits behind our own small adapter, so it can be
swapped later (for example for llhttp), the same way libuv stays inside
the I/O layer.

- `vm/http_parse.h` holds our types only: a parsed head struct (method,
  target, version, status, reason, and the headers with their count, all
  as byte slices into the input buffer) and
  `agc_http_parse_request_head(buf, len, limits, out)` and
  `agc_http_parse_response_head(buf, len, limits, out)`. They return OK
  with the bytes consumed, INCOMPLETE, or ERROR with our own error enum.
- Only `vm/http_pico.c` includes `picohttpparser.h`. No picohttpparser type
  or return code leaks out of it.
- The adapter calls picohttpparser without `last_len`, and only when the
  newly read bytes complete a line (contain LF). Each call parses the whole
  buffered head again. A head is at most the start line (8192 bytes plus
  CRLF) and 64 KiB of headers (10.5), and it has at most about 100 lines
  (the start line, 100 headers and the blank line) before the pre-scan
  stops it, so parsing work is bounded by lines × head size. On INCOMPLETE
  the caller reads more and calls again with the grown buffer.
- A -1 from picohttpparser maps to one error: 400 "invalid HTTP request
  head" for a server, and an error `Result` ("invalid HTTP response head")
  for a client.
- The adapter checks more than picohttpparser, all on our own pre-scan or
  on picohttpparser's output:
  - The pre-scan (one pass over newly read bytes) checks the line and
    head size limits (431), rejects bare LF (kept strict against
    smuggling), and counts header lines: once the count passes 100 it
    returns 431, before picohttpparser runs. Before a request, the
    pre-scan and the start-line check skip one leading CRLF, matching the
    documented leniency, so the header count is not off by one. The
    pre-scan stops at the end of the start line; the start-line check
    (431 for its length, then 505 or 400) runs before the pre-scan looks
    at any header line.
  - Once the start line is complete, and before picohttpparser runs, the
    adapter checks it itself with the evaluator's shape. A request is
    `METHOD SP+ TARGET SP+ VERSION`, a response `VERSION SP+ 3DIGIT`. In
    a request, a version of the form `HTTP/[0-9.]+` gives 505 unless it is
    exactly `HTTP/1.1` (so `HTTP/1`, `HTTP/2`, `HTTP/1.10` and `HTTP/2.0`
    give 505); any other bad shape gives 400. In a response, a bad version
    or shape is a client error `Result`. So a complete bad start line
    always fails at once, even where picohttpparser would still return -2
    for short input.
  - Request target: origin form (`/...`), or `*` with `OPTIONS`; only bytes
    33 to 126; anything else is 400.
  - Method: token characters only (400); `CONNECT` gives 501.
  - obs-fold lines (picohttpparser returns a header with `name == NULL`)
    are rejected with 400.
  - Responses: `HTTP/1.1` only, status 100 to 599, 101 rejected, at most
    15 interim responses (the 16th fails); these give an error `Result`.
  - The `Host` rules, and the body framing and smuggling rules above
    (conflicting `Content-Length` 400, unsupported `Transfer-Encoding`
    501).
- The body is never buffered whole by the parsing layer. Our own body
  decoder, `vm/http_body.c` (no third-party code), is an incremental state
  machine. It is set up with the framing (`Content-Length` n, chunked, or
  until close for responses) and the `max_body_bytes` limit; then
  `feed(buf, len)` returns the bytes consumed, zero or more body slices
  pointing into the input, and NEED_MORE, DONE or ERROR: 413 over the
  limit, 431 for an over-long chunk-size or trailer line or for trailers
  over the block-size or count limit, and 400 for every other malformed
  body. Chunk sizes accumulate with saturation;
  `phr_decode_chunked` is not used, since it knows no limits. `HttpBody`,
  `HTTP.request_stream` and `HttpWriter` read and write through it chunk by
  chunk, so a large upload or download never sits whole in memory. Trailer
  lines are checked by the body decoder with the header rules (token
  names, value bytes, the forbidden trailer list, and the size and count
  limits), as `http-wire.rkt`'s `read-headers` with `#:trailers? #t`. The
  encoder that writes chunked output is ours too. Swapping the head parser
  leaves the body decoder unchanged.
- Tests target the adapter interface, so a replacement parser must pass the
  same tests: a C unit test in `vm/tests/`, and fixed, deterministic hostile
  cases run on both backends. They check that both reject (and the code
  where it must match), not message text: `Content-Length` with
  `Transfer-Encoding`, conflicting `Content-Length` (400), equal duplicate
  `Content-Length` twice and as `5, 5` (accepted), `Transfer-Encoding:
  gzip`, `gzip, chunked` and two `Transfer-Encoding` headers (501), huge
  chunk sizes (413), bare LF, over-long lines and heads (431), 100 headers
  accepted and 101 and 150 rejected with 431, trailers over the line,
  block-size or count limit (431), `HTTP/1`, `HTTP/2`, `HTTP/1.10` and
  `HTTP/2.0` (505), an `HTTP/2.0` start line followed by 101 headers in
  one write (505), a malformed version, a leading CRLF before a request
  with 100 headers (accepted), absolute-form and non-ASCII targets, `*`
  without `OPTIONS`, a bad method token, `CONNECT` (501), an obs-fold line,
  bad trailers, and on the client
  side `HTTP/1.0` responses, status 99 and 600, a 101 response, and 15
  interim responses accepted and 16 rejected. One case sends a complete bad
  start line ending in CRLF and leaves the socket open: it is rejected
  before any timeout; another sends the short line `GET / HTTP/1\r\n`,
  which gets 505.

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
  yyjson's `src/yyjson.c` is compiled per build mode into
  `$(VM_BUILD)/yyjson.o` with only its reader enabled (10).
  picohttpparser (7h) is compiled the same way into
  `$(VM_BUILD)/picohttpparser.o`, without `-msse4.2` (10, 10.6).
  `NO_EXECUTE_PERMISSION` maps the heap without execute permission: macOS on
  arm64 refuses writable and executable pages (`Cannot allocate executable
  pages` once the heap grows), and Linux no longer gets RWX heap pages.
  bdwgc always honors interior pointers from the stack and registers;
  `ALL_INTERIOR_POINTERS` extends that to pointers stored in GC objects and
  static data and to one-past-the-end pointers, at one extra byte per
  object. Nothing in the VM relies on it today; it is upstream's default and
  costs nothing measurable. libuv (7h) is built from its submodule into
  `$(VM_BUILD)/libuv.a` per build mode (10). OpenSSL (7h) is linked
  dynamically by default: `OPENSSL=system` checks `pkg-config
  --atleast-version=3.0 libssl libcrypto` and links `-lssl -lcrypto`.
  `OPENSSL=static` requires `OPENSSL_PREFIX`, unsets `PKG_CONFIG_PATH`,
  sets `PKG_CONFIG_LIBDIR` to the prefix's `lib/pkgconfig`,
  `lib64/pkgconfig` and `lib/<multiarch>/pkgconfig`, fails if `pkg-config
  --exists libssl libcrypto` fails there or if `--variable=libdir` is
  outside the prefix, and links `libssl.a` and `libcrypto.a` from that
  `libdir` by full path, plus each other non-glibc library of libcrypto's
  `Libs.private` as its `.a` archive by full path (a missing one is a
  build error); only glibc's own flags stay (10.0). Both modes take `pkg-config --cflags` from the same
  environment and compile with `-DOPENSSL_API_COMPAT=30000`. The recipe
  for the `build/vm/flags` stamp runs `pkg-config` and writes the resolved
  flags; the link recipe reads them back; nothing runs `pkg-config` at
  Makefile parse time.
  The Agentica version is read from `src/version.rkt` with `sed`, so the VM
  build needs no Racket. Output `dist/agentica-vm`. The compiler flags,
  `OPENSSL`, `OPENSSL_PREFIX` and the resolved OpenSSL cflags and link
  flags are recorded in `build/vm/flags`, so switching between a normal and
  a sanitizer build, or between OpenSSL modes, always relinks.
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
  to `/dev/null`, so the diagnostic printer is fuzzed too. Under `AGC_NO_GC` it
  then frees every block of that mutant (`agc_release_all`, a no-op with libgc),
  so the fuzzer's peak memory is that of one mutant plus ASan's quarantine,
  which still catches a use after free across mutants. Steps bound
  instructions, not bytes, so a mutant can still grow a value to gigabytes;
  `agc_set_alloc_limit` gives each mutant 256 MB (each block counted with 64
  bytes of overhead), and an allocation past it longjmps back to
  `agc_fuzz_one`, which frees the mutant and returns 2 (a mutant that counts
  as run; a seed that fails). Blocks are tracked only while a limit is set,
  and yyjson allocates through `agc_alloc_atomic` in this build, so its
  documents count toward the limit and are freed with the mutant. The VM
  itself sets no limit. `agc_fuzz_one` is linked only
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
  VM cannot be built locally (no C compiler, the submodule is not checked
  out, or no OpenSSL 3 development package or `pkg-config`) and fail in CI
  (`AGENTICA_REQUIRE_VM=1`), as `AGENTS.md` requires.
  `make vm` reads `SANITIZE` from the environment, so the sanitizer job sets
  `SANITIZE=1` once and the tests rebuild the sanitized VM.
- Supply chain: pinned runner images; libgc, yyjson (and libuv and
  picohttpparser from 7h) are git submodules pinned to a release tag,
  upgraded only by bumping the submodule in a reviewed PR; CI checks out
  with `submodules: true`. `agentica-vm --version` and the release notes
  list the libgc, yyjson, libuv, picohttpparser and OpenSSL versions (for
  OpenSSL, the one in use at run time); the release checklist says to
  rebuild and release after any High or Critical advisory for libgc,
  yyjson, libuv, picohttpparser or OpenSSL (or the other archives the
  static build links, such as zlib and zstd). For OpenSSL that means the release artifacts,
  which are built with `OPENSSL=static` (10.0); dynamic builds get OpenSSL
  fixes from the distro.

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
the platform's OpenSSL 3 development package, `libssl-dev` on Debian) to each
job; these jobs use the default dynamic build. One Linux job (or the release
workflow) also installs the `-dev` packages of libcrypto's
`Libs.private` (on trixie `zlib1g-dev` and `libzstd-dev`), builds
`OPENSSL=static OPENSSL_PREFIX=/usr`, checks `readelf -d` against the
`NEEDED` allowlist of 10.0, and runs the TLS tests. The
`test` job, after `make vm`, fails if
`objdump -T dist/agentica-vm | rg -o 'OPENSSL_3\.[0-9.]+' | rg -v '^OPENSSL_3\.0\.0$'` prints
anything. On macOS (paused),
Homebrew's keg-only `openssl@3` needs `PKG_CONFIG_PATH` set to its
`lib/pkgconfig`.

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
  formatting with `src/diagnostic.rkt`) and on `dist/agentica-vm` with
  `--json`, and compare exit code, stdout, the program's own stderr and
  the diagnostic code (black-box parity, 1). With `--json` the diagnostic
  is the last stderr line: it is parsed as JSON for the code and removed
  before stderr is compared. Each fixture also runs once on the VM in the
  plain and `--ai` formats: exit code and stdout must equal the full run's,
  stderr must start with the full run's program stderr, and the rest must
  name the same code (`error[CODE]` or an `[CODE]` line) or be empty when
  there is no diagnostic. Inputs: `examples/`, `tests/eval/tasks/*` reference
  solutions and hidden cases, and `tests/fixtures/vm/` with one program per
  runtime code and error span.
- Every program also runs on the VM under a sweep of `--max-steps`
  limits. The test finds each program's total step count T with the
  evaluator and sweeps every limit from 1 to T when T is at most 2000;
  above that (the call-depth program, about 60,000 steps) it sweeps 1 to
  300, 50 evenly spaced limits, T - 1 and T; then it adds the larger of
  2T + 100 and T + 4000 (two turns of `AGC_TURN_STEPS`, so a task fixture
  does not depend on when Racket first preempts a thread). For
  each limit the VM must either give the full run's outcome, or stop with
  exit 1 and `RUNTIME-STEP-LIMIT` with a stdout and stderr that are
  prefixes of the evaluator's full run. Once the VM finishes at one limit
  it must finish at every larger one, and it must finish at that last limit. The
  evaluator runs once per program, not once per limit. This allows other
  step counts and spans but catches a wrong code, extra output, and
  over-charging (not finishing by the last limit). It cannot catch an ignored
  limit, since these programs finish anyway: the runaway programs in
  `tests/fixtures/vm/step-limited/` do (`while true`, non-tail recursion,
  a self tail call, mutual tail calls, a `while true` whose body is only dead
  code, a `while` inside a `List.each` block, a loop inside a
  closure called through a function value, and the counting builtins).
  Each must stop with exit 1 and `RUNTIME-STEP-LIMIT` on both backends at
  every tested limit, their stdouts and program stderrs must be prefixes
  of one another, and neither may print what follows the loop. On Linux every
  VM run in the sweep and the runaway test has a 60-second timeout
  (`timeout --foreground -k 5 60` in the batch script, so the VM stays in
  the batch's process group; `#:timeout` in `run-process`), so a VM that
  ignores the limit fails with the fixture and limit named instead of
  hanging. After the first run in a batch that times out (status 124 or
  137) the script skips the rest and records them as 124 with empty
  output, so a hanging VM costs one timeout per fixture, not one per
  limit. The inputs are
  `tests/fixtures/vm/` only. This covers 2.1 and 4.4, so the IR needs no
  step test. `Random` fixtures print only what both backends share, since
  seeded sequences differ by design (7.4).
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
  enum chain and nested JSON array, printed and encoded
  (`vm/tests/json_test.c` parses and encodes depth-1,000,000 arrays and
  objects). A program's lists
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
- File programs (7h) are hermetic: a fixture whose `.args` holds `@tmp`
  gets a new empty directory under the shard's work directory for every
  run, evaluator and VM alike (directory names have the same length, so
  cut forms match), the argument is replaced by its path, the path is
  replaced back by `@tmp` in stdout and stderr before the comparison, and
  the directory is deleted afterwards. The fixtures use long timeouts, so
  a loaded machine does not turn a slow write into a timeout.
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
   - **6b** `String`, `List`, `Map`, `Float`, `Time`, `Random` (done; `Random` with
     its own seeded generator, 7.4). `List` and `Map` are done: plain C builtins (no native
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
     `Float`, `Time` and `Random` are done too
     (`vm/numbers.c`, its own builtin table): `Float.to_int` fails at
     the call with `RUNTIME-INVALID-NUMBER` (`cannot convert +nan.0 to
     Int`, `+inf.0`, `-inf.0`) or `RUNTIME-INTEGER-OVERFLOW`, as an error
     value without `!`; `Time.now_ms` is `timespec_get` and
     `monotonic_ms` `CLOCK_MONOTONIC` (`QueryPerformanceCounter` on
     Windows), both floored to milliseconds; `Random` is the VM's own
     xoshiro256** generator of 7.4, and `agentica --vm` passes `--seed`. Fixtures:
     `float-convert`, `float-to-int-*`, `time` (shape only),
     `random` (black-box) and `random-invalid-range`.
7. **JSON.** Parse, extract, encode, builders, typed decode, schema.
   The VM Json tree, with its big-integer node from §5, must follow the number rules of `docs/future.md` §15.2.
   Two PRs:
   - **Part 1** (done). `JSON.parse` over the yyjson reader (2.6, 10),
     the extractors (`get`, `at`, `string`, `int`, `float`, `bool`,
     `list`, `null?`), `JSON.encode` and the builders (`from`, `object`,
     `array`, `null`) in `vm/json.c`, the `Json` value (5.1) with its text
     and debug forms, and `Json` in `vm-type?`. No format bump.
     `vm/tests/json_test.c` checks the sign of zero,
     escapes, key order and dedupe on 5,000 keys, and depth-1,000,000
     arrays and objects parsed and encoded (and a list as deep through
     `JSON.from`; 100,000 under ASan, 1,000 under GC stress); the `json-*` fixtures cover round trips, every parse
     message, the number fixtures of future.md §15.2, the builders,
     extract errors, `RUNTIME-JSON-ENCODE` from `encode` and `from`,
     `RUNTIME-UNWRAP-ERROR` on a missing key, and a 1,024-deep array and
     object (kept small for the GC stress and sanitizer runs; the C test is
     the deep guard).
   - **Part 2** (done). `JSON.decode` and `JSON.schema` (2.7) in
     `vm/json_typed.c`, with the Types section and format version 3 (4.6)
     and its loader rules (8). The type argument lowers to the struct's
     linked name (3.3). Fixtures: `json-decode` (nested, recursive, list
     and map fields, imported structs, big integers to Float, a round
     trip), `json-decode-errors` (every error kind with its path, and the
     parse errors), `json-schema` (several structs, recursion through
     lists and maps, an imported struct beside a local one of the same
     name) and `json-decode-deep` (a 1,000-level recursive value and a
     path error at the bottom).

8. **7h part 1: event loop and files** (done, Linux). libuv v1.53.0 as a
   submodule built by the Makefile, the resource registry and the one-task
   loop of 10.2.2, and every `File`, `Dir` and `Path` builtin with
   `FileHandle` and `FileInfo` (2.8). `agentica-vm --version` names libuv.
   The `files-*` fixtures run each backend in its own temporary directory
   (an `.args` entry `@tmp`, 12.1), and `vm/tests/loop_test.c` checks the
   registry, a completed job, a timed-out job that is dropped later, and
   closing the loop. `examples/file-summary.agc` runs on the VM.

Phase 8a (ranges, done) added the `Range` value (5.1), `RANGE` and
`RANGE_BOUNDS` (4.2), the counter loops of 3.3, the `Range` builtins and
the counting native frames of 4.3, with loader rules (8) and the `ranges`,
`range-size-overflow`, `range-to-a-count` and `times-callback-error`
fixtures.

Outside this list, the **tail-call** PR (done) added `TAIL_CALL`: a
`return f(...)` of a user function reuses the frame (3.3, 4.2, 4.3, 6.1),
with loader rules (8), the `tail-calls` fixture, and a VM-only test of a
loop and a mutually recursive pair one million calls deep.

The **linked programs** PR (done) needed no new code: `compile` and
`--vm` already link through `src/modules.rkt`, and the Sources section
already held every file. It added the `linked` fixture (nested relative
imports, a `pkg/` module from `tests/fixtures/vm/agc_libs/`, imported
structs, enums and blocks, and `RUNTIME-INDEX-OUT-OF-RANGE` raised inside
`lib/stock.agc`), the `std-queue` fixture, the `same-basename` fixture
(`lib/a/m.agc` and `lib/b/m.agc` with blocks at the same line and column,
so two functions are named `block@m.agc:2:17`), `--vm` CLI runs of
`linked` in the three formats,
and loader asserts for spans in a second source. No format bump.

9. **7h tasks** (done, Linux). The split structures of 10.2.3 with N=1,
   the scheduler and turn costs of 10.2.1, `Task.spawn`, `await` and
   `sleep`, per-task `Random` (7.4), stdin and file jobs that park only
   their task (10.2.2), the `task-*` fixtures, and the latency test
   (`tests/vm-latency-test.rkt`, `make vm-latency`) with its
   `AGENTICA_VM_TEST_NO_TURN_COST=1` counter-check. No format bump: the
   Task builtins are new import keys only.

10. **7h processes** (done, Linux). Every `Process` builtin behind the VM's
    own `--allow-run`, which `agentica --vm` now passes through (10.4).
    External jobs complete from libuv callbacks (10.2.2). The harness runs
    fixtures named `process-*` with `--allow-run` on both sides; they spawn
    `/bin/sh` and `cat` (`process-streams`, `process-limits`,
    `process-timeouts`, `process-tasks`), and `spawn-denied` checks the
    error without the flag. A CLI test checks the `PATH` rule on both
    backends, and CI diffs `examples/process-tool.agc` on both. No format
    bump: the `Process` builtins are new import keys only.

7e is done when every example runs on the VM with the same results, except
those that need files, processes, tasks or the network by name:
`file-summary`, `process-tool`, `concurrency`, `tcp_echo`, `http_get` and
`http_server`.

## 13. Open questions

- **Random seeding**: resolved in PR 6b: the VM uses its own
  xoshiro256** generator, so seeded sequences differ from the evaluator
  by design (7.4).
- **Heap cap**: `--max-steps` does not bound memory (1), so a hostile or
  runaway file reaches the out-of-memory exit. Before 7i runs untrusted
  bytecode by default, decide on a cap such as `--max-heap N` through
  `GC_set_max_heap_size`, and whether the evaluator gets a matching limit for the one release it
  stays behind a flag. yyjson allocates its parse document with libc
  `malloc`, outside the GC heap, so such a cap must bound it too (for
  example with a counting `yyjson_alc` passed to `yyjson_read_opts`).
- **BDD on the VM**: decided; handlers move to the VM in 7h, and
  the evaluator is removed in 7i (roadmap).
