## 2. Reference behavior

The rules the VM follows. The goldens (§1, §12.1) pin the exit code, stdout,
program stderr and diagnostic code. Messages, spans and step counts may change
in a PR that rewrites the goldens. Code that is only a description of `vm/*.c`
is not repeated here; read the file.

### 2.1 Steps

- One step is charged when each statement starts and when each expression
  starts, before its children run.
- Not charged: `if` branches, `case` arms, patterns, map entries, named
  arguments, string parts of an interpolation, function entry, binding the `for`
  variable, and work inside builtins.
- A resolved method or field node (`s.to_s` on a String, `xs.size`) charges only
  its resolved node.
- A `while` condition is charged on every evaluation, including the last false
  one. A `for` over a list charges nothing per iteration (the list bounds it). A
  `for` over a range charges one step per iteration at the `for` span, before
  the body, so a huge range always reaches `--max-steps`.
- `Range.each`, `Int.times`, `Int.upto` and `Int.downto` charge one step at the
  call span before each callback. Callbacks of the `List` builtins charge only
  their bodies.
- Without `--max-steps` nothing is counted. With limit N the first N entries run
  and entry N+1 fails with `RUNTIME-STEP-LIMIT` at its span. All tasks share one
  counter. Limits above `INT64_MAX` are clamped.

### 2.2 Numbers

- Int arithmetic is checked against int64: overflow is
  `RUNTIME-INTEGER-OVERFLOW` at the operator span. `INT64_MIN / -1` overflows;
  `INT64_MIN % -1` is `0`.
- Int or Float division and modulo by zero fail at the operator span. For Float,
  a `0.0` or `-0.0` divisor fails; a NaN divisor does not.
- Float `+ - *` never fail: overflow gives infinities, `inf - inf` and
  `inf * 0.0` give NaN. Unary minus flips the sign bit, so NaN stays NaN.
- Ordering with NaN on either side is false for `< <= > >=`.
- Float literals are `digits.digits` only. The lexer converts them and the
  bytecode carries the IEEE bits, so the VM never parses literal text.
- `==` on numbers uses `=`: NaN differs from itself and `0.0 == -0.0`. A `case`
  literal uses `equal?`, so pattern `0.0` does not match `-0.0`.
- `-9223372036854775808` is legal: the literal 2^63 under unary minus is
  accepted (3.3).
- `Float.to_int` truncates and fails on NaN, infinity or a value outside Int.
- The `Int` bit builtins work on the 64-bit two's complement form. `shift_left`
  wraps, `shift_right` is arithmetic, `shift_right_unsigned` is logical, and a
  count of 64 or more shifts every bit out (`shift_right` gives 0 or -1). A
  negative count is `RUNTIME-INVALID-COUNT` at the count. `Float.to_bits` and
  `Float.to_bits32` give the IEEE 754 bits, with the canonical NaN
  (`0x7FF8000000000000`, `0x7FC00000`); `Float.from_bits32` outside
  `0 .. 4294967295` is `RUNTIME-INVALID-NUMBER`.
- `String.to_int` accepts `^[+-]?[0-9]+$` (ASCII digits only) and fails with an
  error value past 64 bits. `String.to_float` accepts
  `^[+-]?[0-9]+(\.[0-9]+)?$`. Text without a dot is an integer that is rounded,
  so `-0` gives `0.0` and `-0.0` gives `-0.0`; a huge integer text gives
  infinity, not an error. Conversion uses `strtod` in the "C" locale.
- Float text (`vm/value.c`, checked by `vm/tests/float_text_test.c`): take the
  shortest round-trip digits `d1...dn` and decimal exponent `e`. Use exponent
  form when `e < -4`, or when `e >= 0` and both `pos > 16` and `pos > sci`. Here
  `pos` is the positional length (`n + 1` with a fraction, else `e + 3` for
  `ddd.0`) and `sci` is `n + (n > 1 ? 1 : 0) + 2 + digits(e)`. Exponents print
  as `e+14` and `e-5`; one digit has no point (`1e+21`). Otherwise print
  positionally with at least one fractional digit (`100.0`, `0.0001`). Specials:
  `+nan.0` (any NaN), `+inf.0`, `-inf.0`, `-0.0`, `0.0`. Exact ties round up in
  magnitude, and at a power of two the neighbour above can win, so the shortest
  string is not always the nearest one.

### 2.3 Strings and text

- Strings are sequences of Unicode scalar values. `length`, `at`, `slice`,
  `index_of`, `reverse` and `split(s, "")` count code points.
- `String.trim` removes exactly space, `\t`, `\n`, `\f` and `\r`. NBSP, `\v` and
  U+3000 stay.
- `split(s, sep)` with a non-empty separator splits at every non-overlapping
  match and keeps empty parts, so joining the parts with `sep` gives `s`.
  `",,a,,"` gives `["", "", "a", "", ""]`. `split("", "")` gives `[]`;
  `split("", sep)` gives `[""]`.
- `replace` replaces every non-overlapping match. An empty `from` inserts at
  every position: `"abc"` gives `"xaxbxcx"`.
- `upcase` and `downcase` are full Unicode mappings (`"straße"` gives
  `"STRASSE"`). Final sigma: `Σ` becomes `ς` only after a cased letter and not
  before one (`ΑΣ` gives `ας`, `ΣΣ` gives `σς`). The mapping tables and the
  write-escape tables are generated from Racket's Unicode data by
  `vm/tools/gen-unicode.rkt` into `vm/unicode_data.c`. `make vm-unicode`
  regenerates it, and the Linux CI job fails when the committed file is stale.
- Debug form of a String: the escapes `\"`, `\\`, `\a \b \t \n \v \f \r \e`; a
  character that is not printed raw becomes `\uXXXX` or `\UXXXXXXXX` (uppercase
  hex). A joiner (U+200C, U+200D, U+E0020 to U+E007F) prints raw only after a
  raw, non-blank character, so family emoji and flag sequences print raw. The
  generator checks `agc_write_form` against Racket's `write` for every code
  point and for joiner contexts.
- Stdin is decoded per byte: each byte that does not start a complete valid
  UTF-8 sequence becomes one U+FFFD (`E2 82 63` gives two U+FFFD then `c`).
  `IO.gets` ends lines at LF, CR or CRLF. A read decodes only the bytes it
  consumes, so `read_bytes` after `gets` starts right after the line terminator.
- `System.args` on Linux and macOS is UTF-8 with one `?` per invalid byte, as
  glibc `iconv` gives. Non-UTF-8 locales are outside the contract, and so are
  Windows console code pages.
- `String.code` needs exactly one code point and `String.from_code` a Unicode
  scalar value, else `RUNTIME-INVALID-CHARACTER` at the argument span (the
  receiver for `s.code`). `at` fails with `RUNTIME-INDEX-OUT-OF-RANGE` at the
  index span, and `slice` at the call span.
- `to_int!` fails with `RUNTIME-INVALID-NUMBER` or `RUNTIME-INTEGER-OVERFLOW`,
  `to_float!` with `RUNTIME-INVALID-NUMBER`, both at the call span. The `Result`
  forms return the same text as an `error(...)` value.
- `String.from_bytes` checks that every item is 0 to 255, then decodes strictly:
  no surrogates, no overlong forms, no code points above U+10FFFF.

### 2.4 Printing values

- Text form: a String as is, a `Json` as its JSON text, anything else in debug
  form. A list prints in debug form even in text form: `puts(["a"])` prints
  `["a"]`.
- Debug form: `nil`, `true`, Int, Float (2.2), String (2.3), `[a, b]`, `{k: v}`
  in insertion order, `Name(f: v, ...)` in declaration order, `Enum.Variant` or
  `Enum.Variant(a, b)`, `ok(v)`, `ok()` for Void, `error("msg")`, and `<Json>`,
  `<Fn>`, `<Task>`, `<Socket>`, `<Listener>`, `<HttpClient>`, `<FileHandle>`,
  `<Process>`.
- Struct and enum names are the declared display names: an imported `Point`
  prints `Point(x: 1)`, not the linker's internal `@2::` identity. The VM never
  looks a type up by its display name.
- A struct with no fields prints `Name()`. A nullary variant prints
  `Enum.Variant` with no parentheses, even when written `Enum.Variant()`.
- JSON text: object keys sorted, short escapes (`\n`), lowercase `\u007f` for
  DEL, non-ASCII raw, floats per 2.2, a big integer as its decimal text.
  `JSON.encode` of a non-Json value keeps struct declaration order and map
  insertion order; only a `Json` inside is sorted. `JSON.from`, `JSON.object`
  and `JSON.array` build a `Json`, so their text is sorted. A non-finite Float
  in either is `RUNTIME-JSON-ENCODE` at the call span.

### 2.5 Diagnostics, streams and exit codes

- A runtime diagnostic carries a code, a message and a span. Only the code is
  contract.
- Plain format: the diagnostic as usual. `--ai` prints `check failed: 1 error`,
  a blank line, `[CODE]`, `  message: `, `  at: file:line:column` and
  `  source: ` with the source line trimmed of space, `\t`, `\n`, `\f` and `\r`
  at both ends. `--json` prints one line with keys in this order: `code`,
  `file`, `message`, `range`.
- Columns count characters. Source lines split on LF with a trailing CR removed.
  Source names and lines print as raw bytes, control characters included.
- Order: flush stdout, write the diagnostic to stderr, exit 1. How the two
  streams interleave at buffer boundaries is not contract.
- Before each blocking stdin read, stdout is flushed when it is a terminal, so
  prompts show up.
- SIGPIPE is ignored. Every `fwrite` and `fflush` result is checked; a failed
  write ends the run with `RUNTIME-INTERNAL`, exit 1.
- `RUNTIME-INTERNAL` is at the program span. Its message is not contract.
- Normal end exits 0. `System.exit(n)` exits with `n` when `1 <= n <= 255`, else
  with 0.

### 2.6 JSON parsing

- A raw character below U+0020 inside a string is an error. DEL passes.
- Any other syntax error, including a lone `\u` surrogate, is an error. A
  surrogate pair decodes to one character.
- Empty input is an error. Anything after the value other than space, tab, CR or
  LF is an error. A number that is not finite is an error. Checks run in this
  order: control characters over the whole text, syntax, trailing content,
  finite check. So `1e400 x` fails as trailing content.
- All parse errors have the `JSON.parse: ` prefix.
- Top level: a number ends at the first byte its grammar does not take, so `01`
  is `0` followed by trailing content and `[01]` is invalid. A literal followed
  by `[A-Za-z0-9_]` (`truex`) is invalid; `true-` is trailing content.
- A number with a fraction or an exponent is a Float (`1e2` is `100.0`); other
  numbers are integers of any size.
- A Float is the exact decimal rounded to nearest, ties to even. A mantissa of
  only zeros gives `0.0` (so `-0.0` and `-0e5` are `0.0`). A non-zero negative
  value that rounds to zero is `-0.0`. `-0` is the integer 0.
- A repeated object key keeps the last value. Objects are sorted by key bytes
  with a stable sort.
- The VM reads top-level strings, arrays and objects with the yyjson reader (10)
  and copies the tree into `Json` nodes. Numbers reach the VM as text. Check
  `strtod` on macOS and Windows when those platforms build again.

### 2.7 Typed JSON

- `JSON.decode(s, T)` parses `s` like `JSON.parse`, then walks `T` in field
  order and stops at the first problem. Every field is required. Extra keys are
  ignored. A decoded map is built in sorted key order.
- Errors are values `"<path>: expected <what>"`. The path is `$` at the root,
  `a.b` for fields, `a[3]` for list items and `a["k"]` for map keys. `<what>` is
  `object`, `array`, `required field`, `signed 64-bit Int` (a JSON float or an
  integer outside int64), `finite Float` (a big integer that rounds to infinity
  fails), `Bool` or `String`.
- `JSON.schema(T)` is `{type, properties, required}` for `T`, plus `$defs` when
  the fields reach any struct. Each struct reached is in `$defs` once under its
  linked name (`@2::Point` for an imported one). A struct field is
  `{"$ref": "#/$defs/<name>"}`, with `~` written `~0` and `/` written `~1`. Int
  is `{"type": "integer", "minimum": -2^63, "maximum": 2^63-1}`.
- The VM walks the JSON tree and the type table with an explicit stack and
  builds the error path only on failure. Schema marks the reachable types and
  structs with a queue. Neither recurses, so recursive structs and deep values
  are safe.

### 2.8 Files and paths

Every failure is an error value. The checks run in this order:

- Argument checks: text above 1 MiB; `File.write_bytes` bytes must be 0 to 255
  and at most 1 MiB per call; `File.read_bytes` `max_bytes` must be 1 to 1 MiB;
  the timeout must be positive.
- The mode, then the handle state: a closed handle, or a handle that is not
  readable or writable, fails. `File.close` of a closed handle does no I/O.
- A path must be a nonempty String without NUL. A relative path is completed
  with the current directory, read once at startup, and runs of `/` collapse.
- Output is buffered, 4096 bytes per handle. A write whose bytes fit with what
  is pending (pending + n <= 4096) only goes into the buffer. Otherwise pending
  and new bytes are written together. `File.flush` and `File.close` write the
  buffer, and the end of the run writes handles left open. A write error shows
  at the call that writes the buffer. A handle closed by a timeout drops its
  buffer.
- Kinds follow `stat` (symlinks followed): a directory is `directory`, anything
  else `file`. Reads need an existing path that is not a directory; a FIFO, pipe
  or device that can wait is read on the loop (10.2.2). Writes refuse a
  directory and create a missing file.
- `File.read_text` refuses a file above 1 MiB by its size and decodes strictly.
  `File.read_line` strips LF or CRLF and fails after 1 MiB without a LF.
  `File.read_bytes` reads until `max_bytes` or EOF.
- `File.stat` of a missing path gives an error without a kind. A directory's
  size is 0. `modified_seconds` is the modification time in seconds.
- `Dir.list` drops `.` and `..`, decodes names with U+FFFD and sorts them by
  code point. `Dir.mkdir` creates missing parents with mode 0777; an existing
  directory or file is not an error.
- `Path.join` checks every part, then refuses an absolute later part.
  `Path.resolve` completes the path, drops `.`, pops `..` (never above `/`) and
  collapses `/`. The result ends in `/` when the input did, or ended in `.` or
  `..`.
- After a timeout on an active handle operation the handle is closed: later
  operations fail with "file handle is closed", and `File.close` gives `ok()`.
- A timed-out read on a FIFO or device ends at the timeout (10.2.2).
  `File.read_text` of a pipe reads to end of file.
- `File.each_line` accepts a line of at most `buffer_bytes` bytes counting its
  terminator, and a last line without a terminator of exactly `buffer_bytes`
  bytes. It checks the buffer range first (`RUNTIME-INVALID-COUNT` at the
  argument), then the timeout, then the path.
