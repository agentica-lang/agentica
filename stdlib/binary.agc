## Reads and writes binary numbers in a `Bytes`.
##
## Import it with `import Binary from "std/binary"`. Binary data is a `Bytes`, such as the one that `IO.read_bytes` and
## `File.read_bytes` give. A reader takes a zero-based `offset` and returns a `Result`; it never halts, and its only
## error is an offset outside the data. A writer returns a new `Bytes` with exactly the bytes of its type; join many
## with `Bytes.concat`. `_be` is big-endian (most significant byte first, network order) and `_le` is little-endian.
## Signed types use two's complement. A `u64` above `9223372036854775807` is not an `Int`: use `read_i64_be` and
## `write_i64_be` for all 64 bits.

## Reads an unsigned 8-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_u8(data: Bytes, offset: Int) -> Result[Int]
  return load8(data, offset, "u8")
end

## Reads a signed 8-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_i8(data: Bytes, offset: Int) -> Result[Int]
  value = try load8(data, offset, "i8")
  return ok(extend(value, 8))
end

## Reads a big-endian unsigned 16-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_u16_be(data: Bytes, offset: Int) -> Result[Int]
  return load16_be(data, offset, "u16")
end

## Reads a little-endian unsigned 16-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_u16_le(data: Bytes, offset: Int) -> Result[Int]
  return load16_le(data, offset, "u16")
end

## Reads a big-endian signed 16-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_i16_be(data: Bytes, offset: Int) -> Result[Int]
  value = try load16_be(data, offset, "i16")
  return ok(extend(value, 16))
end

## Reads a little-endian signed 16-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_i16_le(data: Bytes, offset: Int) -> Result[Int]
  value = try load16_le(data, offset, "i16")
  return ok(extend(value, 16))
end

## Reads a big-endian unsigned 32-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_u32_be(data: Bytes, offset: Int) -> Result[Int]
  return load32_be(data, offset, "u32")
end

## Reads a little-endian unsigned 32-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_u32_le(data: Bytes, offset: Int) -> Result[Int]
  return load32_le(data, offset, "u32")
end

## Reads a big-endian signed 32-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_i32_be(data: Bytes, offset: Int) -> Result[Int]
  value = try load32_be(data, offset, "i32")
  return ok(extend(value, 32))
end

## Reads a little-endian signed 32-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_i32_le(data: Bytes, offset: Int) -> Result[Int]
  value = try load32_le(data, offset, "i32")
  return ok(extend(value, 32))
end

## Reads a big-endian unsigned 64-bit integer at `offset`. Returns an error when the bytes are outside `data`, or when
## the value is above `9223372036854775807`.
export def read_u64_be(data: Bytes, offset: Int) -> Result[Int]
  value = try load64_be(data, offset, "u64")
  return unsigned64(value, offset)
end

## Reads a little-endian unsigned 64-bit integer at `offset`. Returns an error when the bytes are outside `data`, or
## when the value is above `9223372036854775807`.
export def read_u64_le(data: Bytes, offset: Int) -> Result[Int]
  value = try load64_le(data, offset, "u64")
  return unsigned64(value, offset)
end

## Reads a big-endian signed 64-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_i64_be(data: Bytes, offset: Int) -> Result[Int]
  return load64_be(data, offset, "i64")
end

## Reads a little-endian signed 64-bit integer at `offset`. Returns an error when the bytes are outside `data`.
export def read_i64_le(data: Bytes, offset: Int) -> Result[Int]
  return load64_le(data, offset, "i64")
end

## Reads a big-endian 32-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
export def read_f32_be(data: Bytes, offset: Int) -> Result[Float]
  bits = try load32_be(data, offset, "f32")
  return ok(Float.from_bits32(bits))
end

## Reads a little-endian 32-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
export def read_f32_le(data: Bytes, offset: Int) -> Result[Float]
  bits = try load32_le(data, offset, "f32")
  return ok(Float.from_bits32(bits))
end

## Reads a big-endian 64-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
export def read_f64_be(data: Bytes, offset: Int) -> Result[Float]
  bits = try load64_be(data, offset, "f64")
  return ok(Float.from_bits(bits))
end

## Reads a little-endian 64-bit IEEE 754 float at `offset`. Returns an error when the bytes are outside `data`.
export def read_f64_le(data: Bytes, offset: Int) -> Result[Float]
  bits = try load64_le(data, offset, "f64")
  return ok(Float.from_bits(bits))
end

## Returns the 1 byte of `value` as an unsigned 8-bit integer. Returns an error when `value` is not in `0 .. 255`.
export def write_u8(value: Int) -> Result[Bytes]
  try fits(value, 0, 255, "u8")
  return ok(pack([value]))
end

## Returns the 1 byte of `value` as a signed 8-bit integer. Returns an error when `value` is not in `-128 .. 127`.
export def write_i8(value: Int) -> Result[Bytes]
  try fits(value, -128, 127, "i8")
  return ok(pack([value.bit_and(255)]))
end

## Returns the 2 bytes of `value` as a big-endian unsigned 16-bit integer. Returns an error when `value` is not in
## `0 .. 65535`.
export def write_u16_be(value: Int) -> Result[Bytes]
  try fits(value, 0, 65535, "u16")
  return ok(bytes2_be(value))
end

## Returns the 2 bytes of `value` as a little-endian unsigned 16-bit integer. Returns an error when `value` is not in
## `0 .. 65535`.
export def write_u16_le(value: Int) -> Result[Bytes]
  try fits(value, 0, 65535, "u16")
  return ok(bytes2_le(value))
end

## Returns the 2 bytes of `value` as a big-endian signed 16-bit integer. Returns an error when `value` is not in
## `-32768 .. 32767`.
export def write_i16_be(value: Int) -> Result[Bytes]
  try fits(value, -32768, 32767, "i16")
  return ok(bytes2_be(value))
end

## Returns the 2 bytes of `value` as a little-endian signed 16-bit integer. Returns an error when `value` is not in
## `-32768 .. 32767`.
export def write_i16_le(value: Int) -> Result[Bytes]
  try fits(value, -32768, 32767, "i16")
  return ok(bytes2_le(value))
end

## Returns the 4 bytes of `value` as a big-endian unsigned 32-bit integer. Returns an error when `value` is not in
## `0 .. 4294967295`.
export def write_u32_be(value: Int) -> Result[Bytes]
  try fits(value, 0, 4294967295, "u32")
  return ok(bytes4_be(value))
end

## Returns the 4 bytes of `value` as a little-endian unsigned 32-bit integer. Returns an error when `value` is not in
## `0 .. 4294967295`.
export def write_u32_le(value: Int) -> Result[Bytes]
  try fits(value, 0, 4294967295, "u32")
  return ok(bytes4_le(value))
end

## Returns the 4 bytes of `value` as a big-endian signed 32-bit integer. Returns an error when `value` is not in
## `-2147483648 .. 2147483647`.
export def write_i32_be(value: Int) -> Result[Bytes]
  try fits(value, -2147483648, 2147483647, "i32")
  return ok(bytes4_be(value))
end

## Returns the 4 bytes of `value` as a little-endian signed 32-bit integer. Returns an error when `value` is not in
## `-2147483648 .. 2147483647`.
export def write_i32_le(value: Int) -> Result[Bytes]
  try fits(value, -2147483648, 2147483647, "i32")
  return ok(bytes4_le(value))
end

## Returns the 8 bytes of `value` as a big-endian unsigned 64-bit integer. Returns an error when `value` is not in
## `0 .. 9223372036854775807`.
export def write_u64_be(value: Int) -> Result[Bytes]
  try fits(value, 0, 9223372036854775807, "u64")
  return ok(bytes8_be(value))
end

## Returns the 8 bytes of `value` as a little-endian unsigned 64-bit integer. Returns an error when `value` is not in
## `0 .. 9223372036854775807`.
export def write_u64_le(value: Int) -> Result[Bytes]
  try fits(value, 0, 9223372036854775807, "u64")
  return ok(bytes8_le(value))
end

## Returns the 8 bytes of `value`, big-endian. It never fails.
export def write_i64_be(value: Int) -> Bytes
  return bytes8_be(value)
end

## Returns the 8 bytes of `value`, little-endian. It never fails.
export def write_i64_le(value: Int) -> Bytes
  return bytes8_le(value)
end

## Returns the 4 bytes of `x` as a big-endian 32-bit IEEE 754 float. It rounds to the nearest binary32 value. It never
## fails; every NaN gives the canonical NaN bits.
export def write_f32_be(x: Float) -> Bytes
  return bytes4_be(Float.to_bits32(x))
end

## Returns the 4 bytes of `x` as a little-endian 32-bit IEEE 754 float. It rounds to the nearest binary32 value. It
## never fails; every NaN gives the canonical NaN bits.
export def write_f32_le(x: Float) -> Bytes
  return bytes4_le(Float.to_bits32(x))
end

## Returns the 8 bytes of `x` as a big-endian 64-bit IEEE 754 float. It never fails; every NaN gives the canonical NaN
## bits.
export def write_f64_be(x: Float) -> Bytes
  return bytes8_be(Float.to_bits(x))
end

## Returns the 8 bytes of `x` as a little-endian 64-bit IEEE 754 float. It never fails; every NaN gives the canonical
## NaN bits.
export def write_f64_le(x: Float) -> Bytes
  return bytes8_le(Float.to_bits(x))
end

## Returns the 4-byte big-endian length of `payload` followed by `payload`. Returns an error when `payload` has more
## than 4294967295 bytes.
export def frame(payload: Bytes) -> Result[Bytes]
  if payload.size > 4294967295
    return error("payload of #{payload.size} bytes does not fit in a u32 length")
  end
  return ok(bytes4_be(payload.size) + payload)
end

## Reads the 4-byte big-endian length of a frame at `offset`. Returns an error when `max` is negative, the bytes are
## outside `data`, or the length is above `max`. Read the body yourself after it.
export def read_frame_length(data: Bytes, offset: Int, max: Int) -> Result[Int]
  if max < 0
    return error("frame limit #{max} is negative")
  end
  length = try load32_be(data, offset, "u32")
  if length > max
    return error("frame length #{length} is above the limit #{max}")
  end
  return ok(length)
end

def window(data: Bytes, offset: Int, n: Int, type: String) -> Result[Void]
  if offset < 0 or offset > data.size - n
    return error("#{type} at offset #{offset} is outside bytes of length #{data.size}")
  end
  return ok()
end

def fits(value: Int, low: Int, high: Int, type: String) -> Result[Void]
  if value < low or value > high
    return error("value #{value} does not fit in #{type}")
  end
  return ok()
end

def extend(value: Int, bits: Int) -> Int
  return value.shift_left(64 - bits).shift_right(64 - bits)
end

def load8(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 1, type)
  a = data[offset]
  return ok(a)
end

def load16_be(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 2, type)
  a = data[offset]
  b = data[offset + 1]
  return ok(a.shift_left(8).bit_or(b))
end

def load16_le(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 2, type)
  a = data[offset]
  b = data[offset + 1]
  return ok(b.shift_left(8).bit_or(a))
end

def load32_be(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 4, type)
  a = data[offset]
  b = data[offset + 1]
  c = data[offset + 2]
  d = data[offset + 3]
  return ok(a.shift_left(24).bit_or(b.shift_left(16)).bit_or(c.shift_left(8)).bit_or(d))
end

def load32_le(data: Bytes, offset: Int, type: String) -> Result[Int]
  try window(data, offset, 4, type)
  a = data[offset]
  b = data[offset + 1]
  c = data[offset + 2]
  d = data[offset + 3]
  return ok(d.shift_left(24).bit_or(c.shift_left(16)).bit_or(b.shift_left(8)).bit_or(a))
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
  return ok(high.shift_left(32).bit_or(low))
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
  return ok(high.shift_left(32).bit_or(low))
end

def unsigned64(value: Int, offset: Int) -> Result[Int]
  if value < 0
    return error("u64 at offset #{offset} does not fit in Int")
  end
  return ok(value)
end

def bytes2_be(value: Int) -> Bytes
  return pack([value.shift_right(8).bit_and(255), value.bit_and(255)])
end

def bytes2_le(value: Int) -> Bytes
  return pack([value.bit_and(255), value.shift_right(8).bit_and(255)])
end

def bytes4_be(value: Int) -> Bytes
  return pack([
    value.shift_right(24).bit_and(255),
    value.shift_right(16).bit_and(255),
    value.shift_right(8).bit_and(255),
    value.bit_and(255),
  ])
end

def bytes4_le(value: Int) -> Bytes
  return pack([
    value.bit_and(255),
    value.shift_right(8).bit_and(255),
    value.shift_right(16).bit_and(255),
    value.shift_right(24).bit_and(255),
  ])
end

def bytes8_be(value: Int) -> Bytes
  return pack([
    value.shift_right(56).bit_and(255),
    value.shift_right(48).bit_and(255),
    value.shift_right(40).bit_and(255),
    value.shift_right(32).bit_and(255),
    value.shift_right(24).bit_and(255),
    value.shift_right(16).bit_and(255),
    value.shift_right(8).bit_and(255),
    value.bit_and(255),
  ])
end

def bytes8_le(value: Int) -> Bytes
  return pack([
    value.bit_and(255),
    value.shift_right(8).bit_and(255),
    value.shift_right(16).bit_and(255),
    value.shift_right(24).bit_and(255),
    value.shift_right(32).bit_and(255),
    value.shift_right(40).bit_and(255),
    value.shift_right(48).bit_and(255),
    value.shift_right(56).bit_and(255),
  ])
end

# Every item the callers give is masked to 0 .. 255, so from_list cannot fail.
def pack(items: List[Int]) -> Bytes
  return Bytes.from_list(items).unwrap!
end
