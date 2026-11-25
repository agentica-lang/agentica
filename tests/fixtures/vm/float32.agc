# Float32 values: the shortest text, an infinity past the largest, -0.0 and NaN as binary32 has them, the conversions,
# a field default and a module constant, a case on a literal, and JSON. tests/fixtures/float32-vectors.py checks the
# values in bulk against fractions.Fraction.
LIMIT: Float32 = 3.4028235e38

struct Reading
  value: Float32
  scale: Float32 = 0.5
end

def main() -> Void
  tenth: Float32 = 0.1
  puts(tenth)
  puts(tenth.to_f)
  puts(tenth + 0.2)
  puts(LIMIT * 2.0)
  puts(-LIMIT * 2.0)
  zero: Float32 = 0.0
  puts(-zero)
  nan = LIMIT * 2.0 - LIMIT * 2.0
  puts("#{nan} #{nan == nan} #{nan != nan} #{nan < 1.0} #{nan.to_bits}")
  puts(Float32.from_bits(2143289345).to_bits)
  puts(9007199791611905.to_float32.to_bits)
  puts(1.0e39.to_float32)
  xs: List[Float32] = [1.5, -0.25, 1e-45, 16777217.0]
  puts(xs)
  puts(xs.inspect)
  reading = Reading(value: 3.0)
  puts(reading)
  puts(JSON.encode(reading))
  puts(JSON.decode("{\"value\": 0.1}", Reading))
  puts(JSON.decode("{\"value\": 1e39}", Reading))
  puts(JSON.schema(Reading))
  case tenth
    0.1 -> puts("a case on 0.1")
    _ -> puts("no case")
  end

  puts(tenth.to_f.to_float32 == tenth)
  puts(Float32.from_bits(1))
end
