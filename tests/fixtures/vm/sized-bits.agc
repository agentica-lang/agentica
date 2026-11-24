# The vectors of tests/fixtures/sized-bits.py (Python ints), read from stdin: the bit and wrapping
# methods, Int.wrap_<type>
# and the widenings of each integer type. The functions of each type are written out below because a method of one type
# does not take another. A negative shift count halts: the fixture sized-shift-negative.

def bits_int8(a: Int, b: Int) -> List[String]
  x = a.to_int8!
  y = b.to_int8!
  [
    x.bit_and(y).to_i.to_s,
    x.bit_or(y).to_i.to_s,
    x.bit_xor(y).to_i.to_s,
    x.wrapping_add(y).to_i.to_s,
    x.wrapping_sub(y).to_i.to_s,
    x.wrapping_mul(y).to_i.to_s,
  ]
end

def shift_int8(a: Int, count: Int) -> List[String]
  x = a.to_int8!
  [x.shift_left(count).to_i.to_s, x.shift_right(count).to_i.to_s, x.shift_right_unsigned(count).to_i.to_s]
end

def not_int8(a: Int) -> String
  x = a.to_int8!
  x.bit_not.to_i.to_s
end

def wrap_int8(n: Int) -> String = n.wrap_int8.to_i.to_s

def widen_int8(a: Int) -> List[String]
  x = a.to_int8!
  [x.to_int16.to_i.to_s, x.to_int32.to_i.to_s, x.to_f.to_s]
end

def bits_int16(a: Int, b: Int) -> List[String]
  x = a.to_int16!
  y = b.to_int16!
  [
    x.bit_and(y).to_i.to_s,
    x.bit_or(y).to_i.to_s,
    x.bit_xor(y).to_i.to_s,
    x.wrapping_add(y).to_i.to_s,
    x.wrapping_sub(y).to_i.to_s,
    x.wrapping_mul(y).to_i.to_s,
  ]
end

def shift_int16(a: Int, count: Int) -> List[String]
  x = a.to_int16!
  [x.shift_left(count).to_i.to_s, x.shift_right(count).to_i.to_s, x.shift_right_unsigned(count).to_i.to_s]
end

def not_int16(a: Int) -> String
  x = a.to_int16!
  x.bit_not.to_i.to_s
end

def wrap_int16(n: Int) -> String = n.wrap_int16.to_i.to_s

def widen_int16(a: Int) -> List[String]
  x = a.to_int16!
  [x.to_int32.to_i.to_s, x.to_f.to_s]
end

def bits_int32(a: Int, b: Int) -> List[String]
  x = a.to_int32!
  y = b.to_int32!
  [
    x.bit_and(y).to_i.to_s,
    x.bit_or(y).to_i.to_s,
    x.bit_xor(y).to_i.to_s,
    x.wrapping_add(y).to_i.to_s,
    x.wrapping_sub(y).to_i.to_s,
    x.wrapping_mul(y).to_i.to_s,
  ]
end

def shift_int32(a: Int, count: Int) -> List[String]
  x = a.to_int32!
  [x.shift_left(count).to_i.to_s, x.shift_right(count).to_i.to_s, x.shift_right_unsigned(count).to_i.to_s]
end

def not_int32(a: Int) -> String
  x = a.to_int32!
  x.bit_not.to_i.to_s
end

def wrap_int32(n: Int) -> String = n.wrap_int32.to_i.to_s

def widen_int32(a: Int) -> List[String]
  x = a.to_int32!
  [x.to_f.to_s]
end

def bits_uint8(a: Int, b: Int) -> List[String]
  x = a.to_uint8!
  y = b.to_uint8!
  [
    x.bit_and(y).to_i.to_s,
    x.bit_or(y).to_i.to_s,
    x.bit_xor(y).to_i.to_s,
    x.wrapping_add(y).to_i.to_s,
    x.wrapping_sub(y).to_i.to_s,
    x.wrapping_mul(y).to_i.to_s,
  ]
end

def shift_uint8(a: Int, count: Int) -> List[String]
  x = a.to_uint8!
  [x.shift_left(count).to_i.to_s, x.shift_right(count).to_i.to_s, x.shift_right_unsigned(count).to_i.to_s]
end

def not_uint8(a: Int) -> String
  x = a.to_uint8!
  x.bit_not.to_i.to_s
end

def wrap_uint8(n: Int) -> String = n.wrap_uint8.to_i.to_s

def widen_uint8(a: Int) -> List[String]
  x = a.to_uint8!
  [x.to_int16.to_i.to_s, x.to_int32.to_i.to_s, x.to_uint16.to_i.to_s, x.to_uint32.to_i.to_s, x.to_f.to_s]
end

def bits_uint16(a: Int, b: Int) -> List[String]
  x = a.to_uint16!
  y = b.to_uint16!
  [
    x.bit_and(y).to_i.to_s,
    x.bit_or(y).to_i.to_s,
    x.bit_xor(y).to_i.to_s,
    x.wrapping_add(y).to_i.to_s,
    x.wrapping_sub(y).to_i.to_s,
    x.wrapping_mul(y).to_i.to_s,
  ]
end

def shift_uint16(a: Int, count: Int) -> List[String]
  x = a.to_uint16!
  [x.shift_left(count).to_i.to_s, x.shift_right(count).to_i.to_s, x.shift_right_unsigned(count).to_i.to_s]
end

def not_uint16(a: Int) -> String
  x = a.to_uint16!
  x.bit_not.to_i.to_s
end

def wrap_uint16(n: Int) -> String = n.wrap_uint16.to_i.to_s

def widen_uint16(a: Int) -> List[String]
  x = a.to_uint16!
  [x.to_int32.to_i.to_s, x.to_uint32.to_i.to_s, x.to_f.to_s]
end

def bits_uint32(a: Int, b: Int) -> List[String]
  x = a.to_uint32!
  y = b.to_uint32!
  [
    x.bit_and(y).to_i.to_s,
    x.bit_or(y).to_i.to_s,
    x.bit_xor(y).to_i.to_s,
    x.wrapping_add(y).to_i.to_s,
    x.wrapping_sub(y).to_i.to_s,
    x.wrapping_mul(y).to_i.to_s,
  ]
end

def shift_uint32(a: Int, count: Int) -> List[String]
  x = a.to_uint32!
  [x.shift_left(count).to_i.to_s, x.shift_right(count).to_i.to_s, x.shift_right_unsigned(count).to_i.to_s]
end

def not_uint32(a: Int) -> String
  x = a.to_uint32!
  x.bit_not.to_i.to_s
end

def wrap_uint32(n: Int) -> String = n.wrap_uint32.to_i.to_s

def widen_uint32(a: Int) -> List[String]
  x = a.to_uint32!
  [x.to_f.to_s]
end

def bits_int(a: Int, b: Int) -> List[String]
  x = a
  y = b
  [
    x.bit_and(y).to_s,
    x.bit_or(y).to_s,
    x.bit_xor(y).to_s,
    x.wrapping_add(y).to_s,
    x.wrapping_sub(y).to_s,
    x.wrapping_mul(y).to_s,
  ]
end

def shift_int(a: Int, count: Int) -> List[String]
  x = a
  [x.shift_left(count).to_s, x.shift_right(count).to_s, x.shift_right_unsigned(count).to_s]
end

def not_int(a: Int) -> String
  x = a
  x.bit_not.to_s
end

def bits(name: String, a: Int, b: Int) -> List[String]
  case name
    "int8" -> bits_int8(a, b)
    "int16" -> bits_int16(a, b)
    "int32" -> bits_int32(a, b)
    "uint8" -> bits_uint8(a, b)
    "uint16" -> bits_uint16(a, b)
    "uint32" -> bits_uint32(a, b)
    "int" -> bits_int(a, b)
    _ -> ["unknown type #{name}"]
  end
end

def shifts(name: String, a: Int, count: Int) -> List[String]
  case name
    "int8" -> shift_int8(a, count)
    "int16" -> shift_int16(a, count)
    "int32" -> shift_int32(a, count)
    "uint8" -> shift_uint8(a, count)
    "uint16" -> shift_uint16(a, count)
    "uint32" -> shift_uint32(a, count)
    "int" -> shift_int(a, count)
    _ -> ["unknown type #{name}"]
  end
end

def negated(name: String, a: Int) -> String
  case name
    "int8" -> not_int8(a)
    "int16" -> not_int16(a)
    "int32" -> not_int32(a)
    "uint8" -> not_uint8(a)
    "uint16" -> not_uint16(a)
    "uint32" -> not_uint32(a)
    "int" -> not_int(a)
    _ -> "unknown type #{name}"
  end
end

def wrapped(name: String, n: Int) -> String
  case name
    "int8" -> wrap_int8(n)
    "int16" -> wrap_int16(n)
    "int32" -> wrap_int32(n)
    "uint8" -> wrap_uint8(n)
    "uint16" -> wrap_uint16(n)
    "uint32" -> wrap_uint32(n)
    _ -> "unknown type #{name}"
  end
end

def widened(name: String, a: Int) -> List[String]
  case name
    "int8" -> widen_int8(a)
    "int16" -> widen_int16(a)
    "int32" -> widen_int32(a)
    "uint8" -> widen_uint8(a)
    "uint16" -> widen_uint16(a)
    "uint32" -> widen_uint32(a)
    _ -> ["unknown type #{name}"]
  end
end

# The wanted results of the line, against the ones the methods give.
def check(line: String) -> Int
  f = line.split(" ")
  a = f[2].to_i!
  got = [""]
  want = f.drop(3)
  case f[0]
    "wrap" -> got = [wrapped(f[1], a)]
    "not" -> got = [negated(f[1], a)]
    "bits" ->
      got = bits(f[1], a, f[3].to_i!)
      want = f.drop(4)
    "shift" ->
      got = shifts(f[1], a, f[3].to_i!)
      want = f.drop(4)
    "widen" -> got = widened(f[1], a)
    _ -> got = ["unknown line"]
  end

  return 0 if got == want

  puts("mismatch: #{line}: got #{got.join(" ")}")
  1
end

def main() -> Void
  _ = IO.gets()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(line)
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
