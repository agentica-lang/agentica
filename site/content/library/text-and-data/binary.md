---
title: Binary data (std)
weight: 4
description: The std/binary module, which reads and writes binary numbers in a list of bytes.
---

`std/binary` is written in Agentica, on the bit functions of [Int and Float](/library/text-and-data/numbers/). Import it: `import Binary from "std/binary"`.

Binary data is a `List[Int]` of bytes (0 to 255), as `TCP.recv_bytes` and `Process.read_bytes` give; `b.to_a` gives that list for the `Bytes` of `IO.read_bytes` and `File.read_bytes`. A reader takes the list and a zero-based `offset`.

```agentica
import Binary from "std/binary"

def main() -> Void
  header = Binary.write_u16_be(513).unwrap!
  body = Binary.write_f64_le(1.5)
  data = Binary.concat([header, body])
  puts(data)
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_f64_le(data, 2))
end
```

```output
[2, 1, 0, 0, 0, 0, 0, 0, 248, 63]
ok(513)
ok(1.5)
```

`_be` is big-endian (network order), `_le` little-endian. Signed types use two's complement.

## Readers

```text
Binary.read_<T>(data: List[Int], offset: Int) -> Result[Int]
Binary.read_<F>(data: List[Int], offset: Int) -> Result[Float]
```

`<T>` is `u8` or `i8`, or `u16`, `i16`, `u32`, `i32`, `u64`, `i64` followed by `_be` or `_le`. `<F>` is `f32` or `f64` followed by `_be` or `_le`.

A reader never halts the program: a bad offset or item is an `error(...)` (see Errors).

```agentica
import Binary from "std/binary"

def main() -> Void
  data = [1, 2, 3, 4, 255, 254]
  puts(Binary.read_u8(data, 4))       # one byte, unsigned
  puts(Binary.read_i8(data, 4))       # the same byte, signed
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_u16_le(data, 0))
  puts(Binary.read_u32_be(data, 0))
  puts(Binary.read_i16_le(data, 4))
end
```

```output
ok(255)
ok(-1)
ok(258)
ok(513)
ok(16909060)
ok(-257)
```

## Writers

```text
Binary.write_<T>(value: Int) -> Result[List[Int]]
Binary.write_<I64>(value: Int) -> List[Int]
Binary.write_<F>(x: Float) -> List[Int]
```

`<T>` is `u8` or `i8`, or `u16`, `i16`, `u32`, `i32`, `u64` followed by `_be` or `_le`. `<I64>` is `i64_be` or `i64_le`. `<F>` is `f32` or `f64` followed by `_be` or `_le`. A writer returns a new list with exactly the bytes of its type, and never changes a list in place.

- Only `<T>` writers return a `Result`, since the value may be outside the type. `write_i64_*` and the float writers cannot fail and return a plain list, so a `try` on them is a check error.
- Ranges: `u8` 0 to 255, `i8` -128 to 127, `u16` 0 to 65535, `i16` -32768 to 32767, `u32` 0 to 4294967295, `i32` -2147483648 to 2147483647, `u64` 0 to 9223372036854775807.

```agentica
import Binary from "std/binary"

def main() -> Void
  puts(Binary.write_u16_be(513))
  puts(Binary.write_u16_le(513))
  puts(Binary.write_u32_be(305419896))
  puts(Binary.write_i64_be(-1))        # a plain list, it cannot fail
  puts(Binary.write_i32_le(-2))
end
```

```output
ok([2, 1])
ok([1, 2])
ok([18, 52, 86, 120])
[255, 255, 255, 255, 255, 255, 255, 255]
ok([254, 255, 255, 255])
```

## Floats

`f64` uses `Float.to_bits` and `Float.from_bits`. `write_f32_*` rounds to the nearest binary32 (`Float.to_bits32`); `read_f32_*` widens back exactly. `-0.0`, infinities and subnormals are kept, and every NaN is written as the canonical NaN.

```agentica
import Binary from "std/binary"

def main() -> Void
  puts(Binary.write_f32_be(1.0))
  puts(Binary.write_f64_be(1.0))
  puts(Binary.write_f32_le(0.1))
  puts(Binary.read_f32_le(Binary.write_f32_le(0.1), 0))
  puts(Binary.read_f64_be([64, 9, 33, 251, 84, 68, 45, 24], 0))
  puts(Binary.read_f32_be([127, 128, 0, 0], 0).unwrap! > 1.0)
end
```

```output
[63, 128, 0, 0]
[63, 240, 0, 0, 0, 0, 0, 0]
[205, 204, 204, 61]
ok(0.10000000149011612)
ok(3.141592653589793)
true
```

## u64 and i64

A `u64` above `9223372036854775807` is not an `Int`: `read_u64_*` gives an error and `write_u64_*` rejects a negative value. For all 64 bits use `read_i64_*` and `write_i64_*`.

```agentica
import Binary from "std/binary"

def main() -> Void
  top = [128, 0, 0, 0, 0, 0, 0, 0]
  puts(Binary.read_u64_be(top, 0))
  puts(Binary.read_i64_be(top, 0))
  puts(Binary.write_u64_be(-1))
  puts(Binary.write_u64_be(9223372036854775807))
end
```

```output
error("u64 at offset 0 does not fit in Int")
ok(-9223372036854775808)
error("value -1 does not fit in u64")
ok([127, 255, 255, 255, 255, 255, 255, 255])
```

## Binary.concat

```text
Binary.concat(parts: List[List[Int]]) -> List[Int]
```

Joins the parts in order, O(n log k) for n bytes in k parts. Build `parts` with `map`: a loop of `List.concat(out, part)` copies the whole output each pass, O(n²).

```agentica
import Binary from "std/binary"

def main() -> Void
  ids = [1, 258, 65536]
  parts = ids.map do |id| Binary.write_i32_be(id).unwrap! end
  puts(Binary.concat(parts))
  puts(Binary.concat([[1], [], [2, 3]]))
end
```

```output
[0, 0, 0, 1, 0, 0, 1, 2, 0, 1, 0, 0]
[1, 2, 3]
```

## Framing

```text
Binary.frame(payload: List[Int]) -> Result[List[Int]]
Binary.read_frame_length(data: List[Int], offset: Int, max: Int) -> Result[Int]
```

`frame` puts the 4-byte big-endian length in front of the payload. `read_frame_length` rejects a length above `max` before the body is read. Read the body yourself in a loop: `TCP.recv_bytes` and `Process.read_bytes` may return fewer bytes than asked.

```agentica
import Binary from "std/binary"

def main() -> Void
  framed = Binary.frame([104, 105]).unwrap!
  puts(framed)
  puts(Binary.read_frame_length(framed, 0, 65536))
  puts(Binary.read_frame_length([0, 1, 17, 112], 0, 65536))
  puts(Binary.read_frame_length(framed, 0, -1))
end
```

```output
[0, 0, 0, 2, 104, 105]
ok(2)
error("frame length 70000 is above the limit 65536")
error("frame limit -1 is negative")
```

## Errors

Every problem is an `error(message)`. A function checks these in order and returns the first that applies:

| Case | Message |
|---|---|
| `read_frame_length` with a negative `max` | `frame limit -1 is negative` |
| `offset` below 0 or above `data.size - n` (any `Int`) | `u32 at offset 10 is outside a list of length 12` |
| an item that is not in `0 .. 255`, the first one by index | `value 300 at index 2 is not a byte` |
| `read_u64_*` with the top bit set | `u64 at offset 0 does not fit in Int` |
| a writer's value outside its type | `value 70000 does not fit in u16` |
| `frame` with more than `4294967295` items | `payload of 4294967296 bytes does not fit in a u32 length` |
| `read_frame_length` above `max` | `frame length 70000 is above the limit 65536` |

The type in a message is the one in the function name.

```agentica
import Binary from "std/binary"

def main() -> Void
  data = [0, 0, 1, 44]
  puts(Binary.read_u32_be(data, 1))
  puts(Binary.read_u16_be(data, -1))
  puts(Binary.read_u16_be([1, 300], 0))
  puts(Binary.write_u8(256))
  puts(Binary.write_i16_le(-32769))
end
```

```output
error("u32 at offset 1 is outside a list of length 4")
error("u16 at offset -1 is outside a list of length 4")
error("value 300 at index 1 is not a byte")
error("value 256 does not fit in u8")
error("value -32769 does not fit in i16")
```

There is no compact `Bytes` type yet: join parts with `Binary.concat`.
