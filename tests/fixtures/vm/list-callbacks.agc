struct Item
  name: String
  rank: Int
  score: Float
end

def name_of(item: Item) -> String
  return item.name
end

def is_even(x: Int) -> Bool
  return x % 2 == 0
end

def joined(acc: String, x: Int) -> String
  return "#{acc}<#{x}"
end

def main() -> Void
  no_items: List[Int] = []
  xs = [5, 2, 8, 2, 7]
  puts(xs.map do |x| x * x end)
  puts(no_items.map do |x| x * x end)
  puts(xs.filter(&is_even))
  puts(no_items.filter(&is_even))
  puts(xs.reduce("") do |acc, x| "#{acc}>#{x}" end)
  puts(List.reduce(xs, "start", &joined))
  puts(no_items.reduce(42) do |acc, x| acc + x end)
  xs.each do |x|
    print("#{x};")
  end
  puts("")
  no_items.each do |x|
    puts("never")
  end
  puts(xs.any? do |x|
    puts("any #{x}")
    x > 7
  end)
  puts(xs.all? do |x|
    puts("all #{x}")
    x < 8
  end)
  puts(no_items.any? do |x| true end)
  puts(no_items.all? do |x| false end)
  items = [Item(name: "c", rank: 2, score: 0.5), Item(name: "a", rank: 1, score: -0.0), Item(name: "b", rank: 2, score: 0.0),
           Item(name: "é", rank: 1, score: 0.0 / 1.0), Item(name: "Z", rank: 3, score: -1.5), Item(name: "ab", rank: 0, score: 2.5)]
  ranked = items.sort_by do |it|
    puts("key #{it.name}")
    it.rank
  end
  puts(ranked.map(&name_of))
  puts(items.sort_by(&name_of).map(&name_of))
  puts(items.sort_by do |it| it.score end.map(&name_of))
  big = 10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000.0
  inf = big * 10.0
  nan = inf - inf
  floats = [3.0, nan, -inf, 1.0, nan, inf, -0.0, 0.0, -2.5]
  puts(floats.sort_by do |f| f end)
  puts(floats.sort_by do |f| 0.0 - f end)
  puts(no_items.sort_by do |x| x end)
  puts([9].sort_by do |x| x end)
  tagged = floats.map do |f| "#{f}" end
  puts(tagged.sort_by do |s| s end)
  nested = [[3, 1], [], [2]].map do |row|
    row.sort_by do |x| x end.reduce(0) do |acc, x| acc * 10 + x end
  end
  puts(nested)
end
