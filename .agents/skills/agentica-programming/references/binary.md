# Binary data (`std/binary`)

`import Binary from "std/binary"`. Binary data is a `List[Int]` with each item
in `0 .. 255`, as `TCP.recv_bytes` and `Process.read_bytes` give (`b.to_a` for
the `Bytes` of `IO.read_bytes` and `File.read_bytes`). The module is written in
Agentica on the bit builtins below.

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
  boundaries. `s.bytes` encodes text for `File.write_bytes` and the like
  (`s.bytes.to_a` for `TCP.send_bytes`).
- `Digest.md5`, `sha1`, `sha256` and `sha512(data: Bytes) -> Bytes` hash
  bytes with OpenSSL and return the 16, 20, 32 or 64 digest bytes; each
  `_hexdigest` form (`Digest.sha256_hexdigest(data) -> String`) returns them
  as lowercase hex, as Ruby's `Digest::SHA256.hexdigest`. Hash text with
  `Digest.sha256("abc".bytes)`. MD5 and SHA-1 are for formats that need them
  (ETags, git), not for security; a FIPS-only system OpenSSL lacks them, and
  the call halts (`RUNTIME-INTERNAL`). The time grows with the data. `Crypto`
  is a reserved type name.
- `HMAC.sha256(key: Bytes, data: Bytes) -> Bytes` and `HMAC.sha512(key, data)`
  return the 32 or 64 bytes of the HMAC (RFC 2104, Ruby's
  `OpenSSL::HMAC.digest`); `HMAC.sha256_hexdigest(key, data) -> String` and
  `sha512_hexdigest` return them as lowercase hex. Any key length works, empty
  included. `HMAC` is a reserved type name.
- `HMAC.secure_compare(a: Bytes, b: Bytes) -> Bool` compares bytes in constant
  time (Ruby's `OpenSSL.secure_compare`): check a received MAC, signature or
  token with it, never with `==`, which is not constant time. Other lengths
  give `false`.

```text
Base64.strict_encode64(data: Bytes) -> String     # padded, one line
Base64.encode64(data: Bytes) -> String            # lines of 60 chars, each ends in "\n"
Base64.urlsafe_encode64(data: Bytes, padding: Bool = true) -> String  # - and _
Base64.strict_decode64(text: String) -> Result[Bytes]
Base64.urlsafe_decode64(text: String) -> Result[Bytes]  # padded or not
Base64.decode64(text: String) -> Bytes            # lenient, never fails
Digest.hexencode(data: Bytes) -> String           # lowercase
Digest.hexdecode(text: String) -> Result[Bytes]   # either case
```

- `Base64` and `hexencode` behave as Ruby's (`hexdecode` is Agentica's own
  inverse, `error("invalid hex")`): `strict_decode64` and `urlsafe_decode64`
  give `error("invalid base64")` for anything but base64 (no newlines);
  `decode64` skips other characters and stops at a `=` padding. Text goes
  through `s.bytes` and `String.from_bytes(b)`:
  `Base64.strict_encode64("hi".bytes)`. `Base64` and `Digest` are reserved
  type names.

## Secure random

```text
SecureRandom.random_bytes(n: Int = 16) -> Bytes       # OpenSSL RAND_bytes
SecureRandom.hex(n: Int = 16) -> String               # 2n lowercase hex digits
SecureRandom.uuid() -> String                         # version 4, 36 chars
```

- Use `SecureRandom` for keys, salts, tokens and IDs: `Random` is seeded and
  `--seed` repeats it, so it is not for secrets.
- `n` outside 0..1048576 halts (`RUNTIME-INVALID-COUNT`); a failed draw halts
  (`RUNTIME-INTERNAL`). The calls have the `random` effect label, so a module
  constant cannot call them. `SecureRandom` is a reserved type name.
