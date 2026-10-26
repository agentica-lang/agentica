def show(r: Result[Int]) -> Void
  case r
    ok(n) -> puts("ok #{n}")
    error(m) -> puts("error #{m}")
  end
end

def main() -> Void
  big = 9223372036854775807
  puts(Float.from_int(0))
  puts(Float.from_int(-7))
  puts(Float.from_int(9007199254740993))
  puts(Float.from_int(big))
  puts(Float.from_int(-big - 1))
  puts(12345.to_f)
  puts(Float.to_int!(2.9))
  puts(Float.to_int!(-2.9))
  puts(Float.to_int!(-0.5))
  puts((0.0 - 0.0).to_i!)
  puts(1000000000000000000.0.to_i!)
  puts(Float.to_int!(-9223372036854775808.0))
  puts(9223372036854774784.0.to_i!)
  huge = 100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0
  inf = huge * huge
  nan = inf - inf
  show(Float.to_int(1.5))
  show(Float.to_int(9223372036854775808.0))
  show(Float.to_int(-9223372036854777856.0))
  show(nan.to_i)
  show(inf.to_i)
  show((-inf).to_i)
  show(Float.to_int(0.000001))
  puts(1.5e-3)
  puts(2.0E+10)
  puts(1e5)
  puts(1.0e300 == 1e300)
  puts(1_0.5e1_0)
  puts(1e999)
  puts(-1e999)
  puts("1.5e-3".to_f! == 1.5e-3)
end
