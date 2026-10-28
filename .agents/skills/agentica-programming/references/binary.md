# Binary data (`std/binary`)

`import Binary from "std/binary"`. Binary data is a `List[Int]` with each item
in `0 .. 255`, as `IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` and
`Process.read_bytes` give. The module is written in Agentica on the bit builtins
below.

```text
Binary.read_u8(data: List[Int], offset: Int) -> Result[Int]
Binary.read_i8(data: List[Int], offset: Int) -> Result[Int]
Binary.read_u16_be(data, offset) -> Result[Int]     # also _le, i16, u32, i32, u64, i64
Binary.read_f32_be(data, offset) -> Result[Float]   # also _le, f64
Binary.write_u8(value: Int) -> Result[List[Int]]
Binary.write_i8(value: Int) -> Result[List[Int]]
Binary.write_u16_be(value: Int) -> Result[List[Int]]  # also _le, i16, u32, i32, u64
Binary.write_i64_be(value: Int) -> List[Int]          # also _le; cannot fail
Binary.write_f32_be(x: Float) -> List[Int]            # also _le, f64; cannot fail
Binary.concat(parts: List[List[Int]]) -> List[Int]
Binary.frame(payload: List[Int]) -> Result[List[Int]]
Binary.read_frame_length(data: List[Int], offset: Int, max: Int) -> Result[Int]
```

- `_be` is big-endian (network order), `_le` little-endian; `u8` and `i8` have
  no suffix. Signed types use two's complement. `offset` is zero-based.
- A reader never halts: every problem is an `error(...)`. A writer that can fail
  (a value outside its type) returns a `Result`; `write_i64_*`, `write_f32_*`
  and `write_f64_*` return a plain `List[Int]`, so `try` on them is a check
  error.
- `u64` is `0 .. 9223372036854775807`: `read_u64_*` errors on a top bit set and
  `write_u64_*` rejects a negative value. For all 64 bits (hashes, IDs) use
  `read_i64_*` and `write_i64_*`, which read and write the same bytes.
- Floats: `write_f64_*` writes `Float.to_bits`, `write_f32_*` writes
  `Float.to_bits32` (it rounds). Every NaN is written as the canonical NaN, so a
  NaN with another payload reads and writes back canonical. `-0.0`, infinities
  and subnormals are exact.
- `concat` joins any number of parts in O(n log k); a loop of `out =
  List.concat(out, part)` copies the output each time and is O(n²). Build
  `parts` with `map`: `values.map do |v| Binary.write_i64_be(v) end`.
- `frame(payload)` is the 4-byte big-endian length, then the payload.
  `read_frame_length(data, offset, max)` returns the length, or an error above
  `max` (and for a negative `max`), so a program rejects a hostile length before
  it reads the body; then it reads that many bytes itself (`TCP.recv_bytes` and
  `Process.read_bytes` may return fewer).
- Errors, in this order (the first that applies): `frame limit -1 is negative`;
  `u32 at offset 10 is outside a list of length 12` (offset below 0 or above
  `size - n`, any `Int`); `value 300 at index 2 is not a byte` (the first bad
  item by index in the bytes read); `u64 at offset 0 does not fit in Int`;
  `value 70000 does not fit in u16`; `payload of 4294967296 bytes does not fit
  in a u32 length`; `frame length 70000 is above the limit 65536`.
- No mutable buffers and no `Bytes` type: writers return new lists, which the
  program joins.

## Bit operations

```text
Int.bit_and(a: Int, b: Int) -> Int                       # 64-bit two's complement; never fails
Int.bit_or(a: Int, b: Int) -> Int
Int.bit_xor(a: Int, b: Int) -> Int
Int.bit_not(a: Int) -> Int                               # -1 - a
Int.shift_left(a: Int, count: Int) -> Int                # wraps; 64 or more gives 0
Int.shift_right(a: Int, count: Int) -> Int               # arithmetic, rounds down; 64 or more gives 0 or -1
Int.shift_right_unsigned(a: Int, count: Int) -> Int      # logical; 64 or more gives 0
Float.to_bits(x: Float) -> Int                           # binary64 bits as an Int; every NaN gives 9221120237041090560
Float.from_bits(bits: Int) -> Float                      # any Int; any NaN pattern gives NaN
Float.to_bits32(x: Float) -> Int                         # rounds to binary32; 0..4294967295; every NaN gives 2143289344
Float.from_bits32(bits: Int) -> Float                    # exact; bits outside 0..4294967295 halt (RUNTIME-INVALID-NUMBER)
```

- A negative shift count halts with `RUNTIME-INVALID-COUNT` at the count.
- The core has no hex literals: write masks in decimal (`255`, `65535`).
- `x.shift_right(i).bit_and(1) == 1` tests bit `i`; `x.to_bits < 0` tests the
  sign of a Float (not NaN: use `x != x`).

## Text bytes and hashing

- `String.from_bytes` decodes strictly. A byte read can split a UTF-8 character,
  so decode complete sequences only and switch to text reads only at character
  boundaries. `String.to_bytes(s)` encodes text for `TCP.send_bytes`,
  `File.write_bytes` and the like.
- `Digest.md5`, `sha1`, `sha256` and `sha512(data: List[Int]) -> List[Int]`
  hash bytes with OpenSSL and return the 16, 20, 32 or 64 digest bytes; each
  `_hexdigest` form (`Digest.sha256_hexdigest(data) -> String`) returns them
  as lowercase hex, as Ruby's `Digest::SHA256.hexdigest`. MD5 and SHA-1 are
  for formats that need them (ETags, git), not for security. An item outside
  0..255 halts (`RUNTIME-INVALID-NUMBER`). The time grows with the list.
  `Crypto` is a reserved type name.

```text
Base64.strict_encode64(data: List[Int]) -> String     # padded, one line
Base64.encode64(data: List[Int]) -> String            # lines of 60 chars, each ends in "\n"
Base64.urlsafe_encode64(data: List[Int], padding: Bool = true) -> String  # - and _
Base64.strict_decode64(text: String) -> Result[List[Int]]
Base64.urlsafe_decode64(text: String) -> Result[List[Int]]  # padded or not
Base64.decode64(text: String) -> List[Int]            # lenient, never fails
Digest.hexencode(data: List[Int]) -> String           # lowercase
Digest.hexdecode(text: String) -> Result[List[Int]]   # either case
```

- `Base64` and `hexencode` behave as Ruby's (`hexdecode` is Agentica's own
  inverse, `error("invalid hex")`): `strict_decode64` and `urlsafe_decode64`
  give `error("invalid base64")` for anything but base64 (no newlines);
  `decode64` skips other characters and stops at a `=` padding. Text goes
  through `String.to_bytes` and `String.from_bytes`:
  `Base64.strict_encode64(String.to_bytes("hi"))`. An encoded item outside
  0..255 halts (`RUNTIME-INVALID-NUMBER`). `Base64` and `Digest` are reserved
  type names.
