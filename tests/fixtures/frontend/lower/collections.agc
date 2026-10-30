def main() -> Void
  empty: List[Int] = []
  xs = [1, 2, 3]
  m = {"a": 1, "b": 2}
  no_items: Map[String, Int] = {}
  nested = [[1], [2, 3]]
  s = Set.new([1, 2, 2])
  s = s.add(5)
  puts("#{xs[1]} #{m["a"]} #{m.get("z", 0)} #{nested[1][0]} #{s.size} #{empty.size} #{no_items.size}")
  ys = xs.push(4).reverse
  puts(ys.map do |v| v * 2 end)
  puts(Map.keys(m))
  puts(s.include?(2))
  other = Set.new([2, 7])
  puts(s.union(other).to_a)
end
