def main() -> Void
  xs = [4, 2, 0, 1]
  total = xs.map do |x|
    8 / x
  end
  puts(total)
end
