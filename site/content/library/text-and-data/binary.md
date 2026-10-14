---
title: Binary data (std)
weight: 4
description: The std/binary module, which reads and writes binary numbers in a list of bytes.
---

`std/binary` is part of the standard library. It is written in Agentica itself, on the bit functions of [Int and Float](/library/text-and-data/numbers/). Import it with an alias: `import "std/binary" as Binary`.

Binary data is a `List[Int]` with each item in `0 .. 255`, the same list that `IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` and `Process.read_bytes` give. A reader takes the list and a zero-based `offset` and returns a `Result`. A writer returns a new list with the bytes of a number, and you join the lists with `Binary.concat`.

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

```output
[2, 1, 0, 0, 0, 0, 0, 0, 248, 63]
ok(513)
ok(1.5)
```

`_be` is big-endian (the most significant byte first, the order of networks) and `_le` is little-endian. Signed types use two's complement.

## Readers

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
```

A reader reads the bytes of its type from `offset`. It never halts the program: a bad offset or a bad item is an `error(...)` (see Errors below).

```agentica
import "std/binary" as Binary

def main() -> Void
  data = [1, 2, 3, 4, 255, 254]
  puts(Binary.read_u8(data, 4))
  puts(Binary.read_i8(data, 4))
  puts(Binary.read_u16_be(data, 0))
  puts(Binary.read_u16_le(data, 0))
  puts(Binary.read_u32_be(data, 0))
  puts(Binary.read_u32_le(data, 0))
  puts(Binary.read_i16_be(data, 4))
  puts(Binary.read_i16_le(data, 4))
end
```

```output
ok(255)
ok(-1)
ok(258)
ok(513)
ok(16909060)
ok(67305985)
ok(-2)
ok(-257)
```

## Writers

```text
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
```

A writer returns a new list with exactly the bytes of its type. The ranges are `u8` `0 .. 255`, `i8` `-128 .. 127`, `u16` `0 .. 65535`, `i16` `-32768 .. 32767`, `u32` `0 .. 4294967295`, `i32` `-2147483648 .. 2147483647`, and `u64` `0 .. 9223372036854775807`. A writer that can fail, because the value may be outside its type, returns a `Result`. `write_i64_*`, `write_f32_*` and `write_f64_*` cannot fail and return a plain list, so a `try` on them is a check error.

```agentica
import "std/binary" as Binary

def main() -> Void
  puts(Binary.write_u16_be(513))
  puts(Binary.write_u16_le(513))
  puts(Binary.write_i16_be(-2))
  puts(Binary.write_u32_be(305419896))
  puts(Binary.write_u32_le(305419896))
  puts(Binary.write_i64_be(-1))
  puts(Binary.write_i32_le(-2))
end
```

```output
ok([2, 1])
ok([1, 2])
ok([255, 254])
ok([18, 52, 86, 120])
ok([120, 86, 52, 18])
[255, 255, 255, 255, 255, 255, 255, 255]
ok([254, 255, 255, 255])
```

## Floats

`write_f64_*` writes the 8 bytes of `Float.to_bits`, and `read_f64_*` is `Float.from_bits` of those bytes. `write_f32_*` writes the 4 bytes of `Float.to_bits32`, so it rounds to the nearest binary32 value and never fails; `read_f32_*` widens the value back, which is exact. `-0.0`, infinities and subnormals are kept. Every NaN is written as the canonical NaN, so a NaN with another payload comes back canonical.

```agentica
import "std/binary" as Binary

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

`Int` is signed, so a `u64` above `9223372036854775807` is not an `Int`. `read_u64_*` returns an error for it instead of a negative number, and `write_u64_*` rejects a negative value. A program that needs all 64 bits (a hash, an ID) uses `read_i64_*` and `write_i64_*`, which read and write the same bytes as two's complement.

```agentica
import "std/binary" as Binary

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

Joins any number of parts in order. It costs O(n log k) for n bytes in k parts. Build `parts` with `map`. A loop of `out = List.concat(out, part)` copies the whole output on each pass and is O(n²) in the output size.

```agentica
import "std/binary" as Binary

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

`frame` puts the 4-byte big-endian length of the payload in front of it. `read_frame_length` reads that length at `offset` and returns an error when it is above `max`, so a reader can reject a hostile length before it reads the body. The program then reads that many bytes itself (`TCP.recv_bytes` and `Process.read_bytes` may return fewer bytes than asked, so read in a loop). Neither function looks at the payload items.

```agentica
import "std/binary" as Binary

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

The type in a message is the one in the function name. The index in `is not a byte` is the item's position in `data`.

```agentica
import "std/binary" as Binary

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

Writers return new lists and never change one in place, and there is no compact `Bytes` type yet, so a program joins the parts it writes with `Binary.concat`.
