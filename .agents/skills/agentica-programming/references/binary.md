# Binary data (`std/binary`)

`import Binary from "std/binary"`. Binary data is a `List[Int]` with each item
in `0 .. 255`, like `IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` and
`Process.read_bytes` give. The module is written in Agentica on the `Int` and
`Float` bit builtins (`references/builtins.md`).

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

- `_be` is big-endian (network order), `_le` is little-endian. `u8` and `i8`
  have no suffix. Signed types use two's complement. `offset` is zero-based.
- A reader never halts: every problem is an `error(...)`. A writer that can fail
  (a value outside its type) returns a `Result`; `write_i64_*`, `write_f32_*`
  and `write_f64_*` return a plain `List[Int]`, so `try` on them is a check
  error.
- `u64` is `0 .. 9223372036854775807`: `read_u64_*` returns an error for a top
  bit set and `write_u64_*` rejects a negative value. For all 64 bits (hashes,
  IDs) use `read_i64_*` and `write_i64_*`, which read and write the same bytes.
- Floats: `write_f64_*` writes `Float.to_bits`, `write_f32_*` writes
  `Float.to_bits32` (it rounds). Every NaN is written as the canonical NaN, so a
  NaN pattern with another payload reads and writes back canonical. `-0.0`,
  infinities and subnormals are exact.
- `concat` joins any number of parts in O(n log k). A loop of `out =
  List.concat(out, part)` copies the whole output each time and is O(n²). Build
  `parts` with `map`: `values.map do |v| Binary.write_i64_be(v) end`.
- `frame(payload)` is the 4-byte big-endian length, then the payload.
  `read_frame_length(data, offset, max)` returns the length, or an error above
  `max` (and for a negative `max`), so a program rejects a hostile length before
  it reads the body. Then it reads that many bytes itself (`TCP.recv_bytes` and
  `Process.read_bytes` may return fewer).
- Errors, in this order (the first that applies): `frame limit -1 is negative`;
  `u32 at offset 10 is outside a list of length 12` (offset below 0 or above
  `size - n`, any `Int`); `value 300 at index 2 is not a byte` (the first bad
  item by index in the bytes read); `u64 at offset 0 does not fit in Int`;
  `value 70000 does not fit in u16`; `payload of 4294967296 bytes does not fit
  in a u32 length`; `frame length 70000 is above the limit 65536`.
- No mutable buffers and no `Bytes` type: writers return new lists, which the
  program joins.

```ruby
import Binary from "std/binary"

def main() -> Void
  header = Binary.write_u16_be(513).unwrap!
  data = Binary.concat([header, Binary.write_f64_le(1.5)])
  puts(data)
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_f64_le(data, 2))
  puts(Binary.read_u32_be(data, 8))
end
```

It prints `[2, 1, 0, 0, 0, 0, 0, 0, 248, 63]`, `ok(513)`, `ok(1.5)` and
`error("u32 at offset 8 is outside a list of length 10")`.
