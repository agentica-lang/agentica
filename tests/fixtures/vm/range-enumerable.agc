# The Enumerable methods of Range give what .to_a and the List method give, on an inclusive, an exclusive and an
# empty range. A runtime error of one (each_slice(0)) is reported at the call.
def check(name: String, same: Bool) -> Void
  puts("#{name}: #{same}")
end

def main() -> Void
  for r in [1..10, 0...7, 5..1]
    xs = r.to_a
    puts(r)
    check("map", r.map do |n| n * n end == xs.map do |n| n * n end)
    check("collect", r.collect do |n| n + 1 end == xs.map do |n| n + 1 end)
    check("select", r.select do |n| n % 3 == 0 end == xs.select do |n| n % 3 == 0 end)
    check("flat_map", r.flat_map do |n| [n, -n] end == xs.flat_map do |n| [n, -n] end)
    check("reduce", r.reduce(7) do |acc, n| acc * 2 + n end == xs.reduce(7) do |acc, n| acc * 2 + n end)
    check("inject", r.inject(0) do |acc, n| acc - n end == xs.reduce(0) do |acc, n| acc - n end)
    check("sum", r.sum == xs.sum)
    check("min", r.min == xs.min)
    check("max", r.max == xs.max)
    check("min_by", r.min_by do |n| (n - 4) * (n - 4) end == xs.min_by do |n| (n - 4) * (n - 4) end)
    check("max_by", r.max_by do |n| "k#{n % 4}" end == xs.max_by do |n| "k#{n % 4}" end)
    check("max_by float", r.max_by do |n| Float.from_int(n % 3) end == xs.max_by do |n| Float.from_int(n % 3) end)
    check("find", r.find do |n| n > 3 end == xs.find do |n| n > 3 end)
    check("detect", r.detect do |n| n > 30 end == xs.find do |n| n > 30 end)
    check("find_index", r.find_index do |n| n == 5 end == xs.find_index do |n| n == 5 end)
    check("any?", r.any? do |n| n > 8 end == xs.any? do |n| n > 8 end)
    check("all?", r.all? do |n| n < 9 end == xs.all? do |n| n < 9 end)
    check("each_slice", r.each_slice(3) == xs.each_slice(3))
    check("partition", r.partition do |n| n % 2 == 0 end == xs.partition do |n| n % 2 == 0 end)
    check("group_by", r.group_by do |n| n % 3 end == xs.group_by do |n| n % 3 end)
    check("take_while", r.take_while do |n| n < 4 end == xs.take_while do |n| n < 4 end)
    check("drop_while", r.drop_while do |n| n < 4 end == xs.drop_while do |n| n < 4 end)
    r.each_with_index do |n, index| print("#{index}:#{n} ") end
    puts("")
  end

  puts((1..3).map do |n| n * 10 end)
  puts((5..1).max)
  puts((0...3000).sum)
  puts((1..4).each_slice(0))
end
