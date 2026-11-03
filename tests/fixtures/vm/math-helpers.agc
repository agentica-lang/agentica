# The number helpers of #987 and #857: Int#abs, pow, gcd, clamp; Float#abs, floor, ceil, round, clamp; Math.sqrt;
# List#min and List#max. math-vectors.agc checks many more values against Python.
def infinity() -> Float
  return 1.0e308 * 10.0
end

def main() -> Void
  least = 0 - 9223372036854775807 - 1
  puts((-5).abs)
  puts((-2.5).abs)
  puts((0.0 - 1.0) * 0.0)
  puts(((0.0 - 1.0) * 0.0).abs)
  puts(2.pow(10))
  puts(0.pow(0))
  puts((-1).pow(9223372036854775807))
  puts((-2).pow(63) == least)
  puts(12.gcd(18))
  puts((-12).gcd(18))
  puts(0.gcd(0))
  puts(least.gcd(6))
  puts(15.clamp(1, 10))
  puts((-3).clamp(1, 10))
  puts(4.clamp(4, 4))
  puts(2.5.floor)
  puts((-2.5).floor)
  puts(2.5.ceil)
  puts((-2.5).ceil)
  puts(2.5.round)
  puts((-2.5).round)
  puts(0.49999999999999994.round)
  puts(2.5.clamp(0.0, 1.0))
  puts((-0.5).clamp(0.0, 1.0))
  nan = infinity() - infinity()
  puts(nan.clamp(0.0, 1.0))
  puts(nan.abs)
  puts(Math.sqrt(16.0))
  puts(Math.sqrt(2.0))
  puts(Math.sqrt((0.0 - 1.0) * 0.0))
  puts(Math.sqrt(infinity()))
  puts(Math.sqrt(nan))
  puts([3, 1, 2].min)
  puts([3, 1, 2].max)
  puts([2.5, nan, 0.5].min)
  puts([nan, nan].max)
  puts(["pear", "apple", "fig"].min)
  puts(["pear", "apple", "fig"].max)
  empty: List[Int] = []
  puts(empty.min)
  puts(empty.max.unwrap_or(0))
  puts([700, 80, 512].max.unwrap!.clamp(1, 512))
end
