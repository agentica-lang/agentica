---
title: Binary data (std)
weight: 4
description: The std/binary module, which reads and writes binary numbers in a Bytes.
---

`std/binary` is written in Agentica, on the bit functions of [Int and Float](/library/text-and-data/numbers/). Import it: `import Binary from "std/binary"`.

Binary data is a [`Bytes`](/library/data-structures/bytes/), such as the one `IO.read_bytes`, `File.read_bytes`, `TCP.recv_bytes` and `Process.read_bytes` give. Each function has the [sized type](/library/text-and-data/numbers/#int8-int16-int32-uint8-uint16-and-uint32) of its width: `read_u16_be` gives a `UInt16`, `write_i32_le` takes an `Int32`. A reader takes the `Bytes` and a zero-based `offset`; its only error is an offset outside the data. A writer takes a value of its type, so it cannot fail, and returns a new `Bytes`.

```agentica
import Binary from "std/binary"

def main() -> Void
  header = Binary.write_u16_be(513)
  body = Binary.write_f64_le(1.5)
  data = Bytes.concat([header, body])
  puts(data.to_a)
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

```signature
Binary.read_<T>(data: Bytes, offset: Int) -> Result[<type of T>]
Binary.read_<F>(data: Bytes, offset: Int) -> Result[Float]
```

`<T>` is `u8` or `i8`, or `u16`, `i16`, `u32`, `i32`, `u64`, `i64` followed by `_be` or `_le`, and its type is `UInt8`, `Int8`, `UInt16`, `Int16`, `UInt32`, `Int32`, `UInt64` and `Int` (`i64` is the `Int`). `<F>` is `f32` or `f64` followed by `_be` or `_le`.

A reader never halts the program: a bad offset is an `error(...)` (see Errors). The `offset` may be any `Int`. `x.to_i` gives the `Int` of a narrow value when you need to count with it.

```agentica
import Binary from "std/binary"

def main() -> Void
  data = Bytes.from_list([1, 2, 3, 4, 255, 254]).unwrap!
  puts(Binary.read_u8(data, 4)) # one byte, a UInt8
  puts(Binary.read_i8(data, 4)) # the same byte, an Int8
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

```signature
Binary.write_<T>(value: <type of T>) -> Bytes
Binary.write_<F>(value: Float) -> Bytes
```

`<T>` and its types are the ones of the readers. `<F>` is `f32` or `f64` followed by `_be` or `_le`. A writer returns a new `Bytes` with exactly the bytes of its type; a `Bytes` never changes in place.

- No writer fails and none returns a `Result`, so a `try` on one is a check error. A literal takes the type of the parameter (`Binary.write_u16_be(513)`); a value that may be outside the type is converted first, where the error can be handled: `try n.to_uint16`.

```agentica
import Binary from "std/binary"

def main() -> Void
  puts(Binary.write_u16_be(513).to_a)
  puts(Binary.write_u16_le(513).to_a)
  puts(Binary.write_u32_be(305419896).to_a)
  puts(Binary.write_i64_be(-1).to_a)
  puts(Binary.write_i32_le(-2).to_a)
end
```

```output
[2, 1]
[1, 2]
[18, 52, 86, 120]
[255, 255, 255, 255, 255, 255, 255, 255]
[254, 255, 255, 255]
```

## Floats

`f64` uses `Float.to_bits` and `Float.from_bits`, which read the 64 bits as a `UInt64`. `write_f32_*` rounds to the nearest binary32 (`Float.to_bits32`); `read_f32_*` widens back exactly. `-0.0`, infinities and subnormals are kept, and every NaN is written as the canonical NaN.

```agentica
import Binary from "std/binary"

def main() -> Void
  puts(Binary.write_f32_be(1.0).to_a)
  puts(Binary.write_f64_be(1.0).to_a)
  puts(Binary.write_f32_le(0.1).to_a)
  puts(Binary.read_f32_le(Binary.write_f32_le(0.1), 0))
  puts(Binary.read_f64_be(Bytes.from_list([64, 9, 33, 251, 84, 68, 45, 24]).unwrap!, 0))
  puts(Binary.read_f32_be(Bytes.from_list([127, 128, 0, 0]).unwrap!, 0).unwrap! > 1.0)
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

`read_u64_*` gives a `UInt64`, which holds all of `0` to `18446744073709551615`; `read_i64_*` reads the same bytes as an `Int`, negative when the top bit is set. Every `ok` of an integer reader writes back to the same bytes; a float reader does too, except that a NaN pattern other than the canonical one comes back canonical.

```agentica
import Binary from "std/binary"

def main() -> Void
  top = Bytes.from_list([128, 0, 0, 0, 0, 0, 0, 0]).unwrap!
  puts(Binary.read_u64_be(top, 0))
  puts(Binary.read_i64_be(top, 0))
  puts(Binary.write_u64_be(18446744073709551615).to_a)
end
```

```output
ok(9223372036854775808)
ok(-9223372036854775808)
[255, 255, 255, 255, 255, 255, 255, 255]
```

Writers return new values and no buffer is ever changed. Offset writers into an existing `Bytes` are not part of the module. Half floats (f16) and varints (LEB128) are not supported; hex and Base64 are the `OpenSSL.Digest` and `Base64` builtins. The bit operations and the `Float` bit conversions are `Int` and `Float` builtins, because in Agentica each one is a 64-bit loop or an exact scaling by powers of two with special cases for `-0.0`, NaN and subnormals.

## Joining

To join writer results, use `Bytes.concat(parts)`: one copy for any number of parts. Build `parts` with `map`; a loop of `+` copies the whole output each pass, O(n²).

```agentica
import Binary from "std/binary"

def main() -> Void
  ids: List[Int32] = [1, 258, 65536]
  parts = ids.map do |id: Int32| Binary.write_i32_be(id) end
  puts(Bytes.concat(parts).to_a)
  puts(Bytes.concat([]).to_a)
end
```

```output
[0, 0, 0, 1, 0, 0, 1, 2, 0, 1, 0, 0]
[]
```

## Framing

```signature
Binary.frame(payload: Bytes) -> Result[Bytes]
Binary.read_frame_length(data: Bytes, offset: Int, max: Int) -> Result[Int]
```

`frame` puts the payload's 4-byte big-endian length in front of it (an error above `4294967295` bytes). `read_frame_length` rejects a length above `max` before the body is read. Read the body yourself in a loop: `TCP.recv_bytes` and `Process.read_bytes` may return fewer bytes than asked.

```agentica
import Binary from "std/binary"

def main() -> Void
  framed = Binary.frame("hi".bytes).unwrap!
  puts(framed.to_a)
  puts(Binary.read_frame_length(framed, 0, 65536))
  puts(Binary.read_frame_length(Bytes.from_list([0, 1, 17, 112]).unwrap!, 0, 65536))
  puts(Binary.read_frame_length(framed, 0, -1))
end
```

```output
[0, 0, 0, 2, 104, 105]
ok(2)
error("frame length 70000 is above the limit 65536", kind: "binary.too_large")
error("frame limit -1 is negative", kind: "argument")
```

## Errors

Every problem is an `error(message)`. A function checks these in order and returns the first that applies:

| Case | Message |
|---|---|
| `read_frame_length` with a negative `max` | `frame limit -1 is negative` |
| `offset` below 0 or above `data.size - n` (any `Int`) | `u32 at offset 10 is outside bytes of length 12` |
| `frame` with more than `4294967295` bytes | `payload of 4294967296 bytes does not fit in a u32 length` |
| `read_frame_length` above `max` | `frame length 70000 is above the limit 65536` |

The type in a message is the one in the function name.

```agentica
import Binary from "std/binary"

def main() -> Void
  data = Bytes.from_list([0, 0, 1, 44]).unwrap!
  puts(Binary.read_u32_be(data, 1))
  puts(Binary.read_u16_be(data, -1))
  puts(Binary.read_u8(data, 4))
end
```

```output
error("u32 at offset 1 is outside bytes of length 4", kind: "argument")
error("u16 at offset -1 is outside bytes of length 4", kind: "argument")
error("u8 at offset 4 is outside bytes of length 4", kind: "argument")
```
