def show(r: Result[Int]) -> Void
  case r
    ok(n) -> puts("ok #{n}")
    error(m) -> puts("error #{m}")
  end
end

def main() -> Void
  big = 9223372036854775807
  puts(0.to_f)
  puts((-7).to_f)
  puts(9007199254740993.to_f)
  puts(big.to_f)
  puts((-big - 1).to_f)
  puts(12345.to_f)
  puts(2.9.to_i!)
  puts((-2.9).to_i!)
  puts((-0.5).to_i!)
  puts((0.0 - 0.0).to_i!)
  puts(1000000000000000000.0.to_i!)
  puts((-9223372036854775808.0).to_i!)
  puts(9223372036854774784.0.to_i!)
  huge = 100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0
  inf = huge * huge
  nan = inf - inf
  show(1.5.to_i)
  show(9223372036854775808.0.to_i)
  show((-9223372036854777856.0).to_i)
  show(nan.to_i)
  show(inf.to_i)
  show((-inf).to_i)
  show(0.000001.to_i)
  puts(1.5e-3)
  puts(2.0E+10)
  puts(1e5)
  puts(1.0e300 == 1e300)
  puts(1_0.5e1_0)
  puts(1e999)
  puts(-1e999)
  puts("1.5e-3".to_f! == 1.5e-3)
end
