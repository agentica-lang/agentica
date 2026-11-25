LIMIT: UInt64 = 9223372036854775808

struct Counter
  total: UInt64 = 18446744073709551615
end

def measure(a: UInt64, b: UInt64) -> UInt64
  return (a + b) * 2 - a / b + a % b
end

def order(a: UInt64, b: UInt64) -> List[Bool]
  [a < b, a <= b, a > b, a >= b, a == b, a != b]
end

def label(n: UInt64) -> String
  case n
    0 -> "zero"
    18446744073709551615 -> "max"
    _ -> "other"
  end
end

def main() -> Void
  zero: UInt64 = -0
  puts(measure(LIMIT / 4, 3))
  puts(order(zero, Counter().total))
  puts(label(Counter().total))
end
