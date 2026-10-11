def main() -> Void
  xs = [4, 2, 0, 1]
  total = xs.reduce(0) do |acc, x|
    puts("at #{x}")
    acc + 8 / x
  end
  puts(total)
end
