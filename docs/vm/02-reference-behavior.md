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

