# Each prelude method once on 2,000 elements. The steps in prelude-cost.expected are the cost contract: a body that
# loops more than once for each element, or calls an O(n) builtin inside a loop, changes them.
# The steps are linear in the size (references/performance.md has them for
# 100,000 elements); a longer list would make the --max-steps sweep of the golden check run for minutes.
# The steps do not show that the wall time of tally and uniq grows with the number of distinct keys: that is the
# VM's Map and Set insert cost, the same as in a hand-written loop.
def main() -> Void
  numbers = (1..2000).to_a
  words = numbers.map do |n| "w#{n % 100}" end
  keys = numbers.map do |n| (n * 7919) % 2003 end
  floats = numbers.map do |n| n.to_f end
  counts = numbers.tally
  total = 0
  total += numbers.find { |n| n == 2000 }.unwrap!
  numbers.each_with_index do |n, index|
    if index < 0
      puts(n)
    end
  end
  total += numbers.flat_map { |n| [n, n] }.size
  total += numbers.partition { |n| n % 2 == 0 }[0].size
  total += numbers.take_while { |n| n < 2000 }.size
  total += numbers.drop_while { |n| n < 2000 }.size
  total += numbers.each_slice(3).size
  total += numbers.group_by { |n| n % 100 }.size
  total += words.group_by { |word| word }.size
  total += words.tally.size
  total += keys.uniq.size
  total += numbers.sum
  total += floats.sum.to_i!
  total += numbers.min_by { |n| keys[n - 1] }.unwrap!
  total += numbers.max_by { |n| keys[n - 1] }.unwrap!
  total += floats.min_by { |x| x }.unwrap!.to_i!
  total += words.max_by { |word| word }.unwrap!.length
  counts.each do |key, value|
    if value < 0
      puts(key)
    end
  end
  total += counts.filter { |key, _| key % 2 == 0 }.size
  lazy = numbers.lazy.map { |n| n + 1 }.filter { |n| n % 2 == 0 }.with_index do |n, index| n + index end
  total += lazy.flat_map { |n| [n] }.each_slice(3).each_cons(2).to_a.unwrap!.size
  middle = (1..2000).lazy.drop_while { |n| n < 10 }.take_while { |n| n < 1990 }.drop(5).take(1900)
  total += middle.first(1900).unwrap!.size
  chunked = numbers.lazy.chunk_while { |a, b| b == a + 1 }.reduce(0) do |sum, chunk| sum + chunk.size end
  total += chunked.unwrap!
  naturals = Lazy.produce(1) do |n| n + 1 end
  total += naturals.find { |n| n == 2000 }.unwrap!
  done = numbers.lazy.each { |_| ok() }
  if done.ok?
    total += 1
  end
  puts(total)
end
