def check(label: Int, value: Bool) -> Void
  print(label)
  print(" ")
  puts(value)
end

def main() -> Void
  a = 7.5
  b = -2.0
  puts(a + b)
  puts(a - b)
  puts(a * b)
  puts(a / b)
  puts(-a)
  zero = 0.0
  negative_zero = -zero
  huge = 100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0
  inf = huge * huge
  nan = inf - inf
  check(1, a > b)
  check(2, a >= a)
  check(3, a < b)
  check(4, b <= a)
  check(5, a == 7.5)
  check(6, a != 7.5)
  check(7, zero == negative_zero)
  check(8, zero != negative_zero)
  check(9, nan == nan)
  check(10, nan != nan)
  check(11, nan < 1.0)
  check(12, nan > 1.0)
  check(13, nan <= nan)
  check(14, nan >= nan)
  check(15, inf > huge)
  check(16, -inf < -huge)
  puts(1.0 / inf)
  puts(-1.0 / inf)
  puts(inf * zero)
  puts(nan / 2.0)
  puts(2.0 / nan)
  i = 0
  total = 0.0
  while total < 1.0
    total = total + 0.1
    i += 1
  end
  puts(i)
  puts(total)
end
