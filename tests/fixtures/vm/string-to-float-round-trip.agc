# Float#to_s reads back with String#to_f: the edges, the special values and
# pseudo-random bit patterns (NaN by x != x).
def same?(x: Float, y: Float) -> Bool
  if x != x
    return y != y
  end
  return Float.to_bits(x) == Float.to_bits(y)
end

def round_trips?(x: Float) -> Bool
  read = x.to_s.to_f
  return read.ok? && same?(x, read.unwrap!)
end

def main() -> Void
  fixed = [0, -9223372036854775808, 1, 4503599627370495, 4503599627370496, 9218868437227405311,
    -4503599627370497, 9218868437227405312, -4503599627370496, 9221120237041090560, 4906019910204099648,
    4607182418800017408, 4591870180066957722, 118622047889322841]
  for bits in fixed
    puts("#{Float.from_bits(bits)} #{round_trips?(Float.from_bits(bits))}")
  end
  seed = 12345
  failures = 0
  count = 0
  while count < 3000
    seed = (seed * 1103515245 + 12345) % 2147483648
    high = seed % 1073741824
    seed = (seed * 1103515245 + 12345) % 2147483648
    bits = high * 8589934592 + seed * 4 + count % 4
    if count % 2 == 1
      bits = 0 - bits - 1
    end
    if !round_trips?(Float.from_bits(bits))
      failures += 1
    end
    count += 1
  end
  puts("random failures: #{failures}")
  for text in ["1e+20", "1.5E-3", "-2e-2", "-0e0", "1e400", "-1e400", "1e-400", "+inf.0", "-inf.0", "+nan.0"]
    puts("#{text} #{text.to_f.inspect}")
  end
  for text in ["1e", "e5", "1e+", "1.e5", " 1", "1_000.0", "Infinity", "NaN", "-nan.0", "inf"]
    puts("#{text.inspect} #{text.to_f.ok?}")
  end
end
