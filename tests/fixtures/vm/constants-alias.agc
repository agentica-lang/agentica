import Limits from "lib/limits"

# A constant exported by a module is read through its alias like an exported function.
DOUBLE = Limits.TOP * 2

def main() -> Void
  puts("#{Limits.TOP} #{Limits.top()} #{DOUBLE}")
  puts(Limits.NAMES.size)
  puts(Limits.NAMES[1])
  puts(Limits.STARTS.include?("y"))
  puts(Limits.WINDOW)
  moved = Limits.WINDOW.with(high: 1)
  puts("#{moved.low} #{moved.high} #{Limits.WINDOW.high}")
  puts(Limits.NAMES.map do |name| name + "!" end)
end
