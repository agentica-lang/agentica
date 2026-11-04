def main() -> Void
  seen: Set[String] = Set.new([])
  seen = seen.add("a").add("b")
  nums = Set.new([1, 2, 2])
  other: Set[Int] = Set.new([2, 3])
  _both: Set[Int] = nums.union(other).intersection(other).difference(Set.new([3]))
  _n: Int = seen.size
  _e: Bool = nums.empty? or nums.include?(1) or nums.subset?(other)
  _xs: List[Int] = Set.to_a(nums.delete(1))
  for x in seen
    puts(x + "!")
  end
  puts("#{nums} #{seen.inspect}")
  _ = Test.eq(nums, other)
end

