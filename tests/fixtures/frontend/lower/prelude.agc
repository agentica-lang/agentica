def main() -> Void
  numbers = [3, 1, 4]
  puts(numbers.find do |n| n > 2 end)
  puts(numbers.each_slice(2))
  puts(numbers.sum)
  puts(["b", "a"].min_by do |word| word end)
  puts(numbers.tally)
end
