def main() -> Void
  numbers = [1, 2, 0]
  puts(numbers.take(2).flat_map do |n| [10 / n] end)
  puts(numbers.flat_map do |n| [10 / n] end)
end
