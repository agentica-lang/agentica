## 23. Binary data

**Status:** planned (roadmap phase 13). It is a new feature after 7i (roadmap
order row 7.2.4, before the freeze), VM-only, and comes before UDP. No grammar
change: new `Int` and `Float` builtins, and a new `std/binary` module.

Programs that speak a binary format must turn numbers into bytes and back: the
4-byte length in front of a message (§16.7), UDP and other packet headers, file
headers. Today a program does it by hand with `/ 256` and `% 256`, and it cannot
get the bits of a `Float` at all.

### 23.1 Where each part lives

- The roadmap rule "New library features: `std/` first" applies
  (`docs/roadmap/`, after the order table). Packing numbers into bytes is pure
  computation over types that already exist, so it is `std/binary.agc`, written
  in Agentica. It runs on the VM with no VM work, and the golden fixtures test
  it.
- Bit operations and the `Float` bit conversions are builtins, under exception 5
  of that rule (basic operations on the core types): in Agentica each one is a
  loop over 64 bits, or an exact scaling by powers of two with special cases for
  `-0.0`, NaN and subnormals, which is slow and easy to get wrong; in C each is
  about one line. They are VM-only: the evaluator is gone by then (7i), and new
  features get no Racket twin.
- So there is one module, `std/binary`. A separate `std/bits` would have nothing
  left to hold, since the bit operations are `Int` builtins.
- Binary data stays `List[Int]`, each item in `0 .. 255`, like `IO.read_bytes`,
  `File.read_bytes`, `Process.send_bytes` and the other `*_bytes` builtins. The
  compact `Bytes` type stays deferred (§12.5), and this work does not replace
  it. When `Bytes` lands, the `std/binary` API moves to `Bytes` in the same
  change as the `*_bytes` builtins.
- No mutable references are planned. Writers return small new lists that the
  program joins. If a mutable buffer is ever needed, it would be a handle type
  (like `HttpWriter`), not references.

### 23.2 `Int` bit builtins

```text
Int.bit_and(a: Int, b: Int) -> Int
Int.bit_or(a: Int, b: Int) -> Int
Int.bit_xor(a: Int, b: Int) -> Int
Int.bit_not(a: Int) -> Int
Int.shift_left(a: Int, count: Int) -> Int
Int.shift_right(a: Int, count: Int) -> Int
Int.shift_right_unsigned(a: Int, count: Int) -> Int
```

- Names: `and`, `or` and `not` are reserved words, so these say `bit_`, like
  Ruby's `bit_length`; the shifts use whole words, like the rest of the library
  (`index_of`, `from_int`). They are also methods on `Int`: `flags.bit_and(4)`,
  `x.shift_left(8)`. They have no effects, so an ignored result is
  `CHECK-UNUSED-VALUE`. The core has no hex literals, so masks are written in
  decimal (`255`, `65535`).
- Every function works on the 64-bit two's complement form of its arguments and
  reads the result back the same way.
- `bit_and`, `bit_or`, `bit_xor` and `bit_not` never fail. `bit_not(a)` is
  `-1 - a`: `bit_not(0)` is `-1`, and `bit_not` of the smallest Int is the
  largest.
- `shift_left(a, n)` for `n` in `0 .. 63` is the low 64 bits of `a × 2^n`. Bits
  that leave the top are dropped, and bit 63 becomes the sign, as in C on
  unsigned types, Java, Go and Rust: `1.shift_left(63)` is
  `-9223372036854775808`, `(-1).shift_left(1)` is `-2`,
  `4611686018427387904.shift_left(1)` is `-9223372036854775808`. It wraps
  instead of failing because a shift works on bits, not on a number: checksums
  and random generators (CRC-32, xorshift) depend on the dropped bits. A program
  that wants the overflow check multiplies: `x * 2` still halts with
  `RUNTIME-INTEGER-OVERFLOW`.
- `shift_right(a, n)` is arithmetic: copies of the sign bit come in at the top.
  It is `a / 2^n` rounded down, toward minus infinity (`/` truncates toward zero
  instead): `(-7).shift_right(1)` is `-4`, `(-1).shift_right(10)` is `-1`.
- `shift_right_unsigned(a, n)` is logical: zeros come in at the top, so it reads
  `a` as an unsigned 64-bit number: `(-1).shift_right_unsigned(60)` is `15`, and
  the smallest Int shifted by 63 is `1`. For `n >= 1` the result is never
  negative; for `n = 0` it is `a`. Hashes and random generators need it, where
  `shift_right` would copy the sign bit.
- A count of 64 or more shifts every bit out, as in Go: `shift_left` and
  `shift_right_unsigned` give `0`; `shift_right` gives `0` when `a >= 0` and
  `-1` when `a < 0`. So `(-1).shift_right_unsigned(64 - n)` is a mask of the low
  `n` bits for every `n` from 0 to 64.
- A negative count halts with `RUNTIME-INVALID-COUNT` at the count argument, the
  code that `List.take` and `List.repeat` use for bad counts. A negative count
  is almost always a bug: Ruby turns it into the other shift and Java keeps only
  its low 6 bits, and both hide the bug.
- Not included: a population count and a bit test.
  `x.shift_right(i).bit_and(1) == 1` tests bit `i`; `Int.bit_count` comes when a
  real program needs it.
- Implementation: C computes on `uint64_t`, so there is no signed overflow and
  no undefined shift, and checks the count before it shifts.

### 23.3 `Float` bit builtins

```text
Float.to_bits(x: Float) -> Int
Float.from_bits(bits: Int) -> Float
Float.to_bits32(x: Float) -> Int
Float.from_bits32(bits: Int) -> Float
```

- `to_bits` gives the IEEE 754 binary64 bits of `x` as a two's complement Int,
  so a Float with the sign bit set gives a negative Int. `1.0` gives
  `4607182418800017408` (`0x3FF0000000000000`), `-0.0` gives
  `-9223372036854775808`, `+inf.0` gives `9218868437227405312`
  (`0x7FF0000000000000`), `-inf.0` gives `-4503599627370496`
  (`0xFFF0000000000000`), and the smallest subnormal gives `1`. Every NaN gives
  the one quiet NaN `9221120237041090560` (`0x7FF8000000000000`), the value CBOR
  writes too (§16.4), so every platform agrees whatever NaN the host makes. It
  is also a method: `x.to_bits`.
- `from_bits` takes every Int and reads its 64 bits as a binary64. Subnormals,
  infinities and `-0.0` come back exactly; any NaN pattern gives NaN. So
  `Float.to_bits(Float.from_bits(n)) == n` for every `n` except NaN patterns
  other than `0x7FF8000000000000`.
- `to_bits32` rounds `x` to binary32 and gives its 32 bits as an Int in
  `0 .. 4294967295` (unsigned, since `Int` has room):
  - one rounding from the full 53-bit significand, to nearest with ties to even,
    as C's `(float)x`;
  - a magnitude of `2^128 - 2^103` or more becomes infinity with the same sign
    (exactly `2^128 - 2^103` is a tie, and the even neighbour is infinity),
    while a value just below rounds to the largest finite f32;
  - small magnitudes round to an f32 subnormal or to zero and keep their sign:
    `2^-150` is a tie and gives `0`, and `3 × 2^-150` gives `2 × 2^-149`;
  - `-0.0` gives `2147483648` (`0x80000000`), `+inf.0` gives `2139095040`
    (`0x7F800000`), `-inf.0` gives `4286578688` (`0xFF800000`), and every NaN
    gives `2143289344` (`0x7FC00000`).
- `from_bits32` reads 32 bits as a binary32 and widens it to a Float, which is
  always exact: every f32, subnormals included, is a binary64 value. It takes
  `0 .. 4294967295` only; any other Int halts with `RUNTIME-INVALID-NUMBER` at
  the argument, as `String.from_code` does (that one with
  `RUNTIME-INVALID-CHARACTER`). A value read from 4 bytes is always in range.
  NaN patterns give NaN, so `Float.to_bits32(Float.from_bits32(n)) == n` for
  every `n` except NaN patterns other than `0x7FC00000`.
- Today, without these builtins: a program gets an infinity only from an
  overflow (`big * big`, since Float literals have no exponent and
  `String.to_float` rejects `inf`, `nan` and exponents), and NaN from
  `inf - inf` or `inf * 0.0`, which do not fail; `x / 0.0`, `0.0 / 0.0`
  included, is `RUNTIME-DIVISION-BY-ZERO`. Since `-0.0 == 0.0`, it tells the two
  zeros apart only by text (`x.to_s == "-0.0"`). With `to_bits`, `x.to_bits < 0`
  tests the sign bit of every value except NaN, whose canonical bits are
  positive (test NaN with `x != x`).
- Implementation: C copies the bits with `memcpy`, converts with `(float)` and
  `(double)` (the VM never changes the rounding mode), and checks `isnan` first.
  The Python vectors (23.7) check the 4-byte rounding on ties at `1.0`, the
  largest finite f32 and the tie above it, f32 subnormal ties, and overflow.

### 23.4 Where the builtins go

No new opcode and no bytecode format change: the VM imports builtins by name
(`docs/vm/03-ir-and-bytecode.md` §4.5).

- `src/builtins.rkt`: eleven catalog rows, next to `Int.times` and
  `Float.from_int`. The checker reads signatures from the catalog, and methods
  come from the type of the first parameter (`src/checker.rkt` already maps
  `Int` and `Float` receivers to their modules), so the checker needs no other
  change. `agentica help Int.shift_left` reads the same rows.
- `src/lower.rkt`: the names in `vm-builtins`.
- `vm/numbers.c`: rows in `agc_number_builtins`, with `AGC_NATIVE_NONE` and
  `AGC_COST_NONE`.
- Docs in the same PR: the builtin list and the `Int` row of the methods table
  in `grammar.md`; the programming skill's `references/builtins.md`, and
  `references/diagnostics.md` for the new uses of `RUNTIME-INVALID-COUNT` and
  `RUNTIME-INVALID-NUMBER`; `site/content/library/text-and-data/numbers.md`.

### 23.5 `std/binary`

```agentica
import "std/binary" as Binary

def main() -> Void
  header = Binary.write_u16_be(513).unwrap!
  body = Binary.write_f64_le(1.5)
  data = Binary.concat([header, body])
  puts(data)
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_f64_le(data, 2))
end
```

It prints `[2, 1, 0, 0, 0, 0, 0, 0, 248, 63]`, `ok(513)` and `ok(1.5)`.

```text
Binary.read_u8(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i8(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u16_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u16_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i16_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i16_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u32_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u32_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i32_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i32_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u64_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u64_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i64_be(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i64_le(data: List[Int], offset: Int) -> Result[Int]
Binary.read_f32_be(data: List[Int], offset: Int) -> Result[Float]
Binary.read_f32_le(data: List[Int], offset: Int) -> Result[Float]
Binary.read_f64_be(data: List[Int], offset: Int) -> Result[Float]
Binary.read_f64_le(data: List[Int], offset: Int) -> Result[Float]

Binary.write_u8(value: Int) -> Result[List[Int]]
Binary.write_i8(value: Int) -> Result[List[Int]]
Binary.write_u16_be(value: Int) -> Result[List[Int]]
Binary.write_u16_le(value: Int) -> Result[List[Int]]
Binary.write_i16_be(value: Int) -> Result[List[Int]]
Binary.write_i16_le(value: Int) -> Result[List[Int]]
Binary.write_u32_be(value: Int) -> Result[List[Int]]
Binary.write_u32_le(value: Int) -> Result[List[Int]]
Binary.write_i32_be(value: Int) -> Result[List[Int]]
Binary.write_i32_le(value: Int) -> Result[List[Int]]
Binary.write_u64_be(value: Int) -> Result[List[Int]]
Binary.write_u64_le(value: Int) -> Result[List[Int]]
Binary.write_i64_be(value: Int) -> List[Int]
Binary.write_i64_le(value: Int) -> List[Int]
Binary.write_f32_be(x: Float) -> List[Int]
Binary.write_f32_le(x: Float) -> List[Int]
Binary.write_f64_be(x: Float) -> List[Int]
Binary.write_f64_le(x: Float) -> List[Int]

Binary.concat(parts: List[List[Int]]) -> List[Int]
Binary.frame(payload: List[Int]) -> Result[List[Int]]
Binary.read_frame_length(data: List[Int], offset: Int, max: Int) -> Result[Int]
```

- `_be` is big-endian (most significant byte first, network order) and `_le` is
  little-endian.
- Ranges: `u8` is `0 .. 255`, `i8` is `-128 .. 127`, `u16` is `0 .. 65535`,
  `i16` is `-32768 .. 32767`, `u32` is `0 .. 4294967295`, `i32` is
  `-2147483648 .. 2147483647`, `u64` is `0 .. 9223372036854775807` (as an Int,
  see below), and `i64` is every Int. Signed types use two's complement.
- **Readers** take a zero-based `offset` into `data` and read the type's bytes
  from there. They never halt the program: every problem is an `error(...)`.
- **Writers** return a new list with exactly the type's bytes. Writers that can
  fail (a value outside the type) return a `Result`; `i64`, `f32` and `f64`
  writers cannot fail and return a plain `List[Int]`, so the types say which is
  which (a `try` on a plain list is a check error).
- **u64:** `Int` is signed, so a u64 above `2^63 - 1` is not an Int.
  `read_u64_*` returns an error for it instead of a negative number, and
  `write_u64_*` rejects negative values. A program that needs all 64 bits (a
  hash, an ID) uses `read_i64_*` and `write_i64_*`, which read and write the
  same bytes as two's complement. So every `ok` of an integer reader writes back
  to the same bytes; a float reader does too, except that a NaN pattern other
  than the canonical one comes back canonical (§23.3).
- **Floats:** `read_f64_*` is `Float.from_bits` of the `i64`, and `write_f64_*`
  writes the 8 bytes of `Float.to_bits`. `read_f32_*` is `Float.from_bits32` of
  the `u32`, and `write_f32_*` writes the 4 bytes of `Float.to_bits32`, so it
  rounds and never fails. The rules for NaN, `-0.0`, infinities and subnormals
  are those of §23.3.
- **Joining:** for two or three parts, `List.concat` is fine. `concat(parts)`
  joins any number of parts in order. It splits `parts` in halves and joins them
  with `List.concat` recursively, so it costs O(n log k) for n bytes in k parts,
  and the recursion is only about log2 k deep. Build `parts` with `List.map`
  (O(k)), for example `values.map do |v| Binary.write_i64_be(v) end`. A loop of
  `out = List.concat(out, part)` copies the whole output each time, O(n²)
  (23.6).
- **Framing** (§16.7): `frame(payload)` is the 4-byte big-endian length, then
  the payload. `read_frame_length(data, offset, max)` reads that length at
  `offset` and returns an error when it is above `max` (a negative `max` is an
  error too), so a reader rejects a hostile length before it reads the body. The
  program then reads that many bytes itself (`TCP.recv_bytes` or
  `Process.read_bytes` in a loop; both may return fewer bytes than asked).
  Neither function looks at the payload items: `frame` copies them as they are.
- **Errors**, checked in this order; the first that applies is returned:

  | Case | Message |
  |---|---|
  | `read_frame_length` with `max < 0` | `frame limit -1 is negative` |
  | `offset < 0` or `offset > data.size - n` (no overflow for any offset) | `u32 at offset 10 is outside a list of length 12` |
  | an item that is not in `0 .. 255`, the first one by index | `value 300 at index 2 is not a byte` |
  | `read_u64_*` with the top bit set | `u64 at offset 0 does not fit in Int` |
  | a writer's value outside its type | `value 70000 does not fit in u16` |
  | `frame` with more than `4294967295` items | `payload of 4294967296 bytes does not fit in a u32 length` |
  | `read_frame_length` above `max` | `frame length 70000 is above the limit 65536` |

  The type in a message is the one in the function name (`u8`, `i16`, `f32`,
  ...; `read_frame_length` reads a `u32`). Messages are lowercase with no final
  period, like other `Result` messages. The index in `is not a byte` is the
  item's position in `data`, not in the value: reading at offset 10 with a bad
  first byte gives `at index 10`. The text comes from the Agentica code of the
  module.
- **Implementation**, in Agentica on the 23.2 and 23.3 builtins, with no loop
  over bytes (and no module state, which Agentica does not have):
  - a reader checks the range with `offset < 0 or offset > data.size - n`; reads
    the items by index (O(1) on the VM); checks them all with one `bit_or` of
    the items and one range test, and walks them again only on failure, to name
    the first bad one; and combines them with `shift_left` and `bit_or`, whose
    wrap gives the right `i64`. Signed types below 64 bits sign-extend with
    `v.shift_left(64 - w).shift_right(64 - w)` for width `w`.
  - a writer checks the range, then returns a list literal of
    `value.shift_right(8 * k).bit_and(255)`, which is right for negative values
    too, since `shift_right` is arithmetic.

### 23.6 Cost

Measured on today's VM (AMD Ryzen 5 3550H, Linux) with prototypes of the readers
and writers in today's Agentica, using `/`, `%` and `+` where the real module
calls the bit builtins (a builtin method call costs the same steps as a binary
operator: one for the node and one per operand):

- A 4-byte read costs about 70 steps and an 8-byte read about 120; a 4-byte
  write about 35 and an 8-byte write about 45. The 1- and 2-byte forms cost
  less, and a float adds one builtin call (about 3 steps). In time: about 0.4 µs
  per write and 0.75 to 1 µs per read.
- Each new builtin is one call: one step plus its arguments, and constant time.
- `concat` costs about 35 steps per part, plus the copies. For 25,000 parts of 4
  bytes (100,000 bytes), `Binary.concat` took 0.08 s; `List.concat` in a loop
  took 5.7 s.
- Faster lists (8d) make `push` (`List.append`) cheap (§12.4), so a loop that
  pushes each byte onto the output is fine too. §12.4 promises nothing for
  `List.concat`, so `Binary.concat` stays the way to join parts, with the same
  API. Writers still return new lists: offset writers into an existing list are
  not planned (`List.set` copies today, and no mutation is planned, 23.1).
- Taking a payload out of a large buffer with `List.drop` and `List.take` copies
  the rest of the buffer on the VM. If a real program needs that often, a
  `List.slice` builtin (exception 5 of the roadmap rule) is the fix; it is not
  part of this plan.

### 23.7 Tests

Each PR of phase 13 brings its own tests: 13a for the builtins, 13b for
`std/binary`.

- **Python vectors**, the independent counterpart. A generator script (Python 3,
  standard library only: `struct`, and `float.as_integer_ratio` for exact
  values) writes the vectors, one per line, as decimal Ints or the tokens `inf`,
  `-inf`, `nan` and `-0` (the first line is a header that the fixture skips),
  into the `.stdin` sidecar of a fixture in `tests/fixtures/vm/`, so the golden
  shards run the fixture on the VM. The script, its output and the fixture are
  checked in together; the script is run by hand when the vectors change, and
  the header says how the output was made. CI never runs Python for this.
  - **13a**, `bits-vectors.py` writes `bits-vectors.stdin` for
    `bits-vectors.agc`: each `Int` bit builtin on edge values (0, 1, -1, the
    smallest and largest Int, alternating bit patterns) and counts (0, 1, 63,
    64, 65, the largest Int), computed by Python on unbounded ints masked to 64
    bits, except that the expected `shift_left` result for counts of 64 or more
    is written from the §23.2 rule (`0`), not computed, since CPython cannot
    shift left by the largest Int; `Float.to_bits` and `Float.to_bits32` of
    Float inputs, against `struct` (`>d` read back as `>q`, `>f` read back as
    `>I`); `from_bits` and `from_bits32` of bit patterns, against the expected
    Float.
  - **13b**, `std-binary-vectors.py` writes `std-binary-vectors.stdin` for
    `std-binary-vectors.agc`: every reader and writer against the bytes of
    `struct.pack`, with `>` and `<` and the formats `B b H h I i Q q f d`. Ints:
    0, 1, -1, the smallest and largest value of each type, the values just
    outside it (writer errors), and patterns such as `0x0102030405060708` that
    show the byte order.
  - Float values in both: `0.0`, `-0.0`, `1.0`, `-1.5`, `0.1`, the largest
    finite value, the smallest normal, the largest and smallest subnormals, both
    infinities and NaN (expected: the canonical bits), and for decoding NaN
    patterns with other payloads and signs. For f32 also rounding: ties to even
    next to `1.0` (`1 + 2^-24`, `1 + 3 × 2^-24`), the largest finite f32 and the
    tie above it, values that overflow (Python's `struct` raises `OverflowError`
    there; the script writes infinity of the same sign, which is what C's cast
    gives), f32 subnormal ties (`2^-150`, `3 × 2^-150`), and the largest and
    smallest f32 subnormals.
  - A Float input is written as an Int significand `m` (`|m| < 2^53`) and a
    power of two `e`, or as `inf`, `-inf`, `nan` or `-0`. The fixture builds
    `Float.from_int(m)` times `2^e`, with the power of two made by repeated
    squaring of `2.0` or `0.5`; every step is exact, since every power of two
    from `2^-1074` to `2^1023` is a Float and the script only writes values that
    are doubles. It makes infinity from an overflow and NaN from `inf - inf`. So
    the inputs do not depend on `Float.from_bits`, and a decoded Float is
    compared with the value built by arithmetic (equal `to_s`, and `x != x` for
    NaN).
  - Each vectors fixture checks every vector in both directions, prints a line
    for each mismatch, and then `N vectors ok`.
- **Round trips:**
  - 13a, in `float-bits.agc`: `Float.from_bits(Float.to_bits(x))` has the same
    `to_s` as `x` for every vector value, and
    `Float.to_bits32(Float.from_bits32(n))` is `n` for every non-NaN `n`; a NaN
    pattern other than the canonical one comes back canonical.
  - 13b, in `std-binary.agc`: `read(write(v), 0)` is `ok(v)` for every vector
    value, every width and both byte orders, and `write(read(b, 0))` gives back
    `b` for every byte pattern of the vectors. The two exceptions are tested on
    purpose: `read_u64_*` with the top bit set is an error, and a NaN pattern
    other than the canonical one comes back canonical. `frame` then
    `read_frame_length` gives the payload's length; `concat` of 0, 1, 2, 3 and
    many parts, with empty parts.
- **Errors:** 13a: `int-shift-negative.agc` halts with `RUNTIME-INVALID-COUNT`,
  and `float-from-bits32-negative.agc` (`-1`) and `float-from-bits32-range.agc`
  (`4294967296`) halt with `RUNTIME-INVALID-NUMBER`; their goldens hold the
  codes, and a test checks the spans. 13b, in `std-binary.agc`: offsets `-1`,
  `size - n + 1`, and the smallest and largest Int; items `-1` and `256`; each
  writer one past each end of its range; the u64 top bit; a frame length above
  `max`; a negative `max` (`frame limit -1 is negative`).
- **Fixed expected output:** every fixture above has a golden
  (`<name>.expected`, `docs/vm/12-testing-and-pr-plan.md` §12.1), hand-checked
  when it is first written: no mismatch lines, `N vectors ok`, and the expected
  lines of the other fixtures. The Python vectors are the independent
  counterpart, so a bug in `std/binary` cannot hide behind a matching golden.
- If a vectors fixture is slow under the `--max-steps` sweep, list it in
  `heavy-fixtures` in `tests/vm-diff-common.rkt`.

### 23.8 Moving a function to C later

Under the roadmap rule, a `std/binary` function moves to a C builtin only when a
measurement shows it is hot: a `make bench` program, the server measurement (7j)
or the cross-language benchmarks (phase 12) show it among the top costs of a
real program. Then its body in `stdlib/binary.agc` becomes one call to a new
builtin with the same results and the same error strings (they are program data,
`docs/vm/README.md` §1), so user code and its output do not change. The new
builtin is public (no internal helper builtins, `docs/vm/03-ir-and-bytecode.md`
§4.5). It goes in an existing builtin module whose first parameter type fits
(for example `List.read_u32_be(data, offset)`), never under a module named like
the `std/` module's documented import alias, so the import keeps working. It is
documented like any other builtin, and the `std/` function becomes a one-line
wrapper. The goldens hold; only step counts change. The numbers before and after
go in `docs/vm-benchmarks.md`.

### 23.9 `std/queue`

§12.3 used to say that `std/queue` is removed once another `std/` module exists,
and `std/binary` is such a module. Its PR does not remove `std/queue`: §12.3 now
says that the removal waits until 8c has landed `Queue[T]`, and that it is its
own PR with a changelog note.

### 23.10 Not planned

- `Bytes` (§12.5), mutable buffers or references (23.1), and writers into an
  existing list at an offset.
- Half floats (f16), varints (LEB128), hex and Base64: later, each when a real
  program needs it (§20 keeps hex and Base64 open).

