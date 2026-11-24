# The narrow integer types: literals typed by their context, printing, ==, case, to_int, and Int.to_uint16! halting on
# a value outside the type.

struct Pixel
  r: UInt8
  g: UInt8
end

def lowest() -> Int16 = -32768

def widest(x: UInt32) -> UInt32 = x

def main() -> Void
  a: UInt8 = 200
  b: Int8 = -128
  p = Pixel(r: 255, g: 0)
  xs: List[UInt16] = [1, 65535]
  m: Map[String, Int32] = {"low": -2147483648, "high": 2147483647}
  puts("#{a} #{b} #{lowest()} #{widest(4294967295)} #{xs} #{m}")
  puts(p.inspect)
  puts(a.to_s + " " + b.inspect)
  puts(a == p.r)
  puts(p.r == 255.to_uint8!)
  puts(a.to_int + b.to_int)
  case a
    200 -> puts("two hundred")
    _ -> puts("other")
  end

  puts(Int.to_int8(300).ok?)
  n = 70000
  puts(n.to_uint16!)
end
