import Binary from "std/binary"

struct Tables
  int_readers: Map[String, Fn[Bytes, Int, Result[String]]]
  int_writers: Map[String, Fn[String, Bytes]]
  float_readers: Map[String, Fn[Bytes, Int, Result[Float]]]
  float_writers: Map[String, Fn[Float, Bytes]]
end

## The UInt64 of a decimal text, which has no parser of its own.
def uint64_of(text: String) -> UInt64
  text.bytes.to_a.reduce(0.to_uint64!) do |acc: UInt64, digit: Int| acc * 10 + (digit - 48).to_uint64! end
end

def read_u8_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u8(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u8_be(text: String) -> Bytes = Binary.write_u8(text.to_i!.to_uint8!)

def read_u8_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u8(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u8_le(text: String) -> Bytes = Binary.write_u8(text.to_i!.to_uint8!)

def read_i8_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i8(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i8_be(text: String) -> Bytes = Binary.write_i8(text.to_i!.to_int8!)

def read_i8_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i8(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i8_le(text: String) -> Bytes = Binary.write_i8(text.to_i!.to_int8!)

def read_u16_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u16_be(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u16_be(text: String) -> Bytes = Binary.write_u16_be(text.to_i!.to_uint16!)

def read_u16_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u16_le(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u16_le(text: String) -> Bytes = Binary.write_u16_le(text.to_i!.to_uint16!)

def read_i16_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i16_be(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i16_be(text: String) -> Bytes = Binary.write_i16_be(text.to_i!.to_int16!)

def read_i16_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i16_le(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i16_le(text: String) -> Bytes = Binary.write_i16_le(text.to_i!.to_int16!)

def read_u32_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u32_be(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u32_be(text: String) -> Bytes = Binary.write_u32_be(text.to_i!.to_uint32!)

def read_u32_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u32_le(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u32_le(text: String) -> Bytes = Binary.write_u32_le(text.to_i!.to_uint32!)

def read_i32_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i32_be(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i32_be(text: String) -> Bytes = Binary.write_i32_be(text.to_i!.to_int32!)

def read_i32_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i32_le(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i32_le(text: String) -> Bytes = Binary.write_i32_le(text.to_i!.to_int32!)

def read_u64_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u64_be(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u64_be(text: String) -> Bytes = Binary.write_u64_be(uint64_of(text))

def read_u64_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_u64_le(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_u64_le(text: String) -> Bytes = Binary.write_u64_le(uint64_of(text))

def read_i64_be(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i64_be(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i64_be(text: String) -> Bytes = Binary.write_i64_be(text.to_i!)

def read_i64_le(data: Bytes, offset: Int) -> Result[String]
  case Binary.read_i64_le(data, offset)
    ok(value) -> ok("#{value}")
    error(message) -> error(message)
  end
end

def write_i64_le(text: String) -> Bytes = Binary.write_i64_le(text.to_i!)

def tables() -> Tables
  int_readers: Map[String, Fn[Bytes, Int, Result[String]]] = {
    "u8_be": &read_u8_be, "u8_le": &read_u8_le, "i8_be": &read_i8_be, "i8_le": &read_i8_le, "u16_be": &read_u16_be,
    "u16_le": &read_u16_le, "i16_be": &read_i16_be, "i16_le": &read_i16_le, "u32_be": &read_u32_be,
    "u32_le": &read_u32_le, "i32_be": &read_i32_be, "i32_le": &read_i32_le, "u64_be": &read_u64_be,
    "u64_le": &read_u64_le, "i64_be": &read_i64_be, "i64_le": &read_i64_le,
  }

  int_writers: Map[String, Fn[String, Bytes]] = {
    "u8_be": &write_u8_be, "u8_le": &write_u8_le, "i8_be": &write_i8_be, "i8_le": &write_i8_le,
    "u16_be": &write_u16_be, "u16_le": &write_u16_le, "i16_be": &write_i16_be, "i16_le": &write_i16_le,
    "u32_be": &write_u32_be, "u32_le": &write_u32_le, "i32_be": &write_i32_be, "i32_le": &write_i32_le,
    "u64_be": &write_u64_be, "u64_le": &write_u64_le, "i64_be": &write_i64_be, "i64_le": &write_i64_le,
  }

  float_readers: Map[String, Fn[Bytes, Int, Result[Float]]] = {
    "f32_be": &Binary.read_f32_be, "f32_le": &Binary.read_f32_le, "f64_be": &Binary.read_f64_be,
    "f64_le": &Binary.read_f64_le,
  }

  float_writers: Map[String, Fn[Float, Bytes]] = {
    "f32_be": &Binary.write_f32_be, "f32_le": &Binary.write_f32_le, "f64_be": &Binary.write_f64_be,
    "f64_le": &Binary.write_f64_le,
  }

  Tables(
    int_readers: int_readers,
    int_writers: int_writers,
    float_readers: float_readers,
    float_writers: float_writers,
  )
end

def infinity() -> Float
  x = 10.0
  i = 0
  while i < 9
    x = x * x
    i += 1
  end
  x
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
  result
end

def float_of(field: String) -> Float
  if field == "inf"
    return infinity()
  elsif field == "-inf"
    return 0.0 - infinity()
  elsif field == "nan"
    return infinity() - infinity()
  elsif field == "-0"
    return (0.0 - 1.0) * 0.0
  end
  parts = field.split("p")
  parts[0].to_i!.to_f * pow2(parts[1].to_i!)
end

def float_text(x: Float) -> String
  return "nan" if x != x
  x.to_s
end

def bytes_of(field: String) -> Bytes
  return "".bytes if field == "-"
  Bytes.from_list(field.split(",").map do |part| part.to_i! end).unwrap!
end

def bytes_text(bytes: Bytes) -> String = bytes.to_a.map { |b| b.to_s }.join(",")

def int_result_text(result: Result[String]) -> String
  case result
    ok(value) -> value
    error(message) -> "error: #{message}"
  end
end

def float_result_text(result: Result[Float]) -> String
  case result
    ok(value) -> float_text(value)
    error(message) -> "error: #{message}"
  end
end

def bytes_result_text(result: Result[Bytes]) -> String
  case result
    ok(bytes) -> bytes_text(bytes)
    error(message) -> "error: #{message}"
  end
end

def length_result_text(result: Result[Int]) -> String
  case result
    ok(value) -> value.to_s
    error(message) -> "error: #{message}"
  end
end

def report(line: String, got: String, want: String) -> Int
  return 0 if got == want
  puts("mismatch: #{line}: got #{got}, want #{want}")
  1
end

def padded(bytes: Bytes) -> Bytes
  Bytes.concat([Bytes.from_list([170]).unwrap!, bytes, Bytes.from_list([187]).unwrap!])
end

def check_int(t: Tables, line: String, f: List[String]) -> Int
  key = "#{f[1]}_#{f[2]}"
  bytes = bytes_of(f[4])
  failed = report(line, bytes_text(t.int_writers[key].call(f[3])), f[4])
  failed += report(line, int_result_text(t.int_readers[key].call(bytes, 0)), f[3])
  failed += report(line, int_result_text(t.int_readers[key].call(padded(bytes), 1)), f[3])
  failed
end

def check_float_write(t: Tables, line: String, f: List[String]) -> Int
  key = "#{f[1]}_#{f[2]}"
  report(line, bytes_text(t.float_writers[key].call(float_of(f[3]))), f[4])
end

def check_float_read(t: Tables, line: String, f: List[String]) -> Int
  key = "#{f[1]}_#{f[2]}"
  bytes = bytes_of(f[3])
  failed = report(line, float_result_text(t.float_readers[key].call(bytes, 0)), float_text(float_of(f[4])))
  failed += report(line, float_result_text(t.float_readers[key].call(padded(bytes), 1)), float_text(float_of(f[4])))
  failed
end

def check_frame(line: String, f: List[String]) -> Int
  report(line, bytes_result_text(Binary.frame(bytes_of(f[1]))), f[2])
end

def check_frame_length(line: String, f: List[String]) -> Int
  max = f[2].to_i!
  want = f[3]
  if want == "neg"
    want = "error: frame limit #{max} is negative"
  elsif want.start_with?("above:")
    want = "error: frame length #{want.split(":")[1]} is above the limit #{max}"
  end
  report(line, length_result_text(Binary.read_frame_length(bytes_of(f[1]), 0, max)), want)
end

def check(t: Tables, line: String) -> Int
  f = line.split(" ")
  kind = f[0]
  if kind == "int"
    return check_int(t, line, f)
  elsif kind == "fwrite"
    return check_float_write(t, line, f)
  elsif kind == "fread"
    return check_float_read(t, line, f)
  elsif kind == "frame"
    return check_frame(line, f)
  elsif kind == "flen"
    return check_frame_length(line, f)
  end
  puts("mismatch: unknown vector: #{line}")
  1
end

def main() -> Void
  _ = IO.gets()
  t = tables()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(t, line)
        count += 1
      error(_) -> running = false
    end
  end
  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
