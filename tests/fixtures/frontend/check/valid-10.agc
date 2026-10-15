def main() -> Void
  seen: Set[String] = Set.new([])
  seen = seen.add("a").add("b")
  nums = Set.new([1, 2, 2])
  other: Set[Int] = Set.new([2, 3])
  both: Set[Int] = nums.union(other).intersection(other).difference(Set.new([3]))
  n: Int = seen.size
  e: Bool = nums.empty? or nums.include?(1) or nums.subset?(other)
  xs: List[Int] = Set.to_a(nums.delete(1))
  for x in seen
    puts(x + "!")
  end
  puts("#{nums} #{seen.inspect}")
  r = Test.eq(nums, other)
end

