# format(...): every conversion with its flags, widths and precisions; tests/fixtures/format-peer.py and
# format-peer.js print the same lines.

def money(x: Float) -> String
  return format("%.2f", x)
end

def row(name: String, price: Float, count: Int) -> String = format("%-8s|%8.3f|%04d|%x", name, price, count, count)

def main() -> Void
  puts(row("apple", 2.5, 7))
  puts(row("crème", -0.125, -255))
  puts(format("[%d] [%5d] [%-5d] [%05d] [%-05d] [%0d]", 42, -42, -42, -42, 42, 7))
  puts(format("[%x] [%6x] [%-6x] [%06x] [%x] [%x]", 255, -255, 48879, -1, 0, -9223372036854775807 - 1))
  puts(format("[%20d] [%-21d]", 9223372036854775807, -9223372036854775807 - 1))
  for x in [0.5, 1.5, 2.5, 2.675, 1.005, -0.5, -0.0, 0.125, 1e-7, 123456.789]
    puts(format("%f|%.0f|%.1f|%.2f|%.3f|%10.4f|%-10.1f|%010.2f", x, x, x, x, x, x, x, x))
  end

  puts(format("%.50f", 0.1))
  puts(format("%.17f|%.20f", 1.0 / 3.0, 2.0 / 3.0))
  puts(format("%.1f", 1.7976931348623157e308))
  puts(format("%.3f|%.0f", 5e-324, 1e22))
  nan = Float.from_bits(9221120237041090560)
  inf = Float.from_bits(9218868437227405312)
  puts(format("[%f] [%6.2f] [%-6f] [%06f] [%f] [%07.1f]", nan, nan, inf, inf, 0.0 - inf, 0.0 - inf))
  puts(format("[%s] [%7s] [%-7s] [%3s] [%s]", "héllo", "héllo", "日本", "toolong", [1, 2]))
  puts(format("100%% of %s is %5.1f%%", "x", 99.95))
  n = 5
  n = format("%3d|%d", n * 2, n).length
  puts(n)
  puts("in #{format("%03d", n)} text")
  puts(money(3.14159))
end
