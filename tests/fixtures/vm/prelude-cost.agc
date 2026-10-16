# Each prelude method once on 2,000 elements. The steps in prelude-cost.expected are the cost contract: a body that
# loops more than once for each element, or calls an O(n) builtin inside a loop, changes them
# (docs/future/25-ruby-typed-idioms.md 25.6). The steps are linear in the size (references/performance.md has them for
# 100,000 elements); a longer list would make the --max-steps sweep of the golden check run for minutes.
# The steps do not show that the wall time of tally and uniq grows with the number of distinct keys: that is the
# VM's Map and Set insert cost, the same as in a hand-written loop.
def main() -> Void
  numbers = (1..2000).to_a
  words = numbers.map do |n| "w#{n % 100}" end
  keys = numbers.map do |n| (n * 7919) % 2003 end
  floats = numbers.map do |n| Float.from_int(n) end
  counts = numbers.tally
  total = 0
  total += numbers.find do |n| n == 2000 end.unwrap!
  numbers.each_with_index do |n, index|
    if index < 0
      puts(n)
    end
  end
  total += numbers.flat_map do |n| [n, n] end.size
  total += numbers.partition do |n| n % 2 == 0 end[0].size
  total += numbers.take_while do |n| n < 2000 end.size
  total += numbers.drop_while do |n| n < 2000 end.size
  total += numbers.each_slice(3).size
  total += numbers.group_by do |n| n % 100 end.size
  total += words.group_by do |word| word end.size
  total += words.tally.size
  total += keys.uniq.size
  total += numbers.sum
  total += floats.sum.to_i!
  total += numbers.min_by do |n| keys[n - 1] end.unwrap!
  total += numbers.max_by do |n| keys[n - 1] end.unwrap!
  total += floats.min_by do |x| x end.unwrap!.to_i!
  total += words.max_by do |word| word end.unwrap!.length
  counts.each do |key, value|
    if value < 0
      puts(key)
    end
  end
  total += counts.filter do |key, value| key % 2 == 0 end.size
  puts(total)
end
