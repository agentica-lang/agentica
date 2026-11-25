# Binary data (`std/binary`)

`import Binary from "std/binary"`. Binary data is a `Bytes`, such as the one
`IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` and `Process.read_bytes`
give. The module is written in Agentica on the bit builtins below.

```text
Binary.read_u8(data: Bytes, offset: Int) -> Result[UInt8]
Binary.read_i8(data: Bytes, offset: Int) -> Result[Int8]
Binary.read_u16_be(data, offset) -> Result[UInt16]  # also _le, i16 (Int16), u32, i32, u64 (UInt64)
Binary.read_i64_be(data, offset) -> Result[Int]     # also _le
Binary.read_f32_be(data, offset) -> Result[Float]   # also _le, f64
Binary.write_u8(value: UInt8) -> Bytes
Binary.write_i8(value: Int8) -> Bytes
Binary.write_u16_be(value: UInt16) -> Bytes       # also _le, i16, u32, i32, u64 (UInt64)
Binary.write_i64_be(value: Int) -> Bytes          # also _le
Binary.write_f32_be(value: Float) -> Bytes        # also _le, f64
Binary.frame(payload: Bytes) -> Result[Bytes]
Binary.read_frame_length(data: Bytes, offset: Int, max: Int) -> Result[Int]
```

- `_be` is big-endian (network order), `_le` little-endian; `u8` and `i8` have
  no suffix. Signed types use two's complement. `offset` is zero-based.
- Int overflow halts the program (`RUNTIME-INTEGER-OVERFLOW`), so a length,
  count or offset read from untrusted bytes is checked by subtraction
  (`len > max - held`), never added first; a product of two such numbers is
  checked by division (`a > max / b`). Test a parser with the largest length
  the wire allows.
- A reader never halts: an `offset` outside the data is an `error(...)`. A
  writer takes the type of its width and returns a plain `Bytes`, so `try` on
  one is a check error. A literal takes the parameter's type
  (`Binary.write_u16_be(513)`); convert an `Int` that may not fit first:
  `try n.to_uint16`. `x.to_i` gives the `Int` of a narrow reader result.
- `read_u64_*` gives a `UInt64` (`0 .. 18446744073709551615`, hashes, IDs);
  `read_i64_*` reads the same bytes as an `Int`, negative on a top bit set.
- Floats: `write_f32_*` rounds; every NaN is written as the canonical NaN.
  `-0.0`, infinities and subnormals are exact.
- Join writer results with `Bytes.concat(parts)`, not `+` in a loop
  (`bytes.md`). Build `parts` with `map`:
  `values.map do |v| Binary.write_i64_be(v) end`.
- `frame(payload)` is the 4-byte big-endian length, then the payload.
  `read_frame_length(data, offset, max)` returns the length, or an error above
  `max` (and for a negative `max`), so a program rejects a hostile length before
  it reads the body; then it reads that many bytes itself (`TCP.recv_bytes` and
  `Process.read_bytes` may return fewer).
- No mutable buffers: writers return new `Bytes`, which the program joins.

## Bit operations

```text
Int.bit_and(int: Int, other: Int) -> Int                 # 64-bit two's complement
Int.bit_or(int: Int, other: Int) -> Int
Int.bit_xor(int: Int, other: Int) -> Int
Int.bit_not(int: Int) -> Int                             # -1 - int
Int.shift_left(int: Int, count: Int) -> Int              # wraps; 64 or more gives 0
Int.shift_right(int: Int, count: Int) -> Int             # arithmetic, rounds down; 64 or more gives 0 or -1
Int.shift_right_unsigned(int: Int, count: Int) -> Int    # logical; 64 or more gives 0
Float.to_bits(float: Float) -> UInt64                    # binary64 bits; every NaN gives 9221120237041090560
Float.from_bits(bits: UInt64) -> Float                   # any UInt64; any NaN pattern gives NaN
Float.to_bits32(float: Float) -> Int                     # rounds to binary32; 0..4294967295; every NaN gives 2143289344
Float.from_bits32(bits: Int) -> Float                    # exact; bits outside 0..4294967295 halt (RUNTIME-INVALID-NUMBER)
```

- A negative shift count halts with `RUNTIME-INVALID-COUNT` at the count.
- Write masks in hex or binary: `0xFF`, `0xFFFF`, `0b1010`.
- `x.shift_right(i).bit_and(1) == 1` tests bit `i`; `x.to_bits >= 9223372036854775808`
  tests the sign of a Float (not NaN: use `x != x`).

## Text bytes

- `String.from_bytes` decodes strictly. A byte read can split a UTF-8 character,
  so decode complete sequences only. `s.bytes` encodes text for
  `File.write_bytes`, `TCP.send_bytes` and the like.

Hashes, MACs, ciphers, `Base64` and hex: `crypto.md`.
