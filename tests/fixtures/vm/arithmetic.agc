def noisy(label: Int, value: Bool) -> Bool
  puts(label)
  return value
end

def main() -> Void
  a = 17
  b = -5
  puts(a + b)
  puts(a - b)
  puts(a * b)
  puts(a / b)
  puts(a % b)
  puts(-a / 5)
  puts(-a % 5)
  puts(-9223372036854775808)
  puts(-9223372036854775807 - 1)
  smallest = -9223372036854775807 - 1
  puts(smallest % -1)
  puts(9223372036854775807)
  if a > b and b >= -5 and a != b and not (a == b)
    puts(1)
  end
  if a <= b or b < -5
    puts(0)
  end
  if noisy(10, false) and noisy(11, true)
    puts(0)
  end
  if noisy(12, true) or noisy(13, true)
    puts(14)
  end
  same = true == not false
  if same != false
    puts(15)
  end
end
