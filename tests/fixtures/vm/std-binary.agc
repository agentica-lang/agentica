import "std/binary" as Binary

struct IntReader
  name: String
  size: Int
  read: Fn[List[Int], Int, Result[Int]]
end

struct IntWriter
  name: String
  low: Int
  high: Int
  write: Fn[Int, Result[List[Int]]]
end

struct Pair
  name: String
  size: Int
  write: Fn[Int, Result[List[Int]]]
  read: Fn[List[Int], Int, Result[Int]]
  values: List[Int]
end

def write_i64_be(value: Int) -> Result[List[Int]]
  return ok(Binary.write_i64_be(value))
end

def write_i64_le(value: Int) -> Result[List[Int]]
  return ok(Binary.write_i64_le(value))
end

def int_min() -> Int
  return Int.bit_not(9223372036854775807)
end

def readers() -> List[IntReader]
  return [
    IntReader(name: "u8", size: 1, read: &Binary.read_u8),
    IntReader(name: "i8", size: 1, read: &Binary.read_i8),
    IntReader(name: "u16", size: 2, read: &Binary.read_u16_be),
    IntReader(name: "u16", size: 2, read: &Binary.read_u16_le),
    IntReader(name: "i16", size: 2, read: &Binary.read_i16_be),
    IntReader(name: "i16", size: 2, read: &Binary.read_i16_le),
    IntReader(name: "u32", size: 4, read: &Binary.read_u32_be),
    IntReader(name: "u32", size: 4, read: &Binary.read_u32_le),
    IntReader(name: "i32", size: 4, read: &Binary.read_i32_be),
    IntReader(name: "i32", size: 4, read: &Binary.read_i32_le),
    IntReader(name: "u64", size: 8, read: &Binary.read_u64_be),
    IntReader(name: "u64", size: 8, read: &Binary.read_u64_le),
    IntReader(name: "i64", size: 8, read: &Binary.read_i64_be),
    IntReader(name: "i64", size: 8, read: &Binary.read_i64_le)
  ]
end

def writers() -> List[IntWriter]
  return [
    IntWriter(name: "u8", low: 0, high: 255, write: &Binary.write_u8),
    IntWriter(name: "i8", low: -128, high: 127, write: &Binary.write_i8),
    IntWriter(name: "u16", low: 0, high: 65535, write: &Binary.write_u16_be),
    IntWriter(name: "u16", low: 0, high: 65535, write: &Binary.write_u16_le),
    IntWriter(name: "i16", low: -32768, high: 32767, write: &Binary.write_i16_be),
    IntWriter(name: "i16", low: -32768, high: 32767, write: &Binary.write_i16_le),
    IntWriter(name: "u32", low: 0, high: 4294967295, write: &Binary.write_u32_be),
    IntWriter(name: "u32", low: 0, high: 4294967295, write: &Binary.write_u32_le),
    IntWriter(name: "i32", low: -2147483648, high: 2147483647, write: &Binary.write_i32_be),
    IntWriter(name: "i32", low: -2147483648, high: 2147483647, write: &Binary.write_i32_le)
  ]
end

def pairs() -> List[Pair]
  small = [0, 1, 127]
  return [
    Pair(name: "u8", size: 1, write: &Binary.write_u8, read: &Binary.read_u8, values: [0, 1, 127, 128, 255]),
    Pair(name: "i8", size: 1, write: &Binary.write_i8, read: &Binary.read_i8, values: [-128, -1, 0, 1, 127]),
    Pair(name: "u16_be", size: 2, write: &Binary.write_u16_be, read: &Binary.read_u16_be, values: [0, 1, 513, 32768, 65535]),
    Pair(name: "u16_le", size: 2, write: &Binary.write_u16_le, read: &Binary.read_u16_le, values: [0, 1, 513, 32768, 65535]),
    Pair(name: "i16_be", size: 2, write: &Binary.write_i16_be, read: &Binary.read_i16_be, values: [-32768, -2, -1, 0, 1, 32767]),
    Pair(name: "i16_le", size: 2, write: &Binary.write_i16_le, read: &Binary.read_i16_le, values: [-32768, -2, -1, 0, 1, 32767]),
    Pair(name: "u32_be", size: 4, write: &Binary.write_u32_be, read: &Binary.read_u32_be, values: [0, 1, 16909060, 2147483648, 4294967295]),
    Pair(name: "u32_le", size: 4, write: &Binary.write_u32_le, read: &Binary.read_u32_le, values: [0, 1, 16909060, 2147483648, 4294967295]),
    Pair(name: "i32_be", size: 4, write: &Binary.write_i32_be, read: &Binary.read_i32_be, values: [-2147483648, -1, 0, 1, 2147483647]),
    Pair(name: "i32_le", size: 4, write: &Binary.write_i32_le, read: &Binary.read_i32_le, values: [-2147483648, -1, 0, 1, 2147483647]),
    Pair(name: "u64_be", size: 8, write: &Binary.write_u64_be, read: &Binary.read_u64_be, values: [0, 1, 72623859790382856, 4294967296, 9223372036854775807]),
    Pair(name: "u64_le", size: 8, write: &Binary.write_u64_le, read: &Binary.read_u64_le, values: [0, 1, 72623859790382856, 4294967296, 9223372036854775807]),
    Pair(name: "i64_be", size: 8, write: &write_i64_be, read: &Binary.read_i64_be, values: [int_min(), -1, 0, 1, 72623859790382856, 9223372036854775807]),
    Pair(name: "i64_le", size: 8, write: &write_i64_le, read: &Binary.read_i64_le, values: [int_min(), -1, 0, 1, 72623859790382856, 9223372036854775807])
  ]
end

def int_result_text(result: Result[Int]) -> String
  case result
    ok(value) -> return "ok(#{value})"
    error(message) -> return "error(#{message})"
  end
end

def float_result_text(result: Result[Float]) -> String
  case result
    ok(value) -> return "ok(#{float_text(value)})"
    error(message) -> return "error(#{message})"
  end
end

def bytes_result_text(result: Result[List[Int]]) -> String
  case result
    ok(bytes) -> return "ok(#{bytes_text(bytes)})"
    error(message) -> return "error(#{message})"
  end
end

def bytes_text(bytes: List[Int]) -> String
  return "[#{bytes.map do |b| b.to_s end.join(", ")}]"
end

def float_text(x: Float) -> String
  if x != x
    return "nan"
  end
  return x.to_s
end

def expect(label: String, got: String, want: String) -> Int
  if got == want
    return 0
  end
  puts("mismatch: #{label}: got #{got}, want #{want}")
  return 1
end

def infinity() -> Float
  x = 10.0
  i = 0
  while i < 9
    x = x * x
    i += 1
  end
  return x
end

def pow2(exponent: Int) -> Float
  base = 2.0
  n = exponent
  if exponent < 0
    base = 0.5
    n = 0 - exponent
  end
  result = 1.0
  while n > 0
    if n % 2 == 1
      result = result * base
    end
    n = n / 2
    if n > 0
      base = base * base
    end
  end
  return result
end

def unwrap_bytes(result: Result[List[Int]]) -> List[Int]
  return result.unwrap!
end

def round_trip_ints() -> Int
  failed = 0
  checked = 0
  for pair in pairs()
    for value in pair.values
      bytes = unwrap_bytes(pair.write.call(value))
      failed += expect("#{pair.name} #{value} size", bytes.size.to_s, pair.size.to_s)
      failed += expect("#{pair.name} #{value} read", int_result_text(pair.read.call(bytes, 0)), "ok(#{value})")
      back = pair.read.call(bytes, 0).unwrap!
      failed += expect("#{pair.name} #{value} write", bytes_result_text(pair.write.call(back)), "ok(#{bytes_text(bytes)})")
      checked += 1
    end
  end
  puts("int round trips: #{checked} values, #{failed} mismatches")
  return failed
end

def byte_patterns() -> List[List[Int]]
  return [
    [0, 0, 0, 0, 0, 0, 0, 0],
    [1, 2, 3, 4, 5, 6, 7, 8],
    [127, 255, 255, 255, 255, 255, 255, 255],
    [128, 0, 0, 0, 0, 0, 0, 1],
    [255, 255, 255, 255, 255, 255, 255, 255],
    [0, 255, 0, 255, 0, 255, 0, 255],
    [254, 253, 252, 251, 250, 249, 248, 247]
  ]
end

def round_trip_bytes() -> Int
  failed = 0
  checked = 0
  for pair in pairs()
    for pattern in byte_patterns()
      bytes = List.take(pattern, pair.size)
      value = pair.read.call(bytes, 0)
      case value
        ok(v) ->
          failed += expect("#{pair.name} #{bytes_text(bytes)} write", bytes_result_text(pair.write.call(v)), "ok(#{bytes_text(bytes)})")
          checked += 1
        error(message) ->
          failed += expect("#{pair.name} #{bytes_text(bytes)} error", message, "u64 at offset 0 does not fit in Int")
      end
    end
  end
  puts("byte round trips: #{checked} patterns, #{failed} mismatches")
  return failed
end

def round_trip_floats() -> Int
  failed = 0
  inf = infinity()
  values = [0.0, (0.0 - 1.0) * 0.0, 1.0, -1.5, 0.1, 3.14159, pow2(1000), 0.0 - inf, inf, inf - inf, pow2(-1074), pow2(-1022), pow2(1023), pow2(-149), pow2(127)]
  for x in values
    wide = Binary.write_f64_be(x)
    failed += expect("f64_be #{float_text(x)}", float_result_text(Binary.read_f64_be(wide, 0)), "ok(#{float_text(x)})")
    little = Binary.write_f64_le(x)
    failed += expect("f64_le #{float_text(x)}", float_result_text(Binary.read_f64_le(little, 0)), "ok(#{float_text(x)})")
    failed += expect("f64 order #{float_text(x)}", bytes_text(wide), bytes_text(little.reverse))
    narrow = Binary.write_f32_be(x)
    narrow_le = Binary.write_f32_le(x)
    failed += expect("f32 order #{float_text(x)}", bytes_text(narrow), bytes_text(narrow_le.reverse))
    rounded = Binary.read_f32_be(narrow, 0).unwrap!
    failed += expect("f32_be #{float_text(x)}", bytes_text(Binary.write_f32_be(rounded)), bytes_text(narrow))
    failed += expect("f32_le #{float_text(x)}", float_result_text(Binary.read_f32_le(narrow_le, 0)), "ok(#{float_text(rounded)})")
  end
  failed += expect("f32 exact 1.5", float_result_text(Binary.read_f32_be(Binary.write_f32_be(1.5), 0)), "ok(1.5)")
  failed += expect("f32 exact -0.0", float_result_text(Binary.read_f32_be(Binary.write_f32_be((0.0 - 1.0) * 0.0), 0)), "ok(-0.0)")
  puts("float round trips: #{values.size} values, #{failed} mismatches")
  return failed
end

def float_bytes_back() -> Void
  puts(bytes_text(Binary.write_f64_be(Binary.read_f64_be([127, 248, 0, 0, 0, 0, 0, 1], 0).unwrap!)))
  puts(bytes_text(Binary.write_f64_le(Binary.read_f64_le([1, 0, 0, 0, 0, 0, 248, 255], 0).unwrap!)))
  puts(bytes_text(Binary.write_f32_be(Binary.read_f32_be([127, 192, 0, 1], 0).unwrap!)))
  puts(bytes_text(Binary.write_f32_le(Binary.read_f32_le([1, 0, 192, 255], 0).unwrap!)))
  puts(bytes_text(Binary.write_f64_be(Binary.read_f64_be([127, 240, 0, 0, 0, 0, 0, 0], 0).unwrap!)))
  puts(bytes_text(Binary.write_f32_le(Binary.read_f32_le([255, 255, 127, 255], 0).unwrap!)))
end

def offset_errors() -> Int
  failed = 0
  checked = 0
  data = List.repeat(0, 12)
  for reader in readers()
    last = data.size - reader.size
    failed += expect("#{reader.name} last offset", int_result_text(reader.read.call(data, last)), "ok(0)")
    for offset in [-1, last + 1, int_min(), 9223372036854775807]
      want = "error(#{reader.name} at offset #{offset} is outside a list of length 12)"
      failed += expect("#{reader.name} offset #{offset}", int_result_text(reader.read.call(data, offset)), want)
      checked += 1
    end
    failed += expect("#{reader.name} empty", int_result_text(reader.read.call([], 0)), "error(#{reader.name} at offset 0 is outside a list of length 0)")
  end
  for name in ["f32", "f64"]
    size = 4
    if name == "f64"
      size = 8
    end
    for offset in [-1, data.size - size + 1, int_min(), 9223372036854775807]
      want = "error(#{name} at offset #{offset} is outside a list of length 12)"
      if name == "f32"
        failed += expect("f32_be offset #{offset}", float_result_text(Binary.read_f32_be(data, offset)), want)
        failed += expect("f32_le offset #{offset}", float_result_text(Binary.read_f32_le(data, offset)), want)
      else
        failed += expect("f64_be offset #{offset}", float_result_text(Binary.read_f64_be(data, offset)), want)
        failed += expect("f64_le offset #{offset}", float_result_text(Binary.read_f64_le(data, offset)), want)
      end
      checked += 2
    end
  end
  puts("offset errors: #{checked} checks, #{failed} mismatches")
  puts(int_result_text(Binary.read_u32_be(data, 10)))
  puts(int_result_text(Binary.read_i16_le(data, -1)))
  puts(float_result_text(Binary.read_f64_be(data, 5)))
  return failed
end

def item_errors() -> Int
  failed = 0
  for bad in [-1, 256, 300, int_min(), 9223372036854775807]
    data = [0, 0, 0, bad, 0, 0, 0, 0, 0, 0, 0, 0]
    for reader in readers()
      want = "error(value #{bad} at index 3 is not a byte)"
      if reader.size >= 4
        failed += expect("#{reader.name} item #{bad}", int_result_text(reader.read.call(data, 0)), want)
      end
      failed += expect("#{reader.name} item #{bad} outside", int_result_text(reader.read.call(data, 4)).starts_with?("ok(").to_s, "true")
    end
    failed += expect("f32 item #{bad}", float_result_text(Binary.read_f32_le(data, 1)), "error(value #{bad} at index 3 is not a byte)")
    failed += expect("f64 item #{bad}", float_result_text(Binary.read_f64_be(data, 3)), "error(value #{bad} at index 3 is not a byte)")
  end
  first = [0, 0, 300, 0, -1, 0, 0, 0, 0, 0, 0, 0]
  failed += expect("first bad by index", int_result_text(Binary.read_u64_be(first, 0)), "error(value 300 at index 2 is not a byte)")
  failed += expect("first bad by index from 3", int_result_text(Binary.read_u64_le(first, 3)), "error(value -1 at index 4 is not a byte)")
  failed += expect("u8 bad", int_result_text(Binary.read_u8([256], 0)), "error(value 256 at index 0 is not a byte)")
  failed += expect("i8 bad", int_result_text(Binary.read_i8([0, -1], 1)), "error(value -1 at index 1 is not a byte)")
  failed += expect("masked pair", int_result_text(Binary.read_u16_be([-1, 256], 0)), "error(value -1 at index 0 is not a byte)")
  failed += expect("offset wins over item", int_result_text(Binary.read_u16_be([300], 0)), "error(u16 at offset 0 is outside a list of length 1)")
  puts(int_result_text(Binary.read_u32_be([0, 1, 300, 0, 0, 0], 1)))
  puts(int_result_text(Binary.read_i16_be([0, 0, 0, 0, -7, 0], 4)))
  puts("item errors: #{failed} mismatches")
  return failed
end

def writer_errors() -> Int
  failed = 0
  for writer in writers()
    low = writer.write.call(writer.low)
    high = writer.write.call(writer.high)
    failed += expect("#{writer.name} low ok", low.ok?.to_s, "true")
    failed += expect("#{writer.name} high ok", high.ok?.to_s, "true")
    below = writer.low - 1
    above = writer.high + 1
    failed += expect("#{writer.name} below", bytes_result_text(writer.write.call(below)), "error(value #{below} does not fit in #{writer.name})")
    failed += expect("#{writer.name} above", bytes_result_text(writer.write.call(above)), "error(value #{above} does not fit in #{writer.name})")
    failed += expect("#{writer.name} smallest Int", bytes_result_text(writer.write.call(int_min())), "error(value #{int_min()} does not fit in #{writer.name})")
    failed += expect("#{writer.name} largest Int", bytes_result_text(writer.write.call(9223372036854775807)), "error(value 9223372036854775807 does not fit in #{writer.name})")
  end
  failed += expect("u64 negative", bytes_result_text(Binary.write_u64_be(-1)), "error(value -1 does not fit in u64)")
  failed += expect("u64 smallest Int", bytes_result_text(Binary.write_u64_le(int_min())), "error(value #{int_min()} does not fit in u64)")
  failed += expect("u64 largest Int", bytes_result_text(Binary.write_u64_be(9223372036854775807)), "ok([127, 255, 255, 255, 255, 255, 255, 255])")
  puts(bytes_result_text(Binary.write_u16_be(70000)))
  puts(bytes_result_text(Binary.write_i8(-129)))
  puts(bytes_result_text(Binary.write_u64_le(-1)))
  puts("writer errors: #{failed} mismatches")
  return failed
end

def top_bit() -> Int
  failed = 0
  failed += expect("u64_be top bit", int_result_text(Binary.read_u64_be([128, 0, 0, 0, 0, 0, 0, 0], 0)), "error(u64 at offset 0 does not fit in Int)")
  failed += expect("u64_le top bit", int_result_text(Binary.read_u64_le([0, 0, 0, 0, 0, 0, 0, 128], 0)), "error(u64 at offset 0 does not fit in Int)")
  failed += expect("u64_be offset", int_result_text(Binary.read_u64_be([1, 255, 255, 255, 255, 255, 255, 255, 255], 1)), "error(u64 at offset 1 does not fit in Int)")
  failed += expect("i64_be same bytes", int_result_text(Binary.read_i64_be([128, 0, 0, 0, 0, 0, 0, 0], 0)), "ok(#{int_min()})")
  failed += expect("i64_le all ones", int_result_text(Binary.read_i64_le([255, 255, 255, 255, 255, 255, 255, 255], 0)), "ok(-1)")
  puts(int_result_text(Binary.read_u64_be([255, 255, 255, 255, 255, 255, 255, 255], 0)))
  puts(int_result_text(Binary.read_i64_be([255, 255, 255, 255, 255, 255, 255, 255], 0)))
  puts("top bit: #{failed} mismatches")
  return failed
end

def joined(parts: List[List[Int]]) -> List[Int]
  initial: List[Int] = []
  return parts.reduce(initial) do |acc, part| List.concat(acc, part) end
end

def concat_cases() -> Int
  failed = 0
  none: List[List[Int]] = []
  failed += expect("concat of none", bytes_text(Binary.concat(none)), "[]")
  failed += expect("concat of one", bytes_text(Binary.concat([[1, 2, 3]])), "[1, 2, 3]")
  failed += expect("concat of empty", bytes_text(Binary.concat([[]])), "[]")
  failed += expect("concat of two", bytes_text(Binary.concat([[1], [2, 3]])), "[1, 2, 3]")
  failed += expect("concat of three", bytes_text(Binary.concat([[1], [], [2, 3]])), "[1, 2, 3]")
  failed += expect("concat of empties", bytes_text(Binary.concat([[], [], [], []])), "[]")
  failed += expect("concat of five", bytes_text(Binary.concat([[1], [2], [], [3, 4], [5]])), "[1, 2, 3, 4, 5]")
  parts: List[List[Int]] = []
  for i in 0...1000
    if i % 7 == 3
      parts = parts.push([])
    else
      parts = parts.push([i % 256, (i + 1) % 256])
    end
  end
  many = Binary.concat(parts)
  failed += expect("concat of many", bytes_text(many), bytes_text(joined(parts)))
  failed += expect("concat of many size", many.size.to_s, joined(parts).size.to_s)
  puts("concat: #{many.size} bytes from #{parts.size} parts, #{failed} mismatches")
  return failed
end

def frame_cases() -> Int
  failed = 0
  failed += expect("frame empty", bytes_result_text(Binary.frame([])), "ok([0, 0, 0, 0])")
  failed += expect("frame three", bytes_result_text(Binary.frame([7, 8, 9])), "ok([0, 0, 0, 3, 7, 8, 9])")
  payload = Binary.concat([Binary.write_u16_be(513).unwrap!, Binary.write_f64_le(1.5)])
  framed = Binary.frame(payload).unwrap!
  failed += expect("frame length", int_result_text(Binary.read_frame_length(framed, 0, payload.size)), "ok(#{payload.size})")
  failed += expect("frame body", bytes_text(List.drop(framed, 4)), bytes_text(payload))
  shifted = Binary.concat([[9, 9], framed])
  failed += expect("frame at offset", int_result_text(Binary.read_frame_length(shifted, 2, 65536)), "ok(10)")
  failed += expect("frame odd items", bytes_result_text(Binary.frame([300, -1])), "ok([0, 0, 0, 2, 300, -1])")
  failed += expect("limit equal", int_result_text(Binary.read_frame_length([0, 1, 17, 112], 0, 70000)), "ok(70000)")
  failed += expect("limit zero", int_result_text(Binary.read_frame_length([0, 0, 0, 0], 0, 0)), "ok(0)")
  failed += expect("limit above", int_result_text(Binary.read_frame_length([0, 1, 17, 112], 0, 65536)), "error(frame length 70000 is above the limit 65536)")
  failed += expect("limit negative", int_result_text(Binary.read_frame_length([0, 0, 0, 1], 0, -1)), "error(frame limit -1 is negative)")
  failed += expect("limit negative first", int_result_text(Binary.read_frame_length([], -5, -2)), "error(frame limit -2 is negative)")
  failed += expect("limit smallest Int", int_result_text(Binary.read_frame_length([0, 0, 0, 1], 0, int_min())), "error(frame limit #{int_min()} is negative)")
  failed += expect("offset before limit", int_result_text(Binary.read_frame_length([0, 0, 1], 0, 5)), "error(u32 at offset 0 is outside a list of length 3)")
  failed += expect("offset before limit at max", int_result_text(Binary.read_frame_length([0, 0, 0, 1], 1, 9223372036854775807)), "error(u32 at offset 1 is outside a list of length 4)")
  failed += expect("item before limit", int_result_text(Binary.read_frame_length([0, 300, 0, 0], 0, 5)), "error(value 300 at index 1 is not a byte)")
  failed += expect("largest limit", int_result_text(Binary.read_frame_length([255, 255, 255, 255], 0, 9223372036854775807)), "ok(4294967295)")
  puts(int_result_text(Binary.read_frame_length([0, 1, 17, 112], 0, 65536)))
  puts(int_result_text(Binary.read_frame_length([0, 0, 0, 1], 0, -1)))
  puts("frames: #{failed} mismatches")
  return failed
end

def main() -> Void
  failed = round_trip_ints()
  failed += round_trip_bytes()
  failed += round_trip_floats()
  float_bytes_back()
  failed += offset_errors()
  failed += item_errors()
  failed += writer_errors()
  failed += top_bit()
  failed += concat_cases()
  failed += frame_cases()
  if failed == 0
    puts("all checks ok")
  else
    puts("#{failed} checks failed")
  end
end
