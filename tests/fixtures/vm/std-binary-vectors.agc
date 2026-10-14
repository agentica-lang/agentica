import "std/binary" as Binary

struct Tables
  int_readers: Map[String, Fn[List[Int], Int, Result[Int]]]
  int_writers: Map[String, Fn[Int, Result[List[Int]]]]
  float_readers: Map[String, Fn[List[Int], Int, Result[Float]]]
  float_writers: Map[String, Fn[Float, List[Int]]]
end

def write_i64_be(value: Int) -> Result[List[Int]]
  return ok(Binary.write_i64_be(value))
end

def write_i64_le(value: Int) -> Result[List[Int]]
  return ok(Binary.write_i64_le(value))
end

def tables() -> Tables
  int_readers: Map[String, Fn[List[Int], Int, Result[Int]]] = {
    "u8_be": &Binary.read_u8, "u8_le": &Binary.read_u8, "i8_be": &Binary.read_i8, "i8_le": &Binary.read_i8,
    "u16_be": &Binary.read_u16_be, "u16_le": &Binary.read_u16_le, "i16_be": &Binary.read_i16_be, "i16_le": &Binary.read_i16_le,
    "u32_be": &Binary.read_u32_be, "u32_le": &Binary.read_u32_le, "i32_be": &Binary.read_i32_be, "i32_le": &Binary.read_i32_le,
    "u64_be": &Binary.read_u64_be, "u64_le": &Binary.read_u64_le, "i64_be": &Binary.read_i64_be, "i64_le": &Binary.read_i64_le
  }
  int_writers: Map[String, Fn[Int, Result[List[Int]]]] = {
    "u8_be": &Binary.write_u8, "u8_le": &Binary.write_u8, "i8_be": &Binary.write_i8, "i8_le": &Binary.write_i8,
    "u16_be": &Binary.write_u16_be, "u16_le": &Binary.write_u16_le, "i16_be": &Binary.write_i16_be, "i16_le": &Binary.write_i16_le,
    "u32_be": &Binary.write_u32_be, "u32_le": &Binary.write_u32_le, "i32_be": &Binary.write_i32_be, "i32_le": &Binary.write_i32_le,
    "u64_be": &Binary.write_u64_be, "u64_le": &Binary.write_u64_le, "i64_be": &write_i64_be, "i64_le": &write_i64_le
  }
  float_readers: Map[String, Fn[List[Int], Int, Result[Float]]] = {
    "f32_be": &Binary.read_f32_be, "f32_le": &Binary.read_f32_le, "f64_be": &Binary.read_f64_be, "f64_le": &Binary.read_f64_le
  }
  float_writers: Map[String, Fn[Float, List[Int]]] = {
    "f32_be": &Binary.write_f32_be, "f32_le": &Binary.write_f32_le, "f64_be": &Binary.write_f64_be, "f64_le": &Binary.write_f64_le
  }
  return Tables(int_readers: int_readers, int_writers: int_writers, float_readers: float_readers, float_writers: float_writers)
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
  return Float.from_int(parts[0].to_i!) * pow2(parts[1].to_i!)
end

def float_text(x: Float) -> String
  if x != x
    return "nan"
  end
  return x.to_s
end

def bytes_of(field: String) -> List[Int]
  if field == "-"
    return []
  end
  return field.split(",").map do |part| part.to_i! end
end

def bytes_text(bytes: List[Int]) -> String
  return bytes.map do |b| b.to_s end.join(",")
end

def int_result_text(result: Result[Int]) -> String
  case result
    ok(value) -> return value.to_s
    error(message) -> return "error: #{message}"
  end
end

def float_result_text(result: Result[Float]) -> String
  case result
    ok(value) -> return float_text(value)
    error(message) -> return "error: #{message}"
  end
end

def bytes_result_text(result: Result[List[Int]]) -> String
  case result
    ok(bytes) -> return bytes_text(bytes)
    error(message) -> return "error: #{message}"
  end
end

def report(line: String, got: String, want: String) -> Int
  if got == want
    return 0
  end
  puts("mismatch: #{line}: got #{got}, want #{want}")
  return 1
end

def padded(bytes: List[Int]) -> List[Int]
  return Binary.concat([[170], bytes, [187]])
end

def check_int(t: Tables, line: String, f: List[String]) -> Int
  key = "#{f[1]}_#{f[2]}"
  value = f[3].to_i!
  bytes = bytes_of(f[4])
  failed = report(line, bytes_result_text(t.int_writers[key].call(value)), f[4])
  failed += report(line, int_result_text(t.int_readers[key].call(bytes, 0)), f[3])
  failed += report(line, int_result_text(t.int_readers[key].call(padded(bytes), 1)), f[3])
  return failed
end

def check_write_error(t: Tables, line: String, f: List[String]) -> Int
  key = "#{f[1]}_#{f[2]}"
  return report(line, bytes_result_text(t.int_writers[key].call(f[3].to_i!)), "error: value #{f[3]} does not fit in #{f[1]}")
end

def check_u64_top_bit(t: Tables, line: String, f: List[String]) -> Int
  key = "u64_#{f[1]}"
  return report(line, int_result_text(t.int_readers[key].call(bytes_of(f[2]), 0)), "error: u64 at offset 0 does not fit in Int")
end

def check_float_write(t: Tables, line: String, f: List[String]) -> Int
  key = "#{f[1]}_#{f[2]}"
  return report(line, bytes_text(t.float_writers[key].call(float_of(f[3]))), f[4])
end

def check_float_read(t: Tables, line: String, f: List[String]) -> Int
  key = "#{f[1]}_#{f[2]}"
  bytes = bytes_of(f[3])
  failed = report(line, float_result_text(t.float_readers[key].call(bytes, 0)), float_text(float_of(f[4])))
  failed += report(line, float_result_text(t.float_readers[key].call(padded(bytes), 1)), float_text(float_of(f[4])))
  return failed
end

def check_frame(line: String, f: List[String]) -> Int
  return report(line, bytes_result_text(Binary.frame(bytes_of(f[1]))), f[2])
end

def check_frame_length(line: String, f: List[String]) -> Int
  max = f[2].to_i!
  want = f[3]
  if want == "neg"
    want = "error: frame limit #{max} is negative"
  elsif want.starts_with?("above:")
    want = "error: frame length #{want.split(":")[1]} is above the limit #{max}"
  end
  return report(line, int_result_text(Binary.read_frame_length(bytes_of(f[1]), 0, max)), want)
end

def check(t: Tables, line: String) -> Int
  f = line.split(" ")
  kind = f[0]
  if kind == "int"
    return check_int(t, line, f)
  elsif kind == "werr"
    return check_write_error(t, line, f)
  elsif kind == "rerr64"
    return check_u64_top_bit(t, line, f)
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
  return 1
end

def main() -> Void
  IO.gets()
  t = tables()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(t, line)
        count += 1
      error(message) ->
        running = false
    end
  end
  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
