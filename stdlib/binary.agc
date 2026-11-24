## Reads and writes binary numbers in a `Bytes`.
##
## Import it with `import Binary from "std/binary"`. Binary data is a `Bytes`, such as the one that `IO.read_bytes` and
## `File.read_bytes` give. Each function has the type of its width: `read_u16_be` gives a `UInt16`, `write_i32_le`
## takes an `Int32`, `read_u64_be` gives a `UInt64`, and the 64-bit signed and float functions use `Int` and `Float`. A
## reader takes a zero-based `offset` and returns a `Result`; it never halts, and its only error is an offset outside
## the data. A writer returns a new `Bytes` with exactly the bytes of its type and never fails; convert a value that
## may be too big first (`try n.to_uint16`) and join many with `Bytes.concat`. `_be` is big-endian (most significant
## byte first, network order) and `_le` is little-endian. Signed types use two's complement.

## Reads a unsigned 8-bit integer at `offset` as a `UInt8`. Returns an error when the bytes are outside `data`.
def read_u8(data: Bytes, offset: Int) -> Result[UInt8]
  value = try load8(data, offset, "u8")
  ok(value.wrap_uint8)
end

## Reads a signed 8-bit integer at `offset` as a `Int8`. Returns an error when the bytes are outside `data`.
def read_i8(data: Bytes, offset: Int) -> Result[Int8]
  value = try load8(data, offset, "i8")
  ok(value.wrap_int8)
end

## Reads a big-endian unsigned 16-bit integer at `offset` as a `UInt16`. Returns an error when the bytes are outside
## `data`.
def read_u16_be(data: Bytes, offset: Int) -> Result[UInt16]
  value = try load16_be(data, offset, "u16")
  ok(value.wrap_uint16)
end

## Reads a little-endian unsigned 16-bit integer at `offset` as a `UInt16`. Returns an error when the bytes are outside
## `data`.
def read_u16_le(data: Bytes, offset: Int) -> Result[UInt16]
  value = try load16_le(data, offset, "u16")
  ok(value.wrap_uint16)
end

## Reads a big-endian signed 16-bit integer at `offset` as a `Int16`. Returns an error when the bytes are outside
## `data`.
def read_i16_be(data: Bytes, offset: Int) -> Result[Int16]
  value = try load16_be(data, offset, "i16")
  ok(value.wrap_int16)
end

## Reads a little-endian signed 16-bit integer at `offset` as a `Int16`. Returns an error when the bytes are outside
## `data`.
def read_i16_le(data: Bytes, offset: Int) -> Result[Int16]
  value = try load16_le(data, offset, "i16")
  ok(value.wrap_int16)
end

## Reads a big-endian unsigned 32-bit integer at `offset` as a `UInt32`. Returns an error when the bytes are outside
## `data`.
def read_u32_be(data: Bytes, offset: Int) -> Result[UInt32]
  value = try load32_be(data, offset, "u32")
  ok(value.wrap_uint32)
end

## Reads a little-endian unsigned 32-bit integer at `offset` as a `UInt32`. Returns an error when the bytes are outside
## `data`.
def read_u32_le(data: Bytes, offset: Int) -> Result[UInt32]
  value = try load32_le(data, offset, "u32")
  ok(value.wrap_uint32)
end

## Reads a big-endian signed 32-bit integer at `offset` as a `Int32`. Returns an error when the bytes are outside
## `data`.
def read_i32_be(data: Bytes, offset: Int) -> Result[Int32]
  value = try load32_be(data, offset, "i32")
  ok(value.wrap_int32)
end

## Reads a little-endian signed 32-bit integer at `offset` as a `Int32`. Returns an error when the bytes are outside
## `data`.
def read_i32_le(data: Bytes, offset: Int) -> Result[Int32]
  value = try load32_le(data, offset, "i32")
  ok(value.wrap_int32)
end

## Reads a big-endian unsigned 64-bit integer at `offset` as a `UInt64`. Returns an error when the bytes are outside
## `data`.
def read_u64_be(data: Bytes, offset: Int) -> Result[UInt64]
  value = try load64_be(data, offset, "u64")
  ok(value.wrap_uint64)
end

## Reads a little-endian unsigned 64-bit integer at `offset` as a `UInt64`. Returns an error when the bytes are outside
## `data`.
def read_u64_le(data: Bytes, offset: Int) -> Result[UInt64]
  value = try load64_le(data, offset, "u64")
  ok(value.wrap_uint64)
end

## Reads a big-endian signed 64-bit integer at `offset`. Returns an error when the bytes are outside `data`.
def read_i64_be(data: Bytes, offset: Int) -> Result[Int] = load64_be(data, offset, "i64")

## Reads a little-endian signed 64-bit integer at `offset`. Returns an error when the bytes are outside `data`.
def read_i64_le(data: Bytes, offset: Int) -> Result[Int] = load64_le(data, offset, "i64")

## Reads a big-endian 32-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
def read_f32_be(data: Bytes, offset: Int) -> Result[Float]
  bits = try load32_be(data, offset, "f32")
  ok(Float.from_bits32(bits))
end

## Reads a little-endian 32-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
def read_f32_le(data: Bytes, offset: Int) -> Result[Float]
  bits = try load32_le(data, offset, "f32")
  ok(Float.from_bits32(bits))
end

## Reads a big-endian 64-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
def read_f64_be(data: Bytes, offset: Int) -> Result[Float]
  bits = try load64_be(data, offset, "f64")
  ok(Float.from_bits(bits.wrap_uint64))
end

## Reads a little-endian 64-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
def read_f64_le(data: Bytes, offset: Int) -> Result[Float]
  bits = try load64_le(data, offset, "f64")
  ok(Float.from_bits(bits.wrap_uint64))
end

## Returns the 1 byte of `value` as a unsigned 8-bit integer.
def write_u8(value: UInt8) -> Bytes = pack([value.to_i])

## Returns the 1 byte of `value` as a signed 8-bit integer.
def write_i8(value: Int8) -> Bytes = pack([value.to_i.bit_and(255)])

## Returns the 2 bytes of `value` as a big-endian unsigned 16-bit integer.
def write_u16_be(value: UInt16) -> Bytes = bytes2_be(value.to_i)

## Returns the 2 bytes of `value` as a little-endian unsigned 16-bit integer.
def write_u16_le(value: UInt16) -> Bytes = bytes2_le(value.to_i)

## Returns the 2 bytes of `value` as a big-endian signed 16-bit integer.
def write_i16_be(value: Int16) -> Bytes = bytes2_be(value.to_i)

## Returns the 2 bytes of `value` as a little-endian signed 16-bit integer.
def write_i16_le(value: Int16) -> Bytes = bytes2_le(value.to_i)

## Returns the 4 bytes of `value` as a big-endian unsigned 32-bit integer.
def write_u32_be(value: UInt32) -> Bytes = bytes4_be(value.to_i)

## Returns the 4 bytes of `value` as a little-endian unsigned 32-bit integer.
def write_u32_le(value: UInt32) -> Bytes = bytes4_le(value.to_i)

## Returns the 4 bytes of `value` as a big-endian signed 32-bit integer.
def write_i32_be(value: Int32) -> Bytes = bytes4_be(value.to_i)

## Returns the 4 bytes of `value` as a little-endian signed 32-bit integer.
def write_i32_le(value: Int32) -> Bytes = bytes4_le(value.to_i)

## Returns the 8 bytes of `value` as a big-endian unsigned 64-bit integer.
def write_u64_be(value: UInt64) -> Bytes = bytes8_be(value)

## Returns the 8 bytes of `value` as a little-endian unsigned 64-bit integer.
def write_u64_le(value: UInt64) -> Bytes = bytes8_le(value)

## Returns the 8 bytes of `value` as a big-endian signed 64-bit integer.
def write_i64_be(value: Int) -> Bytes = bytes8_be(value.wrap_uint64)

## Returns the 8 bytes of `value` as a little-endian signed 64-bit integer.
def write_i64_le(value: Int) -> Bytes = bytes8_le(value.wrap_uint64)

## Returns the 4 bytes of `value` as a big-endian 32-bit IEEE 754 float. It rounds to the nearest binary32 value. It
## never fails; every NaN gives the canonical NaN bits.
def write_f32_be(value: Float) -> Bytes = bytes4_be(Float.to_bits32(value))

## Returns the 4 bytes of `value` as a little-endian 32-bit IEEE 754 float. It rounds to the nearest binary32 value. It
## never fails; every NaN gives the canonical NaN bits.
def write_f32_le(value: Float) -> Bytes = bytes4_le(Float.to_bits32(value))

## Returns the 8 bytes of `value` as a big-endian 64-bit IEEE 754 float. It never fails; every NaN gives the canonical
## NaN bits.
def write_f64_be(value: Float) -> Bytes = bytes8_be(Float.to_bits(value))

## Returns the 8 bytes of `value` as a little-endian 64-bit IEEE 754 float. It never fails; every NaN gives the
## canonical NaN bits.
def write_f64_le(value: Float) -> Bytes = bytes8_le(Float.to_bits(value))

## Returns the 4-byte big-endian length of `payload` followed by `payload`. Returns an error when `payload` has more
## than 4294967295 bytes.
def frame(payload: Bytes) -> Result[Bytes]
  if payload.size > 4294967295
    return error("payload of #{payload.size} bytes does not fit in a u32 length", kind: "argument")
  end
  ok(bytes4_be(payload.size) + payload)
end

## Reads the 4-byte big-endian length of a frame at `offset`. Returns an error when `max` is negative, the bytes are
## outside `data`, or the length is above `max`. Read the body yourself after it.
def read_frame_length(data: Bytes, offset: Int, max: Int) -> Result[Int]
  return error("frame limit #{max} is negative", kind: "argument") if max < 0
  length = try load32_be(data, offset, "u32")
  return error("frame length #{length} is above the limit #{max}", kind: "binary.too_large") if length > max
  ok(length)
end

private

def window(data: Bytes, offset: Int, n: Int, type: String) -> Result[Void]
  if offset < 0 or offset > data.size - n
    return error("#{type} at offset #{offset} is outside bytes of length #{data.size}", kind: "argument")
  end
  ok()
end

def load8(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 1, type)
  a = data[offset]
  ok(a)
end

def load16_be(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 2, type)
  a = data[offset]
  b = data[offset + 1]
  ok(a.shift_left(8).bit_or(b))
end

def load16_le(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 2, type)
  a = data[offset]
  b = data[offset + 1]
  ok(b.shift_left(8).bit_or(a))
end

def load32_be(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 4, type)
  a = data[offset]
  b = data[offset + 1]
  c = data[offset + 2]
  d = data[offset + 3]
  ok(a.shift_left(24).bit_or(b.shift_left(16)).bit_or(c.shift_left(8)).bit_or(d))
end

def load32_le(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 4, type)
  a = data[offset]
  b = data[offset + 1]
  c = data[offset + 2]
  d = data[offset + 3]
  ok(d.shift_left(24).bit_or(c.shift_left(16)).bit_or(b.shift_left(8)).bit_or(a))
end

def load64_be(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 8, type)
  a = data[offset]
  b = data[offset + 1]
  c = data[offset + 2]
  d = data[offset + 3]
  e = data[offset + 4]
  f = data[offset + 5]
  g = data[offset + 6]
  h = data[offset + 7]
  high = a.shift_left(24).bit_or(b.shift_left(16)).bit_or(c.shift_left(8)).bit_or(d)
  low = e.shift_left(24).bit_or(f.shift_left(16)).bit_or(g.shift_left(8)).bit_or(h)
  ok(high.shift_left(32).bit_or(low))
end

def load64_le(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 8, type)
  a = data[offset]
  b = data[offset + 1]
  c = data[offset + 2]
  d = data[offset + 3]
  e = data[offset + 4]
  f = data[offset + 5]
  g = data[offset + 6]
  h = data[offset + 7]
  low = d.shift_left(24).bit_or(c.shift_left(16)).bit_or(b.shift_left(8)).bit_or(a)
  high = h.shift_left(24).bit_or(g.shift_left(16)).bit_or(f.shift_left(8)).bit_or(e)
  ok(high.shift_left(32).bit_or(low))
end

def bytes2_be(value: Int) -> Bytes = pack([value.shift_right(8).bit_and(255), value.bit_and(255)])

def bytes2_le(value: Int) -> Bytes = pack([value.bit_and(255), value.shift_right(8).bit_and(255)])

def bytes4_be(value: Int) -> Bytes
  pack([
    value.shift_right(24).bit_and(255),
    value.shift_right(16).bit_and(255),
    value.shift_right(8).bit_and(255),
    value.bit_and(255),
  ])
end

def bytes4_le(value: Int) -> Bytes
  pack([
    value.bit_and(255),
    value.shift_right(8).bit_and(255),
    value.shift_right(16).bit_and(255),
    value.shift_right(24).bit_and(255),
  ])
end

def bytes8_be(value: UInt64) -> Bytes
  pack([
    value.shift_right(56).to_i!,
    value.shift_right(48).bit_and(255).to_i!,
    value.shift_right(40).bit_and(255).to_i!,
    value.shift_right(32).bit_and(255).to_i!,
    value.shift_right(24).bit_and(255).to_i!,
    value.shift_right(16).bit_and(255).to_i!,
    value.shift_right(8).bit_and(255).to_i!,
    value.bit_and(255).to_i!,
  ])
end

def bytes8_le(value: UInt64) -> Bytes
  pack([
    value.bit_and(255).to_i!,
    value.shift_right(8).bit_and(255).to_i!,
    value.shift_right(16).bit_and(255).to_i!,
    value.shift_right(24).bit_and(255).to_i!,
    value.shift_right(32).bit_and(255).to_i!,
    value.shift_right(40).bit_and(255).to_i!,
    value.shift_right(48).bit_and(255).to_i!,
    value.shift_right(56).to_i!,
  ])
end

# Every item the callers give is masked to 0 .. 255, so from_list cannot fail.
def pack(items: List[Int]) -> Bytes = Bytes.from_list(items).unwrap!
