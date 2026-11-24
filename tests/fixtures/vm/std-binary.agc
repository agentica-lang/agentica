import Binary from "std/binary"

def int_min() -> Int = Int.bit_not(9223372036854775807)

def bytes_text(bytes: Bytes) -> String = "[#{bytes.to_a.map { |b| b.to_s }.join(", ")}]"

def pack(items: List[Int]) -> Bytes = Bytes.from_list(items).unwrap!

def expect(label: String, got: String, want: String) -> Int
  return 0 if got == want
  puts("mismatch: #{label}: got #{got}, want #{want}")
  1
end

def shown(label: String, text: String) -> Void
  puts("#{label}: #{text}")
end

def int_result_text(result: Result[Int]) -> String
  case result
    ok(value) -> "ok(#{value})"
    error(message) -> "error(#{message})"
  end
end

def float_result_text(result: Result[Float]) -> String
  case result
    ok(value) -> "ok(#{value})"
    error(message) -> "error(#{message})"
  end
end

def bytes_result_text(result: Result[Bytes]) -> String
  case result
    ok(bytes) -> "ok(#{bytes_text(bytes)})"
    error(message) -> "error(#{message})"
  end
end

## The readers give the type of their width, and the writers take it and never fail.
def typed_round_trips() -> Int
  failed = 0
  a: UInt8 = Binary.read_u8(pack([200]), 0).unwrap!
  b: Int8 = Binary.read_i8(pack([200]), 0).unwrap!
  c: UInt16 = Binary.read_u16_be(pack([1, 2]), 0).unwrap!
  d: Int16 = Binary.read_i16_le(pack([254, 255]), 0).unwrap!
  e: UInt32 = Binary.read_u32_le(pack([255, 255, 255, 255]), 0).unwrap!
  f: Int32 = Binary.read_i32_be(pack([128, 0, 0, 0]), 0).unwrap!
  g: UInt64 = Binary.read_u64_be(pack([255, 255, 255, 255, 255, 255, 255, 255]), 0).unwrap!
  h: Int = Binary.read_i64_le(pack([255, 255, 255, 255, 255, 255, 255, 255]), 0).unwrap!
  shown("typed", "#{a} #{b} #{c} #{d} #{e} #{f} #{g} #{h}")
  failed += expect("u8 write", bytes_text(Binary.write_u8(a)), "[200]")
  failed += expect("i8 write", bytes_text(Binary.write_i8(b)), "[200]")
  failed += expect("u16 write", bytes_text(Binary.write_u16_le(c)), "[2, 1]")
  failed += expect("i32 write", bytes_text(Binary.write_i32_le(f)), "[0, 0, 0, 128]")
  failed += expect("u64 write", bytes_text(Binary.write_u64_le(g)), "[255, 255, 255, 255, 255, 255, 255, 255]")
  failed += expect("u16 literal", bytes_text(Binary.write_u16_be(513)), "[2, 1]")
  failed += expect("u64 literal", bytes_text(Binary.write_u64_be(9223372036854775808)), "[128, 0, 0, 0, 0, 0, 0, 0]")
  failed += expect("i64 write", bytes_text(Binary.write_i64_be(int_min())), "[128, 0, 0, 0, 0, 0, 0, 0]")
  wide = Binary.read_u16_be(pack([1, 2]), 0).unwrap!.to_i + 1
  failed += expect("to_i", wide.to_s, "259")
  puts("typed: #{failed} mismatches")
  failed
end

## u64 keeps all 64 bits where i64 reads the same bytes as a negative number.
def top_bit() -> Int
  failed = 0
  top = pack([128, 0, 0, 0, 0, 0, 0, 0])
  failed += expect("u64_be", Binary.read_u64_be(top, 0).unwrap!.to_s, "9223372036854775808")
  failed += expect(
    "u64_le",
    Binary.read_u64_le(pack([1, 0, 0, 0, 0, 0, 0, 128]), 0).unwrap!.to_s,
    "9223372036854775809",
  )

  failed += expect(
    "u64 offset",
    Binary.read_u64_be(pack([1, 255, 255, 255, 255, 255, 255, 255, 255]), 1).unwrap!.to_s,
    "18446744073709551615",
  )

  failed += expect("i64 same bytes", int_result_text(Binary.read_i64_be(top, 0)), "ok(#{int_min()})")
  puts("top bit: #{failed} mismatches")
  failed
end

## A NaN keeps no payload, and -0.0 keeps its sign.
def float_edges() -> Int
  failed = 0
  failed += expect(
    "f64 nan",
    bytes_text(Binary.write_f64_be(Binary.read_f64_be(pack([127, 248, 0, 0, 0, 0, 0, 1]), 0).unwrap!)),
    "[127, 248, 0, 0, 0, 0, 0, 0]",
  )

  failed += expect(
    "f64 nan le",
    bytes_text(Binary.write_f64_le(Binary.read_f64_le(pack([1, 0, 0, 0, 0, 0, 248, 255]), 0).unwrap!)),
    "[0, 0, 0, 0, 0, 0, 248, 127]",
  )

  failed += expect(
    "f64 infinity",
    bytes_text(Binary.write_f64_be(Binary.read_f64_be(pack([127, 240, 0, 0, 0, 0, 0, 0]), 0).unwrap!)),
    "[127, 240, 0, 0, 0, 0, 0, 0]",
  )

  failed += expect(
    "f64 negative zero",
    bytes_text(Binary.write_f64_be(Binary.read_f64_be(pack([128, 0, 0, 0, 0, 0, 0, 0]), 0).unwrap!)),
    "[128, 0, 0, 0, 0, 0, 0, 0]",
  )

  failed += expect(
    "f64 subnormal",
    bytes_text(Binary.write_f64_le(Binary.read_f64_le(pack([1, 0, 0, 0, 0, 0, 0, 0]), 0).unwrap!)),
    "[1, 0, 0, 0, 0, 0, 0, 0]",
  )

  failed += expect(
    "f32 nan",
    bytes_text(Binary.write_f32_be(Binary.read_f32_be(pack([127, 192, 0, 1]), 0).unwrap!)),
    "[127, 192, 0, 0]",
  )

  failed += expect(
    "f32 le nan",
    bytes_text(Binary.write_f32_le(Binary.read_f32_le(pack([1, 0, 192, 255]), 0).unwrap!)),
    "[0, 0, 192, 127]",
  )

  failed += expect("f32 exact", float_result_text(Binary.read_f32_be(Binary.write_f32_be(1.5), 0)), "ok(1.5)")
  puts("float edges: #{failed} mismatches")
  failed
end

## Every reader reports an offset outside the data, with no other error.
def offset_errors() -> Int
  failed = 0
  data = pack([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  for offset in [-1, 11, int_min(), 9223372036854775807]
    failed += expect(
      "u32 #{offset}",
      Binary.read_u32_be(data, offset).message,
      "u32 at offset #{offset} is outside bytes of length 12",
    )

    failed += expect(
      "u64 #{offset}",
      Binary.read_u64_le(data, offset).message,
      "u64 at offset #{offset} is outside bytes of length 12",
    )

    failed += expect(
      "i16 #{offset}",
      Binary.read_i16_le(data, offset).message,
      "i16 at offset #{offset} is outside bytes of length 12",
    )

    failed += expect(
      "f64 #{offset}",
      Binary.read_f64_be(data, offset).message,
      "f64 at offset #{offset} is outside bytes of length 12",
    )
  end
  failed += expect("last u32", Binary.read_u32_be(data, 8).ok?.to_s, "true")
  failed += expect("empty", Binary.read_u8(pack([]), 0).message, "u8 at offset 0 is outside bytes of length 0")
  puts("offset errors: #{failed} mismatches")
  failed
end

def frame_cases() -> Int
  failed = 0
  failed += expect("frame empty", bytes_result_text(Binary.frame(pack([]))), "ok([0, 0, 0, 0])")
  failed += expect("frame three", bytes_result_text(Binary.frame(pack([7, 8, 9]))), "ok([0, 0, 0, 3, 7, 8, 9])")
  payload = Bytes.concat([Binary.write_u16_be(513), Binary.write_f64_le(1.5)])
  framed = Binary.frame(payload).unwrap!
  failed += expect(
    "frame length",
    int_result_text(Binary.read_frame_length(framed, 0, payload.size)),
    "ok(#{payload.size})",
  )

  failed += expect("frame body", bytes_text(framed.drop(4)), bytes_text(payload))
  shifted = Bytes.concat([pack([9, 9]), framed])
  failed += expect("frame at offset", int_result_text(Binary.read_frame_length(shifted, 2, 65536)), "ok(10)")
  failed += expect(
    "limit equal",
    int_result_text(Binary.read_frame_length(pack([0, 1, 17, 112]), 0, 70000)),
    "ok(70000)",
  )

  failed += expect("limit zero", int_result_text(Binary.read_frame_length(pack([0, 0, 0, 0]), 0, 0)), "ok(0)")
  failed += expect(
    "limit above",
    int_result_text(Binary.read_frame_length(pack([0, 1, 17, 112]), 0, 65536)),
    "error(frame length 70000 is above the limit 65536)",
  )

  failed += expect(
    "limit negative",
    int_result_text(Binary.read_frame_length(pack([0, 0, 0, 1]), 0, -1)),
    "error(frame limit -1 is negative)",
  )

  failed += expect(
    "limit negative first",
    int_result_text(Binary.read_frame_length(pack([]), -5, -2)),
    "error(frame limit -2 is negative)",
  )

  failed += expect(
    "limit smallest Int",
    int_result_text(Binary.read_frame_length(pack([0, 0, 0, 1]), 0, int_min())),
    "error(frame limit #{int_min()} is negative)",
  )

  failed += expect(
    "offset before limit",
    int_result_text(Binary.read_frame_length(pack([0, 0, 1]), 0, 5)),
    "error(u32 at offset 0 is outside bytes of length 3)",
  )

  failed += expect(
    "offset before limit at max",
    int_result_text(Binary.read_frame_length(pack([0, 0, 0, 1]), 1, 9223372036854775807)),
    "error(u32 at offset 1 is outside bytes of length 4)",
  )

  failed += expect(
    "largest limit",
    int_result_text(Binary.read_frame_length(pack([255, 255, 255, 255]), 0, 9223372036854775807)),
    "ok(4294967295)",
  )

  puts(int_result_text(Binary.read_frame_length(pack([0, 1, 17, 112]), 0, 65536)))
  puts(int_result_text(Binary.read_frame_length(pack([0, 0, 0, 1]), 0, -1)))
  puts("frames: #{failed} mismatches")
  failed
end

def main() -> Void
  failed = typed_round_trips()
  failed += top_bit()
  failed += float_edges()
  failed += offset_errors()
  failed += frame_cases()
  if failed == 0
    puts("all checks ok")
  else
    puts("#{failed} checks failed")
  end
end
