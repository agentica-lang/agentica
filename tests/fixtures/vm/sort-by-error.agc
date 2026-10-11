def main() -> Void
  keys = [4, 2, 0, 1].sort_by do |x|
    puts("key #{x}")
    8 / x
  end
  puts(keys)
end
