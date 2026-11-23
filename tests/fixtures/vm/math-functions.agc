# Math.exp, log, log10, sin and cos at values every libm gives exactly, and the edge values that Ruby gives too.
# tests/test_spec_math.py checks many more values against Python's math module.
def nan?(x: Float) -> Bool
  return x != x
end

def main() -> Void
  inf = Float.from_bits(9218868437227405312)
  nan = Float.from_bits(9221120237041090560)
  puts(Math.exp(0.0))
  puts(Math.exp(1.0))
  puts(Math.exp(inf))
  puts(Math.exp(0.0 - inf))
  puts(Math.exp(1000.0))
  puts(nan?(Math.exp(nan)))
  puts(Math.log(1.0))
  puts(Math.log(0.0))
  puts(Math.log(-0.0))
  puts(Math.log(inf))
  puts(nan?(Math.log(nan)))
  puts(Math.log10(1000.0))
  puts(Math.log10(0.0))
  puts(Math.log10(inf))
  puts(Math.sin(0.0))
  puts(Math.sin(-0.0))
  puts(nan?(Math.sin(inf)))
  puts(Math.cos(0.0))
  puts(nan?(Math.cos(0.0 - inf)))
end
