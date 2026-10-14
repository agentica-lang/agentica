def infinity() -> Float
  x = 10.0
  i = 0
  while i < 9
    x = x * x
    i += 1
  end
  return x
end

def power_of_two(exponent: Int) -> Float
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

def text(x: Float) -> String
  if x != x
    return "nan"
  end
  return x.to_s
end

def round_trip_ok(x: Float) -> Bool
  return text(Float.from_bits(Float.to_bits(x))) == text(x)
end

def main() -> Void
  inf = infinity()
  nan = inf - inf
  negative_zero = (0.0 - 1.0) * 0.0
  smallest = Float.from_bits(1)
  puts(Float.to_bits(1.0))
  puts(Float.to_bits(2.0))
  puts(Float.to_bits(-2.0))
  puts(Float.to_bits(0.0))
  puts(Float.to_bits(negative_zero))
  puts(Float.to_bits(inf))
  puts(Float.to_bits(0.0 - inf))
  puts(Float.to_bits(nan))
  puts(Float.to_bits(0.0 - nan))
  puts(Float.to_bits(smallest))
  puts(smallest.to_bits)
  puts(negative_zero.to_bits < 0)
  puts(0.0.to_bits < 0)
  puts(Float.from_bits(4607182418800017408))
  puts(Float.from_bits(0))
  puts(text(Float.from_bits(-9223372036854775808)))
  puts(Float.from_bits(-9223372036854775808).to_s)
  puts(Float.from_bits(9218868437227405312))
  puts(Float.from_bits(-4503599627370496))
  puts(text(Float.from_bits(9221120237041090560)))
  puts(text(Float.from_bits(9221120237041090561)))
  puts(text(Float.from_bits(-1)))
  puts(text(Float.from_bits(9218868437227405313)))
  puts(Float.to_bits(Float.from_bits(9221120237041090561)))
  puts(Float.to_bits(Float.from_bits(-1)))
  puts(Float.from_bits(4503599627370496) == power_of_two(-1022))
  puts(Float.from_bits(1) == power_of_two(-1074))
  puts(Float.from_bits(4611686018427387904))
  puts(Float.to_bits32(1.0))
  puts(Float.to_bits32(-1.5))
  puts(Float.to_bits32(0.0))
  puts(Float.to_bits32(negative_zero))
  puts(Float.to_bits32(inf))
  puts(Float.to_bits32(0.0 - inf))
  puts(Float.to_bits32(nan))
  puts(Float.to_bits32(0.0 - nan))
  puts(Float.to_bits32(0.1))
  puts(Float.to_bits32(1.0 + power_of_two(-24)))
  puts(Float.to_bits32(1.0 + 3.0 * power_of_two(-24)))
  puts(Float.to_bits32(1.0 + power_of_two(-23)))
  puts(Float.to_bits32(340282346638528859811704183484516925440.0))
  puts(Float.to_bits32(340282356779733661637539395458142568448.0))
  puts(Float.to_bits32(0.0 - 340282356779733661637539395458142568448.0))
  puts(Float.to_bits32(power_of_two(1000)))
  puts(Float.to_bits32(power_of_two(-126)))
  puts(Float.to_bits32(power_of_two(-149)))
  puts(Float.to_bits32(power_of_two(-150)))
  puts(Float.to_bits32(0.0 - power_of_two(-150)))
  puts(Float.to_bits32(3.0 * power_of_two(-150)))
  puts(Float.to_bits32(power_of_two(-1074)))
  puts(Float.from_bits32(1065353216))
  puts(Float.from_bits32(0))
  puts(text(Float.from_bits32(2147483648)))
  puts(Float.from_bits32(2147483648).to_s)
  puts(Float.from_bits32(2139095040))
  puts(Float.from_bits32(4286578688))
  puts(Float.from_bits32(1) == power_of_two(-149))
  puts(Float.from_bits32(8388607) == power_of_two(-126) - power_of_two(-149))
  puts(Float.from_bits32(2139095039) == 340282346638528859811704183484516925440.0)
  puts(Float.from_bits32(1036831949))
  puts(text(Float.from_bits32(2143289344)))
  puts(text(Float.from_bits32(2143289345)))
  puts(text(Float.from_bits32(2139095041)))
  puts(text(Float.from_bits32(4294967295)))
  puts(Float.to_bits(Float.from_bits32(1065353216)))
  samples = [0.0, negative_zero, 1.0, -1.5, 0.1, 3.141592653589793, inf, 0.0 - inf, nan, smallest, power_of_two(-1022), power_of_two(1023)]
  agree = 0
  for x in samples
    if round_trip_ok(x)
      agree += 1
    end
  end
  puts("#{agree} of #{samples.size} float round trips")
  patterns = [0, 1, 8388607, 8388608, 1065353216, 2139095039, 2139095040, 2147483648, 2147483649, 4286578688, 2143289344, 2143289345, 2139095041, 4294967295, 4290772992]
  for n in patterns
    puts("#{n} -> #{Float.to_bits32(Float.from_bits32(n))}")
  end
end
