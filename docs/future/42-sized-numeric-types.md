## 42. Sized numeric types

**Status:** designed, not scheduled. The owner's scope of 2026-10-14 is in this
section. It is implemented in the Agentica front end (`compiler/`) and the VM,
so it is a checker change and not VM-only. Every name and every choice is a
proposal for the owner to review. Each open choice has a recommendation and one
line of reasoning, and the rejected options are named.

Agentica has one integer type, `Int` (signed 64-bit), and one float type,
`Float` (IEEE binary64). This section adds fixed-width integer types (`Int8`,
`Int16`, `Int32`, `UInt8`, `UInt16`, `UInt32`, `UInt64`) and `Float32`, with the
rules that keep them safe for agents to write.

### 42.1 Decisions at a glance

Each choice is argued in the section named; the recommendation is the text
there.

- Types: `Int8`, `Int16`, `Int32`, `UInt8`, `UInt16`, `UInt32`, `UInt64`,
  `Float32`; `Int64` and `Float64` are aliases; `Int` and `Float` stay the
  default spellings; no `Byte`, no `Bytes` (42.4, 42.10). Float16 and BFloat16
  later (42.9).
- Literals: typed by context, `Int` or `Float` with none; no suffixes; no hex
  yet; out of range is `CHECK-INT-RANGE`, and `CHECK-FLOAT-RANGE` is new (42.5).
- Conversions: plain value when it cannot fail, `Result` when it can, `!`
  halts, `wrap_` wraps (42.6).
- Arithmetic: same type only (`CHECK-TYPE-MISMATCH`, no implicit widening);
  overflow halts at each width in both directions (`RUNTIME-INTEGER-OVERFLOW`);
  `wrapping_add`, `wrapping_sub`, `wrapping_mul` on every integer type; the
  seven `Int` bit names read at each width (42.7).
- `UInt64` prints unsigned, and JSON decoding reads the stored text (42.8).
- Map keys: every integer type, no floats; `Range`: `Int` only (42.10).
- JSON: sized struct fields, with bounds in the schema (42.10).
- `std/binary` moves to the sized types in step 3 (breaking, 42.10).
- VM: one new tag per kind; the `Int` opcodes stay; one `FIT` opcode after
  64-bit ops; unsigned ops for `UInt64`; `ROUND_F32` (42.11).
- Storage: `agc_value` items in steps 1 to 3; typed storage in step 4, if
  measured (42.12).
- Phasing: 1 integers, 2 Float32, 3 binary API, 4 storage (gated) (42.13).
- `Int` and `Float` are 64 bits on every target (42.4, 42.16).

### 42.2 Today

- `Int` is signed 64-bit. Overflow in `+`, `-`, `*`, unary `-` and `MIN / -1`
  halts with `RUNTIME-INTEGER-OVERFLOW` (`docs/grammar/06-semantics.md`).
- `Float` is IEEE binary64. A float literal is digits, a `.` and digits, with no
  exponent (`docs/grammar/04-lexical.md`). A float literal of 401 digits checks.
  The value it runs with is not checked here, so §42.5 settles the range.
- Integer literals take `_` separators. `0xFF`, `200u8` and `1e3` are
  `PARSE-UNEXPECTED-TOKEN`.
- An integer literal above the 64-bit range is `CHECK-INT-RANGE`.
  `-9223372036854775808` checks, so the smallest `Int` needs no special form.
- There is no implicit numeric conversion. `2 * 1.5`, `1 == 1.0`, `x: Float =
  1`, `[1.0, 2]` and a `Range` of Floats are all `CHECK-TYPE-MISMATCH`.
- A `Map` key that is not an integer or string type is `CHECK-MAP-KEY-TYPE`
  (`Map[Float, Int]`).
- The checker's method aliases map `s.to_i` to `String.to_int`, `n.to_f` to
  `Float.from_int`, `n.to_s` to `String.from_int` and `x.to_i!` to
  `Float.to_int!`.
- `check_binary` checks both operands with no expected type. Literal typing
  from the other operand needs a change there.
- A `List[Int]` item takes 8 bytes (unboxed leaves, `docs/vm/17-lists.md`
  §17.12), and an item of any other list is an `agc_value`, which is 16 bytes
  (`vm/value.h`). So a byte in a `List[Int]` costs 8 bytes, not one.
- The VM picks typed opcodes from static types: `AGC_OP_ADD_I` and
  `AGC_OP_ADD_F` are separate opcodes. The checker's types reach lowering.
- The `.agcb` type table has the kinds `INT`, `FLOAT`, `BOOL`, `STRING`, `LIST`,
  `MAP` and `STRUCT` (`AGC_TYPE_*` in `vm/value.h`). The loader rejects an
  unknown kind (`load_types` in `vm/loader.c`). Typed JSON uses these kinds
  (`vm/json_typed.c`).
- A JSON integer beyond `Int` is kept as its text until it is extracted
  (`AGC_JSON_BIG`). `JSON.int` extracts `Int` only.
- Float text is `agc_float_text` (`vm/value.c`). It tries 15 to 17 digits
  and keeps the first that reads back to the same double, then strips trailing
  zeros. JSON encoding uses it too.
- A user `struct Int8` checks. So reserving the new names is a breaking change
  (§42.15).
- Equality and map keys test the tag (`vm/equal.c`, `vm/map.c`), as do other
  generic paths (42.11).

### 42.3 Motivation, and what it costs

The reasons, in the order of their weight:

- **Memory.** A byte in `List[Int]` costs 8 bytes. A type alone does not fix
  that: a `List[UInt8]` stored as 64-bit numbers costs 8 bytes per item too.
  The memory gain needs typed storage that uses the element width (1 byte for
  `UInt8`, §42.12). The types are the input that storage needs.
- **Binary protocols and files.** `std/binary` reads and writes numbers as
  `Int`, so the width is only a convention in the function name, and
  `write_u16_be` checks the range at run time (`value 70000 does not fit in
  u16`). With `UInt16` the range is in the type, and the writer takes the type.
- **A future FFI (§40).** C has `int32_t`, `uint8_t` and `float`. A native
  function needs those widths in its signature, and §40 lists the types that
  need conversions first.
- **Interop.** CBOR's integer major types cover -2^64 to 2^64 - 1
  (`docs/future/16-cbor.md` maps `Int` only). Other systems use `uint64` IDs
  and 32-bit floats in their data.
- **Wrap-around math.** Hashes and checksums need arithmetic that wraps.
  `std/binary` covers the bits with the `Int` shift builtins, but `+` and `*`
  halt on overflow, so a 64-bit multiply in a hash (FNV-1a, for example) can
  only be written today by hand with bit operations.

The cost is real. Every conversion is one more thing an agent must write, and
Agentica is meant to be easy for agents. The project measures agent success in
its evaluation rounds (`docs/eval.md`). The design limits the cost in four ways.
Literals stay plain (§42.5). Conversions are explicit, as they are today with
`to_f` and `to_i!` (§42.6). The rule for conversions is one rule (§42.6). And
the evaluation rounds measure the binary tasks again after step 3 (§42.13).

Other languages, by their own rules:

- Go: int8 to int64, uint8 to uint64; no implicit conversion; wraps silently;
  the wrap is the rule.
- Rust: i8 to i128, u8 to u128; no implicit conversion (`as` casts); panics in
  debug, wraps in release; `wrapping_*`, `checked_*`, `saturating_*`;
  `try_from` returns a Result.
- Swift: Int8 to Int64, UInt8 to UInt64; no implicit conversion; traps; `&+`,
  `&-`, `&*`; `init(exactly:)` returns an optional.
- Zig: any width; safe widening only; illegal behavior, checked in safe builds;
  `+%`, `+|`; `@intCast` is checked.
- Kotlin: Byte to Long and unsigned types; no implicit conversion; wraps
  silently; no modular ops in the core.
- C#: sbyte to ulong; widening only; unchecked unless in `checked`.
- Python, Ruby: one arbitrary-precision `int`; never overflows.

The pattern: the languages that avoid silent wrong results halt on overflow
(Rust in debug, Swift, Zig in safe builds), and they name the wrap operations
(`wrapping_`, `&+`, `+%`). Most of them convert explicitly. Agentica follows
that pattern and keeps the existing rule of §6 that there is no implicit
conversion.

### 42.4 Names and aliases

- **Names.** `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`,
  `UInt64`, `Float32` and `Float64`. Reason: the Swift spelling (`UInt8`)
  follows the rule that type names start with an uppercase letter, and it is the
  names the owner listed.
- **`Int64` is an alias of `Int`, and `Float64` is an alias of `Float`.** They
  are the same type, not a second one. Reason: `String.length`, `Random.int`,
  `JSON.int` and every other builtin return `Int`, and a second 64-bit type
  would make each of them a conversion. Messages print the canonical `Int` and
  `Float`. The alias holds only while `Int` is 64 bits on every target (§42.1,
  §42.16).
- **`Int` and `Float` stay the default spellings** in the cheat sheet, the
  examples and the builtin signatures. Reason: agents learn one name for the
  common case, and the new names are for the cases that need a width.
- **No `Byte`.** `UInt8` is the byte type. Reason: a `Byte` alias would be a
  second name for one type, and it reads like `Bytes` (§12.5).
- **Reserved names.** The new names are reserved, as the builtin records of
  §41.2 are, and a user `struct`, `enum`, type parameter or import alias with
  one of them is `CHECK-REDEFINED-NAME`. Reason: otherwise `Int8(...)` could
  mean two things. A user `struct Int8` checks today, so this is breaking
  (§42.15). There is no migration path: the language has no external users.

### 42.5 Literals

- **Context types a literal (recommended).** An integer or float literal takes
  the sized type that its context expects: an annotation, a parameter, a struct
  field, a return type, a list or map element, a `case` pattern (the scrutinee's
  type), or the other operand of an arithmetic or comparison operator. With no
  such context it is `Int`, or `Float` for a decimal literal. Reason: `x: UInt8
  = 200`, `b + 1` and `Binary.write_u16_be(513)` read as they do today, and
  agents write literals more than anything else. Rust and Swift do this, and Go
  does it with untyped constants.
- **Consequences.** `x = 200` is `Int`, since there is no context; annotate it
  to get `UInt8`. `[1, 2]` with no context stays `List[Int]`. `1_000` follows
  the same rule, since its `_` is only visual. For `b + 1`, the checker checks
  `b` first and then checks the literal with `b`'s type as the expected type
  (`check_binary`).
- **Operators, calls and sign (recommended; open owner question, §42.17).** A
  literal expression is an arithmetic tree of only literals, such as `1 + 2` or
  `(1 + 2) * 3`, and it is typed like a literal. A literal, or a literal
  expression, on either side of an operator takes the type of the other operand:
  the checker checks the operand that is not a literal expression first, then
  types the literal side with its type, so `2 * b`, `0 < b` and `b + (1 + 2)`
  work as `b + 1` does. For an arithmetic operator (`+`, `-`, `*`, `/`, `%`)
  with two literal expressions, the expected type of the whole expression flows
  into both operands: `x: UInt8 = 1 + 2` types `1` and `2` as `UInt8`. A
  comparison gives `Bool`, so its expected type does not flow into its operands:
  `x: Bool = 1 < 2` types `1` and `2` as `Int`. In a call with a type variable,
  the argument that fixes the variable types the literal arguments:
  `List.append(bytes, 1)` types `1` as `UInt8` when `bytes` is a `List[UInt8]`.
  A unary `-` before an integer literal folds into the literal, so `-5` is one
  literal with the value -5: `x: UInt8 = -5` is `CHECK-INT-RANGE` at the
  literal's span, and `x: Int8 = -128` is in range. Folding also keeps
  `-9223372036854775808` a valid `Int` literal (42.2), since
  `9223372036854775808` alone is out of range. Reason: without folding, `-128`
  could not be an `Int8`. The unary minus of a variable stays
  `CHECK-TYPE-MISMATCH` (42.7).
- **No suffixes (recommended).** `200u8` and `1.5f32` are not written. Reason:
  context covers every case a suffix would, a suffix is a second spelling, and
  the lexer rejects `200u8` today.
- **No hex, octal or binary literals in this design.** Reason: they are a
  grammar change with their own review, and the `_` rules in the grammar would
  have to cover hex digits. Masks stay in decimal. Hex is the one literal
  form that binary code would want, so it is the first candidate for a separate
  proposal (§42.16).
- **Out of range (recommended).** An integer literal outside its type is
  `CHECK-INT-RANGE`, at the literal's span, with a message that names the type
  and its range: `200 is outside UInt8, 0 to 255`. A negative literal for an
  unsigned type is the same code. Reason: the code exists, and it means the same
  thing as it does for `Int`.
- **Float literals and range (new code `CHECK-FLOAT-RANGE`).** A float literal
  that rounds to infinity in its type is `CHECK-FLOAT-RANGE`. This applies to
  `Float` too, which today accepts a 401-digit literal. Reason: an infinity from
  a literal is a silent bug, and the same rule must hold for `Float32`. The
  exact boundary of `Float32` (its largest finite value is
  3.4028234663852886e38) goes into the test vectors.
- **Rounding a `Float32` literal (recommended).** The literal is stored as its
  decimal text, and the VM rounds it to binary32 once, when the program loads,
  with a correctly rounded `strtof`. Reason: the Agentica front end cannot round
  decimal text exactly, and rounding through binary64 first can give the wrong
  binary32 in a tie (the same reason as §42.9). The text is a new constant kind
  of `.agcb` (§42.11). The implementation PR tests `strtof` against exact
  rounding on every release target, the Windows UCRT included.
- **No integer literal becomes a `Float`.** `x: Float = 1` stays
  `CHECK-TYPE-MISMATCH`. Reason: that is today's rule (§6); contextual typing
  applies to sized integers and to float literals, not to the change of kind.

### 42.6 Conversions

- **One rule (recommended).** A conversion returns the plain value when it
  cannot fail: every source value fits the target, or it only rounds. It returns
  a `Result` when some source value does not fit. Reason: `std/binary` already
  does this for the writers (`i64`, `f32` and `f64` return plain lists, the
  others a Result), so the rule is not new, and the type tells the agent which
  form it has. `try` on a plain value is a check error.
- **Names (recommended).** A conversion is a method on the source, named `to_`
  followed by the lowercased target: `to_int`, `to_int8`, `to_int16`,
  `to_int32`, `to_uint8`, `to_uint16`, `to_uint32`, `to_uint64`, `to_float`,
  `to_float32`. The bang form `to_uint8!` halts. The wrap form is `wrap_uint8`,
  which keeps the low bits of the two's complement value and never fails.
  Reason: the full names match the type names, and short names (`u8`, `i32`)
  would be a second vocabulary to learn. The existing `to_i` and `to_f` are the
  short forms for `String` and `Float`, and they stay. The owner's examples
  (`to_u8`, `wrap_u8`) keep the same forms with other names.
- **Which are plain** (recommended):

- **Conversion:** Int8, Int16, Int32, UInt8, UInt16, UInt32 to Int
  - **Form:** plain

- **Conversion:** UInt64 to Int
  - **Form:** Result (values above 2^63 - 1 exist)

- **Conversion:** Int to Int8, Int16, Int32, UInt8, UInt16, UInt32, UInt64
  - **Form:** Result; `!` halts; `wrap_` wraps

- **Conversion:** A lossless widening between sized types (for example UInt8 to
  UInt16, Int8 to Int32)
  - **Form:** plain method on the source (`x.to_uint16`)

- **Conversion:** Any integer to Float, through `to_float`
  - **Form:** plain (rounds to nearest)

- **Conversion:** Any integer to Float32, through `to_float32`
  - **Form:** plain (rounds once, from the 64-bit integer, to nearest, ties to
    even; §42.9)

- **Conversion:** Float32 to Float
  - **Form:** plain (exact)

- **Conversion:** Float to any integer type
  - **Form:** Result; `!` halts; no wrap form

- **Conversion:** Float to Float32
  - **Form:** plain (rounds; overflow gives an infinity of the same sign, as
    `Float.to_bits32` does)

- **Sized to sized (recommended).** A lossless widening is a plain method on the
  source (`x.to_uint16`, 12 pairs). Every other conversion between sized
  types goes through `Int`: `x.to_int.to_uint8`, where the first step is plain
  or a Result and the second is a Result. Reason: direct methods between every
  pair would be 8 sources times 7 targets times 3 forms, 168 catalog rows,
  against about 60 with the `Int` hub, and the widenings are the only pairs that
  are plain.
- **Float to integer.** The bang and Result forms follow `Float.to_int` and
  `Float.to_int!`: truncation toward zero, NaN and infinity give
  `RUNTIME-INVALID-NUMBER`, and a value out of range gives
  `RUNTIME-INTEGER-OVERFLOW`. Reason: the same codes for the same meaning. There
  is no wrap form for floats, since a wrapped float has no clear meaning.
- **Text parsers (step 1: none for sized types).** A program parses with
  `String.to_int` and then converts: `try s.to_int` and `.to_uint8`. Reason:
  that covers the 8, 16 and 32 bit types. `String.to_int` stops at the `Int`
  maximum, so `UInt64` text needs its own parser with a clear rule, which is
  later (§42.16).
- **Saturating forms: later.** Reason: clamping is a short `if` in the program,
  and the API should stay small until an evaluation round shows the need.
- **Errors.** The `!` forms use `RUNTIME-INTEGER-OVERFLOW` for a value out of
  range, the code `Range.size` and `Float.to_int!` already use. No new code is
  added for this.

### 42.7 Arithmetic, comparison and bit operations

- **Same type only (recommended).** `+`, `-`, `*`, `/`, `%` and the comparisons
  take two values of one type. Mixing two types is `CHECK-TYPE-MISMATCH`, with a
  help that names the conversion. Reason: §6's rule is unchanged, and an agent
  learns one rule for all numbers.
- **Halt on overflow at each width (recommended).** A result outside the type's
  range halts with `RUNTIME-INTEGER-OVERFLOW` and a message that names the
  range: `result 256 is above UInt8's maximum 255`. This holds in both
  directions, so `UInt8` `3 - 5` is an error and not a wrap. Reason: `Int` halts
  today, the same code means the same thing, and wrapping is available by name
  (below).
- **How the check is done.** The VM computes the result in 64 bits and then
  checks that it is in range for the type (§42.11). This is exact for every
  width. For `UInt32` the 64-bit signed product can overflow when it is above
  2^63, but such a product is above `UInt32`'s maximum anyway, so the code and
  the outcome are the same.
- **Modular math (recommended).** `wrapping_add`, `wrapping_sub` and
  `wrapping_mul` are methods on every integer type, including `Int`. Each
  returns the type and keeps the low bits of the two's complement result.
  Reason: hashes and checksums need them, the names say what happens, and
  `Int.shift_left` already wraps.
- **Checked methods: later.** `checked_add` and the like, returning a Result.
  Reason: the operators already halt, and a program that must recover from
  overflow can use `try` on a conversion first. This can be added when a program
  needs it.
- **Division and remainder.** `/` truncates toward zero, and `%` takes the sign
  of the dividend, as they do for `Int`. A zero divisor is
  `RUNTIME-DIVISION-BY-ZERO`. For a signed type, `MIN / -1` halts with
  `RUNTIME-INTEGER-OVERFLOW`; for `Int8`, `-128 / -1` is 128, which is out of
  range and is caught by the same range check.
- **Unary minus is for signed types only (recommended).** `-x` on an unsigned
  value is `CHECK-TYPE-MISMATCH`, with the help: unsigned values have no minus;
  use `0 - x`, which halts below zero. Reason: a silent wrap of `-x` is the
  mistake this design is meant to prevent.
- **Comparisons.** Ordering and equality work within one type. Float32 follows
  IEEE, as Float does: NaN is not equal to itself. `UInt64` comparisons use
  unsigned operations in the VM (§42.11).
- **Bit operations (recommended).** `bit_and`, `bit_or`, `bit_xor`, `bit_not`,
  `shift_left`, `shift_right` and `shift_right_unsigned` are methods on every
  integer type, with the `Int` bit rules read at the type's width: the result is
  the low `w` bits, read back in the type. Specifically: `bit_not` on an
  unsigned type flips the bits within its width, so `UInt8.bit_not(0)` is 255,
  while on a signed type it is `-1 - a` as on `Int`. `shift_left` drops the bits
  that leave the width, and a count of the width or more gives 0. `shift_right`
  copies the sign bit on a signed type and is logical on an unsigned type, which
  has no sign bit. `shift_right_unsigned` is logical on every type. A negative
  count is `RUNTIME-INVALID-COUNT`. Reason: one meaning per name, at every
  width, and one rule to learn. The `Int` bit methods do not change.

### 42.8 UInt64 above the `Int` maximum

- **Representation.** A `UInt64` value is stored as its 64-bit pattern, and the
  VM reads it as unsigned. A value above 2^63 - 1 is not an `Int`, and it never
  becomes one by accident, because the types differ.
- **Printing.** `to_s`, interpolation and `inspect` print the unsigned decimal,
  so the largest value prints `18446744073709551615`. Reason: printing a
  negative number for a `UInt64` would be a silent wrong answer.
- **Arithmetic.** `+` and `*` check unsigned overflow, `-` halts below zero, and
  `/`, `%` and the comparisons are unsigned.
- **Conversions.** `to_int` is a Result for `UInt64` (§42.6). `to_uint64` from
  an `Int` is a Result, and a negative value is an error. `to_float` rounds to
  nearest.
- **JSON encoding.** Writes the unsigned decimal.
- **JSON decoding.** A `UInt64` field reads the integer's text, which the JSON
  parser already keeps for an integer beyond `Int` (`AGC_JSON_BIG`), and checks
  the range. So `18446744073709551615` decodes, and `18446744073709551616` is an
  error with its path. Reason: the text is already there, so no second number
  parser is needed. JavaScript readers lose precision above 2^53, which is a
  note for interop and not a reason to change the type.
- **JSON schema.** `minimum` and `maximum` for each type. The `UInt64` maximum
  is 18446744073709551615.
- **`JSON.int` and `JSON.kind`.** `JSON.int` stays `Int` only. A sized extractor
  such as `JSON.uint64` is later (§42.16). §15 plans `JsonBigInt(String)` for a
  value beyond `Int`, as its text.
- **CBOR.** A `UInt64` is CBOR major type 0 with the full 64-bit value. §16 maps
  `Int` only today, so it gains one row per type when CBOR lands. This design
  does not change §16.
- **Hashes.** Use `wrapping_mul` and the bit methods on `UInt64` directly. They
  do not need a round trip through `Int`.

### 42.9 Float32

- **Arithmetic (recommended).** Each operation runs in binary64 and rounds once
  to binary32. For `+`, `-`, `*`, `/` and `sqrt`, that gives the correctly
  rounded binary32 result, because binary64 has at least 2p + 2 bits where p =
  24 is the precision of binary32 (53 is at least 50). This is Figueroa's result
  on double rounding (1995). The condition is stated for normal results, so the
  implementation PR tests subnormal results against exact rational rounding.
  Each `Float32` value is stored as a double that holds a binary32 value, and a
  new opcode `ROUND_F32` rounds the result after each float operation (§42.11).
  Reason: one routine rounds all operations, and no separate float32 arithmetic
  is needed in C.
- **Overflow.** A result above the `Float32` range is an infinity, not an error,
  as `Float` is today (`big * big`). Division by zero is
  `RUNTIME-DIVISION-BY-ZERO`, as it is for `Float`
  (`docs/grammar/06-semantics.md`).
- **NaN.** Canonical NaN in `to_bits`: every NaN gives `0x7FC00000`
  (2143289344), the same rule as `Float.to_bits32`. Reason: every
  platform gives the same bits.
- **Printing (recommended).** `to_s` prints the shortest decimal that reads back
  to the same binary32 value. The Float32 nearest 0.1 prints `0.1`, not
  `0.10000000149011612`. `agc_float_text` cannot be reused unchanged: it starts
  at 15 digits, which is right for doubles, because every decimal of 15 digits
  or fewer reads back through a double. For binary32 the new routine starts at 1
  digit, stops at 9, and checks each candidate by rounding it to binary32.
  Reason: that is the shortest form, and it is what a reader expects. An
  infinity or NaN prints as `Float` does: `+inf.0`, `-inf.0` or `+nan.0`.
- **Conversion from `Int` (recommended).** An integer is rounded to binary32
  once, from its 64-bit value: C converts the `int64_t` straight to `float`, not
  through a `double`. A `UInt64` converts the same way, with
  `(float)(uint64_t)`. Through a `double` the result can be wrong.
  `9007199791611905` (2^53 + 2^29 + 1) rounds to 9007200328482816 (2^53 + 2^30),
  and through a `double` to 9007199254740992 (2^53). `2^60 + 2^36 + 1` rounds to
  1152921642045800448 (2^60 + 2^37), and through a `double` to
  1152921504606846976 (2^60). These are exact integers, not printed text,
  because a `Float32` prints its short form (Printing, above). The vectors of
  step 2 test both.
- **JSON (recommended).** Encoding uses the same shortest text. Decoding uses a
  correctly rounded `strtof` (glibc's rounds the decimal once), not `strtod`
  followed by a cast, because the cast rounds a second time. Reason: the double
  rounding gives the wrong binary32 in rare ties. The vectors of step 2 test it.
- **Bits.** `Float32.to_bits(x) -> UInt32` and `Float32.from_bits(bits: UInt32)
  -> Float32` are added in step 2, and the existing `Float.to_bits32` and
  `Float.from_bits32` (which use `Int`) are removed in step 3 (§42.15). Reason:
  the 32-bit pattern gets one type, and the removal waits until the binary API
  moves.
- **Open: `Float.to_bits` return type.** It returns `Int` today, signed, and a
  negative `Int` for a sign bit. A `UInt64` return would make the bit
  pattern unsigned. This is in §42.17 for the owner to decide.
- **Float16 and BFloat16: later.** Reason: no program needs them yet. Their main
  use is machine learning, which waits for the SIMD work of §19. Each needs its
  own rounding and printing, but the routine above takes the significand width
  as a parameter, so they can follow without a redesign. The trigger is a real
  program that reads a 16-bit float format from a file or a device.

### 42.10 Interactions

- **Generics.** `List[T]` and `Map[K, V]` take any value type, as they do today.
  Map keys are every integer type (recommended). Reason: integer equality is
  exact, and `vm/map.c` already keys on the tag. No float is a key, as today.
  `Set` (§12.2) follows the same rule.
- **`case` patterns.** A literal pattern takes the scrutinee's type (§42.5). An
  out-of-range pattern is `CHECK-INT-RANGE`. The `_` arm stays required for
  every non-enum `case` (`docs/grammar/06-semantics.md`).
- **Interpolation and `inspect`.** Decimal text. A `Float32` prints its shortest
  form (§42.9). A `UInt64` prints unsigned (§42.8).
- **`==`.** Two values of one sized type compare. The skill's rule for `==` on
  primitives (same type on both sides) extends to the new types.
- **Struct and enum fields.** Any sized type is a field type.
- **JSON.** Sized fields in structs encode and decode, with the range check and
  the path in the error (§42.8). `JSON.schema` gives `minimum` and `maximum`.
  The change is additive for `Int`: no existing JSON program changes.
- **CBOR (§16).** Adds one row per type when CBOR lands. Nothing changes now.
- **`std/binary`.** Recommended: step 3 moves the API to the types.
  Readers return the width type (`read_u16_be(data, offset) -> Result[UInt16]`),
  and writers take it (`write_u16_be(value: UInt16) -> List[UInt8]`). The
  function names stay. The errors that remain are for the offset and the frame
  length, since a list of `UInt8` cannot hold a bad item. Reason: the range
  check moves to the type, `Binary.write_u16_be(513)` still compiles (the
  literal takes the context type), and a value that is too big becomes an
  explicit conversion at the call site (`try n.to_uint16`). `read_frame_length`
  still returns `Result[Int]`, since a length is a count (below). This is
  breaking, and the module's design already names the move.
- **Byte lists.** In step 3, `IO.read_bytes`, `File.read_bytes`,
  `TCP.recv_bytes`, `Process.read_bytes`, `String.from_bytes` and the `*_bytes`
  writers take and return `List[UInt8]`. This is breaking (§42.15).
- **`Bytes` (§12.5): not added (recommended).** Reason: `List[UInt8]`, with the
  typed storage of step 4, is the compact byte sequence that `Bytes` was meant
  to be, and a second type would double every `*_bytes` builtin. The docs that
  name `Bytes` as a prerequisite (§12.5, §16, §20, §18.4, §40 and others; `rg -l
  '\bBytes\b'`) are updated when step 3 lands.
- **Range (§12.1).** Stays `Int` only (recommended). Reason: a range over a
  sized type has no natural end type, and `for` over `Int` is the common loop. A
  program converts the bounds: `for i in 0...b.to_int`.
- **Counts, sizes and indexes.** Stay `Int`: `String.length`, `List.at(index:
  Int)`, `List.repeat` counts, `Random.int(min: Int, max: Int)`, the `Time`
  functions (§41), `Int.times`, `read_frame_length`. Reason: a count is not
  negative in the programs that use it, and sized counts would add a conversion
  to nearly every loop.

### 42.11 VM representation

The checker knows every type, so the VM can use static types. The design has to
keep the run-time paths that do not know the type: `inspect`, `to_s`,
`JSON.encode`, `List.sort`, map keys and equality. Each of them reads the tag
today. Three options were weighed.

- **(A) Static types only, no new tags.** Rejected. The generic paths would need
  the kind passed in, and the VM keeps no types at run time today. Every builtin
  that handles any value would change.
- **(B) One `Int` tag, with the kind in the spare bits of the 32-bit tag word.**
  Rejected. Every `agc_is(v, AGC_T_INT)` would have to mask the word, and a
  missed mask would give a wrong answer without an error. It saves no memory,
  since `agc_value` stays 16 bytes.
- **(C) One tag per kind (recommended).** `AGC_T_INT8`, `AGC_T_INT16`,
  `AGC_T_INT32`, `AGC_T_UINT8`, `AGC_T_UINT16`, `AGC_T_UINT32`, `AGC_T_UINT64`
  and `AGC_T_FLOAT32` are added. Reason: each site is explicit, the compiler
  finds the missed ones, and the value stays 16 bytes (`vm/value.h`).

With (C), the operations are:

- **The `Int` opcodes do not change.** `ADD_I`, `SUB_I`, `MUL_I`, `DIV_I`,
  `MOD_I`, `NEG_I`, `LT_I` and `LE_I` keep their 64-bit overflow checks.
- **Six narrow kinds: one check opcode.** For `Int8`, `Int16`, `Int32`, `UInt8`,
  `UInt16` and `UInt32`, the lowering emits the 64-bit operation and then one
  new opcode, `FIT`, with the kind as an operand. `FIT` halts with
  `RUNTIME-INTEGER-OVERFLOW` when the value is outside the kind's range. Reason:
  one check for six types, against six opcodes for each operator. The name `FIT`
  is a placeholder for the implementation PR.
- **`UInt64`: unsigned opcodes.** `ADD_U`, `SUB_U`, `MUL_U`, `DIV_U`, `MOD_U`,
  `LT_U` and `LE_U`, seven new opcodes. Reason: the signed 64-bit operations are
  wrong above 2^63.
- **`Float32`: one rounding opcode.** `ROUND_F32` rounds a double to binary32
  after each float operation (§42.9). `Float32` uses the `_F` opcodes for the
  rest.
- **Bit, wrap and conversion operations are C builtins**, rows in `vm/numbers.c`
  with a row in the catalog. They are not opcodes.
- **Generic comparison.** `List.sort`, `List.sort_by` and the other generic
  paths compare by tag. A `UInt64` value compares as unsigned, so
  `18446744073709551615` sorts after `1`, as `UInt64` comparisons do (§42.7).
- **Hot path.** The `Int` code is unchanged. A sized operation adds one compare
  and branch. This is an estimate and is not measured. The benchmark rule of
  §38.7 applies: `make bench` runs an integer loop before and after step 1, and
  the numbers go in `docs/vm-benchmarks.md`.
- **Opcodes are appended.** New opcodes at the end of the list do not change the
  encoding of existing `.agcb` files, and the loader rejects only opcodes it
  does not know. So they do not change the format version.
- **Type-table kinds change the format.** Sized struct fields in typed JSON need
  new type-table kinds (`AGC_TYPE_*` in `vm/value.h`), and the loader rejects an
  unknown kind. A `Float32` literal needs a new constant kind that holds its
  decimal text (§42.5): the binary64 constant kind would round twice. So the
  format goes to version 7 (version 8 if §41 lands first, 41.18; the current
  version is in `docs/vm/03-ir-and-bytecode.md`). The writer of the Agentica
  compiler emits that version, so the format-version rule of §18.2 applies: the
  old `stage0` compiles the new compiler, which then compiles itself.
- **GC.** The sized values are not pointers, like `Int` (§38.1). No change to
  the collector's setup.

### 42.12 Storage (§38.6)

- **Step 4, gated by measurement.** Typed storage stores a list of a scalar type
  with its element width: 1 byte for `Int8` and `UInt8`, 2 bytes for the 16-bit
  types, 4 bytes for the 32-bit types and `Float32`, and 8 bytes for `Int`,
  `UInt64` and `Float`. No tag is stored per item. The list header holds the
  element kind, so the paths that have no static type (`inspect`, `to_s`,
  `JSON.encode`, `List.sort` and equality, §42.11) read the width from the list,
  as they read a tag today. A read rebuilds the `agc_value` from the element
  kind (§38.6, item 1). `Int` and `Float` lists are already unboxed at 8 bytes
  (§17.12), so step 4 is for `UInt64` and the narrower widths.
- **Why not earlier.** It touches every container that holds values, and the
  persistent vector (§17.12) would need leaves of more widths than its 8-byte
  Int and Float leaves. §38.7 says to change the value layout only when a
  measurement says so. The criterion: a program that reads a 10 MB file into a
  `List[UInt8]` has a peak RSS that is too high for its task, measured with the
  benchmark script, and the change is made only if the list items are the limit.
- **What it buys.** A `List[UInt8]` of 10 MB costs about 10 MB with typed
  storage, against about 160 MB with 16-byte items.

### 42.13 Phasing and tests

Each step is one or more PRs. Each PR holds its own contracts, with its own
tests and docs, so a later PR never carries a check that an earlier one
should have made.

- **Step 1: integer types.** Sub-PRs, in order: **1a** the types, reserved
  names, literals in context, same-type arithmetic, comparisons, `FIT` and the
  unsigned opcodes, and printing; **1b** the conversions, the bit methods and
  the wrap methods, with their catalog rows and `numbers.c` rows; **1c** JSON
  (struct fields, schema, decode with paths) and map keys. No storage change.
- **Step 2: Float32.** Type, literals (with `CHECK-FLOAT-RANGE`), `ROUND_F32`,
  the printing routine, `strtof` for text and JSON, and `Float32.to_bits` and
  `from_bits`.
- **Step 3: binary API and byte lists.** `std/binary` moves to the sized types
  (§42.10); the `*_bytes` builtins take `List[UInt8]`; `Float.to_bits32` and
  `Float.from_bits32` are removed. This is one breaking PR, as the module's
  design requires, and it is followed by a re-measure of the `binary` arm of the
  evaluation rounds.
- **Step 4: typed storage, if measured.** §42.12.

Tests, for each step: goldens for the VM, an independent Python peer with the
standard library only, and the checker goldens of the Agentica front end against
`agentica check --json`, each asserting the code and the span.

- **Vectors (Python peer).** A generator computes every result with Python's
  unbounded integers, masked to the width, and writes the input of a fixture, as
  the binary work does. It covers: edge values of each type (the smallest, the
  largest, zero, one, minus one); each operation on those values; each bit
  method and count (0, 1, width - 1, width, 63, 64); each conversion, including
  the plain and Result forms; `UInt64` values above 2^63, and `UInt64` lists
  sorted in unsigned order. CI never runs Python for this.
- **Float32 vectors.** The generator computes the exact result of each operation
  with `fractions.Fraction` and rounds it to binary32 with integer arithmetic.
  It does not use the double-rounding argument, so it is independent of §42.9.
  It also covers ties near 1.0, the largest finite value and the tie above it,
  subnormal ties, overflow to infinity, the Int-to-Float32 cases of §42.9
  (`9007199791611905` and `2^60 + 2^36 + 1`), and the shortest printing. The
  shortest printing tries each candidate of 1 to 9 digits and checks it with
  exact `Fraction` arithmetic: the candidate, as an exact decimal, must round to
  the value under the rule above, ties to even. It does not round through a
  `double` or call `struct`, so it repeats neither the double rounding of §42.9
  nor the C loop, and it does not use `repr`.
- **Round trips.** `to_uint8` then `to_int` gives back the value; `read` of
  `write` gives back the value for each type (step 3); `strtof` of the printed
  text gives back the Float32; `wrap_` of a value in range gives that value.
- **Errors.** Goldens hold each diagnostic code and its span: `CHECK-INT-RANGE`
  for a literal and for a negative literal of an unsigned type;
  `CHECK-TYPE-MISMATCH` for mixed types and for unary minus on an unsigned type;
  `CHECK-MAP-KEY-TYPE` for a float key; `CHECK-FLOAT-RANGE`;
  `RUNTIME-INTEGER-OVERFLOW` for each direction and for `MIN / -1`;
  `RUNTIME-INVALID-COUNT` for a negative shift count.
- **Docs in each step.** The grammar (`04-lexical.md`, `06-semantics.md`,
  `06b-builtins.md`, `07-diagnostics.md`), the programming skill (kept near
  2,000 tokens), the site numbers page (and `binary.md` in step 3), the
  development skill's VM references, and a `CHANGELOG.md` entry under
  `## [Unreleased]`, with `**Breaking:**` for the reserved names (step 1) and
  the binary API (step 3).

### 42.14 Freeze and bootstrap impact

- **Where it lands.** The Agentica front end (`compiler/`), which is the only
  front end. The sized rows go into its catalog.
- **`stage0`.** Step 1 adds no syntax, and the compiler's own code does not use
  the new types, so no `stage0` refresh is needed for it. Step 3 may change the
  compiler's use of the byte lists, which is a `stage0` change under §18.2 if it
  does. The format change (§42.11) is the `stage0` path of §18.2.

### 42.15 Breaking changes

- **Reserved names (step 1).** `Int8` to `UInt64`, `Float32`, `Int64` and
  `Float64` become reserved. A user `struct` with one of those names is
  `CHECK-REDEFINED-NAME`. `CHANGELOG.md` marks it **Breaking:**.
- **Binary API (step 3).** The `std/binary` readers and writers take and return
  the sized types, and the `*_bytes` builtins take `List[UInt8]`. `CHANGELOG.md`
  marks it **Breaking:**.
- **Float bit builtins (step 3).** `Float.to_bits32` and `Float.from_bits32` are
  removed in favour of `Float32.to_bits` and `from_bits`. `Float.to_bits`
  changes only if the owner decides on `UInt64` (§42.17).
- **No change to existing literals or `Int` results.** An existing program that
  uses `Int` does not change its meaning. Its literals stay `Int`, and its JSON
  `Int` fields stay the same.

### 42.16 Later and not planned

Later, each when a real program needs it:

- Float16 and BFloat16 (§42.9).
- Saturating conversions and methods (§42.6).
- Checked arithmetic methods that return a Result (§42.7).
- Hex, octal and binary literals (§42.5). This is the most likely first
  addition.
- Text parsers for the sized types, `UInt64` first (§42.6).
- A sized JSON extractor such as `JSON.uint64` (§42.8).
- SIMD vectors of the sized types (§19).
- Packed struct fields for the sized types (§38.6, item 3), after step 4.

Not planned:

- **Arbitrary-precision integers (`BigInt`).** Python's `int` is the case for
  it. It would need allocation and its own cost on the hot path, and no program
  needs it yet.
- **A decimal type.** No program needs one, and it is not on the roadmap.
- **Implicit numeric promotion or widening.** A second rule would make
  conversion errors invisible to agents. Explicit conversions only (§42.6).
- **Operator overloading to make conversions implicit.** §6 says there is none.
- **A `Byte` alias** (§42.4) and a separate `Bytes` type (§42.10).
- **An unsigned `Int`.** `Int` stays signed, and `UInt64` covers the range above
  it.
- **A target-dependent `Int` width.** The owner confirmed that `Int` and
  `Float` stay 64-bit on every target. A 32-bit option is only a note: the owner
  noted that it could be revisited if an old 32-bit architecture ever becomes a
  target; none is planned.
  - Design rationale (the author's, not the owner's): the VM stores `Int` as C
    `int64_t` and `Float` as `double`, which C provides on 32-bit CPUs too. A
    32-bit build must compute `Float` in hardware double (SSE2 on x86, VFP on
    ARM), since x87 extended precision gives other results. A build option for a
    32-bit `Int` would make the same program overflow on one target and not on
    another, and `.agcb` files would not move between them.

### 42.17 Questions for the owner

- **Literal typing (42.5, "Operators, calls and sign").** Adopt the rule as
  written: a literal, or a literal expression of arithmetic operators, takes the
  other operand's type; with two literal expressions, an arithmetic operator
  passes the expected type into both operands, and a comparison does not; a type
  variable of a call is fixed by its other arguments; and a unary `-` folds into
  an integer literal, so `x: UInt8 = -5` is `CHECK-INT-RANGE`. Recommendation:
  adopt it.
- **`Float.to_bits` return type.** Keep `Int` (signed bit pattern),
  or change to `UInt64` in step 3? Recommendation: change it in step 3, with the
  other bit builtins, so one type holds a 64-bit pattern. This is breaking, and
  it is a choice of API, not of correctness.
- **Trigger for step 4.** The measurement in §42.12 is a proposal. The owner may
  prefer a fixed trigger, for example a benchmark row of roadmap 14.
- **Hex literals.** Keep them later (recommended), or bring them into step 1
  when the literal rules are written, since the `0xFF` form is what binary code
  asks for first.
