def main() -> Void
  puts((-8).shift_right_unsigned(1))
  puts(Int.shift_right_unsigned(8, -9223372036854775807 - 1))
  puts("not reached")
end
